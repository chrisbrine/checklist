import XCTest
import GRDB
@testable import ChecklistCore

/// Owned projection fixtures include historical mixed-phase membership; current
/// membership commands still enforce separate Implementation and Review Triages.
final class ActiveSectionTests: XCTestCase {
    private var root: URL!
    private var router: CommandRouter!
    private var pid = ""
    private let owner = Caller(role: "owner", installation: "active-section-tests", projectIDs: [])
    private var worker: Caller { Caller(role: "worker", installation: "active-section-worker", projectIDs: [pid], workspace: root.path) }
    private let members = ["queued", "draft", "review", "active", "blocked", "parked", "done"]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("active-section-" + UUID().uuidString)
        router = try CommandRouter(root: root)
        pid = try call("project_create", ["name": "Active section fixture", "key_prefix": "AS", "root_path": root.path])["id"] as! String
        try write { db in
            for category in self.members where category != "draft" {
                try self.router.save(db, ["id": "status-" + category, "project_id": self.pid, "revision": 1,
                                         "name": category == "active" ? "In progress" : category.capitalized, "category": category], type: "status")
            }
            for id in self.members {
                var task: JSON = ["id": id, "project_id": self.pid, "key": "AS-" + id, "revision": 1, "title": id,
                                  "kind": "work", "brief": "Synthetic projection fixture", "acceptance": ["Only own Active status"], "acceptance_revision": 1,
                                  "status_id": "status-" + (id == "draft" ? "queued" : id), "readiness": id == "draft" ? "draft" : "ready",
                                  "archived": false, "trashed": false, "tag_ids": [String](), "updated_at": "2026-10-22T00:00:00Z"]
                if id == "queued" { task["planned_assignee"] = "human" }
                try self.router.save(db, task, type: "task")
            }
            try self.router.save(db, ["id": "owner-question", "project_id": self.pid, "task_id": "queued", "revision": 1, "state": "pending"], type: "request")
            try self.router.save(db, ["id": "triage", "project_id": self.pid, "revision": 1, "kind": "triage", "phase": "implementation",
                                     "name": "Historical mixed Triage", "purpose": "Projection coverage", "archived": false, "task_ids": self.members], type: "group")
        }
    }
    override func tearDownWithError() throws { router = nil; try? FileManager.default.removeItem(at: root) }
    private func call(_ method: String, _ input: JSON, _ caller: Caller? = nil) throws -> JSON {
        var input = input
        if !CommandRouter.readMethods.contains(method) { input["command_id"] = UUID().uuidString }
        return try router.handle(method: method, params: input, caller: caller ?? owner)["data"] as! JSON
    }
    private func write(_ body: (Database) throws -> Void) throws {
        try router.dbQueue.writeWithoutTransaction { db in
            try router.withValidatedDomainTransaction(db) { try body(db); return .commit }
        }
    }
    private func orchestration(_ active: Bool) throws {
        try write { db in
            var group = try self.router.record(db, "triage", type: "group")
            if active { group["orchestration"] = ["state": "active", "session_id": "coordinator", "actor_display": "Fixture coordinator"] }
            else { group.removeValue(forKey: "orchestration") }
            try self.router.save(db, group, type: "group")
        }
    }
    private func page(_ status: String, surface: String = "tickets", limit: Int = 200, cursor: Any? = nil) throws -> JSON {
        var input: JSON = ["project_id": pid, "limit": limit, "view": ["surface": surface, "status_filter": status, "tag_filter": "all", "group_by": "status", "order_by": "manual"]]
        if let cursor { input["cursor"] = cursor }
        return try call("task_list", input)["tickets_page"] as! JSON
    }
    private func ids(_ reply: JSON) -> Set<String> { Set((reply["tasks"] as! [JSON]).compactMap { $0["id"] as? String }) }

    func testOrchestratedAndUnorchestratedActivePagesCountsAndSidebar() throws {
        for orchestrated in [false, true] {
            try orchestration(orchestrated)
            let active = try page("active")
            XCTAssertEqual(ids(active), ["active"])
            XCTAssertEqual(active["matched_count"] as? Int, 1)
            XCTAssertEqual(active["scoped_count"] as? Int, 6)
            let summary = try XCTUnwrap((active["triages"] as! [JSON]).first)
            XCTAssertEqual(summary["member_count"] as? Int, 7)
            XCTAssertEqual(summary["matching_count"] as? Int, 1)
            XCTAssertEqual(summary["page_member_ids"] as? [String], ["active"])
            if orchestrated {
                XCTAssertEqual((summary["orchestration"] as? JSON)?["actor_display"] as? String, "Fixture coordinator")
                XCTAssertEqual((summary["orchestration"] as? JSON)?["session_id"] as? String, "coordinator")
            } else { XCTAssertNil(summary["orchestration"]) }
            XCTAssertEqual(ids(try page("queued")), ["queued", "draft"])
            XCTAssertEqual(ids(try page("draft")), ["draft"])
            XCTAssertEqual(ids(try page("review")), ["review"])
            XCTAssertEqual(ids(try page("active", surface: "archived")), [])
            XCTAssertEqual(ids(try page("active", surface: "overview")), ["active"])
            // The actual sidebar badge is Needs You, not Active.
            XCTAssertEqual(active["outstanding_request_count"] as? Int, 1)
            XCTAssertEqual(active["human_task_count"] as? Int, 1)
            let counts = try router.dbQueue.read { try router.ownerNeedsYouCounts($0) }
            XCTAssertEqual(counts.requests + counts.tasks, 2)
            // Header-only and continuation pages keep exact distinct totals.
            let header = try page("active", limit: 1)
            XCTAssertEqual(ids(header), [])
            XCTAssertEqual(header["matched_count"] as? Int, 1)
            let member = try page("active", limit: 1, cursor: header["next_cursor"])
            XCTAssertEqual(ids(member), ["active"])
            XCTAssertEqual(member["matched_count"] as? Int, 1)
        }
    }

    func testAgentReadsKeepExactStatusSelectionAndAdvisoryAttention() throws {
        try orchestration(true)
        let listed = try call("task_list", ["project_id": pid, "status_ids": ["status-active"]], worker)
        XCTAssertEqual(ids(listed), ["active"])
        XCTAssertEqual(listed["total"] as? Int, 1)
        for id in members {
            let task = try call("task_get", ["project_id": pid, "task_id": id], worker)
            XCTAssertEqual(task["status_category"] as? String, id == "draft" ? "queued" : id)
            XCTAssertEqual(task["active_attention"] as? Bool, true, "Compatibility attention remains advisory, even outside Active")
        }
        let context = try call("task_context", ["project_id": pid, "task_id": "queued"], worker)
        XCTAssertEqual((context["task"] as? JSON)?["status_category"] as? String, "queued")
        let triage = try XCTUnwrap((call("triage_list", ["project_id": pid], worker)["groups"] as! [JSON]).first)
        XCTAssertEqual((triage["orchestration"] as? JSON)?["session_id"] as? String, "coordinator")
    }

    func testActiveAttemptDoesNotOverrideOwnCategory() throws {
        try write { db in
            var review = try self.router.record(db, "review", type: "task")
            review["active_attempt_id"] = "review-attempt"
            try self.router.save(db, review, type: "task")

        }
        XCTAssertEqual(ids(try page("active")), ["active"])
    }

    func testOverviewActiveWorkExcludesReviewAttempts() throws {
        try orchestration(true)
        try write { db in
            for id in ["active", "review"] {
                var task = try self.router.record(db, id, type: "task"); task["active_attempt_id"] = "attempt-" + id
                try self.router.save(db, task, type: "task")
                try self.router.save(db, ["id": "attempt-" + id, "project_id": self.pid, "task_id": id, "state": "active",
                                         "phase": id == "review" ? "review" : "implementation", "session_id": "human",
                                         "last_checkpoint": ISO8601DateFormatter().string(from: Date()), "revision": 1], type: "attempt")
            }
        }
        let work = try call("workspace_page", ["project_id": pid, "surface": "needs_active"])
        XCTAssertEqual(Set((work["rows"] as! [JSON]).compactMap { $0["id"] as? String }), ["active"])
        XCTAssertEqual(work["total"] as? Int, 1)
    }
}

