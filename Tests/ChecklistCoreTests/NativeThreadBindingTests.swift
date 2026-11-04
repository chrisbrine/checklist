import ChecklistTestSupport
import XCTest
@testable import ChecklistCore

extension CoreTests {
    func testUnboundWorkerServiceInfoExplainsMissingThreadWithoutClaimingAuthority() throws {
        for session in [nil, ""] as [String?] {
            let worker = Caller(role: "worker", installation: "unbound-mcp-fixture", projectIDs: [], sessionID: session)
            let info = try call("service_info", [:], worker)
            let caller = try XCTUnwrap(info["caller"] as? JSON)
            XCTAssertEqual(caller["session_id"] as? String, "")
            let binding = try XCTUnwrap(caller["thread_binding"] as? JSON)
            XCTAssertEqual(binding["state"] as? String, "unbound")
            XCTAssertEqual(binding["reason"] as? String, "native_thread_identity_unavailable")
            XCTAssertTrue((binding["message"] as? String ?? "").contains("_meta.threadId"))
            XCTAssertEqual(info["project_ids"] as? [String], [])
            XCTAssertNil(info["_checklist"])
            // Core catalogs describe role schemas; actual scope still refuses a
            // caller with no enrollment. The MCP shim tests its limited discovery.
            assertCode("FORBIDDEN") {
                _ = try self.call("task_list", ["project_id": UUID().uuidString], worker)
            }
        }
    }

    func testServiceInfoDoesNotLabelOwnerOrRegisteredWorkerAsUnbound() throws {
        XCTAssertNil((try call("service_info")["caller"] as? JSON)?["thread_binding"])
        let project = try call("project_create", ["name": "Thread binding fixture", "key_prefix": "TB", "root_path": directory.path])
        let pid = try XCTUnwrap(project["id"] as? String), sid = UUID().uuidString
        _ = try call("session_register", ["project_id": pid, "project_ids": [pid], "session_id": sid,
            "installation": "bound-fixture", "provider": "codex", "role": "worker", "workspace": directory.path])
        let worker = Caller(role: "worker", installation: "bound-fixture", projectIDs: [pid], sessionID: sid, workspace: directory.path)
        let info = try call("service_info", [:], worker)
        XCTAssertEqual((info["caller"] as? JSON)?["session_id"] as? String, sid)
        XCTAssertNil((info["caller"] as? JSON)?["thread_binding"])
    }
}
