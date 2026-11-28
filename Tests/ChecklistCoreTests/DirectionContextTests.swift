import ChecklistTestSupport
import GRDB
import XCTest
@testable import ChecklistCore

final class DirectionContextTests: XCTestCase {
    var directory: URL!
    var router: CommandRouter!
    let owner = Caller(role:"owner",installation:"context-owner",projectIDs:[])
    override func setUpWithError() throws {
        let parent = try FileManager.default.url(for:.cachesDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("ChecklistQualification/CL-24/DirectionContextTests",isDirectory:true)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        directory = parent.appendingPathComponent(UUID().uuidString)
        router = try TestStore.router(root:directory.appendingPathComponent("store"))
    }
    override func tearDownWithError() throws { router = nil; try? FileManager.default.removeItem(at:directory) }
    @discardableResult func call(_ method: String,_ params: JSON,_ caller: Caller? = nil) throws -> JSON {
        var input = method == "work_submit" ? try fixtureAcceptanceEvidence(router,input:params) : params
        if !CommandRouter.readMethods.contains(method) { input["command_id"] = UUID().uuidString }
        return try router.handle(method:method,params:fixtureTaskInput(router,method:method,input:input),caller:caller ?? owner)["data"] as! JSON
    }
    func assertCode(_ code: String,_ block: () throws -> Void,file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertThrowsError(try block(),file:file,line:line) { XCTAssertEqual(($0 as? CoreError)?.code,code,file:file,line:line) }
    }
    func fixture() throws -> (JSON,JSON,Caller) {
        let project = try call("project_create",["name":"Context fixture","key_prefix":"CTX","root_path":directory.path])
        var task = try call("task_create",["project_id":project["id"]!,"title":"Preserve context","brief":"Continue with the recorded decisions","acceptance":["Retain exact context"]])
        task = try call("task_edit",["project_id":project["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"patch":["readiness":"ready"]])
        let sid = UUID().uuidString
        _ = try call("session_register",["project_id":project["id"]!,"session_id":sid,"provider":"codex","role":"worker","label":"Context worker","workspace_path":directory.path])
        return (project,task,Caller(role:"worker",installation:"context-worker",projectIDs:[project["id"] as! String],sessionID:sid,workspace:directory.path))
    }
    func claim(_ project: JSON,_ task: JSON,_ worker: Caller) throws -> JSON {
        try call("work_claim",["project_id":project["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!],worker)
    }
    func context(_ project: JSON,_ task: JSON,_ worker: Caller? = nil) throws -> JSON {
        try call("task_context",["project_id":project["id"]!,"task_id":task["id"]!],worker)
    }

    func testSavedDirectionPickupRequiresActualBoundCheckpoint() throws {
        let (project,task,worker) = try fixture(),pid = project["id"] as! String
        let note = try call("message_send",["project_id":pid,"task_id":task["id"]!,"body":"Keep keyboard behavior","requires_action":true])
        XCTAssertEqual(note["delivery_status"] as? String,"saved_for_pickup")
        let attempt = try claim(project,task,worker)
        let pickup = attempt["context"] as! JSON
        XCTAssertEqual(pickup["next_action"] as? String,"address_owner_directions")
        XCTAssertEqual(((pickup["unresolved_directions"] as! [JSON]).first?["id"] as? String),note["id"] as? String)
        let inbox = try call("session_inbox",["project_id":pid],worker),delivery = (inbox["deliveries"] as! [JSON])[0]
        _ = try call("message_ack",["project_id":pid,"delivery_id":delivery["id"]!,"stage":"acknowledged"],worker)
        XCTAssertEqual((try context(project,task,worker)["counts"] as! JSON)["unresolved_directions"] as? Int,1)
        assertCode("INVALID_INPUT") { _ = try self.call("message_ack",["project_id":pid,"delivery_id":delivery["id"]!,"stage":"addressed","response_ref":"I did it"],worker) }
        assertCode("NOT_FOUND") { _ = try self.call("message_ack",["project_id":pid,"delivery_id":delivery["id"]!,"stage":"addressed","response_ref":["kind":"checkpoint","id":UUID().uuidString]],worker) }
        let unrelated = try call("message_send",["project_id":pid,"task_id":task["id"]!,"body":"Unrelated progress"],worker)
        assertCode("DIRECTION_EVIDENCE_REQUIRED") { _ = try self.call("message_ack",["project_id":pid,"delivery_id":delivery["id"]!,"stage":"addressed","response_ref":["kind":"message","id":unrelated["id"]!]],worker) }
        let checkpoint = try call("work_checkpoint",["project_id":pid,"attempt_id":attempt["id"]!,"claim_token":attempt["claim_token"]!,"progress":"Verified keyboard behavior remains available","direction_ids":[note["id"]!],"direction_cursor":pickup["direction_cursor"]!],worker)
        let addressed = try call("message_ack",["project_id":pid,"delivery_id":delivery["id"]!,"stage":"addressed","response_ref":["kind":"checkpoint","id":checkpoint["checkpoint_id"]!]],worker)
        XCTAssertNotNil(addressed["disposition_id"])
        XCTAssertEqual((try context(project,task,worker)["counts"] as! JSON)["unresolved_directions"] as? Int,0)
        _ = try call("message_ack",["project_id":pid,"delivery_id":delivery["id"]!,"stage":"acknowledged"],worker)
        XCTAssertEqual(((try call("session_inbox",["project_id":pid],worker)["deliveries"] as! [JSON])[0])["state"] as? String,"addressed")
    }

    func testDirectionRacingSubmissionRetainsClaimAndRoundCursor() throws {
        let (project,task,worker) = try fixture(),pid = project["id"] as! String
        let attempt = try claim(project,task,worker),oldContext = attempt["context"] as! JSON
        let artifactPath = directory.appendingPathComponent("result.txt");try Data("Verified output".utf8).write(to:artifactPath)
        let artifact = try call("attachment_add",["project_id":pid,"task_id":task["id"]!,"path":artifactPath.path])
        let note = try call("message_send",["project_id":pid,"task_id":task["id"]!,"body":"Check this new constraint","requires_action":true])
        let input: JSON = ["project_id":pid,"attempt_id":attempt["id"]!,"claim_token":attempt["claim_token"]!,"acceptance_revision":1,"direction_cursor":oldContext["direction_cursor"]!,"evidence_manifest":["artifact_refs":[["artifact_id":artifact["id"]!,"sha256":artifact["sha256"]!]]]]
        assertCode("USER_DIRECTION_PENDING") { _ = try self.call("work_submit",input,worker) }
        XCTAssertEqual((try call("task_get",["project_id":pid,"task_id":task["id"]!],worker))["active_attempt_id"] as? String,attempt["id"] as? String)
        _ = try call("direction_waive",["project_id":pid,"message_id":note["id"]!,"expected_revision":note["revision"]!,"reason":"No longer applies to this output"])
        assertCode("CURSOR_RESET") { _ = try self.call("work_submit",input,worker) }
        var fresh = input;fresh["direction_cursor"] = try context(project,task,worker)["direction_cursor"]
        let submission = try call("work_submit",fresh,worker)
        XCTAssertNotNil(submission["manifest_id"])
        // A token from the implementation attempt cannot authorize a later completion/review round.
        let currentTask = submission["task"] as! JSON
        try router.dbQueue.write { db in
            self.assertCode("CURSOR_RESET") { try self.router.validateDirectionCursor(db,params:["direction_cursor":fresh["direction_cursor"]!],task:currentTask,caller:worker) }
        }
    }

    func testGeneratedDirectionCursorValidationMatchesLegacyScopeAndErrors() throws {
        let (project, originalTask, worker) = try fixture()
        let pid = try XCTUnwrap(project["id"] as? String), tid = try XCTUnwrap(originalTask["id"] as? String)
        var task = originalTask
        task["tag_ids"] = ["keep"]
        let matching: JSON = ["id": "pin-keep", "body": "Keep behavior", "revision": 2, "tag_ids": ["keep"]]
        let excluded: JSON = ["id": "pin-skip", "body": "Asset only", "revision": 1, "task_kinds": ["asset"]]
        let legacy: JSON = ["id": "legacy-0", "body": "Preserve legacy context", "revision": 1, "origin": "legacy_project_context"]
        let inputs: [(brief: String, pins: Any, expected: [JSON])] = [
            ("", [JSON](), []), ("Project context", [excluded, matching], [matching]),
            ("", ["Preserve legacy context"], [legacy]), ("", [excluded], []),
        ]
        let fallbackAttemptID = UUID().uuidString
        try router.dbQueue.write { db in
            try router.save(db, [
                "id": fallbackAttemptID, "project_id": pid, "task_id": tid, "revision": 1,
                "state": "active", "phase": "review", "principal": worker.principal,
            ], type: "attempt")
            let authorization = try router.authorizationScope(db, worker)
            let generation = try router.callerSessionGeneration(db, worker, project: pid)
            for variant in 0..<16 {
                try db.inSavepoint {
                    let input = inputs[variant % inputs.count]
                    let revision = variant + 1
                    let pending = variant >= 8 && variant.isMultiple(of: 2)
                    var updatedProject = router.revised(try router.record(db, pid, type: "project"))
                    updatedProject["brief"] = input.brief
                    updatedProject["brief_revision"] = revision
                    updatedProject["pinned_decisions"] = input.pins
                    try router.save(db, updatedProject, type: "project")
                    var expectedDirections: [JSON] = []
                    for index in 0..<(variant / inputs.count) {
                        let id = UUID().uuidString, addressed = !(pending && index == 0)
                        try router.save(db, [
                            "id": id, "project_id": pid, "task_id": tid, "origin": "human_ui",
                            "requires_action": true, "addressed": addressed, "revision": index + 1,
                        ], type: "message")
                        if index == 2 {
                            try router.save(db, [
                                "id": UUID().uuidString, "project_id": pid, "task_id": tid,
                                "message_id": id, "state": "retracted", "revision": 1,
                            ], type: "direction_disposition")
                        } else {
                            expectedDirections.append(["id": id, "revision": index + 1, "addressed": addressed])
                        }
                    }
                    let relevant: JSON = [
                        "brief": input.brief, "brief_revision": revision, "decisions": input.expected, "directions": expectedDirections,
                    ]
                    let digest = ChecklistCore.hash(Data((try jsonString(relevant)).utf8))
                    for attempt in [nil, ["id": "exact-review-round"]] as [JSON?] {
                        let round = attempt?["id"] as? String ?? fallbackAttemptID
                        let expectedScope = "\(pid):directions:\(tid):\(round):\(digest):\(authorization):\(generation)"
                        XCTAssertEqual(try router.directionCursorScope(db, task: task, caller: worker, attempt: attempt), expectedScope)
                        let valid = try router.cursor(db, caller: worker, scope: expectedScope, sequence: revision)
                        let priorScope = try router.directionCursorScope(db, task: task, caller: worker, attempt: ["id": "prior-review-round"])
                        let stale = try router.cursor(db, caller: worker, scope: priorScope, sequence: revision)
                        let foreign = try router.cursor(db, caller: owner, scope: expectedScope, sequence: revision)
                        for cursor in [valid, stale, foreign] {
                            let params: JSON = ["direction_cursor": cursor]
                            if pending || cursor != valid {
                                assertCode(pending ? "USER_DIRECTION_PENDING" : "CURSOR_RESET") {
                                    try self.router.validateDirectionCursor(db, params: params, task: task, caller: worker, attempt: attempt)
                                }
                            } else {
                                var queries: [String] = []
                                db.trace { if case .statement(let statement) = $0 { queries.append(statement.sql) } }
                                XCTAssertNoThrow(try router.validateDirectionCursor(db, params: params, task: task, caller: worker, attempt: attempt))
                                db.trace(options: [])
                                XCTAssertEqual(queries.filter { $0.contains("json_extract(data,'$.origin')='human_ui'") }.count, 1)
                                XCTAssertEqual(queries.filter { $0.hasSuffix("WHERE id = CAST(? AS TEXT) AND type = CAST(? AS TEXT)") }.count, 1)
                            }
                        }
                        let hasContext = !input.brief.isEmpty || !input.expected.isEmpty || !expectedDirections.isEmpty
                        for params in [[:], ["direction_cursor": NSNull()]] as [JSON] {
                            if pending || hasContext {
                                assertCode(pending ? "USER_DIRECTION_PENDING" : "DIRECTION_CURSOR_REQUIRED") {
                                    try self.router.validateDirectionCursor(db, params: params, task: task, caller: worker, attempt: attempt)
                                }
                            } else {
                                try router.validateDirectionCursor(db, params: params, task: task, caller: worker, attempt: attempt)
                            }
                        }
                    }
                    return .rollback
                }
            }
        }
    }

    func testApprovedProjectContextKeepsHistoryAndPropagatesOnlyRelevantPins() throws {
        let (project,task,worker) = try fixture(),pid = project["id"] as! String
        _ = try claim(project,task,worker)
        let current = try call("project_settings_get",["project_id":pid])
        let updated = try call("project_edit",["project_id":pid,"expected_revision":current["revision"]!,"brief":"Use the native platform conventions","pinned_decisions":[["body":"Preserve shortcuts","task_kinds":["work"]],["body":"Keep asset alpha","task_kinds":["asset"]]]])
        let packet = try context(project,task,worker),common = packet["project"] as! JSON
        XCTAssertEqual(common["brief_revision"] as? Int,1)
        XCTAssertEqual((common["pinned_decisions"] as! [JSON]).count,1)
        XCTAssertEqual((common["pinned_decisions"] as! [JSON])[0]["origin"] as? String,"human_ui")
        let deliveries = packet["direction_deliveries"] as! [JSON]
        XCTAssertEqual(deliveries.count,1);XCTAssertEqual(deliveries[0]["recipient_session_id"] as? String,worker.sessionID)
        var pins = updated["pinned_decisions"] as! [JSON];pins[0]["body"] = "Preserve shortcuts and focus"
        let newer = try call("project_edit",["project_id":pid,"expected_revision":updated["revision"]!,"pinned_decisions":pins])
        let history = try call("task_context",["project_id":pid,"task_id":task["id"]!,"context_revision_id":newer["previous_context_revision_id"]!],worker)["historical_project_context"] as! JSON
        XCTAssertEqual((history["pinned_decisions"] as! [JSON])[0]["body"] as? String,"Preserve shortcuts")
        XCTAssertEqual(((newer["pinned_decisions"] as! [JSON])[0])["revision"] as? Int,2)
        // A cosmetic change neither creates a direction nor invalidates a context cursor.
        let before = try context(project,task,worker)
        _ = try call("project_edit",["project_id":pid,"expected_revision":newer["revision"]!,"name":"Renamed fixture"])
        XCTAssertEqual((try context(project,task,worker)["counts"] as! JSON)["unresolved_directions"] as? Int,(before["counts"] as! JSON)["unresolved_directions"] as? Int)
    }

    func testNewDirectionBlocksVerdictAndCompletionAtomically() throws {
        let (project,task,worker) = try fixture(),pid = project["id"] as! String
        // This case deliberately tests the separate completion gate after a pass.
        let settings = try call("project_settings_get",["project_id":pid])
        var policy = settings["policy"] as! JSON;policy["review_batch_policy"] = "hold_passing_for_batch"
        _ = try call("policy_apply",["project_id":pid,"expected_revision":settings["revision"]!,"policy":policy])
        let attempt = try claim(project,task,worker)
        let path = directory.appendingPathComponent("reviewed.txt");try Data("Exact review output".utf8).write(to:path)
        let artifact = try call("attachment_add",["project_id":pid,"task_id":task["id"]!,"path":path.path])
        let submitted = try call("work_submit",["project_id":pid,"attempt_id":attempt["id"]!,"claim_token":attempt["claim_token"]!,"acceptance_revision":1,"evidence_manifest":["artifact_refs":[["artifact_id":artifact["id"]!,"sha256":artifact["sha256"]!]]]],worker)
        let target = submitted["task"] as! JSON,rid = (submitted["review_request_ids"] as! [String])[0]
        let reviewer = Caller(role:"owner",installation:"independent-context-reviewer",projectIDs:[])
        let review = try call("work_claim",["project_id":pid,"task_id":task["id"]!,"expected_revision":target["revision"]!,"phase":"review","review_request_id":rid,"target_manifest_id":submitted["manifest_id"]!,"gate":"review"],reviewer)
        let report = try call("review_evidence_add",["project_id":pid,"attempt_id":review["id"]!,"claim_token":review["claim_token"]!,"title":"Synthetic reviewer direction-guard report","body":"Synthetic independent review assessment for this exact target; direction guards remain separately enforced."],reviewer)
        let manifest = try router.dbQueue.read {try router.record($0,submitted["manifest_id"] as! String,type:"manifest")}
        let assessedTask = try call("task_get",["project_id":pid,"task_id":task["id"]!])
        let assessment = try fixtureReviewAssessment(router,task:assessedTask,manifest:manifest,artifact:report)
        let firstDirection = try call("message_send",["project_id":pid,"task_id":task["id"]!,"body":"Check the latest review constraint","requires_action":true])
        var verdict: JSON = ["project_id":pid,"attempt_id":review["id"]!,"claim_token":review["claim_token"]!,"review_request_id":rid,"target_manifest_id":submitted["manifest_id"]!,"gate":"review","verdict":"pass","checks":[],"findings":[],"review_assessment":assessment,"direction_cursor":(review["context"] as! JSON)["direction_cursor"]!]
        assertCode("USER_DIRECTION_PENDING") { _ = try self.call("review_record",verdict,reviewer) }
        XCTAssertEqual((try call("task_get",["project_id":pid,"task_id":task["id"]!]))["active_attempt_id"] as? String,review["id"] as? String)
        _ = try call("direction_waive",["project_id":pid,"message_id":firstDirection["id"]!,"expected_revision":firstDirection["revision"]!,"reason":"Review constraint is no longer applicable"])
        verdict["direction_cursor"] = try context(project,task,reviewer)["direction_cursor"]
        _ = try call("review_record",verdict,reviewer)
        let current = try call("task_get",["project_id":pid,"task_id":task["id"]!]),beforeClose = try context(project,task)
        let secondDirection = try call("message_send",["project_id":pid,"task_id":task["id"]!,"body":"Check the final closure constraint","requires_action":true])
        var close: JSON = ["project_id":pid,"task_id":task["id"]!,"expected_revision":current["revision"]!,"direction_cursor":beforeClose["direction_cursor"]!]
        assertCode("USER_DIRECTION_PENDING") { _ = try self.call("task_complete",close) }
        XCTAssertEqual((try call("task_get",["project_id":pid,"task_id":task["id"]!]))["status_category"] as? String,"review")
        _ = try call("direction_waive",["project_id":pid,"message_id":secondDirection["id"]!,"expected_revision":secondDirection["revision"]!,"reason":"Closure constraint is no longer applicable"])
        close["direction_cursor"] = try context(project,task)["direction_cursor"]
        XCTAssertEqual((try call("task_complete",close))["status_category"] as? String,"done")
    }

    func testCompactPacketAndHistoryPagesDoNotLoseLongMessagesOrCorrections() throws {
        let (project,task,worker) = try fixture(),pid = project["id"] as! String
        let original = try call("message_send",["project_id":pid,"task_id":task["id"]!,"body":String(repeating:"a",count:5000)])
        let correction = try call("message_send",["project_id":pid,"task_id":task["id"]!,"body":"Corrected detail","correction_of":original["id"]!])
        for index in 0..<61 { _ = try call("message_send",["project_id":pid,"task_id":task["id"]!,"body":"History \(index)"]) }
        let summary = try context(project,task,worker)
        XCTAssertEqual((summary["messages"] as! [JSON]).count,10);XCTAssertEqual(summary["truncated"] as? Bool,true)
        var seen: [JSON] = [], cursor: String?
        repeat {
            var input: JSON = ["project_id":pid,"task_id":task["id"]!,"detail_level":"full"]
            if let cursor {input["history_cursor"] = cursor}
            let page = try call("task_context",input,worker);seen += page["records"] as! [JSON]
            cursor = (page["has_more_records"] as? Bool == true) ? page["next_history_cursor"] as? String : nil
        } while cursor != nil
        let messages = seen.filter {$0["record_type"] as? String == "message"}
        XCTAssertEqual(messages.count,63);XCTAssertEqual(Set(messages.compactMap {$0["id"] as? String}).count,63)
        XCTAssertEqual(messages.first?["body"] as? String,String(repeating:"a",count:5000))
        XCTAssertEqual(messages[1]["correction_of"] as? String,original["id"] as? String)
        XCTAssertEqual(messages[1]["id"] as? String,correction["id"] as? String)
        let first = try call("history_list",["project_id":pid,"task_id":task["id"]!,"limit":3],worker)
        XCTAssertEqual((first["events"] as! [JSON]).count,3);XCTAssertLessThanOrEqual((first["messages"] as! [JSON]).count,3)
        let second = try call("history_list",["project_id":pid,"task_id":task["id"]!,"limit":3,"cursor":first["next_cursor"]!],worker)
        XCTAssertTrue(Set((first["events"] as! [JSON]).compactMap {$0["id"] as? String}).isDisjoint(with:(second["events"] as! [JSON]).compactMap {$0["id"] as? String}))
    }

    func testCurrentHandlerAndAcceptedChildHaveSeparateDirectionReceipts() throws {
        let (project,task,legacyWorker) = try fixture(),pid = project["id"] as! String
        _ = try call("session_register",["project_id":pid,"session_id":legacyWorker.sessionID!,"provider":"codex","role":"worker","installation":"context-worker","execution_domain":"synthetic-parent-host","workspace":directory.path])
        let parent = Caller(role:"worker",installation:"context-worker",projectIDs:[pid],sessionID:legacyWorker.sessionID,workspace:directory.path,executionDomain:"synthetic-parent-host")
        let childID = UUID().uuidString,observerID = UUID().uuidString,coordinatorID = UUID().uuidString
        for (id,label) in [(childID,"Child"),(observerID,"Context observer"),(coordinatorID,"Context coordinator")] {
            _ = try call("session_register",["project_id":pid,"session_id":id,"provider":"codex","role":"worker","label":label,"installation":"child-installation-"+id,"execution_domain":"synthetic-child-host-"+id,"workspace":directory.path])
        }
        let child = Caller(role:"worker",installation:"child-installation-"+childID,projectIDs:[pid],sessionID:childID,workspace:directory.path,executionDomain:"synthetic-child-host-"+childID)
        let observer = Caller(role:"worker",installation:"child-installation-"+observerID,projectIDs:[pid],sessionID:observerID,workspace:directory.path,executionDomain:"synthetic-child-host-"+observerID)
        _ = try call("session_attach_task",["project_id":pid,"task_id":task["id"]!],observer)
        // CL-248: the Triage orchestrator replaces the retired coordinator_session_id.
        let coordinator = Caller(role:"worker",installation:"child-installation-"+coordinatorID,projectIDs:[pid],sessionID:coordinatorID,workspace:directory.path,executionDomain:"synthetic-child-host-"+coordinatorID)
        let triage = try call("triage_orchestrate",["project_id":pid,"action":"start"],coordinator)
        _ = try call("group_membership",["project_id":pid,"group_id":triage["id"]!,"expected_revision":triage["revision"]!,"task_id":task["id"]!,"action":"add"],coordinator)
        let attempt = try claim(project,task,parent)
        let offer = try call("work_delegate",["project_id":pid,"attempt_id":attempt["id"]!,"claim_token":attempt["claim_token"]!,"child_session_id":childID,"file_scopes":[],"lane_scopes":[],"brief":"Inspect only this ticket context"],parent)
        _ = try call("work_child_accept",["project_id":pid,"delegation_id":offer["id"]!],child)
        let note = try call("message_send",["project_id":pid,"task_id":task["id"]!,"body":"Retain the current constraints","requires_action":true])
        let receipts = note["deliveries"] as! [JSON]
        XCTAssertEqual(Set(receipts.compactMap {$0["recipient_session_id"] as? String}),Set([parent.sessionID!,childID,coordinatorID]))
        XCTAssertEqual(Set(receipts.compactMap {$0["recipient_role"] as? String}),Set(["handler","registered_child","triage_orchestrator"]))
        let childReceipt = receipts.first {$0["recipient_session_id"] as? String == childID}!
        _ = try call("message_ack",["project_id":pid,"delivery_id":childReceipt["id"]!,"stage":"acknowledged"],child)
        let parentInbox = try call("session_inbox",["project_id":pid],parent)["deliveries"] as! [JSON]
        XCTAssertEqual(parentInbox.first?["state"] as? String,"queued")
        XCTAssertEqual((try context(project,task,parent)["counts"] as! JSON)["unresolved_directions"] as? Int,1)
    }
}
