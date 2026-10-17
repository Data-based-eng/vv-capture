import AVFoundation
import Foundation
import Observation
import os

/// Photogrammetry with the device held still and the object rotating.
///
/// `ObjectCaptureSession` cannot do this: its guided flow is built on ARKit world
/// tracking, so a fixed device reads as "never moved" and the bounding box drifts
/// off a turning object. `PhotogrammetrySession` has no such dependency — it
/// solves poses from the images themselves, and a turntable is geometrically
/// equivalent to orbiting the camera.
@MainActor
@Observable
final class TurntableCaptureEngine: ScanEngine {
    private static let logger = Logger(subsystem: "com.visionvend.capture", category: "turntable")

    static let kind: ScanEngineKind = .turntable

    static var availability: EngineAvailability {
        guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil else {
            return .unsupportedDevice(reason: String(localized: "Rear camera not found."))
        }
        guard DeviceCapabilities.supportsPhotogrammetry else {
            return .unsupportedDevice(reason: String(localized: "This device doesn't support on-device photogrammetry."))
        }
        return .available
    }

    /// Fewer than this and the solver has too little overlap to close a loop.
    ///
    /// Raised from 20 after measuring a real pass: 20 shots spread over a full
    /// revolution is 18° between frames, which is at the edge of what feature
    /// matching survives. A full turn at ~11° is the honest floor.
    static let minimumShots = 32

    /// Shots that make up roughly one revolution at the recommended ~10° step.
    /// Used only to prompt for a second pass at a different height.
    static let shotsPerRevolution = 36

    /// Views extracted from one video take (7.5° apart).
    static let videoViews = 48

    /// Nominal seconds per turntable revolution, used only when the rim marker
    /// can't be measured in the footage. The turntable app's speed setting is
    /// the source of truth — match this to it.
    var videoRevSeconds: Double = 60

    /// Turntable speed in revolutions per minute, when known. The auto-capture
    /// interval is derived from it so shots land ~10° apart at any speed.
    /// Nil means unknown — the yaw manifest's timestamps let \u03b8 backfill
    /// later once the RPM is measured.
    var turntableRPM: Double?

    /// Seconds between automatic shots. RPM-derived when the turntable speed is
    /// known, otherwise the 2.0 s default (~10° per shot at a comfortable hand speed).
    var autoCaptureInterval: TimeInterval {
        guard let rpm = turntableRPM, rpm > 0 else { return 2.0 }
        return 60.0 / (rpm * Double(Self.shotsPerRevolution))
    }

    /// True once a full revolution's worth of frames exists at one height.
    ///
    /// A single ring of camera positions has almost no vertical parallax, which is
    /// the main reason a tripod pass loses to a hand-held orbit — a walking person
    /// varies elevation without thinking about it. Prompting for the second pass is
    /// the cheapest fix available.
    var shouldChangeElevation: Bool {
        shotCount >= Self.shotsPerRevolution
    }

    // MARK: - Observable state

    private(set) var phase: ScanPhase = .idle
    private(set) var shotCount = 0
    /// Saved shot indices in capture order. Drives the coverage overlay: the
    /// index (not the count) sets each notch's nominal angle, so blur-rejected
    /// gaps don't shift the ring.
    private(set) var capturedShotIndices: [Int] = []
    private(set) var isAutoCapturing = false
    private(set) var deliversDepth = false
    private(set) var megapixels = 0
    private(set) var captureError: String?
    private(set) var isLocked = false
    /// Distinguishes "not tried yet" from "tried and the device refused".
    private(set) var lockState: LockState = .unlocked
    /// Non-fatal notes from reconstruction, e.g. masking being skipped.
    private(set) var warnings: [String] = []

    enum LockState: Equatable {
        case unlocked
        case locking
        case locked
        case failed
    }
    private(set) var rejectedShots = 0
    private(set) var lastRejectionReason: String?
    /// True while the turntable video take is recording. The photo session is
    /// parked for the duration — AVFoundation runs one session per camera.
    private(set) var isRecordingVideo = false
    /// Workspace video file once a take finalises.
    private(set) var recordedVideoURL: URL?

