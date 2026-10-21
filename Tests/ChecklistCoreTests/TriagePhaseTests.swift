import XCTest
import GRDB
@testable import ChecklistCore

extension CoreTests {
    func testTriagePhasesAcceptInProgressWorkAndSeparateReviewTargets() throws {
        let p = try project(),task = try ready(p,self.task(p)),implementation = try triage(p)
        let claim = try call("work_claim",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!])
        try addTriage(p,implementation,task,"manual")
        XCTAssertEqual(strings(try currentTriage(p,implementation),"task_ids"),[task["id"] as! String])
        let submitted = try submitTriageArtifact(p,task,claim);try assertEmptyTriage(p,implementation)
        assertCode("TRIAGE_PHASE_CONFLICT") { _ = try self.addTriage(p,implementation,task) }
        let review = try triage(p,"Review the submitted phase",phase:"review");try addTriage(p,review,task)
        let queued = try ready(p,self.task(p,"Different implementation"))
        assertCode("TRIAGE_PHASE_CONFLICT") { _ = try self.addTriage(p,review,queued) }
        let current = try currentTriage(p,review)
        assertCode("TRIAGE_PHASE_CONFLICT") { _ = try self.call("triage_edit",["project_id":p["id"]!,"group_id":review["id"]!,"expected_revision":current["revision"]!,"phase":"implementation"]) }
        XCTAssertNotNil(submitted["manifest_id"])
    }
    func testReviewGroupReturningToImplementationDepartsAllReviewMemberships() throws {
        let value = try submittedArtifact(),p = value.project,first = try triage(p,"Review first",phase:"review"),other = try triage(p,"Review other",phase:"review")
        try addTriage(p,first,value.task);try addTriage(p,other,value.task)
        let result = try call("triage_transition",triageInput(p,first,["action":"reopen"]))
        XCTAssertEqual(strings(result,"changed_task_ids"),[value.task["id"] as! String]);try assertEmptyTriage(p,first);try assertEmptyTriage(p,other)
        XCTAssertEqual(try call("task_get",["project_id":p["id"]!,"task_id":value.task["id"]!])["status_category"] as? String,"queued")
    }
    func testLegacyTriagePhaseSelectionNeverSilentlyDeletesMemberships() throws {
        let p = try project(),first = try task(p),second = try task(p),group = try triage(p);try addTriage(p,group,first);try addTriage(p,group,second)
        try router.dbQueue.write { db in
            var legacy = try router.scoped(db,group["id"] as! String,p["id"] as! String,type:"group");legacy.removeValue(forKey:"phase")
            var members = legacy["members"] as! [JSON];members[0]["handling_phase"] = "implementation";members[1]["handling_phase"] = "review";legacy["members"] = members;try router.save(db,legacy,type:"group")
        }
        let unresolved = try currentTriage(p,group);XCTAssertTrue(bool(unresolved,"phase_requires_selection"));XCTAssertEqual(strings(unresolved,"task_ids").count,2)
        assertCode("TRIAGE_PHASE_REQUIRED") { _ = try self.addTriage(p,group,first) }
        let chosen = try call("triage_edit",["project_id":p["id"]!,"group_id":group["id"]!,"expected_revision":unresolved["revision"]!,"phase":"implementation"])
        XCTAssertEqual(chosen["phase"] as? String,"implementation");XCTAssertEqual(strings(chosen,"task_ids").count,2)
    }
    func testActualOrchestrationMarksMembersActiveWithoutInventingTicketClaims() throws {
        let workspace = directory.appendingPathComponent("orchestration");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let p = try call("project_create",["name":"Orchestrated","key_prefix":"O","root_path":workspace.path]),task = try ready(p,self.task(p)),group = try triage(p);try addTriage(p,group,task)
        var current = try currentTriage(p,group)
        assertCode("ACTUAL_SESSION_REQUIRED") { _ = try self.call("triage_orchestrate",["project_id":p["id"]!,"triage_id":group["id"]!,"expected_revision":current["revision"]!,"action":"start","session_id":"invented"]) }
        let sid = UUID().uuidString,domain = "fixture-real-bound-session"
        var session = try call("session_register",["project_id":p["id"]!,"session_id":sid,"installation":"orchestrator","provider":"codex","role":"worker","workspace":workspace.path,"execution_domain":domain])
        let worker = Caller(role:"worker",installation:"orchestrator",projectIDs:[p["id"] as! String],sessionID:sid,workspace:workspace.path,executionDomain:domain)
        current = try call("triage_orchestrate",["project_id":p["id"]!,"triage_id":group["id"]!,"expected_revision":current["revision"]!,"action":"start","progress":"Coordinate the selected tickets"],worker)
        XCTAssertTrue(bool(current,"active_attention"));XCTAssertEqual((current["orchestration"] as! JSON)["session_id"] as? String,sid)
        var ticket = try call("task_get",["project_id":p["id"]!,"task_id":task["id"]!]);XCTAssertTrue(bool(ticket,"active_attention"));XCTAssertNil(ticket["active_attempt_id"]);XCTAssertEqual(ticket["status_category"] as? String,"queued")
        session = try call("session_update",["project_id":p["id"]!,"session_id":sid,"expected_revision":session["revision"]!,"state":"ended"])
        current = try currentTriage(p,group);XCTAssertEqual(current["orchestration_connection"] as? String,"recovery_required");XCTAssertTrue(bool(current,"active_attention"))
        current = try call("triage_orchestrate",["project_id":p["id"]!,"triage_id":group["id"]!,"expected_revision":current["revision"]!,"action":"finish","reason":"Owner explicitly ended this recorded coordination; no ticket claim existed"])
        XCTAssertFalse(bool(current,"active_attention"));ticket = try call("task_get",["project_id":p["id"]!,"task_id":task["id"]!]);XCTAssertNil(ticket["active_attempt_id"])
    }
}
