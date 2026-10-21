import XCTest
import GRDB
@testable import ChecklistCore

/// CL-68: optional Bug and Playtest starter fields are structured ticket data and reach agent context.
extension CoreTests {
    func testBugAndPlaytestStarterFieldsAreOptionalStructuredAndInContext() throws {
        let p = try project("Starters", "SF"), pid = p["id"] as! String
        let titleOnly = try call("task_create", ["project_id": pid, "title": "Just a thought"])
        XCTAssertNil(titleOnly["starter_fields"], "Title-only Draft capture still works")
        XCTAssertEqual(titleOnly["readiness"] as? String, "draft")

        let bug = try call("task_create", ["project_id": pid, "title": "Jump fails", "kind": "bug",
                                           "starter_fields": ["reproduction": "1. Start level 2\n2. Press jump twice", "expected": "Double jump", "actual": "Nothing happens"]])
        XCTAssertThrowsError(try call("task_create", ["project_id": pid, "title": "Wrong", "kind": "work", "starter_fields": ["reproduction": "x"]])) {
            XCTAssertEqual(($0 as? CoreError)?.code, "INVALID_INPUT")
        }
        XCTAssertThrowsError(try call("task_create", ["project_id": pid, "title": "Wrong", "kind": "bug", "starter_fields": ["build": "12"]]), "A Bug has no build field") {
            XCTAssertEqual(($0 as? CoreError)?.code, "INVALID_INPUT")
        }
        let fields = bug["starter_fields"] as! JSON
        XCTAssertEqual(fields["expected"] as? String, "Double jump")
        let context = try call("task_context", ["project_id": pid, "task_id": bug["id"]!])
        XCTAssertEqual(((context["task"] as! JSON)["starter_fields"] as? JSON)?["actual"] as? String, "Nothing happens", "Agents get the fields in task context")

        let playtest = try call("task_create", ["project_id": pid, "title": "Try the new boss", "kind": "playtest",
                                                "starter_fields": ["build": "0.4.2 (118)", "platform": "macOS", "clip": "  "]])
        XCTAssertEqual((playtest["starter_fields"] as? JSON)?["platform"] as? String, "macOS")
        XCTAssertNil((playtest["starter_fields"] as? JSON)?["clip"], "An empty field is not stored")

        // An edit replaces the whole set; a kind change keeps only the fields the new kind uses and history keeps the rest.
        let edited = try call("task_edit", ["project_id": pid, "task_id": bug["id"]!, "expected_revision": bug["revision"]!, "patch": ["starter_fields": ["actual": "Character falls through the floor"]]])
        XCTAssertEqual((edited["starter_fields"] as? JSON)?.keys.sorted(), ["actual"])
        XCTAssertEqual((edited["starter_fields"] as? JSON)?["actual"] as? String, "Character falls through the floor")
        let changed = try call("task_edit", ["project_id": pid, "task_id": bug["id"]!, "expected_revision": edited["revision"]!, "patch": ["kind": "playtest"]])
        XCTAssertNil(changed["starter_fields"])
        let history = try router.dbQueue.read { db in try Row.fetchAll(db, sql: "SELECT data FROM events WHERE kind='task_edited' ORDER BY seq DESC LIMIT 1") }
        XCTAssertTrue((history.first?["data"] as String?)?.contains("Character falls through the floor") == true, "History keeps the removed text")
        let cleared = try call("task_edit", ["project_id": pid, "task_id": playtest["id"]!, "expected_revision": playtest["revision"]!, "patch": ["starter_fields": [String: Any]()]])
        XCTAssertNil(cleared["starter_fields"], "An empty set clears the fields")
    }
}
