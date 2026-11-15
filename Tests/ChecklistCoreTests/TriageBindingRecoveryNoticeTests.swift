import XCTest
import ChecklistBridges
@testable import ChecklistCore

extension EvidenceAuthorityTests {
    private var recoveryNoticeBootstrap: Caller { Caller(role: "owner", installation: "native-thread-bootstrap", projectIDs: []) }

    private func recoveryNoticeFixture(_ label: String) throws -> (JSON, JSON, Caller) {
        let p = try project(), worker = try native(p, label, domain: "claude:401:1:0", provider: "claude")
        let group = try call("triage_orchestrate", ["project_id": p["id"]!, "action": "start", "name": "Recovery notice"], worker)
        return (p, group, worker)
    }

    private func recoveryNoticeResume(_ p: JSON, _ worker: Caller) throws -> (Caller, JSON) {
        let generation = try router.dbQueue.read { try router.sessionGeneration(router.record($0, worker.sessionID!, type: "session")) }
        _ = try router.reconcileVerifiedNativeClosure(VerifiedNativeClosure(projectID: p["id"] as! String,
            sessionID: worker.sessionID!, installation: worker.installation, executionDomain: worker.executionDomain!, provider: "claude",
            authorizationGeneration: generation, processState: "gone", registryState: "absent", registryDigest: nil),
            caller: Caller(role: "owner", installation: "native-lifecycle", projectIDs: []))
        let installation = worker.installation + "/resumed", domain = worker.executionDomain! + "/resumed"
        let session = try router.resumeVerifiedNativeSession(NativeSessionResumption(projectID: p["id"] as! String,
            sessionID: worker.sessionID!, provider: "claude", oldInstallation: worker.installation, oldExecutionDomain: worker.executionDomain!,
            newInstallation: installation, newExecutionDomain: domain), caller: recoveryNoticeBootstrap)
        return (Caller(role: "worker", installation: installation, projectIDs: worker.projectIDs, sessionID: worker.sessionID,
                       workspace: workspace.path, executionDomain: domain), session)
    }

    private func recoveryNotices(_ p: JSON) throws -> [JSON] {
        try router.dbQueue.read { db in
            try router.records(db, type: "message", project: p["id"] as? String).filter { $0["recovery_orchestration_id"] != nil }
        }
    }

    private func assertRecoveryNotice(_ p: JSON, _ group: JSON, _ worker: Caller, _ session: JSON,
                                      file: StaticString = #filePath, line: UInt = #line) throws -> JSON {
        let notice = try XCTUnwrap(try recoveryNotices(p).last, file: file, line: line)
        XCTAssertEqual(notice["triage_id"] as? String, group["id"] as? String, file: file, line: line)
        XCTAssertEqual(notice["origin"] as? String, "system", file: file, line: line)
        XCTAssertEqual(notice["orchestration_connection"] as? String, "recovery_required", file: file, line: line)
        let command = try XCTUnwrap(notice["resume_command"] as? JSON, file: file, line: line)
        XCTAssertEqual(command["method"] as? String, "triage_orchestrate", file: file, line: line)
        let arguments = try XCTUnwrap(command["arguments"] as? JSON, file: file, line: line)
        XCTAssertEqual(arguments["action"] as? String, "resume", file: file, line: line)
        XCTAssertEqual(arguments["triage_id"] as? String, group["id"] as? String, file: file, line: line)
        XCTAssertEqual(arguments["expected_revision"] as? Int, group["revision"] as? Int, file: file, line: line)
        XCTAssertFalse((arguments["reason"] as? String ?? "").isEmpty, file: file, line: line)
        let beforePickup = try call("delivery_pending", ["native_session_ids": [worker.sessionID!], "native_dispatch_candidates": true],
                                    Caller(role: "owner", installation: "native-bridge", projectIDs: []))["deliveries"] as! [JSON]
        let delivery = try XCTUnwrap(beforePickup.first { $0["message_id"] as? String == notice["id"] as? String }, file: file, line: line)
        XCTAssertEqual(delivery["recipient_session_id"] as? String, worker.sessionID, file: file, line: line)
        XCTAssertEqual(delivery["recipient_authorization_generation"] as? String, session["authorization_generation"] as? String, file: file, line: line)
        XCTAssertEqual(delivery["recipient_role"] as? String, "triage_orchestrator", file: file, line: line)
        XCTAssertEqual(delivery["native_relay"] as? String, "triage_recovery", file: file, line: line)
        XCTAssertEqual(NativeRelayOrigin.forDispatch(messageOrigin: notice["origin"] as? String,
                                                     nativeRelay: delivery["native_relay"] as? String), .system, file: file, line: line)
        XCTAssertEqual(delivery["push_state"] as? String, "unavailable", file: file, line: line)
        let inbox = try call("session_inbox", ["project_id": p["id"]!], worker)
        XCTAssertTrue((inbox["messages"] as! [JSON]).contains { $0["id"] as? String == notice["id"] as? String }, file: file, line: line)
        XCTAssertTrue((inbox["deliveries"] as! [JSON]).contains { $0["id"] as? String == delivery["id"] as? String }, file: file, line: line)
        let storedGroup = try router.dbQueue.read { try router.record($0, group["id"] as! String, type: "group") }
        XCTAssertEqual(try jsonString(storedGroup["orchestration"]!), try jsonString(group["orchestration"]!), file: file, line: line)
        return notice
    }

