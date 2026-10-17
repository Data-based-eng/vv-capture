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
    private let motionQueue = OperationQueue()
    private var startYaw: Double?
    private var lastYaw: Double?

    private var isCancelled = false

    init(storage: ScanStorage) {
        self.storage = storage
    }

    func start() throws {
        guard case .available = Self.availability else {
            throw ScanEngineError.sessionUnavailable(Self.availability.blockedReason ?? "Unknown reason")
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
                Task { @MainActor in self?.captureError = message }
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
        phase = .capturing(shots: 0, limit: 0)
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
            throw ScanEngineError.sessionUnavailable("No active session.")
        }

        if isRecordingVideo {
            stopVideoRecording()
            await videoCoordinator?.awaitFinalized()
        }

        guard !isCancelled, case .capturing = phase else {
            throw ScanEngineError.cancelled
        }

        guard let videoURL = recordedVideoURL else {
            phase = .failed(message: String(localized: "No video was recorded."))
            throw ScanEngineError.noImagesCaptured
        }

        phase = .processingVideo(VideoProcessingProgress(stage: "Extracting sharp frames"))
        let frameCount: Int
        do {
            let processTask = Task.detached {
                try await FrameExtractor().extractTimeSpread(
                    videoURL: videoURL,
                    views: Self.orbitViews,
                    imagesURL: workspace.imagesURL,
                    manifest: manifest
                ) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .processingVideo = self.phase else { return }
                        self.phase = .processingVideo(VideoProcessingProgress(
                            fraction: fraction,
                            stage: "Extracting sharp frames"
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
            warnings.append(String(localized: "Partial orbit: only \(Int(coverageDegrees))° of 360° was covered. Walk all the way around next time."))
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
        storage.commit(record, workspace: workspace)

        teardown()
        phase = .done(record)
        return record
    }

    func cancel() {
        isCancelled = true
        extractTask?.cancel()
        if isRecordingVideo { stopVideoRecording() }
        stopMotionTracking()
        if let workspace {
            storage.discard(workspace)
        }
        teardown()
        phase = .cancelled
    }

    private func teardown() {
        videoCoordinator?.stop()
        videoCoordinator = nil
        workspace = nil
        yawManifest = nil
    }

    private static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return String(localized: "Orbit scan \(formatter.string(from: date))")
    }
}
