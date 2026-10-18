import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import RealityKit
import UniformTypeIdentifiers
import os

/// Folder/video import engine for macOS: no camera, just stills (or a video to
/// pull stills from) in, a PhotogrammetrySession reconstruction out — at
/// medium/full/raw detail, which iOS cannot offer.
///
/// Lifecycle mirrors the capture engines: `configure(...)` selects the input,
/// `start()` validates, `finish()` stages the stills and runs the solver,
/// `cancel()` aborts. The returned `ScanRecord` is already persisted.
@MainActor
@Observable
final class MacImportEngine: ScanEngine {
    static let kind: ScanEngineKind = .macImport

    static var availability: EngineAvailability {
        PhotogrammetrySession.isSupported
            ? .available
            : .unsupportedDevice(reason: String(
                localized: "This Mac doesn't support on-device photogrammetry."))
    }

    private static let logger = Logger(
        subsystem: "com.visionvend.capture", category: "mac-import")

    /// Stills the solver ingests — mirrors PhotogrammetryReconstructor's set.
    private static let sourceImageExtensions: Set<String> =
        ["heic", "heif", "jpg", "jpeg", "png"]
    /// Video containers we know how to pull frames from.
    private static let sourceVideoExtensions: Set<String> =
        ["mp4", "mov", "m4v"]

    private(set) var phase: ScanPhase = .idle

    private let storage: ScanStorage
    private let reconstructor = PhotogrammetryReconstructor()
    private var workspace: ScanWorkspace?
    private var finishTask: Task<ScanRecord, Error>?
    private var isCancelled = false
    private var warnings: [String] = []

    private var importURLs: [URL] = []
    private var detail: ReconstructionDetail = .full
    private var enableObjectMasking = true
    private var videoFrameCount = 48

    init(storage: ScanStorage) {
        self.storage = storage
    }

    /// Select the input before `start()`: a folder of stills, loose stills, or
    /// a single video. Folder URLs are read at `finish()` time.
    func configure(
        imageURLs: [URL],
        detail: ReconstructionDetail,
        enableObjectMasking: Bool,
        videoFrameCount: Int = 48
    ) {
        self.importURLs = imageURLs
        self.detail = detail
        self.enableObjectMasking = enableObjectMasking
        self.videoFrameCount = max(8, videoFrameCount)
    }

    func start() async throws {
        guard Self.availability.isUsable else {
            throw ScanEngineError.sessionUnavailable(
                Self.availability.blockedReason ?? "unavailable")
        }
        guard !importURLs.isEmpty else { throw ScanEngineError.noImagesCaptured }
        phase = .preparing
    }

    func finish() async throws -> ScanRecord {
        let task = Task<ScanRecord, Error> { [weak self] in
            guard let self else { throw ScanEngineError.cancelled }
            return try await self.finishImpl()
        }
        finishTask = task
        return try await task.value
    }

    private func finishImpl() async throws -> ScanRecord {
        let workspace: ScanWorkspace
        do {
            workspace = try storage.makeWorkspace()
        } catch {
            phase = .failed(message: error.localizedDescription)
            throw error
        }
        self.workspace = workspace
        defer { self.workspace = nil }

        do {
            try Task.checkCancellation()
            let staged = try await stageImages(into: workspace)
            guard staged > 0 else {
                storage.discard(workspace)
                phase = .failed(message: String(
                    localized: "No usable images found in the selection."))
                throw ScanEngineError.noImagesCaptured
            }

            phase = .reconstructing(ReconstructionProgress())
            let output = try await reconstructor.reconstruct(
                workspace: workspace,
                detail: detail,
                maskRect: nil,
                enableObjectMasking: enableObjectMasking,
                framing: .orbit,
                onWarning: { [weak self] note in self?.warnings.append(note) }
            ) { [weak self] progress in
                self?.phase = .reconstructing(progress)
            }

            if isCancelled {
                storage.discard(workspace)
                phase = .cancelled
                throw ScanEngineError.cancelled
            }

            if let poses = output.poses {
                warnings.append(contentsOf: poses.advice)
            }

            let record = ScanRecord(
                id: workspace.id,
                name: Self.defaultName(for: Date()),
                engine: Self.kind,
                // Scale comes from depth embedded in each still. Imported
                // photos carry none, so no metric claim is made.
                isMetricallyScaled: false,
                imageCount: staged,
                detail: detail,
                summary: output.poses?.summaryText
            )
            try storage.commit(record, workspace: workspace)
            phase = .done(record)
            return record
        } catch {
            // A cancel that lands mid-run must win over the failure: the
            // workspace is being discarded, so staying cancelled and
            // committing nothing is the only consistent outcome.
            if isCancelled || error is CancellationError {
                storage.discard(workspace)
                phase = .cancelled
                throw ScanEngineError.cancelled
            }
            storage.discard(workspace)
            phase = .failed(message: error.localizedDescription)
            throw error
        }
    }

