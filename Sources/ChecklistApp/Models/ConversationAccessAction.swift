import Foundation

/// Native owner UI only. Neither command belongs to an agent tool catalog.
enum ConversationAccessAction {
    case disconnect, allowAgain

    static func available(for session: Record) -> Self? {
        guard session.string("role") == "worker", !session.string("installation").isEmpty,
              ["codex","claude"].contains(session.string("provider").lowercased()) else { return nil }
        if session.bool("owner_revoked") { return .allowAgain }
        if session.string("state") == "connected" || session.bool("owner_reconnect_allowed") { return .disconnect }
        return nil
    }
    var label: String { self == .disconnect ? "Disconnect…" : "Allow again…" }
    var method: String { self == .disconnect ? "connection_revoke" : "connection_allow" }
    var success: String { self == .disconnect ? "Conversation disconnected" : "Conversation allowed to reconnect" }

    func parameters(_ session: Record, task: Record) -> [String:Any] {
        ["project_id":task.string("project_id"),"task_id":task.id,"session_id":session.id,
         "installation":session.string("installation"),"expected_revision":session.integer("revision")]
    }
    func confirmation(_ session: Record, perform: @escaping () -> Void) -> PendingConfirmation {
        let name = [session.string("native_conversation_title"),session.string("label")].first { !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty } ?? "Agent conversation"
        let identity = "\(name) · \(session.id.prefix(8))"
        if self == .disconnect {
            return PendingConfirmation(title:"Disconnect \(identity)?",
                effect:"This ends this conversation's Checklist access across its tickets. Eligible claims return to Queued for pickup and leave their Triages, with history. Source checks and writable contributors retain reservations until stopped-work recovery. This does not stop the agent process, complete work or acknowledge messages. Reconnect stays refused until you select Allow again here.",
                confirmLabel:"Disconnect",perform:perform,cancelIsDefault:true)
        }
        return PendingConfirmation(title:"Allow \(identity) again?",
            effect:"This permits the actual conversation to reconnect with fresh access after its retained claims are recovered. It keeps its history and must claim work again. Old claims and queued messages stay fenced; this does not launch or resume the agent.",
            confirmLabel:"Allow again",perform:perform,cancelIsDefault:true)
    }
}
