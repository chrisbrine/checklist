import XCTest
@testable import ChecklistCore

extension CoreTests {
    func testArchiveHistoryReasonArchive() throws { try checkTaskArchiveHistoryReason("archive") }
    func testArchiveHistoryReasonUnarchive() throws { try checkTaskArchiveHistoryReason("unarchive") }
    func testArchiveHistoryReasonTrash() throws { try checkTaskArchiveHistoryReason("trash") }
    func testArchiveHistoryReasonRestore() throws { try checkTaskArchiveHistoryReason("restore") }
    func testArchiveHistoryReasonProjectArchive() throws { try checkProjectArchiveHistoryReason(archived:true) }
    func testArchiveHistoryReasonProjectRestore() throws { try checkProjectArchiveHistoryReason(archived:false) }

    func testProjectHistorySelectorScopePaginationAndCursorIsolation() throws {
        let (p,agent) = try agentChangeFixture(),pid = p["id"] as! String
        let t = try task(p)
        _ = try call("task_archive",["project_id":pid,"task_id":t["id"]!,"expected_revision":t["revision"]!,"action":"archive","reason":"Ticket only"])
        for archived in [true,false] {
            _ = try call("project_archive",["project_id":pid,"expected_revision":try currentProjectRevision(p),"archived":archived,"reason":"Project only"],agent)
        }
        let full = try call("history_list",["project_id":pid,"entity":"project"],agent)
        let expected = full["events"] as! [JSON]
        XCTAssertGreaterThan(expected.count,1)
        XCTAssertFalse(expected.contains { ($0["kind"] as? String)?.hasPrefix("task_") == true })
        XCTAssertTrue((full["messages"] as! [JSON]).isEmpty)
        var ids: [String] = [],cursor: Any?,firstCursor: Any?
        repeat {
            var input: JSON = ["project_id":pid,"entity":"project","limit":1]
            if let cursor { input["cursor"] = cursor }
            let page = try call("history_list",input,agent),events = page["events"] as! [JSON]
            XCTAssertLessThanOrEqual(events.count,1)
            for event in events {
                XCTAssertEqual((event["subject"] as? JSON)?["id"] as? String,pid)
                ids.append(event["id"] as! String)
            }
            cursor = page["next_cursor"];if firstCursor == nil {firstCursor = cursor}
            if !bool(page,"has_more") {break}
        } while ids.count <= expected.count
        XCTAssertEqual(ids,expected.map {$0["id"] as! String})
        assertCode("INVALID_INPUT") { _ = try self.call("history_list",["project_id":pid],agent) }
        assertCode("INVALID_INPUT") { _ = try self.call("history_list",["project_id":pid,"entity":"task"],agent) }
        assertCode("INVALID_INPUT") { _ = try self.call("history_list",["project_id":pid,"entity":"project","task_id":t["id"]!],agent) }
        assertCode("CURSOR_RESET") { _ = try self.call("history_list",["project_id":pid,"task_id":t["id"]!,"cursor":firstCursor!],agent) }
        assertCode("CURSOR_RESET") { _ = try self.call("history_list",["project_id":pid,"entity":"project","cursor":firstCursor!]) }
        let (foreign,otherAgent) = try agentChangeFixture()
        assertCode("FORBIDDEN") { _ = try self.call("history_list",["project_id":foreign["id"]!,"entity":"project"],agent) }
        assertCode("FORBIDDEN") { _ = try self.call("history_list",["project_id":pid,"entity":"project"],otherAgent) }
    }

    private func checkTaskArchiveHistoryReason(_ action: String) throws {
        for asAgent in [false,true] {
            let (p,agent) = try agentChangeFixture(),caller = asAgent ? agent : owner
            for reason: String? in ["  Keep this reason: café\nSecond line.  ",nil,""," \n\t"] {
                var t = try task(p)
                if action == "unarchive" || action == "restore" {
                    t = try call("task_archive",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"action":action == "unarchive" ? "archive" : "trash","reason":"Earlier reason"],caller)
                }
                var input: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"action":action]
                if let reason { input["reason"] = reason }
                let command = UUID().uuidString
                let changed = try call("task_archive",input,caller,command)
                _ = try call("task_archive",input,caller,command)
                XCTAssertEqual(int(changed,"revision"),int(t,"revision")+1)
                XCTAssertEqual(bool(changed,"archived"),action == "archive")
                XCTAssertEqual(bool(changed,"trashed"),action == "trash")
                if action == "trash" { XCTAssertEqual(changed["trash_reason"] as? String,reason ?? "") }
                let history = try call("history_list",["project_id":p["id"]!,"task_id":t["id"]!],caller)
                let events = (history["events"] as! [JSON]).filter { $0["kind"] as? String == "task_"+action }
                XCTAssertEqual(events.count,1,"Replay must not append a second event")
                try assertArchiveHistoryReason(XCTUnwrap(events.last),reason:reason,agent:asAgent,caller:caller)
            }
        }
    }

    private func checkProjectArchiveHistoryReason(archived: Bool) throws {
        for asAgent in [false,true] {
            for reason: String? in ["  Retain project reason: café\nSecond line.  ",nil,""," \n\t"] {
                let (p,agent) = try agentChangeFixture(),caller = asAgent ? agent : owner
                if !archived { _ = try call("project_archive",["project_id":p["id"]!,"expected_revision":try currentProjectRevision(p),"archived":true,"reason":"Earlier reason"],caller) }
                var input: JSON = ["project_id":p["id"]!,"expected_revision":try currentProjectRevision(p),"archived":archived]
                if let reason { input["reason"] = reason }
                let command = UUID().uuidString
                let changed = try call("project_archive",input,caller,command)
                _ = try call("project_archive",input,caller,command)
                XCTAssertEqual(bool(changed,"archived"),archived)
                XCTAssertEqual(int(changed,"revision"),(input["expected_revision"] as! Int)+1)
                // Agents and owners read the scoped project entity, including while archived.
                let history = try call("history_list",["project_id":p["id"]!,"entity":"project"],caller)
                let events = (history["events"] as! [JSON]).filter { $0["kind"] as? String == "project_updated" }
                XCTAssertEqual(events.count,archived ? 1 : 2,"Replay must not append a second event")
                try assertArchiveHistoryReason(XCTUnwrap(events.last),reason:reason,agent:asAgent,caller:caller)
            }
        }
    }

    private func assertArchiveHistoryReason(_ event: JSON, reason: String?, agent: Bool, caller: Caller) throws {
        let data = try XCTUnwrap(event["data"] as? JSON)
        let expected = reason.flatMap { $0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil : $0 }
        XCTAssertEqual(data["reason"] as? String,expected)
        XCTAssertEqual(data["origin"] as? String,agent ? "agent" : "human_ui")
        XCTAssertEqual(event["actor"] as? String,caller.principal)
    }
}
