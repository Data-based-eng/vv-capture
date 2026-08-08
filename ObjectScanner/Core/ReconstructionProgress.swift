import Foundation

/// Reconstruction state as reported by `PhotogrammetrySession`.
///
/// The session emits progress on two separate outputs — `.requestProgress` carries
/// the fraction, `.requestProgressInfo` carries the stage and a time estimate —
/// and they interleave. This struct is the merged view of both.
struct ReconstructionProgress: Equatable, Sendable {
    var fraction: Double = 0
    var stage: ReconstructionStage?
    var estimatedRemaining: TimeInterval?

    /// Formatted countdown, or nil while the session has no estimate yet.
    /// Deliberately coarse: the underlying estimate swings by tens of seconds and
    /// a jittering "1:23 kaldı" reads as broken.
    var remainingText: String? {
        guard let estimatedRemaining, estimatedRemaining > 5 else { return nil }
        let minutes = Int(estimatedRemaining) / 60
        switch minutes {
        case 0: return String(localized: "1 dakikadan az")
        case 1...2: return String(localized: "yaklaşık \(minutes + 1) dakika")
        default: return String(localized: "yaklaşık \(minutes) dakika")
        }
    }
}

/// The pipeline stages photogrammetry moves through, in order.
///
/// Showing these beats a bare percentage: a 4-minute run that sits at 40% looks
/// stuck, whereas "Nokta bulutu oluşturuluyor" reads as working.
enum ReconstructionStage: Int, Equatable, Sendable, CaseIterable, Identifiable {
    case preProcessing
    case imageAlignment
    case pointCloudGeneration
    case meshGeneration
    case textureMapping
    case optimization

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .preProcessing: String(localized: "Görüntüler hazırlanıyor")
        case .imageAlignment: String(localized: "Kamera pozları çözülüyor")
        case .pointCloudGeneration: String(localized: "Nokta bulutu oluşturuluyor")
        case .meshGeneration: String(localized: "Mesh çıkarılıyor")
        case .textureMapping: String(localized: "Texture yerleştiriliyor")
        case .optimization: String(localized: "Model optimize ediliyor")
        }
    }

    var symbolName: String {
        switch self {
        case .preProcessing: "photo.stack"
        case .imageAlignment: "camera.metering.matrix"
        case .pointCloudGeneration: "aqi.medium"
        case .meshGeneration: "grid"
        case .textureMapping: "paintbrush"
        case .optimization: "wand.and.sparkles"
        }
    }

    /// The stage most of the wall-clock goes into, worth a reassuring note.
    var isLongRunning: Bool {
        self == .imageAlignment || self == .meshGeneration
    }
}
