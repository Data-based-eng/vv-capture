import Foundation

/// The capture technology. Exactly one: turntable photogrammetry with the
/// device fixed and the object rotating.
///
/// The enum survives (rather than being deleted) because `ScanRecord` persists
/// it and downstream UI reads its maturity badge.
enum ScanEngineKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Photogrammetry with the device fixed and the object rotating.
    case turntable

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .turntable: String(localized: "Turntable")
        }
    }

    var tagline: String {
        switch self {
        case .turntable: String(localized: "Rear camera \u{2022} object rotates \u{2022} phone fixed")
        }
    }

    var symbolName: String {
        switch self {
        case .turntable: "arrow.trianglehead.clockwise.rotate.90"
        }
    }

    var isImplemented: Bool { true }

    var producesMesh: Bool { true }

    /// Solving poses from images alone, with no world tracking to lean on, is
    /// the weakest link: it fails on featureless objects and on backgrounds
    /// that move with the subject.
    var maturity: Maturity { .beta }

    enum Maturity: Sendable {
        case stable
        case beta

        /// Nil when there is nothing worth flagging.
        var badge: String? {
            switch self {
            case .stable: nil
            case .beta: "beta"
            }
        }
    }
}
