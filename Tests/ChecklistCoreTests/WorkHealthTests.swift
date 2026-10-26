import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

/// Bounded, owned-store tests. No service, model, installation or live ticket is used.
extension EvidenceAuthorityTests {
    private func healthWrite(_ body: (Database) throws -> Void) throws {
        try router.dbQueue.writeWithoutTransaction { db in
            try router.withValidatedDomainTransaction(db) { try body(db); return .commit }
        }
    }
    private func healthTask(_ p: JSON, _ t: JSON) throws -> JSON {
        try call("task_get", ["project_id":p["id"]!, "task_id":t["id"]!])
    }
    private func health(_ p: JSON, _ t: JSON) throws -> JSON {
        try call("work_health_get", ["project_id":p["id"]!, "task_id":t["id"]!])
    }
    private func healthRows(_ type: String, task: JSON) throws -> [JSON] {
        try router.dbQueue.read { try router.scopedTaskRows($0, type:type, task:task) }
    }
    private func ageHealthAttempt(_ a: JSON, by seconds: Double = 1201) throws {
        try healthWrite { db in
            var row = try router.record(db,a["id"] as! String,type:"attempt")
            row["started_at"] = ISO8601DateFormatter().string(from:Date().addingTimeInterval(-seconds))
            try router.save(db,row,type:"attempt")
        }
    }
    private func checkHealth(at date: Date = Date()) throws {
        // Only this deterministic one-page fixture invocation; never a polling loop.
        _ = try router.runWorkHealthChecks(at:date)
    }
    private func respondHealth(_ p: JSON, _ t: JSON, request: String, caller: Caller, progress: String = "Still handling this; awaiting the bounded build") throws -> JSON {
        try call("work_health_respond", ["project_id":p["id"]!, "task_id":t["id"]!, "request_id":request, "expected_revision":healthTask(p,t)["revision"]!, "progress":progress], caller)
    }
    func testWorkHealthInspectionDoesNotReadDisplayOnlyFacts() throws {
        let p = try project(), t = try ready(p), w = try native(p,"health-narrow",domain:"health-narrow")
        _ = try claim(p,t,caller:w)
        var statements: [String] = []
        try router.dbQueue.read { db in
            db.trace { if case .statement(let statement) = $0 { statements.append(statement.expandedSQL) } }
        }
        defer { try? router.dbQueue.read { $0.trace(options:[]) } }
        let result = try router.runWorkHealthChecks()
        XCTAssertEqual(result["inspected"] as? Int,1)
        for family in ["attachment","tag","relation"] {
            XCTAssertFalse(statements.contains { $0.hasPrefix("SELECT") && $0.contains("type='" + family + "'") }, "Health eligibility must not project \(family) display facts")
        }
        XCTAssertNotNil(try health(p,t)["current_target"])
    }

    func testWorkHealthFallbackKeepsExactFactsWithoutDisplayReads() throws {
        let p = try project(), t = try ready(p), prerequisite = try ready(p)
        let w = try native(p,"health-facts",domain:"health-facts")
        _ = try claim(p,t,caller:w)
        try healthWrite { db in
            try router.save(db,["id":uuid(),"project_id":p["id"]!,"source_task_id":t["id"]!,"target_task_id":prerequisite["id"]!,"relation":"depends_on","required":true,"state":"active","revision":1],type:"relation")
        }
        try router.dbQueue.read { db in
            let task = try router.record(db,t["id"] as! String,type:"task")
            let selected = try router.selectedTaskProjectionWithoutHealth(db,task:task)
            let expected = try router.workHealthView(db,task:task,selectedProjection:selected)
            var statements: [String] = []
            db.trace { if case .statement(let statement) = $0 { statements.append(statement.expandedSQL) } }
            let actual = try router.workHealthView(db,task:task)
            db.trace(options:[])
            XCTAssertEqual(try jsonString(actual),try jsonString(expected))
            XCTAssertTrue((actual["known_waits"] as? [JSON] ?? []).contains { $0["kind"] as? String == "dependency" })
            for family in ["attachment","tag"] {
                XCTAssertFalse(statements.contains { $0.hasPrefix("SELECT") && $0.contains("type='" + family + "'") }, "Health response must not render \(family) display facts")
            }
        }
    }

