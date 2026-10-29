import Foundation
import Dispatch

/// An opaque, process-local drain generation. It grants no database or filesystem
/// authority, and cannot be restored or reused with another router.
public final class StorageDrainTicket: @unchecked Sendable {
    fileprivate let owner: StorageAdmission
    fileprivate let id: UUID
    fileprivate let completion: DispatchGroup

    fileprivate init(owner: StorageAdmission, id: UUID, completion: DispatchGroup) {
        self.owner = owner
        self.id = id
        self.completion = completion
    }
}

/// The active-ID set makes explicit finish and deinit idempotent, even if callers
/// race to finish. The lease spans an entire operation, including its rollback
/// and post-commit filesystem/outcome work.
final class StorageOperationLease: @unchecked Sendable {
    fileprivate let owner: StorageAdmission
    fileprivate let id: UUID

    fileprivate init(owner: StorageAdmission, id: UUID) {
        self.owner = owner
        self.id = id
    }

    func finish() { owner.finish(id) }
    deinit { finish() }
}

/// Accounts only for entries wired into this exact router. It is not an old
/// process fence, object hold/reference validator, or durable upgrade receipt.
final class StorageAdmission: @unchecked Sendable {
    private enum State {
        case bootstrapping
        case admitting
        case draining(UUID, DispatchGroup)
        case drained(UUID)
    }

    private let lock = NSLock()
    private var state: State = .bootstrapping
    private var active = Set<UUID>()
    private let continuationKey = "ChecklistStorageContinuation-" + UUID().uuidString

    func openAfterBootstrap() throws {
        lock.lock(); defer { lock.unlock() }
        guard case .bootstrapping = state else { throw invalidDrain() }
        state = .admitting
    }

    func acquire() throws -> StorageOperationLease {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .bootstrapping:
            throw CoreError("STORAGE_NOT_READY", "Storage recovery must finish before this operation can start.")
        case .draining, .drained:
            // A durable queued intent was admitted before the drain began. Its
            // synchronous continuation may enter nested storage boundaries; this
            // grants nothing to a new request on any other thread.
            if let parent = Thread.current.threadDictionary[continuationKey] as? StorageOperationLease,
               parent.owner === self,active.contains(parent.id) {
                let id = UUID();active.insert(id);return StorageOperationLease(owner:self,id:id)
            }
            throw CoreError("STORAGE_DRAINING", "Storage admission is paused. Preserve the original command and retry after recovery resumes.")
        case .admitting:
            let id = UUID()
            active.insert(id)
            return StorageOperationLease(owner: self, id: id)
        }
    }

    func withContinuation<T>(_ lease: StorageOperationLease,_ body: () throws -> T) throws -> T {
        lock.lock();let valid = lease.owner === self && active.contains(lease.id);lock.unlock()
        guard valid else {throw invalidDrain()}
        let previous = Thread.current.threadDictionary[continuationKey]
        Thread.current.threadDictionary[continuationKey] = lease
        defer {if let previous {Thread.current.threadDictionary[continuationKey] = previous} else {Thread.current.threadDictionary.removeObject(forKey:continuationKey)}}
        return try body()
    }

    fileprivate func finish(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard active.remove(id) != nil else { return }
        if active.isEmpty, case .draining(let generation, let completion) = state {
            state = .drained(generation)
            completion.leave()
        }
    }

    func beginDrain() throws -> StorageDrainTicket {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .bootstrapping:
            throw CoreError("STORAGE_NOT_READY", "Storage recovery has not established admission.")
        case .draining, .drained:
            throw CoreError("STORAGE_DRAIN_ACTIVE", "Finish or cancel the current drain before starting another.")
        case .admitting:
            let id = UUID(), completion = DispatchGroup()
            if active.isEmpty {
                state = .drained(id)
            } else {
                completion.enter()
                state = .draining(id, completion)
            }
            return StorageDrainTicket(owner: self, id: id, completion: completion)
        }
    }

    /// The caller must wait outside writer/coordinator queues needed by admitted
    /// work. DispatchGroup uses a monotonic finite deadline; scheduling or blocked
    /// filesystem IO is not subject to a hard deadline guarantee here.
    func waitForDrain(_ ticket: StorageDrainTicket, timeout: TimeInterval) throws -> Bool {
        guard timeout.isFinite, timeout >= 0, timeout <= 60 else {
            throw CoreError("INVALID_INPUT", "Use a finite storage drain timeout from zero through sixty seconds.")
        }
        lock.lock()
        do { try requireCurrent(ticket) }
        catch { lock.unlock(); throw error }
        lock.unlock()

        let result = ticket.completion.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        try requireCurrent(ticket) // Cancellation/new generations never become success.
        // A completion racing after the timeout cannot upgrade that expired wait
        // into success. A later explicit observation may establish drained.
        guard result == .success else { return false }
        if case .drained = state { return true }
        throw invalidDrain()
    }

    func cancelDrain(_ ticket: StorageDrainTicket) throws {
        lock.lock(); defer { lock.unlock() }
        try requireCurrent(ticket)
        switch state {
        case .draining(_, let completion):
            state = .admitting
            completion.leave() // Wake waiters; their generation check rejects cancellation.
        case .drained:
            state = .admitting
        case .admitting, .bootstrapping:
            throw invalidDrain()
        }
    }

    private func requireCurrent(_ ticket: StorageDrainTicket) throws {
        guard ticket.owner === self else { throw invalidDrain() }
        switch state {
        case .draining(let id, _), .drained(let id):
            guard id == ticket.id else { throw invalidDrain() }
        case .bootstrapping, .admitting:
            throw invalidDrain()
        }
    }

    private func invalidDrain() -> CoreError {
        CoreError("STORAGE_DRAIN_INVALID", "This drain does not identify the current router generation.")
    }
}

extension CommandRouter {
    /// Internal host lifecycle APIs, with no MCP/dispatch exposure. These owner
    /// checks do not qualify service drain or another process's continued IO.
    public func beginStorageDrain(caller: Caller) throws -> StorageDrainTicket {
        try owner(caller)
        return try storageAdmission.beginDrain()
    }

    public func waitForStorageDrain(_ ticket: StorageDrainTicket, timeout: TimeInterval, caller: Caller) throws -> Bool {
        try owner(caller)
        return try storageAdmission.waitForDrain(ticket, timeout: timeout)
    }

    public func cancelStorageDrain(_ ticket: StorageDrainTicket, caller: Caller) throws {
        try owner(caller)
        try storageAdmission.cancelDrain(ticket)
    }
}
