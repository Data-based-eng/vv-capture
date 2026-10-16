import Foundation

/// Per-shot yaw sidecar: `yaw.jsonl` at the workspace root, one JSON object
/// per line, written as shots land.
///
/// \u03b8 is filled by the yaw estimator (ArUco marker on the turntable edge).
/// Until that lands, every entry carries the capture timestamp and file name,
/// so \u03b8 backfills as \u03c9\u00b7\u0394t once the turntable RPM is known —
/// which is exactly what the panorama builder and the 4DGS-style splat stage
/// need to place each frame.
struct YawEntry: Codable {
    /// 1-based shot index, matching `shot_%04d.heic`.
    var shot: Int
    var file: String
    var timestamp: Date
    /// Yaw in degrees, clockwise looking down at the turntable. Nil until the
    /// estimator (or an RPM-derived backfill) fills it in.
    var thetaDeg: Double?
    /// How thetaDeg was produced: "timestamp" (estimator pending), "marker",
    /// "vision", "rpm".
    var method: String
    /// Gradient-energy sharpness score from capture, when measured.
    var sharpness: Float?
}

final class YawManifest: Sendable {
    private let url: URL
    private let lock = NSLock()

    init(directory: URL) {
        url = directory.appending(path: "yaw.jsonl", directoryHint: .notDirectory)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        }
    }

    func append(shot: Int, file: String, takenAt: Date, thetaDeg: Double?, method: String, sharpness: Float?) {
        let entry = YawEntry(
            shot: shot, file: file, timestamp: takenAt,
            thetaDeg: thetaDeg, method: method, sharpness: sharpness
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        handle.write(data)
        handle.write(Data("\n".utf8))
    }
}
