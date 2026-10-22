import Foundation

/// A reply may finish only the exact form whose send is still being observed.
struct RequestAnswerSubmission {
    let id = UUID()
    let requestID: String
    let projectID: String
    let formIdentity: String
    let formRevision: Int
    let requestRevision: Int
    let action: String

    init(request: Record, action: String) {
        requestID = request.id
        projectID = request.string("project_id")
        formIdentity = RequestDraftIdentity.form(request)
        formRevision = request.integer("form_revision")
        requestRevision = request.integer("revision")
        self.action = action
    }

    func reconcile(_ recorded: Record, currentRequest: Record?, currentDetail: Detail?, draft: AnswerDraft) -> RequestAnswerCompletion? {
        guard currentDetail == .request(requestID), let currentRequest,
              currentRequest.id == requestID, currentRequest.string("project_id") == projectID,
              !["canceled", "superseded"].contains(Canceled.normalized(currentRequest.string("state"))),
              RequestDraftIdentity.form(currentRequest) == formIdentity,
              currentRequest.integer("form_revision") == formRevision,
              draft.targetIdentity == formIdentity, draft.formRevision == formRevision,
              recorded.id == requestID, recorded.string("project_id") == projectID,
              RequestDraftIdentity.form(recorded) == formIdentity,
              recorded.integer("form_revision") == formRevision,
              recorded.integer("revision", fallback: 0) > requestRevision,
              let response = recorded.records("responses").last, !response.id.isEmpty,
              response.string("origin") == "human_ui", response.string("action") == action,
              response.string("form_identity") == formIdentity,
              response.integer("form_revision") == formRevision else { return nil }
        let complete = response.bool("complete")
        guard complete ? action == "answered" && recorded.string("state") == "answered" : recorded.string("state") == "pending" else { return nil }
        let notChecked = response.records("answers").contains { $0.string("result", fallback: $0.string("value")) == "not_checked" }
        guard !(complete && notChecked), action != "answered" || complete else { return nil }
        var updated = draft
        updated.revision = max(draft.revision, recorded.integer("revision"))
        return RequestAnswerCompletion(draft: updated, shouldDismiss: action == "answered")
    }
}

struct RequestAnswerCompletion {
    let draft: AnswerDraft
    let shouldDismiss: Bool
}

/// Leaving the form or starting another send invalidates the old presentation's reply.
struct RequestAnswerCompletionObserver {
    private var submissionID: UUID?
    mutating func observe(_ submission: RequestAnswerSubmission) { submissionID = submission.id }
    mutating func invalidate() { submissionID = nil }
    mutating func reconcile(_ submission: RequestAnswerSubmission, recorded: Record, currentRequest: Record?, currentDetail: Detail?, draft: AnswerDraft) -> RequestAnswerCompletion? {
        guard submissionID == submission.id,
              let completion = submission.reconcile(recorded, currentRequest: currentRequest, currentDetail: currentDetail, draft: draft) else { return nil }
        submissionID = nil
        return completion
    }
}
