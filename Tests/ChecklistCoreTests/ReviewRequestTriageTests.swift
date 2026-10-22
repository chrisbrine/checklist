import XCTest
import GRDB
@testable import ChecklistCore

extension CoreTests {
    private func reviewRequestTriageFixture(_ verdict: String) throws -> (project: JSON, task: JSON, groups: [JSON], request: JSON, reviewer: Caller) {
        let f = try reviewBatchInputsFixture(), p = f.project, task = f.tasks[0]
        let other = try triage(p,"Other review pass",phase:"review")
        try addTriage(p,other,task);try addTriage(p,other,f.tasks[2])
        let batch = try prepareReviewBatch(p,f.group,[task,f.tasks[2]],f.reviewer)
        let claims = try claimFixedBatch(p,batch,f.reviewer)["claims"] as! [JSON]
        let inputs: [JSON] = claims.map { claim in
            var input: JSON = ["attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"review_request_id":claim["review_request_id"]!,"target_manifest_id":claim["manifest_id"]!,"gate":"review","verdict":verdict,"reason":"Need the recorded check output"]
            if verdict == "not_run" { input["check"] = "Inspect recorded output" }
            return input
        }
        _ = try call("batch_review_record",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"members":inputs],f.reviewer)
        let claim = claims.first { $0["task_id"] as? String == task["id"] as? String }!
        let request = try router.dbQueue.read { try router.record($0,claim["review_request_id"] as! String,type:"review_request") }
        return (p,task,[f.group,other],request,f.reviewer)
    }
    private func requestAgain(_ p: JSON,_ task: JSON,_ request: JSON) throws -> JSON {
        let current = try call("task_get",["project_id":p["id"]!,"task_id":task["id"]!])
        return ["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":current["revision"]!,"target_manifest_id":request["manifest_id"]!,"gate":"review","supersedes_request_id":request["id"]!,"reason":"Continue review of the same result"]
    }
    private func reviewFixtureWrite(_ body: (Database) throws -> Void) throws {
        try router.dbQueue.writeWithoutTransaction { db in
            try router.withValidatedDomainTransaction(db) { try body(db);return .commit }
        }
    }
    private func reviewTriageState(_ group: JSON) throws -> String {
        try router.dbQueue.read { try jsonString(router.record($0,group["id"] as! String,type:"group")) }
    }
    func testReviewRequestSupplementalEvidenceRetainsReviewTriagesAndRefreshesBatchInputs() throws {
        let f = try reviewRequestTriageFixture("evidence_missing"), p = f.project
        let before = try f.groups.map { try reviewTriageState($0) }
        let log = directory.appendingPathComponent("supplemental.log");try Data("Required check passed".utf8).write(to:log)
        let artifact = try call("attachment_add",["project_id":p["id"]!,"task_id":f.task["id"]!,"path":log.path])
        var input = try requestAgain(p,f.task,f.request)
        input["supplemental_evidence_refs"] = [["artifact_id":artifact["id"]!,"sha256":artifact["sha256"]!]]
        let command = UUID().uuidString, result = try call("review_request",input,nil,command)
        XCTAssertNotEqual(result["id"] as? String,f.request["id"] as? String)
        XCTAssertEqual(result["manifest_id"] as? String,f.request["manifest_id"] as? String)
        XCTAssertEqual((result["supplemental_evidence_refs"] as? [JSON])?.first?["artifact_id"] as? String,artifact["id"] as? String)
        XCTAssertNotNil(result["answers_evidence_request"])
        XCTAssertEqual(int(result["triage_effect"] as! JSON,"removed_count"),0)
        XCTAssertEqual(try f.groups.map { try reviewTriageState($0) },before)
        for group in f.groups {
            let read = try call("review_batch_inputs",["project_id":p["id"]!,"triage_id":group["id"]!],f.reviewer)
            let row = (read["tasks"] as! [JSON]).first { $0["task_id"] as? String == f.task["id"] as? String }
            XCTAssertEqual(row?["review_request_id"] as? String,result["id"] as? String)
            XCTAssertEqual(row?["target_manifest_id"] as? String,f.request["manifest_id"] as? String)
            _ = try call("batch_prepare",["project_id":p["id"]!,"triage_id":group["id"]!,"expected_revision":read["triage_revision"]!,"phase":"review","tasks":read["tasks"]!],f.reviewer)
        }
        let replay = try call("review_request",input,nil,command)
        XCTAssertEqual(try jsonString(result),try jsonString(replay))
        // A fresh command returning the now-queued request also preserves membership.
        let queued = try call("review_request",requestAgain(p,f.task,result))
        XCTAssertEqual(queued["id"] as? String,result["id"] as? String)
        XCTAssertEqual(try f.groups.map { try reviewTriageState($0) },before)
        let history = try call("history_list",["project_id":p["id"]!,"task_id":f.task["id"]!])
        let groupIDs = Set(f.groups.compactMap { $0["id"] as? String })
        XCTAssertFalse((history["events"] as! [JSON]).contains { $0["kind"] as? String == "task_left_triage" && groupIDs.contains(($0["data"] as? JSON)?["triage_id"] as? String ?? "") })
    }
    func testReviewRequestSameTargetRoundAndNotRunPickupRetainReviewTriages() throws {
        for verdict in ["evidence_missing","not_run"] {
            let f = try reviewRequestTriageFixture(verdict), p = f.project
            let reviewStatus = try call("status_create",["project_id":p["id"]!,"name":"Review waiting for checks","category":"review"])
            try reviewFixtureWrite { db in
                var task = try router.record(db,f.task["id"] as! String,type:"task")
                task["status_id"] = reviewStatus["id"];try router.save(db,router.revised(task),type:"task")
            }
            let before = try f.groups.map { try reviewTriageState($0) }
            let result = try call("review_request",requestAgain(p,f.task,f.request))
            let task = try call("task_get",["project_id":p["id"]!,"task_id":f.task["id"]!])
            XCTAssertEqual(task["status_id"] as? String,reviewStatus["id"] as? String)
            if verdict == "evidence_missing" { XCTAssertNotEqual(result["id"] as? String,f.request["id"] as? String) }
            else { XCTAssertEqual(result["id"] as? String,f.request["id"] as? String) }
            XCTAssertEqual(try f.groups.map { try reviewTriageState($0) },before)
            for group in f.groups {
                let read = try call("review_batch_inputs",["project_id":p["id"]!,"triage_id":group["id"]!],f.reviewer)
                XCTAssertEqual((read["tasks"] as! [JSON]).first { $0["task_id"] as? String == f.task["id"] as? String }?["review_request_id"] as? String,result["id"] as? String)
            }
        }
    }
    func testReviewRequestNewTargetStillDepartsReviewTriages() throws {
        let f = try reviewRequestTriageFixture("evidence_missing"), p = f.project, mid = UUID().uuidString
        // Model a replacement current target with no request yet. Keep the old memberships
        // in this owned fixture so this command's departure is tested independently of work_submit.
        try reviewFixtureWrite { db in
            var manifest = try router.record(db,f.request["manifest_id"] as! String,type:"manifest")
            manifest["id"] = mid;try router.save(db,manifest,type:"manifest")
            var task = try router.record(db,f.task["id"] as! String,type:"task")
            task["current_manifest_id"] = mid;try router.save(db,router.revised(task),type:"task")
        }
        var input = try requestAgain(p,f.task,f.request);input["target_manifest_id"] = mid
        input.removeValue(forKey:"supersedes_request_id")
        let result = try call("review_request",input)
        XCTAssertEqual(result["manifest_id"] as? String,mid)
        XCTAssertEqual(int(result["triage_effect"] as! JSON,"removed_count"),2)
        for group in f.groups { XCTAssertFalse(strings(try currentTriage(p,group),"task_ids").contains(f.task["id"] as! String)) }
        let history = try call("history_list",["project_id":p["id"]!,"task_id":f.task["id"]!])
        let groupIDs = Set(f.groups.compactMap { $0["id"] as? String })
        XCTAssertEqual((history["events"] as! [JSON]).filter { $0["kind"] as? String == "task_left_triage" && groupIDs.contains(($0["data"] as? JSON)?["triage_id"] as? String ?? "") }.count,2)
    }
    func testReviewRequestPhaseChangeStillDepartsTriagesForExistingTarget() throws {
        let f = try reviewRequestTriageFixture("evidence_missing"), p = f.project
        // A retained target outside Review must not opt out of status departures.
        try reviewFixtureWrite { db in
            var task = try router.record(db,f.task["id"] as! String,type:"task")
            task["status_id"] = try router.status(db,p["id"] as! String,"queued")["id"]
            try router.save(db,router.revised(task),type:"task")
        }
        let result = try call("review_request",requestAgain(p,f.task,f.request))
        XCTAssertEqual(int(result["triage_effect"] as! JSON,"removed_count"),2)
        for group in f.groups { XCTAssertFalse(strings(try currentTriage(p,group),"task_ids").contains(f.task["id"] as! String)) }
        let task = try call("task_get",["project_id":p["id"]!,"task_id":f.task["id"]!])
        XCTAssertEqual(task["status_category"] as? String,"review")
    }

}
