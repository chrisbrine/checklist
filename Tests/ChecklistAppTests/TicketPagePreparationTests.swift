import XCTest
@testable import ChecklistApp

@MainActor final class TicketPagePreparationTests: XCTestCase {
    func testCancelRetiresOnlyMatchingRequestAndPreservesPreparation() throws {
        // Cancellation/generation logic needs the page protocol, not SQLite.
        let query = TicketPageQuery(surface: "tickets", projectID: nil, text: "", statusFilter: "all", tagFilter: "all", groupBy: "status", orderBy: "manual")
        let page = try TicketPage(response: ["schema_version": 1, "tickets_page": [
            "query_key": "empty-query", "content_cursor": "empty-content", "tasks": [], "ordinary_ids": [], "triages": [],
            "scoped_count": 0, "matched_count": 0, "has_more": false, "next_cursor": NSNull(), "previous_cursor": NSNull(),
            "projects": [], "statuses": [], "tags": [], "epics": [], "outstanding_request_count": 0, "human_task_count": 0,
            "overview_requests": [], "overview_request_count": 0, "service": ["store_incarnation": "page-fixture"]]])
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

    func testStatusOverlayRegroupsNonAdjacentLabelsAndFullPageReplacesIt() throws {
        let tasks: [[String:Any]] = zip(["a","b","c"],["Active","Review","Queued"]).map {id,status in
            ["id":id,"project_id":"p","title":id,"revision":1,"status_id":status,"status_name":status,"status_category":status.lowercased()]
        }
        let page = try TicketPage(response:["schema_version":1,"tickets_page":[
            "query_key":"q","content_cursor":"c","tasks":tasks,"ordinary_ids":["a","b","c"],"triages":[],
            "scoped_count":3,"matched_count":3,"has_more":false,"next_cursor":NSNull(),"previous_cursor":NSNull(),
            "projects":[["id":"p"]],"statuses":[],"tags":[],"epics":[],"outstanding_request_count":0,"human_task_count":0,
            "overview_requests":[],"overview_request_count":0,"service":["store_incarnation":"s"]]])
        let query = TicketPageQuery(surface:"tickets",projectID:"p",text:"",statusFilter:"all",tagFilter:"all",groupBy:"status",orderBy:"manual")
        var preparation = TicketPagePreparation()
        XCTAssertTrue(preparation.receive(page,for:preparation.begin(query:query)))
        let patch = Record(values:["id":"c","project_id":"p","revision":2,"status_id":"Active","status_name":"Active","status_category":"active","title":"Do not replace text"])
        preparation.applyCommittedStatuses([(patch,[])])
        let displayed = preparation.prepared(expansion:TicketWorkspaceExpansion())
        XCTAssertEqual(displayed?.ordinaryGroups.map {$0.0},["Active","Review"])
        XCTAssertEqual(displayed?.ordinaryGroups.first?.1.map(\.id),["a","c"])
        XCTAssertEqual(preparation.displayedTasks.last?.string("title"),"c")
        XCTAssertTrue(preparation.receive(page,for:preparation.begin(query:query)))
        XCTAssertEqual(preparation.prepared(expansion:TicketWorkspaceExpansion())?.ordinaryGroups.map {$0.0},["Active","Review","Queued"])
    }

    func testWorkspaceGenerationCancellationPreservesAcceptedRowsAndNewerState() throws {
        let observation = WorkspacePageObservation(), query = WorkspacePageQuery(surface: "epics", project: nil)
        let response: [String: Any] = ["workspace_version": 1, "needs_you_count": 0, "surface": "epics", "record_id": "", "rows": [["id": "e", "project_id": "p"]], "total": 1,
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