    func testTriageRecoveryNoticeNativeResumeReachesNewGenerationRelayAndPickupWithoutRebinding() throws {
        let (p, group, old) = try recoveryNoticeFixture("native-recovery-notice")
        let (resumed, session) = try recoveryNoticeResume(p, old)
        let notice = try assertRecoveryNotice(p, group, resumed, session)
        let summary = try XCTUnwrap((call("service_info", [:], resumed)["native_recovery"] as? [JSON])?.first)
        XCTAssertEqual((summary["recovery_required_orchestrations"] as? [JSON])?.first?["triage_id"] as? String, group["id"] as? String)
        let arguments = ((notice["resume_command"] as! JSON)["arguments"] as! JSON)
        let rebound = try call("triage_orchestrate", arguments, resumed)
        XCTAssertEqual(rebound["orchestration_connection"] as? String, "current")
    }

    // CL-461 item 1: service_info names the stale binding and the ready explicit resume command, and runs nothing.
    func testServiceInfoShowsStaleBindingWithReadyResumeCommandOnlyForVerifiedResumption() throws {
        let (p, group, old) = try recoveryNoticeFixture("service-info-recovery")
        let current = try XCTUnwrap((call("service_info", [:], old)["caller"] as? JSON)?["orchestrated_triage"] as? JSON)
        XCTAssertEqual(current["orchestration_connection"] as? String, "current")
        XCTAssertNil(current["resume_command"]); XCTAssertNil(current["resume_available"])
        let (resumed, _) = try recoveryNoticeResume(p, old)
        let stale = try XCTUnwrap((call("service_info", [:], resumed)["caller"] as? JSON)?["orchestrated_triage"] as? JSON)
        XCTAssertEqual(stale["triage_id"] as? String, group["id"] as? String)
        XCTAssertEqual(stale["orchestration_connection"] as? String, "recovery_required")
        XCTAssertEqual(stale["resume_available"] as? Bool, true)
        let storedBefore = try router.dbQueue.read { try router.record($0, group["id"] as! String, type: "group") }
        XCTAssertEqual(stale["expected_revision"] as? Int, storedBefore["revision"] as? Int)
        let command = try XCTUnwrap(stale["resume_command"] as? JSON)
        XCTAssertEqual(command["method"] as? String, "triage_orchestrate")
        var arguments = try XCTUnwrap(command["arguments"] as? JSON)
        XCTAssertEqual(arguments["action"] as? String, "resume"); XCTAssertNil(arguments["command_id"])
        // Reading service_info changed nothing: the binding is still the old one.
        let storedAfter = try router.dbQueue.read { try router.record($0, group["id"] as! String, type: "group") }
        XCTAssertEqual(try jsonString(storedAfter["orchestration"]!), try jsonString(storedBefore["orchestration"]!))
        arguments["command_id"] = UUID().uuidString
        let rebound = try call("triage_orchestrate", arguments, resumed)
        XCTAssertEqual(rebound["orchestration_connection"] as? String, "current")
        let after = try XCTUnwrap((call("service_info", [:], resumed)["caller"] as? JSON)?["orchestrated_triage"] as? JSON)
        XCTAssertEqual(after["orchestration_connection"] as? String, "current"); XCTAssertNil(after["resume_command"])
    }

