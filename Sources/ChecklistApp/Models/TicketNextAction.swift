import Foundation

/// Work health from ticket attempts and their sessions (CL-52, CL-66). Ended, revoked or unknown
/// sessions need recovery; they are never shown as working.
enum WorkHealth {
    static func needsRecovery(_ attempt: Record, session: Record?) -> Bool {
        if attempt.string("session_id") == "human" { return false }
        guard let session else { return true }
        // The same rule as the Overview's need surfaces: ended, revoked, unknown or no recorded state.
        return ["ended", "revoked", "unknown", ""].contains(session.string("state"))
    }
}

/// The first decisions of a ticket's next-action bar (CL-52). A blocking request comes first; the
/// review, completion and start actions follow from the ticket's work records.
enum TicketNextAction: Equatable {
    case completed
    case answer(String)
    case recover(String)
    case makeReady

    static func lead(task: Record, requests: [Record], activeAttempt: Record?, session: Record?) -> TicketNextAction? {
        if task.string("status_category") == "done" { return .completed }
        if let request = blockingRequest(requests) { return .answer(request.id) }
        if let activeAttempt, WorkHealth.needsRecovery(activeAttempt, session: session) { return .recover(activeAttempt.id) }
        if activeAttempt == nil && task.string("readiness") == "draft" { return .makeReady }
        return nil
    }

    static func blockingRequest(_ requests: [Record]) -> Record? {
        requests.first { !["answered", "canceled", "superseded", "resolved"].contains(Canceled.normalized($0.string("state"))) && $0.bool("blocking") }
    }
}
