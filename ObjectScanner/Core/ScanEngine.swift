import Foundation

/// The contract both capture modes fulfil.
///
/// Kept deliberately thin. The two engines have very different *interaction*
/// models — photogrammetry needs a bounding box and multiple passes, a depth
/// engine needs a turntable rig — so their views differ. What must stay common
/// is lifecycle, coarse progress, and the `ScanRecord` they hand back.
@MainActor
protocol ScanEngine: AnyObject {
    static var kind: ScanEngineKind { get }

    /// Resolved at runtime, never from a hardcoded device list — those go stale
    /// with every hardware generation.
    static var availability: EngineAvailability { get }

    var phase: ScanPhase { get }

    /// Begin capture. Throws if the engine can't acquire the sensor.
    func start() throws

    /// Stop capture and produce the model. The returned record is already persisted.
    func finish() async throws -> ScanRecord

    /// Tear down without producing a record. Safe to call in any phase.
    func cancel()
}

enum EngineAvailability: Equatable, Sendable {
    case available
    case notImplementedYet
    case unsupportedDevice(reason: String)

    var isUsable: Bool { self == .available }

    var blockedReason: String? {
        switch self {
        case .available: nil
        case .notImplementedYet: String(localized: "Bu mod henüz gelmedi (Faz 2).")
        case .unsupportedDevice(let reason): reason
        }
    }
}

/// Coarse lifecycle, shared by both engines so the shell UI can show progress
/// without knowing which engine is running.
enum ScanPhase: Equatable, Sendable {
    case idle
    case preparing
    /// Sensors are live but object detection has not started. The user aims at the
    /// object and confirms — detection cannot begin before the camera feed is on
    /// screen, so this is a real step rather than a loading state.
    case readyToDetect
    /// Engine is asking the user to frame the object (bounding box, distance).
    case framing
    case capturing(shots: Int, limit: Int)
    case reconstructing(ReconstructionProgress)
    case done(ScanRecord)
    case failed(message: String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .done, .failed, .cancelled: true
        default: false
        }
    }
}

enum ScanEngineError: LocalizedError {
    case sessionUnavailable(String)
    case reconstructionFailed(String)
    case noImagesCaptured
    case cancelled

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable(let detail):
            "Tarama oturumu başlatılamadı: \(detail)"
        case .reconstructionFailed(let detail):
            "Model oluşturulamadı: \(detail)"
        case .noImagesCaptured:
            String(localized: "Hiç görüntü yakalanmadı. Taramayı tekrar deneyin.")
        case .cancelled:
            "Tarama iptal edildi."
        }
    }
}
