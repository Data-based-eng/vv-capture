import AVFoundation
import CoreMotion
import Foundation
import Observation
import os

/// Photogrammetry with the product fixed and the phone walked around it.
///
/// No turntable, so there is no rotation to measure: the take is one locked-
/// exposure video, and the finish pipeline extracts sharp frames spread across
/// time. Camera poses come from the photogrammetry solver, not from a yaw
/// estimator — the yaw manifest entries for orbit frames carry no angle.
///
/// Coverage guidance comes from the gyro: `deviceMotion.attitude.yaw` is
/// tracked relative to the recording start and binned into 5° sectors, so the
/// UI ring fills as the user sweeps around the product. No location permission
/// needed, and a minute of gyro drift is a couple of degrees — fine for
/// guidance. (On the simulator motion is unavailable and the ring stays empty;
// finish still works.)
///
/// Camera access is gated on `CameraPermission.ensureVideoAccess()` at the top
/// of `start()`: a fresh install that denies (or never grants) camera access
/// fails fast with a routed error instead of sitting on a black preview.
@MainActor
@Observable
final class OrbitCaptureEngine: ScanEngine {
    private static let logger = Logger(subsystem: "com.visionvend.capture", category: "orbit")

    static let kind: ScanEngineKind = .orbit

    static var availability: EngineAvailability {
        guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil else {
            return .unsupportedDevice(reason: String(localized: "Rear camera not found."))
        }
        guard DeviceCapabilities.supportsPhotogrammetry else {
            return .unsupportedDevice(reason: String(localized: "This device doesn't support on-device photogrammetry."))
        }
        return .available
    }

    /// Frames pulled from the orbit video, spread across the take.
    static let orbitViews = 48

    /// 5° yaw sectors; a full orbit lights all of them.
    static let yawBinCount = 72

    private(set) var phase: ScanPhase = .idle
    private(set) var isRecordingVideo = false
    private(set) var recordedVideoURL: URL?
    private(set) var warnings: [String] = []
    private(set) var captureError: String?
    private(set) var deliversDepth = false

    /// Yaw sectors the user has swept through since recording started.
    private(set) var coveredYawBins: Set<Int> = []

    var coverageDegrees: Double { Double(coveredYawBins.count) * (360 / Double(Self.yawBinCount)) }
    var isOrbitComplete: Bool { coveredYawBins.count >= Self.yawBinCount }

    var objectMaskRect: CGRect?
    var session: AVCaptureSession? { videoCoordinator?.session }
    var canFinish: Bool { recordedVideoURL != nil }

    private let storage: ScanStorage
    private let reconstructor = PhotogrammetryReconstructor()
    private var videoCoordinator: VideoCaptureCoordinator?
    private var workspace: ScanWorkspace?
    private var yawManifest: YawManifest?
    private var extractTask: Task<Int, Error>?

    private let motionManager = CMMotionManager()
    /// Dedicated serial queue for the 30 Hz motion stream. Serial: concurrent
    /// handlers could interleave yaw samples and corrupt the sector fill.
    /// Dedicated (not main): a stuck main queue would delay callbacks — Apple
    /// recommends a queue of your own for motion data, not the main queue.
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.visionvend.capture.orbit-motion"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var startYaw: Double?
    private var lastYaw: Double?

    private var isCancelled = false
    /// M20 reentrancy guard. Sticky: set once at the top of finish() and never
    /// cleared — a second finish() must not start a second extraction,
    /// reconstruction, or library commit.
    private var isFinishing = false

    init(storage: ScanStorage) {
        self.storage = storage
    }

    /// NOTE: async as of the C1 fix. This no longer satisfies the synchronous
    /// `ScanEngine.start()` requirement — the protocol requirement and the
    /// `try engine.start()` call sites (OrbitFlowView.startIfNeeded) must move
    /// to `await` in the same change (coordinated, outside this file).
    func start() async throws {
        // C1: the OS only prompts once — gate every engine start on an
        // explicit grant, so a fresh install that denies camera access fails
        // fast with a routed error instead of a black preview with dead taps.
        guard await CameraPermission.ensureVideoAccess() else {
            let message = CameraPermission.denialMessage
            captureError = message
            phase = .failed(message: message)
            throw ScanEngineError.sessionUnavailable(message)
        }

        // Minor: refuse a second start while a session is live instead of
        // stacking a new capture session on top of the old one. Terminal
        // phases (.done/.failed/.cancelled) may restart; live phases may not.
        if !phase.isTerminal, phase != .idle {
            throw ScanEngineError.sessionUnavailable("A scan is already in progress.")
        }

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

        let video = VideoCaptureCoordinator(
            videoURL: workspace.videoURL,
            onFinishedRecording: { [weak self] url in
                Task { @MainActor in
                    self?.recordedVideoURL = url
                    self?.isRecordingVideo = false
                    self?.stopMotionTracking()
                }
            },
            onFailure: { [weak self] message in
                Task { @MainActor in
                    guard let self else { return }
                    // M19: a failed take must not leave the UI stuck on
                    // "recording", and must not leave the gyro streaming at
                    // 30 Hz with nobody listening — reset both here.
                    self.isRecordingVideo = false
                    self.stopMotionTracking()
                    self.captureError = message
                }
            }
        )
        do {
            try video.configure()
            self.videoCoordinator = video
        } catch {
            storage.discard(workspace)
            self.workspace = nil
            self.yawManifest = nil
            phase = .failed(message: error.localizedDescription)
            throw ScanEngineError.sessionUnavailable(error.localizedDescription)
        }

        video.start()
        phase = .capturing(shots: 0)
    }