    /// Region of every frame that contains the object, in 0…1 image coordinates.
    ///
    /// Valid only because the device is stationary: the object sits in the same part
    /// of every frame, so one rectangle masks the whole set. This is what keeps a
    /// close or textured background out of the model.
    var objectMaskRect: CGRect?

    var session: AVCaptureSession? { coordinator?.session }

    /// Stills need enough frames to close the loop. A finished video take is
    /// processed into `videoViews` views, which always suffices.
    var canFinish: Bool { shotCount >= Self.minimumShots || recordedVideoURL != nil }

    // MARK: - Private

    private let storage: ScanStorage
    private let reconstructor = PhotogrammetryReconstructor()
    private var coordinator: PhotoCaptureCoordinator?
    private var videoCoordinator: VideoCaptureCoordinator?
    private var workspace: ScanWorkspace?
    private var yawManifest: YawManifest?
    private var autoCaptureTask: Task<Void, Never>?
    /// The detached video processing task, so `cancel()` can stop it mid-run.
    private var videoProcessTask: Task<VideoProcessResult, Error>?
    /// Set by `cancel()`. `finish()` checks it at every await boundary so a
    /// cancel that lands mid-reconstruction produces `.cancelled` — never a
    /// `.failed` for a workspace that was deliberately discarded, and never a
    /// committed record for one.
    private var isCancelled = false

    init(storage: ScanStorage) {
        self.storage = storage
    }

    // MARK: - ScanEngine

    func start() async throws {
        // C1: the camera permission prompt must fire before any session is
        // created. Without this, a fresh install starts a black preview and
        // every capture tap silently no-ops. The denial message surfaces in
        // the view's startupError via the thrown error below, and no engine
        // state or capture session is created.
        guard await CameraPermission.ensureVideoAccess() else {
            let message = CameraPermission.denialMessage
            phase = .failed(message: message)
            throw ScanEngineError.sessionUnavailable(message)
        }
        resetSessionState()

        guard Self.availability.isUsable else {
            throw ScanEngineError.sessionUnavailable(Self.availability.blockedReason ?? String(localized: "Unknown reason"))
        }

        phase = .preparing

        let workspace: ScanWorkspace
        do {
            workspace = try storage.makeWorkspace()
        } catch {
            phase = .failed(message: error.localizedDescription)
            throw ScanEngineError.sessionUnavailable(error.localizedDescription)
        }
        self.workspace = workspace
        self.yawManifest = YawManifest(directory: workspace.root)

        let coordinator = PhotoCaptureCoordinator(
            imagesDirectory: workspace.imagesURL,
            onShotSaved: { [weak self] index, takenAt, sharpness in
                Task { @MainActor in self?.shotSaved(index, takenAt: takenAt, sharpness: sharpness) }
            },
            onShotRejected: { [weak self] reason in
                Task { @MainActor in
                    self?.rejectedShots += 1
                    self?.lastRejectionReason = reason
                }
            },
            onFailure: { [weak self] message in
                Task { @MainActor in self?.captureError = message }
            }
        )

        do {
            try coordinator.configure()
        } catch {
            storage.discard(workspace)
            self.workspace = nil
            self.yawManifest = nil
            phase = .failed(message: error.localizedDescription)
            throw ScanEngineError.sessionUnavailable(error.localizedDescription)
        }

        self.coordinator = coordinator
        deliversDepth = coordinator.deliversDepth
        megapixels = coordinator.megapixels
        coordinator.start()

        // Video runs on its own session because AVFoundation allows only one
        // running session per camera. A video failure must not fail capture:
        // stills keep working.
        let video = VideoCaptureCoordinator(
            videoURL: workspace.videoURL,
            onFinishedRecording: { [weak self] url in
                Task { @MainActor in self?.recordedVideoURL = url }
            },
            onFailure: { [weak self] message in
                Task { @MainActor in self?.captureError = message }
            }
        )
        do {
            try video.configure()
            self.videoCoordinator = video
        } catch {
            warnings.append(String(localized: "Video capture unavailable: \(error.localizedDescription)"))
            Self.logger.error("Video coordinator configuration failed: \(error.localizedDescription, privacy: .public)")
        }

        phase = .capturing(shots: 0)
    }

