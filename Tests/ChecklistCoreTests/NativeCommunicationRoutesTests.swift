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
            XCTAssertEqual(route.statusLabel, route.id == "codex_idle_wake" ? "Source enabled; qualification incomplete" : "Unavailable")
            XCTAssertEqual(route.status, route.id == "codex_idle_wake" ? "source_enabled" : "unavailable")
            XCTAssertTrue(route.qualifiedVersions.isEmpty)
            if route.id != "codex_idle_wake" { XCTAssertTrue(route.qualificationReceipts.isEmpty) }
        }
        let parent = try XCTUnwrap(NativeCommunicationRoutes.all.first { $0.id == "claude_idle_wake" })
        XCTAssertEqual(parent.mode, .recordedConfiguration)
        XCTAssertEqual(parent.qualifiedVersions["checklist_build"], "801d716c6c99cf40 (19)")
        XCTAssertEqual(parent.qualificationReceipts, ["CL-5:note_C", "CL-5:note_D_idle", "CL-386:relay-past-cap", "CL-386:relay-past-cap-health"])
        XCTAssertTrue(NativeCommunicationRoutes.summary.contains(NativeCommunicationRoutes.relayQualification))
        XCTAssertTrue(NativeCommunicationRoutes.summary.contains("Codex child closure remain unavailable"))
    }

    func testCodexPartialReceiptsKeepRecoveryAndBootstrapGapsUnqualified() throws {
        let route = try XCTUnwrap(NativeCommunicationRoutes.all.first { $0.id == "codex_idle_wake" })
        XCTAssertTrue(route.sourceEnabled)
        XCTAssertFalse(route.qualified)
        XCTAssertEqual(route.status, "source_enabled")
        XCTAssertEqual(route.statusLabel, "Source enabled; qualification incomplete")
        XCTAssertTrue(route.qualifiedVersions.isEmpty, "Partial observations are not qualified versions")
        XCTAssertEqual(route.qualificationReceipts, [
            "CL-413:loaded-thread; checklist_build=273",
            "CL-417:unloaded-thread; checklist_build=289; message_id=c54829df-7d89-40a3-9486-e6396b02aa9c",
            "CL-417:unloaded-thread; checklist_build=291; message_id=445ded0f-bf72-427d-96fb-30d5422e1d50",
            "CL-417:later-note-recovery; checklist_build=291; message_id=321dfa67-caac-4e1f-9d40-b50f66ffeca5",
            "CL-417:unloaded-thread; checklist_build=292; message_id=ebe09471-90db-4385-9b3b-33f791fe5223",
            "CL-417:later-note-recovery; checklist_build=292; message_id=0ca0ee01-6cd9-49c0-817b-eaed7d9718d8"
        ])
        for fact in ["4 November 2026", "build 289", "14:05:45", "build 291 (91b23bf52628646c)", "16:46:29 PDT", "16:46:52",
                     "pending_after_20s", "exited_zero", "open_exit_status=0", "provider_accepted",
                     "16:55:35 PDT", "queue_poll_result=queue_occupied", "reason_code=queue_occupied", "result=refused (no second item)", "16:55:38",
                     "ChatGPT 26.1029.61003", "codex-cli 0.166.0-alpha.6", "0.166.0-alpha.5.1",
                     "no recheck on these versions", "current enrollment generation", "NATIVE_SESSION_MISMATCH", "CL-434", "not fully qualified",
                     "while the waiting item existed", "relayed the later note as its own queue item", "16:56:33 PDT", "queue_poll_result=removed",
                     "open_result=not_needed", "16:56:30-16:56:38", "wrote the note's marker", "On build 292, a non-contributor check runner",
                     "17:50:18 PDT", "17:51:05 PDT", "CL-440", Self.build291RecoverySnapshotSHA256, Self.build292RecoverySnapshotSHA256,
                     "The CL-434 reconnect has no passing installed run yet"] {
            XCTAssertTrue(route.reason.contains(fact), fact)
        }
        XCTAssertFalse(route.reason.contains("not yet run"), "The recovery case has run")
        for stale in Self.staleRecoveryClaims { XCTAssertFalse(route.reason.contains(stale), stale) }
        XCTAssertFalse(route.reason.contains("reconnect refused there"))
        XCTAssertEqual(route.serviceInfo["qualification_scope"] as? String, "none")
        XCTAssertEqual(route.serviceInfo["qualified"] as? Bool, false)
        XCTAssertEqual(route.serviceInfo["qualification_receipts"] as? [String], route.qualificationReceipts)
        XCTAssertTrue(NativeCommunicationRoutes.summary.contains("later-note recovery checks passed"))
        XCTAssertTrue(NativeCommunicationRoutes.summary.contains("stays unqualified"))
        XCTAssertFalse(NativeCommunicationRoutes.summary.contains("not yet run"))
        XCTAssertTrue(NativeCommunicationRoutes.summary.contains("after an app restart. The CL-434 reconnect has no passing installed run yet; docs/codex-host-restart.md records its results. Autonomous child push/wake"))
        let joined = try NSRegularExpression(pattern: "[a-z)]\\.[A-Z]")
        let summary = NativeCommunicationRoutes.summary
        XCTAssertEqual(joined.numberOfMatches(in: summary, range: NSRange(summary.startIndex..., in: summary)), 0, "Every sentence of native_push_status starts after a space")
    }

    static let build291RecoverySnapshotSHA256 = "9d63f15bcd091ea9eecc849466b6430fd60ed8d4c02eed6380263b3b5d63b380"
    static let build292RecoverySnapshotSHA256 = "3aa32159dee6cfbaaf995147995577c3bc1b5ef024c495cd6ce8db58679266e0"
    static let staleRecoveryClaims = ["later note stayed in the inbox", "later note stays in the inbox", "stays in the inbox because the turn belongs to the older item", "later note's marker did not appear"]

    func testPublishedCodexRouteDocsStateTheRecoveryResult() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let integrations = try String(contentsOf: root.appendingPathComponent("docs/integrations.md"), encoding: .utf8)
        let status = try String(contentsOf: root.appendingPathComponent("docs/implementation-status.md"), encoding: .utf8)
        let row = try XCTUnwrap(integrations.components(separatedBy: "\n").first { $0.hasPrefix("| `codex_idle_wake` |") })
        for fact in ["445ded0f-bf72-427d-96fb-30d5422e1d50", "321dfa67-caac-4e1f-9d40-b50f66ffeca5", "queue_occupied", "result=refused", "0.166.0-alpha.6", "NATIVE_SESSION_MISMATCH"] {
            XCTAssertTrue(row.contains(fact), fact)
            XCTAssertTrue(status.contains(fact), fact)
        }
        for fact in ["0ca0ee01-6cd9-49c0-817b-eaed7d9718d8", "ebe09471-90db-4385-9b3b-33f791fe5223", "relayed the later note as its own queue item",
                     "`queue_poll_result=removed`", "`open_result=not_needed`", "16:56:33 PDT", "CL-440", Self.build291RecoverySnapshotSHA256, Self.build292RecoverySnapshotSHA256] {
            XCTAssertTrue(row.contains(fact), fact)
            XCTAssertTrue(status.contains(fact), fact)
        }
        let openLimit = try XCTUnwrap(integrations.components(separatedBy: "\n").first { $0.hasPrefix("Open limit (CL-416).") })
        for fact in ["gets a `refused` receipt", "relays the later note as its own queue item", "relayed the later note as its own item", "Build 292 repeated this relay"] {
            XCTAssertTrue(openLimit.contains(fact), fact)
        }
        XCTAssertTrue(integrations.contains("3. **Build 292 recheck, pass.**"))
        XCTAssertTrue(integrations.contains("retains its six partial qualification receipts"))
        XCTAssertTrue(status.contains("now hold six partial receipts"))
        for document in [integrations, status, row, openLimit] {
            for stale in Self.staleRecoveryClaims { XCTAssertFalse(document.contains(stale), stale) }
        }
        for document in [integrations, status] {
            XCTAssertFalse(document.contains("recovery case is not yet run"))
            XCTAssertFalse(document.contains("later-note recovery case is not yet run"))
            XCTAssertFalse(document.contains("is **not yet run**"))
        }
    }

    func testServiceInfoDoesNotPromoteEnrollmentOrTransportReceipts() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ChecklistQualification/CL-83", isDirectory: true)
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
