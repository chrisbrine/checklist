import XCTest
@testable import ChecklistCore

extension EvidenceAuthorityTests {
    private func returnedTask(_ p: JSON,_ t: JSON) throws -> JSON { try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!]) }
    private func returnFixture() throws -> (JSON,JSON,JSON,JSON,Caller,Caller) {
        let f = try preparedPhase("review-return") { fixture in
            try fixture.sourceFixture()
            let p = try fixture.project(),author = try fixture.native(p,"return-author",domain:"codex:return-author"),reviewer = try fixture.native(p,"return-reviewer",domain:"claude:return-reviewer",provider:"claude")
            let task = try fixture.ready(p),attempt = try fixture.claim(p,task,files:[["path":"tracked.txt","access":"write"]],caller:author)
            var input = fixture.auth(p,attempt);input["acceptance_revision"] = 1;input["evidence_manifest"] = ["kind":"source","source_capture":[:]]
            let submitted = try fixture.call("work_submit",input,author),review = try fixture.reviewClaim(p,submitted,reviewer)
            return ["project":p,"task":task,"attempt":attempt,"review":review,"author":author.sessionID!,"reviewer":reviewer.sessionID!]
        }
        return (f["project"] as! JSON,f["task"] as! JSON,f["attempt"] as! JSON,f["review"] as! JSON,try phaseCaller(f["author"]!),try phaseCaller(f["reviewer"]!))
    }
    private func returnInput(_ p: JSON,_ review: JSON,_ kind: String) -> JSON {
        var input = reviewInput(p,review,verdict:kind == "implementation_blocked" ? "blocked" : kind)
        input["reason"] = "The implementing session must supply the recorded device check."
        if kind == "not_run" { input["check"] = "device check" }
        if kind == "implementation_blocked" { input["blocked_on"] = "implementation" }
        return input
    }
    func testReviewGapsReturnToExactImplementerWithFreshClaimTargetAndHistory() throws {
        for kind in ["evidence_missing","not_run","implementation_blocked"] {
            let (p,t,old,review,author,reviewer) = try returnFixture()
            var input = returnInput(p,review,kind)
            if kind == "implementation_blocked" {
                let manifest = try router.dbQueue.read {try router.record($0,review["manifest_id"] as! String,type:"manifest")}
                let source = (manifest["evidence"] as! JSON)["source_capture"] as! JSON
                input["findings"] = [["client_ref":"missing-input","description":"Supply the recorded device input","evidence_refs":[["source_capture_id":source["id"]!,"sha256":source["sha256"]!]]]]
            }
            let command = UUID().uuidString,result = try call("review_record",input,reviewer,command:command)
            XCTAssertEqual(try jsonString(result),try jsonString(call("review_record",input,reviewer,command:command)))
            let active = try returnedTask(p,t),routing = result["implementation_return"] as! JSON
            XCTAssertEqual(active["status_category"] as? String,"active",kind);XCTAssertNil(active["current_manifest_id"])
            XCTAssertEqual(routing["state"] as? String,"active");XCTAssertEqual(routing["session_id"] as? String,author.sessionID)
            XCTAssertNil(result["claim_token"]);XCTAssertFalse(try jsonString(result).contains("claim_token"))
            let request = try router.dbQueue.read {try router.record($0,review["review_request_id"] as! String,type:"review_request")}
            XCTAssertEqual(request["state"] as? String,"returned");XCTAssertEqual(request["latest_verdict_id"] as? String,result["id"] as? String)
            assertCode("STALE_CLAIM") { var checkpoint = self.auth(p,review);checkpoint["progress"] = "after verdict";_ = try self.call("work_checkpoint",checkpoint,reviewer) }
            assertCode("STALE_CLAIM") { var checkpoint = self.auth(p,old);checkpoint["progress"] = "old implementation";_ = try self.call("work_checkpoint",checkpoint,author) }
            assertCode("CLAIM_CONFLICT") {_ = try self.claim(p,active,caller:reviewer)}
            let pickup = try claim(p,active,caller:author)
            XCTAssertNotEqual(pickup["id"] as? String,old["id"] as? String)
            XCTAssertEqual((pickup["file_scopes"] as! [JSON]).count,1);XCTAssertNil(pickup["batch_id"])
            var checkpoint = auth(p,pickup);checkpoint["progress"] = "Collecting missing check";_ = try call("work_checkpoint",checkpoint,author)
            assertCode("REVIEW_ALREADY_ACTIVE") { _ = try self.call("review_request",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":active["revision"]!,"target_manifest_id":review["manifest_id"]!,"gate":"review"],author) }
            var submit = auth(p,pickup);submit["acceptance_revision"] = 1;submit["evidence_manifest"] = ["kind":"source","source_capture":[:]]
            let next = try call("work_submit",submit,author)
            XCTAssertNotEqual(next["manifest_id"] as? String,review["manifest_id"] as? String)
            XCTAssertFalse((next["review_request_ids"] as! [String]).contains(review["review_request_id"] as! String))
            let context = try call("task_context",["project_id":p["id"]!,"task_id":t["id"]!,"detail_level":"full"])
            let rounds = (context["review_summary"] as! JSON)["rounds"] as! [JSON]
            XCTAssertEqual(rounds.first?["failed_rounds"] as? Int,0)
            let history = try call("history_list",["project_id":p["id"]!,"task_id":t["id"]!])
            let events = history["events"] as! [JSON]
            XCTAssertTrue(events.contains {$0["kind"] as? String == "review_returned_to_implementation" && ($0["data"] as? JSON)?["review_id"] as? String == result["id"] as? String})
            let stored = try router.dbQueue.read {try router.record($0,result["id"] as! String,type:"review")}
            XCTAssertEqual(stored["reason"] as? String,input["reason"] as? String)
            if kind == "not_run" {XCTAssertEqual(stored["check"] as? String,"device check")}
            if kind == "implementation_blocked" {XCTAssertEqual((stored["findings"] as? [JSON])?.count,1)}
            let deliveries = try call("message_delivery_list",["project_id":p["id"]!,"task_id":t["id"]!,"message_id":routing["message_id"]!])
            XCTAssertTrue(try jsonString(deliveries).contains(author.sessionID!))
        }
    }
    func testBatchReviewGapsReturnNativeHoldersAndLeaveReviewTriage() throws {
        try sourceFixture()
        let p = try project(),author = try native(p,"batch-return-author",domain:"codex:batch-return"),reviewer = try native(p,"batch-return-reviewer",domain:"claude:batch-return",provider:"claude")
        var submitted: [JSON] = []
        for path in ["tracked.txt","untracked.txt","scripts"] {
            let task = try ready(p),attempt = try claim(p,task,files:[["path":path,"access":"write"]],caller:author)
            var input = auth(p,attempt);input["acceptance_revision"] = 1;input["evidence_manifest"] = ["kind":"source","source_capture":[:]]
            submitted.append(try call("work_submit",input,author))
        }
        let group = try call("triage_create",["project_id":p["id"]!,"name":"Review return cohort","phase":"review"])
        for (index,value) in submitted.enumerated() {
            _ = try call("group_membership",["project_id":p["id"]!,"group_id":group["id"]!,"expected_revision":index+1,"task_id":(value["task"] as! JSON)["id"]!,"action":"add"])
        }
        let read = try call("review_batch_inputs",["project_id":p["id"]!,"triage_id":group["id"]!],reviewer)
        let batch = try call("batch_prepare",["project_id":p["id"]!,"triage_id":group["id"]!,"expected_revision":read["triage_revision"]!,"phase":"review","tasks":read["tasks"]!],reviewer)
        let claims = try call("batch_claim",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":batch["revision"]!,"policy_revision":batch["policy_revision"]!],reviewer)["claims"] as! [JSON]
        let inputs = zip(claims,["evidence_missing","not_run","implementation_blocked"]).map { claim,kind in returnInput(p,claim,kind) }
        let result = try call("batch_review_record",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":batch["revision"]!,"members":inputs],reviewer)
        XCTAssertEqual((result["results"] as? [JSON])?.count,3)
        let groups = try call("triage_list",["project_id":p["id"]!,"triage_id":group["id"]!])["groups"] as! [JSON]
        XCTAssertTrue(strings(groups[0],"task_ids").isEmpty)
        for row in result["results"] as! [JSON] {
            let task = try returnedTask(p,row["task"] as! JSON)
            XCTAssertEqual(task["status_category"] as? String,"active")
            XCTAssertEqual((row["implementation_return"] as? JSON)?["session_id"] as? String,author.sessionID)
            let history = try call("history_list",["project_id":p["id"]!,"task_id":task["id"]!])["events"] as! [JSON]
            XCTAssertEqual(history.filter {$0["kind"] as? String == "task_left_triage" && ($0["data"] as? JSON)?["triage_id"] as? String == group["id"] as? String}.count,1)
        }
    }
    func testReviewReturnFallsBackToQueueWhenHolderGenerationOrReservationsChanged() throws {
        for cause in ["ended","generation","scope","missing"] {
            let (p,t,old,review,author,reviewer) = try returnFixture()
            if cause == "scope" {
                _ = try claim(p,ready(p),files:[["path":"tracked.txt","access":"write"]],caller:author)
            } else if cause == "ended" || cause == "generation" {
                let session = try router.dbQueue.read {try router.record($0,author.sessionID!,type:"session")}
                _ = try call(cause == "ended" ? "session_update" : "session_register",["project_id":p["id"]!,"session_id":author.sessionID!,"expected_revision":session["revision"]!,"state":cause == "ended" ? "ended" : "connected","label":"Reauthorized holder"])
            } else {
                try router.dbQueue.write { db in
                    var manifest = try router.record(db,review["manifest_id"] as! String,type:"manifest")
                    manifest["attempt_id"] = UUID().uuidString;try router.save(db,manifest,type:"manifest")
                }
            }
            let result = try call("review_record",returnInput(p,review,"evidence_missing"),reviewer),task = try returnedTask(p,t)
            XCTAssertEqual(task["status_category"] as? String,"queued",cause);XCTAssertNil(task["active_attempt_id"])
            XCTAssertNotNil((result["implementation_return"] as? JSON)?["code"],cause)
            let prior = try router.dbQueue.read {try router.record($0,old["id"] as! String,type:"attempt")}
            XCTAssertEqual(prior["state"] as? String,"submitted");XCTAssertNil(prior["token_hash"])
        }
    }
    func testBlockedSideValidationAndReviewerDefaultKeepReviewPickup() throws {
        let (p,t,_,review,_,reviewer) = try returnFixture()
        var input = returnInput(p,review,"implementation_blocked");input.removeValue(forKey:"reason")
        assertCode("INVALID_INPUT") {_ = try self.call("review_record",input,reviewer)}
        input["blocked_on"] = "unknown"
        assertCode("INVALID_INPUT") {_ = try self.call("review_record",input,reviewer)}
        input = returnInput(p,review,"not_run");input["blocked_on"] = "implementation"
        assertCode("INVALID_INPUT") {_ = try self.call("review_record",input,reviewer)}
        input = reviewInput(p,review,verdict:"blocked");input["blocked_on"] = "reviewer";input["reason"] = "Reviewer device is unavailable"
        let result = try call("review_record",input,reviewer)
        XCTAssertNil(result["implementation_return"]);XCTAssertEqual(try returnedTask(p,t)["status_category"] as? String,"review")
        let request = try router.dbQueue.read {try router.record($0,review["review_request_id"] as! String,type:"review_request")}
        XCTAssertEqual(request["state"] as? String,"queued")
    }
}