    func finish() async throws -> ScanRecord {
        // finish() after cancel() must report cancellation, not "No active
        // session": cancel() may already have torn the session down.
        guard !isCancelled else { throw ScanEngineError.cancelled }
        guard let coordinator, let workspace else {
            throw ScanEngineError.sessionUnavailable(String(localized: "No active session."))
        }

        stopAutoCapture()
        coordinator.stop()

        // A recording left running would keep writing while the solver reads
        // the workspace. Stop it and wait for the file to finalise first.
        //
        // M17: the stills session stays parked and the video session is
        // stopped outright here — the two heaviest phases (video processing,
        // reconstruction) don't need the camera, and it competes with
        // compute for power/thermal headroom. Apple: "call stopRunning() at
        // the earliest opportunity."
        if isRecordingVideo {
            stopVideoRecording(restartStills: false)
            // M16: awaitFinalized() hands the URL back directly instead of
            // assigning it across a MainActor hop (which could land after
            // this await, silently dropping the take so the model built from
            // stills with no warning).
            if let finalizedURL = await videoCoordinator?.awaitFinalized() {
                recordedVideoURL = finalizedURL
            } else {
                warnings.append(String(localized: "The video take didn't finalise; the model will be built from stills only."))
                Self.logger.warning("Video take dropped: awaitFinalized() returned nil; building from stills.")
            }
            videoCoordinator?.stop()
        }

        // A photo whose delegate hasn't fired yet must not land after the
        // reconstruction input was enumerated — or after teardown, with no yaw
        // entry at all. Wait for the in-flight captures first.
        await coordinator.drainPendingCaptures()

        // A cancel may have landed while draining, and a second finish must not
        // reconstruct twice.
        guard !isCancelled, case .capturing = phase else {
            throw ScanEngineError.cancelled
        }

        // Video take → measured yaw + sharp frames straight into the images
        // directory. The reconstructor below then treats them exactly like
        // stills, and the yaw manifest carries their angles.
        var videoFrameCount = 0
        if let videoURL = recordedVideoURL, let manifest = yawManifest {
            phase = .processingVideo(VideoProcessingProgress(stage: String(localized: "Measuring rotation")))
            // Read the MainActor-isolated settings before detaching: the
            // detached closure can't touch engine state.
            let nominalRevSeconds = videoRevSeconds
            // Video frames continue the stills' numbering so the images
            // directory sorts in capture order and yaw-manifest `shot`
            // indices stay unique. Gaps from blur-rejected shots are fine —
            // what matters is no overlap.
            let firstVideoShotIndex = (capturedShotIndices.max() ?? 0) + 1
            do {
                let processTask = Task.detached {
                    try await VideoPipeline.process(
                        videoURL: videoURL,
                        imagesURL: workspace.imagesURL,
                        manifest: manifest,
                        nominalRevSeconds: nominalRevSeconds,
                        views: Self.videoViews,
                        firstShotIndex: firstVideoShotIndex
                    ) { [weak self] progress in
                        Task { @MainActor in
                            guard let self, case .processingVideo = self.phase else { return }
                            self.phase = .processingVideo(progress)
                        }
                    }
                }
                videoProcessTask = processTask
                let result = try await processTask.value
                videoProcessTask = nil
                videoFrameCount = result.frameCount
                if let warning = result.warning { warnings.append(warning) }
            } catch {
                videoProcessTask = nil
                if error is CancellationError || isCancelled {
                    storage.discard(workspace)
                    teardown()
                    self.workspace = nil
                    phase = .cancelled
                    throw ScanEngineError.cancelled
                }
                // M18: a failed attempt strands GB-scale 4K video plus
                // extracted frames. The OS gives no guarantee of ever
                // sweeping tmp/, so discard the workspace explicitly, like
                // the cancel path does.
                storage.discard(workspace)
                teardown()
                self.workspace = nil
                phase = .failed(message: error.localizedDescription)
                throw error
            }
        }

        // A cancel may have landed during video processing.
        guard !isCancelled else {
            storage.discard(workspace)
            teardown()
            phase = .cancelled
            throw ScanEngineError.cancelled
        }

        guard shotCount + videoFrameCount > 0 else {
            phase = .failed(message: String(localized: "No photos were taken."))
            throw ScanEngineError.noImagesCaptured
        }

        let capturedShots = shotCount + videoFrameCount
        phase = .reconstructing(ReconstructionProgress())

        let output: PhotogrammetryReconstructor.Output
        do {
            output = try await reconstructor.reconstruct(
                workspace: workspace,
                detail: .reduced,
                maskRect: objectMaskRect,
                onWarning: { [weak self] note in
                    self?.warnings.append(note)
                }
            ) { [weak self] progress in
                self?.phase = .reconstructing(progress)
            }
        } catch {
            // A cancel that lands mid-reconstruction must win over the failure:
            // the workspace is being discarded, so staying cancelled and
            // committing nothing is the only consistent outcome.
            if isCancelled {
                storage.discard(workspace)
                teardown()
                phase = .cancelled
                throw ScanEngineError.cancelled
            }
            phase = .failed(message: error.localizedDescription)
            throw error
        }

        if isCancelled {
            storage.discard(workspace)
            teardown()
            phase = .cancelled
            throw ScanEngineError.cancelled
        }

        // Appended after the reconstruction warnings so the result screen reads
        // worst-first: what broke, then why the geometry looks the way it does.
        if let poses = output.poses {
            warnings.append(contentsOf: poses.advice)
        }

        let record = ScanRecord(
            id: workspace.id,
            name: Self.defaultName(for: Date()),
            engine: Self.kind,
            // Scale comes from the depth embedded in each still. Without a LiDAR
            // device there is none, and claiming real dimensions would be a lie.
            isMetricallyScaled: deliversDepth,
            imageCount: capturedShots,
            detail: .reduced,
            summary: output.poses?.summaryText
        )
        try storage.commit(record, workspace: workspace)

        teardown()
        phase = .done(record)
        return record
    }

