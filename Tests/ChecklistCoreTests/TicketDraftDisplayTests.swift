import ChecklistTestSupport
import XCTest
@testable import ChecklistCore

final class TicketDraftDisplayTests: XCTestCase {
    private var root: URL!
    private var router: CommandRouter!
    private var project = ""
    private let owner = Caller(role: "owner", installation: "draft-display-tests", projectIDs: [])

    override func setUpWithError() throws {
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChecklistQualification/CL-156/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        router = try TestStore.router(root: root)
        project = try call("project_create", ["name": "Synthetic Draft display", "key_prefix": "DRAFT", "root_path": root.path])["id"] as! String
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
    private func page(_ filter: String = "all", surface: String = "tickets") throws -> [JSON] {
        let result = try call("task_list", ["project_id": project, "view": ["surface": surface, "status_filter": filter, "tag_filter": "all", "group_by": "status", "order_by": "manual"], "limit": 100])
        return (result["tickets_page"] as! JSON)["tasks"] as! [JSON]
    }
    private func bulk(_ tickets: [JSON], action: String) throws {
        _ = try call("task_bulk_edit", ["project_id": project, "preview": false, "tasks": tickets.map { ["task_id": $0["id"]!, "expected_revision": $0["revision"]!] }, "changes": ["kind": "status", "action": action, "reason": "Synthetic display check"]])
    }

    func testStatusGroupingSeparatesParkedAndBlockedDraftsFromQueuedDrafts() throws {
        let queued = try ticket("Queued Draft"), parked = try ticket("Parked Draft"), blocked = try ticket("Blocked Draft")
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

    func testBulkDraftStatusIsVisibleOnTheNextReadIncludingCancelAndReopen() throws {
        _ = try ticket("Unchanged queued Draft")
        let pair = try [ticket("First Draft"), ticket("Second Draft")]
        let pairIDs = Set(pair.compactMap { $0["id"] as? String })
        for (action, category) in [("defer", "parked"), ("block", "blocked"), ("queue", "queued"), ("cancel", "canceled"), ("reopen", "queued")] {
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
}
