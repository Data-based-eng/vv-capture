import Foundation
import RealityKit
import os

/// Wraps `PhotogrammetrySession`: a directory of stills in, a USDZ out.
///
/// Runs entirely on device. It is CPU/GPU heavy and iOS will suspend it if the
/// app is backgrounded, which is why the caller keeps the screen awake and the
/// checkpoint directory is on disk.
struct PhotogrammetryReconstructor {
    private static let logger = Logger(subsystem: "com.visionvend.capture", category: "photogrammetry")

    /// The model plus what the solver had to say about the input that produced it.
    struct Output {
        let modelURL: URL
        /// Nil when the poses request was unavailable or failed — it is a
        /// diagnostic, never a requirement.
        let poses: PoseDiagnostics?
    }

    /// PhotogrammetrySession isn't Sendable, but this helper's lifecycle keeps
    /// it confined: created here, consumed by the outputs loop below, and only
    /// `cancel()` crosses into the `@Sendable` onCancel closure. The box
    /// documents that manual guarantee.
    private final class UncheckedSessionBox: @unchecked Sendable {
        let session: PhotogrammetrySession
        init(_ session: PhotogrammetrySession) { self.session = session }
    }

    /// Extensions the solver can actually ingest. The images directory must
    /// contain only solver inputs: dotfile-exclusion alone let any stray file
    /// (a renamed video, an export dropped in by mistake) reach the session.
    private static let sourceImageExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png"]

    private static func isSourceImage(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return !name.hasPrefix(".") && sourceImageExtensions.contains(url.pathExtension.lowercased())
    }

    /// - Parameters:
    ///   - maskRect: region of every frame that contains the object, in
    ///     NORMALIZED UPRIGHT-PORTRAIT image space (origin top-left, 0…1), the
    ///     same space as the EXIF-upright portrait buffers
    ///     `PhotogrammetrySample(contentsOf:)` hands back.
    ///     Cross-file contract: the capture UI derotates the drag rect before it
    ///     gets here, so `MaskedSampleSequence`/`ObjectMaskBuilder` stamp it
    ///     WITHOUT any additional rotation. Do not derotate here — the
    ///     sensor-native landscape space never reaches this layer.
    ///     Only meaningful when the device was stationary — see
    ///     `MaskedSampleSequence`. Nil feeds the images as a plain (still
    ///     sorted) sample sequence and lets the session work out the object
    ///     itself.
    ///   - enableObjectMasking: lets the session segment a single subject out of
    ///     each frame. Right for an object on a table, actively wrong for a room —
    ///     there the room *is* the subject, and asking for an object gets part of it
    ///     cut away.
    ///   - framing: whether the cameras surrounded the subject or stood inside it.
    ///     Decides which pose measurements are meaningful.
    ///   - onWarning: non-fatal problems worth telling the user about, such as
    ///     masking being unavailable.
    ///   - onProgress: merged progress, always delivered on the main actor.
    func reconstruct(
        workspace: ScanWorkspace,
        detail: ReconstructionDetail,
        maskRect: CGRect? = nil,
        enableObjectMasking: Bool = true,
        framing: PoseDiagnostics.Framing = .orbit,
        onWarning: @escaping @MainActor (String) -> Void = { _ in },
        onProgress: @escaping @MainActor (ReconstructionProgress) -> Void
    ) async throws -> Output {

        // Fail fast: don't probe files and spin up a GPU session for a task
        // that's already been cancelled.
        try Task.checkCancellation()

        guard PhotogrammetrySession.isSupported else {
            throw ScanEngineError.reconstructionFailed(String(localized: "This device doesn't support on-device photogrammetry."))
        }

        let imageURLs = ((try? FileManager.default.contentsOfDirectory(
            at: workspace.imagesURL,
            includingPropertiesForKeys: nil
        )) ?? [])
            .filter { Self.isSourceImage($0) }
            // Capture order is the orbit order, which is what `.sequential` promises
            // the solver — directory enumeration order is not.
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let imageCount = imageURLs.count
        guard imageCount > 0 else { throw ScanEngineError.noImagesCaptured }

        var configuration = PhotogrammetrySession.Configuration(checkpointDirectory: workspace.checkpointURL)
        // Guided capture and turntable capture both write images in orbit order,
        // which spares the solver an all-pairs matching search.
        configuration.sampleOrdering = .sequential
        configuration.featureSensitivity = .high
        configuration.isObjectMaskingEnabled = enableObjectMasking

        // Remove a stale model from a previous attempt; the session refuses to
        // overwrite and the error it throws is opaque.
        try? FileManager.default.removeItem(at: workspace.modelURL)

        // Probe one file before committing to the sample path. `PhotogrammetrySample`
        // does not necessarily read every HEIC we produce, and an earlier version
        // swallowed those failures with `try?` — leaving an empty sequence and an
        // opaque session error. Better to find out on one file than on eighty.
        var effectiveMask = maskRect
        if maskRect != nil, let probe = imageURLs.first {
            do {
                _ = try await PhotogrammetrySample(contentsOf: probe)
            } catch {
                effectiveMask = nil
                Self.logger.error("Couldn't read sample, mask disabled: \(error.localizedDescription, privacy: .public)")
                await onWarning(String(localized: "Couldn't apply mask, background included: \(error.localizedDescription)"))
            }
        }

        do {
            return try await run(
                workspace: workspace,
                imageURLs: imageURLs,
                imageCount: imageCount,
                detail: detail,
                maskRect: effectiveMask,
                configuration: configuration,
                framing: framing,
                onProgress: onProgress
            )
        } catch let establishment as MaskEstablishmentError {
            // The masked path failed at establishment time — before the solver
            // had a chance to run — which is the only failure an unmasked retry
            // can plausibly fix. A failure *during* the solve would fail the
            // same way unmasked, so it is not retried: retrying would burn
            // another multi-minute run for nothing.
            // `underlying` is always the mapped ScanEngineError here — never the
            // raw CancellationError — so a cancelled task has to be detected via
            // the task itself. Without this, cancelling during masked setup
            // would burn a second session just to be cancelled again, and show
            // a misleading "retried without mask" warning first.
            try Task.checkCancellation()
            Self.logger.error("Masked run rejected at setup, retrying unmasked: \(establishment.underlying.localizedDescription, privacy: .public)")
            await onWarning(String(localized: "Masked processing failed, retried without mask."))
            try? FileManager.default.removeItem(at: workspace.modelURL)
            return try await run(
                workspace: workspace,
                imageURLs: imageURLs,
                imageCount: imageCount,
                detail: detail,
                maskRect: nil,
                configuration: configuration,
                framing: framing,
                onProgress: onProgress
            )
        }
    }

