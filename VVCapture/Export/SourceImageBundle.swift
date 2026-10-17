import Foundation
import os

/// Zips a scan's captured stills so they can be reconstructed on a Mac.
///
/// This exists because of a hard platform limit, not as a nice-to-have: the iOS
/// SDK only offers `PhotogrammetrySession.Request.Detail.reduced`, while macOS
/// adds `medium`, `full` and `raw`. Same photos, same framework, higher-poly
/// mesh — the only way to get full detail out of a photogrammetry scan.
enum SourceImageBundle {
    private static let logger = Logger(subsystem: "com.visionvend.capture", category: "bundle")

    enum BundleError: LocalizedError {
        case imagesMissing
        case zipFailed(String)

        var errorDescription: String? {
            switch self {
            case .imagesMissing:
                String(localized: "Source images were deleted. You'll need to re-scan the object for full detail.")
            case .zipFailed(let detail):
                String(localized: "Couldn't create archive: \(detail)")
            }
        }
    }

    /// - Returns: a temporary `.zip` ready for a share sheet, AirDrop or Files.
    static func makeArchive(imagesDirectory: URL, named baseName: String) async throws -> URL {
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(atPath: imagesDirectory.path(percentEncoded: false))) ?? []
        guard !contents.isEmpty else { throw BundleError.imagesMissing }

        let safeName = baseName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let destination = fileManager.temporaryDirectory
            .appending(path: "\(safeName.isEmpty ? "scan" : safeName)-images.zip", directoryHint: .notDirectory)

        try await Task.detached(priority: .userInitiated) {
            try zip(directory: imagesDirectory, to: destination)
        }.value

        logger.info("Archive ready: \(contents.count, privacy: .public) images")
        return destination
    }

    /// `NSFileCoordinator`'s `.forUploading` option is the only zip writer in the
    /// iOS SDK. It hands back a temporary archive that is valid *only* inside the
    /// accessor block, so the copy has to happen there.
    private static func zip(directory: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        var didProduce = false

        NSFileCoordinator().coordinate(
            readingItemAt: directory,
            options: [.forUploading],
            error: &coordinationError
        ) { temporaryArchive in
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: temporaryArchive, to: destination)
                didProduce = true
            } catch {
                copyError = error
            }
        }

        if let coordinationError { throw BundleError.zipFailed(coordinationError.localizedDescription) }
        if let copyError { throw BundleError.zipFailed(copyError.localizedDescription) }
        guard didProduce else { throw BundleError.zipFailed(String(localized: "Couldn't write the archive.")) }
    }

    /// Pasted next to the share button — the Mac side is four lines of code and
    /// nobody should have to go looking for them.
    static let macInstructions = """
        With the tool in this project:

        swiftc -O -parse-as-library Tools/Reconstruct.swift -o /tmp/reconstruct
        /tmp/reconstruct ~/Downloads/frames ~/Desktop/model.usdz raw

        detail: macOS offers .medium / .full / .raw, iOS only .reduced.
        """
}
