import ChecklistTestSupport
import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

extension EvidenceAuthorityTests {
    private func reviewHealthState() throws -> [[String]] {
        try router.dbQueue.read { db in
            [try String.fetchAll(db, sql: "SELECT json_array(id,project_id,type,revision,data) FROM records ORDER BY id"),
             try String.fetchAll(db, sql: "SELECT json_array(seq,id,project_id,entity_id,actor,kind,occurred_at,data) FROM events ORDER BY seq"),
             try String.fetchAll(db, sql: "SELECT json_array(principal,command_id,digest,result) FROM commands ORDER BY principal,command_id")]
        }
    }

    private func storedRecordReturnFixture() throws -> (JSON, JSON, JSON, JSON, Caller, Caller) {
        try sourceFixture()
        let p = try project(), author = try native(p,"stored-return-author",domain:"stored-return-author")
        let reviewer = try native(p,"stored-return-reviewer",domain:"stored-return-reviewer",provider:"claude")
        let task = try ready(p), attempt = try claim(p,task,files:[["path":"tracked.txt","access":"write"]],caller:author)
        var input = auth(p,attempt)
        input["acceptance_revision"] = 1; input["evidence_manifest"] = ["kind":"source","source_capture":[:]]
        let submitted = try call("work_submit",input,author)
        return (p,task,attempt,try reviewClaim(p,submitted,reviewer),author,reviewer)
    }

    func testReviewReturnRejectsCorruptReservationAndRollsBackVerdict() throws {
        let (p,t,_,review,author,reviewer) = try storedRecordReturnFixture()
        let other = try claim(p,ready(p),files:[["path":"other","access":"write"]],caller:author)
        try router.dbQueue.write { db in
            var attempt = try router.record(db,other["id"] as! String,type:"attempt")
            // Canonical identity remains valid; the reservation's mandatory path is corrupt.
            // Only the automatic implementation claim consumes that reservation field.
            attempt["file_scopes"] = [["path":NSNull(),"access":"write"]]
            try router.save(db,attempt,type:"attempt")
        }
        let before = try reviewHealthState()
        var input = reviewInput(p,review,verdict:"evidence_missing")
        input["reason"] = "The implementing holder must supply the missing observation."
        assertCode("CANONICAL_RECORD_INVALID") { _ = try self.call("review_record",input,reviewer) }
        XCTAssertEqual(try reviewHealthState(),before,"The verdict, queue transition, claim, events and notices must roll back together")
        let task = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!])
        XCTAssertEqual(task["status_category"] as? String,"review")
        XCTAssertEqual(task["active_attempt_id"] as? String,review["id"] as? String)
    }

    func testReviewReturnStillQueuesForExpectedReservationConflict() throws {
        let (p,t,_,review,author,reviewer) = try storedRecordReturnFixture()
        _ = try claim(p,ready(p),files:[["path":"tracked.txt","access":"write"]],caller:author)
        var input = reviewInput(p,review,verdict:"evidence_missing")
        input["reason"] = "The implementing holder must supply the missing observation."
        let result = try call("review_record",input,reviewer)
        let returned = try XCTUnwrap(result["implementation_return"] as? JSON)
        XCTAssertEqual(returned["state"] as? String,"queued")
        XCTAssertEqual(returned["code"] as? String,"SCOPE_CONFLICT")
        let task = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!])
        XCTAssertEqual(task["status_category"] as? String,"queued")
        XCTAssertNil(task["active_attempt_id"])
    }

    private func storedRecordHealthFixture() throws -> (JSON, JSON, JSON, Caller, String) {
        let p = try project(), t = try ready(p), worker = try native(p,"stored-health",domain:"stored-health")
        let attempt = try claim(p,t,caller:worker)
        _ = try router.runWorkHealthChecks()
        _ = try router.runWorkHealthChecks(at:Date().addingTimeInterval(1202))
        let health = try call("work_health_get",["project_id":p["id"]!,"task_id":t["id"]!])
        return (p,t,attempt,worker,try XCTUnwrap(health["request_id"] as? String))
    }

    private func storedRecordHealthReply(_ p: JSON, _ t: JSON, _ worker: Caller, _ mid: String) throws -> JSON {
        let current = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!])
        return try call("work_health_respond",["project_id":p["id"]!,"task_id":t["id"]!,"request_id":mid,
            "expected_revision":current["revision"]!,"progress":"Still handling this bounded task."],worker)
    }

    func testWorkHealthReplyRejectsCorruptAttemptTaskIDAndRollsBack() throws {
        let (p,t,a,worker,mid) = try storedRecordHealthFixture()
        try router.dbQueue.write { db in
            var attempt = try router.record(db,a["id"] as! String,type:"attempt")
            // Target identity is unchanged, so reconciliation reaches policy authority.
            attempt["task_id"] = NSNull()
            try router.save(db,attempt,type:"attempt")
        }
        let before = try reviewHealthState()
        assertCode("CANONICAL_RECORD_INVALID") { _ = try self.storedRecordHealthReply(p,t,worker,mid) }
        XCTAssertEqual(try reviewHealthState(),before,"The reply, health outcome, task and deliveries must remain unchanged")
    }

    func testWorkHealthReplyStillRetainsExpectedAuthorityChange() throws {
        let (p,t,a,worker,mid) = try storedRecordHealthFixture()
        try router.dbQueue.write { db in
            var attempt = try router.record(db,a["id"] as! String,type:"attempt")
            attempt["policy_authority_revoked"] = true
            try router.save(db,attempt,type:"attempt")
        }
        let result = try storedRecordHealthReply(p,t,worker,mid)
        XCTAssertEqual(result["outcome"] as? String,"fresh_claim_or_handoff_required")
        let request = try router.dbQueue.read { try router.record($0,mid,type:"message")["health_request"] as? JSON }
        XCTAssertEqual(request?["outcome"] as? String,"fresh_claim_or_handoff_required")
        XCTAssertNotNil(request?["response_id"])
    }
}

