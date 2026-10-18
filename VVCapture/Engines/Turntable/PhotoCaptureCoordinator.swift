import AVFoundation
import os

/// Owns the `AVCaptureSession` for turntable capture and writes stills to disk.
///
/// Separate from the engine because AVFoundation delivers on its own queues and
/// wants an `NSObject` delegate, while the engine is a main-actor observable.
///
/// Threading contract: all session and capture-state mutation happens on
/// `sessionQueue`. Photo-output delegate callbacks arrive on AVFoundation's
/// callback queue and are funneled onto `sessionQueue` before touching state.
/// `stopSync()` is the one deliberate exception — it blocks its caller.
final class PhotoCaptureCoordinator: NSObject, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.visionvend.capture", category: "turntable")

    enum SetupError: LocalizedError {
        case noCamera
        case configurationFailed(String)
        case noPhotoData

        var errorDescription: String? {
            switch self {
            case .noCamera: String(localized: "Rear camera not found.")
            case .configurationFailed(let detail): String(localized: "Couldn't configure the camera: \(detail)")
            case .noPhotoData: String(localized: "Couldn't get photo data.")
            }
        }
    }

    let session = AVCaptureSession()

    /// True when the capture device can attach depth to each photo. Without it the
    /// reconstruction still works but comes out unscaled, so the caller records the
    /// difference on the `ScanRecord` instead of quietly claiming real dimensions.
    private(set) var deliversDepth = false

    /// Largest photo resolution the active format offers, in megapixels — surfaced so
    /// the UI can show what it is actually capturing at.
    private(set) var megapixels = 0

    /// Photo codec in use for this session, decided once the output is attached.
    /// On every device this app supports (iOS 18+) the HEVC codec is available,
    /// so the JPEG fallback below is effectively unreachable — but the file
    /// extension must still match the bytes actually written.
    private(set) var usesHEVC = false

    /// File extension for stills written by this coordinator — "heic" when the
    /// HEVC codec is in use, "jpg" for the JPEG fallback.
    var photoFileExtension: String { usesHEVC ? "heic" : "jpg" }

    /// File name for a shot index, exactly as `capture()` writes it to disk.
    /// The engine's yaw manifest must build names with this rather than a
    /// hardcoded ".heic", or the manifest and the directory diverge on the
    /// JPEG-fallback path.
    func fileName(forShot index: Int) -> String {
        String(format: "shot_%06d.\(photoFileExtension)", index)
    }

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.visionvend.capture.turntable")
    private let imagesDirectory: URL

    private var device: AVCaptureDevice?
    private var maxDimensions = CMVideoDimensions(width: 0, height: 0)

    /// One delegate per in-flight photo, keyed by settings id — the shape
    /// `AVCapturePhotoOutput` expects, since it only holds the delegate weakly.
    /// A delegate stays registered until its terminal
    /// `didFinishCaptureFor` fires: that callback, not the app's serial queue,
    /// is what marks the photo output's internal pipeline as drained.
    /// Guarded by `pendingLock`.
    private var pendingCaptures: [Int64: PhotoDelegate] = [:]
    private let pendingLock = NSLock()
    /// Continuations parked in `drainPendingCaptures()`, resumed when the last
    /// in-flight delegate reports back. Guarded by `pendingLock`.
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set only by `drainPendingCaptures()`'s timeout path, when the 15 s sleep
    /// actually completes. Serves two purposes: (1) the timeout task resumes
    /// the worker before returning, so `group.next()` may collect the worker's
    /// `false` first — OR-ing this flag makes the timeout deterministic instead
    /// of racy; (2) after this point no waiter may park — the timeout task has
    /// already popped every waiter, so a continuation appended afterwards would
    /// never be resumed and the task group would hang on scope exit. Guarded by
    /// `pendingLock`.
    private var drainTimedOut = false
    /// Set once `finish()`'s drain has returned: a delegate that fires after
    /// this point is a straggler past the drain cap, and its bytes must not
    /// land on disk — otherwise the file exists with no yaw entry, or lands
    /// after the reconstruction input was already enumerated. Guarded by
    /// `pendingLock`.
    private var discardLateCaptures = false

    /// `AVCaptureSessionRuntimeError` observer token. Without it a mid-scan
    /// session death (device lost, media services reset) is silent — the
    /// engine's `onFailure` handler would stay dead code forever.
    private var runtimeErrorObserver: NSObjectProtocol?

    private var shotIndex = 0

    /// Decaying reference for the blur gate. Absolute sharpness values mean
    /// nothing across scenes; relative ones do — but a never-decaying maximum
    /// lets one anomalously sharp frame (or dimming light afterwards) reject
    /// everything for the rest of the session. Every scored frame pulls the
    /// reference toward itself (`max(sharpness, reference * decay)`), so a
    /// lucky early frame stops dominating after a few dozen frames.
    private var sharpnessReference: Float = 0
    /// Per scored frame — 0.97^35 ≈ 0.34, so a stale reference halves in
    /// roughly two dozen frames.
    private let referenceDecay: Float = 0.97

    /// A frame scoring below this fraction of the reference is discarded.
    private let sharpnessFloor: Float = 0.45
    /// Consecutive blur rejections. Past `maxConsecutiveRejections` the floor
    /// relaxes to `relaxedFloor`: sustained rejection means the reference (or
    /// the light) is wrong, not the scene, and the scan must not starve.
    private var consecutiveRejections = 0
    private let maxConsecutiveRejections = 8
    private let relaxedFloor: Float = 0.15

    private let onShotSaved: @Sendable (Int, Date, Float?) -> Void
    private let onShotRejected: @Sendable (String) -> Void
    /// Session-level failures only (configuration, unrecoverable session state).
    /// Per-capture failures — a bad frame, a write error — go through
    /// `onShotRejected`: one failing frame must never invalidate the session
    /// or the captures still in flight.
    private let onFailure: @Sendable (String) -> Void

    init(
        imagesDirectory: URL,
        onShotSaved: @escaping @Sendable (Int, Date, Float?) -> Void,
        onShotRejected: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.imagesDirectory = imagesDirectory
        self.onShotSaved = onShotSaved
        self.onShotRejected = onShotRejected
        self.onFailure = onFailure
        super.init()

        // Session-level failures after configure() have no other reporting
        // path. Delivered on an arbitrary thread; funneled to sessionQueue.
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let message: String
            if let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error {
                message = error.localizedDescription
            } else {
                message = String(localized: "The camera session failed unexpectedly.")
            }
            self.sessionQueue.async { [weak self] in
                self?.onFailure(message)
            }
        }
    }

    deinit {
        if let runtimeErrorObserver {
            NotificationCenter.default.removeObserver(runtimeErrorObserver)
        }
    }

    // MARK: - Lifecycle

    func configure() throws {
        // The LiDAR depth camera must NEVER be the photo input: on it,
        // fileDataRepresentation() yields depth-map data (or nil), not a color
        // photo. Prefer the wide-angle-family color devices instead — the
        // dual/triple virtual devices still expose depth-data delivery, so
        // metric scale survives without sacrificing color stills.
        let device = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)

        guard let device else { throw SetupError.noCamera }
        self.device = device

        session.beginConfiguration()
        session.sessionPreset = .photo

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

        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            throw SetupError.configurationFailed(String(localized: "Couldn't add photo output."))
        }
        session.addOutput(photoOutput)

        usesHEVC = photoOutput.availablePhotoCodecTypes.contains(.hevc)

        // Must be raised on the output before any per-shot request can ask for it.
        photoOutput.maxPhotoQualityPrioritization = .quality

        // Photogrammetry detail scales directly with pixels on the subject, so take
        // the largest resolution the active format supports rather than the default.
        if let largest = device.activeFormat.supportedMaxPhotoDimensions
            .max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            maxDimensions = largest
            photoOutput.maxPhotoDimensions = largest
            megapixels = Int((Double(largest.width) * Double(largest.height) / 1_000_000).rounded())
        }

        if photoOutput.isDepthDataDeliverySupported {
            photoOutput.isDepthDataDeliveryEnabled = true
            deliversDepth = true
        }

        session.commitConfiguration()

        // Stabilisation warps pixels relative to the published intrinsics, which is
        // exactly what the solver relies on.
        if let connection = photoOutput.connection(with: .video), connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }

        Self.logger.info("Turntable camera ready — \(self.megapixels, privacy: .public) MP, depth: \(self.deliversDepth, privacy: .public)")
    }

    func start() {
        // Fire-and-forget, kept for existing callers. Routes through the
        // awaitable path so a start that races a still-finalising video
        // session gets its one retry instead of silently staying stopped.
        Task { [weak self] in _ = await self?.startAsync() }
    }

    /// Starts the session and waits — bounded — for it to actually run.
    ///
    /// This is the deterministic primitive for the video→photo handoff: the
    /// engine should `await` this (after synchronously stopping the video
    /// session) instead of the fire-and-forget `start()`, so a start that
    /// raced the camera's release is retried rather than silently dropped.
    /// - Returns: true when the session is running within `timeout`.
    func startAsync(timeout: TimeInterval = 5) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                guard let self else { return false }
                // First attempt.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.sessionQueue.async { [weak self] in
                        guard let self else { continuation.resume(); return }
                        if !self.session.isRunning { self.session.startRunning() }
                        continuation.resume()
                    }
                }
                if await self.pollRunning(upTo: 2) { return true }
                // One retry: the video session may have been finalising the
                // movie file while the first attempt ran.
                Self.logger.warning("Photo session didn't start; retrying once")
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.sessionQueue.async { [weak self] in
                        guard let self else { continuation.resume(); return }
                        if !self.session.isRunning { self.session.startRunning() }
                        continuation.resume()
                    }
                }
                return await self.pollRunning(upTo: 2)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    /// Polls `isRunning` until true or `seconds` elapse. Runs off `sessionQueue`
    /// so it never blocks the queue the session needs.
    private func pollRunning(upTo seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        // `Task.isCancelled` in the condition: once cancelled, `Task.sleep`
        // returns immediately, and without this the loop would hot-spin until
        // the deadline.
        while !session.isRunning, !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return session.isRunning
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.retryPendingCleanup()
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// Synchronous stop. Blocks the calling thread until the session fully
    /// stops — `AVCaptureSession.stopRunning()` is itself blocking, typically
    /// tens of milliseconds, worst case ~2s if `sessionQueue` is mid-convergence
    /// in `lockCameraSettings`.
    ///
    /// The engine uses this on the photo→video handoff: the video session must
    /// not `startRunning()` while the photo session still holds the device.
    /// Must not be called from `sessionQueue` itself (deadlock).
    ///
    /// For new code prefer `stopAsync()`, which never blocks the caller.
    func stopSync() {
        sessionQueue.sync { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// Stops the session without blocking the caller. `stopRunning()` still
    /// runs on `sessionQueue` (it must), but the caller just awaits the
    /// outcome — safe from the main actor and from any queue the capture
    /// callbacks need.
    /// - Returns: true when the session stopped within `timeout`. A false
    ///   return means the stop may still complete afterwards; the session is
    ///   not guaranteed stopped.
    func stopAsync(timeout: TimeInterval = 5) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                guard let self else { return false }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.sessionQueue.async { [weak self] in
                        guard let self else { continuation.resume(); return }
                        if self.session.isRunning { self.session.stopRunning() }
                        continuation.resume()
                    }
                }
                return !self.session.isRunning
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                Self.logger.warning("Timed out waiting for photo session to stop")
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    /// Called by the engine after `drainPendingCaptures()` returns: any
    /// delegate still outstanding blew the 15 s cap, and its bytes must not
    /// land on disk from here on.
    func setDiscardLateCaptures() {
        pendingLock.withLock { discardLateCaptures = true }
    }

    /// Thread-safe read of `discardLateCaptures` for the photo output's
    /// callback queue (which must never touch `sessionQueue` state).
    private func shouldDiscardLateCapture() -> Bool {
        pendingLock.withLock { discardLateCaptures }
    }

    /// Resolves once every in-flight capture has reported back.
    ///
    /// `finish()` waits on this before reconstructing: without it, a photo whose
    /// delegate fires after teardown would land on disk with no yaw entry, and a
    /// photo landing mid-reconstruction would miss the solver's input enumeration.
    ///
    /// The drain tracks the photo output's *internal* pipeline, not the app's
    /// serial queue: each capture's delegate stays retained in `pendingCaptures`
    /// until its terminal `didFinishCaptureFor` fires, and waiters parked here
    /// are resumed at that point. Bounded — a delegate that never fires must
    /// not hang the finish path.
    func drainPendingCaptures() async {
        // A fresh drain must not inherit a previous call's expiry.
        pendingLock.withLock { drainTimedOut = false }
        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                guard let self else { return false }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.pendingLock.withLock {
                        if self.pendingCaptures.isEmpty || self.drainTimedOut {
                            continuation.resume()
                        } else {
                            self.drainWaiters.append(continuation)
                        }
                    }
                }
                return false
            }
            group.addTask { [weak self] in
                // `try?` would conflate cancellation with timeout; distinguish
                // them so the error log below stays truthful. Either way the
                // waiters MUST be unparked here, not just abandoned: the worker
                // above is parked in a checked continuation that cancellation
                // cannot resume, so without this the task group would wait on
                // the worker forever and the 15 s bound would be a lie — and an
                // externally cancelled drain would hang the group on scope
                // exit. Each waiter is popped exactly once under pendingLock,
                // so this can't double-resume one the delegate path took.
                // Only a REAL timeout marks expiry (see `drainTimedOut`): on
                // cancellation the worker already finished normally, so there
                // is nothing parked and nothing to mark.
                let didTimeOut: Bool
                do {
                    try await Task.sleep(for: .seconds(15))
                    didTimeOut = true
                } catch {
                    didTimeOut = false
                }
                if let self {
                    self.pendingLock.withLock {
                        if didTimeOut { self.drainTimedOut = true }
                    }
                    let waiters: [CheckedContinuation<Void, Never>] = self.pendingLock.withLock {
                        defer { self.drainWaiters.removeAll() }
                        return self.drainWaiters
                    }
                    for waiter in waiters { waiter.resume() }
                }
                return didTimeOut
            }
            let first = await group.next() ?? true
            group.cancelAll()
            // `first` alone is racy: on a real timeout the worker is resumed
            // by the unpark above and can return `false` before the timeout
            // task's `true` reaches `group.next()`. The flag is set only by
            // the timeout path, so OR-ing makes the timeout deterministic.
            return first || pendingLock.withLock { drainTimedOut }
        }
        if timedOut {
            let stuck = pendingLock.withLock { pendingCaptures.count }
            Self.logger.error("Timed out waiting for in-flight captures: \(stuck, privacy: .public) remaining")
        }
    }

    // MARK: - Locking

    /// Converges focus, exposure and white balance once, then freezes all three.
    ///
    /// This matters more than it sounds. Refocusing between shots causes focus
    /// breathing — the effective focal length shifts, so the intrinsics the solver
    /// assumes no longer match the image. Drifting exposure and white balance change
    /// the appearance of the same physical point from frame to frame, which is
    /// exactly what feature matching is trying to rely on. A turntable keeps the
    /// subject at a fixed distance, so there is nothing to gain from tracking.
    ///
    /// - Parameter completion: called once the settings are locked, or immediately if
    ///   the device cannot lock.
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

            // One-shot converge on the centre of the frame, where the object is.
            let centre = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = centre }
            if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = centre }
            if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
            if device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
                device.whiteBalanceMode = .autoWhiteBalance
            }
            device.unlockForConfiguration()

            // Wait for convergence before freezing, otherwise a blurry focus gets
            // locked in. Polled rather than observed: bounded, and this queue is
            // already serial.
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

            Self.logger.info("Focus, exposure, and white balance locked")
            completion(true)
        }
    }

    // MARK: - Capture

    func capture() {
        sessionQueue.async { [weak self] in
            self?.captureAttempt(0)
        }
    }

    /// One capture attempt, on `sessionQueue`. `captureReadiness` is honored:
    /// `.notReady` is transitional (e.g. mid-reconfiguration), so the attempt is
    /// retried briefly rather than dropped silently or fired into a busy pipeline.
    private func captureAttempt(_ attempt: Int) {
        guard session.isRunning else { return }

        guard photoOutput.captureReadiness == .ready else {
            if attempt < 3 {
                sessionQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.captureAttempt(attempt + 1)
                }
            } else {
                onShotRejected(String(localized: "Camera busy — shot skipped"))
            }
            return
        }

        let settings: AVCapturePhotoSettings
        if usesHEVC {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }

        if maxDimensions.width > 0 {
            settings.maxPhotoDimensions = maxDimensions
        }
        settings.photoQualityPrioritization = .quality

        if photoOutput.isDepthDataDeliveryEnabled {
            settings.isDepthDataDeliveryEnabled = true
            // Embedding rather than handling depth separately means
            // `PhotogrammetrySession` picks it up straight from the file, and
            // the existing folder-based reconstruction path stays untouched.
            settings.embedsDepthDataInPhoto = true
        }

        // A small preview accompanies the full-resolution photo and is what the
        // sharpness check runs on — measuring 48 MP would cost far more than the
        // decision is worth.
        if let previewFormat = settings.availablePreviewPhotoPixelFormatTypes.first {
            settings.previewPhotoFormat = [
                kCVPixelBufferPixelFormatTypeKey as String: previewFormat,
                kCVPixelBufferWidthKey as String: 512,
                kCVPixelBufferHeightKey as String: 384,
            ]
        }

        shotIndex += 1
        let index = shotIndex
        let takenAt = Date()
        let destination = imagesDirectory
            .appending(path: fileName(forShot: index), directoryHint: .notDirectory)

        // Lifted out before the closure: `AVCapturePhotoSettings` is not
        // `Sendable`, but its id is a plain `Int64`.
        let settingsID = settings.uniqueID

        // The photo output invokes the delegate on its own callback queue, while
        // `capture()` runs on `sessionQueue`: funnel the result through
        // `sessionQueue` so `shotIndex` and `sharpnessReference` are only ever
        // touched on one thread. The delegate stays retained in
        // `pendingCaptures` until its terminal `didFinishCaptureFor` fires —
        // that is the signal the output's internal pipeline has drained.
        // If the coordinator is gone (cancel() tore the session down) the
        // capture is definitionally late: its bytes must never land on disk.
        let delegate = PhotoDelegate(destination: destination, takenAt: takenAt, shouldDiscard: { [weak self] in
            self?.shouldDiscardLateCapture() ?? true
        }) { [weak self] result in
            guard let self else { return }
            self.sessionQueue.async { [weak self] in
                guard let self else { return }
                let waiters: [CheckedContinuation<Void, Never>] = self.pendingLock.withLock {
                    self.pendingCaptures[settingsID] = nil
                    guard self.pendingCaptures.isEmpty else { return [] }
                    defer { self.drainWaiters.removeAll() }
                    return self.drainWaiters
                }
                self.handle(result: result, index: index, destination: destination)
                for waiter in waiters { waiter.resume() }
            }
        }

        pendingLock.withLock {
            pendingCaptures[settingsID] = delegate
        }

        // Swift cannot catch the NSException that
        // -capturePhotoWithSettings:delegate: throws for invalid settings —
        // it would SIGABRT the app (builds 1-3, TestFlight 2026-10-18).
        // The ObjC guard converts a rejected settings combination into a
        // rejected shot, and its error carries the exception's name and
        // reason so the offending combination gets logged, not lost.
        if let requestError = PhotoCaptureGuard.capturePhoto(with: photoOutput,
                                                             settings: settings,
                                                             delegate: delegate) {
            pendingLock.withLock { pendingCaptures[settingsID] = nil }
            Self.logger.error("Photo request rejected: \(requestError.localizedDescription, privacy: .public)")
            onShotRejected(String(localized: "Couldn't start frame \(index): \(requestError.localizedDescription)"))
            return
        }
    }

    private func handle(result: Result<PhotoDelegate.Capture, Error>, index: Int, destination: URL) {
        retryPendingCleanup()
        switch result {
        case .failure(let error):
            // A capture discarded by PhotoDelegate resolved after the session
            // moved on: its bytes were never written, so there is nothing to
            // report — dropping it silently, not as a user-visible rejection.
            if case ScanEngineError.cancelled = error {
                Self.logger.debug("Discarding late capture #\(index, privacy: .public): session moved on before its delegate fired")
                return
            }
            // Per-frame failure: reported through the rejection channel, never
            // the session-level `onFailure`. One bad frame must not invalidate
            // the session or the captures still in flight.
            onShotRejected(String(localized: "Couldn't save frame \(index): \(error.localizedDescription)"))

        case .success(let capture):
            guard let sharpness = capture.sharpness else {
                // No usable preview to judge; keeping the frame beats guessing.
                consecutiveRejections = 0
                onShotSaved(index, capture.takenAt, nil)
                return
            }

            // Exponential moving maximum: the reference tracks the recent best
            // but decays, so one anomalously sharp frame — or dimming light
            // afterwards — can't reject everything for the rest of the session.
            // (Apple's own sharpest-in-sequence guidance likewise ranks
            // relatively within a sequence, never against a fixed global floor.)
            sharpnessReference = max(sharpness, sharpnessReference * referenceDecay)

            let floor = consecutiveRejections >= maxConsecutiveRejections ? relaxedFloor : sharpnessFloor
            if sharpnessReference > 0, sharpness < sharpnessReference * floor {
                // Discarded on purpose: a soft frame contributes wrong matches, and
                // the auto-capture loop will cover this angle again shortly. The
                // index is deliberately NOT reused — with captures in flight, a
                // reused number could be handed to two different shots and one file
                // would overwrite the other. Gaps in the numbering are harmless.
                consecutiveRejections += 1
                let cleanup = deleteRejectedFile(at: destination)
                Self.logger.debug("Blurry frame dropped: \(sharpness, privacy: .public) / \(self.sharpnessReference, privacy: .public)")
                var reason = String(localized: "Blurry frame skipped — rotate more slowly")
                if cleanup == .kept {
                    // The solver enumerates every non-dotfile in the images
                    // directory, so a leftover would be re-ingested. Say so
                    // loudly rather than silently shipping a soft frame.
                    reason += " " + String(localized: "(cleanup failed — frame kept)")
                }
                onShotRejected(reason)
            } else {
                consecutiveRejections = 0
                onShotSaved(index, capture.takenAt, sharpness)
            }
        }
    }

    /// Outcome of removing a blur-rejected frame. The solver enumerates every
    /// non-dotfile in the images directory, so only `.gone` and `.quarantined`
    /// keep a rejected frame out of the reconstruction.
    private enum RejectedFileCleanup {
        case gone
        case quarantined
        case kept
    }

    /// Files a blur rejection couldn't remove — quarantine dotfiles whose
    /// later deletion is still pending, and files where even quarantine
    /// failed. Retried on subsequent capture results and at stop: transient
    /// failures (spotlight/AV locks) often clear within seconds, and a
    /// leftover would otherwise be committed to the user's library by the
    /// engine. SessionQueue-confined.
    private var pendingCleanup: [URL] = []

    /// Removes a blur-rejected frame. If deletion fails, the file is renamed
    /// with a dot prefix instead: the solver skips dotfiles, so a rejected
    /// frame can't be re-ingested even though its bytes are still on disk.
    private func deleteRejectedFile(at url: URL) -> RejectedFileCleanup {
        let path = url.path(percentEncoded: false)
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return .gone }
        for _ in 0..<2 where fm.fileExists(atPath: path) {
            try? fm.removeItem(at: url)
        }
        guard fm.fileExists(atPath: path) else { return .gone }
        let quarantined = url.deletingLastPathComponent()
            .appending(path: "." + url.lastPathComponent, directoryHint: .notDirectory)
        if (try? fm.moveItem(at: url, to: quarantined)) != nil, !fm.fileExists(atPath: path) {
            Self.logger.error("Couldn't delete rejected frame; quarantined as dotfile: \(quarantined.lastPathComponent, privacy: .public)")
            pendingCleanup.append(quarantined)
            return .quarantined
        }
        Self.logger.error("Couldn't delete rejected frame: \(url.lastPathComponent, privacy: .public)")
        pendingCleanup.append(url)
        return .kept
    }

    /// Best-effort deletion of files left behind by failed cleanups. Called on
    /// sessionQueue for every capture result and at stop; entries that still
    /// won't delete stay listed for the next attempt.
    private func retryPendingCleanup() {
        guard !pendingCleanup.isEmpty else { return }
        let fm = FileManager.default
        let before = pendingCleanup.count
        pendingCleanup.removeAll { url in
            let path = url.path(percentEncoded: false)
            guard fm.fileExists(atPath: path) else { return true }
            try? fm.removeItem(at: url)
            return !fm.fileExists(atPath: path)
        }
        let cleared = before - pendingCleanup.count
        if cleared > 0 {
            Self.logger.info("Cleaned up \(cleared, privacy: .public) previously quarantined frame(s)")
        }
    }
}

