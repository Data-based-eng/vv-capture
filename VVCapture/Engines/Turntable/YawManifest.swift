import Foundation
import os

/// Per-shot yaw sidecar: `yaw.jsonl` at the workspace root, one JSON object
/// per line, written as shots land.
///
/// θ is filled by the yaw estimator where one runs (video path). Every entry
/// always carries the capture timestamp and file name, so a downstream tool
/// can derive θ = ω·Δt once the turntable RPM is known. The on-disk contract
/// is documented in the README ("### `yaw.jsonl`"); `YawEntry` is its schema.
struct YawEntry: Codable, Sendable {
    /// 1-based shot index in the shared capture sequence, matching
    /// `shot_%06d.<ext>` — `.heic` for stills, `.jpg` for extracted video
    /// frames. Unique across stills and video frames within one scan.
    let shot: Int
    let file: String
    let timestamp: Date
    /// Yaw in degrees, clockwise looking down at the turntable. Nil until the
    /// estimator fills it in.
    let thetaDeg: Double?
    /// How thetaDeg was produced: "timestamp" (estimator pending), "marker",
    /// "vision", "rpm". The video frame extractor maps its internal strings
    /// onto this vocabulary before appending (see `manifestMethod` in
    /// VideoFrameExtractor).
    let method: String
    /// Gradient-energy sharpness score from capture, when measured.
    let sharpness: Float?
}

/// Append-only writer (plus a read-back for tooling) for a scan's `yaw.jsonl`.
final class YawManifest: Sendable {
    private static let logger = Logger(subsystem: "com.visionvend.capture", category: "yaw-manifest")

    private let url: URL
    private let lock = NSLock()
    /// Held open for the manifest's lifetime with O_APPEND: the kernel
    /// positions every write at end-of-file, so the old seek-then-write race —
    /// a silently failed seek landing the next write at offset 0 and clobbering
    /// valid JSON lines — is impossible, not merely guarded. -1 when the open
    /// failed; appends then no-op (the failure is logged once, in init).
    /// Immutable after init, which is what keeps the `Sendable` conformance
    /// sound: every post-init access (append under `lock`, close in `deinit`)
    /// only reads it.
    private let fd: Int32

    init(directory: URL) {
        url = directory.appending(path: "yaw.jsonl", directoryHint: .notDirectory)
        let opened: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        }
        if opened < 0 {
            Self.logger.error("Couldn't open yaw manifest for appending — yaw entries will be lost")
        }
        fd = opened
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    func append(shot: Int, file: String, takenAt: Date, thetaDeg: Double?, method: String, sharpness: Float?) {
        let entry = YawEntry(
            shot: shot, file: file, timestamp: takenAt,
            thetaDeg: thetaDeg, method: method, sharpness: sharpness
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else {
            Self.logger.error("Couldn't encode yaw entry for shot \(shot, privacy: .public)")
            return
        }
        var line = data
        line.append(0x0A) // '\n'
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return } // open failure already logged in init
        let ok: Bool = line.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            var written = 0
            while written < buffer.count {
                let n = Darwin.write(fd, base.advanced(by: written), buffer.count - written)
                guard n > 0 else { return false }
                written += n
            }
            return true
        }
        if !ok {
            Self.logger.error("Couldn't write yaw entry for shot \(shot, privacy: .public)")
        }
    }

    /// Reads every entry back. Malformed lines are skipped with a log — one bad
    /// line must not nuke the manifest. Intended for downstream tooling (e.g.
    /// RPM backfill); nothing in the capture path calls this yet.
    func load() throws -> [YawEntry] {
        // Snapshot under the lock, parse outside it: decoding the snapshot
        // needs no synchronization, and a large manifest shouldn't block
        // appends while every line is decoded.
        let text = try readSnapshot()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [YawEntry] = []
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let data = rawLine.data(using: .utf8) else { continue }
            do {
                entries.append(try decoder.decode(YawEntry.self, from: data))
            } catch {
                Self.logger.warning("Skipping malformed yaw.jsonl line \(index, privacy: .public)")
            }
        }
        return entries
    }

    /// Reads the whole file while holding the lock. The caller parses the
    /// returned snapshot without the lock held.
    private func readSnapshot() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
