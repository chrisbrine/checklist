import XCTest
@testable import ChecklistApp

final class TicketListStabilityTests: XCTestCase {
    private func task(_ id: String) -> Record { Record(values: ["id": id, "project_id": "p", "title": id, "key": id]) }
    /// A bounded ticket page summary: page_member_ids only, never task_ids.
    private func pageSection(_ id: String, members: [String]) -> InlineTriageSection {
        let summary = Record(values: ["id": id, "project_id": "p", "kind": "triage", "name": id, "purpose": "Purpose \(id)",
                                      "page_member_ids": members, "members_complete": false, "member_count": members.count])
        return InlineTriageSection(triage: summary, allMembers: [], visibleMembers: members.map(task), matchesGroupSearch: false)
    }
    private func snapshotSection(_ id: String, members: [String]) -> InlineTriageSection {
        let triage = Record(values: ["id": id, "project_id": "p", "kind": "triage", "name": id, "purpose": "Purpose \(id)", "task_ids": members])
        return InlineTriageSection(triage: triage, allMembers: members.map(task), visibleMembers: members.map(task), matchesGroupSearch: false)
    }
    private func rows(_ sections: [InlineTriageSection], expanded: [String], ordinary: [String]) -> [TicketListRow] {
        TicketListRows.make(triages: sections, expandedIDs: Set(expanded), ordinaryGroups: ordinary.isEmpty ? [] : [("Tickets", ordinary.map(task))])
    }

    func testPageSummaryHeadersStayWhileHeldForExpandedAndCollapsedTriages() {
        let sections = [pageSection("A", members: ["a1", "a2"]), pageSection("B", members: []), pageSection("C", members: ["c1"])]
        let prior = rows(sections, expanded: ["A"], ordinary: ["o1"])
        let visible = RecordIdentitySet(["a1", "a2", "c1", "o1"])
        let held = StableTicketRows.holding(prior, current: prior, visibleRecordIDs: visible)
        XCTAssertEqual(held.map(\.id), prior.map(\.id))
        XCTAssertEqual(held.filter { if case .triage = $0.content { return true } else { return false } }.count, 3)
        XCTAssertTrue(held.contains { $0.id == .triagePurpose("A") })
        XCTAssertTrue(held.contains { $0.id == .triageMember(triageID: "A", taskID: "a2") })
    }

    func testRemovedPageSummaryHeaderStaysWhileAPageMemberIsStillVisible() {
        let prior = rows([pageSection("A", members: ["a1"])], expanded: ["A"], ordinary: ["o1"])
        let current = rows([], expanded: [], ordinary: ["o1"])
        let held = StableTicketRows.holding(prior, current: current, visibleRecordIDs: RecordIdentitySet(["a1", "o1"]))
        XCTAssertEqual(held.map(\.id), prior.map(\.id))
    }

    func testFilterRemovingTheLastVisibleMemberRemovesThePageTriage() {
        let prior = rows([pageSection("A", members: ["a1"]), pageSection("B", members: ["b1"])], expanded: ["A", "B"], ordinary: ["o1"])
        let current = rows([pageSection("B", members: ["b1"])], expanded: ["B"], ordinary: ["o1"])
        let held = StableTicketRows.holding(prior, current: current, visibleRecordIDs: RecordIdentitySet(["b1", "o1"]))
        for gone: TicketListRow.ID in [.triage("A"), .triagePurpose("A"), .triageMember(triageID: "A", taskID: "a1"), .triageSeparator("A")] {
            XCTAssertFalse(held.contains { $0.id == gone }, "\(gone) must leave the held list")
        }
        XCTAssertEqual(held.map(\.id), current.map(\.id))
    }

    func testClosedLastMemberRemovesTheSnapshotTriage() {
        let prior = rows([snapshotSection("S", members: ["s1"])], expanded: [], ordinary: ["o1"])
        let current = rows([], expanded: [], ordinary: ["o1"])
        let held = StableTicketRows.holding(prior, current: current, visibleRecordIDs: RecordIdentitySet(["o1"]))
        XCTAssertFalse(held.contains { $0.id == .triage("S") })
        XCTAssertEqual(held.map(\.id), current.map(\.id))
    }

    @MainActor func testPointerHoldKeepsPositionsAndApplyInstallsTheUpdate() {
        let sections = [pageSection("A", members: ["a1"])]
        let prior = rows(sections, expanded: [], ordinary: ["o1", "o2"])
        let updated = rows(sections, expanded: [], ordinary: ["o2", "o1"])
        let visible = RecordIdentitySet(["a1", "o1", "o2"])
        let stability = TicketListStability()
        stability.pointer(true, rows: prior)
        XCTAssertEqual(stability.rows(updated, visibleRecordIDs: visible).map(\.id), prior.map(\.id))
        XCTAssertTrue(stability.pending(updated))
        stability.apply(updated)
        XCTAssertEqual(stability.rows(updated, visibleRecordIDs: visible).map(\.id), updated.map(\.id))
        XCTAssertFalse(stability.pending(updated))
        stability.pointer(false, rows: updated)
        XCTAssertEqual(stability.rows(prior, visibleRecordIDs: visible).map(\.id), prior.map(\.id))
    }
}
