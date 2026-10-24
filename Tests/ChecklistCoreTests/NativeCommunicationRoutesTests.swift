import ChecklistTestSupport
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
        XCTAssertEqual(Set(routes.filter(\.qualified).map(\.id)), [
            "claude_idle_wake", "codex_child_inbound", "codex_child_outbound",
            "claude_child_inbound", "claude_child_outbound",
            "codex_parent_relay_inbound", "codex_parent_relay_outbound"
        ])
        XCTAssertEqual(Set(routes.filter { !$0.qualified }.map(\.id)), [
            "codex_idle_wake", "claude_parent_relay_inbound", "claude_parent_relay_outbound"
        ])
        for route in routes {
            let row = try XCTUnwrap(documentation.components(separatedBy: "\n").first { $0.hasPrefix("| `\(route.id)` |") })
            XCTAssertTrue(row.contains("| \(route.statusLabel) |"), route.id)
            for value in route.qualifiedVersions.values { XCTAssertTrue(row.contains(value), "\(route.id): \(value)") }
            for receipt in route.qualificationReceipts { XCTAssertTrue(row.contains(receipt), "\(route.id): \(receipt)") }
            XCTAssertFalse(route.reason.isEmpty)
        }

    }

    func testRecordedModesVersionsAndEvidenceStayBounded() throws {
        for route in NativeCommunicationRoutes.all where route.qualified && route.id != "claude_idle_wake" {
            XCTAssertEqual(route.qualifiedVersions["checklist_build"], "d9ef8900fed26778 (111)")
            XCTAssertEqual(route.mode, route.direction.contains("via_parent") ? .hostRelay : .explicitPickup)
            XCTAssertTrue(route.statusLabel.hasPrefix("Qualified for explicit Checklist pickup and acknowledgment"))
            if route.provider == "codex" {
                XCTAssertEqual(route.qualifiedVersions["codex_cli"], "0.159.0")
                XCTAssertTrue(route.qualificationReceipts.contains { $0.contains("attachment=e20676fe-a4e0-486d-8aa8-78eee940b82d; sha256=8991dca45f0a3be87ca21fa9a640cfd2d30f2642178ae447c529ff09fbae4650") })
            } else {
                XCTAssertEqual(route.qualifiedVersions["desktop_app"], "3.1623.0")
                XCTAssertEqual(route.qualifiedVersions["engine"], "2.1.304")
                XCTAssertEqual(route.qualifiedVersions["peer_protocol"], "1")
                XCTAssertEqual(route.qualifiedVersions["receipt_read_build"], "60394b4fa961cb6b (112); historical receipts only")
                XCTAssertTrue(route.qualificationReceipts.contains { $0.contains("attachment=15d8b2ff-e222-45f6-8b5b-9708b259781c; sha256=8746c94cbd3bc302f3b31bf3c01aa62c71d1eddb4bc51f730059de9a12f93ef8") })
                XCTAssertTrue(route.qualificationReceipts.contains { $0.contains("attachment=9cfc8395-2193-4e8e-9407-a919fbb89d24; sha256=625e8a65cd916613915f69780c8cd5baa5d6842453e46c019380159b1891904d") })
            }
        }
        for route in NativeCommunicationRoutes.all where !route.qualified {
            XCTAssertEqual(route.statusLabel, "Unavailable")
            XCTAssertTrue(route.qualifiedVersions.isEmpty)
            XCTAssertTrue(route.qualificationReceipts.isEmpty)
        }
        let parent = try XCTUnwrap(NativeCommunicationRoutes.all.first { $0.id == "claude_idle_wake" })
        XCTAssertEqual(parent.mode, .recordedConfiguration)
        XCTAssertEqual(parent.qualifiedVersions["checklist_build"], "801d716c6c99cf40 (19)")
        XCTAssertEqual(parent.qualificationReceipts, ["CL-5:note_C", "CL-5:note_D_idle"])
        XCTAssertTrue(NativeCommunicationRoutes.summary.contains("Codex child closure remain unavailable"))
    }

    func testServiceInfoDoesNotPromoteEnrollmentOrTransportReceipts() throws {
        let parent = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ChecklistQualification/CL-83", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let directory = parent.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = try TestStore.router(root: directory)
        let owner = Caller(role: "owner", installation: "qualification-advertisement-test", projectIDs: [])
        func call(_ method: String, _ input: JSON = [:], _ caller: Caller? = nil) throws -> JSON {
            var input = input
            if !CommandRouter.readMethods.contains(method) { input["command_id"] = uuid() }
            return try XCTUnwrap(router.handle(method: method, params: fixtureTaskInput(router,method:method,input:input), caller: caller ?? owner)["data"] as? JSON)
        }
        func advertised(_ caller: Caller? = nil) throws -> Data {
            let info = try call("service_info", [:], caller)
            XCTAssertEqual(info["native_push"] as? Bool, false)
            XCTAssertEqual(info["native_push_status"] as? String, NativeCommunicationRoutes.summary)
            let routes = try XCTUnwrap(info["native_routes"] as? [JSON])
            XCTAssertEqual(routes.count, 10)
            for route in routes {
                let id = try XCTUnwrap(route["id"] as? String)
                let expected = try XCTUnwrap(NativeCommunicationRoutes.all.first { $0.id == id })
                XCTAssertEqual(route["status"] as? String, expected.status)
                XCTAssertEqual(route["qualified"] as? Bool, expected.qualified)
                XCTAssertEqual(route["qualification_scope"] as? String, expected.qualified ? expected.mode.rawValue : "none")
                XCTAssertEqual(route["qualified_versions"] as? [String: String], expected.qualifiedVersions)
                XCTAssertEqual(route["qualification_receipts"] as? [String], expected.qualificationReceipts)
                XCTAssertEqual(route["reason"] as? String, expected.reason)
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
