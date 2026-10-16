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

    /// Region of every frame that contains the object, in 0…1 image coordinates.
    ///
    /// Valid only because the device is stationary: the object sits in the same part
    /// of every frame, so one rectangle masks the whole set. This is what keeps a
    /// close or textured background out of the model.
    var objectMaskRect: CGRect?

    var session: AVCaptureSession? { coordinator?.session }

    var canFinish: Bool { shotCount >= Self.minimumShots }

    // MARK: - Private

    private let storage: ScanStorage
    private let reconstructor = PhotogrammetryReconstructor()
    private var coordinator: PhotoCaptureCoordinator?
    private var workspace: ScanWorkspace?
    private var yawManifest: YawManifest?
    private var autoCaptureTask: Task<Void, Never>?

    init(storage: ScanStorage) {
        self.storage = storage
    }

    // MARK: - ScanEngine

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

        phase = .capturing(shots: 0, limit: 0)
    }

    func finish() async throws -> ScanRecord {
        guard let coordinator, let workspace else {
            throw ScanEngineError.sessionUnavailable("No active session.")
        }

        stopAutoCapture()
        coordinator.stop()

        guard shotCount > 0 else {
            phase = .failed(message: String(localized: "No photos were taken."))
            throw ScanEngineError.noImagesCaptured
        }

        let capturedShots = shotCount
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
            phase = .failed(message: error.localizedDescription)
            throw error
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
        storage.commit(record, workspace: workspace)

        teardown()
        phase = .done(record)
        return record
    }

    func cancel() {
        stopAutoCapture()
        coordinator?.stop()
        teardown()
        if let workspace {
            storage.discard(workspace)
            self.workspace = nil
        }
        phase = .cancelled
    }

    // MARK: - Capture control

    /// Freezes focus, exposure and white balance. Called before the first shot
    /// rather than left on automatic: drifting between frames is what breaks the
    /// solve, and a turntable holds the subject at a fixed distance anyway.
    func lockCameraSettings() {
        guard lockState != .locking else { return }
        lockState = .locking
        coordinator?.lockCameraSettings { [weak self] success in
            Task { @MainActor in
                self?.isLocked = success
                self?.lockState = success ? .locked : .failed
            }
        }
    }

    func captureNow() {
        coordinator?.capture()
    }

    func toggleAutoCapture() {
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

    // MARK: - Private

    private func shotSaved(_ index: Int, takenAt: Date, sharpness: Float?) {
        shotCount = index
        captureError = nil
        // \u03b8 itself is filled by the yaw estimator (ArUco marker on the
        // turntable edge). Until then the timestamp is the source of truth —
        // \u03b8 backfills as \u03c9\u00b7\u0394t once the RPM is known.
        yawManifest?.append(
            shot: index,
            file: String(format: "shot_%04d.heic", index),
            takenAt: takenAt,
            thetaDeg: nil,
            method: "timestamp",
            sharpness: sharpness
        )
        if case .capturing = phase {
            phase = .capturing(shots: index, limit: 0)
        }
    }

    private func teardown() {
        stopAutoCapture()
        coordinator = nil
        yawManifest = nil
        captureError = nil
    }

    private static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "d MMM HH:mm"
        return "Scan \(formatter.string(from: date))"
    }
}
