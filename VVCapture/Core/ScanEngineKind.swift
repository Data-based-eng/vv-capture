import Foundation

/// The capture technology. Exactly one: turntable photogrammetry with the
/// device fixed and the object rotating.
///
/// The enum survives (rather than being deleted) because `ScanRecord` persists
/// it and the engine protocol requires it.
enum ScanEngineKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Photogrammetry with the device fixed and the object rotating.
    case turntable

    var id: String { rawValue }
}
