import XCTest
@testable import ChecklistApp

final class RequestDraftValidationTests: XCTestCase {
    private func question(_ id: String, _ prompt: String, type: String = "check", required: Bool = true) -> Record {
        Record(values: ["id": id, "prompt": prompt, "type": type, "required": required])
    }
    private func message(_ draft: AnswerDraft = AnswerDraft(), questions: [Record], files: [Record] = []) -> String? {
        RequestDraftIdentity.incompleteMessage(draft, questions: questions, fileRequests: files)
    }
    func testOneMissingItemNamesItsPrompt() {
        XCTAssertEqual(message(questions: [question("q", "Synthetic check required item")]), "Answer “Synthetic check required item”. Choose a result, or select Other response · Not checked and add an explanation. You can also use Need clarification or Cannot do with an explanation.")
    }
    func testTwoMissingItemsNamesBothInFormOrder() {
        XCTAssertEqual(message(questions: [question("a", "First"), question("b", "Second")]), "Answer “First” and “Second”. Choose a result, or select Other response · Not checked and add an explanation. You can also use Need clarification or Cannot do with an explanation.")
    }
    func testFourMissingItemsNamesThreeAndCountsTheRest() {
        XCTAssertEqual(message(questions: (1...4).map { question("q\($0)", "Item \($0)") }), "Answer “Item 1”, “Item 2”, “Item 3” and 1 more. Choose a result, or select Other response · Not checked and add an explanation. You can also use Need clarification or Cannot do with an explanation.")
    }
    func testCompleteFormHasNoMissingItemMessage() {
        let questions = [question("check", "Check"), question("approval", "Approval", type: "approval"), question("text", "Text", type: "text")]
        var draft = AnswerDraft()
        draft.values = ["check": "declined", "approval": "approved", "text": "Answer"]
        draft.paths = ["file": ["/synthetic/file"]]
        let files = [Record(values: ["id": "file", "prompt": "Evidence"])]
        XCTAssertNil(message(draft, questions: questions, files: files))
        XCTAssertTrue(RequestDraftIdentity.isComplete(draft, questions: questions, fileRequests: files))
    }
    func testMissingFileIsNamedAlongsideMissingQuestion() {
        XCTAssertEqual(message(questions: [question("q", "Explanation", type: "text")], files: [Record(values: ["id": "file", "prompt": "Evidence file"])]), "Complete “Explanation” and “Evidence file”. You can also use Need clarification or Cannot do with an explanation.")
    }
    func testNotCheckedNamesTheItemAndKeepsOtherResponseGuidance() {
        var draft = AnswerDraft()
        draft.values = ["q": "not_checked"]
        let questions = [question("q", "Optional check", required: false)]
        XCTAssertEqual(message(draft, questions: questions), "Answer “Optional check”. Add an explanation for Not checked. You can also use Need clarification or Cannot do with an explanation.")
        XCTAssertFalse(RequestDraftIdentity.isComplete(draft, questions: questions, fileRequests: []))
    }
    func testCustomAnswerAndEmptyOptionalItemsDoNotBlockSend() {
        var draft = AnswerDraft()
        draft.customValues = ["choice": "My answer"]
        let questions = [Record(values: ["id": "choice", "prompt": "Choice", "type": "choice", "allow_custom": true]), question("optional", "Optional", type: "text", required: false)]
        XCTAssertNil(message(draft, questions: questions, files: [Record(values: ["id": "optionalFile", "required": false])]))
        draft.customValues["choice"] = " \n "
        XCTAssertEqual(message(draft, questions: questions), "Answer “Choice”. You can also use Need clarification or Cannot do with an explanation.")
    }
    func testEveryQuestionTypeAndAnswerKindRequiredAndOptional() {
        for type in ["text", "choice", "approval", "check"] {
            for required in [true, false] {
                for kind in ["yes", "no", "other", "empty"] {
                    let q = Record(values: ["id": "q", "prompt": "Question", "type": type, "required": required, "allow_custom": true,
                                            "options": [["id": "yes", "label": "Yes"], ["id": "no", "label": "No"]]])
                    var draft = AnswerDraft()
                    if kind != "empty" {
                        switch type {
                        case "text": draft.values["q"] = kind == "other" ? "My own response" : kind
                        case "choice":
                            if kind == "other" { draft.customValues["q"] = "My own response" }
                            else { draft.values["q"] = kind }
                        default:
                            draft.values["q"] = kind == "other" ? "not_checked" : kind == "no" ? "declined" : type == "check" ? "passed" : "approved"
                            if kind == "other" { draft.explanation = "I could not inspect this candidate" }
                        }
                    }
                    let complete = kind != "empty" || !required
                    let label = "\(type) required=\(required) \(kind)"
                    XCTAssertEqual(RequestDraftIdentity.isComplete(draft, questions: [q], fileRequests: []), complete, label)
                    XCTAssertEqual(message(draft, questions: [q]) == nil, complete, label)
                    let payload = RequestDraftIdentity.answers(draft, questions: [q])
                    XCTAssertEqual(payload.count, kind == "empty" ? 0 : 1, label)
                    if kind != "empty" {
                        let field = type == "text" ? "text" : type == "choice" ? (kind == "other" ? "custom_text" : "option_ids") : "result"
                        if field == "option_ids" { XCTAssertEqual(payload[0][field] as? [String], [kind], label) }
                        else { XCTAssertEqual(payload[0][field] as? String, type == "choice" ? draft.customValues["q"] : draft.values["q"], label) }
                    }
                }
            }
        }
    }
    func testNotCheckedNeedsOwnerWordsForRequiredAndOptionalDecisions() {
        for type in ["check", "approval"] {
            for required in [true, false] {
                let questions = [question("q", "Inspection", type: type, required: required)]
                var draft = AnswerDraft(); draft.values["q"] = "not_checked"
                for explanation in ["", " \n ", "I have no access to this build"] {
                    draft.explanation = explanation
                    let complete = !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    XCTAssertEqual(RequestDraftIdentity.isComplete(draft, questions: questions, fileRequests: []), complete)
                    if !complete {
                        let guidance = message(draft, questions: questions)!
                        XCTAssertTrue(guidance.contains("Inspection")); XCTAssertTrue(guidance.contains("Add an explanation"))
                        XCTAssertTrue(guidance.contains("Need clarification")); XCTAssertTrue(guidance.contains("Cannot do"))
                    }
                }
            }
        }
    }

