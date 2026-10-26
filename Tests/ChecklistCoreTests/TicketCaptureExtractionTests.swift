import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

extension CoreTests {
    /// Includes the project counter, primary Epic revision/members, task rows, events
    /// and durable receipts, so a rejected capture cannot consume any of them.
    private func captureSnapshot() throws -> [String] {
        try router.dbQueue.read { db in
            let records = try String.fetchAll(db, sql: "SELECT data FROM records ORDER BY id")
            let events = try String.fetchAll(db, sql: "SELECT id || ':' || kind || ':' || data FROM events ORDER BY seq")
            let commands = try String.fetchAll(db, sql: "SELECT principal || ':' || command_id || ':' || digest || ':' || result FROM commands ORDER BY principal,command_id")
            return records + ["--events--"] + events + ["--commands--"] + commands
        }
    }

    private func rawCapture(_ input: JSON, caller: Caller? = nil) throws -> JSON {
        try router.handle(method: "task_create", params: input, caller: caller ?? owner)
    }

    func testCaptureExtractionValidationLeavesCounterMembershipEventsAndReceiptUntouched() throws {
        let first = try project("Capture", "CAP"), second = try project("Other", "OTH")
        let epic = try call("epic_create", ["project_id": first["id"]!, "name": "Capture Epic"])
        let foreignEpic = try call("epic_create", ["project_id": second["id"]!, "name": "Other Epic"])
        let foreignTag = try call("tag_create", ["project_id": second["id"]!, "name": "Other tag"])
        let base: JSON = ["project_id": first["id"]!, "title": "Atomic capture", "epic_id": epic["id"]!]
        var missingEpic = base; missingEpic.removeValue(forKey: "epic_id")
        var emptyTitle = base; emptyTitle["title"] = "  "
        var invalidKind = base; invalidKind["kind"] = "unsupported-kind"
        var otherEpic = base; otherEpic["epic_id"] = foreignEpic["id"]!
        var otherTag = base; otherTag["tag_ids"] = [foreignTag["id"]!]
        for var input in [missingEpic, emptyTitle, invalidKind, otherEpic, otherTag] {
            input["command_id"] = UUID().uuidString
            let before = try captureSnapshot()
            XCTAssertThrowsError(try rawCapture(input))
            XCTAssertEqual(try captureSnapshot(), before)
        }
    }

    func testCaptureExtractionEventFailureRollsBackThenSameCommandSucceedsOnce() throws {
        let project = try project("Rollback", "RB")
        let epic = try call("epic_create", ["project_id": project["id"]!, "name": "Rollback Epic"])
        let input: JSON = ["command_id": UUID().uuidString, "project_id": project["id"]!, "title": "Rollback capture", "epic_id": epic["id"]!]
        let before = try captureSnapshot()
        try router.dbQueue.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_capture_event BEFORE INSERT ON events WHEN NEW.kind='task_created' BEGIN SELECT RAISE(ABORT, 'synthetic capture event failure'); END")
        }
        XCTAssertThrowsError(try rawCapture(input))
        XCTAssertEqual(try captureSnapshot(), before)
        try router.dbQueue.write { db in try db.execute(sql: "DROP TRIGGER reject_capture_event") }
        let success = try rawCapture(input), after = try captureSnapshot()
        let replay = try rawCapture(input)
        XCTAssertEqual(try jsonString(success["data"]!), try jsonString(replay["data"]!))
        XCTAssertEqual(success["event_cursor"] as? String, replay["event_cursor"] as? String)
        XCTAssertEqual(replay["replayed"] as? Bool, true)
        XCTAssertEqual(try captureSnapshot(), after)
        let task = success["data"] as! JSON
        XCTAssertEqual(task["key"] as? String, "RB-1")
        XCTAssertEqual(task["readiness"] as? String, "draft")
        try router.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events WHERE kind='task_created'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM commands WHERE command_id=?", arguments: [input["command_id"] as! String]), 1)
            XCTAssertEqual(int(try router.record(db, project["id"] as! String, type: "project"), "next_number"), 2)
            XCTAssertEqual(strings(try router.record(db, epic["id"] as! String, type: "group"), "task_ids"), [task["id"] as! String])
        }
    }

    func testCaptureExtractionSameCommandChangedPayloadConflictsWithoutMutation() throws {
        let project = try project("Conflict", "CF")
        let epic = try call("epic_create", ["project_id": project["id"]!, "name": "Conflict Epic"])
        var input: JSON = ["command_id": UUID().uuidString, "project_id": project["id"]!, "title": "First capture", "epic_id": epic["id"]!]
        _ = try rawCapture(input)
        let before = try captureSnapshot()
        input["title"] = "Different capture"
        assertCode("IDEMPOTENCY_CONFLICT") { _ = try self.rawCapture(input) }
        XCTAssertEqual(try captureSnapshot(), before)
    }

    func testCaptureExtractionCommandReceiptsAreScopedToDistinctWorkerPrincipals() throws {
        let workspace = directory.appendingPathComponent("capture-workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let project = try call("project_create", ["name": "Workers", "key_prefix": "WK", "root_path": workspace.path])
        let pid = project["id"] as! String
        let epic = try call("epic_create", ["project_id": pid, "name": "Worker Epic"])
        var workers: [Caller] = []
        for installation in ["capture-worker-one", "capture-worker-two"] {
            let sid = UUID().uuidString
            _ = try call("session_register", ["project_id": pid, "session_id": sid, "provider": "codex", "role": "worker", "installation": installation])
            workers.append(Caller(role: "worker", installation: installation, projectIDs: [pid], sessionID: sid, workspace: workspace.path))
        }
        let input: JSON = ["command_id": UUID().uuidString, "project_id": pid, "title": "Shared command UUID", "epic_id": epic["id"]!]
        let first = try rawCapture(input, caller: workers[0]), second = try rawCapture(input, caller: workers[1])
        let a = first["data"] as! JSON, b = second["data"] as! JSON
        XCTAssertNotEqual(a["id"] as? String, b["id"] as? String)
        XCTAssertEqual(a["key"] as? String, "WK-1")
        XCTAssertEqual(b["key"] as? String, "WK-2")
        XCTAssertEqual(a["created_by"] as? String, workers[0].principal)
        XCTAssertEqual(b["created_by"] as? String, workers[1].principal)
        let before = try captureSnapshot()
        for (index, original) in [first, second].enumerated() {
            let replay = try rawCapture(input, caller: workers[index])
            XCTAssertEqual(try jsonString(replay["data"]!), try jsonString(original["data"]!))
            XCTAssertEqual(replay["replayed"] as? Bool, true)
        }
        XCTAssertEqual(try captureSnapshot(), before)
        try router.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM commands WHERE command_id=?", arguments: [input["command_id"] as! String]), 2)
        }
    }
}
