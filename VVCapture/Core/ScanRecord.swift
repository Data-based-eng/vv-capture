import Foundation

/// A finished scan, as persisted in the library.
///
/// Deliberately stores a *relative* file name rather than an absolute URL: the
/// app container path changes between installs, so absolute URLs go stale and
/// every model in the library silently 404s. `ScanStorage` resolves the real URL.
struct ScanRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    let engine: ScanEngineKind

    /// File name inside the scan's own directory, e.g. `model.usdz`.
    let modelFileName: String

    /// True when the geometry carries real-world dimensions. Photogrammetry gets
    /// this from LiDAR; a pure-photo reconstruction would not.
    let isMetricallyScaled: Bool

    /// How many stills fed the reconstruction (nil for depth-based engines).
    let imageCount: Int?

    /// Physical bounding box in millimetres, when the engine knows it. The
    /// fastest way to sanity-check metric scale — compare it against a ruler.
    var dimensionsMillimetres: [Int]?

    /// Reconstruction detail the model was built at. Photogrammetry only.
    let detail: ReconstructionDetail?

    /// One-line description of what the model contains, when the engine can say
    /// something more useful than a file size. Optional, so records written
    /// before this existed still decode.
    var summary: String?

    /// True when the file is a mesh Quick Look can render. Point clouds are not,
    /// so the library has to fall back to a stats view instead of a preview.
    var isPreviewable: Bool {
        modelFileName.hasSuffix(".usdz")
    }

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        engine: ScanEngineKind,
        modelFileName: String = "model.usdz",
        isMetricallyScaled: Bool,
        imageCount: Int? = nil,
        dimensionsMillimetres: [Int]? = nil,
        detail: ReconstructionDetail? = nil,
        summary: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.engine = engine
        self.modelFileName = modelFileName
        self.isMetricallyScaled = isMetricallyScaled
        self.imageCount = imageCount
        self.dimensionsMillimetres = dimensionsMillimetres
        self.detail = detail
        self.summary = summary
    }
}

/// Mesh density the model was reconstructed at.
///
/// `PhotogrammetrySession.Request.Detail` declares `medium`, `full` and `raw`
/// **only on macOS**. The iOS SDK exposes `reduced` alone, so on-device
/// reconstruction cannot produce a high-poly mesh at any setting — the Mac
/// target adds the higher levels, which is the entire reason it exists.
///
/// The path to full detail is to move the captured stills to a Mac — hence
/// `SourceImageBundle`, and hence keeping the images after reconstruction.
enum ReconstructionDetail: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The only level iOS offers for on-device photogrammetry.
    case reduced
#if os(macOS)
    /// Higher polygon counts, offered by PhotogrammetrySession on macOS only.
    case medium
    case full
    case raw
#endif

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .reduced: String(localized: "On-device (reduced)")
#if os(macOS)
        case .medium: String(localized: "Medium")
        case .full: String(localized: "Full")
        case .raw: String(localized: "Raw (undecimated)")
#endif
        }
    }

    var explanation: String {
        switch self {
        case .reduced:
            String(localized: "The only level iOS supports for on-device photogrammetry. Transfer the source images to a Mac for higher polygon counts.")
#if os(macOS)
        case .medium:
            String(localized: "Higher polygon count than reduced. A good balance of detail and speed.")
        case .full:
            String(localized: "Full-resolution mesh. Slow — best on Apple silicon.")
        case .raw:
            String(localized: "Undecimated raw mesh. Very slow and very large — for inspection, not sharing.")
#endif
        }
    }
}
