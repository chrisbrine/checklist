import Darwin
import Foundation
import GRDB
import SQLite3

/// Periodic WAL housekeeping outside the router's writer and object gate.
/// The writer still uses synchronous=FULL for each acknowledged commit.
final class WALCheckpointLane: @unchecked Sendable {
    private static let checkpointPages: Int32 = 1_000
    private let queue = DispatchQueue(label: "org.checklist.wal-checkpoint", qos: .utility)
    private let connection: DatabaseQueue
    private let admission: StorageAdmission
    private let files: StorageObjectFiles
    private let serviceLease: StorageServiceLease?
    private let database: FileIdentity
    private let observe: (@Sendable (Int32, Int32, Int32) -> Void)?
    private let lock = NSLock()
    private var enqueued = false
    private var pending = false
    private var stopped = false

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ files: StorageObjectFiles) throws {
            try files.requireNamedRoot(files.root)
            var entry = stat()
            guard fstatat(files.descriptor, "checklist.sqlite", &entry, AT_SYMLINK_NOFOLLOW) == 0,
                  entry.st_mode & S_IFMT == S_IFREG, entry.st_nlink == 1 else {
                throw StoreRecovery.required("wal_checkpoint_database_unavailable")
            }
            device = entry.st_dev
            inode = entry.st_ino
        }
    }

    // Separate-connection checkpoints can race a WAL reset on older SQLite.
    // Leave the runtime's existing inline hook there, including vendor backports
    // whose patch identity we cannot establish from the version alone.
    static func supportsConcurrentCheckpoint(sqliteVersion: Int32) -> Bool { sqliteVersion >= 3_051_003 }

    init?(files: StorageObjectFiles, incarnation: String, admission: StorageAdmission, serviceLease: StorageServiceLease? = nil,
          observe: (@Sendable (Int32, Int32, Int32) -> Void)? = nil) throws {
        guard Self.supportsConcurrentCheckpoint(sqliteVersion: sqlite3_libversion_number()) else { return nil }
        let database = try FileIdentity(files)
        var configuration = Configuration()
        configuration.qos = .utility
        configuration.prepareDatabase { db in
            try SchemaMigrations.installStorageCollation(db)
            try db.execute(sql: "PRAGMA synchronous=FULL; PRAGMA busy_timeout=0")
        }
        let connection = try DatabaseQueue(path: StorageBootstrap.writableURI(files.root.appendingPathComponent("checklist.sqlite")),
                                           configuration: configuration)
        let matches = try connection.unsafeRead { db in
            try Self.isAtNamedPath(db) && String.fetchOne(db, sql: "PRAGMA journal_mode") == "wal" &&
                String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='incarnation'") == incarnation
        }
        guard matches, try FileIdentity(files) == database else {
            throw StoreRecovery.required("wal_checkpoint_database_identity_changed")
        }
        self.connection = connection
        self.admission = admission
        self.files = files
        self.serviceLease = serviceLease
        self.database = database
        self.observe = observe
    }

    private static func isAtNamedPath(_ db: Database) -> Bool {
        var moved: Int32 = 0
        return sqlite3_file_control(db.sqliteConnection, "main", SQLITE_FCNTL_HAS_MOVED, &moved) == SQLITE_OK && moved == 0
    }

    func install(on writer: Database) -> Bool {
        guard Self.isAtNamedPath(writer), (try? FileIdentity(files)) == database else { return false }
        sqlite3_wal_hook(writer.sqliteConnection, { context, _, database, frames in
            if frames >= WALCheckpointLane.checkpointPages, let context, let database, strcmp(database, "main") == 0 {
                Unmanaged<WALCheckpointLane>.fromOpaque(context).takeUnretainedValue().request()
            }
            // SQLite has already committed. Never turn a checkpoint notification
            // into a failure of the committed command.
            return SQLITE_OK
        }, Unmanaged.passUnretained(self).toOpaque())
        Self.log(["scope":"sqlite_checkpoint_lane", "state":"ready", "sqlite_version":sqlite3_libversion_number()])
        return true
    }

    func remove(from writer: Database) {
        sqlite3_wal_autocheckpoint(writer.sqliteConnection, Self.checkpointPages)
    }

    func request() {
        let first = lock.withLock {
            guard !stopped else { return false }
            pending = true
            guard !enqueued else { return false }
            enqueued = true
            return true
        }
        if first { schedule(attempt: 0) }
    }

    private func schedule(attempt: Int) {
        // A pinned reader gets a bounded retry after 1, 2 and 4 seconds.
        // New commits coalesce and get another turn even during the checkpoint.
        queue.asyncAfter(deadline: .now() + .milliseconds(500 << attempt)) { [weak self] in
            self?.run(attempt: attempt)
        }
    }

    private func run(attempt: Int) {
        let running = lock.withLock {
            pending = false
            return !stopped
        }
        guard running else { return }
        let incomplete = checkpoint()
        let next = lock.withLock { () -> Int? in
            if !stopped {
                if pending { return 0 }
                if incomplete, attempt < 3 { return attempt + 1 }
            }
            enqueued = false
            return nil
        }
        if let next { schedule(attempt: next) }
    }

    private func checkpoint() -> Bool {
        guard let lease = try? admission.acquire() else { return false }
        defer { lease.finish() }
        do { try serviceLease?.requireRoot(files.root) }
        catch { return false }
        guard (try? FileIdentity(files)) == database else { return false }
        let started = ProcessInfo.processInfo.systemUptime
        let startedAt = Date()
        var frames: Int32 = -1, checkpointed: Int32 = -1
        let result = connection.writeWithoutTransaction { db -> Int32 in
            guard Self.isAtNamedPath(db) else { return SQLITE_CANTOPEN }
            let watchdog = ServiceHoldWatchdog.shared
            let hold = watchdog.begin(resource:"wal_checkpoint",work:"sqlite_checkpoint_passive")
            defer { watchdog.end(hold) }
            return sqlite3_wal_checkpoint_v2(db.sqliteConnection, "main", SQLITE_CHECKPOINT_PASSIVE, &frames, &checkpointed)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        observe?(result, frames, checkpointed)
        var load = [Double](repeating: 0, count: 3)
        let count = getloadavg(&load, 3)
        Self.log(["scope":"sqlite_checkpoint_passive", "started_at":StoredClock.shared.string(from:startedAt),
                  "duration_ms":elapsed*1_000, "loadavg":Array(load.prefix(max(0, Int(count)))),
                  "result_code":result, "frames":frames, "checkpointed_frames":checkpointed])
        return result == SQLITE_BUSY || (result == SQLITE_OK && checkpointed < frames)
    }

    func close() throws {
        lock.withLock { stopped = true }
        // An already enqueued delayed block checks stopped before using the connection.
        try queue.sync { try connection.close() }
    }

    private static func log(_ row: JSON) {
        guard ProcessInfo.processInfo.environment["CHECKLIST_TIMING"] == "1",
              let encoded = try? jsonString(row) else { return }
        fputs("ChecklistTiming \(encoded)\n", stderr)
    }
}
