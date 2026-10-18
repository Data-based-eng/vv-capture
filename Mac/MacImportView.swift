import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// The Mac app's whole UI: a scan library plus the import panel.
///
/// There is no capture here. A folder of stills (or a single video) goes in,
/// the import engine stages sharp frames, and PhotogrammetrySession builds
/// the mesh at medium/full/raw — detail levels iOS cannot offer.
struct MacImportView: View {
    @Environment(ScanStorage.self) private var storage

    @State private var engine: MacImportEngine?
    @State private var selection: ScanRecord.ID?
    @State private var detail: ReconstructionDetail = .full
    @State private var isolateObject = true
    @State private var frameCount = 48
    @State private var showFolderImporter = false
    @State private var showVideoImporter = false
    @State private var error: String?
    @State private var isBusy = false

    var body: some View {
        NavigationSplitView {
            libraryList
        } detail: {
            if let record = selectedRecord {
                scanDetail(record)
            } else {
                importPanel
            }
        }
        .navigationTitle("VV Capture")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Import photo folder…") { showFolderImporter = true }
                    Button("Import video…") { showVideoImporter = true }
                } label: {
                    Label("Import", systemImage: "plus")
                }
                .disabled(isBusy)
            }
            if isBusy {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Cancel", role: .cancel) { engine?.cancel() }
                }
            }
        }
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in beginImport(result, kind: .folder) }
        .fileImporter(
            isPresented: $showVideoImporter,
            allowedContentTypes: [.movie, .video],
            allowsMultipleSelection: false
        ) { result in beginImport(result, kind: .video) }
        .dropDestination(for: URL.self) { urls, _ in
            guard !isBusy, !urls.isEmpty else { return false }
            beginImport(.success(urls), kind: .dropped)
            return true
        }
        .alert("Import failed", isPresented: errorBinding) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )
    }

    // MARK: - Library

    private var selectedRecord: ScanRecord? {
        storage.scans.first { $0.id == selection }
    }

    private var libraryList: some View {
        List(selection: $selection) {
            Section("Scans") {
                ForEach(storage.scans) { record in
                    Label {
                        VStack(alignment: .leading) {
                            Text(record.name).font(.headline).lineLimit(1)
                            Text(subtitle(for: record))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "cube")
                    }
                    .tag(record.id)
                    .contextMenu {
                        Button("Reveal in Finder") {
                            reveal(record)
                        }
                        Button("Delete", role: .destructive) {
                            delete(record)
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets {
                        try? storage.deleteScan(id: storage.scans[i].id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func subtitle(for record: ScanRecord) -> String {
        var parts: [String] = []
        if let n = record.imageCount { parts.append("\(n) photos") }
        if let d = record.detail { parts.append(d.displayName) }
        return parts.joined(separator: " · ")
    }

    private func reveal(_ record: ScanRecord) {
        NSWorkspace.shared.activateFileViewerSelecting(
            [storage.directoryURL(for: record)])
    }

    private func delete(_ record: ScanRecord) {
        if selection == record.id { selection = nil }
        try? storage.deleteScan(id: record.id)
    }

    // MARK: - Import panel

    private enum ImportKind { case folder, video, dropped }

    private var importPanel: some View {
        Form {
            Section("Source") {
                Text("Drop a folder of photos (or a single video) onto this window, "
                    + "or use the Import menu. Photos stay in capture order — "
                    + "name them so alphabetical order is orbit order.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Reconstruction") {
                Picker("Detail", selection: $detail) {
                    ForEach(ReconstructionDetail.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                Text(detail.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("Isolate object from background", isOn: $isolateObject)
                Stepper("Frames per video: \(frameCount)", value: $frameCount,
                        in: 8...120, step: 8)
            }
            Section {
                if isBusy {
                    busyView
                } else {
                    HStack {
                        Button("Choose photo folder…") { showFolderImporter = true }
                        Button("Choose video…") { showVideoImporter = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 560)
        .padding()
    }

    private var busyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(progressTitle).font(.headline)
            if let fraction = progressFraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            if let eta = progressETA {
                Text(eta).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var progressTitle: String {
        guard let engine else { return "Working…" }
        switch engine.phase {
        case .idle: return "Waiting…"
        case .preparing: return "Preparing…"
        case .capturing(let shots): return "Staging \(shots) photos…"
        case .processingVideo(let p):
            return p.stage ?? "Processing video…"
        case .reconstructing(let p):
            return p.stage?.displayName ?? "Reconstructing…"
        case .done: return "Done"
        case .failed(let m): return m
        case .cancelled: return "Cancelled"
        }
    }

    private var progressFraction: Double? {
        guard let engine else { return nil }
        switch engine.phase {
        case .processingVideo(let p): return p.fraction
        case .reconstructing(let p): return p.fraction
        default: return nil
        }
    }

    private var progressETA: String? {
        guard let engine, case .reconstructing(let p) = engine.phase else {
            return nil
        }
        return p.remainingText
    }

    private func beginImport(
        _ result: Result<[URL], Error>, kind: ImportKind
    ) {
        let urls: [URL]
        switch result {
        case .failure(let e):
            error = e.localizedDescription
            return
        case .success(let u):
            guard !u.isEmpty, !isBusy else { return }
            urls = u
        }
        _ = kind

        let engine = MacImportEngine(storage: storage)
        engine.configure(
            imageURLs: urls,
            detail: detail,
            enableObjectMasking: isolateObject,
            videoFrameCount: frameCount)
        self.engine = engine
        self.error = nil
        isBusy = true
        Task {
            do {
                try await engine.start()
                let record = try await engine.finish()
                selection = record.id
            } catch {
                if !(error is CancellationError)
                    && !(error is ScanEngineError && engine.phase == .cancelled)
                {
                    self.error = error.localizedDescription
                }
            }
            isBusy = false
        }
    }

    // MARK: - Scan detail

    private func scanDetail(_ record: ScanRecord) -> some View {
        VStack(spacing: 0) {
            ModelPreviewView(url: storage.modelURL(for: record))
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.name).font(.headline)
                    Text(detailLine(for: record))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reveal in Finder") { reveal(record) }
                Button("Delete", role: .destructive) { delete(record) }
            }
            .padding()
        }
    }

    private func detailLine(for record: ScanRecord) -> String {
        var parts: [String] = []
        parts.append(record.createdAt.formatted(date: .abbreviated, time: .shortened))
        if let n = record.imageCount { parts.append("\(n) photos") }
        if let d = record.detail { parts.append(d.displayName) }
        if let dims = record.dimensionsMillimetres, dims.count == 3 {
            parts.append("\(dims[0])×\(dims[1])×\(dims[2]) mm")
        }
        if let summary = record.summary { parts.append(summary) }
        return parts.joined(separator: " · ")
    }
}
