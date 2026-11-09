import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

final class TicketDraftDisplayTests: XCTestCase {
    private var root: URL!
    private var router: CommandRouter!
    private var project = ""
    private let owner = Caller(role: "owner", installation: "draft-display-tests", projectIDs: [])

    private static func phase(_ name: String,_ titles: [String]) -> TestStore.Template {
        TestStore.Template(name:"draft-display-" + name) { router,workspace in
            let fixture = TicketDraftDisplayTests()
            fixture.root = workspace;fixture.router = router
            fixture.project = try fixture.call("project_create",["name":"Synthetic Draft display","key_prefix":"DRAFT","root_path":workspace.path])["id"] as! String
            for title in titles {_ = try fixture.ticket(title)}
        }
    }
    private static let groupingPhase = phase("grouping",["Queued Draft","Parked Draft","Blocked Draft"])
    private static let bulkPhase = phase("bulk",["Unchanged queued Draft","First Draft","Second Draft"])
    override func setUpWithError() throws {
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChecklistQualification/CL-156/" + UUID().uuidString)
        let phase = name.contains("StatusGrouping") ? Self.groupingPhase : Self.bulkPhase
        router = try TestStore.router(root:root.appendingPathComponent("store"),template:phase,workspace:root.appendingPathComponent("workspace"))
        project = try router.dbQueue.read {try XCTUnwrap(router.records($0,type:"project").first?["id"] as? String)}
    }
    override func tearDownWithError() throws { router = nil; try FileManager.default.removeItem(at: root) }
    private func call(_ method: String, _ input: JSON) throws -> JSON {
        var input = input
        if !CommandRouter.readMethods.contains(method) { input["command_id"] = UUID().uuidString }
        return try router.handle(method: method, params: fixtureTaskInput(router,method:method,input:input), caller: owner)["data"] as! JSON
    }
    private func ticket(_ title: String) throws -> JSON {
        try call("task_create", ["project_id": project, "title": title, "brief": "Synthetic outcome"])
    }
    private func storedTicket(_ title: String) throws -> JSON {
        try router.dbQueue.read {try XCTUnwrap(router.records($0,type:"task",project:project).first {$0["title"] as? String == title})}
    }
    private func page(_ filter: String = "all", surface: String = "tickets") throws -> [JSON] {
        let result = try call("task_list", ["project_id": project, "view": ["surface": surface, "status_filter": filter, "tag_filter": "all", "group_by": "status", "order_by": "manual"], "limit": 100])
        return (result["tickets_page"] as! JSON)["tasks"] as! [JSON]
    }
    private func bulk(_ tickets: [JSON], action: String) throws {
        _ = try call("task_bulk_edit", ["project_id": project, "preview": false, "tasks": tickets.map { ["task_id": $0["id"]!, "expected_revision": $0["revision"]!] }, "changes": ["kind": "status", "action": action, "reason": "Synthetic display check"]])
    }

    func testStatusGroupingSeparatesParkedAndBlockedDraftsFromQueuedDrafts() throws {
        let queued = try storedTicket("Queued Draft"), parked = try storedTicket("Parked Draft"), blocked = try storedTicket("Blocked Draft")
        try bulk([parked], action: "defer"); try bulk([blocked], action: "block")
        let rows = try page()
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, [blocked, parked, queued].compactMap { $0["id"] as? String }, "Status groups use Blocked, Parked, then Drafts, rather than one Draft group")
        XCTAssertEqual(try page("draft").count, 3, "Drafts filter includes every open brief needing refinement")
        for (category, ticket) in [("queued", queued), ("parked", parked), ("blocked", blocked)] {
            let filtered = try page(category)
            XCTAssertEqual(filtered.first?["id"] as? String, ticket["id"] as? String)
            XCTAssertEqual(filtered.count, 1)
            XCTAssertEqual(filtered.first?["readiness"] as? String, "draft")
            XCTAssertEqual(filtered.first?["status_category"] as? String, category)
            let row = try XCTUnwrap(filtered.first)
            XCTAssertEqual(try page(row["status_id"] as! String).count, 1)
        }
        XCTAssertTrue(try page("ready").isEmpty)
    }

    func testBulkDraftStatusIsVisibleOnTheNextReadIncludingCancelAndReopen() throws {try assertBulkDraftStatus(at:0)}
    func testBulkDraftBlockedStatusIsVisibleOnTheNextRead() throws {try assertBulkDraftStatus(at:1)}
    func testBulkDraftQueuedStatusIsVisibleOnTheNextRead() throws {try assertBulkDraftStatus(at:2)}
    func testBulkDraftCanceledStatusIsVisibleOnTheNextRead() throws {try assertBulkDraftStatus(at:3)}
    func testBulkDraftReopenedStatusIsVisibleOnTheNextRead() throws {try assertBulkDraftStatus(at:4)}

    private func assertBulkDraftStatus(at index: Int) throws {
        let pair = try [storedTicket("First Draft"), storedTicket("Second Draft")]
        let pairIDs = Set(pair.compactMap { $0["id"] as? String })
        let actions = [("defer", "parked"), ("block", "blocked"), ("queue", "queued"), ("cancel", "canceled"), ("reopen", "queued")]
        // Preserve the original predecessor states and transition sequence. The
        // selected action still executes through the public bulk entry point;
        // preparation uses the same domain operation without command journals.
        for (action,_) in actions.prefix(index) {
            try router.dbQueue.writeWithoutTransaction {db in
                try router.withValidatedDomainTransaction(db) {
                    let current = try pair.map {try router.record(db,$0["id"] as! String,type:"task")}
                    _ = try router.taskBulkEdit(db,["command_id":uuid(),"project_id":project,"preview":false,"tasks":current.map {["task_id":$0["id"]!,"expected_revision":$0["revision"]!]},"changes":["kind":"status","action":action,"reason":"Synthetic display check"]],owner)
                    return .commit
                }
            }
        }
        let (action,category) = actions[index]
            let current = try page("all", surface: action == "reopen" ? "archived" : "tickets").filter { pairIDs.contains($0["id"] as! String) }
            XCTAssertEqual(current.count, 2)
            try bulk(current, action: action)
            let updated = try page(category, surface: category == "canceled" ? "archived" : "tickets")
                .filter { pairIDs.contains($0["id"] as! String) }
            XCTAssertEqual(updated.count, 2)
            XCTAssertTrue(updated.allSatisfy { $0["status_category"] as? String == category && $0["readiness"] as? String == "draft" })
            if ["parked", "blocked"].contains(category) {
                XCTAssertTrue(pairIDs.contains(try page().first!["id"] as! String), "Changed status group must precede queued Drafts immediately")
            }
            XCTAssertEqual(try page("draft").count, category == "canceled" ? 1 : 3)
    }
}
