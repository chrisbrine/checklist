import Foundation

@main
enum RequestAnswerCompletionChecks {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL: \(name)") }
        count += 1; print("PASS: \(name)")
    }
    static func changed(_ record: Record, _ values: [String: Any]) -> Record {
        Record(values: record.values.merging(values) { _, new in new })
    }
    static func bytes(_ draft: AnswerDraft) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(draft)
    }
    static func main() {
        let request = Record(values: ["id": "request-a", "project_id": "project-a", "form_identity": "form-a", "form_revision": 2, "revision": 4, "state": "pending"])
        var draft = AnswerDraft(revision: 4)
        draft.targetIdentity = "form-a"; draft.formRevision = 2
        draft.values = ["choice": "chosen"]; draft.explanation = "Keep these owner notes"
        draft.paths = ["file": ["selected-original"]]; draft.pathHashes = ["selected-original": "digest"]
        let submission = RequestAnswerSubmission(request: request, action: "answered")
        let response = Record(values: ["id": "synthetic-response", "origin": "human_ui", "action": "answered", "form_identity": "form-a", "form_revision": 2, "complete": true, "answers": [["question_id": "choice", "option_ids": ["chosen"]]]])
        let reply = changed(request, ["revision": 5, "state": "answered", "responses": [response.values]])
        func reconcile(_ result: Record, current: Record? = request, detail: Detail? = .request("request-a"), local: AnswerDraft? = nil) -> RequestAnswerCompletion? {
            submission.reconcile(result, currentRequest: current, currentDetail: detail, draft: local ?? draft)
        }
        let saved = reconcile(reply)!
        check(saved.shouldDismiss && saved.draft.revision == 5, "confirmed complete answer permits leaving exact request")
        var expected = draft; expected.revision = 5
        check(bytes(saved.draft) == bytes(expected), "saving revision retains notes, choices, paths and hashes")
        check(reconcile(reply, current: reply)?.shouldDismiss == true, "refreshed answered history still permits original completion")
        let failedCheck = changed(response, ["answers": [["question_id": "check", "result": "failed"]]])
        check(reconcile(changed(reply, ["responses": [failedCheck.values]]))?.shouldDismiss == true, "a complete reported failed check is a saved answer")
        let notChecked = changed(response, ["complete": false, "answers": [["question_id": "check", "result": "not_checked"]]])
        let partial = changed(reply, ["state": "pending", "responses": [notChecked.values]])
        check(reconcile(partial)?.shouldDismiss == true && partial.string("state") == "pending", "saved Not checked dismisses while retaining pending state")
        for action in ["clarification", "cannot_do"] {
            let alternate = RequestAnswerSubmission(request: request, action: action)
            let record = changed(response, ["action": action, "complete": false])
            let result = alternate.reconcile(changed(reply, ["state": "pending", "responses": [record.values]]), currentRequest: request, currentDetail: .request(request.id), draft: draft)
            check(result?.shouldDismiss == false && result?.draft.explanation == draft.explanation, "\(action) remains visible with its explanation")
        }
        let invalidReplies: [(Record, String)] = [
            (Record(values: [:]), "ambiguous empty reply"),
            (changed(reply, ["id": "request-b"]), "wrong request reply"),
            (changed(reply, ["project_id": "project-b"]), "wrong project reply"),
            (changed(reply, ["form_identity": "replacement"]), "stale target reply"),
            (changed(reply, ["form_revision": 3]), "stale form revision reply"),
            (changed(reply, ["revision": 4]), "unadvanced request reply"),
            (changed(reply, ["responses": []]), "reply without saved response"),
            (changed(reply, ["responses": [changed(response, ["origin": "worker"]).values]]), "nonowner response"),
            (changed(reply, ["responses": [changed(response, ["form_identity": "replacement"]).values]]), "response for different target"),
            (changed(reply, ["responses": [changed(response, ["action": "cannot_do"]).values]]), "different action reply"),
            (changed(reply, ["state": "pending"]), "inconsistent completion state"),
            (changed(reply, ["state": "pending", "responses": [changed(response, ["complete": false]).values]]), "incomplete unconfirmed answer"),
            (changed(reply, ["responses": [changed(notChecked, ["complete": true]).values]]), "Not checked falsely marked complete")
        ]
        for (record, name) in invalidReplies { check(reconcile(record) == nil, name + " preserves draft and navigation") }
        check(reconcile(reply, current: nil) == nil, "missing live request retains view")
        check(reconcile(reply, detail: nil) == nil, "reply after closing cannot navigate")
        check(reconcile(reply, detail: .request("request-b")) == nil, "late A reply cannot close B")
        check(reconcile(reply, detail: .task("task-a")) == nil, "late reply cannot close unrelated task")
        check(reconcile(reply, current: changed(request, ["form_identity": "form-b", "form_revision": 3])) == nil, "live replacement form is preserved")
        check(reconcile(reply, current: changed(request, ["state": "canceled"])) == nil, "live cancellation is preserved")
        var revisedDraft = draft; revisedDraft.targetIdentity = "form-b"
        check(reconcile(reply, local: revisedDraft) == nil, "draft for revised target is preserved")
        var observer = RequestAnswerCompletionObserver()
        observer.observe(submission)
        check(observer.reconcile(submission, recorded: Record(values: [:]), currentRequest: request, currentDetail: .request(request.id), draft: draft) == nil, "unknown outcome does not consume original intent")
        check(observer.reconcile(submission, recorded: reply, currentRequest: request, currentDetail: .request(request.id), draft: draft)?.shouldDismiss == true, "confirmed reconciliation can finish original intent")
        check(observer.reconcile(submission, recorded: reply, currentRequest: request, currentDetail: .request(request.id), draft: draft) == nil, "duplicate successful receipt cannot navigate twice")
        observer.observe(submission); observer.invalidate()
        check(observer.reconcile(submission, recorded: reply, currentRequest: request, currentDetail: .request(request.id), draft: draft) == nil, "leaving and reopening A invalidates earlier presentation reply")
        let next = RequestAnswerSubmission(request: request, action: "answered")
        observer.observe(next)
        check(observer.reconcile(submission, recorded: reply, currentRequest: request, currentDetail: .request(request.id), draft: draft) == nil, "old submission cannot consume new send intent")
        check(observer.reconcile(next, recorded: reply, currentRequest: request, currentDetail: .request(request.id), draft: draft)?.shouldDismiss == true, "current send survives unrelated stale reply")
        check(draft.revision == 4 && draft.explanation == "Keep these owner notes", "rejected and late paths never mutate original draft")
        print("\(count) request answer completion checks passed")
    }
}