    func testServiceInfoOwnerReconnectWithoutVerifiedClosureOffersNoResumeCommand() throws {
        let (p, _, old) = try recoveryNoticeFixture("service-info-owner-reconnect")
        func accessInput() throws -> JSON {
            let session = try router.dbQueue.read { try router.record($0, old.sessionID!, type: "session") }
            return ["project_id": p["id"]!, "session_id": old.sessionID!, "installation": session["installation"]!, "expected_revision": session["revision"]!]
        }
        _ = try call("connection_revoke", accessInput())
        _ = try call("connection_allow", accessInput())
        let installation = old.installation + "/allowed"
        _ = try router.reconnectOwnerAllowedSession(NativeSessionResumption(projectID: p["id"] as! String,
            sessionID: old.sessionID!, provider: "claude", oldInstallation: old.installation, oldExecutionDomain: old.executionDomain!,
            newInstallation: installation, newExecutionDomain: old.executionDomain!), caller: recoveryNoticeBootstrap)
        let resumed = Caller(role: "worker", installation: installation, projectIDs: old.projectIDs, sessionID: old.sessionID,
                             workspace: workspace.path, executionDomain: old.executionDomain)
        let stale = try XCTUnwrap((call("service_info", [:], resumed)["caller"] as? JSON)?["orchestrated_triage"] as? JSON)
        XCTAssertEqual(stale["orchestration_connection"] as? String, "recovery_required")
        XCTAssertEqual(stale["resume_available"] as? Bool, false)
        XCTAssertTrue(stale["resume_command"] is NSNull)
        XCTAssertTrue((stale["recovery_step"] as? String ?? "").contains("take it over"))
    }

    func testTriageRecoveryNoticeOwnerReconnectReachesNewGenerationWithoutGrantingResumeAuthority() throws {
        let (p, group, old) = try recoveryNoticeFixture("owner-recovery-notice")
        func accessInput() throws -> JSON {
            let session = try router.dbQueue.read { try router.record($0, old.sessionID!, type: "session") }
            return ["project_id": p["id"]!, "session_id": old.sessionID!, "installation": session["installation"]!, "expected_revision": session["revision"]!]
        }
        _ = try call("connection_revoke", accessInput())
        _ = try call("connection_allow", accessInput())
        let installation = old.installation + "/allowed"
        let session = try router.reconnectOwnerAllowedSession(NativeSessionResumption(projectID: p["id"] as! String,
            sessionID: old.sessionID!, provider: "claude", oldInstallation: old.installation, oldExecutionDomain: old.executionDomain!,
            newInstallation: installation, newExecutionDomain: old.executionDomain!), caller: recoveryNoticeBootstrap)
        let resumed = Caller(role: "worker", installation: installation, projectIDs: old.projectIDs, sessionID: old.sessionID,
                             workspace: workspace.path, executionDomain: old.executionDomain)
        let notice = try assertRecoveryNotice(p, group, resumed, session)
        let arguments = ((notice["resume_command"] as! JSON)["arguments"] as! JSON)
        assertCode("FORBIDDEN") { _ = try self.call("triage_orchestrate", arguments, resumed) }
    }

    func testTriageRecoveryNoticeIsIdempotentWithinGenerationAndFreshForSecondResume() throws {
        let (p, group, old) = try recoveryNoticeFixture("repeated-recovery-notice")
        let (resumed, session) = try recoveryNoticeResume(p, old)
        try router.dbQueue.write { db in
            try router.queueTriageBindingRecoveryNotices(db, session: session, caller: recoveryNoticeBootstrap)
        }
        XCTAssertEqual(try recoveryNotices(p).count, 1)
        let (again, nextSession) = try recoveryNoticeResume(p, resumed)
        let fresh = try assertRecoveryNotice(p, group, again, nextSession)
        XCTAssertEqual(try recoveryNotices(p).count, 2)
        XCTAssertEqual(fresh["recovery_authorization_generation"] as? String, nextSession["authorization_generation"] as? String)
    }

    func testTriageRecoveryNoticeSkipsCurrentFinishedAndForeignOrchestrations() throws {
        let (p, group, worker) = try recoveryNoticeFixture("current-recovery-notice")
        let session = try router.dbQueue.read { try router.record($0, worker.sessionID!, type: "session") }
        try router.dbQueue.write { try router.queueTriageBindingRecoveryNotices($0, session: session, caller: recoveryNoticeBootstrap) }
        XCTAssertTrue(try recoveryNotices(p).isEmpty)
        _ = try call("triage_orchestrate", ["project_id": p["id"]!, "triage_id": group["id"]!, "expected_revision": group["revision"]!,
                                            "action": "finish", "reason": "Finished before reconnect"], worker)
        let foreign = try native(p, "foreign-recovery-notice", domain: "claude:402:1:0", provider: "claude")
        _ = try call("triage_orchestrate", ["project_id": p["id"]!, "action": "start"], foreign)
        _ = try recoveryNoticeResume(p, worker)
        XCTAssertTrue(try recoveryNotices(p).isEmpty)
    }
}
