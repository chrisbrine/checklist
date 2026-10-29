import XCTest
@testable import ChecklistCore

extension EvidenceAuthorityTests {
    private func orchestrationFixture() throws -> (JSON, JSON, [JSON]) {
        let p = try project(), tasks = try [ready(p), ready(p)]
        var group = try call("triage_create", ["project_id":p["id"]!,"name":"Orchestration recovery","phase":"implementation"])
        for task in tasks {
            group = try call("group_membership", ["project_id":p["id"]!,"group_id":group["id"]!,"expected_revision":group["revision"]!,"task_id":task["id"]!,"action":"add"])
        }
        return (p, group, tasks)
    }
    private func orchestrate(_ p: JSON,_ group: JSON,_ action: String,_ caller: Caller? = nil,reason: String? = nil,command: String? = nil) throws -> JSON {
        let current = try router.dbQueue.read { try router.record($0,group["id"] as! String,type:"group") }
        var input: JSON = ["project_id":p["id"]!,"triage_id":group["id"]!,"expected_revision":current["revision"]!,"action":action]
        if let reason { input["reason"] = reason }
        return try call("triage_orchestrate",input,caller,command:command)
    }
    private func orchestrationHistory(_ p: JSON,_ group: JSON) throws -> [JSON] {
        try call("history_list",["project_id":p["id"]!,"triage_id":group["id"]!])["events"] as! [JSON]
    }
    private func orchestrationProtectedRecords(_ p: JSON) throws -> String {
        try router.dbQueue.read { db in
            var rows: [JSON] = []
            for type in ["task","attempt","batch","batch_claim","triage_membership_interval","triage_membership_exit"] {
                rows += try router.records(db,type:type,project:p["id"] as? String)
            }
            return try jsonString(rows)
        }
    }
    private func closeAndResumeOrchestrator(_ p: JSON,_ worker: Caller) throws -> (Caller, String) {
        let generation = try router.dbQueue.read { try router.sessionGeneration(router.record($0,worker.sessionID!,type:"session")) }
        let closed = try router.reconcileVerifiedNativeClosure(VerifiedNativeClosure(projectID:p["id"] as! String,sessionID:worker.sessionID!,installation:worker.installation,executionDomain:worker.executionDomain!,provider:"claude",authorizationGeneration:generation,processState:"gone",registryState:"absent",registryDigest:nil),caller:Caller(role:"owner",installation:"native-lifecycle",projectIDs:[]))
        let installation = worker.installation + "-resumed", domain = worker.executionDomain! + "-resumed"
        _ = try router.resumeVerifiedNativeSession(NativeSessionResumption(projectID:p["id"] as! String,sessionID:worker.sessionID!,provider:"claude",oldInstallation:worker.installation,oldExecutionDomain:worker.executionDomain!,newInstallation:installation,newExecutionDomain:domain),caller:Caller(role:"owner",installation:"native-thread-bootstrap",projectIDs:[]))
        return (Caller(role:"worker",installation:installation,projectIDs:[p["id"] as! String],sessionID:worker.sessionID!,workspace:workspace.path,executionDomain:domain),closed["observation_ref"] as! String)
    }

