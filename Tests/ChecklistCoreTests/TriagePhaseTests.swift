import XCTest
import GRDB
@testable import ChecklistCore

extension CoreTests {
    func testTriagesHaveNoPhaseAndAcceptAnyTicket() throws {
        let p = try project(),task = try ready(p,self.task(p)),implementation = try triage(p),tid = task["id"] as! String
        let claim = try call("work_claim",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!])
        try addTriage(p,implementation,task,"manual")
        XCTAssertEqual(strings(try currentTriage(p,implementation),"task_ids"),[tid])
        // CL-125 rule 10: submission keeps the ticket and records its return Triage.
        let submitted = try submitTriageArtifact(p,task,claim);XCTAssertEqual(strings(try currentTriage(p,implementation),"task_ids"),[tid])
        // Rule 9: a Triage has no phase, so Review and Queued tickets share one; an explicit add moves the ticket (rule 4).
        let review = try triage(p,"Review the submitted phase",phase:"review");try addTriage(p,review,task)
        let queued = try ready(p,self.task(p,"Different implementation"));try addTriage(p,review,queued)
        XCTAssertEqual(Set(strings(try currentTriage(p,review),"task_ids")),[tid,queued["id"] as! String])
        XCTAssertFalse(bool(try currentTriage(p,review),"phase_requires_selection"))
        // Rule 11: the emptied plan archives with its history kept.
        XCTAssertTrue(bool(try storedTriage(implementation),"archived"))
        XCTAssertNotNil(submitted["manifest_id"])
    }
    func testReviewGroupReopenKeepsTheTicketInItsTriage() throws {
        let value = try submittedArtifact(),p = value.project,first = try triage(p,"Review first",phase:"review")
        try addTriage(p,first,value.task)
        let result = try call("triage_transition",triageInput(p,first,["action":"reopen"]))
        // CL-125 rule 8: returning to Queued is a status action and keeps membership.
        XCTAssertEqual(strings(result,"changed_task_ids"),[value.task["id"] as! String]);XCTAssertEqual(strings(try currentTriage(p,first),"task_ids"),[value.task["id"] as! String])
        XCTAssertEqual(try call("task_get",["project_id":p["id"]!,"task_id":value.task["id"]!])["status_category"] as? String,"queued")
    }
    func testLegacyTriagePhaseSelectionNeverSilentlyDeletesMemberships() throws {
        let p = try project(),first = try task(p),second = try task(p),group = try triage(p);try addTriage(p,group,first);try addTriage(p,group,second)
        // TaskReferenceValidation.swift: validate the complete synthetic legacy group at commit.
        try fixtureDomainTransaction { db in
            var legacy = try router.scoped(db,group["id"] as! String,p["id"] as! String,type:"group");legacy.removeValue(forKey:"phase")
            var members = legacy["members"] as! [JSON];members[0]["handling_phase"] = "implementation";members[1]["handling_phase"] = "review";legacy["members"] = members;try router.save(db,legacy,type:"group")
        }
        let unresolved = try currentTriage(p,group);XCTAssertFalse(bool(unresolved,"phase_requires_selection"));XCTAssertEqual(strings(unresolved,"task_ids").count,2)
        // CL-125 rule 9: a Triage has no phase, so a legacy member phase never blocks an add or a group action.
        let third = try task(p);try addTriage(p,group,third)
        XCTAssertEqual(strings(try currentTriage(p,group),"task_ids").count,3)
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
