import XCTest
@testable import ChecklistCore

// Owner decision, 19 October 2026 (CL-137): any eligible AI claims an unclaimed ticket,
// every verdict ends the review claim, a final pass marks Done, and a takeover needs no
// permission but tells the earlier holder why.
extension EvidenceAuthorityTests {
    private func task(_ p: JSON, _ t: JSON) throws -> JSON { try call("task_get", ["project_id": p["id"]!, "task_id": t["id"]!]) }
    private func handlers(_ t: JSON) throws -> [String] {
        try router.dbQueue.read { db in try router.relevantHandlerRecipients(db, task: router.record(db, t["id"] as! String, type: "task")).compactMap { $0["session_id"] as? String } }
    }
    private func submit(_ p: JSON, _ a: JSON, _ caller: Caller) throws -> JSON {
        var input = auth(p, a); input["acceptance_revision"] = 1; input["evidence_manifest"] = ["kind": "source", "source_capture": [:]]
        return try call("work_submit", input, caller)
    }
    private func takeover(_ p: JSON, _ t: JSON, _ caller: Caller, reason: String = "The earlier holder stopped responding") throws -> JSON {
        try call("work_takeover", ["project_id": p["id"]!, "task_id": t["id"]!, "expected_revision": try task(p, t)["revision"]!, "reason": reason], caller)
    }

    func testAnyEligibleAgentClaimsAnAgentAssignedTicketButNotTheOwners() throws {
        let p = try project(), assigned = try native(p, "assigned", domain: "claude:301:1:0", provider: "claude")
        let other = try native(p, "other", domain: "codex:302:1:0")
        let t = try ready(p)
        let preferred = try call("task_edit", ["project_id": p["id"]!, "task_id": t["id"]!, "expected_revision": t["revision"]!,
            "patch": ["planned_assignee": ["kind": "agent", "session_id": assigned.sessionID!], "assignment_reason": "Preferred for this area"]])
        let claimed = try claim(p, preferred, caller: other)
        XCTAssertEqual(try task(p, t)["active_attempt_id"] as? String, claimed["id"] as? String)
        XCTAssertEqual(try task(p, t)["status_category"] as? String, "active")
        let owners = try ready(p)
        let human = try call("task_edit", ["project_id": p["id"]!, "task_id": owners["id"]!, "expected_revision": owners["revision"]!, "patch": ["planned_assignee": "human"]])
        assertCode("POLICY_DENIED") { _ = try self.claim(p, human, caller: other) }
    }

    func testSubmitAndRejectLeaveNoReviewerAndRejectReturnsToQueue() throws {
        try sourceFixture()
        let p = try project(), author = try native(p, "author", domain: "codex:311:1:0"), reviewer = try native(p, "reviewer", domain: "claude:312:1:0", provider: "claude")
        let t = try ready(p), submitted = try submit(p, try claim(p, t, caller: author), author)
        XCTAssertEqual(try task(p, t)["status_category"] as? String, "review"); XCTAssertNil(try task(p, t)["active_attempt_id"]); XCTAssertEqual(try handlers(t), [])
        let review = try reviewClaim(p, submitted, reviewer)
        XCTAssertEqual(try handlers(t), [reviewer.sessionID!])
        let manifest = try router.dbQueue.read { try router.record($0, submitted["manifest_id"] as! String, type: "manifest") }
        let source = (manifest["evidence"] as! JSON)["source_capture"] as! JSON
        var reject = reviewInput(p, review, verdict: "reject")
        reject["findings"] = [["client_ref": "gap", "description": "Expected result absent", "severity": "normal", "evidence_refs": [["source_capture_id": source["id"]!, "sha256": source["sha256"]!]]]]
        _ = try call("review_record", reject, reviewer)
        let rejected = try task(p, t)
        XCTAssertEqual(rejected["status_category"] as? String, "queued"); XCTAssertNil(rejected["active_attempt_id"]); XCTAssertNil(rejected["current_manifest_id"])
        XCTAssertEqual(try handlers(t), [])
        var stale = auth(p, review); stale["progress"] = "after verdict"
        assertCode("STALE_CLAIM") { _ = try self.call("work_checkpoint", stale, reviewer) }
        // Any eligible AI picks the rework up again.
        _ = try claim(p, rejected, caller: reviewer)
        XCTAssertEqual(try task(p, t)["status_category"] as? String, "active")
    }

