import XCTest
@testable import ChecklistApp

final class TicketBulkControlsTests: XCTestCase {
    private func ticket(_ id: String, revision: Int = 1, project: String = "p") -> Record {
        Record(values: ["id": id, "project_id": project, "revision": revision, "key": "P-" + id, "title": id])
    }
    @MainActor func testOrdinaryClickStillOpensDetailWhileModifiedClicksSelectDisplayedRange() {
        let selection = TicketBulkSelection(), a = ticket("a"), b = ticket("b"), c = ticket("c")
        XCTAssertFalse(selection.activate(a, order: [a,b,c], command: false, shift: false))
        XCTAssertEqual(selection.count, 0)
        XCTAssertTrue(selection.activate(a, order: [a,b,c], command: true, shift: false))
        XCTAssertTrue(selection.activate(c, order: [a,b,c], command: false, shift: true))
        XCTAssertEqual(selection.tickets.map(\.id), ["a","b","c"])
        XCTAssertTrue(selection.activate(b, order: [a,b,c], command: true, shift: false))
        XCTAssertEqual(selection.tickets.map(\.id), ["a","c"])
        selection.clear()
        XCTAssertFalse(selection.selecting)
        XCTAssertEqual(selection.count, 0)
    }
    @MainActor func testSelectionRetainsObservedRevisionsAndRejectsMixedProjectBulkScope() {
        let selection = TicketBulkSelection(), a = ticket("a", revision: 2)
        selection.selecting = true
        selection.activate(a, order: [a], command: false, shift: false)
        let newer = ticket("a", revision: 3)
        XCTAssertTrue(selection.contains(newer))
        XCTAssertEqual(selection.tickets.first?.integer("revision"), 2)
        XCTAssertEqual(selection.project, "p")
        let other = ticket("a", project: "another")
        selection.activate(other, order: [other], command: true, shift: false)
        XCTAssertEqual(selection.count, 2)
        XCTAssertNil(selection.project)
    }
    @MainActor func testRenderedOrderDeduplicatesTriageRowsAndPreservesExactIdentity() {
        let a = ticket("é"), b = ticket("e\u{0301}")
        let rows: [TicketListRow] = [
            .init(id: .triageMember(triageID: "t", taskID: a.id), content: .triageMember(a)),
            .init(id: .ticket(a.id), content: .ticket(a)),
            .init(id: .ticket(b.id), content: .ticket(b))
        ]
        XCTAssertEqual(TicketBulkSelection.renderedTickets(rows).count, 2)
    }
    func testPreviewListsAllConflictsAndEligibleRetryKeepsOriginalRevision() throws {
        let a = ticket("a", revision: 2), b = ticket("b", revision: 4)
        let reply: [String: Any] = ["affected_count": 1, "rows": [
            ["task_id": "a", "eligible": true, "current_revision": 2],
            ["task_id": "b", "eligible": false, "current_revision": 5, "reason": "This ticket changed since you selected it."]
        ]]
        let preview = try TicketBulkPreview(reply, tickets: [a,b])
        XCTAssertEqual(preview.affectedCount, 1)
        XCTAssertEqual(preview.blocked.first?.string("reason"), "This ticket changed since you selected it.")
        XCTAssertEqual(preview.eligibleTickets(from: [a,b]).map(\.id), ["a"])
        XCTAssertEqual(preview.eligibleTickets(from: [a,b]).first?.integer("revision"), 2)
        XCTAssertThrowsError(try TicketBulkPreview(reply, tickets: [a]))
        var wrong = reply
        wrong["rows"] = [["task_id": "a", "eligible": true], ["task_id": "a", "eligible": false]]
        XCTAssertThrowsError(try TicketBulkPreview(wrong, tickets: [a,b]))
    }
    func testUndoReceiptBindsOriginalCommandAndAfterRevisions() throws {
        let row = ticket("a", revision: 2)
        let reply: [String: Any] = ["command_id": "original", "affected_count": 1, "rows": [["task_id": "a", "eligible": true, "after_revision": 3]]]
        let receipt = try XCTUnwrap(TicketBulkReceipt(reply: reply, project: "p", summary: "Add tags", selected: [row]))
        XCTAssertEqual(receipt.commandID, "original")
        XCTAssertEqual(receipt.project, "p")
        XCTAssertEqual(receipt.tickets.first?.integer("revision"), 3)
        XCTAssertNil(TicketBulkReceipt(reply: ["affected_count": 1, "rows": []], project: "p", summary: "Add tags", selected: [row]))
    }
    func testWorkerAssigneeChoicesExcludeAssistantProfilesWrongScopeAndIneligibleProviders() {
        func worker(_ id: String, role: String = "worker", provider: String = "codex", project: String = "p", mode: String = "", state: String = "active") -> Record {
            Record(values: ["id": id, "role": role, "provider": provider, "project_id": project, "access_mode": mode, "state": state])
        }
        let choices = [worker("actual"), worker("Dots", role: "assistant"), worker("observer", mode: "observer_messenger"), worker("wrong-provider", provider: "claude"), worker("another-project", project: "q"), worker("ended", state: "ended")]
        XCTAssertEqual(TicketBulkWorkers.eligible(choices, project: "p", providers: ["codex"]).map(\.id), ["actual"])
    }
}
