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
        XCTAssertEqual(message(questions: [question("q", "Synthetic check required item")]), "Answer “Synthetic check required item”. Choose No to decline; use Other response for Not checked.")
    }
    func testTwoMissingItemsNamesBothInFormOrder() {
        XCTAssertEqual(message(questions: [question("a", "First"), question("b", "Second")]), "Answer “First” and “Second”. Choose No to decline; use Other response for Not checked.")
    }
    func testFourMissingItemsNamesThreeAndCountsTheRest() {
        XCTAssertEqual(message(questions: (1...4).map { question("q\($0)", "Item \($0)") }), "Answer “Item 1”, “Item 2”, “Item 3” and 1 more. Choose No to decline; use Other response for Not checked.")
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
        XCTAssertEqual(message(questions: [question("q", "Explanation", type: "text")], files: [Record(values: ["id": "file", "prompt": "Evidence file"])]), "Complete “Explanation” and “Evidence file”.")
    }
    func testNotCheckedNamesTheItemAndKeepsOtherResponseGuidance() {
        var draft = AnswerDraft()
        draft.values = ["q": "not_checked"]
        let questions = [question("q", "Optional check", required: false)]
        XCTAssertEqual(message(draft, questions: questions), "Answer “Optional check”. Choose No to decline; use Other response for Not checked.")
        XCTAssertFalse(RequestDraftIdentity.isComplete(draft, questions: questions, fileRequests: []))
    }
    func testCustomAnswerAndEmptyOptionalItemsDoNotBlockSend() {
        var draft = AnswerDraft()
        draft.customValues = ["choice": "My answer"]
        let questions = [Record(values: ["id": "choice", "prompt": "Choice", "type": "choice", "allow_custom": true]), question("optional", "Optional", type: "text", required: false)]
        XCTAssertNil(message(draft, questions: questions, files: [Record(values: ["id": "optionalFile", "required": false])]))
        draft.customValues["choice"] = " \n "
        XCTAssertEqual(message(draft, questions: questions), "Answer “Choice”.")
    }
}
