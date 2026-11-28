import Foundation
import GRDB

/// Core's synchronous transaction boundary. Database handles stay inside the
/// macOS persistence implementation; this is not a portable SQL contract.
/// Storage admission, archive gates and command authority remain with callers.
protocol TransactionStorage: AnyObject, Sendable {
    func read<T>(work: String, _ value: (Database) throws -> T) throws -> T
    func write<T>(work: String, _ updates: (Database) throws -> T) throws -> T
    func writeWithoutTransaction<T>(work: String, _ updates: (Database) throws -> T) rethrows -> T
    func tryMaintenanceWrite<T>(label: String, deadline: MaintenanceDeadline,
                                _ updates: (Database, MaintenanceDeadline) throws -> T) throws -> T?
    func close() throws
}

extension TransactionStorage {
    func read<T>(_ value: (Database) throws -> T, work: String = #function) throws -> T {
        try read(work: work, value)
    }
    func write<T>(_ updates: (Database) throws -> T, work: String = #function) throws -> T {
        try write(work: work, updates)
    }
    func writeWithoutTransaction<T>(_ updates: (Database) throws -> T, work: String = #function) rethrows -> T {
        try writeWithoutTransaction(work: work, updates)
    }
}

/// Adapts the queue already opened and qualified by StorageBootstrap. Opening,
/// schema migration, protected backup and recovery are deliberately not repeated.
final class GRDBTransactionAdapter: TransactionStorage, @unchecked Sendable {
    private enum MaintenanceTurn { case idle, reserved, running }
    private let queue: DatabaseQueue
    // The condition protects admission state. GRDB owns SQLite serialization.
    private let priority = NSCondition()
    private let beforeMaintenanceEntry: (@Sendable () -> Void)?
    private let beforeForegroundWait: (@Sendable () -> Void)?
    private var foreground = 0
    private var maintenance = MaintenanceTurn.idle

    init(queue: DatabaseQueue, beforeMaintenanceEntry: (@Sendable () -> Void)? = nil,
         beforeForegroundWait: (@Sendable () -> Void)? = nil) {
        self.queue = queue
        self.beforeMaintenanceEntry = beforeMaintenanceEntry
        self.beforeForegroundWait = beforeForegroundWait
    }

    func read<T>(work: String, _ value: (Database) throws -> T) throws -> T {
        let label = ServiceHoldWatchdog.workLabel(fallback: work)
        return try withForeground {
            try queue.read { db in try measure(label) { try value(db) } }
        }
    }

    func write<T>(work: String, _ updates: (Database) throws -> T) throws -> T {
        try writeWithoutTransaction(work: work) { db in
            var result: T?
            try db.inTransaction {
                result = try updates(db)
                return .commit
            }
            return result!
        }
    }

    func writeWithoutTransaction<T>(work: String, _ updates: (Database) throws -> T) rethrows -> T {
        let label = ServiceHoldWatchdog.workLabel(fallback: work)
        return try withForeground {
            try queue.writeWithoutTransaction { db in
                try measure(label) { try updates(db) }
            }
        }
    }

    func tryMaintenanceWrite<T>(label: String, deadline: MaintenanceDeadline,
                                _ updates: (Database, MaintenanceDeadline) throws -> T) throws -> T? {
        let admitted = priority.withLock {
            guard foreground == 0, maintenance == .idle else { return false }
            maintenance = .reserved
            return true
        }
        guard admitted else { return nil }
        defer {
            priority.withLock {
                maintenance = .idle
                priority.broadcast()
            }
        }
        beforeMaintenanceEntry?()
        do {
            return try queue.writeWithoutTransaction { db in
                let canRun = priority.withLock {
                    // Foreground callers register before enqueueing. Yield
                    // if one arrived while this reservation entered GRDB.
                    maintenance = .running
                    priority.broadcast()
                    return foreground == 0
                }
                guard canRun else { return nil }
                return try measure(label) {
                    try deadline.withSQLite(db) { try updates(db, deadline) }
                }
            }
        } catch is MaintenanceStepDeferred { return nil }
        catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_INTERRUPT { return nil }
    }

    private func withForeground<T>(_ body: () throws -> T) rethrows -> T {
        priority.lock()
        foreground += 1
        // Keep a foreground callback from occupying GRDB between the idle
        // check and maintenance admission. It gets the next writer turn.
        if maintenance == .reserved, let beforeForegroundWait {
            priority.unlock()
            beforeForegroundWait()
            priority.lock()
        }
        while maintenance == .reserved { priority.wait() }
        priority.unlock()
        defer { priority.withLock { foreground -= 1 } }
        return try body()
    }

    private func measure<T>(_ work: String, _ body: () throws -> T) rethrows -> T {
        let watchdog = ServiceHoldWatchdog.shared
        let id = watchdog.begin(resource: "writer", work: work)
        defer { watchdog.end(id) }
        return try body()
    }

    func close() throws {
        try queue.close()
    }
}
