import Foundation
import os

/// The state of this service process's native reply listener. The route table in
/// `native_routes` is build-level; this value is what the running process observed.
public struct NativeReplyListenerStatus: Equatable, Sendable {
    public enum State: String, Sendable { case notStarted = "not_started", listening, failed }
    public let state: State
    public let reason: String?
    public let codexQueueRelayEnabled: Bool

    public init(state: State, reason: String? = nil, codexQueueRelayEnabled: Bool) {
        self.state = state; self.reason = reason; self.codexQueueRelayEnabled = codexQueueRelayEnabled
    }

    var message: String {
        switch state {
        case .notStarted: return "The native reply listener did not start yet."
        case .listening: return "The native reply listener is running."
        case .failed:
            let codex = codexQueueRelayEnabled ? "The Codex queue route does not use this listener and still runs." : "This build keeps the Codex queue route off."
            return "Checklist does not relay notes to Claude conversations now, because its reply listener did not start. Reason: \(reason ?? "unknown"). "
                + "Each note waits for the conversation's next Checklist check. \(codex) The service tries the listener again at its next start."
        }
    }

    var serviceInfo: [String: Any] {
        var info: [String: Any] = ["state": state.rawValue, "message": message,
                                   "claude_relay": state == .listening ? "running" : "stopped",
                                   "codex_queue_relay": codexQueueRelayEnabled ? "running" : "off"]
        if let reason { info["reason"] = reason }
        return info
    }
}

final class NativeReplyListenerStatusHolder: Sendable {
    let current = OSAllocatedUnfairLock(initialState: NativeReplyListenerStatus(state: .notStarted, codexQueueRelayEnabled: false))
}

extension CommandRouter {
    /// The service sets this value before it accepts a client.
    public var nativeReplyListenerStatus: NativeReplyListenerStatus {
        get { nativeReplyListenerHolder.current.withLock { $0 } }
        set { nativeReplyListenerHolder.current.withLock { $0 = newValue } }
    }
}