    func testBlockedVerdictReturnsTheReviewToAnyEligibleReviewer() throws {
        try sourceFixture()
        let p = try project(), author = try native(p, "blocked-author", domain: "codex:321:1:0")
        let first = try native(p, "blocked-reviewer", domain: "claude:322:1:0", provider: "claude"), second = try native(p, "next-reviewer", domain: "claude:323:1:0", provider: "claude")
        let t = try ready(p), submitted = try submit(p, try claim(p, t, caller: author), author)
        let review = try reviewClaim(p, submitted, first)
        _ = try call("review_record", reviewInput(p, review, verdict: "blocked"), first)
        let waiting = try task(p, t)
        XCTAssertEqual(waiting["status_category"] as? String, "review"); XCTAssertNil(waiting["active_attempt_id"]); XCTAssertEqual(try handlers(t), [])
        let request = try router.dbQueue.read { try router.record($0, (submitted["review_request_ids"] as! [String])[0], type: "review_request") }
        XCTAssertEqual(request["state"] as? String, "queued"); XCTAssertEqual((request["blocked_verdict_ids"] as? [String])?.count, 1)
        XCTAssertEqual(try call("task_context", ["project_id": p["id"]!, "task_id": t["id"]!])["next_action"] as? String, "claim_pending_review")
        var stale = auth(p, review); stale["progress"] = "after blocked"
        assertCode("STALE_CLAIM") { _ = try self.call("work_checkpoint", stale, first) }
        // Any eligible reviewer picks up the same request again.
        let again = try reviewClaim(p, ["task": waiting, "review_request_ids": submitted["review_request_ids"]!, "manifest_id": submitted["manifest_id"]!], second)
        XCTAssertEqual(again["review_request_id"] as? String, review["review_request_id"] as? String)
        XCTAssertEqual(try handlers(t), [second.sessionID!])
    }

    func testFinalPassMarksDoneAndAnOpenPrerequisiteKeepsReview() throws {
        try sourceFixture()
        let p = try project(), reviewer = Caller(role: "owner", installation: "pass-reviewer", projectIDs: [])
        let submitted = try submitSource(p, try claim(p, ready(p))), review = try reviewClaim(p, submitted, reviewer)
        var pass = reviewInput(p, review, verdict: "pass"); pass["review_assessment"] = try ownReviewAssessment(p, review, reviewer)
        let verdict = try call("review_record", pass, reviewer)
        XCTAssertEqual((verdict["completion"] as? JSON)?["completed"] as? Bool, true)
        let done = try call("task_get", ["project_id": p["id"]!, "task_id": (submitted["task"] as! JSON)["id"]!])
        XCTAssertEqual(done["status_category"] as? String, "done"); XCTAssertNil(done["active_attempt_id"])

        // A prerequisite added during the review keeps the passed ticket in Review.
        let second = try submitSource(p, try claim(p, ready(p))), secondTask = second["task"] as! JSON
        let waiting = try reviewClaim(p, second, reviewer)
        let open = try ready(p), current = try task(p, secondTask)
        _ = try call("task_link", ["project_id": p["id"]!, "task_id": secondTask["id"]!, "expected_revision": current["revision"]!, "target_task_id": open["id"]!, "relation": "depends_on", "required": true])
        var secondPass = reviewInput(p, waiting, verdict: "pass"); secondPass["review_assessment"] = try ownReviewAssessment(p, waiting, reviewer)
        let held = try call("review_record", secondPass, reviewer)
        XCTAssertEqual((held["completion"] as? JSON)?["completed"] as? Bool, false)
        XCTAssertEqual((held["completion"] as? JSON)?["waiting_for"] as? String, "DEPENDENCY_UNSATISFIED")
        let stillReview = try task(p, secondTask)
        XCTAssertEqual(stillReview["status_category"] as? String, "review"); XCTAssertNil(stillReview["active_attempt_id"])
    }