    func cancel() {
        // A finished or failed scan is terminal: cancelling now would clobber
        // the outcome phase (and, on the capturing branch below, discard a
        // workspace that finish() has already committed).
        guard !phase.isTerminal else { return }
        isCancelled = true
        stopAutoCapture()
        coordinator?.stop()
        if isRecordingVideo {
            isRecordingVideo = false
            videoCoordinator?.stopRecording()
        }
        videoCoordinator?.stop()
        // A detached processing task keeps no reference to the engine, so it
        // must be stopped explicitly — otherwise it would keep writing frames
        // into a workspace finish() has already discarded.
        videoProcessTask?.cancel()
        // During reconstruction the solver still owns the workspace directory;
        // deleting it now would corrupt the in-flight session. finish()
        // observes isCancelled at its next await boundary, discards the
        // workspace, and leaves the phase cancelled.
        if case .capturing = phase {
            teardown()
            if let workspace {
                storage.discard(workspace)
                self.workspace = nil
            }
        }
        phase = .cancelled
    }

    // MARK: - Capture control

    /// Freezes focus, exposure and white balance. Called before the first shot
    /// rather than left on automatic: drifting between frames is what breaks the
    /// solve, and a turntable holds the subject at a fixed distance anyway.
    func lockCameraSettings() {
        // Locking the stills device mid-recording would move exposure under the
        // video take. The video path locks its own device when recording starts.
        guard lockState != .locking, !isRecordingVideo else { return }
        lockState = .locking
        coordinator?.lockCameraSettings { [weak self] success in
            Task { @MainActor in
                self?.isLocked = success
                self?.lockState = success ? .locked : .failed
            }
        }
    }

    func captureNow() {
        guard case .capturing = phase, !isRecordingVideo else { return }
        coordinator?.capture()
    }

    func toggleAutoCapture() {
        guard case .capturing = phase, !isRecordingVideo else { return }
        isAutoCapturing ? stopAutoCapture() : startAutoCapture()
    }

