import RealityKit
// Cross-import overlay: `ObjectCaptureSession` needs both modules in scope.
import SwiftUI

extension ObjectCaptureSession.Feedback {
    /// Turkish coaching line, or nil for feedback not worth interrupting the user
    /// with. Returning nil matters: surfacing every hint at once turns the overlay
    /// into noise and people stop reading it.
    var hint: String? {
        switch self {
        case .objectTooFar:
            String(localized: "Objeye yaklaşın")
        case .objectTooClose:
            String(localized: "Biraz uzaklaşın")
        case .movingTooFast:
            String(localized: "Daha yavaş hareket ettirin")
        case .environmentTooDark:
            String(localized: "Ortam çok karanlık — ışık ekleyin")
        case .environmentLowLight:
            String(localized: "Işık yetersiz, detay kaybolabilir")
        case .outOfFieldOfView:
            String(localized: "Objeyi kadraja alın")
        case .objectNotFlippable:
            String(localized: "Bu obje çevrilerek taranamaz — yörüngeye devam edin")
        case .overCapturing:
            nil
        default:
            nil
        }
    }
}

extension ObjectCaptureSession.Tracking {
    var isReliable: Bool {
        if case .normal = self { return true }
        return false
    }

    /// Tracking loss is the single most common cause of a warped mesh, so it gets
    /// a distinct message from the framing hints.
    var warning: String? {
        switch self {
        case .normal:
            nil
        case .notAvailable:
            String(localized: "Konum takibi yok — cihazı hareket ettirip yeniden deneyin")
        case .limited(let reason):
            switch reason {
            case .initializing: nil
            case .relocalizing: String(localized: "Konum yeniden bulunuyor — yavaş hareket edin")
            case .excessiveMotion: String(localized: "Çok hızlı hareket — yavaşlayın")
            case .insufficientFeatures: String(localized: "Ortamda yeterli doku yok — dokulu bir zemin kullanın")
            @unknown default: String(localized: "Konum takibi zayıf")
            }
        @unknown default:
            nil
        }
    }
}