    // MARK: - Recording

    func toggleVideoRecording() {
        isRecordingVideo ? stopVideoRecording() : startVideoRecording()
    }

    private func startVideoRecording() {
        guard let videoCoordinator, !isRecordingVideo else { return }
        recordedVideoURL = nil
        coveredYawBins = []
        startYaw = nil
        lastYaw = nil
        // Lock exposure/white balance before the take so frames match each
        // other for feature matching.
        videoCoordinator.lockCameraSettings { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isCancelled else { return }
                self.videoCoordinator?.startRecording()
                self.isRecordingVideo = true
                self.startMotionTracking()
            }
        }
    }

    private func stopVideoRecording() {
        videoCoordinator?.stopRecording()
        // isRecordingVideo flips when the delegate reports the file finalised.
    }

    // MARK: - Motion coverage

    private func startMotionTracking() {
        guard motionManager.isDeviceMotionAvailable else {
            Self.logger.info("Device motion unavailable — orbit coverage ring disabled")
            return
        }
        motionManager.deviceMotionUpdateInterval = 1 / 30
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let motion, let self else { return }
            let yaw = motion.attitude.yaw
            Task { @MainActor in self.noteYaw(yaw) }
        }
    }

    private func stopMotionTracking() {
        // Apple: "always call stopDeviceMotionUpdates() when you no longer
        // need motion data." Safe to call when not started; called from every
        // exit path (failure, cancel, teardown) because deinit is not a
        // reliable stop.
        motionManager.stopDeviceMotionUpdates()
    }

    /// Bins the yaw relative to the recording start into 5° sectors.
    private func noteYaw(_ yaw: Double) {
        guard isRecordingVideo else { return }
        if startYaw == nil {
            startYaw = yaw
            lastYaw = yaw
            coveredYawBins.insert(0)
            return
        }
        var relative = yaw - startYaw!
        // Unwrap into [-π, π] so crossing the ±π seam doesn't jump sectors.
        while relative > .pi { relative -= 2 * .pi }
        while relative < -.pi { relative += 2 * .pi }
        // Fill every sector between the last reading and this one, so a fast
        // swing doesn't skip over sectors.
        if let last = lastYaw {
            var prev = last - startYaw!
            while prev > .pi { prev -= 2 * .pi }
            while prev < -.pi { prev += 2 * .pi }
            var a = prev
            var b = relative
            // Walk the short way; both are within [-π, π].
            if b - a > .pi { a += 2 * .pi } else if a - b > .pi { b += 2 * .pi }
            let steps = max(1, Int(abs(b - a) / (Double.pi / 72)))
            for s in 0...steps {
                let y = a + (b - a) * Double(s) / Double(steps)
                var norm = y.truncatingRemainder(dividingBy: 2 * .pi)
                if norm < 0 { norm += 2 * .pi }
                coveredYawBins.insert(Int(norm / (2 * .pi) * Double(Self.yawBinCount)) % Self.yawBinCount)
            }
        }
        lastYaw = yaw
    }

    // MARK: - Finish / cancel

    func finish() async throws -> ScanRecord {
        guard let workspace, let manifest = yawManifest else {
            throw ScanEngineError.sessionUnavailable(String(localized: "No active session."))
        }

        // M20: check-and-set as ONE synchronous region with no await between
        // check and set. MainActor is reentrant (WWDC21) — a check, an await,
        // then a set would let a second finish() slip in and run a second
        // extraction, reconstruction, and library commit.
        guard !isFinishing else {
            throw ScanEngineError.sessionUnavailable("Finish already in progress.")
        }
        isFinishing = true

        if isRecordingVideo {
            stopVideoRecording()
            // M16-pattern: take the finalized URL from awaitFinalized()
            // directly. The onFinishedRecording hop assigns recordedVideoURL
            // on the MainActor and can lag the finalization continuation,
            // which used to drop the take silently.
            if let coordinator = videoCoordinator,
               let finalizedURL = await coordinator.awaitFinalized() {
                recordedVideoURL = finalizedURL
            } else if recordedVideoURL == nil {
                warnings.append(String(localized: "The video take was dropped — the recording never finalised."))
            }
        }

        // isFinishing is sticky (never cleared), so it can't flip back across
        // an await — still, re-validate it alongside the existing gates at
        // each suspension boundary per the reentrancy guidance.
        guard isFinishing, !isCancelled, case .capturing = phase else {
            throw ScanEngineError.cancelled
        }

        guard let videoURL = recordedVideoURL else {
            phase = .failed(message: String(localized: "No video was recorded."))
            throw ScanEngineError.noImagesCaptured
        }

        phase = .processingVideo(VideoProcessingProgress(stage: String(localized: "Extracting sharp frames")))
        let frameCount: Int
        do {
            let processTask = Task.detached {
                try await FrameExtractor().extractTimeSpread(
                    videoURL: videoURL,
                    views: Self.orbitViews,
                    imagesURL: workspace.imagesURL,
                    manifest: manifest,
                    firstShotIndex: 1,
                    onCoverageWarning: { [weak self] note in
                        Task { @MainActor in self?.warnings.append(note) }
                    }
                ) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .processingVideo = self.phase else { return }
                        self.phase = .processingVideo(VideoProcessingProgress(
                            fraction: fraction,
                            stage: String(localized: "Extracting sharp frames")
                        ))
                    }
                }
            }
            extractTask = processTask
            frameCount = try await processTask.value
            extractTask = nil
        } catch {
            extractTask = nil
            if error is CancellationError || isCancelled {
                storage.discard(workspace)
                teardown()
                phase = .cancelled
                throw ScanEngineError.cancelled
            }
            phase = .failed(message: error.localizedDescription)
            throw error
        }

        guard !isCancelled else {
            storage.discard(workspace)
            teardown()
            phase = .cancelled
            throw ScanEngineError.cancelled
        }

        guard frameCount > 0 else {
            phase = .failed(message: String(localized: "No frames could be extracted."))
            throw ScanEngineError.noImagesCaptured
        }

        if !isOrbitComplete {
            // Minor: on the simulator motion is unavailable so the ring is
            // always empty — don't scold the user about a "0° partial orbit".
            #if targetEnvironment(simulator)
            warnings.append(String(localized: "Orbit coverage tracking is unavailable in the simulator, so the coverage ring stays empty."))
            #else
            warnings.append(String(localized: "Partial orbit: only \(Int(coverageDegrees))° of 360° was covered. Walk all the way around next time."))
            #endif
        }

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

        if let poses = output.poses {
            warnings.append(contentsOf: poses.advice)
        }

        let record = ScanRecord(
            id: workspace.id,
            name: Self.defaultName(for: Date()),
            engine: Self.kind,
            isMetricallyScaled: false,
            imageCount: frameCount,
            detail: .reduced,
            summary: output.poses?.summaryText
        )
        try storage.commit(record, workspace: workspace)

        teardown()
        phase = .done(record)
        return record
    }

    func cancel() {
        // Terminal phases (.done/.failed/.cancelled) must not be re-entered:
        // without this, cancelling after finish() discards the committed
        // workspace and flips the result screen to "cancelled".
        guard !phase.isTerminal else { return }
        isCancelled = true
        extractTask?.cancel()
        if isRecordingVideo { stopVideoRecording() }
        stopMotionTracking()
        // M35: during reconstruction the solver still owns the workspace
        // directory — deleting it now would pull files out from under the
        // live session (mirrors TurntableCaptureEngine, which deliberately
        // avoids this). Discard only when no reconstruction is in flight;
        // finish() observes isCancelled at its next boundary and discards
        // there, after the session is done with the directory.
        let mayDiscard: Bool = {
            if case .reconstructing = phase { return false }
            return true
        }()
        let doomedWorkspace = mayDiscard ? workspace : nil
        teardown()
        if let doomedWorkspace {
            storage.discard(doomedWorkspace)
        }
        phase = .cancelled
    }

    private func teardown() {
        // M19/minor: stop motion on EVERY exit path — deinit is not a
        // reliable stop for CMMotionManager, and an unpaired start drains the
        // battery at 30 Hz indefinitely.
        stopMotionTracking()
        videoCoordinator?.stop()
        videoCoordinator = nil
        workspace = nil
        yawManifest = nil
    }

    private static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "d MMM HH:mm"
        return String(localized: "\(Self.kind.displayName) scan \(formatter.string(from: date))")
    }
}