    func testTakeoverEndsTheOldClaimTellsTheHolderAndKeepsContributors() throws {
        try sourceFixture()
        let p = try project(), holder = try native(p, "holder", domain: "claude:401:1:0", provider: "claude"), taker = try native(p, "taker", domain: "codex:402:1:0")
        let catalog = try call("tool_catalog", [:], taker)["tools"] as! [JSON]
        let tool = try XCTUnwrap(catalog.first { $0["name"] as? String == "work_takeover" })
        XCTAssertTrue(strings(tool["inputSchema"] as! JSON, "required").contains("command_id"))
        XCTAssertTrue((tool["description"] as? String ?? "").contains("without its permission"))
        let t = try ready(p)
        assertCode("INVALID_TRANSITION") { _ = try self.takeover(p, t, taker) }
        let a = try claim(p, t, files: [["path": "Sources", "access": "write"]], caller: holder)
        var progress = auth(p, a); progress["progress"] = "Half of the change is in place"
        _ = try call("work_checkpoint", progress, holder)
        assertCode("INVALID_INPUT") { _ = try self.takeover(p, t, holder) }
        assertCode("INVALID_INPUT") { _ = try self.takeover(p, t, taker, reason: "") }
        let taken = try takeover(p, t, taker)
        XCTAssertNotNil(taken["claim_token"]); XCTAssertEqual(taken["takeover_from_attempt_id"] as? String, a["id"] as? String)
        XCTAssertEqual(taken["takeover_context"] as? String, "Half of the change is in place")
        XCTAssertEqual(try jsonString(taken["file_scopes"] ?? []), try jsonString(a["file_scopes"] ?? []))
        XCTAssertEqual(try task(p, t)["active_attempt_id"] as? String, taken["id"] as? String)
        XCTAssertEqual(try task(p, t)["status_category"] as? String, "active")
        var stale = auth(p, a); stale["progress"] = "still working"
        assertCode("STALE_CLAIM") { _ = try self.call("work_checkpoint", stale, holder) }
        let deliveries = ((taken["takeover_notices"] as? [JSON])?.first?["deliveries"] as? [JSON]) ?? []
        XCTAssertEqual(deliveries.compactMap { $0["recipient_session_id"] as? String }, [holder.sessionID!])
        let inbox = try call("session_inbox", ["project_id": p["id"]!], holder)["deliveries"] as! [JSON]
        XCTAssertTrue(inbox.contains { $0["id"] as? String == deliveries.first?["id"] as? String })
        let takeoverBody = ((inbox.first { $0["id"] as? String == deliveries.first?["id"] as? String })?["message"] as? JSON)?["body"] as? String ?? ""
        XCTAssertTrue(takeoverBody.contains(AgentReference.text(t)))
        // The earlier holder stays a contributor and cannot review the result.
        let submitted = try submit(p, taken, taker)
        assertCode("REVIEW_INDEPENDENCE") { _ = try self.reviewClaim(p, submitted, holder) }
    }

    func testReviewTakeoverKeepsIndependenceAndOwnersTicketStaysWithTheOwner() throws {
        try sourceFixture()
        let p = try project(), author = try native(p, "review-author", domain: "codex:411:1:0")
        let first = try native(p, "first-reviewer", domain: "claude:412:1:0", provider: "claude"), second = try native(p, "second-reviewer", domain: "claude:413:1:0", provider: "claude")
        let t = try ready(p), submitted = try submit(p, try claim(p, t, caller: author), author)
        let review = try reviewClaim(p, submitted, first)
        assertCode("REVIEW_INDEPENDENCE") { _ = try self.takeover(p, t, author) }
        let taken = try takeover(p, t, second, reason: "The first reviewer is busy elsewhere")
        XCTAssertEqual(taken["phase"] as? String, "review"); XCTAssertEqual(taken["review_request_id"] as? String, review["review_request_id"] as? String)
        XCTAssertEqual(try task(p, t)["status_category"] as? String, "review")
        assertCode("STALE_CLAIM") { _ = try self.call("review_record", self.reviewInput(p, review, verdict: "reject"), first) }

        let owners = try ready(p)
        let human = try call("task_edit", ["project_id": p["id"]!, "task_id": owners["id"]!, "expected_revision": owners["revision"]!, "patch": ["planned_assignee": "human"]])
        _ = try claim(p, human)
        assertCode("POLICY_DENIED") { _ = try self.takeover(p, owners, second) }
    }
}
