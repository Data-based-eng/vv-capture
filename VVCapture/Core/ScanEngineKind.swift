import Foundation

/// The capture technology: turntable (device fixed, object rotating) or phone
/// orbit (object fixed, device walked around it).
///
/// The enum survives (rather than being deleted) because `ScanRecord` persists
/// it and the engine protocol requires it.
enum ScanEngineKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Photogrammetry with the device fixed and the object rotating.
    case turntable
    /// Photogrammetry with the object fixed and the device orbited around it.
    case orbit
#if os(macOS)
    /// macOS folder/video import: no camera — stills in, high-detail mesh out.
    case macImport
#endif

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .turntable: String(localized: "Turntable")
        case .orbit: String(localized: "Phone orbit")
#if os(macOS)
        case .macImport: String(localized: "Mac import")
#endif
        }
    }

    var tagline: String {
        switch self {
        case .turntable: String(localized: "Product spins, phone stays put.")
        case .orbit: String(localized: "Product stays put, walk around it.")
#if os(macOS)
        case .macImport: String(localized: "Folder or video in, high-detail mesh out.")
#endif
        }
    }
}