    private func startAutoCapture() {
        guard coordinator != nil else { return }
        // Locking first, not per-shot: the whole point is that nothing changes
        // between frames.
        if !isLocked { lockCameraSettings() }
        isAutoCapturing = true
        autoCaptureTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isAutoCapturing else { return }
                self.coordinator?.capture()
                try? await Task.sleep(for: .seconds(self.autoCaptureInterval))
            }
        }
    }

    private func stopAutoCapture() {
        isAutoCapturing = false
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
    }

    // MARK: - Video

    /// Toggles the turntable video take. The photo session is parked while the
    /// video session owns the camera, and restarted afterwards — AVFoundation
    /// runs one session per physical device.
    func toggleVideoRecording() {
        guard case .capturing = phase else { return }
        isRecordingVideo ? stopVideoRecording() : startVideoRecording()
    }

    private func startVideoRecording() {
        guard let video = videoCoordinator, !isRecordingVideo else { return }
        // A previous take's URL must not survive into a new recording:
        // canFinish() reads it, and a stale URL would let finish() reach
        // for a discarded file.
        recordedVideoURL = nil
        stopAutoCapture()
        // Synchronous: the video session must not startRunning() while the
        // photo session is still stopping on the same device.
        coordinator?.stopSync()
        isRecordingVideo = true
        // Lock on the video device, then roll. A failed lock still records —
        // unlocked footage beats no footage.
        video.lockCameraSettings { [weak video] _ in
            video?.startRecording()
        }
    }

    private func stopVideoRecording(restartStills: Bool = true) {
        guard isRecordingVideo else { return }
        isRecordingVideo = false
        videoCoordinator?.stopRecording()
        // Hand the camera back to the stills session; the movie file finalises
        // in the background and reports via onFinishedRecording.
        //
        // M17: finish() passes restartStills: false — restarting the session
        // right before video processing + reconstruction would hold the
        // camera open through the two heaviest phases, burning the
        // power/thermal headroom the solver needs.
        if restartStills {
            coordinator?.start()
        }
    }

    // MARK: - Private

    private func shotSaved(_ index: Int, takenAt: Date, sharpness: Float?) {
        // Count saved shots, not the shot index: blur rejections leave gaps in
        // the numbering, and tracking the index overstated the photo count, the
        // finish threshold, and the saved record's image count by the number of
        // rejections. The index still names the file and the yaw entry.
        shotCount += 1
        capturedShotIndices.append(index)
        captureError = nil
        // \u03b8 itself is filled by the yaw estimator (ArUco marker on the
        // turntable edge). Until then the timestamp is the source of truth —
        // \u03b8 backfills as \u03c9\u00b7\u0394t once the RPM is known.
        yawManifest?.append(
            shot: index,
            file: coordinator?.fileName(forShot: index) ?? String(format: "shot_%06d.heic", index),
            takenAt: takenAt,
            thetaDeg: nil,
            method: "timestamp",
            sharpness: sharpness
        )
        if case .capturing = phase {
            phase = .capturing(shots: shotCount)
        }
    }

    /// Clears per-session state so a second scan on a reused engine starts
    /// clean. Previously start() never reset this — latent, since engines
    /// are currently one-shot, but a stale recordedVideoURL or shotCount
    /// would corrupt canFinish() and the coverage overlay on reuse.
    ///
    /// objectMaskRect is deliberately left alone: the view owns the drag
    /// rectangle and pushes it into the engine during capture.
    private func resetSessionState() {
        shotCount = 0
        capturedShotIndices = []
        isAutoCapturing = false
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        videoProcessTask?.cancel()
        videoProcessTask = nil
        isCancelled = false
        isRecordingVideo = false
        recordedVideoURL = nil
        captureError = nil
        rejectedShots = 0
        lastRejectionReason = nil
        isLocked = false
        lockState = .unlocked
        warnings = []
    }

    private func teardown() {
        stopAutoCapture()
        isRecordingVideo = false
        // Stop the stills session before dropping the coordinator: without
        // this the capture indicator can linger after a successful scan.
        coordinator?.stop()
        coordinator = nil
        videoCoordinator?.stop()
        videoCoordinator = nil
        videoProcessTask?.cancel()
        videoProcessTask = nil
        yawManifest = nil
        captureError = nil
    }

    private static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "d MMM HH:mm"
        return String(localized: "\(Self.kind.displayName) scan \(formatter.string(from: date))")
    }
}
