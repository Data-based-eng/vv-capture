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
    /// a jittering "1:23 left" reads as broken.
    var remainingText: String? {
        guard let estimatedRemaining, estimatedRemaining > 5 else { return nil }
        let minutes = Int(estimatedRemaining) / 60
        switch minutes {
        case 0: return String(localized: "Less than a minute")
        case 1...2: return String(localized: "about \(minutes + 1) minutes")
        default: return String(localized: "about \(minutes) minutes")
        }
    }
}

/// The pipeline stages photogrammetry moves through, in order.
///
/// Showing these beats a bare percentage: a 4-minute run that sits at 40% looks
/// stuck, whereas "Generating point cloud" reads as working.
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
        case .preProcessing: String(localized: "Preparing images")
        case .imageAlignment: String(localized: "Solving camera poses")
        case .pointCloudGeneration: String(localized: "Generating point cloud")
        case .meshGeneration: String(localized: "Extracting mesh")
        case .textureMapping: String(localized: "Placing texture")
        case .optimization: String(localized: "Optimizing model")
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
