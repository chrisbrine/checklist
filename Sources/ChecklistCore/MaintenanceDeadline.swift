import Foundation
import GRDB
import SQLite3

struct MaintenanceStepDeferred: Error {}

/// A monotonic deadline shared by gate and writer. Leave headroom for SQLite
/// rollback after an interrupt. A filesystem syscall can still overshoot it.
struct MaintenanceDeadline {
    private let end: DispatchTime

    init(seconds: TimeInterval = 0.2) {
        end = .now() + max(0, seconds)
    }

    func check() throws {
        guard DispatchTime.now() < end else { throw MaintenanceStepDeferred() }
    }

    func transaction<T>(_ db: Database, _ body: () throws -> T) throws -> T {
        try check()
        var value: T?
        try db.inTransaction(.immediate) {
            try check()
            value = try body()
            try check()
            return .commit
        }
        return value!
    }

    func withSQLite<T>(_ db: Database, _ body: () throws -> T) throws -> T {
        try check()
        let connection = db.sqliteConnection
        // BEGIN, COMMIT and SQLite's lock acquisition can all invoke the busy
        // handler without executing opcodes. Maintenance yields on contention.
        sqlite3_busy_timeout(connection, 0)
        defer { sqlite3_busy_timeout(connection, StorageBootstrap.writerBusyTimeoutMS) }
        var uptime = end.uptimeNanoseconds
        return try withUnsafeMutablePointer(to: &uptime) { pointer in
            sqlite3_progress_handler(connection, 100, { context in
                guard let context else { return 1 }
                return DispatchTime.now().uptimeNanoseconds >= context.load(as: UInt64.self) ? 1 : 0
            }, pointer)
            defer { sqlite3_progress_handler(connection, 0, nil, nil) }
            return try body()
        }
    }
}

extension CommandRouter {
    /// Backup admission and foreground writer work get priority over a routine
    /// step. A deferred attempt has no writer queue reservation.
    func withMaintenanceWriter<T>(label: String, deadline: MaintenanceDeadline = .init(),
                                  _ body: (Database, MaintenanceDeadline) throws -> T) throws -> T? {
        guard backupWrites.admitWithoutQueue() else { return nil }
        defer { backupWrites.finishWrite() }
        return try dbQueue.tryMaintenanceWrite(label: label, deadline: deadline, body)
    }

    /// Admission may inspect the backup queue. Acquire it before the archive
    /// gate so the gate cannot be held behind backup journal publication.
    func withMaintenanceGateAndWriter<T>(label: String,
                                         _ body: (Database, ArchiveStoragePermit, MaintenanceDeadline) throws -> T) throws -> T? {
        guard backupWrites.admitWithoutQueue() else { return nil }
        defer { backupWrites.finishWrite() }
        return try ArchiveStorageGate.withMaintenanceAccess(root: root, work: label) { permit, deadline in
            try dbQueue.tryMaintenanceWrite(label: label, deadline: deadline) { db, deadline in
                try body(db, permit, deadline)
            }
        } ?? nil
    }
}
