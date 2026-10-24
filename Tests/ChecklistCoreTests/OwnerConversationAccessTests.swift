import XCTest
@testable import ChecklistCore

extension EvidenceAuthorityTests {
    private func accessInput(_ p: JSON, _ worker: Caller, task: JSON? = nil) throws -> JSON {
        let session = try router.dbQueue.read { try router.record($0,worker.sessionID!,type:"session") }
        var input: JSON = ["project_id":p["id"]!,"session_id":worker.sessionID!,"installation":session["installation"]!,"expected_revision":session["revision"]!]
        if let task { input["task_id"] = task["id"] }
        return input
    }
    private var accessBootstrap: Caller { Caller(role:"owner",installation:"native-thread-bootstrap",projectIDs:[]) }
    private func accessResumption(_ p: JSON, _ worker: Caller, domain: String? = nil) -> NativeSessionResumption {
        NativeSessionResumption(projectID:p["id"] as! String,sessionID:worker.sessionID!,provider:"codex",
            oldInstallation:worker.installation,oldExecutionDomain:worker.executionDomain!,
            newInstallation:worker.installation+"/new",newExecutionDomain:domain ?? worker.executionDomain!)
    }
    func testOwnerDisconnectReturnsAllOwnClaimsAndFencesOldMessagesWithHistory() throws {
        let p = try project(), worker = try native(p,"disconnect",domain:"codex:301:1:0")
        let t1 = try ready(p), t2 = try ready(p), other = try native(p,"unaffected",domain:"codex:302:1:0"), t3 = try ready(p)
        let a1 = try claim(p,t1,caller:worker), a2 = try claim(p,t2,caller:worker), a3 = try claim(p,t3,caller:other)
        let note = try call("message_send",["project_id":p["id"]!,"task_id":t1["id"]!,"body":"Old queued message","recipient":["kind":"session","session_id":worker.sessionID!]])
        let initial = try call("task_context",["task_id":t1["id"]!,"detail_level":"ui"])
        let displaySession = try XCTUnwrap(((initial["collections"] as! JSON)["sessions"] as! [JSON]).first)
        XCTAssertEqual(displaySession["installation"] as? String,worker.installation)
        XCTAssertNotNil(displaySession["revision"])
        let input = try accessInput(p,worker,task:t1), command = UUID().uuidString
        let result = try call("connection_revoke",input,command:command)
        XCTAssertEqual(Set(result["released_attempt_ids"] as! [String]),Set([a1["id"] as! String,a2["id"] as! String]))
        XCTAssertEqual(result["pending_attempt_ids"] as? [String],[])
        // Same command is a durable receipt, not a second owner event or release.
        XCTAssertEqual(try call("connection_revoke",input,command:command)["session_id"] as? String,worker.sessionID)
        try router.dbQueue.read { db in
            let session = try router.record(db,worker.sessionID!,type:"session")
            XCTAssertEqual(session["state"] as? String,"revoked"); XCTAssertTrue(bool(session,"owner_revoked"))
            for task in [t1,t2] {
                let stored = try router.record(db,task["id"] as! String,type:"task")
                XCTAssertNil(stored["active_attempt_id"])
                XCTAssertEqual(stored["status_id"] as? String,try router.status(db,p["id"] as! String,"queued")["id"] as? String)
            }
            XCTAssertEqual(try router.record(db,a3["id"] as! String,type:"attempt")["state"] as? String,"active")
        }
        let selected = try call("task_context",["task_id":t1["id"]!,"detail_level":"ui"])
        let detailed = try call("task_context",["task_id":t1["id"]!,"detail_level":"ui_records","selected_context_cursor":selected["context_cursor"]!])
        for context in [selected,detailed] {
            let projected = try XCTUnwrap(((context["collections"] as! JSON)["sessions"] as! [JSON]).first { $0["id"] as? String == worker.sessionID })
            XCTAssertEqual(projected["owner_revoked"] as? Bool,true)
            XCTAssertEqual(projected["installation"] as? String,worker.installation)
            XCTAssertNotNil(projected["revision"])
        }
        let receipts = try call("message_delivery_list",["project_id":p["id"]!,"task_id":t1["id"]!,"message_id":note["id"]!])["deliveries"] as! [JSON]
        XCTAssertEqual(receipts.first?["state"] as? String,"fenced"); XCTAssertNil(receipts.first?["acknowledged_at"])
        let events = try call("history_list",["project_id":p["id"]!,"task_id":t1["id"]!])["events"] as! [JSON]
        let ownerEvents = events.filter { $0["kind"] as? String == "owner_conversation_disconnected" }
        XCTAssertEqual(ownerEvents.count,1); XCTAssertEqual(ownerEvents.first?["actor"] as? String,owner.principal)
        XCTAssertEqual(events.filter { $0["kind"] as? String == "work_released" }.count,1)
        let otherEvents = try call("history_list",["project_id":p["id"]!,"task_id":t2["id"]!])["events"] as! [JSON]
        XCTAssertEqual(otherEvents.filter { $0["kind"] as? String == "work_released" }.count,1)
        XCTAssertFalse(events.contains { ["task_completed","review_recorded","message_acknowledged"].contains($0["kind"] as? String ?? "") })
        assertCode("CONNECTION_REVOKED") { _ = try self.router.reconnectOwnerAllowedSession(self.accessResumption(p,worker),caller:self.accessBootstrap) }
    }
    func testOwnerAllowRequiresVerifiedFreshReconnectAndCannotReviveClaimOrDelivery() throws {
        let p = try project(), worker = try native(p,"allow",domain:"codex:303:1:0"), t = try ready(p)
        let a = try claim(p,t,caller:worker)
        let note = try call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"Fenced forever"])
        _ = try call("connection_revoke",accessInput(p,worker,task:t))
        _ = try call("connection_allow",accessInput(p,worker,task:t))
        assertCode("FORBIDDEN") { _ = try self.router.reconnectOwnerAllowedSession(self.accessResumption(p,worker),caller:self.owner) }
        let connected = try router.reconnectOwnerAllowedSession(accessResumption(p,worker),caller:accessBootstrap)
        XCTAssertEqual(connected["state"] as? String,"connected")
        XCTAssertEqual(connected["execution_domain"] as? String,worker.executionDomain,"Allow again works for a still-running actual host too")
        let resumed = Caller(role:"worker",installation:worker.installation+"/new",projectIDs:worker.projectIDs,sessionID:worker.sessionID,workspace:workspace.path,executionDomain:worker.executionDomain)
        var checkpoint = auth(p,a); checkpoint["progress"] = "Old claim cannot resume"
        assertCode("STALE_CLAIM") { _ = try self.call("work_checkpoint",checkpoint,resumed) }
        let inbox = try call("session_inbox",["project_id":p["id"]!],resumed)["deliveries"] as! [JSON]
        XCTAssertFalse(inbox.contains { $0["message_id"] as? String == note["id"] as? String })
        let returned = try router.dbQueue.read { try router.record($0,t["id"] as! String,type:"task") }
        _ = try claim(p,returned,caller:resumed)
        assertCode("CONNECTION_REVOKED") { _ = try self.router.reconnectOwnerAllowedSession(self.accessResumption(p,worker),caller:self.accessBootstrap) }
        let events = try call("history_list",["project_id":p["id"]!,"task_id":t["id"]!])["events"] as! [JSON]
        XCTAssertEqual(events.filter { $0["kind"] as? String == "owner_conversation_allowed" }.count,1)
    }
    func testOwnerDisconnectActionsAreAbsentAndRefusedForWorkersAndAssistants() throws {
        let p = try project(), worker = try native(p,"forbidden-access",domain:"codex:304:1:0")
        let assistant = Caller(role:"assistant",installation:"assistant",projectIDs:worker.projectIDs,assistantGrants:[p["id"] as! String:["read":true]])
        for caller in [worker,assistant] {
            let names = router.toolCatalog(caller).compactMap { $0["name"] as? String }
            for method in ["connection_revoke","connection_allow"] {
                XCTAssertFalse(names.contains(method))
                assertCode("FORBIDDEN") { _ = try self.call(method,self.accessInput(p,worker),caller) }
            }
        }
        let session = try accessInput(p,worker)
        assertCode("FORBIDDEN") { _ = try self.call("session_update",["project_id":p["id"]!,"expected_revision":session["expected_revision"]!,"state":"revoked"],worker) }
        _ = try call("connection_revoke",accessInput(p,worker))
        for method in ["session_update","session_register"] {
            let current = try accessInput(p,worker)
            var input: JSON = ["project_id":p["id"]!,"expected_revision":current["expected_revision"]!]
            if method == "session_update" { input["state"] = "connected" }
            assertCode("FORBIDDEN") { _ = try self.call(method,input,worker) }
        }
    }
    func testOwnerAccessRefusesStaleRevisionAndDifferentRegistration() throws {
        let p = try project(), worker = try native(p,"revision-access",domain:"codex:305:1:0")
        var stale = try accessInput(p,worker); stale["expected_revision"] = 0
        assertCode("REVISION_CONFLICT") { _ = try self.call("connection_revoke",stale) }
        var wrong = try accessInput(p,worker); wrong["installation"] = "different"
        assertCode("RECIPIENT_CHANGED") { _ = try self.call("connection_revoke",wrong) }
        assertCode("INVALID_TRANSITION") { _ = try self.call("connection_allow",self.accessInput(p,worker)) }
        XCTAssertEqual(try router.dbQueue.read { try router.record($0,worker.sessionID!,type:"session") }["state"] as? String,"connected")
    }
    func testOwnerDisconnectRetainsUnstoppedSourceReservationsUntilRecovery() throws {
        let p = try project(), worker = try native(p,"source-access",domain:"codex:306:1:0"), t = try ready(p)
        let a = try claim(p,t,files:[["path":"Sources","access":"write"]],caller:worker), job = UUID().uuidString
        try router.dbQueue.write { db in
            try router.save(db,["id":job,"project_id":p["id"]!,"task_id":t["id"]!,"attempt_id":a["id"]!,"state":"interrupted","revision":1],type:"source_execution")
        }
        let result = try call("connection_revoke",accessInput(p,worker))
        XCTAssertEqual(result["released_attempt_ids"] as? [String],[]); XCTAssertEqual(result["pending_attempt_ids"] as? [String],[a["id"] as! String])
        assertCode("OWNER_DISCONNECT_PENDING") { _ = try self.call("connection_allow",self.accessInput(p,worker)) }
        let retained = try router.dbQueue.read { try router.record($0,a["id"] as! String,type:"attempt") }
        XCTAssertEqual(retained["state"] as? String,"active"); XCTAssertNotNil(retained["token_hash"])
        // Only the explicit stopped source state permits a later owner retry to release.
        try router.dbQueue.write { db in
            var source = try router.record(db,job,type:"source_execution"); source["state"] = "stopped"
            try router.save(db,router.revised(source),type:"source_execution")
        }
        XCTAssertEqual(try call("connection_revoke",accessInput(p,worker))["released_attempt_ids"] as? [String],[a["id"] as! String])
        _ = try call("connection_allow",accessInput(p,worker))
    }
    func testOwnerDisconnectRetainsForeignWritableChildAndRequeuesReviewWithoutVerdict() throws {
        let p = try project(), parent = try native(p,"parent-access",domain:"codex:307:1:0"), child = try native(p,"child-access",domain:"codex:308:1:0"), t = try ready(p)
        let a = try claim(p,t,files:[["path":"Sources","access":"write"]],caller:parent)
        var offerInput = auth(p,a); offerInput["child_session_id"] = child.sessionID!; offerInput["file_scopes"] = [["path":"Sources/Child.swift","access":"write"]]
        let offer = try call("work_delegate",offerInput,parent)
        let b = try call("work_child_accept",["project_id":p["id"]!,"delegation_id":offer["id"]!],child)
        XCTAssertEqual(try call("connection_revoke",accessInput(p,parent))["pending_attempt_ids"] as? [String],[a["id"] as! String])
        var release = auth(p,b); release["reason"] = "Child explicitly stopped"
        do { _ = try call("work_release",release,child) }
        catch { XCTFail("Child release fixture: \(error)"); return }
        _ = try call("connection_revoke",accessInput(p,parent))
        // A separate review claim returns its existing request for an independent pickup.
        let author = try native(p,"author-access",domain:"codex:309:1:0"), reviewer = try native(p,"review-access",domain:"codex:310:1:0"), reviewTask = try ready(p)
        try sourceFixture()
        let implementation = try claim(p,reviewTask,caller:author)
        let submission: JSON
        do {
            var input = auth(p,implementation); input["acceptance_revision"] = 1; input["evidence_manifest"] = ["kind":"source","source_capture":[:]]
            submission = try call("work_submit",input,author)
        }
        catch { XCTFail("Review submission fixture: \(error)"); return }
        let review = try reviewClaim(p,submission,reviewer)
        _ = try call("connection_revoke",accessInput(p,reviewer))
        let request = try router.dbQueue.read { try router.record($0,review["review_request_id"] as! String,type:"review_request") }
        XCTAssertEqual(request["state"] as? String,"queued"); XCTAssertNil(request["latest_verdict_id"])
    }
    func testOwnerAccessSurvivesNativeClosureBeforeOrAfterAllowAgain() throws {
        let p = try project()
        for allowBeforeClosure in [false,true] {
            let worker = try native(p,"closure-access-\(allowBeforeClosure)",domain:"codex:311:1:0")
            _ = try call("connection_revoke",accessInput(p,worker))
            if allowBeforeClosure { _ = try call("connection_allow",accessInput(p,worker)) }
            let session = try router.dbQueue.read { try router.record($0,worker.sessionID!,type:"session") }
            let proof = VerifiedNativeClosure(projectID:p["id"] as! String,sessionID:worker.sessionID!,installation:worker.installation,
                executionDomain:worker.executionDomain!,provider:"codex",authorizationGeneration:session["authorization_generation"] as! String,
                processState:"gone",registryState:"absent",registryDigest:nil)
            _ = try router.reconcileVerifiedNativeClosure(proof,caller:Caller(role:"owner",installation:"native-lifecycle",projectIDs:[]))
            if !allowBeforeClosure {
                assertCode("CONNECTION_REVOKED") { _ = try self.router.resumeVerifiedNativeSession(self.accessResumption(p,worker,domain:"codex:312:2:0"),caller:self.accessBootstrap) }
                _ = try call("connection_allow",accessInput(p,worker))
            }
            let connected = try router.reconnectOwnerAllowedSession(accessResumption(p,worker,domain:"codex:312:2:0"),caller:accessBootstrap)
            XCTAssertEqual(connected["state"] as? String,"connected")
            XCTAssertNotNil(connected["prior_native_closure_refs"])
        }
    }

    func testOwnerDisconnectKeepsContextOnlyConversationVisibleUntilReconnect() throws {
        let p = try project(), worker = try native(p,"context-access",domain:"codex:313:1:0"), t = try ready(p)
        _ = try call("session_attach_task",["project_id":p["id"]!,"task_id":t["id"]!],worker)
        _ = try call("connection_revoke",accessInput(p,worker,task:t))
        for allow in [false,true] {
            if allow { _ = try call("connection_allow",accessInput(p,worker,task:t)) }
            let selected = try call("task_context",["task_id":t["id"]!,"detail_level":"ui"])
            let detailed = try call("task_context",["task_id":t["id"]!,"detail_level":"ui_records","selected_context_cursor":selected["context_cursor"]!])
            let collections = detailed["collections"] as! JSON
            XCTAssertEqual((collections["task_sessions"] as! [JSON]).count,1)
            let session = try XCTUnwrap((collections["sessions"] as! [JSON]).first)
            XCTAssertEqual(session[allow ? "owner_reconnect_allowed" : "owner_revoked"] as? Bool,true)
            XCTAssertEqual(session["installation"] as? String,worker.installation)
        }
    }

}