    /// The masked sample path failed before the solver started. Carried
    /// separately from `ScanEngineError` so `reconstruct()` can tell "the mask
    /// setup was rejected" (retry unmasked) from "the solve itself failed"
    /// (surface the error).
    private struct MaskEstablishmentError: Error {
        let underlying: Error
    }

    private func run(
        workspace: ScanWorkspace,
        imageURLs: [URL],
        imageCount: Int,
        detail: ReconstructionDetail,
        maskRect: CGRect?,
        configuration: PhotogrammetrySession.Configuration,
        framing: PoseDiagnostics.Framing,
        onProgress: @escaping @MainActor (ReconstructionProgress) -> Void
    ) async throws -> Output {

        let masked = maskRect != nil
        let session: PhotogrammetrySession
        do {
            // Masked and unmasked both go through the sorted sample sequence,
            // so both get deterministic order. The old unmasked path passed the
            // raw folder URL, which made the lexicographic sort above dead code
            // and let `.sequential` rest on OS enumeration order.
            session = try PhotogrammetrySession(
                input: MaskedSampleSequence(imageURLs: imageURLs, normalizedRect: maskRect),
                configuration: configuration
            )
        } catch {
            let mapped = ScanEngineError.reconstructionFailed(error.localizedDescription)
            if masked { throw MaskEstablishmentError(underlying: mapped) }
            throw mapped
        }

        let modelRequest = PhotogrammetrySession.Request.modelFile(
            url: workspace.modelURL,
            detail: detail.apiDetail
        )
        // The poses request rides along on alignment work the session already does,
        // so it costs almost nothing and turns "bad quality" into three numbers.
        do {
            try session.process(requests: [modelRequest, .poses])
        } catch {
            // `process()` throws are establishment-time too — the session never
            // started solving.
            let mapped = ScanEngineError.reconstructionFailed(error.localizedDescription)
            if masked { throw MaskEstablishmentError(underlying: mapped) }
            throw mapped
        }

        // Fraction and stage arrive on two different outputs and interleave, so
        // both are accumulated here and emitted as one value.
        var progress = ReconstructionProgress()
        var diagnostics: PoseDiagnostics?

        // Cancelling the Swift Task alone does NOTHING to PhotogrammetrySession:
        // the GPU pipeline keeps running until `session.cancel()` is called.
        // `cancel()` is asynchronous — it only *requests* the stop, and is a
        // no-op if the session isn't processing — so this function does not
        // return (and no new session is started) until the outputs stream
        // delivers `.processingCancelled`, which the loop below converts to
        // `ScanEngineError.cancelled`.
        // Box the session for the @Sendable onCancel closure (see
        // UncheckedSessionBox): the outputs loop above uses `session` directly.
        let sessionBox = UncheckedSessionBox(session)
        // The operation closure must return on every path: if the outputs
        // stream ends without `.processingComplete`, trust the file system
        // rather than guessing.
        return try await withTaskCancellationHandler {
            for try await output in session.outputs {
                switch output {
                case .requestProgress(let request, let fraction):
                    // Two requests report progress independently; showing both would
                    // make the bar jump backwards.
                    guard request == modelRequest else { break }
                    progress.fraction = fraction
                    await onProgress(progress)

                case .requestProgressInfo(let request, let info):
                    guard request == modelRequest else { break }
                    progress.stage = info.processingStage.flatMap(ReconstructionStage.init)
                    progress.estimatedRemaining = info.estimatedRemainingTime
                    await onProgress(progress)

                case .requestComplete(let request, let result):
                    if case .poses(let poses) = result {
                        diagnostics = PoseDiagnostics(poses: poses, totalSamples: imageCount, framing: framing)
                    }
                    guard request == modelRequest else { break }
                    progress.fraction = 1
                    await onProgress(progress)

                case .processingComplete:
                    Self.logger.info("Reconstruction complete: \(imageCount, privacy: .public) images")
                    if let diagnostics {
                        Self.logger.info("Pose diagnostics: \(diagnostics.summaryText, privacy: .public)")
                    }
                    return Output(modelURL: workspace.modelURL, poses: diagnostics)

                case .requestError(let request, let error):
                    // A failed poses request must not cost the user their model.
                    guard request == modelRequest else {
                        Self.logger.error("Pose request failed: \(error.localizedDescription, privacy: .public)")
                        break
                    }
                    // The session is still alive here: without an explicit
                    // cancel the GPU pipeline keeps running after we throw
                    // (only task cancellation reaches the onCancel handler).
                    session.cancel()
                    throw ScanEngineError.reconstructionFailed(error.localizedDescription)

                case .processingCancelled:
                    throw ScanEngineError.cancelled

                case .invalidSample(let id, let reason):
                    Self.logger.debug("Invalid sample \(id, privacy: .public): \(reason, privacy: .public)")

                case .skippedSample, .automaticDownsampling, .inputComplete, .stitchingIncomplete:
                    break

                @unknown default:
                    break
                }
            }
            guard FileManager.default.fileExists(atPath: workspace.modelURL.path(percentEncoded: false)) else {
                // The outputs stream ended without a terminal state; make sure
                // the session isn't still running before we throw.
                session.cancel()
                throw ScanEngineError.reconstructionFailed(String(localized: "Session ended without producing a model."))
            }
            return Output(modelURL: workspace.modelURL, poses: diagnostics)
        } onCancel: {
            sessionBox.session.cancel()
        }
    }
}

private extension ReconstructionDetail {
    /// See `ReconstructionDetail`: iOS declares only `.reduced`.
    var apiDetail: PhotogrammetrySession.Request.Detail {
        switch self {
        case .reduced: .reduced
#if os(macOS)
        case .medium: .medium
        case .full: .full
        case .raw: .raw
#endif
        }
    }
}

private extension ReconstructionStage {
    init?(_ stage: PhotogrammetrySession.Output.ProcessingStage) {
        switch stage {
        case .preProcessing: self = .preProcessing
        case .imageAlignment: self = .imageAlignment
        case .pointCloudGeneration: self = .pointCloudGeneration
        case .meshGeneration: self = .meshGeneration
        case .textureMapping: self = .textureMapping
        case .optimization: self = .optimization
        @unknown default: return nil
        }
    }
}
