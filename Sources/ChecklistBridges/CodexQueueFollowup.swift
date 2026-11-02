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

/// One foreground delivery continuation, on the relay worker, never a schedule.
/// The caller commits its durable send fence and queue acceptance before waiting.
public enum CodexQueueFollowup {
    public static func finish(itemID: String?, registration: NativeLifecycleRegistration,
                              authorized: () -> Bool,
                              openEffects: any CodexThreadOpenEffects = MacOSCodexThreadOpenEffects()) -> CodexQueueFollowupReceipt {
        guard let store = CodexQueueStore.current else { return .init(pollResult:"database_read_error",openResult:"refused") }
        return finish(itemID:itemID,registration:registration,openEnabled:CodexQueueRelay.openUnloadedThreads,
            item:{ store.item($0,threadID:registration.sessionID) },observe:{ CodexQueueRelay.observation(registration) },
            authorized:authorized,now:{ ProcessInfo.processInfo.systemUptime },pause:{ Thread.sleep(forTimeInterval:$0) },openEffects:openEffects)
    }

    static func finish(itemID: String?, registration: NativeLifecycleRegistration, openEnabled: Bool,
                       item: (String) -> CodexQueueStore.Item, observe: () -> CodexQueueObservation,
                       authorized: () -> Bool, now: () -> TimeInterval, pause: (TimeInterval) -> Void,
                       openEffects: any CodexThreadOpenEffects) -> CodexQueueFollowupReceipt {
        guard registration.provider == "codex",UUID(uuidString:registration.sessionID) != nil else { return .init(pollResult:"not_started",openResult:"refused") }
        guard let itemID,!itemID.isEmpty,itemID.utf8.count <= 160,
              itemID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            return .init(pollResult:"item_unconfirmed",openResult:"refused")
        }
        let deadline = now() + 20
        // The count also bounds a broken/injected clock. No database transaction
        // or service command queue is held while waiting between observations.
        for turn in 0...20 {
            guard authorized() else { return .init(pollResult:"authorization_changed",openResult:"authorization_changed") }
            switch item(itemID) {
            case .removed: return .init(pollResult:"removed",openResult:"not_needed")
            case .failed(let reason): return .init(pollResult:reason.rawValue,openResult:"refused")
            case .pending: break
            }
            let left = deadline - now()
            if left <= 0 || turn == 20 { break }
            pause(min(1,left))
        }
        guard openEnabled else { return .init(pollResult:"pending_after_20s",openResult:"disabled") }
        guard authorized() else { return .init(pollResult:"authorization_changed",openResult:"authorization_changed") }
        guard observe().host == .nativeApp else { return .init(pollResult:"pending_after_20s",openResult:"refused") }
        // Observe the exact item again after source/authorization checks. It can
        // be consumed while those checks run; an empty queue needs no app open.
        switch item(itemID) {
        case .removed: return .init(pollResult:"removed",openResult:"not_needed")
        case .failed(let reason): return .init(pollResult:reason.rawValue,openResult:"refused")
        case .pending: break
        }
        guard authorized() else { return .init(pollResult:"authorization_changed",openResult:"authorization_changed") }
        do {
            let status = try openEffects.open(threadID:registration.sessionID,timeout:5)
            return .init(pollResult:"pending_after_20s",openResult:status == 0 ? "exited_zero" : "failed",openExitStatus:status)
        } catch { return .init(pollResult:"pending_after_20s",openResult:"outcome_unknown") }
    }
}
