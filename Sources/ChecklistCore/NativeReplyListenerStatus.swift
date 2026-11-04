import Foundation
import os

/// The state of this service process's native reply listener. The route table in
/// `native_routes` is build-level; this value is what the running process observed.
public struct NativeReplyListenerStatus: Equatable, Sendable {
    public enum State: String, Sendable { case notStarted = "not_started", listening, failed, disabled }
    public let state: State
    public let reason: String?
    public let usesFallbackName: Bool
    public let codexQueueRelayEnabled: Bool
    public let slotRelayMode: String?
    public let slotRelayMessage: String?

    public init(state: State, reason: String? = nil, usesFallbackName: Bool = false, codexQueueRelayEnabled: Bool, slotRelayMode: String? = nil, slotRelayMessage: String? = nil) {
        self.state = state; self.reason = reason; self.usesFallbackName = usesFallbackName; self.codexQueueRelayEnabled = codexQueueRelayEnabled
        self.slotRelayMode = slotRelayMode; self.slotRelayMessage = slotRelayMessage
    }

    var message: String {
        let listenerMessage: String
        switch state {
        case .disabled: return slotRelayMessage ?? "All native relays are off. Notes wait for Checklist pickup."
        case .notStarted: listenerMessage = "The native reply listener did not start yet."
        case .listening:
            listenerMessage = usesFallbackName
                ? "The native reply listener is running at a fallback name, because a file already exists at its process ID name. No check has shown that Claude replies to this name."
                : "The native reply listener is running."
        case .failed:
            let codex = codexQueueRelayEnabled ? "The Codex queue route does not use this listener and still runs." : "This build keeps the Codex queue route off."
            listenerMessage = "Checklist does not relay notes to Claude conversations now, because its reply listener did not start. Reason: \(reason ?? "unknown"). "
                + "Each note waits for the conversation's next Checklist check. \(codex) The service tries the listener again at its next start."
        }
        return listenerMessage + (slotRelayMessage.map { " " + $0 } ?? "")
    }

    var serviceInfo: [String: Any] {
        var info: [String: Any] = ["state": state.rawValue, "message": message,
                                   "claude_relay": state == .listening ? "running" : "stopped",
                                   "codex_queue_relay": codexQueueRelayEnabled ? "running" : "off"]
        if let reason { info["reason"] = reason }
        if let slotRelayMode { info["slot_relays"] = slotRelayMode }
        if state == .listening { info["reply_path_name"] = usesFallbackName ? "fallback" : "process_id" }
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
