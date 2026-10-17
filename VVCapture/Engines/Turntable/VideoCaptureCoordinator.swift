import AVFoundation
import os

/// Owns the `AVCaptureSession` for turntable *video* capture and writes one
/// movie file per recording.
///
/// Separate session from the stills coordinator because AVFoundation gives one
/// running session per camera: when video recording starts, the engine stops
/// the photo session first, and restarts it when recording stops.
///
/// Why video: the turntable is driven by the Edelkrone app, which this app
/// cannot talk to (no BLE API on the v2 head). Video needs no shutter trigger
/// at all — yaw comes from the footage itself (motion onset + calibrated
/// angular velocity), so the two apps never need to synchronise.
final class VideoCaptureCoordinator: NSObject, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.visionvend.capture", category: "turntable-video")

    enum SetupError: LocalizedError {
        case noCamera
        case configurationFailed(String)

        var errorDescription: String? {
            switch self {
            case .noCamera: String(localized: "Rear camera not found.")
            case .configurationFailed(let detail): "Couldn't configure the video camera: \(detail)"
            }
        }
    }

    let session = AVCaptureSession()

    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.visionvend.capture.turntable.video")
    private let videoURL: URL

    private var device: AVCaptureDevice?

    /// Guarded by `stateLock`: true between `startRecording` being accepted and
    /// the file-output delegate reporting completion.
    private let stateLock = NSLock()
    private var _recording = false

    private let onFinishedRecording: @Sendable (URL) -> Void
    private let onFailure: @Sendable (String) -> Void

    init(
        videoURL: URL,
        onFinishedRecording: @escaping @Sendable (URL) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.videoURL = videoURL
        self.onFinishedRecording = onFinishedRecording
        self.onFailure = onFailure
        super.init()
    }

    // MARK: - Lifecycle

    func configure() throws {
        // LiDAR-backed device preferred: a future step records depth alongside
        // the video for auto-masking, and only this device can do that.
        let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)

        guard let device else { throw SetupError.noCamera }
        self.device = device

        session.beginConfiguration()
        // 4K when the device offers it; the frame extractor downsamples for
        // sharpness scoring, but the kept frames stay full resolution.
        if session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
        } else {
            session.sessionPreset = .high
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw SetupError.configurationFailed("Couldn't add input.")
            }
            session.addInput(input)
        } catch let error as SetupError {
            session.commitConfiguration()
            throw error
        } catch {
            session.commitConfiguration()
            throw SetupError.configurationFailed(error.localizedDescription)
        }

        guard session.canAddOutput(movieOutput) else {
            session.commitConfiguration()
            throw SetupError.configurationFailed(String(localized: "Couldn't add movie output."))
        }
        session.addOutput(movieOutput)

        // A hard cap so a forgotten recording can't fill the disk: 15 minutes
        // is several full revolutions at any sane turntable speed.
        movieOutput.maxRecordedDuration = CMTime(seconds: 900, preferredTimescale: 600)

        session.commitConfiguration()

        if let connection = movieOutput.connection(with: .video) {
            // Stabilisation warps pixels relative to the published intrinsics —
            // the same reason it stays off for stills.
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
        }

        // Constant frame rate: the yaw estimator multiplies elapsed time by
        // angular velocity, which is only valid if frames are evenly spaced.
        lockConstantFrameRate(device: device)

        Self.logger.info("Turntable video ready")
    }

    private func lockConstantFrameRate(device: AVCaptureDevice) {
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= 30 && 30 <= $0.maxFrameRate
        }) else {
            Self.logger.error("30 fps not supported, leaving variable frame rate")
            return
        }
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        } catch {
            Self.logger.error("Couldn't lock frame rate: \(error.localizedDescription, privacy: .public)")
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// Resolves once the in-flight recording has been finalised on disk.
    /// Bounded — a delegate that never fires must not hang the finish path.
    func awaitFinalized() async {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if stateLock.withLock({ !_recording }) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        Self.logger.error("Timed out waiting for the video file to finalise")
    }

    // MARK: - Locking

    /// Same discipline as stills: converge focus, exposure and white balance
    /// once, then freeze all three. Drifting exposure between frames is what
    /// breaks feature matching, and the turntable holds a fixed distance.
    func lockCameraSettings(completion: @escaping @Sendable (Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else {
                completion(false)
                return
            }

            do {
                try device.lockForConfiguration()
            } catch {
                completion(false)
                return
            }

            let centre = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = centre }
            if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = centre }
            if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
            if device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
                device.whiteBalanceMode = .autoWhiteBalance
            }
            device.unlockForConfiguration()

            for _ in 0..<40 where device.isAdjustingFocus || device.isAdjustingExposure || device.isAdjustingWhiteBalance {
                Thread.sleep(forTimeInterval: 0.05)
            }

            guard (try? device.lockForConfiguration()) != nil else {
                completion(false)
                return
            }
            if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            device.unlockForConfiguration()

            Self.logger.info("Video focus, exposure, and white balance locked")
            completion(true)
        }
    }

    // MARK: - Recording

    /// Begins recording to the workspace's `video.mp4`. Starts the session if
    /// needed. Safe to call when already recording — the second call is a no-op.
    func startRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.stateLock.withLock({ self._recording }) { return }
            guard !self.movieOutput.isRecording else { return }

            if !self.session.isRunning {
                self.session.startRunning()
            }
            // A stale file from a previous attempt must not be appended to.
            try? FileManager.default.removeItem(at: self.videoURL)
            self.movieOutput.startRecording(to: self.videoURL, recordingDelegate: self)
            self.stateLock.withLock { self._recording = true }
            Self.logger.info("Video recording started")
        }
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension VideoCaptureCoordinator: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // Funnelled through sessionQueue: `_recording` is only ever touched
        // there, and the delegate may arrive on any queue.
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.withLock { self._recording = false }
            if let error {
                Self.logger.error("Recording failed: \(error.localizedDescription, privacy: .public)")
                self.onFailure(error.localizedDescription)
            } else {
                Self.logger.info("Video saved: \(outputFileURL.lastPathComponent, privacy: .public)")
                self.onFinishedRecording(outputFileURL)
            }
        }
    }
}
