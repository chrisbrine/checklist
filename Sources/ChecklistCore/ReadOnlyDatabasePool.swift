import Foundation
import GRDB

/// Readers never wait for a replacement pool. A failed open schedules one retry
/// at a time, on a lane that owns neither the command queue nor the writer.
final class ReadOnlyDatabasePool: @unchecked Sendable {
    private let lock = NSLock()
    private let openingQueue = DispatchQueue(label:"org.checklist.reader-open",qos:.utility)
    private let database: URL
    private var opened: DatabasePool?
    private var opening = false
    private var closed = false
    private var retryAfter: DispatchTime = .now()

    init(root: URL) {
        database = root.appendingPathComponent("checklist.sqlite")
        if !CommandRouter.disableReaderPoolForTesting {
            opened = try? Self.open(database)
        }
    }

    var current: DatabasePool? {lock.withLock {opened}}

    func retryOpen() {
        let shouldOpen = lock.withLock {
            guard opened == nil, !opening, !closed, .now() >= retryAfter,
                  !CommandRouter.disableReaderPoolForTesting else {return false}
            opening = true
            return true
        }
        guard shouldOpen else {return}
        openingQueue.async { [self] in
            let replacement = try? Self.open(database)
            let adopted = lock.withLock {
                opening = false
                retryAfter = .now() + .seconds(1)
                guard !closed else {return false}
                opened = replacement
                return true
            }
            if !adopted {try? replacement?.close()}
        }
    }

    func close() throws {
        let pool = lock.withLock {
            closed = true
            let pool = opened
            opened = nil
            return pool
        }
        openingQueue.sync {}
        try pool?.close()
    }

    private static func open(_ database: URL) throws -> DatabasePool {
        try DatabasePool(path:database.path,configuration:configuration())
    }

    static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in
            try SchemaMigrations.installStorageCollation(db)
            CommandRouter.installTicketSearchFunctions(db)
            // The WAL snapshot can coexist with a writer. If SQLite itself
            // cannot start a read (for example during recovery), surface it
            // immediately instead of inheriting the writer's busy timeout.
            try db.execute(sql:"PRAGMA busy_timeout=0")
        }
        return configuration
    }
}

extension CommandRouter {
    /// Long maintenance scans have a separate connection and leave the
    /// request reader pool available. Open it while the store is admitted.
    func openMaintenanceReader() throws -> DatabaseQueue {
        try DatabaseQueue(path:root.appendingPathComponent("checklist.sqlite").path,
                          configuration:ReadOnlyDatabasePool.configuration())
    }

    func readOnMaintenanceConnection<T>(_ body: (Database) throws -> T) throws -> T {
        let reader = try openMaintenanceReader()
        defer { try? reader.close() }
        return try reader.read(body)
    }

    func readerUnavailable() -> CoreError {
        readerPool.retryOpen()
        return CoreError("READ_LANE_UNAVAILABLE","The store reader is opening. Retry the read.",details:["retryable":true])
    }
}
