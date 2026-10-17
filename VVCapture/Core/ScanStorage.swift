import Foundation
import Observation
import os

/// The directory tree for a single in-progress scan.
///
/// Every engine gets one of these and writes only inside it, so a failed or
/// cancelled scan is cleaned up by deleting one folder.
struct ScanWorkspace: Sendable {
    let id: UUID
    let root: URL

    /// Captured stills. Photogrammetry reads the whole directory.
    var imagesURL: URL { root.appending(path: "images", directoryHint: .isDirectory) }

    /// Reconstruction scratch space. Letting RealityKit checkpoint here means a
    /// backgrounded or crashed reconstruction can resume instead of restarting.
    var checkpointURL: URL { root.appending(path: "checkpoint", directoryHint: .isDirectory) }

    var modelURL: URL { root.appending(path: "model.usdz", directoryHint: .notDirectory) }

    /// Turntable video take. The frame extractor reads this; the stills path
    /// ignores it.
    var videoURL: URL { root.appending(path: "video.mp4", directoryHint: .notDirectory) }

    /// The yaw sidecar written by `YawManifest`.
    var yawURL: URL { root.appending(path: "yaw.jsonl", directoryHint: .notDirectory) }
}

/// Errors surfaced by `ScanStorage` instead of being log-and-swallowed.
enum ScanStorageError: LocalizedError {
    /// The library root couldn't be created at launch.
    case rootUnavailable(Error)
    /// `library.json` couldn't be durably written.
    case persistFailed(Error)
    /// A workspace directory couldn't be removed.
    case cleanupFailed(Error)
    /// No library record for the id.
    case scanNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .rootUnavailable(let error):
            "The scan library couldn't be opened: \(error.localizedDescription)"
        case .persistFailed(let error):
            "The scan library couldn't be saved: \(error.localizedDescription)"
        case .cleanupFailed(let error):
            "Scan files couldn't be deleted: \(error.localizedDescription)"
        case .scanNotFound(let id):
            "No scan with id \(id.uuidString) in the library."
        }
    }
}

/// Owns the on-disk scan library.
@MainActor
@Observable
final class ScanStorage {
    private static let logger = Logger(subsystem: "com.visionvend.capture", category: "storage")

    private(set) var scans: [ScanRecord] = []

    /// Set when the library root couldn't be created at launch. The store is
    /// degraded (the library reads as empty and writes throw); surfaced here
    /// and fault-logged instead of limping silently.
    private(set) var initializationError: Error?

    private let fileManager = FileManager.default
    private let scansRoot: URL
    private let libraryFile: URL

