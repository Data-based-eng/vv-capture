import Foundation
import ModelIO
import os

enum MeshExportFormat: String, CaseIterable, Identifiable, Sendable {
    /// The reconstructor's native output — geometry plus material, no conversion.
    case usdz
    case obj
    case ply
    case stl

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .usdz: "USDZ"
        case .obj: "OBJ"
        case .ply: "PLY"
        case .stl: "STL"
        }
    }

    var explanation: String {
        switch self {
        case .usdz: String(localized: "Apple ecosystem, AR Quick Look. Source format — no conversion.")
        case .obj: String(localized: "Common interchange format. Blender, MeshLab, ZBrush.")
        case .ply: String(localized: "Point cloud / mesh, geometry-focused tools.")
        case .stl: String(localized: "3D printing. Geometry only, no materials.")
        }
    }

    /// Whether the conversion drops surface appearance. Worth surfacing in the UI
    /// even for a geometry-first workflow, so nobody is surprised later.
    var isGeometryOnly: Bool {
        switch self {
        case .usdz, .obj: false
        case .ply, .stl: true
        }
    }
}

enum MeshExportError: LocalizedError {
    case sourceMissing
    case formatUnsupported(MeshExportFormat)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            String(localized: "Model file not found.")
        case .formatUnsupported(let format):
            "\(format.displayName) bu cihazda desteklenmiyor."
        case .conversionFailed(let detail):
            "Conversion failed: \(detail)"
        }
    }
}

enum MeshExporter {
    private static let logger = Logger(subsystem: "com.visionvend.capture", category: "export")

    /// Converts a reconstructed USDZ into `format`, returning a temporary file
    /// ready to hand to a share sheet.
    ///
    /// Conversion runs off the main actor — a full-detail mesh is large enough
    /// that ModelIO will visibly hitch the UI otherwise.
    static func export(
        modelAt sourceURL: URL,
        as format: MeshExportFormat,
        namedLike baseName: String
    ) async throws -> URL {

        guard FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
            throw MeshExportError.sourceMissing
        }

        let safeName = baseName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let fileName = safeName.isEmpty ? "model" : safeName

        // No work to do for the native format; copying keeps the share sheet's
        // filename consistent with the other formats.
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "\(fileName).\(format.rawValue)", directoryHint: .notDirectory)
        try? FileManager.default.removeItem(at: destination)

        if format == .usdz {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return destination
        }

        guard MDLAsset.canExportFileExtension(format.rawValue) else {
            throw MeshExportError.formatUnsupported(format)
        }

        try await Task.detached(priority: .userInitiated) {
            let asset = MDLAsset(url: sourceURL)
            guard asset.count > 0 else {
                throw MeshExportError.conversionFailed("Kaynak modelde geometri yok.")
            }
            do {
                try asset.export(to: destination)
            } catch {
                throw MeshExportError.conversionFailed(error.localizedDescription)
            }
        }.value

        logger.info("Exported: \(format.rawValue, privacy: .public)")
        return destination
    }
}
