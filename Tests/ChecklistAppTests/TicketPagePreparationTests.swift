import XCTest
@testable import ChecklistApp
@testable import ChecklistCore

@MainActor final class TicketPagePreparationTests: XCTestCase {
    func testCancelRetiresOnlyMatchingRequestAndPreservesPreparation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-cancel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let router = try CommandRouter(root: root)
        let query = TicketPageQuery(surface: "tickets", projectID: nil, text: "", statusFilter: "all", tagFilter: "all", groupBy: "status", orderBy: "manual")
        let reply = try router.handle(method: "task_list", params: query.parameters(), caller: Caller(role: "owner", installation: "page-cancel", projectIDs: []))
        let page = try TicketPage(response: reply["data"] as! [String: Any])
        var preparation = TicketPagePreparation()
        XCTAssertTrue(preparation.receive(page, for: preparation.begin(query: query)))
        let rows = preparation.prepared(expansion: TicketWorkspaceExpansion())?.rows.count
        let old = preparation.begin(query: query), current = preparation.begin(query: query)
        preparation.cancel(old)
        XCTAssertTrue(preparation.loading)
        preparation.cancel(current)
        XCTAssertFalse(preparation.loading)
        XCTAssertNil(preparation.error)
        XCTAssertEqual(preparation.page?.queryKey, page.queryKey)
        XCTAssertEqual(preparation.prepared(expansion: TicketWorkspaceExpansion())?.rows.count, rows)
        XCTAssertFalse(preparation.receive(page, for: current), "Canceled replies cannot install")
        let newer = preparation.begin(query: query)
        preparation.fail(newer)
        preparation.cancel(old)
        XCTAssertNotNil(preparation.error, "Old cancellation cannot clear a newer failure")
    }

    func testWorkspaceGenerationCancellationPreservesAcceptedRowsAndNewerState() throws {
        let observation = WorkspacePageObservation(), query = WorkspacePageQuery(surface: "epics", project: nil)
        let response: [String: Any] = ["workspace_version": 1, "surface": "epics", "record_id": "", "rows": [["id": "e", "project_id": "p"]], "total": 1,
            "has_more": false, "next_cursor": NSNull(), "previous_cursor": NSNull(), "projects": [["id": "p"]], "service": ["store_incarnation": "s"], "content_cursor": "c"]
        XCTAssertTrue(try observation.receive(response, query: query, generation: observation.begin(query)))
        let old = observation.begin(query), newer = observation.begin(query)
        observation.cancel(old)
        XCTAssertTrue(observation.loading)
        observation.cancel(newer)
        XCTAssertFalse(observation.loading); XCTAssertNil(observation.error)
        XCTAssertEqual(observation.page?.rows.map(\.id), ["e"])
        XCTAssertFalse(try observation.receive(response, query: query, generation: newer))
        let failed = observation.begin(query); observation.fail(failed); observation.cancel(old)
        XCTAssertNotNil(observation.error)
    }
}
