import Foundation

/// The contract the capture engine fulfils.
///
/// Kept deliberately thin. What must stay common is lifecycle, coarse
/// progress, and the `ScanRecord` handed back.
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
    case unsupportedDevice(reason: String)

    var isUsable: Bool { self == .available }

    var blockedReason: String? {
        switch self {
        case .available: nil
        case .unsupportedDevice(let reason): reason
        }
    }
}

/// Coarse lifecycle, so the shell UI can show progress without knowing
/// engine internals.
enum ScanPhase: Equatable, Sendable {
    case idle
    case preparing
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
            "Couldn't start the scan session: \(detail)"
        case .reconstructionFailed(let detail):
            "Couldn't create the model: \(detail)"
        case .noImagesCaptured:
            String(localized: "No images were captured. Try the scan again.")
        case .cancelled:
            "Scan cancelled."
        }
    }
}
