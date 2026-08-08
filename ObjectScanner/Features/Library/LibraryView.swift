import SwiftUI

struct LibraryView: View {
    @Environment(ScanStorage.self) private var storage

    /// Hand-rolled rather than using `List(selection:)` plus `EditButton`.
    ///
    /// Two reasons, both found the hard way. A `selection` binding on `List` takes
    /// over row taps, so `NavigationLink` rows stop navigating and just highlight.
    /// And `EditButton` writes to the ambient `editMode` environment value, which a
    /// local `.environment(\.editMode, …)` override on the list silently
    /// disconnects — the button toggles one value while the list reads another.
    ///
    /// Owning the mode means a tap does exactly one thing, chosen here.
    @State private var isSelecting = false
    @State private var selection = Set<UUID>()
    @State private var isConfirmingBulkDelete = false

    var body: some View {
        Group {
            if storage.scans.isEmpty {
                ContentUnavailableView(
                    "Henüz tarama yok",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("Tara sekmesinden ilk taramanızı yapın.")
                )
            } else {
                List {
                    ForEach(storage.scans) { record in
                        row(for: record)
                    }
                    .onDelete { offsets in
                        delete(storage.scans.enumerated().filter { offsets.contains($0.offset) }.map(\.element))
                    }
                }
            }
        }
        // Doubles as confirmation that tapping a row actually registered.
        .navigationTitle(selectionTitle)
        .navigationDestination(for: UUID.self) { ScanDetailView(recordID: $0) }
        .toolbar {
            if !storage.scans.isEmpty {
                if isSelecting {
                    ToolbarItem(placement: .topBarLeading) { selectAllButton }
                    // Not `.bottomBar`: this screen lives inside a TabView, whose tab
                    // bar owns the bottom edge, and the item simply never drew there.
                    ToolbarItem(placement: .topBarTrailing) { deleteSelectedButton }
                }
                ToolbarItem(placement: .topBarTrailing) { selectModeButton }
            }
        }
        .confirmationDialog(
            "\(selection.count) tarama silinsin mi?",
            isPresented: $isConfirmingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Sil", role: .destructive) { deleteSelected() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Modeller ve kaynak görüntüler kalıcı olarak silinir. Bu geri alınamaz.")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for record: ScanRecord) -> some View {
        let content = ScanRow(record: record, modelURL: storage.modelURL(for: record))

        if isSelecting {
            Button {
                if selection.contains(record.id) {
                    selection.remove(record.id)
                } else {
                    selection.insert(record.id)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selection.contains(record.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selection.contains(record.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    content
                }
                .contentShape(.rect)
            }
            // Plain, or the whole row would render in the accent colour.
            .buttonStyle(.plain)
        } else {
            // Navigate by id, not by value: the detail screen renames records, and a
            // captured copy would go stale immediately.
            NavigationLink(value: record.id) { content }
        }
    }

    // MARK: - Toolbar

    private var selectionTitle: String {
        guard isSelecting else { return "Kütüphane" }
        return selection.isEmpty ? String(localized: "Seçin") : "\(selection.count) seçildi"
    }

    private var selectModeButton: some View {
        Button(isSelecting ? "Bitti" : "Seç") {
            isSelecting.toggle()
            // Ticks left behind would silently apply to the next round of selecting.
            if !isSelecting { selection.removeAll() }
        }
    }

    private var selectAllButton: some View {
        Button(selection.count == storage.scans.count ? "Seçimi Kaldır" : "Tümünü Seç") {
            if selection.count == storage.scans.count {
                selection.removeAll()
            } else {
                selection = Set(storage.scans.map(\.id))
            }
        }
    }

    private var deleteSelectedButton: some View {
        Button {
            isConfirmingBulkDelete = true
        } label: {
            Label("Sil", systemImage: "trash")
        }
        // Red rather than the accent colour, so it reads as destructive even though
        // it now sits in the navigation bar next to a harmless "Bitti".
        .tint(.red)
        .disabled(selection.isEmpty)
    }

    // MARK: - Actions

    private func deleteSelected() {
        // Resolved to records before deleting: `storage.scans` shrinks as it goes,
        // so anything holding indices would delete the wrong rows.
        delete(storage.scans.filter { selection.contains($0.id) })
        selection.removeAll()
        isSelecting = false
    }

    private func delete(_ records: [ScanRecord]) {
        for record in records {
            // The thumbnail is cached by URL, and a new scan can reuse a path.
            ThumbnailStore.shared.invalidate(storage.modelURL(for: record))
            storage.delete(record)
        }
    }
}

private struct ScanRow: View {
    let record: ScanRecord
    let modelURL: URL

    var body: some View {
        HStack(spacing: 12) {
            if record.isPreviewable {
                ModelThumbnailView(url: modelURL, side: 54)
            } else {
                // Quick Look cannot render a point cloud, so there is nothing to
                // thumbnail until the meshing pass lands.
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(width: 54, height: 54)
                    .overlay {
                        Image(systemName: "aqi.medium")
                            .foregroundStyle(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(record.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Label(record.engine.displayName, systemImage: record.engine.symbolName)
                    if let summary = record.summary {
                        Text("·")
                        Text(summary)
                    }
                    if let count = record.imageCount {
                        Text("·")
                        Text("\(count) görüntü")
                    }
                    if let count = record.pointCount {
                        Text("·")
                        Text("\(count) nokta")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

struct ScanDetailView: View {
    let recordID: UUID

    @Environment(ScanStorage.self) private var storage

    @State private var exportFormat: MeshExportFormat = .usdz
    @State private var shareableURL: URL?
    @State private var isExporting = false
    @State private var isBundling = false
    @State private var errorMessage: String?
    @State private var draftName = ""

    private var record: ScanRecord? {
        storage.scans.first { $0.id == recordID }
    }

    var body: some View {
        if let record {
            detail(for: record)
        } else {
            // Reachable if the scan is deleted while this screen is on-screen.
            ContentUnavailableView("Tarama bulunamadı", systemImage: "questionmark.folder")
        }
    }

    private func detail(for record: ScanRecord) -> some View {
        List {
            if record.isPreviewable {
                Section {
                    ModelPreviewView(url: storage.modelURL(for: record))
                        .frame(height: 320)
                        .listRowInsets(EdgeInsets())
                }
            } else {
                Section {
                    PointCloudPreviewView(url: storage.modelURL(for: record))
                        .frame(height: 320)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Döndürmek için sürükleyin, yakınlaşmak için iki parmak.")
                }
            }

            Section("Bilgi") {
                TextField("İsim", text: $draftName)
                    .onSubmit { storage.rename(record, to: draftName) }
                LabeledContent("Mod", value: record.engine.displayName)
                if let summary = record.summary {
                    LabeledContent("İçerik", value: summary)
                }
                if let detail = record.detail {
                    LabeledContent("Yoğunluk", value: detail.displayName)
                }
                LabeledContent("Ölçek", value: record.isMetricallyScaled ? String(localized: "Gerçek boyut") : String(localized: "Ölçeksiz"))
                LabeledContent("Tarih", value: record.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let count = record.imageCount {
                    LabeledContent("Görüntü", value: "\(count)")
                }
                if let count = record.pointCount {
                    LabeledContent("Nokta", value: "\(count)")
                }
                if let dimensions = record.dimensionsMillimetres, dimensions.count == 3 {
                    LabeledContent(
                        "Boyut",
                        value: "\(dimensions[0]) × \(dimensions[1]) × \(dimensions[2]) mm"
                    )
                }
            }

            exportSection(for: record)

            if storage.hasIntermediates(for: record) {
                fullDetailSection(for: record)
            }
        }
        .navigationTitle(record.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let shareableURL {
                    ShareLink(item: shareableURL)
                }
            }
        }
        .alert(
            "İşlem başarısız",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("Tamam") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear { draftName = record.name }
    }

    // MARK: - Sections

    @ViewBuilder
    private func exportSection(for record: ScanRecord) -> some View {
        if record.isPreviewable {
            meshExportSection(for: record)
        } else {
            // `MeshExporter` runs through ModelIO, which has nothing to convert
            // here — the PLY is already the deliverable.
            Section {
                Button("PLY'yi Paylaş") { sharePointCloud(record) }
            } header: {
                Text("Dışa aktarma")
            } footer: {
                Text("Nokta bulutu PLY olarak kaydedildi. Mesh'e çevirme (marching cubes) sonraki artımda gelecek.")
            }
        }
    }

    private func meshExportSection(for record: ScanRecord) -> some View {
        Section {
            Picker("Format", selection: $exportFormat) {
                ForEach(MeshExportFormat.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(exportFormat.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if exportFormat.isGeometryOnly {
                Label("Bu format materyal/texture taşımaz — sadece geometri.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                export(record)
            } label: {
                HStack {
                    Text("Dışa Aktar")
                    if isExporting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isExporting)
        } header: {
            Text("Dışa aktarma")
        } footer: {
            Text("Hazırlanan dosya sağ üstteki paylaş düğmesinde görünür.")
        }
    }

    private func fullDetailSection(for record: ScanRecord) -> some View {
        Section {
            LabeledContent(
                "Kaynak görüntüler",
                value: ByteCountFormatter.string(
                    fromByteCount: storage.intermediateBytes(for: record),
                    countStyle: .file
                )
            )

            Button {
                bundleImages(record)
            } label: {
                HStack {
                    Text("Görüntüleri Mac'e Aktar (.zip)")
                    if isBundling {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isBundling)

            DisclosureGroup("Mac tarafında ne yapmalı?") {
                Text(SourceImageBundle.macInstructions)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Button("Kaynak Görüntüleri Sil", role: .destructive) {
                storage.purgeIntermediates(for: record)
            }
        } header: {
            Text("Tam detay")
        } footer: {
            Text("Cihaz üstü model `reduced` seviyede. Aynı görüntüleri bir Mac'te `detail: .full` veya `.raw` ile işlerseniz belirgin şekilde yüksek poligonlu mesh alırsınız. Görüntüleri silerseniz bu yol kapanır.")
        }
    }

    // MARK: - Actions

    private func export(_ record: ScanRecord) {
        isExporting = true
        shareableURL = nil
        Task {
            do {
                shareableURL = try await MeshExporter.export(
                    modelAt: storage.modelURL(for: record),
                    as: exportFormat,
                    namedLike: record.name
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }

    private func sharePointCloud(_ record: ScanRecord) {
        shareableURL = storage.modelURL(for: record)
    }

    private func bundleImages(_ record: ScanRecord) {
        isBundling = true
        shareableURL = nil
        Task {
            do {
                shareableURL = try await SourceImageBundle.makeArchive(
                    imagesDirectory: storage.directoryURL(for: record).appending(path: "images"),
                    named: record.name
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isBundling = false
        }
    }
}

#Preview {
    NavigationStack { LibraryView() }
        .environment(ScanStorage())
        .preferredColorScheme(.dark)
}
