import XCTest
@testable import ChecklistApp

/// Draft means the brief needs refinement; a Ready ticket that waits for prerequisites stays out of Drafts (CL-133).
@MainActor final class TicketReadinessLabelTests: XCTestCase {
    private func ticket(_ id: String, _ key: String, readiness: String, waitsFor blockers: [String], category: String = "queued") -> Record {
        Record(values: ["id": id, "key": key, "title": key, "project_id": "p", "readiness": readiness, "status_category": category, "status_name": "Queued", "updated_at": "2026-10-19T00:00:00Z",
                        "prerequisite_blockers": blockers.map { ["key": $0, "reason": "Prerequisite \($0) must be Done."] as [String: Any] }])
    }
    private func drafts(_ tasks: [Record], triageMembers: [String]) -> TicketListProjection {
        let triage = Record(values: ["id": "g", "kind": "triage", "name": "Planned pass", "project_id": "p", "task_ids": triageMembers])
        return TicketListProjection.make(tasks: tasks, groups: [triage], messages: [], projectID: "p", archived: false, statusFilter: "draft", tagFilter: "all", search: "", includeTriages: true, projectNames: ["p": "Project"])
    }

    func testReadyTicketNamesWhatItWaitsForAndKeepsItsStatus() {
        let waiting = ticket("a", "CL-2", readiness: "ready", waitsFor: ["CL-1"])
        XCTAssertEqual(TicketVisibility.waitingLabel(waiting), "Waiting for CL-1")
        XCTAssertEqual(TicketVisibility.statusLabel(waiting), "Queued")
        XCTAssertEqual(TicketVisibility.category(waiting), "queued")
        XCTAssertEqual(TaskRowPresentation(task: waiting, selected: false, projectName: nil, age: "now").waiting, "Waiting for CL-1")
        XCTAssertEqual(TicketVisibility.waitingLabel(ticket("m", "CL-9", readiness: "ready", waitsFor: ["CL-5", "CL-6", "CL-7"])), "Waiting for CL-5, CL-6 +1")
        XCTAssertEqual(TicketVisibility.waitingLabel(ticket("f", "CL-8", readiness: "ready", waitsFor: [])), "")
    }

    func testDraftAndClosedTicketsShowNoWaitingLabel() {
        let draft = ticket("b", "CL-3", readiness: "draft", waitsFor: ["CL-1"])
        XCTAssertEqual(TicketVisibility.waitingLabel(draft), "")
        XCTAssertEqual(TicketVisibility.statusLabel(draft), "Queued")
        XCTAssertEqual(TaskRowPresentation(task: draft, selected: false, projectName: nil, age: "now").waiting, "")
        XCTAssertEqual(TicketVisibility.waitingLabel(ticket("d", "CL-4", readiness: "ready", waitsFor: ["CL-1"], category: "done")), "")
    }

    func testDraftFilterKeepsOnlyTicketsThatNeedRefinement() {
        let waiting = ticket("a", "CL-2", readiness: "ready", waitsFor: ["CL-1"]), draft = ticket("b", "CL-3", readiness: "draft", waitsFor: [])
        XCTAssertFalse(TicketVisibility.matchesStatus(waiting, filter: "draft", activeTriageMember: false))
        XCTAssertTrue(TicketVisibility.matchesStatus(waiting, filter: "ready", activeTriageMember: false))
        XCTAssertTrue(TicketVisibility.matchesStatus(draft, filter: "draft", activeTriageMember: false))
        XCTAssertEqual(TicketVisibility.groupLabel(waiting), "Queued")
        XCTAssertEqual(TicketVisibility.groupLabel(draft), "Drafts")
    }

    func testTriageAppearsUnderDraftsOnlyForItsDraftMembers() {
        let waiting = ticket("a", "CL-2", readiness: "ready", waitsFor: ["CL-1"]), free = ticket("c", "CL-5", readiness: "ready", waitsFor: [])
        let onlyWaiting = drafts([waiting, free], triageMembers: ["a", "c"])
        XCTAssertTrue(onlyWaiting.triages.isEmpty)
        XCTAssertTrue(onlyWaiting.ordinaryTickets.isEmpty)
        let draft = ticket("b", "CL-3", readiness: "draft", waitsFor: [])
        let withDraft = drafts([waiting, draft], triageMembers: ["a", "b"])
        XCTAssertEqual(withDraft.triages.map(\.id), ["g"])
        XCTAssertEqual(withDraft.triages.first?.visibleMembers.map(\.id), ["b"])
    }
    func testParkedAndBlockedDraftsKeepTheirStatusAndDraftMark() {
        for (category, name) in [("queued", "Queued"), ("parked", "Later"), ("blocked", "Blocked")] {
            var values = ticket(category, "CL-10", readiness: "draft", waitsFor: [], category: category).values
            values["status_name"] = name
            let draft = Record(values: values)
            XCTAssertEqual(TicketVisibility.category(draft), category == "queued" ? "draft" : category)
            XCTAssertEqual(TicketVisibility.groupLabel(draft), category == "queued" ? "Drafts" : name)
            XCTAssertEqual(TicketVisibility.statusLabel(draft), name)
            let row = TaskRowPresentation(task: draft, selected: false, projectName: nil, age: "now")
            XCTAssertEqual(row.statusName, name)
            XCTAssertEqual(row.statusCategory, category)
            XCTAssertTrue(row.draft); XCTAssertTrue(row.showsStatus)
            let detail = TicketStatusPills(task: draft)
            XCTAssertEqual(detail.name, row.statusName)
            XCTAssertEqual(detail.category, row.statusCategory)
            XCTAssertTrue(detail.draft)
            XCTAssertTrue(TicketVisibility.matchesStatus(draft, filter: "draft", activeTriageMember: false))
            XCTAssertTrue(TicketVisibility.matchesStatus(draft, filter: category, activeTriageMember: false))
        }
    }

    func testReadinessChangesInvalidateTheRenderedRowWithoutChangingStatus() {
        let ready = ticket("same", "CL-11", readiness: "ready", waitsFor: [], category: "blocked")
        var values = ready.values; values["readiness"] = "draft"
        let draft = Record(values: values)
        let before = TaskRowPresentation(task: ready, selected: false, projectName: nil, age: "now")
        let after = TaskRowPresentation(task: draft, selected: false, projectName: nil, age: "now")
        XCTAssertEqual(before.statusName, after.statusName)
        XCTAssertFalse(before.draft); XCTAssertTrue(after.draft)
        XCTAssertNotEqual(before, after, "A new Draft mark must redraw an otherwise unchanged row")
    }

}