    func cancel() {
        // A finished or failed run is terminal: cancelling now would clobber
        // the outcome phase (and, on the done branch, discard a workspace
        // that finish() has already committed).
        guard !phase.isTerminal else { return }
        isCancelled = true
        // Abort the in-flight finish(): without this, cancelling during
        // reconstruction only set the flag and let the solver burn CPU/GPU to
        // completion. The reconstructor's task-cancellation handler turns this
        // into session.cancel().
        finishTask?.cancel()
        // During reconstruction the solver still owns the workspace directory;
        // deleting it now would corrupt the in-flight session. finishImpl()
        // observes the cancellation at its next await boundary, discards the
        // workspace, and leaves the phase cancelled.
        phase = .cancelled
    }

    // MARK: - Staging

    /// Copies stills (or extracts them from a video) into the workspace's
    /// images directory, normalized to `shot_%06d.<ext>` in a stable order —
    /// the solver is promised `.sequential` ordering, and directory
    /// enumeration order is not a promise.
    private func stageImages(into workspace: ScanWorkspace) async throws -> Int {
        var stills: [URL] = []
        var videos: [URL] = []
        for url in importURLs {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: url.path(percentEncoded: false), isDirectory: &isDir)
            else { continue }
            if isDir.boolValue {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil)) ?? []
                for item in contents where !item.lastPathComponent.hasPrefix(".") {
                    classify(item, stills: &stills, videos: &videos)
                }
            } else {
                classify(url, stills: &stills, videos: &videos)
            }
        }

        stills.sort { $0.lastPathComponent < $1.lastPathComponent }
        var written = 0
        for still in stills {
            try Task.checkCancellation()
            let dest = workspace.imagesURL.appending(path: String(
                format: "shot_%06d.%@", written + 1,
                still.pathExtension.lowercased()))
            try copyItemIfNeeded(still, to: dest)
            written += 1
        }

        // A video is an alternative to stills, not an addition: take the first
        // one and pull sharp frames out of it.
        if written == 0, let video = videos.first {
            written = try await extractFrames(
                from: video, into: workspace.imagesURL, count: videoFrameCount)
        }
        return written
    }

    private func classify(_ url: URL, stills: inout [URL], videos: inout [URL]) {
        let ext = url.pathExtension.lowercased()
        if Self.sourceImageExtensions.contains(ext) {
            stills.append(url)
        } else if Self.sourceVideoExtensions.contains(ext) {
            videos.append(url)
        }
    }

    private func copyItemIfNeeded(_ src: URL, to dest: URL) throws {
        // The workspace is fresh, so the destination never exists — but a
        // security-scoped read of the source can still fail; surface it.
        do {
            try FileManager.default.copyItem(at: src, to: dest)
        } catch {
            Self.logger.error(
                "Couldn't stage \(src.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Video frame extraction

    /// Pulls `count` sharp stills spread across the video: for each time slot
    /// several candidates are decoded and the sharpest (Laplacian variance via
    /// `SharpnessMeter`) wins. No yaw analysis — a Mac-side video has no
    /// turntable telemetry, so even time spread is the honest placement.
    private func extractFrames(
        from videoURL: URL,
        into imagesURL: URL,
        count: Int
    ) async throws -> Int {
        let accessing = videoURL.startAccessingSecurityScopedResource()
        defer { if accessing { videoURL.stopAccessingSecurityScopedResource() } }

        let asset = AVURLAsset(url: videoURL)
        let seconds = asset.duration.seconds
        guard seconds.isFinite, seconds > 1 else {
            throw ScanEngineError.reconstructionFailed(String(
                localized: "Couldn't read that video's duration."))
        }

        let generator = AVAssetImageGenerator(asset: asset)
        // Applies the track's orientation so portrait video comes out upright.
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter =
            CMTime(seconds: 0.25, preferredTimescale: 600)

        var written = 0
        for i in 0..<count {
            try Task.checkCancellation()
            phase = .processingVideo(VideoProcessingProgress(
                fraction: Double(i) / Double(count),
                stage: String(localized: "Extracting sharp frames")))
            var best: (CGImage, Float)?
            for attempt in 0..<3 {
                let slot = (Double(i) + 0.5) / Double(count)
                let jitter = (Double(attempt) - 1.0) * (0.5 / Double(count)) * 0.3
                let t = min(max(slot + jitter, 0), 0.999) * seconds
                let time = CMTime(seconds: t, preferredTimescale: 600)
                guard let image = try? generator.copyCGImage(
                    at: time, actualTime: nil),
                    let buffer = Self.pixelBuffer(from: image),
                    let score = SharpnessMeter.score(buffer)
                else { continue }
                if best == nil || score > best!.1 { best = (image, score) }
            }
            if let (image, _) = best {
                let dest = imagesURL.appending(
                    path: String(format: "shot_%06d.jpg", written + 1))
                try Self.writeJPEG(image, to: dest)
                written += 1
            }
        }
        phase = .processingVideo(VideoProcessingProgress(
            fraction: 1, stage: String(localized: "Extracting sharp frames")))
        return written
    }

    private static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            throw ScanEngineError.reconstructionFailed(String(
                localized: "Couldn't write an extracted frame."))
        }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality as String: 0.92,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ScanEngineError.reconstructionFailed(String(
                localized: "Couldn't write an extracted frame."))
        }
    }

    private static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "d MMM HH:mm"
        return String(
            localized: "\(Self.kind.displayName) scan \(formatter.string(from: date))")
    }
}