    // CL-197: a live holder need not authorize the new coordinator. Work authority
    // stays with the actual frozen batch claimants, even after coordinator finish.
    func testTriageTakeoverFromLiveSessionPreservesClaimsBatchAndMemberships() throws {
        let (p, group, tasks) = try orchestrationFixture()
        let old = try native(p,"old-coordinator",domain:"host-old"), next = try native(p,"next-coordinator",domain:"host-next"), implementer = try native(p,"member-worker",domain:"host-member")
        let batch = try call("batch_prepare",["project_id":p["id"]!,"triage_id":group["id"]!,"expected_revision":group["revision"]!,"phase":"implementation","tasks":tasks.map {["task_id":$0["id"]!,"expected_revision":$0["revision"]!] as JSON}])
        // CL-125 rule 6: orchestration starts first, so the member worker's claim keeps the tickets in this Triage.
        let started = try orchestrate(p,group,"start",old), previous = started["orchestration"] as! JSON
        _ = try call("batch_claim",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":batch["revision"]!,"policy_revision":batch["policy_revision"]!],implementer)
        let protected = try orchestrationProtectedRecords(p)
        let claimed = try router.dbQueue.read { try router.record($0,group["id"] as! String,type:"group") }
        XCTAssertEqual(claimed["task_ids"] as? [String] ?? [],tasks.compactMap {$0["id"] as? String})
        let input: JSON = ["project_id":p["id"]!,"triage_id":group["id"]!,"expected_revision":claimed["revision"]!,"action":"takeover","reason":"Coordinate the remaining pass"]
        let command = UUID().uuidString
        let taken = try call("triage_orchestrate",input,next,command:command), current = taken["orchestration"] as! JSON
        XCTAssertEqual(current["session_id"] as? String,next.sessionID)
        XCTAssertEqual(current["takeover_from_orchestration_id"] as? String,previous["id"] as? String)
        XCTAssertEqual(current["takeover_reason"] as? String,"Coordinate the remaining pass")
        XCTAssertEqual(taken["orchestration_connection"] as? String,"current");XCTAssertTrue(bool(taken,"active_attention"))
        XCTAssertEqual(try jsonString(taken["members"]!),try jsonString(started["members"]!))
        XCTAssertEqual(try orchestrationProtectedRecords(p),protected)
        let notice = try XCTUnwrap(taken["takeover_notice"] as? JSON), delivery = try XCTUnwrap((notice["deliveries"] as? [JSON])?.first)
        XCTAssertEqual(notice["delivery_status"] as? String,"queued")
        XCTAssertEqual(delivery["recipient_session_id"] as? String,old.sessionID)
        XCTAssertEqual(delivery["state"] as? String,"queued")
        let inbox = try call("session_inbox",["project_id":p["id"]!],old)["messages"] as! [JSON]
        let message = try XCTUnwrap(inbox.first {$0["id"] as? String == notice["message_id"] as? String})
        XCTAssertTrue((message["body"] as! String).contains("Coordinate the remaining pass"))
        XCTAssertTrue((message["body"] as! String).contains(current["actor_display"] as! String))
        XCTAssertEqual((message["subject"] as? JSON)?["id"] as? String,group["id"] as? String)
        let history = try orchestrationHistory(p,group)
        let ended = try XCTUnwrap(history.first {$0["kind"] as? String == "triage_orchestration_taken_over"}?["data"] as? JSON)["orchestration"] as! JSON
        XCTAssertEqual(ended["id"] as? String,previous["id"] as? String);XCTAssertEqual(ended["state"] as? String,"taken_over")
        XCTAssertEqual(ended["taken_over_by_orchestration_id"] as? String,current["id"] as? String)
        XCTAssertEqual(try jsonString(call("triage_orchestrate",input,next,command:command)),try jsonString(taken))
        XCTAssertEqual(try orchestrationHistory(p,group).count,history.count)
        assertCode("REVISION_CONFLICT") { _ = try self.call("triage_orchestrate",input,next) }
        for action in ["checkpoint","finish"] { assertCode("FORBIDDEN") { _ = try self.orchestrate(p,group,action,old) } }
        _ = try orchestrate(p,group,"checkpoint",next)
        _ = try orchestrate(p,group,"finish",next)
        XCTAssertEqual(try orchestrationProtectedRecords(p),protected)
    }
    func testTriageTakeoverFromEndedSessionRetainsNoticeWithoutClaimingDelivery() throws {
        let (p, group, _) = try orchestrationFixture(), old = try native(p,"ended-coordinator",domain:"old"), next = try native(p,"replacement",domain:"next")
        _ = try orchestrate(p,group,"start",old)
        let session = try router.dbQueue.read { try router.record($0,old.sessionID!,type:"session") }
        _ = try call("session_update",["project_id":p["id"]!,"session_id":old.sessionID!,"expected_revision":session["revision"]!,"state":"ended"])
        let projected = try call("triage_list",["project_id":p["id"]!])["groups"] as! [JSON]
        XCTAssertEqual(projected.first?["orchestration_connection"] as? String,"recovery_required")
        let protected = try orchestrationProtectedRecords(p)
        let taken = try orchestrate(p,group,"takeover",next,reason:"Continue after the earlier conversation ended")
        let notice = taken["takeover_notice"] as! JSON
        XCTAssertEqual(notice["delivery_status"] as? String,"saved_for_pickup");XCTAssertTrue((notice["deliveries"] as! [JSON]).isEmpty)
        XCTAssertEqual(try orchestrationProtectedRecords(p),protected)
        let messages = try call("history_list",["project_id":p["id"]!,"triage_id":group["id"]!])["messages"] as! [JSON]
        XCTAssertTrue(messages.contains {$0["id"] as? String == notice["message_id"] as? String})
        // Owner finish remains available with a reason after takeover too.
        assertCode("INVALID_INPUT") { _ = try self.orchestrate(p,group,"finish") }
        let finished = try orchestrate(p,group,"finish",reason:"Owner closes stale coordination")
        XCTAssertEqual((finished["orchestration"] as! JSON)["owner_finish_reason"] as? String,"Owner closes stale coordination")
        XCTAssertFalse(bool(finished,"active_attention"))
    }
    func testTriageTakeoverRequiresReasonDifferentSessionAndCoordinatorEligibility() throws {
        let (p, group, _) = try orchestrationFixture(), old = try native(p,"original",domain:"old"), next = try native(p,"new",domain:"new")
        assertCode("INVALID_TRANSITION") { _ = try self.orchestrate(p,group,"takeover",next,reason:"No earlier record") }
        _ = try orchestrate(p,group,"start",old)
        let before = try orchestrationHistory(p,group).count
        assertCode("INVALID_INPUT") { _ = try self.orchestrate(p,group,"takeover",next) }
        assertCode("INVALID_INPUT") { _ = try self.orchestrate(p,group,"takeover",next,reason:" \n ") }
        assertCode("INVALID_INPUT") { _ = try self.orchestrate(p,group,"takeover",old,reason:"Same conversation") }
        assertCode("ACTUAL_SESSION_REQUIRED") { _ = try self.orchestrate(p,group,"takeover",reason:"Owner needs an actual worker") }
        let assistant = Caller(role:"assistant",installation:next.installation,projectIDs:[p["id"] as! String],sessionID:next.sessionID,workspace:workspace.path,executionDomain:next.executionDomain)
        assertCode("FORBIDDEN") { _ = try self.orchestrate(p,group,"takeover",assistant,reason:"Assistant cannot coordinate") }
        XCTAssertEqual(try orchestrationHistory(p,group).count,before)
        _ = try call("policy_apply",["project_id":p["id"]!,"expected_revision":p["revision"]!,"policy":["routing_preset":"claude_coordinates"],"mode":"future_attempts"])
        assertCode("POLICY_DENIED") { _ = try self.orchestrate(p,group,"takeover",next,reason:"Provider is denied coordination") }
        // Loss of coordinator eligibility must not prevent the existing owner finish route.
        _ = try orchestrate(p,group,"finish",reason:"Owner explicitly ended coordination")
    }

    func testTriageTakeoverLateValidationRollsBackNoticeAndHistory() throws {
        let (p, group, _) = try orchestrationFixture(), old = try native(p,"rollback-original",domain:"old"), next = try native(p,"rollback-next",domain:"next")
        let started = try orchestrate(p,group,"start",old)
        let history = try orchestrationHistory(p,group).count
        let before = try router.dbQueue.read { db in try jsonString([router.record(db,group["id"] as! String,type:"group"),["messages":router.records(db,type:"message",project:p["id"] as? String),"deliveries":router.records(db,type:"delivery",project:p["id"] as? String)]]) }
        assertCode("INVALID_INPUT") {
            _ = try self.call("triage_orchestrate",["project_id":p["id"]!,"triage_id":group["id"]!,"expected_revision":started["revision"]!,"action":"takeover","reason":"Valid reason","progress":" "],next)
        }
        let after = try router.dbQueue.read { db in try jsonString([router.record(db,group["id"] as! String,type:"group"),["messages":router.records(db,type:"message",project:p["id"] as? String),"deliveries":router.records(db,type:"delivery",project:p["id"] as? String)]]) }
        XCTAssertEqual(after,before);XCTAssertEqual(try orchestrationHistory(p,group).count,history)
    }

    // CL-139 recovery is finish-only. CL-197 separately authorizes another eligible
    // coordinator's explicit reasoned takeover, never an implicit start or finish.
    func testTriageResumedClaudeFinishesWithClosureLinkAndRestartsWithHistory() throws {
        let (p, group, _) = try orchestrationFixture(), old = try native(p,"resumed-orchestrator",domain:"claude:123:5:0",provider:"claude")
        let started = try orchestrate(p,group,"start",old), original = started["orchestration"] as! JSON
        let (resumed, closure) = try closeAndResumeOrchestrator(p,old)
        let other = try native(p,"other-orchestrator",domain:"host-other")
        let protected = try orchestrationProtectedRecords(p)
        for action in ["checkpoint","finish"] { assertCode("FORBIDDEN") { _ = try self.orchestrate(p,group,action,other,reason:"Another conversation") } }
        assertCode("CLAIM_CONFLICT") { _ = try self.orchestrate(p,group,"start",other) }
        assertCode("FORBIDDEN") { _ = try self.orchestrate(p,group,"checkpoint",resumed) }
        assertCode("INVALID_INPUT") { _ = try self.orchestrate(p,group,"takeover",resumed,reason:"Use own recovery instead") }
        assertCode("INVALID_INPUT") { _ = try self.orchestrate(p,group,"finish",resumed) }
        assertCode("CLAIM_CONFLICT") { _ = try self.orchestrate(p,group,"start",resumed) }
        let finished = try orchestrate(p,group,"finish",resumed,reason:"Resume after verified process closure"), ended = finished["orchestration"] as! JSON
        XCTAssertEqual(ended["id"] as? String,original["id"] as? String)
        XCTAssertEqual(ended["native_closure_ref"] as? String,closure)
        XCTAssertEqual(ended["recovery_finish_reason"] as? String,"Resume after verified process closure")
        XCTAssertEqual(ended["principal"] as? String,old.principal);XCTAssertEqual(ended["finished_by_principal"] as? String,resumed.principal)
        let restarted = try orchestrate(p,group,"start",resumed), current = restarted["orchestration"] as! JSON
        XCTAssertNotEqual(current["id"] as? String,original["id"] as? String)
        XCTAssertEqual(current["previous_orchestration_id"] as? String,original["id"] as? String)
        XCTAssertEqual(current["principal"] as? String,resumed.principal);XCTAssertEqual(restarted["orchestration_connection"] as? String,"current")
        _ = try orchestrate(p,group,"checkpoint",resumed)
        let history = try orchestrationHistory(p,group)
        XCTAssertTrue(history.contains { event in
            let record = (event["data"] as? JSON)?["orchestration"] as? JSON
            return event["kind"] as? String == "triage_orchestration_finish" && record?["native_closure_ref"] as? String == closure && record?["id"] as? String == original["id"] as? String
        })
        XCTAssertEqual(history.filter {$0["kind"] as? String == "triage_orchestration_start"}.count,2)
        XCTAssertEqual(try orchestrationProtectedRecords(p),protected)
    }
    func testTriageResumeRebindsInOneCommandWithHistoryAndNoMemberAuthority() throws {
        let (p, group, tasks) = try orchestrationFixture()
        let old = try native(p,"one-step-resume",domain:"claude:123:5:0",provider:"claude")
        let started = try orchestrate(p,group,"start",old), original = started["orchestration"] as! JSON
        _ = try claim(p,tasks[0],caller:old)
        let (resumed, closure) = try closeAndResumeOrchestrator(p,old)
        let other = try native(p,"resume-foreign",domain:"host-other")
        let protected = try orchestrationProtectedRecords(p)
        let summary = try XCTUnwrap((call("service_info",[:],resumed)["native_recovery"] as? [JSON])?.first)
        let recovery = try XCTUnwrap((summary["recovery_required_orchestrations"] as? [JSON])?.first)
        XCTAssertEqual(recovery["triage_id"] as? String,group["id"] as? String)
        XCTAssertEqual(recovery["key"] as? String,group["key"] as? String)
        XCTAssertNotNil(recovery["recovery_required_at"])
        XCTAssertTrue((recovery["recovery_step"] as? String ?? "").contains("action=resume"))
        assertCode("FORBIDDEN") { _ = try self.orchestrate(p,group,"resume",other,reason:"Wrong conversation") }
        assertCode("INVALID_INPUT") { _ = try self.orchestrate(p,group,"resume",resumed) }
        assertCode("INVALID_INPUT") { _ = try self.orchestrate(p,group,"resume",resumed,reason:" ") }
        // The checkpoint refusal names the one-step route for the resumed conversation.
        XCTAssertThrowsError(try orchestrate(p,group,"checkpoint",resumed)) {
            XCTAssertEqual(($0 as? CoreError)?.code,"FORBIDDEN"); XCTAssertTrue(($0 as? CoreError)?.message.contains("action=resume") ?? false)
        }
        let command = UUID().uuidString
        let input: JSON = ["project_id":p["id"]!,"triage_id":group["id"]!,"expected_revision":recovery["expected_revision"]!,"action":"resume","reason":"Continue after native closure"]
        let rebound = try call("triage_orchestrate",input,resumed,command:command)
        let current = rebound["orchestration"] as! JSON
        XCTAssertNotEqual(current["id"] as? String,original["id"] as? String)
        XCTAssertEqual(current["previous_orchestration_id"] as? String,original["id"] as? String)
        XCTAssertEqual(current["resumed_from_orchestration_id"] as? String,original["id"] as? String)
        XCTAssertEqual(current["native_closure_ref"] as? String,closure)
        XCTAssertEqual(current["principal"] as? String,resumed.principal)
        XCTAssertEqual(rebound["orchestration_connection"] as? String,"current")
        XCTAssertEqual(try jsonString(rebound["members"]!),try jsonString(started["members"]!))
        XCTAssertEqual(try orchestrationProtectedRecords(p),protected)
        XCTAssertEqual(try jsonString(call("triage_orchestrate",input,resumed,command:command)),try jsonString(rebound))
        let history = try orchestrationHistory(p,group)
        let ended = try XCTUnwrap(history.first {$0["kind"] as? String == "triage_orchestration_rebound"}?["data"] as? JSON)["orchestration"] as! JSON
        XCTAssertEqual(ended["id"] as? String,original["id"] as? String)
        XCTAssertEqual(ended["state"] as? String,"resumed")
        XCTAssertEqual(ended["native_closure_ref"] as? String,closure)
        let refreshed = try XCTUnwrap((call("service_info",[:],resumed)["native_recovery"] as? [JSON])?.first)
        XCTAssertTrue((refreshed["recovery_required_orchestrations"] as! [JSON]).isEmpty)
        assertCode("FORBIDDEN") { _ = try self.orchestrate(p,group,"resume",resumed,reason:"Already current") }
        _ = try orchestrate(p,group,"checkpoint",resumed)
        XCTAssertEqual(try orchestrationProtectedRecords(p),protected)
    }
    func testTriageRecoveryRefusesUnverifiedGenerationRotationAndForeignClosure() throws {
        let (p, group, _) = try orchestrationFixture(), old = try native(p,"unverified-orchestrator",domain:"claude:123:5:0",provider:"claude")
        _ = try orchestrate(p,group,"start",old)
        // Ordinary owner end/reconnect rotates authority but supplies no native resumption proof.
        var session = try router.dbQueue.read { try router.record($0,old.sessionID!,type:"session") }
        session = try call("session_update",["project_id":p["id"]!,"session_id":old.sessionID!,"expected_revision":session["revision"]!,"state":"ended"])
        _ = try call("session_update",["project_id":p["id"]!,"session_id":old.sessionID!,"expected_revision":session["revision"]!,"state":"connected"])
        assertCode("FORBIDDEN") { _ = try self.orchestrate(p,group,"finish",old,reason:"Not a verified resumption") }
        assertCode("FORBIDDEN") { _ = try self.orchestrate(p,group,"resume",old,reason:"Not a verified resumption") }
        // Even a real later closure does not match the orchestration's original generation.
        let (resumed, _) = try closeAndResumeOrchestrator(p,old)
        assertCode("FORBIDDEN") { _ = try self.orchestrate(p,group,"finish",resumed,reason:"Wrong closed generation") }
        assertCode("FORBIDDEN") { _ = try self.orchestrate(p,group,"resume",resumed,reason:"Wrong closed generation") }
        _ = try orchestrate(p,group,"finish",reason:"Owner recovery stays available")
    }
}
