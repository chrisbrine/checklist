import Foundation

public struct CodexQueueFollowupReceipt: Equatable, Sendable {
    public let pollResult: String
    public let openResult: String
    public let openExitStatus: Int32?
    public init(pollResult: String, openResult: String, openExitStatus: Int32? = nil) {
        self.pollResult = pollResult; self.openResult = openResult; self.openExitStatus = openExitStatus
    }
    public var metadata: [String:Any] {
        var result: [String:Any] = ["queue_poll_result":pollResult,"open_result":openResult]
        if let openExitStatus { result["open_exit_status"] = openExitStatus }
        return result
    }
}

/// `changed` includes a fence, a revocation and a new authorization generation.
public enum CodexQueueDeliveryStatus: Sendable { case current, acknowledged, changed }

public struct CodexQueueFollowupEnvironment: Sendable {
    public var openEnabled: Bool
    public var item: @Sendable (String) -> CodexQueueStore.Item
    public var observe: @Sendable () -> CodexQueueObservation
    public var load: @Sendable () -> CodexThreadLoad
    public var status: @Sendable () -> CodexQueueDeliveryStatus
    public var now: @Sendable () -> TimeInterval
    public var schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    public var open: @Sendable (String, TimeInterval) throws -> Int32
    /// An exec process holds this thread or names it. It can take the item and exit.
    public var execHolder: @Sendable () -> Bool
    /// Commits the per-thread open limit before I/O. A result refuses the open.
    public var reserveOpen: @Sendable () -> String? = { nil }
    public init(openEnabled: Bool, item: @escaping @Sendable (String) -> CodexQueueStore.Item, observe: @escaping @Sendable () -> CodexQueueObservation,
                load: @escaping @Sendable () -> CodexThreadLoad, status: @escaping @Sendable () -> CodexQueueDeliveryStatus,
                now: @escaping @Sendable () -> TimeInterval, schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void,
                open: @escaping @Sendable (String, TimeInterval) throws -> Int32, execHolder: @escaping @Sendable () -> Bool = { false }) {
        self.openEnabled = openEnabled; self.item = item; self.observe = observe; self.load = load
        self.status = status; self.now = now; self.schedule = schedule; self.open = open; self.execHolder = execHolder
    }
}

/// One delivery continuation, never a schedule. The caller commits its durable
/// send fence and queue acceptance before this starts. Nothing holds a thread,
/// a service command queue or a database transaction between two observations.
public enum CodexQueueFollowup {
    public static let waitSeconds: TimeInterval = 20
    public static let pollSeconds: TimeInterval = 5
    /// The note went to an exec process or the process took and dropped it. The item is gone
    /// and the owner's app thread may not have it. The note stays in the inbox.
    public static let removedByExec = CodexQueueFollowupReceipt(pollResult:"removed_exec_holder",openResult:"exec_holder")
    static let pendingWithExec = CodexQueueFollowupReceipt(pollResult:"pending_after_20s",openResult:"exec_holder")

    public static func run(itemID: String?, registration: NativeLifecycleRegistration, environment: CodexQueueFollowupEnvironment,
                           done: @escaping @Sendable (CodexQueueFollowupReceipt) -> Void) {
        guard registration.provider == "codex",UUID(uuidString:registration.sessionID) != nil else { return done(.init(pollResult:"not_started",openResult:"refused")) }
        guard let itemID,!itemID.isEmpty,itemID.utf8.count <= 160,
              itemID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            return done(.init(pollResult:"item_unconfirmed",openResult:"refused"))
        }
        poll(itemID:itemID,thread:registration.sessionID,turn:0,deadline:environment.now()+waitSeconds,execSeen:false,environment:environment,done:done)
    }

    private static func settled(_ status: CodexQueueDeliveryStatus) -> CodexQueueFollowupReceipt? {
        switch status {
        case .current: return nil
        case .acknowledged: return .init(pollResult:"acknowledged",openResult:"not_needed")
        case .changed: return .init(pollResult:"authorization_changed",openResult:"authorization_changed")
        }
    }

    /// The exec can exit in the moment it takes the item, so a holder seen at an earlier poll counts.
    private static func settled(_ item: CodexQueueStore.Item, execSeen: Bool, environment e: CodexQueueFollowupEnvironment) -> CodexQueueFollowupReceipt? {
        switch item {
        case .pending: return nil
        case .removed: return execSeen || e.execHolder() ? removedByExec : .init(pollResult:"removed",openResult:"not_needed")
        case .failed(let reason): return .init(pollResult:reason.rawValue,openResult:"refused")
        }
    }

    private static func poll(itemID: String, thread: String, turn: Int, deadline: TimeInterval, execSeen: Bool, environment e: CodexQueueFollowupEnvironment,
                             done: @escaping @Sendable (CodexQueueFollowupReceipt) -> Void) {
        let seen = execSeen || e.execHolder()
        if let result = settled(e.status()) { return done(result) }
        let read = e.item(itemID)
        // A locked read says nothing about the item, so the wait continues. Other results end it.
        let locked = read == .failed(.databaseLocked)
        if !locked,let result = settled(read,execSeen:seen,environment:e) { return done(result) }
        let left = deadline - e.now()
        // The count also bounds a broken or injected clock.
        guard left > 0,turn < Int(waitSeconds/pollSeconds) else {
            // The last read was locked, so the item is unknown: no pending label and no open.
            if locked,let result = settled(read,execSeen:seen,environment:e) { return done(result) }
            return decide(itemID:itemID,thread:thread,execSeen:seen,environment:e,done:done)
        }
        e.schedule(min(pollSeconds,left)) { poll(itemID:itemID,thread:thread,turn:turn+1,deadline:deadline,execSeen:seen,environment:e,done:done) }
    }

    private static func decide(itemID: String, thread: String, execSeen: Bool, environment e: CodexQueueFollowupEnvironment,
                               done: @escaping @Sendable (CodexQueueFollowupReceipt) -> Void) {
        let pending = "pending_after_20s"
        guard e.openEnabled else { return done(.init(pollResult:pending,openResult:"disabled")) }
        guard e.observe().host == .nativeApp else { return done(.init(pollResult:pending,openResult:"refused")) }
        if execSeen { return done(pendingWithExec) }
        switch e.load() {
        // Neutral: the item is still there. A thread whose last turn was interrupted never takes it.
        case .loaded: return done(.init(pollResult:pending,openResult:"loaded_pending"))
        case .unknown: return done(.init(pollResult:pending,openResult:"state_unknown"))
        case .unloaded: break
        }
        // These checks take time. The item can go or the fence can come while they run.
        if let result = settled(e.item(itemID),execSeen:false,environment:e) ?? settled(e.status()) { return done(result) }
        if e.execHolder() { return done(pendingWithExec) }
        if let refusal = e.reserveOpen() { return done(.init(pollResult:pending,openResult:refusal)) }
        do {
            let status = try e.open(thread,5)
            done(.init(pollResult:pending,openResult:status == 0 ? "exited_zero" : "failed",openExitStatus:status))
        } catch { done(.init(pollResult:pending,openResult:"outcome_unknown")) }
    }
}
