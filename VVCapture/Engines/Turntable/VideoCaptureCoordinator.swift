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
///
/// Concurrency model: `sessionQueue` is the ONE serial queue every capture
/// interaction goes through — session start/stop, `startRecording`,
/// `stopRecording`, and both file-output delegate callbacks hop onto it
/// (the delegate "may be called on any thread", so hopping is required, not
/// optional). Recording *state* additionally lives behind `stateLock` because
/// `isRecording` alone lies: `startRecording(to:recordingDelegate:)` is
/// asynchronous, and the only trustworthy "recording is live" signal is
/// `fileOutput(_:didStartRecordingTo:from:)`.
final class VideoCaptureCoordinator: NSObject, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.visionvend.capture", category: "turntable-video")

    enum SetupError: LocalizedError {
        case noCamera
        case configurationFailed(String)

        var errorDescription: String? {
            switch self {
            case .noCamera: String(localized: "Rear camera not found.")
            case .configurationFailed(let detail): String(localized: "Couldn't configure the video camera: \(detail)")
            }
        }
    }

    let session = AVCaptureSession()

    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.visionvend.capture.turntable.video")
    private let videoURL: URL

    private var device: AVCaptureDevice?

    /// Recording lifecycle. `startRecording(to:recordingDelegate:)` returns
    /// immediately; the transition `.starting` -> `.recording` only happens in
    /// `didStartRecordingTo`, so a silent start failure can never strand the
    /// coordinator in a fake "recording" state.
    private enum RecordingState {
        case idle
        case starting      // start requested, not yet confirmed by the delegate
        case recording     // confirmed by didStartRecordingTo
        case stopping      // stop requested, awaiting didFinishRecordingTo
    }

    /// Guarded by `stateLock`.
    private let stateLock = NSLock()
    private var recordingState = RecordingState.idle
    /// `stopRecording()` while `.starting`: nothing is live yet, so the stop
    /// is deferred into `didStartRecordingTo`, which stops immediately.
    private var stopRequestedDuringStart = false
    /// Completion stashed by `stopRecording(completion:)` / `awaitRecordingStopped()`;
    /// resumed exactly once by `didFinishRecordingTo` (or immediately if idle).
    private var stopRecordingCompletion: (@Sendable () -> Void)?
    /// URL of the most recently finalised recording, set by
    /// `finishRecording(url:)` after the zero-byte check passes. Guarded by
    /// `stateLock`; read in `awaitFinalized()` after a `sessionQueue` barrier
    /// so it can't race the delegate block. Cleared when a new recording
    /// starts, so a stale URL is never handed back.
    private var finalizedURL: URL?
    /// Set when the coordinator gives up on the in-flight take — the
    /// `awaitFinalized()` timeout, or a take that went live after its start
    /// was already declared failed. The take's late `didFinishRecordingTo`
    /// must still reset state and resume waiters, but must NOT deliver
    /// `onFinishedRecording`: the engine already moved on (it warned "built
    /// from stills only", and its handler blindly assigns `recordedVideoURL`,
    /// which the video pipeline would then process). Consumed-and-cleared by
    /// the next `didFinishRecordingTo`; cleared by `startRecording()` for a
    /// new take. Guarded by `stateLock`.
    private var suppressFinishCallback = false
    /// True while the session is meant to be running. sessionQueue-confined
    /// (every read and write happens on `sessionQueue`). The start watchdog
    /// must not report "camera failed to start" after a legitimate quick
    /// stop — teardown/cancel inside the 5 s window.
    private var sessionShouldBeRunning = false
    /// Identifies `sessionQueue` so `awaitFinalized()` can skip its
    /// `sessionQueue.sync` barrier when already on the queue (`sync` from
    /// the queue itself deadlocks).
    private let sessionQueueKey = DispatchSpecificKey<Void>()

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
        sessionQueue.setSpecific(key: sessionQueueKey, value: ())
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionInterruption(_:)),
            name: .AVCaptureSessionWasInterrupted,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionInterruptionEnded(_:)),
            name: .AVCaptureSessionInterruptionEnded,
            object: session
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Lifecycle

    func configure() throws {
        // Color video primary: the LiDAR composite device (`builtInLiDARDepthCamera`
        // = two cameras + one LiDAR + one YUV stream) delivers DEPTH frames at
        // VGA-class resolution. Preferring it as the movie input silently
        // degrades the 4K color pipeline the frame extractor depends on — and
        // on the 15 Pro Max it always wins the old `??` chain. Prefer the
        // multi-camera composites for their better zoom, plain wide-angle last.
        // LiDAR stays reserved for a future depth-recording pass, as a SECOND
        // input only — never as the primary movie input.
        let device = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)

        guard let device else { throw SetupError.noCamera }
        self.device = device

        session.beginConfiguration()
        // 4K when the device offers it; the frame extractor downsamples for
        // sharpness scoring, but the kept frames stay full resolution.
        if session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        } else {
            // `.high` is near-universal, but don't assume: assigning an
            // unsupported preset raises. Leave the session default instead.
            Self.logger.error("Neither 4K nor .high preset is settable; keeping the session default")
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw SetupError.configurationFailed(String(localized: "Couldn't add input."))
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
            // Level default; the real orientation is applied from device
            // orientation at record start (see applyVideoRotationFromOrientation).
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
        }

        // Constant frame rate: the yaw estimator multiplies elapsed time by
        // angular velocity, which is only valid if frames are evenly spaced.
        lockConstantFrameRate(device: device)

        Self.logger.info("Turntable video ready (device: \(device.localizedName, privacy: .public))")
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

    /// Applies the current device orientation to the movie connection as a
    /// `videoRotationAngle`, so portrait-grip recordings don't come out
    /// sideways. For `AVCaptureMovieFileOutput` this writes a QuickTime track
    /// matrix (rotation *metadata*, not pixel rotation) — players that ignore
    /// the matrix still show the video unrotated, and any downstream export
    /// must carry the transform. Only 0/90/180/270 are valid; anything else
    /// raises, so the value is rounded to the nearest quarter turn and gated
    /// on `isVideoRotationAngleSupported`.
    private func applyVideoRotationFromOrientation() {
        guard let connection = movieOutput.connection(with: .video),
              let device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        let rawAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        let quarterTurns = Int((rawAngle / 90).rounded())
        let normalized = CGFloat(((quarterTurns % 4) + 4) % 4 * 90)
        guard connection.isVideoRotationAngleSupported(normalized) else {
            Self.logger.error("Video rotation angle \(normalized, privacy: .public)° unsupported; leaving 0°")
            return
        }
        connection.videoRotationAngle = normalized
        Self.logger.info("Video rotation angle set to \(normalized, privacy: .public)°")
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.session.isRunning else { return }
            self.sessionShouldBeRunning = true
            self.session.startRunning()
            self.armSessionStartWatchdog()
        }
    }

    /// Camera-starvation detection: if another app holds the camera (or the
    /// device is otherwise unavailable), `startRunning()` may never bring the
    /// session up. Because this check is queued on `sessionQueue` *after* the
    /// `startRunning()` block, it runs strictly after `startRunning()`
    /// returned — if the session still isn't running then, it never will be.
    /// Gated on `sessionShouldBeRunning`: a legitimate quick stop
    /// (teardown/cancel) inside the 5 s window must not surface a bogus
    /// "camera failed to start".
    private func armSessionStartWatchdog() {
        sessionQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.sessionShouldBeRunning, !self.session.isRunning else { return }
            Self.logger.error("Camera session never reached running — starved by another app?")
            self.onFailure(String(localized: "The camera failed to start — it may be in use by another app."))
        }
    }

    @objc private func handleSessionInterruption(_ notification: Notification) {
        let reasonValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
        let reason = reasonValue.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
        Self.logger.error("Capture session interrupted: \(String(describing: reason), privacy: .public)")
        // Another foreground app took the camera: the session will NOT
        // recover on its own, so surface it instead of recording black.
        if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
            onFailure(String(localized: "The camera was taken by another app."))
        }
    }

    @objc private func handleSessionInterruptionEnded(_ notification: Notification) {
        Self.logger.info("Capture session interruption ended")
    }

    /// Fire-and-forget stop. Kept for existing callers (teardown paths that
    /// don't need to sequence on the stop). Prefer `stop(completion:)` /
    /// `awaitStopped()` when the engine must sequence the stills/video camera
    /// handoff on the session actually being down.
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // Clear first: the start watchdog must stay silent after a
            // legitimate stop, even if the session never got running.
            self.sessionShouldBeRunning = false
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// Stops the session and calls `completion` once it is fully down.
    /// `stopRunning()` is synchronous and blocks until the session stops
    /// completely — it runs on `sessionQueue` (never the main thread), and its
    /// *return* is the completion signal.
    func stop(completion: @escaping @Sendable () -> Void) {
        sessionQueue.async { [weak self] in
            self?.sessionShouldBeRunning = false
            self?.session.stopRunning()
            completion()
        }
    }

    /// Async form of `stop(completion:)`.
    func awaitStopped() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stop { continuation.resume() }
        }
    }

    /// Resolves once the in-flight recording has been finalised on disk, handing
    /// the recorded file URL back directly (M16) instead of relying on a
    /// property assigned across an actor hop (which could land after the
    /// caller's await, silently dropping the take).
    /// Bounded — a delegate that never fires must not hang the finish path.
    /// On timeout the recording state is forcibly reset (a stuck non-idle
    /// state would otherwise no-op every later call and kill video for the
    /// session) and nil is returned so the engine can warn instead of
    /// silently building from stills. If the awaiting task is cancelled, the
    /// take is abandoned quietly instead: state is reset and the late
    /// delegate suppressed, but no `onFailure` fires — cancellation is not a
    /// recording failure.
    func awaitFinalized() async -> URL? {
        let deadline = Date().addingTimeInterval(10)
        var wasCancelled = false
        while Date() < deadline {
            if stateLock.withLock({ recordingState == .idle }) { break }
            // `Task.sleep` throws `CancellationError`, but `try?` would
            // swallow it and keep polling to the deadline — check explicitly
            // so a cancelled finish abandons the take promptly instead.
            if Task.isCancelled { wasCancelled = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Barrier: the delegate block that flips the state to `.idle` runs
        // `finishRecording(url:)` on this same queue immediately after — sync
        // here so the `finalizedURL` read below can't race it and return nil
        // for a perfectly good recording. Skipped when already on
        // `sessionQueue`: `sync` from the queue itself deadlocks, and being
        // on the queue already serialises us after the delegate block.
        if DispatchQueue.getSpecific(key: sessionQueueKey) == nil {
            sessionQueue.sync {}
        }
        let wasPending = stateLock.withLock { () -> Bool in
            let pending = recordingState != .idle
            if pending {
                recordingState = .idle
                stopRequestedDuringStart = false
            }
            return pending
        }
        if wasPending {
            if wasCancelled {
                // The caller is going away — abandon the take quietly.
                // Cancellation isn't a recording failure, so no `onFailure`.
                Self.logger.info("awaitFinalized() cancelled; abandoning the in-flight take")
            } else {
                Self.logger.error("Timed out waiting for the video file to finalise; recording state reset")
            }
            // Don't strand the movie output: without this the take keeps
            // recording to the 15-minute cap as a zombie, and its eventual
            // `didFinishRecordingTo` would deliver `onFinishedRecording` for
            // a take the engine already dropped (its handler blindly assigns
            // `recordedVideoURL`, which the pipeline would then process
            // despite the "built from stills only" warning). Force
            // finalisation now; `suppressFinishCallback` keeps the late
            // delegate from reporting success.
            stateLock.withLock { self.suppressFinishCallback = true }
            sessionQueue.async { [weak self] in
                self?.movieOutput.stopRecording()
            }
            self.drainStopRecordingCompletion()
            if !wasCancelled {
                onFailure(String(localized: "Timed out waiting for the video file to finalise."))
            }
            return nil
        }
        // Consume-on-read: a second call must not hand back the previous take's
        // URL. `startRecording()` also clears it, so this is belt and braces
        // against a stale-URL double read.
        return stateLock.withLock { () -> URL? in
            let url = finalizedURL
            finalizedURL = nil
            return url
        }
    }

    /// Resumes a stashed `stopRecording(completion:)` waiter, if any, and
    /// clears it. Called from every path that returns the state to `.idle`
    /// without going through `didFinishRecordingTo` (watchdogs), so an
    /// `awaitRecordingStopped()` caller can never hang on a dead recording.
    private func drainStopRecordingCompletion() {
        let completion = stateLock.withLock { () -> (@Sendable () -> Void)? in
            defer { self.stopRecordingCompletion = nil }
            return self.stopRecordingCompletion
        }
        completion?()
    }

    // MARK: - Locking

    /// Same discipline as stills: converge focus, exposure and white balance
    /// once, then freeze all three. Drifting exposure between frames is what
    /// breaks feature matching, and the turntable holds a fixed distance.
    ///
    /// The convergence wait is bounded (2 s); if the camera never settles we
    /// report failure rather than locking a bad baseline — a frozen wrong
    /// exposure is worse than retrying.
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

            guard !device.isAdjustingFocus, !device.isAdjustingExposure, !device.isAdjustingWhiteBalance else {
                Self.logger.error("Focus/exposure never converged; refusing to lock a bad baseline")
                completion(false)
                return
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
    ///
    /// The state machine, not `movieOutput.isRecording`, is the source of
    /// truth: `startRecording(to:recordingDelegate:)` is asynchronous and the
    /// actual start is confirmed by `didStartRecordingTo`. If confirmation
    /// never arrives (silent start failure), a 5 s watchdog resets the state
    /// to `.idle` and surfaces the failure instead of stranding `_recording`
    /// at true forever.
    func startRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let alreadyActive = self.stateLock.withLock { () -> Bool in
                guard self.recordingState == .idle else { return true }
                self.recordingState = .starting
                // A stale finalised URL must never be handed back for the new take.
                self.finalizedURL = nil
                // A previous take's abandonment must not suppress this take's
                // finish callback.
                self.suppressFinishCallback = false
                return false
            }
            guard !alreadyActive else {
                // A take is already in flight or finalising (same videoURL —
                // starting another now would corrupt the handoff). Loud
                // enough to spot a dropped start in the log, quiet enough
                // for the normal double-call guard.
                Self.logger.debug("startRecording() ignored: recording state is not idle")
                return
            }

            if !self.session.isRunning {
                self.sessionShouldBeRunning = true
                self.session.startRunning()
                self.armSessionStartWatchdog()
            }
            self.applyVideoRotationFromOrientation()
            // A stale file from a previous attempt must not be appended to.
            try? FileManager.default.removeItem(at: self.videoURL)
            self.movieOutput.startRecording(to: self.videoURL, recordingDelegate: self)
            Self.logger.info("Video recording start requested")

            // Silent-start watchdog: no `didStartRecordingTo` within 5 s means
            // the recording never went live; reset so later calls aren't no-ops.
            // If a stop was requested while the start was in flight, the
            // engine already moved on — report nothing instead of a bogus
            // "failed to start".
            self.sessionQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                let (stillStarting, stopWasRequested) = self.stateLock.withLock { () -> (Bool, Bool) in
                    guard self.recordingState == .starting else { return (false, false) }
                    let stopReq = self.stopRequestedDuringStart
                    self.recordingState = .idle
                    self.stopRequestedDuringStart = false
                    return (true, stopReq)
                }
                if stillStarting {
                    self.drainStopRecordingCompletion()
                    if stopWasRequested {
                        Self.logger.info("Recording start watchdog fired after a stop was requested; no failure reported")
                    } else {
                        Self.logger.error("Recording start was never confirmed by the delegate; state reset")
                        self.onFailure(String(localized: "Video recording failed to start."))
                    }
                }
            }
        }
    }

    /// Fire-and-forget stop of the recording. Guards on the internal state
    /// machine (not `movieOutput.isRecording`): a stop issued while the start
    /// is still in flight is deferred into `didStartRecordingTo`, so a quick
    /// stop can't be silently dropped and leave the recording running to the
    /// 15-minute cap.
    func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let shouldStopNow = self.stateLock.withLock { () -> Bool in
                switch self.recordingState {
                case .idle, .stopping:
                    return false
                case .starting:
                    // Nothing live yet — `didStartRecordingTo` will stop it
                    // the moment the recording actually begins.
                    self.stopRequestedDuringStart = true
                    return false
                case .recording:
                    self.recordingState = .stopping
                    return true
                }
            }
            guard shouldStopNow else { return }
            self.movieOutput.stopRecording()
        }
    }

    /// Stops the recording and calls `completion` once the file-output
    /// delegate has confirmed finalisation (the AVCam pattern: the
    /// continuation is stashed here and resumed in
    /// `didFinishRecordingTo`). If no recording is in flight, `completion`
    /// runs immediately. Note: `completion` fires on stop — it does not
    /// distinguish success from failure; the outcome still travels through
    /// `onFinishedRecording` / `onFailure`.
    func stopRecording(completion: @escaping @Sendable () -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else {
                // The coordinator is gone — resume the waiter instead of
                // stranding `awaitRecordingStopped()` forever.
                completion()
                return
            }
            let alreadyIdle = self.stateLock.withLock { () -> Bool in
                if self.recordingState == .idle { return true }
                self.stopRecordingCompletion = completion
                return false
            }
            if alreadyIdle {
                completion()
            } else {
                self.stopRecording()
            }
        }
    }

    /// Async form of `stopRecording(completion:)`.
    func awaitRecordingStopped() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stopRecording { continuation.resume() }
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension VideoCaptureCoordinator: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        // Hop to sessionQueue: the delegate "may be called on any thread" and
        // all state lives there / behind `stateLock`.
        sessionQueue.async { [weak self] in
            guard let self else { return }
            enum StartResolution { case confirmed, duplicate, stopDeferred, stopOrphaned }
            let resolution = self.stateLock.withLock { () -> StartResolution in
                if self.stopRequestedDuringStart {
                    self.stopRequestedDuringStart = false
                    self.recordingState = .stopping
                    return .stopDeferred
                }
                switch self.recordingState {
                case .starting:
                    self.recordingState = .recording
                    return .confirmed
                case .recording, .stopping:
                    // The take is (or was) owned: `.recording` is a duplicate
                    // confirmation for the live take; `.stopping` means a stop
                    // is already in flight and its finish is expected.
                    // Either way this must NOT be treated as an orphan —
                    // suppressing or stopping here would kill/mute a take the
                    // engine is actively finalising.
                    return .duplicate
                case .idle:
                    // A take went live with no start in flight: the state was
                    // reset by a watchdog after the engine gave up on it (or
                    // was already told the start failed). Nobody owns this
                    // take — stop it at once instead of letting it run to the
                    // 15-minute cap, and suppress its finish callback: the
                    // failure was already reported.
                    self.suppressFinishCallback = true
                    self.recordingState = .stopping
                    return .stopOrphaned
                }
            }
            switch resolution {
            case .confirmed:
                Self.logger.info("Video recording confirmed started")
            case .duplicate:
                Self.logger.warning("Duplicate recording-start confirmation for an owned take; ignoring")
            case .stopDeferred:
                // A stop was requested while the start was in flight: stop now
                // that there is actually something to stop.
                Self.logger.info("Recording started after stop was requested; stopping immediately")
                self.movieOutput.stopRecording()
            case .stopOrphaned:
                Self.logger.error("Recording went live with no start in flight (state was reset by a watchdog); stopping the orphaned take")
                self.movieOutput.stopRecording()
            }
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // Funnelled through sessionQueue: recording state is only ever
        // touched there (or behind `stateLock`), and the delegate may arrive
        // on any thread.
        sessionQueue.async { [weak self] in
            guard let self else { return }
            enum FinishResolution { case stale, suppressed, deliver }
            let resolution = self.stateLock.withLock { () -> FinishResolution in
                guard self.recordingState != .starting else {
                    // A finish for a take whose start was never confirmed:
                    // the take was abandoned (a watchdog/timeout already reset
                    // the state and resumed its waiters), and a new take may
                    // already be starting. Touching state here would stomp the
                    // new take back to `.idle`, and its own start confirmation
                    // would then be mistaken for an orphan and killed. The old
                    // take's waiters were already resumed by the watchdog or
                    // timeout that moved the state on, so there is nothing to
                    // drain — report nothing and leave the new take alone.
                    return .stale
                }
                self.recordingState = .idle
                self.stopRequestedDuringStart = false
                defer { self.suppressFinishCallback = false }
                return self.suppressFinishCallback ? .suppressed : .deliver
            }
            switch resolution {
            case .stale:
                Self.logger.error("Ignoring stale finish callback for a take that never confirmed starting")
                return
            case .suppressed:
                // The recording has stopped; resume the waiter first.
                self.drainStopRecordingCompletion()
                // The engine abandoned this take (finalise timeout) or was
                // already told it failed (orphaned late start). State is
                // reset and waiters are resumed; report nothing further —
                // delivering success now would contradict the failure the
                // engine already acted on.
                Self.logger.info("Discarding finish callback for an abandoned take")
                return
            case .deliver:
                break
            }
            // The recording has stopped either way; resume the waiter first.
            self.drainStopRecordingCompletion()

            if let error {
                if Self.isExpectedCapStop(error) {
                    // 15-minute (or file-size) cap: AVFoundation finalised the
                    // file before cutting it — it is complete and playable.
                    // Reporting this as a failure would discard usable video.
                    Self.logger.info("Recording ended at the duration/size cap; treating as success")
                    self.finishRecording(url: outputFileURL)
                } else {
                    Self.logger.error("Recording failed: \(error.localizedDescription, privacy: .public)")
                    self.onFailure(error.localizedDescription)
                }
            } else {
                self.finishRecording(url: outputFileURL)
            }
        }
    }

    /// The 15-minute `maxRecordedDuration` (or a size cap) delivers these
    /// exact codes with a complete, playable file on disk. Note this is
    /// deliberately NOT the AVCam sample behaviour — AVCam throws on any
    /// non-nil error, which misclassifies cap-stops as failures.
    private static func isExpectedCapStop(_ error: Error) -> Bool {
        guard let avError = error as? AVError else { return false }
        return avError.code == .maximumDurationReached
            || avError.code == .maximumFileSizeReached
    }

    /// Routes a finalised recording to success or failure. Apple documents
    /// that the delegate fires "even if no data is successfully written", so
    /// a nil error with a missing/zero-byte file is also a real failure
    /// state — check the file, not just the error.
    private func finishRecording(url: URL) {
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard byteCount > 0 else {
            Self.logger.error("Recording finished but produced an empty file")
            onFailure(String(localized: "The video recording produced an empty file."))
            return
        }
        Self.logger.info("Video saved: \(url.lastPathComponent, privacy: .public) (\(byteCount, privacy: .public) bytes)")
        stateLock.withLock { self.finalizedURL = url }
        onFinishedRecording(url)
    }
}
