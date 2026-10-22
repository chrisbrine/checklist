import XCTest
@testable import ChecklistCore

/// Deterministic advertisement checks only; these never qualify a native route.
final class NativeCommunicationRoutesTests: XCTestCase {
    func testCatalogCoversEachDirectionAndMatchesPublishedTable() throws {
        let routes = NativeCommunicationRoutes.all
        XCTAssertEqual(Set(routes.map(\.id)).count, routes.count)
        for provider in ["codex", "claude"] {
            XCTAssertEqual(Set(routes.filter { $0.provider == provider }.map(\.direction)),
                           ["service_to_session", "to_child", "from_child", "to_child_via_parent", "from_child_via_parent"])
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let documentation = try String(contentsOf: root.appendingPathComponent("docs/integrations.md"), encoding: .utf8)
        let publishedIDs = documentation.components(separatedBy: "\n").filter { $0.hasPrefix("| `") }.compactMap { $0.split(separator: "`").dropFirst().first.map(String.init) }
        XCTAssertEqual(Set(publishedIDs), Set(routes.map(\.id)))
        XCTAssertEqual(routes.filter(\.qualified).map(\.id), ["claude_idle_wake"])
        XCTAssertTrue(routes.filter { $0.id != "claude_idle_wake" }.allSatisfy { !$0.qualified && $0.status == "unavailable" && !$0.reason.isEmpty })
    }

    func testServiceInfoDoesNotPromoteEnrollmentOrTransportReceipts() throws {
        let parent = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ChecklistQualification/CL-83", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let directory = parent.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = try CommandRouter(root: directory)
        let owner = Caller(role: "owner", installation: "qualification-advertisement-test", projectIDs: [])
        func call(_ method: String, _ input: JSON = [:], _ caller: Caller? = nil) throws -> JSON {
            var input = input
            if !CommandRouter.readMethods.contains(method) { input["command_id"] = uuid() }
            return try XCTUnwrap(router.handle(method: method, params: input, caller: caller ?? owner)["data"] as? JSON)
        }
        func advertised(_ caller: Caller? = nil) throws -> Data {
            let info = try call("service_info", [:], caller)
            XCTAssertEqual(info["native_push"] as? Bool, false)
            XCTAssertEqual(info["native_push_status"] as? String, NativeCommunicationRoutes.summary)
            let routes = try XCTUnwrap(info["native_routes"] as? [JSON])
            XCTAssertEqual(routes.count, 10)
            for route in routes {
                if route["id"] as? String == "claude_idle_wake" {
                    XCTAssertEqual(route["status"] as? String, "qualified")
                    XCTAssertEqual(route["qualified"] as? Bool, true)
                    XCTAssertEqual(route["qualification_scope"] as? String, "recorded_versions_and_configuration_only")
                    XCTAssertEqual((route["qualified_versions"] as? [String: String])?["checklist_build"], "801d716c6c99cf40 (19)")
                    XCTAssertEqual(route["qualification_receipts"] as? [String], ["CL-5:note_C", "CL-5:note_D_idle"])
                } else {
                    XCTAssertEqual(route["status"] as? String, "unavailable")
                    XCTAssertEqual(route["qualified"] as? Bool, false)
                    XCTAssertEqual((route["qualified_versions"] as? [String: String])?.count, 0)
                    XCTAssertEqual(route["qualification_receipts"] as? [String], [])
                }
            }
            return try JSONSerialization.data(withJSONObject: routes, options: [.sortedKeys])
        }
        let before = try advertised()
        let workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let project = try call("project_create", ["name": "Synthetic route advertisement", "key_prefix": "ROUTE", "root_path": workspace.path])
        let pid = try XCTUnwrap(project["id"] as? String)
        let task = try call("task_create", ["project_id": pid, "title": "Synthetic parent receipt"])
        let sid = uuid()
        _ = try call("session_register", ["project_id": pid, "session_id": sid, "role": "worker", "provider": "codex", "installation": "synthetic-parent", "workspace": workspace.path])
        let worker = Caller(role: "worker", installation: "synthetic-parent", projectIDs: [pid], sessionID: sid, workspace: workspace.path)
        let message = try call("message_send", ["project_id": pid, "task_id": task["id"]!, "body": "Synthetic receipt, no actual native send", "recipient": ["kind": "session", "session_id": sid]])
        let delivery = try XCTUnwrap((message["deliveries"] as? [JSON])?.first)
        let bridge = Caller(role: "owner", installation: "native-bridge", projectIDs: [])
        _ = try call("delivery_record", ["delivery_id": delivery["id"]!, "state": "uncertain", "receipt": ["stage": "native_send_started"]], bridge)
        _ = try call("delivery_record", ["delivery_id": delivery["id"]!, "state": "transport_written", "receipt": ["bytes": 12]], bridge)
        XCTAssertEqual(try advertised(), before)
        XCTAssertEqual(try advertised(worker), before)
        let acknowledged = try call("message_ack", ["project_id": pid, "delivery_id": delivery["id"]!, "stage": "acknowledged"], worker)
        XCTAssertEqual(acknowledged["state"] as? String, "acknowledged")
        XCTAssertEqual(try advertised(), before, "A parent's pickup acknowledgment cannot qualify a native child or relay route")
    }
}
