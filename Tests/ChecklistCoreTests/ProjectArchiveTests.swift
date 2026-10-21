import XCTest
import GRDB
@testable import ChecklistCore

/// CL-130: archive and restore a project without losing its tickets, settings or identity.
extension CoreTests {
    func testProjectArchiveNeedsSafeWorkAndRestoreKeepsTheSameProject() throws {
        let archived = try project("Archive me", "AR"), other = try project("Stays", "ST")
        let pid = archived["id"] as! String
        let ticket = try ready(archived, try task(archived, "Ready work"))
        let tid = ticket["id"] as! String
        _ = try ready(other, try task(other, "Other ready work"))
        func archive(_ value: Bool) throws -> JSON {
            let current = try call("project_list", ["include_archived": true])["projects"] as! [JSON]
            let revision = current.first { $0["id"] as? String == pid }!["revision"]!
            return try call("project_archive", ["project_id": pid, "expected_revision": revision, "archived": value])
        }
        func pickupKeys() throws -> Set<String> {
            let rows = try call("workspace_page", ["surface": "needs_pickup", "limit": 50])["rows"] as! [JSON]
            return Set(rows.compactMap { $0["key"] as? String })
        }
        XCTAssertTrue(try pickupKeys().contains("AR-1"))

        // Active work blocks archive and names the ticket.
        try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {
            try router.save(db, ["id": "attempt-ar", "project_id": pid, "task_id": tid, "state": "active", "phase": "implementation", "revision": 1], type: "attempt")
            return .commit
        }}
        XCTAssertThrowsError(try archive(true)) { error in
            XCTAssertEqual((error as? CoreError)?.code, "CLAIM_CONFLICT")
            XCTAssertTrue((error as? CoreError)?.message.contains("AR-1") == true, "The refusal names the ticket with active work")
        }
        try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {
            var attempt = try router.record(db, "attempt-ar", type: "attempt"); attempt["state"] = "released"; try router.save(db, router.revised(attempt), type: "attempt")
            return .commit
        }}

        // An open owner request blocks archive until it is answered or canceled.
        let request = try call("human_request_create", ["project_id": pid, "task_id": tid, "title": "Pick one", "blocking": true,
                                                        "questions": [["id": "q1", "prompt": "Which?", "type": "text"]]])
        XCTAssertThrowsError(try archive(true)) { error in
            XCTAssertEqual((error as? CoreError)?.code, "CLAIM_CONFLICT")
            XCTAssertTrue((error as? CoreError)?.message.contains("open owner requests") == true)
        }
        _ = try call("human_request_cancel", ["project_id": pid, "request_id": request["id"]!, "expected_revision": request["revision"]!, "reason": "Not needed"])

        let result = try archive(true)
        XCTAssertEqual(result["archived"] as? Bool, true)
        let listed = try call("project_list")["projects"] as! [JSON]
        XCTAssertFalse(listed.contains { $0["id"] as? String == pid }, "An archived project leaves the ordinary project list")
        XCTAssertTrue(listed.contains { $0["id"] as? String == other["id"] as? String })
        XCTAssertTrue((try call("project_list", ["include_archived": true])["projects"] as! [JSON]).contains { $0["id"] as? String == pid })
        XCTAssertFalse(try pickupKeys().contains("AR-1"), "All-project lists leave out an archived project")
        XCTAssertTrue(try pickupKeys().contains("ST-1"))
        XCTAssertThrowsError(try call("task_create", ["project_id": pid, "title": "New"])) { XCTAssertEqual(($0 as? CoreError)?.code, "PROJECT_ARCHIVED") }
        let kept = try call("task_get", ["project_id": pid, "task_id": tid])
        XCTAssertEqual(kept["title"] as? String, "Ready work", "Tickets stay readable while the project is archived")
        XCTAssertEqual((try call("workspace_page", ["project_id": pid, "surface": "needs_pickup", "limit": 5])["rows"] as! [JSON]).count, 1,
                       "The archived project's own pages stay readable")

        let restored = try archive(false)
        XCTAssertEqual(restored["archived"] as? Bool, false)
        XCTAssertEqual(restored["id"] as? String, pid); XCTAssertEqual(restored["name"] as? String, "Archive me"); XCTAssertEqual(restored["key_prefix"] as? String, "AR")
        let projects = try call("project_list")["projects"] as! [JSON]
        XCTAssertEqual(projects.filter { $0["id"] as? String == pid }.count, 1, "Restore keeps one project identity")
        XCTAssertTrue(try pickupKeys().contains("AR-1"))
        XCTAssertNoThrow(try call("task_create", ["project_id": pid, "title": "After restore"]))
    }
}
