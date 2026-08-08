import Foundation
import RoomPlan

/// Which USD representation RoomPlan writes.
///
/// The two are genuinely different products, not quality levels, which is why
/// this is a user choice rather than a constant: `parametric` gives clean boxes
/// derived from the *understood* room, `mesh` gives the raw surface RoomPlan
/// measured. Neither is a superset of the other.
enum RoomExportStyle: String, CaseIterable, Identifiable, Sendable {
    /// Walls, doors, windows and furniture as tidy primitives.
    case parametric
    /// The reconstructed triangle mesh of the actual surfaces.
    case mesh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parametric: String(localized: "Mimari")
        case .mesh: String(localized: "Ham yüzey")
        }
    }

    var explanation: String {
        switch self {
        case .parametric:
            String(localized: "Duvar, kapı, pencere ve mobilya temiz kutular olarak çıkar. Dosya küçük, Blender'da düzenlemesi kolay — kat planı ve ölçü almak için doğru seçim.")
        case .mesh:
            String(localized: "LiDAR'ın gerçekten ölçtüğü yüzey üçgen ağı olarak çıkar. Girinti, çıkıntı ve dağınıklık korunur; dosya daha büyük ve geometri düzensiz olur.")
        }
    }

    var options: CapturedRoom.USDExportOptions {
        switch self {
        case .parametric: .parametric
        case .mesh: .mesh
        }
    }
}
