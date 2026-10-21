import XCTest
@testable import ChecklistCore

/// Exercise the shared verdict entry points with both image and playtest inputs.
extension PlaytestBundleTests {
    func combinedProject() throws -> JSON {
        try call("project_create", ["name":"Synthetic combined evidence", "key_prefix":"CE", "root_path":directory.path])
    }

    func combinedSubmission(_ project: JSON) throws -> (submission: JSON, screenshot: JSON) {
        var task = try call("task_create", ["project_id":project["id"]!, "title":"Synthetic image playtest", "kind":"playtest", "brief":"Check a synthetic exact-build bundle", "acceptance":["Checkpoint is shown", "Restart restores checkpoint"]])
        task = try call("task_edit", ["project_id":project["id"]!, "task_id":task["id"]!, "expected_revision":task["revision"]!, "patch":["readiness":"ready"]])
        let attempt = try call("work_claim", ["project_id":project["id"]!, "task_id":task["id"]!, "expected_revision":task["revision"]!])
        var input = try bundle(project, task)
        let url = directory.appendingPathComponent(UUID().uuidString + ".png")
        let png = try XCTUnwrap(Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=="))
        try png.write(to:url)
        let screenshot = try call("attachment_add", ["project_id":project["id"]!, "task_id":task["id"]!, "path":url.path])
        input["screenshots"] = [ref(screenshot)]
        return (try submit(project, attempt, input), screenshot)
    }

    func combinedReviewer(_ project: JSON) throws -> Caller {
        let sid = UUID().uuidString, installation = "synthetic-combined-critic", domain = "synthetic-combined-review-host"
        _ = try call("session_register", ["project_id":project["id"]!, "session_id":sid, "installation":installation, "provider":"codex", "role":"worker", "workspace":directory.path, "execution_domain":domain])
        return Caller(role:"worker", installation:installation, projectIDs:[project["id"] as! String], sessionID:sid, workspace:directory.path, executionDomain:domain)
    }

    func combinedClaim(_ project: JSON, _ submission: JSON, _ reviewer: Caller) throws -> JSON {
        let task = try call("task_get", ["project_id":project["id"]!, "task_id":(submission["task"] as! JSON)["id"]!])
        return try call("work_claim", ["project_id":project["id"]!, "task_id":task["id"]!, "expected_revision":task["revision"]!, "phase":"review", "review_request_id":(submission["review_request_ids"] as! [String])[0], "target_manifest_id":submission["manifest_id"]!, "gate":"review"], reviewer)
    }

    func combinedVerdictInput(_ project: JSON, _ attempt: JSON, _ screenshot: JSON, _ reviewer: Caller) throws -> JSON {
        let task = try record(attempt["task_id"]!, "task"), manifest = try record(attempt["manifest_id"]!, "manifest")
        let report = try call("review_evidence_add", ["project_id":project["id"]!, "attempt_id":attempt["id"]!, "claim_token":attempt["claim_token"]!, "title":"Synthetic combined review", "body":"Component fixture only; no native playtest or installed UI qualification."], reviewer)
        var assessment = try fixtureReviewAssessment(router, task:task, manifest:manifest, artifact:report)
        var rows = assessment["acceptance"] as! [JSON]
        rows[0]["evidence_refs"] = (rows[0]["evidence_refs"] as! [JSON]) + [ref(screenshot)]
        assessment["acceptance"] = rows
        return ["project_id":project["id"]!, "attempt_id":attempt["id"]!, "claim_token":attempt["claim_token"]!, "review_request_id":attempt["review_request_id"]!, "target_manifest_id":attempt["manifest_id"]!, "gate":"review", "verdict":"pass", "checks":[], "review_assessment":assessment, "retain_cited_files":true,
                "inspected_images":[ref(screenshot).merging(["target_manifest_id":attempt["manifest_id"]!]) { _, new in new }]]
    }

    func assertCombinedVerdict(_ verdict: JSON, _ screenshot: JSON, _ reviewer: Caller, file: StaticString = #filePath, line: UInt = #line) throws {
        let marks = try XCTUnwrap(verdict["inspected_images"] as? [JSON], file:file, line:line)
        XCTAssertEqual(marks.count, 1, file:file, line:line)
        XCTAssertEqual(marks.first?["artifact_id"] as? String, screenshot["id"] as? String, file:file, line:line)
        XCTAssertEqual(marks.first?["sha256"] as? String, screenshot["sha256"] as? String, file:file, line:line)
        XCTAssertEqual(marks.first?["target_manifest_id"] as? String, verdict["manifest_id"] as? String, file:file, line:line)
        XCTAssertEqual((verdict["retained_artifact_refs"] as? [JSON])?.compactMap { $0["artifact_id"] as? String }, [screenshot["id"] as! String], file:file, line:line)
        XCTAssertEqual(((verdict["review_assessment"] as? JSON)?["acceptance"] as? [JSON])?.compactMap { $0["result"] as? String }, ["pass", "pass"], file:file, line:line)
        XCTAssertEqual(verdict["actor"] as? String, reviewer.principal, file:file, line:line)
        XCTAssertTrue(bool(try record(screenshot["id"]!, "attachment"), "keep_original"), file:file, line:line)
        let stored = try record(verdict["id"]!, "review")
        for key in ["inspected_images", "review_assessment", "retained_artifact_refs"] {
            XCTAssertEqual(try jsonString(stored[key]!), try jsonString(verdict[key]!), file:file, line:line)
        }
    }

    func testCombinedAgentVerdictEnforcesBothGuardsBeforeRetainingFiles() throws {
        let project = try combinedProject(), fixture = try combinedSubmission(project), reviewer = try combinedReviewer(project)
        let attempt = try combinedClaim(project, fixture.submission, reviewer)
        let input = try combinedVerdictInput(project, attempt, fixture.screenshot, reviewer)
        var missingMarks = input; missingMarks.removeValue(forKey:"inspected_images")
        assertCode("IMAGE_INSPECTION_REQUIRED") { _ = try self.call("review_record", missingMarks, reviewer) }
        var incomplete = input, assessment = input["review_assessment"] as! JSON
        assessment["acceptance"] = Array((assessment["acceptance"] as! [JSON]).prefix(1)); incomplete["review_assessment"] = assessment
        assertCode("REVIEW_ASSESSMENT_INCOMPLETE") { _ = try self.call("review_record", incomplete, reviewer) }
        XCTAssertFalse(bool(try record(fixture.screenshot["id"]!, "attachment"), "keep_original"))
        XCTAssertEqual(try record(attempt["id"]!, "attempt")["state"] as? String, "active")
        let result = try call("review_record", input, reviewer)
        try assertCombinedVerdict(result, fixture.screenshot, reviewer)
    }

    func testCombinedSavedDraftRollsBackRetentionAndSubmitsAllFields() throws {
        let project = try combinedProject(), fixture = try combinedSubmission(project), reviewer = try combinedReviewer(project)
        let attempt = try combinedClaim(project, fixture.submission, reviewer), input = try combinedVerdictInput(project, attempt, fixture.screenshot, reviewer)
        let saved = try call("review_draft_save", input, reviewer), params = (saved["draft_verdict"] as! JSON)["params"] as! JSON
        for key in ["inspected_images", "review_assessment"] { XCTAssertEqual(try jsonString(params[key]!), try jsonString(input[key]!)) }
        XCTAssertEqual(params["retain_cited_files"] as? Bool, true)
        XCTAssertFalse(bool(try record(fixture.screenshot["id"]!, "attachment"), "keep_original"))
        XCTAssertTrue(try router.dbQueue.read { try router.records($0, type:"review", project:project["id"] as? String).isEmpty })
        let context = try call("task_context", ["project_id":project["id"]!, "task_id":attempt["task_id"]!])
        let result = try call("review_draft_submit", ["project_id":project["id"]!, "task_id":attempt["task_id"]!, "attempt_id":attempt["id"]!, "direction_cursor":context["direction_cursor"]!])
        try assertCombinedVerdict(result, fixture.screenshot, reviewer)
        XCTAssertEqual((result["submitted_by"] as? JSON)?["principal"] as? String, owner.principal)
    }

    func testCombinedBatchMembersRetainTheirOwnMarksAssessmentAndCitations() throws {
        let project = try combinedProject(), first = try combinedSubmission(project), second = try combinedSubmission(project), reviewer = try combinedReviewer(project)
        var group = try call("triage_create", ["project_id":project["id"]!, "name":"Synthetic combined review", "phase":"review"])
        for fixture in [first, second] {
            _ = try call("group_membership", ["project_id":project["id"]!, "group_id":group["id"]!, "expected_revision":group["revision"]!, "task_id":(fixture.submission["task"] as! JSON)["id"]!, "action":"add"])
            group = try record(group["id"]!, "group")
        }
        let fixtures = [first, second]
        let members: [JSON] = try fixtures.map { fixture in
            let task = try call("task_get", ["project_id":project["id"]!, "task_id":(fixture.submission["task"] as! JSON)["id"]!])
            return ["task_id":task["id"]!, "expected_revision":task["revision"]!, "file_scopes":[], "lane_scopes":[], "review_request_id":(fixture.submission["review_request_ids"] as! [String])[0], "target_manifest_id":fixture.submission["manifest_id"]!, "gate":"review"]
        }
        let batch = try call("batch_prepare", ["project_id":project["id"]!, "triage_id":group["id"]!, "expected_revision":group["revision"]!, "phase":"review", "tasks":members], reviewer)
        let claims = try call("batch_claim", ["project_id":project["id"]!, "batch_id":batch["id"]!, "expected_revision":batch["revision"]!, "policy_revision":batch["policy_revision"]!], reviewer)["claims"] as! [JSON]
        let inputs = try zip(claims, fixtures).map { try combinedVerdictInput(project, $0.0, $0.1.screenshot, reviewer) }
        var broken = inputs; broken[1]["inspected_images"] = inputs[0]["inspected_images"]
        assertCode("IMAGE_INSPECTION_REQUIRED") { _ = try self.call("batch_review_record", ["project_id":project["id"]!, "batch_id":batch["id"]!, "expected_revision":batch["revision"]!, "members":broken], reviewer) }
        for fixture in fixtures { XCTAssertFalse(bool(try record(fixture.screenshot["id"]!, "attachment"), "keep_original")) }
        let result = try call("batch_review_record", ["project_id":project["id"]!, "batch_id":batch["id"]!, "expected_revision":batch["revision"]!, "members":inputs], reviewer)
        let verdicts = try XCTUnwrap(result["results"] as? [JSON]); XCTAssertEqual(verdicts.count, 2)
        for (verdict, fixture) in zip(verdicts, fixtures) { try assertCombinedVerdict(verdict, fixture.screenshot, reviewer) }
    }

    func testCombinedCatalogExposesBothHelpersOnRecordAndDraft() throws {
        let tools = router.toolCatalog(Caller(role:"worker", installation:"synthetic-catalog", projectIDs:[]))
        for name in ["review_record", "review_draft_save"] {
            let tool = try XCTUnwrap(tools.first { $0["name"] as? String == name }), schema = try XCTUnwrap(tool["inputSchema"] as? JSON), properties = try XCTUnwrap(schema["properties"] as? JSON)
            XCTAssertEqual((properties["inspected_images"] as? JSON)?["type"] as? String, "array")
            XCTAssertEqual((properties["retain_cited_files"] as? JSON)?["type"] as? String, "boolean")
            XCTAssertEqual((properties["review_assessment"] as? JSON)?["type"] as? String, "object")
        }
    }
}