    init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        scansRoot = documents.appending(path: "Scans", directoryHint: .isDirectory)
        libraryFile = scansRoot.appending(path: "library.json", directoryHint: .notDirectory)
        do {
            try fileManager.createDirectory(at: scansRoot, withIntermediateDirectories: true)
        } catch {
            // A storage layer that can't reach its root must fail loudly, not limp.
            Self.logger.fault("Couldn't create scan library root: \(error.localizedDescription, privacy: .public)")
            initializationError = ScanStorageError.rootUnavailable(error)
            return
        }
        if load() {
            sweepOrphanedWorkspaces()
        }
    }

    // MARK: - Library

    /// Loads the library. Returns false when the on-disk library exists but is
    /// unreadable — the in-memory records can't be trusted, so the caller must
    /// not sweep (a corrupt or unreadable `library.json` must never trigger
    /// mass deletion of scan directories).
    private func load() -> Bool {
        guard fileManager.fileExists(atPath: libraryFile.path(percentEncoded: false)) else { return true }
        guard let data = try? Data(contentsOf: libraryFile) else {
            Self.logger.error("Library file exists but couldn't be read — skipping orphan sweep")
            return false
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([ScanRecord].self, from: data)
            // Drop records whose model file vanished — a stale row that opens to
            // nothing is worse than no row.
            scans = decoded.filter { fileManager.fileExists(atPath: modelURL(for: $0).path(percentEncoded: false)) }
            if scans.count != decoded.count {
                do {
                    try persist()
                } catch {
                    // In-memory state is already consistent; only the rewrite failed.
                    Self.logger.error("Couldn't rewrite library after dropping stale records: \(error.localizedDescription, privacy: .public)")
                }
            }
            return true
        } catch {
            Self.logger.error("Couldn't read library: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Atomic write: a crash during the write leaves the old or the new
    /// complete file, never a truncated one.
    private func persist() throws {
        if let initializationError { throw initializationError }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            try encoder.encode(scans).write(to: libraryFile, options: .atomic)
        } catch {
            Self.logger.error("Couldn't write library: \(error.localizedDescription, privacy: .public)")
            throw ScanStorageError.persistFailed(error)
        }
    }

    /// Launch-time orphan sweep: a crash or kill between `makeWorkspace()` and
    /// `commit()` leaves a full workspace no record points at. The OS gives no
    /// guarantee of purging it, so the app does — every UUID-named directory
    /// under the scans root with no matching library record is deleted.
    private func sweepOrphanedWorkspaces() {
        let liveIDs = Set(scans.map(\.id))
        guard let names = try? fileManager.contentsOfDirectory(atPath: scansRoot.path(percentEncoded: false)) else { return }
        for name in names {
            guard let id = UUID(uuidString: name), !liveIDs.contains(id) else { continue }
            let dir = scansRoot.appending(path: name, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: dir.path(percentEncoded: false), isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }
            do {
                try fileManager.removeItem(at: dir)
                Self.logger.info("Swept orphaned workspace \(name, privacy: .public)")
            } catch {
                Self.logger.fault("Couldn't sweep orphaned workspace \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Workspaces

    func makeWorkspace() throws -> ScanWorkspace {
        let id = UUID()
        let workspace = ScanWorkspace(id: id, root: scansRoot.appending(path: id.uuidString, directoryHint: .isDirectory))
        do {
            try fileManager.createDirectory(at: workspace.imagesURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: workspace.checkpointURL, withIntermediateDirectories: true)
            // GB-scale capture data must not ride along in device backups.
            // (The flag is per-item and doesn't inherit — files created later
            // get flagged by `excludeWorkspaceTreeFromBackup` at commit.)
            excludeFromBackup(workspace.root)
            excludeFromBackup(workspace.imagesURL)
            excludeFromBackup(workspace.checkpointURL)
        } catch {
            // Don't leak a half-created directory on the way out.
            try? fileManager.removeItem(at: workspace.root)
            throw error
        }
        return workspace
    }

    /// Best-effort removal. Failures are fault-logged — callers treat discard
    /// as "it's gone", so a silent no-op would be a lie.
    @discardableResult
    func discard(_ workspace: ScanWorkspace) -> Bool {
        guard fileManager.fileExists(atPath: workspace.root.path(percentEncoded: false)) else { return true }
        do {
            try fileManager.removeItem(at: workspace.root)
            return true
        } catch {
            Self.logger.fault("Couldn't discard workspace \(workspace.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Registers a finished scan. The model must already sit at `workspace.modelURL`.
    ///
    /// On success the bulky reconstruction inputs (`video.mp4`, `checkpoint/`)
    /// are deleted — nothing reads them after commit and each is GB-scale. The
    /// stills stay: they feed the full-detail Mac path (`SourceImageBundle`),
    /// as does `yaw.jsonl` (downstream pipeline contract, see README).
    ///
    /// - Throws: `ScanStorageError.persistFailed` (or the root error, when
    ///   degraded) when the library record can't be durably written. The
    ///   in-memory insert is rolled back and the workspace is removed, so
    ///   neither a phantom record nor an orphaned workspace is left behind.
    ///   Callers (both engines' `finish()`) must propagate with `try`.
    func commit(_ record: ScanRecord, workspace: ScanWorkspace) throws {
        precondition(record.id == workspace.id, "Record and workspace identifiers must match")
        scans.insert(record, at: 0)
        do {
            try persist()
        } catch {
            scans.removeAll { $0.id == record.id }
            discard(workspace) // failure already fault-logged inside
            throw error
        }
        // The record is durable; strip what nothing reads post-commit.
        // Cleanup failures here must not fail the commit — the scan is safely
        // in the library — but they are fault-logged, not swallowed.
        removeIfPresent(workspace.videoURL)
        removeIfPresent(workspace.checkpointURL)
        excludeWorkspaceTreeFromBackup(workspace)
    }

    /// Deletes a scan: library record first, workspace second. If the app dies
    /// between the two, the launch-time sweep treats the record-less directory
    /// as an orphan and removes it — the intermediate state is tolerated, not
    /// just unlikely.
    ///
    /// - Throws: `ScanStorageError.scanNotFound` when `id` isn't in the
    ///   library; `ScanStorageError.persistFailed` when the record removal
    ///   can't be durably written (the in-memory removal is rolled back, so
    ///   the scan is fully intact); `ScanStorageError.cleanupFailed` when the
    ///   workspace can't be removed (the record is already gone; the next
    ///   launch's orphan sweep finishes the job).
    func deleteScan(id: UUID) throws {
        guard let index = scans.firstIndex(where: { $0.id == id }) else {
            throw ScanStorageError.scanNotFound(id)
        }
        let record = scans[index]
        scans.remove(at: index)
        do {
            try persist()
        } catch {
            scans.insert(record, at: index)
            throw error
        }
        do {
            try fileManager.removeItem(at: directoryURL(for: record))
        } catch {
            Self.logger.fault("Couldn't remove workspace for deleted scan \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public) — the orphan sweep will retry at next launch")
            throw ScanStorageError.cleanupFailed(error)
        }
    }

    // MARK: - Records

    func directoryURL(for record: ScanRecord) -> URL {
        scansRoot.appending(path: record.id.uuidString, directoryHint: .isDirectory)
    }

    func modelURL(for record: ScanRecord) -> URL {
        directoryURL(for: record).appending(path: record.modelFileName, directoryHint: .notDirectory)
    }

    // MARK: - Private helpers

    /// Best-effort removal of an expected-but-optional path. Missing is fine;
    /// a real failure is fault-logged.
    private func removeIfPresent(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            Self.logger.fault("Couldn't remove \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Marks a path excluded from device backups. Best-effort: exclusion
    /// failing must not fail a capture, but it is logged.
    private func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        do {
            try mutableURL.setResourceValues(values)
        } catch {
            Self.logger.error("Couldn't exclude \(url.lastPathComponent, privacy: .public) from backup: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Backup exclusion doesn't inherit: files created after the workspace
    /// directories were flagged (`model.usdz`, `yaw.jsonl`) need the flag too.
    /// One recursive pass at commit covers everything the session created.
    private func excludeWorkspaceTreeFromBackup(_ workspace: ScanWorkspace) {
        excludeFromBackup(workspace.root)
        guard let enumerator = fileManager.enumerator(at: workspace.root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator {
            excludeFromBackup(url)
        }
    }
}
