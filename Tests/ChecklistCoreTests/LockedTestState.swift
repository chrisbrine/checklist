import Foundation

// The lock owns all mutable state; Value is Sendable and only copied snapshots escape.
final class LockedTestState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    @discardableResult
    func withLock<Result: Sendable>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&value) }
    }

    var snapshot: Value { lock.withLock { value } }
}