extension EvidenceAuthorityTests {
    func testActiveSectionKeepsOrchestratedQueuedWorkHealth() throws {
        let project = try project(), task = try ready(project), sibling = try ready(project)
        let coordinator = try native(project, "active-section-health", domain: "active-section-health")
        var group = try call("triage_create", ["project_id": project["id"]!, "name": "Advisory attention", "phase": "implementation"])
        for member in [task, sibling] {
            group = try call("group_membership", ["project_id": project["id"]!, "group_id": group["id"]!, "task_id": member["id"]!, "expected_revision": group["revision"]!, "action": "add"])
        }
        _ = try call("triage_orchestrate", ["project_id": project["id"]!, "triage_id": group["id"]!, "expected_revision": group["revision"]!, "action": "start"], coordinator)
        _ = try router.runWorkHealthChecks(at: Date().addingTimeInterval(1202))
        let health = try call("work_health_get", ["project_id": project["id"]!, "task_id": task["id"]!])
        XCTAssertEqual((health["current_target"] as? JSON)?["kind"] as? String, "orchestration")
        XCTAssertEqual((health["deliveries"] as? [JSON])?.first?["recipient_session_id"] as? String, coordinator.sessionID)
        let active = try call("task_list", ["project_id": project["id"]!, "view": ["surface": "tickets", "status_filter": "active", "tag_filter": "all", "group_by": "status", "order_by": "manual"]])["tickets_page"] as! JSON
        XCTAssertEqual(active["matched_count"] as? Int, 0)
    }
}