/// One-shot photo delegate: writes the file, scores its preview and reports back.
///
/// Completion is delivered exactly once, from the terminal
/// `didFinishCaptureFor` callback — that is the photo output's end-of-pipeline
/// signal, so the coordinator retains the delegate until then to implement a
/// true drain. `didFinishProcessingPhoto` only computes and stores the result.
private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    struct Capture {
        var takenAt: Date
        var sharpness: Float?
    }

    private let destination: URL
    private let takenAt: Date
    /// Checked on the photo output's callback queue before the file is
    /// written: when true, the capture resolved after the session moved on
    /// and its bytes must not land on disk.
    private let shouldDiscard: @Sendable () -> Bool
    private let completion: @Sendable (Result<Capture, Error>) -> Void
    private let stateLock = NSLock()
    private var processingResult: Result<Capture, Error>?
    private var didComplete = false

    init(destination: URL, takenAt: Date, shouldDiscard: @escaping @Sendable () -> Bool, completion: @escaping @Sendable (Result<Capture, Error>) -> Void) {
        self.destination = destination
        self.takenAt = takenAt
        self.shouldDiscard = shouldDiscard
        self.completion = completion
        super.init()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let result: Result<Capture, Error>
        if shouldDiscard() {
            // The session moved on while this capture was in flight: finish()'s
            // drain returned with this delegate still outstanding, or cancel()
            // tore the session down. Writing now would orphan a file with no
            // yaw entry — or land after the reconstruction input was already
            // enumerated. The coordinator drops this silently (see handle).
            result = .failure(ScanEngineError.cancelled)
        } else if let error {
            // Per-callback error param — a failing frame, not a failing session.
            result = .failure(error)
        } else if let data = photo.fileDataRepresentation() {
            let sharpness = photo.previewPixelBuffer.flatMap(SharpnessMeter.score)
            do {
                try data.write(to: destination, options: .atomic)
                result = .success(Capture(takenAt: takenAt, sharpness: sharpness))
            } catch {
                result = .failure(error)
            }
        } else {
            result = .failure(PhotoCaptureCoordinator.SetupError.noPhotoData)
        }
        stateLock.withLock { processingResult = result }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        let result: Result<Capture, Error>? = stateLock.withLock {
            guard !didComplete else { return nil }
            didComplete = true
            if let processingResult { return processingResult }
            // Processing never produced a result (early failure): surface the
            // terminal error rather than hanging the drain.
            if let error { return .failure(error) }
            return .failure(PhotoCaptureCoordinator.SetupError.noPhotoData)
        }
        if let result { completion(result) }
    }
}
