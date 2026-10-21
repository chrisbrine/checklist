import XCTest
@testable import ChecklistCore

/// Triage 3fd2303d: review outcomes and attempt records (CL-41 to CL-47).
extension EvidenceAuthorityTests {
    private func current(_ p: JSON, _ t: JSON) throws -> JSON { try call("task_get", ["project_id": p["id"]!, "task_id": t["id"]!]) }
    private func record(_ id: Any?, _ type: String) throws -> JSON { try router.dbQueue.read { try router.record($0, id as! String, type: type) } }
    private func sourceRef(_ submitted: JSON) throws -> JSON {
        let source = (try record(submitted["manifest_id"], "manifest")["evidence"] as! JSON)["source_capture"] as! JSON
        return ["source_capture_id": source["id"]!, "sha256": source["sha256"]!]
    }
    private func submit(_ p: JSON, _ t: JSON, _ author: Caller, report: String? = nil) throws -> JSON {
        let attempt = try claim(p, try current(p, t), caller: author)
        var input = auth(p, attempt); input["acceptance_revision"] = 1; input["evidence_manifest"] = ["kind": "source", "source_capture": [:]]
        if let report { input["final_report"] = report }
        return try call("work_submit", input, author)
    }
    /// A non-owner reviewer's own report must be inside its workspace; private/ is outside the source inventory.
    private func agentAssessment(_ p: JSON, _ review: JSON, _ reviewer: Caller) throws -> JSON {
        let task = try record(review["task_id"], "task"), manifest = try record(review["manifest_id"], "manifest")
        let file = workspace.appendingPathComponent("private/review-report-" + UUID().uuidString + ".md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Synthetic reviewer report for this exact target.".utf8).write(to: file)
        let artifact = try call("attachment_add", ["project_id": p["id"]!, "task_id": task["id"]!, "path": file.path], reviewer)
        return try fixtureReviewAssessment(router, task: task, manifest: manifest, artifact: artifact)
    }
    private func finding(_ ref: String, _ evidence: JSON, severity: String? = nil, sameCause: String? = nil) -> JSON {
        var value: JSON = ["client_ref": ref, "description": "Expected result absent (" + ref + ")", "evidence_refs": [evidence]]
        if let severity { value["severity"] = severity }
        if let sameCause { value["same_cause_as"] = sameCause }
        return value
    }