extension HumanGateDirectionTests {
    func testHumanGateRejectsCorruptCompletionInputAndRollsBackVerdict() throws {
        let value = try fixture(), observed = try context(value)
        let params = try approval(value,context:observed)
        try router.dbQueue.write { db in
            // An unrelated retained request is first consumed by the completion
            // scan, after the exact approval target and direction checks passed.
            let id = uuid()
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES(?,?,'request',1,?)",
                arguments:[id,value.project["id"] as! String,try jsonString(["id":NSNull(),"project_id":value.project["id"]!,"revision":1])])
        }
        func snapshot() throws -> [[String]] {
            try router.dbQueue.read { db in
                [try String.fetchAll(db,sql:"SELECT json_array(id,project_id,type,revision,data) FROM records ORDER BY id"),
                 try String.fetchAll(db,sql:"SELECT json_array(seq,id,project_id,entity_id,actor,kind,occurred_at,data) FROM events ORDER BY seq"),
                 try String.fetchAll(db,sql:"SELECT json_array(principal,command_id,digest,result) FROM commands ORDER BY principal,command_id")]
            }
        }
        let before = try snapshot()
        assertCode("CANONICAL_RECORD_INVALID") {
            try router.dbQueue.writeWithoutTransaction { db in
                try router.withValidatedDomainTransaction(db) {
                    _ = try router.recordHumanGate(db,request:value.request,
                        answers:[["question_id":"approve","result":"approved"]],responseID:uuid(),params:params,caller:owner)
                    return .commit
                }
            }
        }
        XCTAssertEqual(try snapshot(),before,"A corrupt completion scan must roll back the passing verdict, gate and task writes")
    }
}

