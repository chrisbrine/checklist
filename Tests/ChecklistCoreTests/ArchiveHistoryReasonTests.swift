import XCTest
@testable import ChecklistCore

extension CoreTests {
    func testArchiveHistoryReasonArchive() throws { try checkTaskArchiveHistoryReason("archive") }
    func testArchiveHistoryReasonUnarchive() throws { try checkTaskArchiveHistoryReason("unarchive") }
    func testArchiveHistoryReasonTrash() throws { try checkTaskArchiveHistoryReason("trash") }
    func testArchiveHistoryReasonRestore() throws { try checkTaskArchiveHistoryReason("restore") }
    func testArchiveHistoryReasonProjectArchive() throws { try checkProjectArchiveHistoryReason(archived:true) }
    func testArchiveHistoryReasonProjectRestore() throws { try checkProjectArchiveHistoryReason(archived:false) }

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
                // Project events use the app's Activity read; history_list has no project selector.
                let activity = try call("workspace_page",["project_id":p["id"]!,"surface":"activity","include_archived":true])
                let events = (activity["rows"] as! [JSON]).filter { $0["kind"] as? String == "project_updated" }
                XCTAssertEqual(events.count,archived ? 1 : 2,"Replay must not append a second event")
                try assertArchiveHistoryReason(XCTUnwrap(events.first),reason:reason,agent:asAgent,caller:caller)
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