    // CL-41
    func testEvidenceMissingReturnsTheSameTargetForMoreEvidence() throws {
        try sourceFixture()
        let p = try project(), author = try native(p, "em-author", domain: "codex:4101:1:0")
        let first = try native(p, "em-reviewer", domain: "claude:4102:1:0", provider: "claude"), second = Caller(role: "owner", installation: "em-second", projectIDs: [])
        let t = try ready(p), submitted = try submit(p, t, author), review = try reviewClaim(p, submitted, first)
        var missing = reviewInput(p, review, verdict: "evidence_missing")
        assertCode("INVALID_INPUT") { _ = try self.call("review_record", missing, first) }
        missing["reason"] = "The build log for the release configuration is not attached."
        var withFinding = missing; withFinding["findings"] = [finding("gap", try sourceRef(submitted))]
        assertCode("INVALID_INPUT") { _ = try self.call("review_record", withFinding, first) }
        let verdict = try call("review_record", missing, first)
        XCTAssertEqual(verdict["verdict"] as? String, "evidence_missing"); XCTAssertEqual((verdict["completion"] as? JSON)?["completed"] as? Bool, false)
        let request = try record(review["review_request_id"], "review_request")
        XCTAssertEqual(request["state"] as? String, "evidence_requested")
        let waiting = try current(p, t)
        XCTAssertEqual(waiting["status_category"] as? String, "review"); XCTAssertEqual(waiting["current_manifest_id"] as? String, submitted["manifest_id"] as? String)
        XCTAssertNil(waiting["active_attempt_id"])
        XCTAssertEqual(try call("task_context", ["project_id": p["id"]!, "task_id": t["id"]!])["next_action"] as? String, "supply_review_evidence")
        assertCode("DEPENDENCY_UNSATISFIED") { _ = try self.call("task_complete", ["project_id": p["id"]!, "task_id": t["id"]!, "expected_revision": waiting["revision"]!]) }

        // The implementer adds evidence and returns the same target to review; no new implementation claim.
        let log = workspace.appendingPathComponent("private/release-build.log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("release build passed".utf8).write(to: log)
        let artifact = try call("attachment_add", ["project_id": p["id"]!, "task_id": t["id"]!, "path": log.path], author)
        var again: JSON = ["project_id": p["id"]!, "task_id": t["id"]!, "expected_revision": waiting["revision"]!, "target_manifest_id": submitted["manifest_id"]!, "gate": "review", "supersedes_request_id": review["review_request_id"]!, "reason": "Release build log added"]
        again["supplemental_evidence_refs"] = [["artifact_id": artifact["id"]!, "sha256": "0000"]]
        assertCode("EVIDENCE_STALE") { _ = try self.call("review_request", again, author) }
        again["supplemental_evidence_refs"] = [["artifact_id": artifact["id"]!, "sha256": artifact["sha256"]!]]
        let requested = try call("review_request", again, author)
        XCTAssertEqual(requested["manifest_id"] as? String, submitted["manifest_id"] as? String); XCTAssertEqual(requested["state"] as? String, "queued")
        XCTAssertEqual((requested["supplemental_evidence_refs"] as? [JSON])?.first?["artifact_id"] as? String, artifact["id"] as? String)
        XCTAssertNotNil(requested["answers_evidence_request"] as? JSON)
        XCTAssertEqual(try current(p, t)["current_manifest_id"] as? String, submitted["manifest_id"] as? String, "no new implementation round")

        // A queued request takes no supplemental evidence; the next reviewer passes the same target.
        var plain = again; plain["supersedes_request_id"] = requested["id"]!; plain["expected_revision"] = try current(p, t)["revision"]!
        assertCode("INVALID_INPUT") { _ = try self.call("review_request", plain, author) }
        let next = try reviewClaim(p, ["task": try current(p, t), "review_request_ids": [requested["id"]!], "manifest_id": submitted["manifest_id"]!], second)
        // Finding 39e5ef8d: the next reviewer selects and cites the supplemental evidence; it keeps its author.
        let supplemental: JSON = ["artifact_id": artifact["id"]!, "sha256": artifact["sha256"]!]
        XCTAssertNoThrow(try call("review_context", ["project_id": p["id"]!, "task_id": t["id"]!, "review_request_id": requested["id"]!, "target_manifest_id": submitted["manifest_id"]!, "gate": "review", "evidence_refs": [supplemental]], second))
        let unrelated = workspace.appendingPathComponent("private/unrelated.log"); try Data("not requested".utf8).write(to: unrelated)
        let other = try call("attachment_add", ["project_id": p["id"]!, "task_id": t["id"]!, "path": unrelated.path], author)
        assertCode("EVIDENCE_STALE") { _ = try self.call("review_context", ["project_id": p["id"]!, "task_id": t["id"]!, "review_request_id": requested["id"]!, "target_manifest_id": submitted["manifest_id"]!, "gate": "review", "evidence_refs": [["artifact_id": other["id"]!, "sha256": other["sha256"]!]]], second) }
        var pass = reviewInput(p, next, verdict: "pass"); var assessment = try ownReviewAssessment(p, next, second)
        assessment["evidence_refs"] = (assessment["evidence_refs"] as! [JSON]) + [supplemental]; pass["review_assessment"] = assessment
        let passed = try call("review_record", pass, second)
        XCTAssertEqual((passed["completion"] as? JSON)?["completed"] as? Bool, true)
        let cited = ((passed["review_assessment"] as? JSON)?["evidence_refs"] as? [JSON] ?? []).first { $0["artifact_id"] as? String == artifact["id"] as? String }
        XCTAssertEqual(cited?["role"] as? String, "supplemental_evidence")
        let rounds = (try call("task_context", ["project_id": p["id"]!, "task_id": t["id"]!])["review_summary"] as! JSON)["rounds"] as! [JSON]
        XCTAssertEqual(rounds.first?["evidence_missing"] as? Int, 1); XCTAssertEqual(rounds.first?["failed_rounds"] as? Int, 0)
    }

    func testNotRunKeepsTheReviewOpenAndIsNotAFail() throws {
        try sourceFixture()
        let p = try project(), author = try native(p, "nr-author", domain: "codex:4111:1:0"), reviewer = try native(p, "nr-reviewer", domain: "claude:4112:1:0", provider: "claude")
        let t = try ready(p), submitted = try submit(p, t, author), review = try reviewClaim(p, submitted, reviewer)
        var notRun = reviewInput(p, review, verdict: "not_run"); notRun["reason"] = "The device lab was offline."
        assertCode("INVALID_INPUT") { _ = try self.call("review_record", notRun, reviewer) }
        notRun["check"] = "iPhone playtest"
        _ = try call("review_record", notRun, reviewer)
        let request = try record(review["review_request_id"], "review_request")
        XCTAssertEqual(request["state"] as? String, "queued")
        XCTAssertEqual((request["not_run_checks"] as? [JSON])?.first?["check"] as? String, "iPhone playtest")
        let ticket = try current(p, t)
        XCTAssertEqual(ticket["status_category"] as? String, "review"); XCTAssertNil(ticket["completed_at"])
        let context = try call("task_context", ["project_id": p["id"]!, "task_id": t["id"]!])
        XCTAssertEqual(context["next_action"] as? String, "claim_pending_review")
        let rounds = (context["review_summary"] as! JSON)["rounds"] as! [JSON]
        XCTAssertEqual(rounds.first?["failed_rounds"] as? Int, 0, "not_run is not a fail"); XCTAssertEqual(rounds.first?["not_run"] as? Int, 1)
        var reason = reviewInput(p, try reviewClaim(p, ["task": ticket, "review_request_ids": submitted["review_request_ids"]!, "manifest_id": submitted["manifest_id"]!], reviewer), verdict: "reject")
        reason["reason"] = "not for reject"
        assertCode("INVALID_INPUT") { _ = try self.call("review_record", reason, reviewer) }
    }

    // CL-42
    func testAdviceFindingsStayVisibleAndDoNotBlockCompletion() throws {
        try sourceFixture()
        let p = try project(), author = try native(p, "adv-author", domain: "codex:4201:1:0")
        let reviewer = try native(p, "adv-reviewer", domain: "claude:4202:1:0", provider: "claude"), other = try native(p, "adv-other", domain: "claude:4203:1:0", provider: "claude")
        let t = try ready(p), submitted = try submit(p, t, author), review = try reviewClaim(p, submitted, reviewer)
        var reject = reviewInput(p, review, verdict: "reject"); reject["findings"] = [finding("polish", try sourceRef(submitted))]
        let rejected = try call("review_record", reject, reviewer)
        let created = (rejected["findings"] as! [JSON])[0]
        XCTAssertEqual(created["severity"] as? String, "blocking", "the default severity is blocking")
        var change: JSON = ["project_id": p["id"]!, "finding_id": created["id"]!, "expected_revision": created["revision"]!, "severity": "advice", "reason": "Linen gloss is polish, not a defect."]
        assertCode("FORBIDDEN") { _ = try self.call("finding_severity_set", change, other) }
        assertCode("FORBIDDEN") { _ = try self.call("finding_severity_set", change, author) }
        let advice = try call("finding_severity_set", change, reviewer)
        XCTAssertEqual(advice["severity"] as? String, "advice")
        XCTAssertEqual((advice["severity_history"] as? [JSON])?.first?["from"] as? String, "blocking")
        XCTAssertEqual((advice["severity_history"] as? [JSON])?.first?["reason"] as? String, "Linen gloss is polish, not a defect.")
        change["expected_revision"] = advice["revision"]!; change["severity"] = "blocking"; change["reason"] = "Owner keeps it blocking for now."
        let owned = try call("finding_severity_set", change)
        XCTAssertEqual((owned["severity_history"] as? [JSON])?.last?["origin"] as? String, "human_ui")
        change["expected_revision"] = owned["revision"]!; change["severity"] = "advice"; change["reason"] = "Owner agrees it is advice."
        _ = try call("finding_severity_set", change)

        // The next round passes with the advice finding still open; it stays visible.
        let second = try submit(p, t, author), next = try reviewClaim(p, second, other)
        var blocking = reviewInput(p, next, verdict: "pass"); blocking["review_assessment"] = try agentAssessment(p, next, other)
        blocking["findings"] = [finding("new-gap", try sourceRef(second))]
        assertCode("FINDINGS_UNRESOLVED") { _ = try self.call("review_record", blocking, other) }
        var pass = blocking; pass["findings"] = [finding("note", try sourceRef(second), severity: "advice")]
        let passed = try call("review_record", pass, other)
        XCTAssertEqual((passed["completion"] as? JSON)?["completed"] as? Bool, true, "open advice findings do not block completion")
        let open = try router.dbQueue.read { db in try router.records(db, type: "finding", project: p["id"] as? String) }.filter { $0["state"] as? String == "open" }
        XCTAssertEqual(open.count, 2); XCTAssertTrue(open.allSatisfy { $0["severity"] as? String == "advice" })
    }

    // CL-43
    func testRepeatedCauseWarnsTheTicketAndItsCoordinator() throws {
        try sourceFixture()
        let p = try project(), author = try native(p, "rep-author", domain: "codex:4301:1:0"), reviewer = try native(p, "rep-reviewer", domain: "claude:4302:1:0", provider: "claude")
        let t = try ready(p)
        var previous: String?
        for round in 1...3 {
            let submitted = try submit(p, t, author), review = try reviewClaim(p, submitted, reviewer)
            var reject = reviewInput(p, review, verdict: "reject"); reject["findings"] = [finding("timing-\(round)", try sourceRef(submitted), sameCause: previous)]
            previous = ((try call("review_record", reject, reviewer)["findings"] as! [JSON])[0])["id"] as? String
            let summary = try call("task_context", ["project_id": p["id"]!, "task_id": t["id"]!])["review_summary"] as! JSON
            XCTAssertEqual((summary["rounds"] as! [JSON]).first?["failed_rounds"] as? Int, round)
            XCTAssertEqual((summary["warnings"] as! [JSON]).count, round == 3 ? 1 : 0, "warn only when the cause returns for the second time")
        }
        let warning = ((try call("task_context", ["project_id": p["id"]!, "task_id": t["id"]!])["review_summary"] as! JSON)["warnings"] as! [JSON])[0]
        XCTAssertEqual(warning["occurrences"] as? Int, 3); XCTAssertEqual((warning["finding_ids"] as? [String])?.count, 3)
        let ticket = try current(p, t)
        XCTAssertEqual(ticket["status_category"] as? String, "queued", "the warning changes no status"); XCTAssertNil(ticket["active_attempt_id"])
        let triage = try call("triage_create", ["project_id": p["id"]!, "name": "Repeated cause", "purpose": "Coordinator view", "phase": "implementation"])
        _ = try call("group_membership", ["project_id": p["id"]!, "group_id": triage["id"]!, "expected_revision": triage["revision"]!, "task_id": t["id"]!, "action": "add"])
        let group = (try call("triage_list", ["project_id": p["id"]!])["groups"] as! [JSON]).first { $0["id"] as? String == triage["id"] as? String }!
        XCTAssertEqual((group["member_warnings"] as? [JSON])?.first?["cause_id"] as? String, warning["cause_id"] as? String)
        // same_cause_as names a finding of this ticket only.
        let otherTicket = try ready(p), otherSubmitted = try submit(p, otherTicket, author), otherReview = try reviewClaim(p, otherSubmitted, reviewer)
        var foreign = reviewInput(p, otherReview, verdict: "reject"); foreign["findings"] = [finding("foreign", try sourceRef(otherSubmitted), sameCause: previous)]
        assertCode("REVIEW_TARGET_MISMATCH") { _ = try self.call("review_record", foreign, reviewer) }
    }

    // CL-44
    func testDraftVerdictHandoffNamesTheReviewerAndTheSubmitter() throws {
        try sourceFixture()
        let p = try project(), author = try native(p, "draft-author", domain: "codex:4401:1:0")
        let reviewer = try native(p, "draft-reviewer", domain: "claude:4402:1:0", provider: "claude"), outsider = try native(p, "draft-outsider", domain: "claude:4403:1:0", provider: "claude")
        let t = try ready(p), submitted = try submit(p, t, author), review = try reviewClaim(p, submitted, reviewer)
        var draft = reviewInput(p, review, verdict: "reject"); draft["findings"] = [finding("draft-gap", try sourceRef(submitted))]; draft["final_report"] = "Stopped at my tool limit after checking the release build."
        var broken = draft; broken["verdict"] = "pass"
        assertCode("REVIEW_ASSESSMENT_REQUIRED") { _ = try self.call("review_draft_save", broken, reviewer) }
        let saved = try call("review_draft_save", draft, reviewer)
        XCTAssertEqual(saved["state"] as? String, "active"); XCTAssertEqual((saved["draft_verdict"] as? JSON)?["verdict"] as? String, "reject")
        XCTAssertNil((saved["draft_verdict"] as? JSON).flatMap { ($0["params"] as? JSON)?["claim_token"] })
        XCTAssertEqual(try current(p, t)["active_attempt_id"] as? String, review["id"] as? String, "a draft keeps the claim active")
        XCTAssertTrue(try router.dbQueue.read { db in try router.records(db, type: "finding", project: p["id"] as? String) }.isEmpty, "the dry run recorded nothing")

        // The implementation author orchestrates the review Triage; it is a contributor and never becomes the reviewer.
        let triage = try call("triage_create", ["project_id": p["id"]!, "name": "Draft handoff", "purpose": "Submit the reviewer's draft", "phase": "review"])
        _ = try call("group_membership", ["project_id": p["id"]!, "group_id": triage["id"]!, "expected_revision": triage["revision"]!, "task_id": t["id"]!, "action": "add"])
        let group = (try call("triage_list", ["project_id": p["id"]!])["groups"] as! [JSON]).first { $0["id"] as? String == triage["id"] as? String }!
        _ = try call("triage_orchestrate", ["project_id": p["id"]!, "triage_id": triage["id"]!, "expected_revision": group["revision"]!, "action": "start", "progress": "Submit the reviewer's draft"], author)
        func submitInput(_ caller: Caller) throws -> JSON {
            ["project_id": p["id"]!, "task_id": t["id"]!, "attempt_id": review["id"]!, "direction_cursor": try call("task_context", ["project_id": p["id"]!, "task_id": t["id"]!], caller)["direction_cursor"]!]
        }
        assertCode("FORBIDDEN") { _ = try self.call("review_draft_submit", try submitInput(outsider), outsider) }
        assertCode("INVALID_TRANSITION") { _ = try self.call("review_draft_submit", try submitInput(reviewer), reviewer) }
        let verdict = try call("review_draft_submit", try submitInput(author), author)
        XCTAssertEqual(verdict["actor"] as? String, reviewer.principal, "the draft's reviewer is the verdict's author")
        XCTAssertEqual((verdict["submitted_by"] as? JSON)?["principal"] as? String, author.principal)
        XCTAssertNotNil(verdict["draft_saved_at"])
        XCTAssertEqual((verdict["findings"] as? [JSON])?.first?["author"] as? String, reviewer.principal)
        let attempt = try record(review["id"], "attempt")
        XCTAssertEqual(attempt["state"] as? String, "finished"); XCTAssertNil(attempt["draft_verdict"])
        XCTAssertEqual(attempt["final_report_author"] as? String, reviewer.principal)
        XCTAssertEqual(try current(p, t)["status_category"] as? String, "queued")
        assertCode("REVIEW_DRAFT_REQUIRED") { _ = try self.call("review_draft_submit", try submitInput(author), author) }
    }

    /// Finding 6c13b7ee: a saved draft never revives a claim or an orchestration whose session generation ended.
    func testDraftSubmissionKeepsTheLiveClaimFences() throws {
        try sourceFixture()
        let p = try project(), author = try native(p, "fence-author", domain: "codex:4411:1:0"), reviewer = try native(p, "fence-reviewer", domain: "claude:4412:1:0", provider: "claude")
        let t = try ready(p), submitted = try submit(p, t, author), review = try reviewClaim(p, submitted, reviewer)
        var draft = reviewInput(p, review, verdict: "not_run"); draft["check"] = "device run"; draft["reason"] = "No device"
        let saved = try call("review_draft_save", draft, reviewer)
        let triage = try call("triage_create", ["project_id": p["id"]!, "name": "Fenced draft", "purpose": "Generation fences", "phase": "review"])
        _ = try call("group_membership", ["project_id": p["id"]!, "group_id": triage["id"]!, "expected_revision": triage["revision"]!, "task_id": t["id"]!, "action": "add"])
        let group = (try call("triage_list", ["project_id": p["id"]!])["groups"] as! [JSON]).first { $0["id"] as? String == triage["id"] as? String }!
        _ = try call("triage_orchestrate", ["project_id": p["id"]!, "triage_id": triage["id"]!, "expected_revision": group["revision"]!, "action": "start", "progress": "Submit drafts"], author)
        // The coordinator's own session generation rotates: its earlier orchestration grants nothing.
        _ = try call("session_register", ["project_id": p["id"]!, "session_id": author.sessionID!, "installation": author.installation, "provider": "codex", "role": "worker", "workspace": workspace.path, "execution_domain": author.executionDomain!])
        let byCoordinator: JSON = ["project_id": p["id"]!, "task_id": t["id"]!, "attempt_id": review["id"]!, "direction_cursor": try call("task_context", ["project_id": p["id"]!, "task_id": t["id"]!], author)["direction_cursor"]!]
        assertCode("FORBIDDEN") { _ = try self.call("review_draft_submit", byCoordinator, author) }
        // The reviewer's session generation rotates: the draft's claim is stale, as for review_record.
        _ = try call("session_register", ["project_id": p["id"]!, "session_id": reviewer.sessionID!, "installation": reviewer.installation, "provider": "claude", "role": "worker", "workspace": workspace.path, "execution_domain": reviewer.executionDomain!])
        assertCode("STALE_CLAIM") { _ = try self.call("review_record", draft, reviewer) }
        assertCode("STALE_CLAIM") { _ = try self.call("review_draft_submit", ["project_id": p["id"]!, "task_id": t["id"]!, "attempt_id": review["id"]!, "expected_revision": saved["revision"]!]) }
        XCTAssertEqual(try current(p, t)["active_attempt_id"] as? String, review["id"] as? String, "nothing changed")
    }

    // CL-46
    func testFinalReportsStayOnCurrentAndPriorAttempts() throws {
        try sourceFixture()
        let p = try project(), author = try native(p, "fr-author", domain: "codex:4601:1:0"), reviewer = try native(p, "fr-reviewer", domain: "claude:4602:1:0", provider: "claude")
        let t = try ready(p), submitted = try submit(p, t, author, report: "Implemented the export path; all affected tests pass.")
        let review = try reviewClaim(p, submitted, reviewer)
        var reject = reviewInput(p, review, verdict: "reject"); reject["findings"] = [finding("fr-gap", try sourceRef(submitted))]; reject["final_report"] = "One gap found in the error path."
        _ = try call("review_record", reject, reviewer)
        let rework = try claim(p, try current(p, t), caller: author)
        var release = auth(p, rework); release["reason"] = "Handing over"; release["final_report"] = String(repeating: "x", count: 64_001)
        assertCode("INVALID_INPUT") { _ = try self.call("work_release", release, author) }
        release["final_report"] = "Started the fix; the handover note has the plan."
        _ = try call("work_release", release, author)
        let attempts = try router.dbQueue.read { db in try router.records(db, type: "attempt", project: p["id"] as? String) }.filter { $0["task_id"] as? String == t["id"] as? String }
        XCTAssertEqual(attempts.compactMap { $0["final_report"] as? String }.count, 3)
        XCTAssertTrue(attempts.allSatisfy { $0["final_report"] == nil || $0["final_report_origin"] as? String == "agent" })
        let context = try call("task_context", ["project_id": p["id"]!, "task_id": t["id"]!])
        XCTAssertEqual((context["attempts"] as? [JSON])?.compactMap { $0["final_report"] as? String }.count, 3)
        XCTAssertEqual((context["prior_handler"] as? JSON)?["final_report"] as? String, "Started the fix; the handover note has the plan.")
        let owners = try claim(p, try current(p, t))
        var ownerRelease = auth(p, owners); ownerRelease["reason"] = "Owner stops"; ownerRelease["final_report"] = "Owner text"
        assertCode("INVALID_INPUT") { _ = try self.call("work_release", ownerRelease) }
    }

    // CL-47
    func testResourceWaitIsShownAndFailedChecksNameTheirCause() throws {
        try sourceFixture()
        let p = try project(), author = try native(p, "rw-author", domain: "codex:4701:1:0"), reviewer = try native(p, "rw-reviewer", domain: "claude:4702:1:0", provider: "claude")
        let t = try ready(p), other = try ready(p), attempt = try claim(p, t, caller: author)
        var wait = auth(p, attempt); wait["progress"] = "Waiting for the engine"; wait["waiting_for_resource"] = "Unity editor lock"
        let waiting = try call("work_checkpoint", wait, author)
        XCTAssertEqual(waiting["waiting_for_resource"] as? String, "Unity editor lock"); XCTAssertNotNil(waiting["waiting_since"])
        let handler = try call("task_context", ["project_id": p["id"]!, "task_id": t["id"]!])["handler"] as! JSON
        XCTAssertEqual((handler["checkpoint_health"] as? JSON)?["state"] as? String, "waiting_for_resource")
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-2 * 3600))
        XCTAssertEqual(CommandRouter.checkpointHealth(["state": "active", "last_checkpoint": old, "waiting_for_resource": "lock"])?["state"] as? String, "waiting_for_resource", "waiting time is never quiet")
        XCTAssertEqual(CommandRouter.checkpointHealth(["state": "active", "last_checkpoint": old])?["state"] as? String, "quiet")
        XCTAssertNil(CommandRouter.checkpointHealth(["state": "submitted", "last_checkpoint": old]))
        var resume = auth(p, attempt); resume["progress"] = "Lock released; compiling"
        let resumed = try call("work_checkpoint", resume, author)
        XCTAssertNil(resumed["waiting_for_resource"]); XCTAssertNotNil(resumed["waiting_seconds"])

