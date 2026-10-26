import GRDB

/// Core's synchronous transaction boundary. Database handles stay inside the
/// macOS persistence implementation; this is not a portable SQL contract.
/// Storage admission, archive gates and command authority remain with callers.
protocol TransactionStorage: AnyObject, Sendable {
    func read<T>(_ value: (Database) throws -> T) throws -> T
    func write<T>(_ updates: (Database) throws -> T) throws -> T
    func writeWithoutTransaction<T>(_ updates: (Database) throws -> T) rethrows -> T
    func close() throws
}

/// Adapts the queue already opened and qualified by StorageBootstrap. Opening,
/// schema migration, protected backup and recovery are deliberately not repeated.
final class GRDBTransactionAdapter: TransactionStorage {
    private let queue: DatabaseQueue

    init(queue: DatabaseQueue) {
        self.queue = queue
    }

    func read<T>(_ value: (Database) throws -> T) throws -> T {
        try queue.read(value)
    }

    func write<T>(_ updates: (Database) throws -> T) throws -> T {
        try queue.write(updates)
    }

    func writeWithoutTransaction<T>(_ updates: (Database) throws -> T) rethrows -> T {
        try queue.writeWithoutTransaction(updates)
    }

    func close() throws {
        try queue.close()
    }
}
