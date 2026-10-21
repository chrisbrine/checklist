import XCTest
@testable import ChecklistCore

extension CoreTests {
    func reviewBatchInputsFixture() throws -> (project: JSON,group: JSON,tasks: [JSON],reviewer: Caller) {
        let p = try project(),tasks = try [ready(p,task(p,"Open request")),ready(p,task(p,"No open request")),ready(p,task(p,"Revision changes"))],implementation = try triage(p)
        for task in tasks {try addTriage(p,implementation,task)}
        let batch = try prepareImplementationBatch(p,implementation,tasks),claims = try claimFixedBatch(p,batch)["claims"] as! [JSON]
        _ = try call("batch_submit",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"members":try claims.map {try batchArtifactInput(p,$0)}])
        // A completed/superseded request leaves no open review request for this member.
        try router.dbQueue.write { db in
            var request = try router.records(db,type:"review_request",project:p["id"] as? String).first {$0["task_id"] as? String == tasks[1]["id"] as? String}!
            request["state"] = "superseded";try router.save(db,request,type:"review_request")
        }
        let group = try triage(p,"Read review inputs",phase:"review");for task in tasks {try addTriage(p,group,task)}
        return (p,group,tasks,Caller(role:"owner",installation:"review-input-reader",projectIDs:[]))
    }
    func testReviewBatchInputsPassUnchangedToPrepareAndRejectStaleTaskRevision() throws {
        let f = try reviewBatchInputsFixture(),p = f.project,group = f.group
        let read = try call("review_batch_inputs",["project_id":p["id"]!,"triage_id":group["id"]!],f.reviewer),tasks = read["tasks"] as! [JSON],unavailable = read["not_ready"] as! [JSON]
        XCTAssertEqual(read["phase"] as? String,"review");XCTAssertEqual(read["triage_key"] as? String,group["key"] as? String);XCTAssertEqual(read["triage_name"] as? String,"Read review inputs")
        XCTAssertEqual(Set(tasks.compactMap {$0["task_id"] as? String}),Set([f.tasks[0]["id"] as! String,f.tasks[2]["id"] as! String]))
        XCTAssertEqual(unavailable.count,1);XCTAssertEqual(unavailable[0]["task_id"] as? String,f.tasks[1]["id"] as? String);XCTAssertEqual(unavailable[0]["reason"] as? String,"no open review request")
        for row in tasks {
            XCTAssertEqual(Set(row.keys),["task_id","key","expected_revision","review_request_id","target_manifest_id","gate","contributor_session_ids"])
            XCTAssertTrue(strings(row,"contributor_session_ids").contains("human"))
            let task = try call("task_get",["project_id":p["id"]!,"task_id":row["task_id"]!]);XCTAssertEqual(int(row,"expected_revision"),int(task,"revision"));XCTAssertEqual(row["key"] as? String,task["key"] as? String)
        }
        let input: JSON = ["project_id":p["id"]!,"triage_id":group["id"]!,"expected_revision":read["triage_revision"]!,"phase":"review","tasks":tasks]
        let batch = try call("batch_prepare",input,f.reviewer)
        for member in batch["members"] as! [JSON] {XCTAssertTrue((member["file_scopes"] as! [JSON]).isEmpty);XCTAssertTrue((member["lane_scopes"] as! [JSON]).isEmpty)}
        let changing = tasks.first {$0["task_id"] as? String == f.tasks[2]["id"] as? String}!
        _ = try call("task_edit",["project_id":p["id"]!,"task_id":changing["task_id"]!,"expected_revision":changing["expected_revision"]!,"patch":["title":"Changed after read"]])
        let before = try call("snapshot")
        assertCode("REVISION_CONFLICT") { _ = try self.call("batch_prepare",input,f.reviewer) }
        let after = try call("snapshot");for key in ["batches","tasks","attempts","events","groups"] {XCTAssertEqual(try jsonString(before[key]!),try jsonString(after[key]!))}
    }
    func testReviewBatchInputsRejectImplementationAndValidateDisplayKeyWithoutTrustingContributors() throws {
        let f = try reviewBatchInputsFixture(),p = f.project,implementation = try triage(p)
        assertCode("TRIAGE_PHASE_CONFLICT") { _ = try self.call("review_batch_inputs",["project_id":p["id"]!,"triage_id":implementation["id"]!]) }
        let read = try call("review_batch_inputs",["project_id":p["id"]!,"triage_id":f.group["id"]!],f.reviewer)
        var rows = read["tasks"] as! [JSON];rows[0]["key"] = "WRONG-KEY"
        var input: JSON = ["project_id":p["id"]!,"triage_id":f.group["id"]!,"expected_revision":read["triage_revision"]!,"phase":"review","tasks":rows]
        assertCode("INVALID_INPUT") { _ = try self.call("batch_prepare",input,f.reviewer) }
        rows = read["tasks"] as! [JSON];for index in rows.indices {rows[index]["contributor_session_ids"] = []};input["tasks"] = rows
        assertCode("REVIEW_INDEPENDENCE") { _ = try self.call("batch_prepare",input) }
    }
    func testReviewBatchInputsExplainClaimedStaleAndAdditionalRequestsAndAllowReaders() throws {
        let f = try reviewBatchInputsFixture(),p = f.project
        let initial = try call("review_batch_inputs",["project_id":p["id"]!,"triage_id":f.group["id"]!],f.reviewer),rows = initial["tasks"] as! [JSON],first = rows.first {$0["task_id"] as? String == f.tasks[0]["id"] as? String}!
        try router.dbQueue.write { db in
            var extra = try router.record(db,first["review_request_id"] as! String,type:"review_request");extra["id"] = UUID().uuidString;extra["created_at"] = "9999-01-01T00:00:00Z";try router.save(db,extra,type:"review_request")
        }
        let multiple = try call("review_batch_inputs",["project_id":p["id"]!,"triage_id":f.group["id"]!],f.reviewer)
        XCTAssertEqual((multiple["tasks"] as! [JSON]).first {$0["task_id"] as? String == first["task_id"] as? String}?["review_request_id"] as? String,first["review_request_id"] as? String)
        XCTAssertTrue((multiple["not_ready"] as! [JSON]).contains {($0["reason"] as? String ?? "").contains("chose oldest ready request")})
        var claim = first.filter {!["key","contributor_session_ids"].contains($0.key)};claim["project_id"] = p["id"];claim["phase"] = "review";_ = try call("work_claim",claim,f.reviewer)
        try addTriage(p,f.group,f.tasks[0])
        let stale = try call("task_get",["project_id":p["id"]!,"task_id":f.tasks[2]["id"]!])
        _ = try call("task_edit",["project_id":p["id"]!,"task_id":stale["id"]!,"expected_revision":stale["revision"]!,"patch":["brief":"Requirements changed after submission"]])
        let sid = "review-input-reader";_ = try call("session_register",["project_id":p["id"]!,"session_id":sid,"role":"assistant","provider":"codex","assistant_grants":[p["id"] as! String:["read":true]]])
        let reader = Caller(role:"assistant",installation:"reader",projectIDs:[p["id"] as! String],sessionID:sid,assistantGrants:[p["id"] as! String:["read":true]])
        let result = try call("review_batch_inputs",["project_id":p["id"]!,"triage_id":f.group["id"]!],reader)
        XCTAssertTrue((result["tasks"] as! [JSON]).isEmpty)
        let reasons = (result["not_ready"] as! [JSON]).compactMap {$0["reason"] as? String}
        XCTAssertTrue(reasons.contains("review already claimed"));XCTAssertTrue(reasons.contains {$0.hasPrefix("target stale:")})
        let catalog = try call("tool_catalog",[:],reader)["tools"] as! [JSON]
        XCTAssertTrue(catalog.contains {$0["name"] as? String == "review_batch_inputs"});XCTAssertFalse(catalog.contains {$0["name"] as? String == "batch_release"})
    }
}
