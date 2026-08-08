import Foundation
import simd
import os

/// Reads and writes the binary PLY files this app produces.
///
/// PLY rather than USDZ because a points-only USDZ renders as nothing in Quick
/// Look, and the cloud's destination is MeshLab, CloudCompare or Blender. Binary
/// rather than ASCII because a scan easily reaches a few hundred thousand points,
/// where ASCII costs roughly 4× the bytes.
///
/// The reader only handles the exact layout `write` emits — this is a round-trip
/// for our own files, not a general PLY parser.
enum PointCloudFile {
    private static let logger = Logger(subsystem: "com.example.ObjectScanner", category: "pointcloud")

    enum FileError: LocalizedError {
        case empty
        case malformedHeader
        case truncated

        var errorDescription: String? {
            switch self {
            case .empty: String(localized: "Nokta bulutu boş — kaydedilecek veri yok.")
            case .malformedHeader: String(localized: "PLY başlığı okunamadı.")
            case .truncated: String(localized: "PLY dosyası eksik.")
            }
        }
    }

    // MARK: - Write

    static func write(points: [SIMD3<Float>], to url: URL) throws {
        guard !points.isEmpty else { throw FileError.empty }

        var header = "ply\n"
        header += "format binary_little_endian 1.0\n"
        header += "comment ObjectScanner TrueDepth\n"
        header += "element vertex \(points.count)\n"
        header += "property float x\n"
        header += "property float y\n"
        header += "property float z\n"
        header += "end_header\n"

        var data = Data(header.utf8)
        data.reserveCapacity(data.count + points.count * 12)

        // Written component-wise: `SIMD3<Float>` is 16-byte aligned, so dumping the
        // raw buffer would emit a padding word per point and produce a file no
        // reader can parse.
        for point in points {
            for component in [point.x, point.y, point.z] {
                withUnsafeBytes(of: component.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
        }

        try data.write(to: url, options: .atomic)
        logger.info("PLY yazıldı: \(points.count, privacy: .public) nokta")
    }

    // MARK: - Read

    static func read(from url: URL) throws -> [SIMD3<Float>] {
        let data = try Data(contentsOf: url)

        // Scan for the header terminator rather than decoding the whole file as
        // text — the payload after it is binary and not valid UTF-8.
        guard let terminator = "end_header\n".data(using: .utf8),
              let headerRange = data.range(of: terminator)
        else { throw FileError.malformedHeader }

        guard let header = String(data: data[data.startIndex..<headerRange.upperBound], encoding: .utf8) else {
            throw FileError.malformedHeader
        }

        guard let vertexLine = header
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("element vertex ") }),
            let count = Int(vertexLine.dropFirst("element vertex ".count))
        else { throw FileError.malformedHeader }

        let payload = data[headerRange.upperBound...]
        guard payload.count >= count * 12 else { throw FileError.truncated }

        var points = [SIMD3<Float>]()
        points.reserveCapacity(count)

        payload.withUnsafeBytes { raw in
            for index in 0..<count {
                let offset = index * 12
                let x = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                let y = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)))
                let z = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self)))
                points.append(SIMD3<Float>(x, y, z))
            }
        }

        return points
    }
}
