import Foundation
import GRDB

/// Pins the source read snapshot while writes are fenced, then copies from that
/// transaction after releasing the writer. The caller still owns the object
/// gate, and snapshot retention continues to protect its managed namespace.
enum StorageDatabaseCapture {
    static func copy(source root: URL, destination path: URL, configuration: Configuration,
                     intentSize: Int64, budget: StorageSnapshotBudget) throws -> String {
        let writer = try DatabaseQueue(path: StorageBootstrap.writableURI(root.appendingPathComponent("checklist.sqlite")), configuration: configuration)
        defer { try? writer.close() }
        let capturedAt = try writer.writeWithoutTransaction { lease -> String in
            try lease.beginTransaction(.immediate)
            let leaseStarted = budget.uptime()
            var leaseActive = true
            defer {
                if leaseActive {
                    try? lease.rollback()
                    budget.measurement.writerLeaseSeconds = budget.uptime() - leaseStarted
                }
            }
            try budget.notify("writer_lease_acquired")
            var readConfiguration = Configuration(); readConfiguration.readonly = true
            readConfiguration.prepareDatabase { db in try SchemaMigrations.installStorageCollation(db); try db.execute(sql: "PRAGMA busy_timeout=50") }
            let source = try DatabaseQueue(path: root.appendingPathComponent("checklist.sqlite").path, configuration: readConfiguration)
            defer { try? source.close() }
            return try source.read { snapshot in
                let pageSize = try Int64.fetchOne(snapshot, sql: "PRAGMA page_size") ?? 0
                guard pageSize > 0 else { throw StorageSnapshotFailure.incomplete }
                // BEGIN DEFERRED alone does not select a WAL end mark. This
                // actual read pins it before the writer fence is rolled back.
                _ = try Int.fetchOne(snapshot, sql: "SELECT COUNT(*) FROM sqlite_schema")
                let capturedAt = now()
                try lease.rollback()
                leaseActive = false
                budget.measurement.writerLeaseSeconds = budget.uptime() - leaseStarted
                try budget.notify("writer_lease_released")
                let destination = try DatabaseQueue(path: path.path, configuration: configuration)
                var sawDone = false
                var callbackFailure: Error?
                do {
                    try destination.writeWithoutTransaction { copy in
                        try snapshot.backup(to: copy, pagesPerStep: budget.pagesPerStep) { progress in
                            if progress.isCompleted { sawDone = true }
                            do {
                                try budget.notify(progress.isCompleted ? "backup_done" : "backup_step")
                                try budget.check()
                                let bound = Int64(progress.totalPageCount).multipliedReportingOverflow(by: pageSize)
                                guard !bound.overflow else { throw StorageSnapshotFailure.limit }
                                _ = try budget.adding(bound.partialValue, to: intentSize)
                            } catch { callbackFailure = error; throw error }
                        }
                    }
                    // GRDB ignores a throw from the completed callback.
                    try budget.check()
                    if let callbackFailure { throw callbackFailure }
                    guard sawDone else { throw StorageSnapshotFailure.incomplete }
                    try destination.close()
                } catch { try? destination.close(); throw error }
                return capturedAt
            }
        }
        try writer.close()
        return capturedAt
    }
}