    func testWorkHealthPagesYieldAndResumeWithoutSkippingCandidates() throws {
        let p = try project(), template = try ready(p)
        var ids: [String] = []
        try healthWrite { db in
            let status = try XCTUnwrap(router.records(db,type:"status",project:p["id"] as? String).first { $0["category"] as? String == "active" })
            for index in 0..<30 {
                var task = template;let id = uuid();ids.append(id)
                task["id"] = id;task["key"] = "HEALTH-PAGE-\(index)";task["revision"] = 1;task["status_id"] = status["id"]
                try router.save(db,task,type:"task")
            }
        }
        var inspected = 0
        for _ in 0..<3 {
            let page = try router.runWorkHealthChecks()
            XCTAssertEqual(page["scanned"] as? Int,10)
            XCTAssertEqual(page["has_more"] as? Bool,true)
            inspected += page["inspected"] as? Int ?? 0
        }
        let end = try router.runWorkHealthChecks()
        XCTAssertEqual(end["scanned"] as? Int,0);XCTAssertEqual(end["has_more"] as? Bool,false)
        XCTAssertEqual(inspected,30)
        try router.dbQueue.read { db in
            for id in ids { XCTAssertNotNil(try router.record(db,id,type:"task")["work_health"]) }
        }
    }

    func testWorkHealthDefaultsOverridesAndInvalidSettings() throws {
        let p = try project()
        let got = try call("project_settings_get",["project_id":p["id"]!])
        XCTAssertEqual((got["work_health_settings"] as? JSON)?["inactivity_minutes"] as? Int,20)
        XCTAssertEqual((got["work_health_settings"] as? JSON)?["response_grace_minutes"] as? Int,20)
        let configured = try call("project_settings_save",["project_id":p["id"]!,"expected_revision":p["revision"]!,"work_health_settings":["enabled":true,"inactivity_minutes":15,"response_grace_minutes":7]])
        XCTAssertEqual((configured["work_health_settings"] as? JSON)?["inactivity_minutes"] as? Int,15)
        for invalid: Any in [0, -1, 1.5, true, "15", 10081] {
            assertCode("INVALID_INPUT") { _ = try self.call("project_settings_save",["project_id":p["id"]!,"expected_revision":configured["revision"]!,"work_health_settings":["enabled":true,"inactivity_minutes":invalid,"response_grace_minutes":20]]) }
        }
    }
    func testWorkHealthInactivityGraceAckIsNotResponseAndNoAuthorityChange() throws {
        let p = try project(), t = try ready(p), worker = try native(p,"health-worker",domain:"health-A")
        let a = try claim(p,t,files:[["path":"Sources","access":"write"]],caller:worker)
        try checkHealth(); XCTAssertEqual(try health(p,t)["state"] as? String,"current")
        try checkHealth(at:Date().addingTimeInterval(1202))
        let ping = try health(p,t), mid = try XCTUnwrap(ping["request_id"] as? String)
        let delivery = try XCTUnwrap((ping["deliveries"] as? [JSON])?.first)
        XCTAssertEqual(delivery["recipient_session_id"] as? String,worker.sessionID)
        XCTAssertEqual(delivery["state"] as? String,"queued")
        _ = try call("message_ack",["project_id":p["id"]!,"delivery_id":delivery["id"]!,"stage":"acknowledged"],worker)
        try checkHealth(at:Date().addingTimeInterval(2390)); XCTAssertEqual(try health(p,t)["state"] as? String,"awaiting_response")
        try checkHealth(at:Date().addingTimeInterval(2405)); XCTAssertEqual(try health(p,t)["state"] as? String,"no_response")
        try checkHealth(at:Date().addingTimeInterval(3600))
        XCTAssertEqual(try healthRows("message",task:t).filter { ($0["kind"] as? String) == "work_health" }.count,2)
        XCTAssertEqual(try health(p,t)["request_id"] as? String,mid)
        let after = try healthTask(p,t)
        XCTAssertEqual(after["active_attempt_id"] as? String,a["id"] as? String)
        XCTAssertEqual(after["status_category"] as? String,"active")
        var checkpoint = auth(p,a); checkpoint["progress"] = "Actual code complete"
        XCTAssertNoThrow(try call("work_checkpoint",checkpoint,worker),"Timeout never fences the live writer")
    }
    func testWorkHealthDuplicateTicksAndRestartRetainOneRequestAndDeadline() throws {
        let p = try project(), t = try ready(p), w = try native(p,"health-restart",domain:"health-R"), a = try claim(p,t,caller:w)
        try ageHealthAttempt(a); try checkHealth()
        let first = try health(p,t)
        try checkHealth(); try checkHealth()
        XCTAssertEqual(try healthRows("message",task:t).count,1)
        try router.closeStore(); router = try TestStore.router(root:directory.appendingPathComponent("store"))
        try checkHealth()
        let second = try health(p,t)
        XCTAssertEqual(first["request_id"] as? String,second["request_id"] as? String)
        XCTAssertEqual(first["deadline"] as? String,second["deadline"] as? String)
        XCTAssertEqual(try healthRows("message",task:t).count,1)
    }
    func testWorkHealthLivenessMetadataAndRepeatedCheckpointDoNotAdvanceProgress() throws {
        let p = try project(), t = try ready(p), w = try native(p,"health-live",domain:"health-L"), a = try claim(p,t,caller:w)
        var checkpoint = auth(p,a); checkpoint["progress"] = "Working on the parser"
        _ = try call("work_checkpoint",checkpoint,w)
        let old = ISO8601DateFormatter().string(from:Date().addingTimeInterval(-1300))
        try healthWrite { db in
            var row = try router.record(db,a["id"] as! String,type:"attempt"); row["health_progress_at"] = old; try router.save(db,row,type:"attempt")
        }
        _ = try call("work_checkpoint",checkpoint,w)
        let session = try router.dbQueue.read {try router.record($0,w.sessionID!,type:"session")}
        _ = try call("session_update",["project_id":p["id"]!,"expected_revision":session["revision"]!,"state":"connected"],w)
        let latest = try healthTask(p,t)
        _ = try call("task_edit",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":latest["revision"]!,"patch":["title":"Cosmetic edit"]])
        _ = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!])
        try checkHealth()
        XCTAssertEqual(try health(p,t)["last_progress_at"] as? String,old)
        XCTAssertEqual(try health(p,t)["state"] as? String,"awaiting_response")
        XCTAssertNotNil(try health(p,t)["last_seen"] as? String)
        checkpoint["progress"] = "Working on the parser \n"
        _ = try call("work_checkpoint",checkpoint,w);try checkHealth()
        XCTAssertEqual(try health(p,t)["state"] as? String,"awaiting_response","Whitespace-only checkpoint changes do not answer the request")
        XCTAssertEqual(try health(p,t)["last_progress_at"] as? String,old)
    }
    func testWorkHealthAcceptedChildProgressAndUnacceptedOfferAreDistinct() throws {
        let p = try project(), t = try ready(p), parent = try native(p,"health-parent",domain:"health-P"), child = try native(p,"health-child",domain:"health-C")
        let a = try claim(p,t,caller:parent); try ageHealthAttempt(a)
        var input = auth(p,a); input["child_session_id"] = child.sessionID!; input["brief"] = "Bounded child work"; input["file_scopes"] = []; input["lane_scopes"] = []
        let offer = try call("work_delegate",input,parent)
        try checkHealth(); XCTAssertEqual(try health(p,t)["state"] as? String,"awaiting_response")
        let b = try call("work_child_accept",["project_id":p["id"]!,"delegation_id":offer["id"]!],child)
        var checkpoint = auth(p,b); checkpoint["progress"] = "Child parser verified"
        _ = try call("work_checkpoint",checkpoint,child)
        // The accepted-tree token distinguishes substantive progress even in the same second.
        try checkHealth(); XCTAssertEqual(try health(p,t)["state"] as? String,"current")
        XCTAssertNil(try health(p,t)["request_id"])
    }
    func testWorkHealthLateReplyResumesCurrentHandlerAndIsIdempotent() throws {
        let p = try project(), t = try ready(p), w = try native(p,"health-late",domain:"health-Late"), a = try claim(p,t,caller:w)
        try ageHealthAttempt(a); try checkHealth()
        let mid = try health(p,t)["request_id"] as! String
        try checkHealth(at:Date().addingTimeInterval(1202))
        XCTAssertEqual(try respondHealth(p,t,request:mid,caller:w)["outcome"] as? String,"resumed")
        let notes = try healthRows("message",task:t).count
        XCTAssertEqual(try respondHealth(p,t,request:mid,caller:w)["outcome"] as? String,"resumed")
        XCTAssertEqual(try healthRows("message",task:t).filter { $0["kind"] as? String == "work_health" }.count,3)
        XCTAssertEqual(try healthRows("message",task:t).count,notes+1,"A new explicit response retains its own history, never repeats the outcome notice")
        XCTAssertEqual(try healthTask(p,t)["active_attempt_id"] as? String,a["id"] as? String)
        XCTAssertEqual(try health(p,t)["response_without_new_progress"] as? Bool,true)
    }
    func testWorkHealthLateReplyAfterTakeoverPreservesNewClaimAndAssignment() throws {
        let p = try project(), t = try ready(p), first = try native(p,"health-old",domain:"health-old"), next = try native(p,"health-new",domain:"health-new")
        let a = try claim(p,t,caller:first); try ageHealthAttempt(a); try checkHealth()
        let mid = try health(p,t)["request_id"] as! String, current = try healthTask(p,t)
        let replacement = try call("work_takeover",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":current["revision"]!,"reason":"Explicit takeover for this fixture"],next)
        let before = try healthTask(p,t)
        XCTAssertEqual(try respondHealth(p,t,request:mid,caller:first)["outcome"] as? String,"fresh_claim_or_handoff_required")
        let after = try healthTask(p,t)
        XCTAssertEqual(after["active_attempt_id"] as? String,replacement["id"] as? String)
        XCTAssertEqual(before["revision"] as? Int,after["revision"] as? Int)
    }
    func testWorkHealthOrdinaryCorrelatedReplyUsesTheSameReconciliation() throws {
        let p = try project(), t = try ready(p), w = try native(p,"health-reply",domain:"health-reply"), a = try claim(p,t,caller:w)
        try ageHealthAttempt(a); try checkHealth()
        let mid = try health(p,t)["request_id"] as! String
        let result = try call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"reply_to":mid,"body":"Still handling; the build is finite and running"],w)
        XCTAssertEqual((result["health_reconciliation"] as? JSON)?["outcome"] as? String,"resumed")
        XCTAssertEqual(try health(p,t)["state"] as? String,"current")
    }
    func testWorkHealthPauseResumeAndBackwardClockRebaseWithoutDuplicatePing() throws {
        let p = try project(), t = try ready(p), w = try native(p,"health-pause",domain:"health-pause"), a = try claim(p,t,caller:w)
        try ageHealthAttempt(a); try checkHealth()
        let mid = try health(p,t)["request_id"] as! String
        let paused = try call("project_settings_save",["project_id":p["id"]!,"expected_revision":p["revision"]!,"work_health_settings":["enabled":false,"inactivity_minutes":15,"response_grace_minutes":15]])
        try checkHealth(at:Date().addingTimeInterval(86400)); XCTAssertEqual(try health(p,t)["state"] as? String,"paused")
        _ = try call("project_settings_save",["project_id":p["id"]!,"expected_revision":paused["revision"]!,"work_health_settings":["enabled":true,"inactivity_minutes":15,"response_grace_minutes":15]])
        try checkHealth(); XCTAssertEqual(try health(p,t)["state"] as? String,"awaiting_response")
        try checkHealth(at:Date().addingTimeInterval(-100)); XCTAssertEqual(try health(p,t)["state"] as? String,"awaiting_response")
        XCTAssertEqual(try health(p,t)["request_id"] as? String,mid)
        XCTAssertEqual(try healthRows("message",task:t).count,1)
    }
    func testWorkHealthKnownWaitsRemainVisibleAndNeverProveProgress() throws {
        let p = try project(), t = try ready(p), w = try native(p,"health-wait",domain:"health-wait"), a = try claim(p,t,caller:w)
        var input = auth(p,a);input["progress"] = "Waiting for build";input["waiting_for_resource"] = "Build queue"
        _ = try call("work_checkpoint",input,w)
        _ = try call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"title":"Choose a fixture option","blocking":true,"questions":[["id":"q","prompt":"Which option?"]]],w)
        let waits = try health(p,t)["known_waits"] as! [JSON]
        XCTAssertTrue(waits.contains { $0["kind"] as? String == "human" })
        XCTAssertTrue(waits.contains { $0["reason"] as? String == "Build queue" })
        try checkHealth(at:Date().addingTimeInterval(1300))
        XCTAssertEqual(try health(p,t)["state"] as? String,"awaiting_response")
    }
    func testWorkHealthEndedSessionRetainsClaimAndHonestPickupFallback() throws {
        let p = try project(), t = try ready(p), w = try native(p,"health-ended",domain:"health-ended"), a = try claim(p,t,caller:w)
        let session = try router.dbQueue.read {try router.record($0,w.sessionID!,type:"session")}
        _ = try call("session_update",["project_id":p["id"]!,"session_id":w.sessionID!,"expected_revision":session["revision"]!,"state":"ended"])
        try ageHealthAttempt(a);try checkHealth()
        let state = try health(p,t)
        XCTAssertEqual(state["delivery_state"] as? String,"saved_for_pickup")
        XCTAssertEqual(state["session_state"] as? String,"ended")
        XCTAssertEqual(try healthTask(p,t)["active_attempt_id"] as? String,a["id"] as? String)
        XCTAssertTrue((state["native_wake"] as? String ?? "").contains("unavailable"))
    }
    func testWorkHealthMCPDiscoveryAndSelectedNativeProjection() throws {
        let p = try project(), t = try ready(p), w = try native(p,"health-catalog",domain:"health-catalog")
        let catalog = try call("tool_catalog",[:],w)["tools"] as! [JSON]
        XCTAssertTrue(catalog.contains { $0["name"] as? String == "work_health_get" })
        XCTAssertTrue(catalog.contains { $0["name"] as? String == "work_health_respond" })
        let ui = try call("task_context",["project_id":p["id"]!,"task_id":t["id"]!,"detail_level":"ui"])
        XCTAssertNotNil((ui["task"] as? JSON)?["work_health"] as? JSON)
    }

    func testWorkHealthTriageOrchestratorFallbackKeepsMembershipAndNotifiesOnce() throws {
        let p = try project(), t = try ready(p), sibling = try ready(p), worker = try native(p,"health-orchestrator",domain:"health-orchestrator")
        var group = try call("triage_create",["project_id":p["id"]!,"name":"Health phase","phase":"implementation"])
        for task in [t,sibling] { group = try call("group_membership",["project_id":p["id"]!,"group_id":group["id"]!,"expected_revision":group["revision"]!,"task_id":task["id"]!,"action":"add"]) }
        group = try call("triage_orchestrate",["project_id":p["id"]!,"triage_id":group["id"]!,"expected_revision":group["revision"]!,"action":"start","progress":"Coordinating this implementation phase"],worker)
        let membership = try jsonString(group["members"]!)
        try checkHealth(at:Date().addingTimeInterval(1202))
        let view = try health(p,t), mid = try XCTUnwrap(view["request_id"] as? String)
        XCTAssertEqual((view["current_target"] as? JSON)?["kind"] as? String,"orchestration")
        XCTAssertEqual((view["deliveries"] as? [JSON])?.first?["recipient_session_id"] as? String,worker.sessionID)
        XCTAssertNil(try healthTask(p,t)["active_attempt_id"])
        try checkHealth(at:Date().addingTimeInterval(2405))
        let quiet = try call("workspace_page",["project_id":p["id"]!,"surface":"needs_quiet"])["rows"] as! [JSON]
        XCTAssertTrue(quiet.contains {$0["id"] as? String == t["id"] as? String},"Unclaimed Triage members surface unanswered health attention")
        _ = try respondHealth(p,t,request:mid,caller:worker)
        let after = try router.dbQueue.read {try router.record($0,group["id"] as! String,type:"group")}
        XCTAssertEqual(try jsonString(after["members"]!),membership)
        XCTAssertEqual(after["revision"] as? Int,group["revision"] as? Int)
        XCTAssertEqual(try healthTask(p,t)["status_category"] as? String,"queued")
    }
    func testWorkHealthMaterialRevisionChangeRequiresFreshReconciliation() throws {
        let p = try project(), t = try ready(p), w = try native(p,"health-material",domain:"health-material"), a = try claim(p,t,caller:w)
        try ageHealthAttempt(a);try checkHealth()
        let mid = try health(p,t)["request_id"] as! String, current = try healthTask(p,t)
        _ = try call("task_edit",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":current["revision"]!,"patch":["acceptance":["Changed requirement"]]])
        XCTAssertEqual(try respondHealth(p,t,request:mid,caller:w)["outcome"] as? String,"fresh_claim_or_handoff_required")
        XCTAssertEqual(try healthTask(p,t)["active_attempt_id"] as? String,a["id"] as? String)
    }
    func testWorkHealthWrongRecipientAndStaleRevisionCannotAnswer() throws {
        let p = try project(), t = try ready(p), w = try native(p,"health-exact",domain:"health-exact"), other = try native(p,"health-other",domain:"health-other"), a = try claim(p,t,caller:w)
        try ageHealthAttempt(a);try checkHealth()
        let mid = try health(p,t)["request_id"] as! String
        assertCode("FORBIDDEN") { _ = try self.respondHealth(p,t,request:mid,caller:other) }
        assertCode("REVISION_CONFLICT") { _ = try self.call("work_health_respond",["project_id":p["id"]!,"task_id":t["id"]!,"request_id":mid,"expected_revision":1,"progress":"Still working"],w) }
        XCTAssertEqual(try health(p,t)["state"] as? String,"awaiting_response")
    }

    func testWorkHealthFifteenMinuteOverrideAndSevenMinuteGraceBoundaries() throws {
        let p = try project(), t = try ready(p), w = try native(p,"health-boundary",domain:"health-boundary")
        _ = try call("project_settings_save",["project_id":p["id"]!,"expected_revision":p["revision"]!,"work_health_settings":["enabled":true,"inactivity_minutes":15,"response_grace_minutes":7]])
        let attempt = try claim(p,t,caller:w)
        // Bind the synthetic claim and observation to one exact whole-second
        // clock; host load between a real claim and Date() cannot move a boundary.
        let start = Date(timeIntervalSince1970:floor(Date().timeIntervalSince1970))
        try healthWrite { db in var row=try router.record(db,attempt["id"] as! String,type:"attempt");row["started_at"]=ISO8601DateFormatter().string(from:start);try router.save(db,row,type:"attempt") }
        try checkHealth(at:start.addingTimeInterval(899));XCTAssertEqual(try health(p,t)["state"] as? String,"current")
        try checkHealth(at:start.addingTimeInterval(901));XCTAssertEqual(try health(p,t)["state"] as? String,"awaiting_response")
        try checkHealth(at:start.addingTimeInterval(1320));XCTAssertEqual(try health(p,t)["state"] as? String,"awaiting_response")
        try checkHealth(at:start.addingTimeInterval(1322));XCTAssertEqual(try health(p,t)["state"] as? String,"no_response")
    }
    func testWorkHealthLargeProjectDecodesOnlyCandidatePage() throws {
        try QualificationSuite.requireEnabled()
        let p = try project(), t = try ready(p), w = try native(p,"health-large",domain:"health-large"), a = try claim(p,t,caller:w)
        try healthWrite { db in
            for index in 0..<20000 {
                var row=t;row["id"]="health-inactive-" + String(index);row["key"]="E-" + String(index + 100);try router.save(db,row,type:"task")
            }
        }
        let start=Date(), result=try router.runWorkHealthChecks()
        print("CL-129 owned 20,001-task candidate page: \(Date().timeIntervalSince(start)) seconds; decoded \(result["scanned"]!)")
        XCTAssertEqual(result["scanned"] as? Int,1)
        XCTAssertEqual(result["inspected"] as? Int,1)
        XCTAssertEqual(try healthTask(p,t)["active_attempt_id"] as? String,a["id"] as? String)
    }

    func testWorkHealthNoResponseAndLateOutcomeNotifyWaitingCoordinatorOnce() throws {
        let p = try project(), t = try ready(p), sibling = try ready(p), handler = try native(p,"health-notice-handler",domain:"health-notice-handler"), coordinator = try native(p,"health-notice-coordinator",domain:"health-notice-coordinator")
        let attempt = try claim(p,t,caller:handler)
        var group = try call("triage_create",["project_id":p["id"]!,"name":"Waiting coordinator","phase":"implementation"])
        for task in [t,sibling] { group = try call("group_membership",["project_id":p["id"]!,"group_id":group["id"]!,"expected_revision":group["revision"]!,"task_id":task["id"]!,"action":"add"]) }
        _ = try call("triage_orchestrate",["project_id":p["id"]!,"triage_id":group["id"]!,"expected_revision":group["revision"]!,"action":"start"],coordinator)
        try ageHealthAttempt(attempt);try checkHealth()
        let mid=try health(p,t)["request_id"] as! String
        try checkHealth(at:Date().addingTimeInterval(1202))
        let note=try health(p,t)["no_response_note_id"] as! String
        let inbox=try call("session_inbox",["project_id":p["id"]!],coordinator)["deliveries"] as! [JSON]
        XCTAssertEqual(inbox.filter {$0["message_id"] as? String == note}.count,1)
        XCTAssertEqual(inbox.first {$0["message_id"] as? String == note}?["recipient_session_id"] as? String,coordinator.sessionID)
        _ = try respondHealth(p,t,request:mid,caller:handler)
        _ = try respondHealth(p,t,request:mid,caller:handler)
        let result=try router.dbQueue.read {try router.record($0,mid,type:"message")}["health_request"] as! JSON
        let outcome=result["outcome_note_id"] as! String
        let after=try call("session_inbox",["project_id":p["id"]!],coordinator)["deliveries"] as! [JSON]
        XCTAssertEqual(after.filter {$0["message_id"] as? String == outcome}.count,1)
        XCTAssertEqual(after.first {$0["message_id"] as? String == outcome}?["state"] as? String,"queued")
        let retained=try router.dbQueue.read {try router.record($0,group["id"] as! String,type:"group")}
        XCTAssertEqual((retained["members"] as? [JSON])?.count,2)
    }
    func testWorkHealthRevokedGenerationCannotResumeAndPolicyRevocationNeedsReconciliation() throws {
        let p = try project(), t = try ready(p), w = try native(p,"health-revoked",domain:"health-revoked"), a = try claim(p,t,caller:w)
        try ageHealthAttempt(a);try checkHealth()
        let mid=try health(p,t)["request_id"] as! String
        try healthWrite { db in var attempt=try router.record(db,a["id"] as! String,type:"attempt");attempt["policy_authority_revoked"]=true;try router.save(db,attempt,type:"attempt") }
        XCTAssertEqual(try respondHealth(p,t,request:mid,caller:w)["outcome"] as? String,"fresh_claim_or_handoff_required")
        let session=try router.dbQueue.read {try router.record($0,w.sessionID!,type:"session")}
        _ = try call("session_update",["project_id":p["id"]!,"session_id":w.sessionID!,"expected_revision":session["revision"]!,"state":"revoked"])
        assertCode("STALE_CLAIM") {_ = try self.respondHealth(p,t,request:mid,caller:w)}
        XCTAssertEqual(try healthTask(p,t)["active_attempt_id"] as? String,a["id"] as? String)
    }

    func testWorkHealthReviewAttemptUsesExactReviewHandlerAndPhase() throws {
        try sourceFixture()
        let p = try project(), t = try ready(p), author = try native(p,"health-review-author",domain:"health-review-author"), reviewer = try native(p,"health-reviewer",domain:"health-reviewer",provider:"claude")
        let attempt=try claim(p,t,caller:author)
        var input=auth(p,attempt);input["acceptance_revision"]=1;input["evidence_manifest"]=["kind":"source","source_capture":[:]]
        let submitted=try call("work_submit",input,author), review=try reviewClaim(p,submitted,reviewer)
        try ageHealthAttempt(review);try checkHealth()
        let state=try health(p,t)
        XCTAssertEqual((state["current_target"] as? JSON)?["phase"] as? String,"review")
        XCTAssertEqual((state["deliveries"] as? [JSON])?.first?["recipient_session_id"] as? String,reviewer.sessionID)
        XCTAssertEqual(try healthTask(p,t)["active_attempt_id"] as? String,review["id"] as? String)
    }

    func testWorkHealthReleasedWorkKeepsHistoryWithoutActiveAttention() throws {
        let p = try project(), t = try ready(p), w = try native(p,"health-release",domain:"health-release"), a = try claim(p,t,caller:w)
        try ageHealthAttempt(a);try checkHealth();try checkHealth(at:Date().addingTimeInterval(1202))
        var input=auth(p,a);input["reason"]="Explicit ordinary release after the fixture observation"
        _ = try call("work_release",input,w)
        XCTAssertEqual(try health(p,t)["state"] as? String,"inactive")
        XCTAssertEqual(try health(p,t)["attention"] as? Bool,false)
        let quiet = try call("workspace_page",["project_id":p["id"]!,"surface":"needs_quiet"])["rows"] as! [JSON]
        XCTAssertFalse(quiet.contains {$0["id"] as? String == t["id"] as? String})
        XCTAssertEqual(try healthRows("message",task:t).filter {$0["kind"] as? String == "work_health"}.count,2)
    }
}
