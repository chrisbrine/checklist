import XCTest
@testable import ChecklistCore

extension CoreTests {
    func testStructuredPrerequisitesPreserveMinimalDraftCapture() throws {
        let p = try project(),t = try call("task_create",["project_id":p["id"]!,"title":"A title is enough to capture"])
        XCTAssertEqual(t["readiness"] as? String,"draft")
        XCTAssertTrue((t["prerequisites"] as! [JSON]).isEmpty)
        XCTAssertEqual(strings(t,"prerequisite_ids"),[])
        XCTAssertTrue(bool(t,"queue_eligible"));XCTAssertFalse(bool(t,"pickup_eligible"))
        assertCode("NOT_READY") { _ = try self.ready(p,t) }
        let populated = try call("task_edit",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"patch":["brief":"Record the requested outcome","acceptance":["The result is observable"],"readiness":"ready"]])
        XCTAssertTrue(bool(populated,"pickup_eligible"))
    }

    func testStructuredPrerequisiteArraysIncludeSatisfiedOptionalAndBlockingLinks() throws {
        var p = try project();p = try call("policy_apply",["project_id":p["id"]!,"expected_revision":p["revision"]!,"policy":["required_gates":[]]])
        let done = try completeRelationFixture(p,task(p,"Finished prerequisite")),pending = try task(p,"Pending prerequisite"),optional = try task(p,"Optional context"),related = try task(p,"Related context")
        let source = try ready(p,task(p,"Dependent"))
        try link(p,source,done);try link(p,source,pending);try link(p,source,optional,required:false);try link(p,source,related,"related_to")
        let current = try currentRelationTask(p,source),prerequisites = current["prerequisites"] as! [JSON]
        XCTAssertEqual(prerequisites.count,3)
        XCTAssertEqual(Set(strings(current,"prerequisite_ids")),Set([done["id"] as! String,pending["id"] as! String,optional["id"] as! String]))
        XCTAssertEqual(Set(strings(current,"required_prerequisite_ids")),Set([done["id"] as! String,pending["id"] as! String]))
        XCTAssertTrue(bool(prerequisites.first {$0["task_id"] as? String == done["id"] as? String}!,"satisfied"))
        XCTAssertFalse(bool(prerequisites.first {$0["task_id"] as? String == optional["id"] as? String}!,"required"))
        XCTAssertEqual((current["prerequisite_blockers"] as! [JSON]).count,1)
        let context = try call("task_context",["project_id":p["id"]!,"task_id":source["id"]!])
        XCTAssertEqual(try jsonString((context["task"] as! JSON)["prerequisites"]!),try jsonString(prerequisites))
        XCTAssertEqual(try jsonString((((context["relation_context"] as! JSON)["eligibility"] as! JSON)["prerequisites"]!)),try jsonString(prerequisites))
    }

    func testQueueWorksWithOpenPrerequisitesWhilePickupWaitsAndTracksReopen() throws {
        var p = try project();p = try call("policy_apply",["project_id":p["id"]!,"expected_revision":p["revision"]!,"policy":["required_gates":[]]])
        let prerequisite = try task(p),source = try ready(p,task(p,"Waiting ticket"))
        let parked = try call("task_transition",["project_id":p["id"]!,"task_id":source["id"]!,"expected_revision":source["revision"]!,"action":"defer"])
        try link(p,parked,prerequisite)
        let blocked = try currentRelationTask(p,source)
        // Triage planning queues work by prerequisite order (CL-133); only pickup waits for the prerequisite.
        XCTAssertTrue(bool(blocked,"queue_eligible"));XCTAssertFalse(bool(blocked,"pickup_eligible"))
        let queued = try call("task_transition",["project_id":p["id"]!,"task_id":source["id"]!,"expected_revision":blocked["revision"]!,"action":"queue"])
        XCTAssertFalse(bool(queued,"pickup_eligible"))
        let done = try completeRelationFixture(p,prerequisite)
        let unblocked = try currentRelationTask(p,source);XCTAssertTrue(bool(unblocked,"pickup_eligible"))
        // docs/operations.md: reopen creates a new round with a reason; earlier evidence remains.
        _ = try call("task_transition",["project_id":p["id"]!,"task_id":done["id"]!,"expected_revision":done["revision"]!,"action":"reopen","reason":"Recheck pickup when the prerequisite needs another round"])
        let reopened = try currentRelationTask(p,source)
        XCTAssertTrue(bool(reopened,"queue_eligible"));XCTAssertFalse(bool(reopened,"pickup_eligible"))
        XCTAssertEqual(reopened["status_id"] as? String,queued["status_id"] as? String)
        XCTAssertEqual(reopened["revision"] as? Int,unblocked["revision"] as? Int)
    }

    func testPlannedTriageHoldsWaitingTicketsWhileBatchClaimRefusesOpenPrerequisites() throws {
        var p = try project();p = try call("policy_apply",["project_id":p["id"]!,"expected_revision":p["revision"]!,"policy":["required_gates":[]]])
        let prerequisite = try task(p,"Prerequisite"),waiting = try task(p,"Waiting ticket"),free = try task(p,"Free ticket"),draft = try task(p,"Draft ticket")
        try link(p,waiting,prerequisite);try link(p,draft,prerequisite)
        let readyWaiting = try ready(p,currentRelationTask(p,waiting)),readyFree = try ready(p,currentRelationTask(p,free))
        XCTAssertEqual(readyWaiting["effective_readiness"] as? String,"blocked");XCTAssertEqual(readyWaiting["status_category"] as? String,"queued")
        // A planned Implementation Triage holds Ready and Draft tickets that still wait (CL-133).
        let group = try triage(p,"Planned pass")
        try addTriage(p,group,readyWaiting);try addTriage(p,group,readyFree);try addTriage(p,group,currentRelationTask(p,draft))
        let members = Set([waiting["id"] as! String,free["id"] as! String,draft["id"] as! String])
        XCTAssertEqual(Set(strings(try currentTriage(p,group),"task_ids")),members)
        var single: CoreError?,prepared: CoreError?
        XCTAssertThrowsError(try call("work_claim",["project_id":p["id"]!,"task_id":waiting["id"]!,"expected_revision":readyWaiting["revision"]!])) { single = $0 as? CoreError }
        XCTAssertEqual(single?.code,"DEPENDENCY_UNSATISFIED")
        // batch_prepare applies the same claim checks to every member and fails the whole call.
        XCTAssertThrowsError(try prepareImplementationBatch(p,group,[readyWaiting,readyFree])) { prepared = $0 as? CoreError }
        XCTAssertEqual(prepared?.code,"DEPENDENCY_UNSATISFIED");XCTAssertEqual(prepared?.message,single?.message)
        XCTAssertNil(try currentRelationTask(p,free)["active_attempt_id"])
        // A prerequisite that reopens after batch_prepare makes batch_claim refuse with no claims.
        let done = try completeRelationFixture(p,prerequisite)
        let batch = try prepareImplementationBatch(p,group,[try currentRelationTask(p,waiting),try currentRelationTask(p,free)])
        // docs/operations.md: reopen creates a new round with a reason; earlier evidence remains.
        _ = try call("task_transition",["project_id":p["id"]!,"task_id":done["id"]!,"expected_revision":done["revision"]!,"action":"reopen","reason":"Recheck pickup when the prerequisite needs another round"])
        assertCode("DEPENDENCY_UNSATISFIED") { _ = try self.claimFixedBatch(p,batch) }
        XCTAssertNil(try currentRelationTask(p,waiting)["active_attempt_id"]);XCTAssertNil(try currentRelationTask(p,free)["active_attempt_id"])
        XCTAssertFalse(bool(try currentRelationTask(p,waiting),"pickup_eligible"))
        // Refused batch commands change no membership.
        XCTAssertEqual(Set(strings(try currentTriage(p,group),"task_ids")),members)
    }

    func testStructuredUnresolvedPrerequisitesDoNotInventTicketIDs() throws {
        let p = try project(),source = try task(p),currentProject = try call("project_settings_get",["project_id":p["id"]!])
        let edgeID = UUID().uuidString
        _ = try call("relation_import",["project_id":p["id"]!,"expected_revision":currentProject["revision"]!,"relations":[["id":edgeID,"source_task_id":source["id"]!,"target_task_id":"legacy-missing","relation":"depends_on"]]])
        let current = try currentRelationTask(p,source),entry = (current["prerequisites"] as! [JSON])[0]
        XCTAssertEqual(entry["relation_id"] as? String,edgeID);XCTAssertFalse(bool(entry,"resolved"));XCTAssertFalse(bool(entry,"satisfied"))
        XCTAssertEqual(entry["legacy_reference"] as? String,"legacy-missing");XCTAssertNil(entry["task_id"])
        XCTAssertTrue(strings(current,"prerequisite_ids").isEmpty);XCTAssertTrue(bool(current,"queue_eligible"));XCTAssertFalse(bool(current,"pickup_eligible"))
    }

    func testStructuredQueueEligibilityExcludesArchivedTicketsAndPreservesProse() throws {
        let p = try project(),original = try task(p,"Preserve the source note"),prerequisite = try task(p)
        _ = try call("message_send",["project_id":p["id"]!,"task_id":original["id"]!,"body":"Rationale: wait for the exact prerequisite; related tickets remain context."])
        try link(p,original,prerequisite,"related_to")
        let beforeArchive = try currentRelationTask(p,original)
        XCTAssertEqual(beforeArchive["brief"] as? String,original["brief"] as? String)
        XCTAssertTrue((beforeArchive["prerequisites"] as! [JSON]).isEmpty)
        let archived = try call("task_archive",["project_id":p["id"]!,"task_id":original["id"]!,"expected_revision":beforeArchive["revision"]!])
        XCTAssertFalse(bool(archived,"queue_eligible"))
        assertCode("INVALID_TRANSITION") { _ = try self.call("task_transition",["project_id":p["id"]!,"task_id":original["id"]!,"expected_revision":archived["revision"]!,"action":"queue"]) }
        let context = try call("task_context",["project_id":p["id"]!,"task_id":original["id"]!])
        XCTAssertEqual((context["messages"] as! [JSON]).count,1)
    }
}
