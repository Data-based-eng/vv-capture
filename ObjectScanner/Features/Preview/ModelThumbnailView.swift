import QuickLookThumbnailing
import SwiftUI

/// Rendered preview of a USDZ, for library rows and grids.
///
/// Uses Quick Look's thumbnail service rather than loading the mesh into a
/// RealityKit scene: it renders out of process, so a heavy model cannot stall the
/// scroll, and the system caches the result across launches.
struct ModelThumbnailView: View {
    let url: URL
    var side: CGFloat = 56

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if didFail {
                Image(systemName: "cube.transparent")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: url) {
            image = await ThumbnailStore.shared.thumbnail(
                for: url,
                side: side,
                scale: displayScale
            )
            didFail = image == nil
        }
    }
}

/// In-memory cache on top of Quick Look's own.
///
/// Needed because `.task(id:)` re-fires whenever a row is recycled, and without
/// this a long library re-requests thumbnails on every scroll pass.
@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    private var cache: [URL: UIImage] = [:]
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private init() {}

    func thumbnail(for url: URL, side: CGFloat, scale: CGFloat) async -> UIImage? {
        if let hit = cache[url] { return hit }
        if let running = inFlight[url] { return await running.value }

        let task = Task<UIImage?, Never> {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: side, height: side),
                scale: scale,
                representationTypes: .thumbnail
            )
            do {
                let representation = try await QLThumbnailGenerator.shared
                    .generateBestRepresentation(for: request)
                return representation.uiImage
            } catch {
                return nil
            }
        }
        inFlight[url] = task

        let result = await task.value
        inFlight[url] = nil
        if let result { cache[url] = result }
        return result
    }

    /// Called on delete so a re-used URL cannot serve a stale render.
    func invalidate(_ url: URL) {
        cache[url] = nil
        inFlight[url]?.cancel()
        inFlight[url] = nil
    }
}