        var input = auth(p, attempt); input["acceptance_revision"] = 1; input["evidence_manifest"] = ["kind": "source", "source_capture": [:]]
        let submitted = try call("work_submit", input, author), review = try reviewClaim(p, submitted, reviewer)
        var reject = reviewInput(p, review, verdict: "reject", checks: [["name": "unit tests", "result": "fail", "failure_cause": "unknown"]])
        reject["findings"] = [finding("rw-gap", try sourceRef(submitted))]
        assertCode("INVALID_INPUT") { _ = try self.call("review_record", reject, reviewer) }
        reject["checks"] = [["name": "lint", "result": "pass", "failure_cause": "environment"]]
        assertCode("INVALID_INPUT") { _ = try self.call("review_record", reject, reviewer) }
        reject["checks"] = [["name": "unit tests", "result": "fail", "failure_cause": "environment"],
                            ["name": "integration", "result": "fail", "failure_cause": "other_ticket", "cause_task_id": other["id"]!],
                            ["name": "export", "result": "fail", "failure_cause": "defect"]]
        let checks = try call("review_record", reject, reviewer)["checks"] as! [JSON]
        XCTAssertEqual(checks.map { $0["failure_cause"] as? String }, ["environment", "other_ticket", "defect"])
        XCTAssertEqual(checks[1]["cause_task_key"] as? String, other["key"] as? String)
    }

    // CL-45
    func testReleaseSetHoldsNeedThePolicyAndCompleteTheSetTogether() throws {
        try sourceFixture()
        let reviewer = Caller(role: "owner", installation: "release-reviewer", projectIDs: [])
        // Without the policy a pass cannot hold, and passing tickets complete independently.
        var p = try project()
        let plainSubmitted = try submitSource(p, try claim(p, try ready(p))), plainReview = try reviewClaim(p, plainSubmitted, reviewer)
        var held = reviewInput(p, plainReview, verdict: "pass"); held["review_assessment"] = try ownReviewAssessment(p, plainReview, reviewer); held["release_set"] = "1.0"; held["hold_reason"] = "Ships with the save format"
        assertCode("POLICY_DENIED") { _ = try self.call("review_record", held, reviewer) }

        p = try record(p["id"], "project")
        p = try call("policy_apply", ["project_id": p["id"]!, "expected_revision": p["revision"]!, "policy": ["required_gates": ["review"], "release_set_holds": true]])
        var tasks: [JSON] = []
        for index in 0..<2 {
            let t = try ready(p), submitted = try submitSource(p, try claim(p, t)), review = try reviewClaim(p, submitted, reviewer)
            var pass = reviewInput(p, review, verdict: "pass"); pass["review_assessment"] = try ownReviewAssessment(p, review, reviewer)
            pass["release_set"] = "1.0"; pass["hold_reason"] = "Committed alone it fails the save-format tests (\(index))"
            let completion = try call("review_record", pass, reviewer)["completion"] as! JSON
            XCTAssertEqual(completion["waiting_for"] as? String, "RELEASE_SET"); XCTAssertEqual(completion["release_set"] as? String, "1.0")
            tasks.append(try current(p, t))
        }
        for t in tasks {
            XCTAssertEqual(t["status_category"] as? String, "review"); XCTAssertEqual((t["release_hold"] as? JSON)?["release_set"] as? String, "1.0")
            assertCode("RELEASE_HOLD_ACTIVE") { _ = try self.call("task_complete", ["project_id": p["id"]!, "task_id": t["id"]!, "expected_revision": t["revision"]!]) }
        }
        // One ticket that is not ready keeps the whole set open.
        let direction = try call("message_send", ["project_id": p["id"]!, "task_id": tasks[1]["id"]!, "body": "Owner direction before release", "requires_action": true])
        XCTAssertThrowsError(try call("release_set_complete", ["project_id": p["id"]!, "release_set": "1.0"])) { error in
            XCTAssertEqual((error as? CoreError)?.code, "RELEASE_SET_NOT_READY")
            let refusals = (error as? CoreError)?.details["not_ready"] as? [JSON] ?? []
            XCTAssertEqual(refusals.map { $0["task_id"] as? String }, [tasks[1]["id"] as? String]); XCTAssertEqual(refusals.first?["code"] as? String, "USER_DIRECTION_PENDING")
        }
        XCTAssertNil(try current(p, tasks[0])["completed_at"], "the set completes together or not at all")
        _ = try call("direction_waive", ["project_id": p["id"]!, "message_id": direction["id"]!, "expected_revision": direction["revision"]!, "reason": "Covered by the release notes"])
        assertCode("NOT_FOUND") { _ = try self.call("release_set_complete", ["project_id": p["id"]!, "release_set": "2.0"]) }
        let result = try call("release_set_complete", ["project_id": p["id"]!, "release_set": "1.0"])
        XCTAssertEqual((result["completed"] as? [JSON])?.count, 2)
        for t in tasks { let done = try current(p, t); XCTAssertEqual(done["status_category"] as? String, "done"); XCTAssertNil(done["release_hold"]) }
    }

    /// Finding ff90ecdf: a release hold survives a later gate; a later reject ends it.
    func testReleaseHoldSurvivesALaterOwnerGate() throws {
        var p = try project()
        p = try call("policy_apply", ["project_id": p["id"]!, "expected_revision": p["revision"]!, "policy": ["required_gates": ["review", "human_approval"], "release_set_holds": true]])
        func candidate(_ name: String) throws -> (task: JSON, submitted: JSON, artifact: JSON) {
            let t = try ready(p), a = try claim(p, t)
            try write("private/\(name).txt", "Exact candidate \(name)")
            let artifact = try call("attachment_add", ["project_id": p["id"]!, "task_id": t["id"]!, "path": workspace.appendingPathComponent("private/\(name).txt").path])
            var input = auth(p, a); input["acceptance_revision"] = 1; input["evidence_manifest"] = ["artifact_refs": [["artifact_id": artifact["id"]!, "sha256": artifact["sha256"]!]]]
            return (t, try call("work_submit", input), artifact)
        }
        func holdPass(_ value: (task: JSON, submitted: JSON, artifact: JSON)) throws {
            let reviewer = Caller(role: "owner", installation: "hold-" + UUID().uuidString, projectIDs: []), review = try reviewClaim(p, value.submitted, reviewer)
            var report = auth(p, review); report["title"] = "Hold report"; report["body"] = "Synthetic verification."
            let evidence = try call("review_evidence_add", report, reviewer)
            var pass = reviewInput(p, review, verdict: "pass"); pass["release_set"] = "atomic"; pass["hold_reason"] = "Ships with the other ticket"
            pass["review_assessment"] = try fixtureReviewAssessment(router, task: try record(review["task_id"], "task"), manifest: try record(review["manifest_id"], "manifest"), artifact: evidence)
            _ = try call("review_record", pass, reviewer)
        }
        func approve(_ value: (task: JSON, submitted: JSON, artifact: JSON), _ result: String) throws {
            let request = try call("human_request_create", ["project_id": p["id"]!, "task_id": value.task["id"]!, "title": "Approval for \(value.task["key"]!)", "target_attachment_id": value.artifact["id"]!, "questions": [["id": "approve", "type": "approval", "prompt": "Inspect the exact candidate for \(value.task["key"]!)"]]])
            let context = try call("task_context", ["project_id": p["id"]!, "task_id": value.task["id"]!])
            _ = try call("human_request_answer", ["project_id": p["id"]!, "request_id": request["id"]!, "expected_revision": request["revision"]!, "target_sha256": value.artifact["sha256"]!, "answers": [["question_id": "approve", "result": result]], "direction_cursor": context["direction_cursor"]!, "expected_task_revision": (context["task"] as! JSON)["revision"]!])
        }
        let first = try candidate("first"), second = try candidate("second")
        try holdPass(first); try approve(first, "approved")
        let held = try current(p, first.task)
        XCTAssertEqual(held["status_category"] as? String, "review", "a later gate does not complete a held ticket"); XCTAssertNil(held["completed_at"]); XCTAssertNotNil(held["release_hold"])
        try holdPass(second); try approve(second, "changes_requested")
        let rejected = try current(p, second.task)
        XCTAssertEqual(rejected["status_category"] as? String, "queued"); XCTAssertNil(rejected["release_hold"], "a reject ends the hold")
        let result = try call("release_set_complete", ["project_id": p["id"]!, "release_set": "atomic"])
        XCTAssertEqual((result["completed"] as? [JSON])?.count, 1)
        XCTAssertEqual(try current(p, first.task)["status_category"] as? String, "done")
    }

    func testToolCatalogListsTheNewReviewCommandsAndVerdicts() throws {
        let p = try project(), agent = try native(p, "catalog", domain: "codex:4801:1:0")
        let tools = router.toolCatalog(agent)
        for name in ["review_draft_save", "review_draft_submit", "finding_severity_set", "release_set_complete"] { XCTAssertNotNil(tools.first { $0["name"] as? String == name }, name) }
        let record = tools.first { $0["name"] as? String == "review_record" }!
        let verdict = ((record["inputSchema"] as! JSON)["properties"] as! JSON)["verdict"] as! JSON
        XCTAssertEqual(Set(verdict["enum"] as! [String]), ["pass", "reject", "blocked", "evidence_missing", "not_run"])
        let checkpoint = ((tools.first { $0["name"] as? String == "work_checkpoint" }!["inputSchema"] as! JSON)["properties"] as! JSON)
        XCTAssertNotNil(checkpoint["waiting_for_resource"])
    }
}