extension EvidenceAuthorityTests {
    private func storedRecordReviewAssessment(_ project: JSON, _ review: JSON, _ reviewer: Caller) throws -> JSON {
        let task = try router.dbQueue.read { try router.record($0,review["task_id"] as! String,type:"task") }
        let manifest = try router.dbQueue.read { try router.record($0,review["manifest_id"] as! String,type:"manifest") }
        // Native worker imports must remain inside that worker's enrolled workspace.
        let path = workspace.appendingPathComponent("stored-record-review-"+uuid()+".md")
        try Data("Synthetic reviewer inspected this exact source target.".utf8).write(to:path)
        let artifact = try call("attachment_add",["project_id":project["id"]!,"task_id":task["id"]!,"path":path.path],reviewer)
        return try fixtureReviewAssessment(router,task:task,manifest:manifest,artifact:artifact)
    }

    func testAgentPassingReviewRejectsCorruptCompletionInputAndRollsBackVerdict() throws {
        let (p,_,_,review,_,reviewer) = try storedRecordReturnFixture()
        var input = reviewInput(p,review,verdict:"pass")
        input["review_assessment"] = try storedRecordReviewAssessment(p,review,reviewer)
        try router.dbQueue.write { db in
            let id = uuid()
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES(?,?,'request',1,?)",
                arguments:[id,p["id"] as! String,try jsonString(["id":NSNull(),"project_id":p["id"]!,"revision":1])])
        }
        let before = try reviewHealthState()
        assertCode("CANONICAL_RECORD_INVALID") { _ = try self.call("review_record",input,reviewer) }
        XCTAssertEqual(try reviewHealthState(),before,"Corrupt completion input must roll back the verdict, ended claim and gate changes")
    }

    func testAgentPassingReviewStillWaitsForExpectedIncompleteGate() throws {
        let (p,t,_,review,_,reviewer) = try storedRecordReturnFixture()
        var input = reviewInput(p,review,verdict:"pass")
        input["review_assessment"] = try storedRecordReviewAssessment(p,review,reviewer)
        try router.dbQueue.write { db in
            var manifest = try router.record(db,review["manifest_id"] as! String,type:"manifest")
            manifest["required_gates"] = ["review","human_approval"]
            try router.save(db,manifest,type:"manifest")
        }
        let result = try call("review_record",input,reviewer)
        let completion = try XCTUnwrap(result["completion"] as? JSON)
        XCTAssertEqual(completion["completed"] as? Bool,false)
        XCTAssertEqual(completion["waiting_for"] as? String,"DEPENDENCY_UNSATISFIED")
        let task = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!])
        XCTAssertEqual(task["status_category"] as? String,"review")
        XCTAssertNil(task["active_attempt_id"])
    }
}

extension HumanGateDirectionTests {
    func testHumanGateStillRetainsPassForExpectedIncompleteGate() throws {
        let value = try fixture()
        try router.dbQueue.write { db in
            var manifest = try router.record(db,value.request["target_manifest_id"] as! String,type:"manifest")
            manifest["required_gates"] = ["human_approval","review"]
            try router.save(db,manifest,type:"manifest")
        }
        let params = try approval(value,context:context(value))
        var review: JSON?
        try router.dbQueue.writeWithoutTransaction { db in
            try router.withValidatedDomainTransaction(db) {
                review = try router.recordHumanGate(db,request:value.request,
                    answers:[["question_id":"approve","result":"approved"]],responseID:uuid(),params:params,caller:owner)
                return .commit
            }
        }
        XCTAssertEqual(review?["verdict"] as? String,"pass")
        let task = try call("task_get",["project_id":value.project["id"]!,"task_id":value.task["id"]!])
        XCTAssertEqual(task["status_category"] as? String,"review")
        XCTAssertNil(task["active_verification_request_id"])
        let gate = try router.dbQueue.read { try router.record($0,value.request["review_request_id"] as! String,type:"review_request") }
        XCTAssertEqual(gate["state"] as? String,"pass")
    }
}