    func testSavedNotCheckedReceiptCompletesSendWithoutClaimingRequestComplete() {
        let request = Record(values: ["id": "r", "project_id": "p", "form_identity": "f", "form_revision": 1, "revision": 1, "state": "pending"])
        var draft = AnswerDraft(revision: 1); draft.targetIdentity = "f"; draft.formRevision = 1
        draft.values["q"] = "not_checked"; draft.explanation = "I cannot inspect this build"
        let submission = RequestAnswerSubmission(request: request, action: "answered")
        let response: [String: Any] = ["id": "response", "origin": "human_ui", "action": "answered", "form_identity": "f", "form_revision": 1, "complete": false, "answers": RequestDraftIdentity.answers(draft, questions: [question("q", "Check")]), "explanation": draft.explanation]
        var recorded = request.values; recorded["revision"] = 2; recorded["responses"] = [response]
        let completion = submission.reconcile(Record(values: recorded), currentRequest: request, currentDetail: .request("r"), draft: draft)
        XCTAssertEqual(completion?.shouldDismiss, true)
        XCTAssertEqual(completion?.draft.revision, 2)
        XCTAssertEqual(completion?.draft.values["q"], "not_checked")
        XCTAssertEqual(completion?.draft.explanation, draft.explanation)
        var inconsistent = recorded; inconsistent["state"] = "answered"
        XCTAssertNil(submission.reconcile(Record(values: inconsistent), currentRequest: request, currentDetail: .request("r"), draft: draft))
    }

}
