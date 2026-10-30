import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

extension CoreTests {
    func prepareImplementationBatch(_ p: JSON,_ group: JSON,_ tasks: [JSON],_ caller: Caller? = nil,scopes: [[JSON]] = []) throws -> JSON {
        if orchestrateBatchTriages { try ensureOrchestrated(p,group) }
        let current = try currentTriage(p,group)
        let members: [JSON] = try tasks.enumerated().map { index,task in
            let currentTask = try call("task_get",["project_id":p["id"]!,"task_id":task["id"]!],caller)
            return ["task_id":task["id"]!,"expected_revision":currentTask["revision"]!,"file_scopes":scopes.isEmpty ? [] : scopes[index],"lane_scopes":[]]
        }
        return try call("batch_prepare",["project_id":p["id"]!,"triage_id":group["id"]!,"expected_revision":current["revision"]!,"phase":"implementation","tasks":members,"checks":[["label":"Inspect the fixed result"]]],caller)
    }
    func claimFixedBatch(_ p: JSON,_ batch: JSON,_ caller: Caller? = nil,_ command: String? = nil) throws -> JSON {
        try call("batch_claim",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":batch["revision"]!,"policy_revision":batch["policy_revision"]!],caller,command)
    }
    func batchArtifactInput(_ p: JSON,_ claim: JSON) throws -> JSON {
        let task = claim["task"] as! JSON,file = directory.appendingPathComponent(UUID().uuidString+".txt")
        try Data("Immutable batch result".utf8).write(to:file)
        let artifact = try call("attachment_add",["project_id":p["id"]!,"task_id":task["id"]!,"path":file.path])
        return ["attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"acceptance_revision":task["acceptance_revision"]!,"evidence_manifest":["artifact_refs":[["artifact_id":artifact["id"]!,"sha256":artifact["sha256"]!]]]]
    }
    func batchPassingCompletionInput(_ p: JSON,_ batch: JSON,_ caller: Caller? = nil) throws -> JSON {
        let current = try call("batch_get",["project_id":p["id"]!,"batch_id":batch["id"]!],caller)
        var cursors: [String:String] = [:]
        for outcome in current["outcomes"] as? [JSON] ?? [] where bool(outcome,"accepted") && !bool(outcome,"completed") {
            let context = try call("task_context",["project_id":p["id"]!,"task_id":outcome["task_id"]!],caller);cursors[outcome["task_id"] as! String] = context["direction_cursor"] as? String
        }
        return ["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":batch["revision"]!,"expected_direction_cursors":cursors]
    }
    func prepareReviewBatch(_ p: JSON,_ group: JSON,_ tasks: [JSON],_ reviewer: Caller) throws -> JSON {
        if orchestrateBatchTriages { try ensureOrchestrated(p,group) }
        let current = try currentTriage(p,group)
        let members: [JSON] = try tasks.map { task in
            let context = try call("task_context",["project_id":p["id"]!,"task_id":task["id"]!,"detail_level":"full"],reviewer),currentTask = context["task"] as! JSON
            let request = (context["review_requests"] as! [JSON]).last {$0["gate"] as? String == "review" && $0["state"] as? String == "queued"}!
            return ["task_id":task["id"]!,"expected_revision":currentTask["revision"]!,"file_scopes":[],"lane_scopes":[],"review_request_id":request["id"]!,"target_manifest_id":request["manifest_id"]!,"gate":"review"]
        }
        return try call("batch_prepare",["project_id":p["id"]!,"triage_id":group["id"]!,"expected_revision":current["revision"]!,"phase":"review","tasks":members],reviewer)
    }
    // Compare domain effects independently of the command-intent journal.
    func batchClaimState(_ p: JSON,_ batch: JSON) throws -> String {
        let snapshot = try call("snapshot")
        var state: JSON = [:]
        for key in ["tasks","attempts","groups","events"] { state[key] = snapshot[key] }
        state["batch"] = try call("batch_get",["project_id":p["id"]!,"batch_id":batch["id"]!])
        state["dispatches"] = try router.dbQueue.read {try router.records($0,type:"batch_claim",project:(p["id"] as! String))}
        return try jsonString(state)
    }
    func testBatchClaimPolicyInputRefusalsLeavePreparationClaimable() throws {
        orchestrateBatchTriages = true // CL-125 rule 6: claims keep tickets in an orchestrated Triage.
        let invalid: [Any?] = [nil,NSNull(),"1",true,false,1.5,0,-1,NSNumber(value:UInt64.max)]
        for value in invalid {
            let fixture = try preparedPolicyBatch(),p = fixture.project,tasks = fixture.tasks,group = fixture.group,batch = fixture.batch
            let before = try batchClaimState(p,batch)
            var input: JSON = ["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":batch["revision"]!]
            input["policy_revision"] = value
            let rejectedCommand = UUID().uuidString
            XCTAssertThrowsError(try call("batch_claim",input,nil,rejectedCommand)) { error in
                XCTAssertEqual((error as? CoreError)?.code,"INVALID_INPUT")
                XCTAssertTrue(error.localizedDescription.contains("policy_revision"))
                XCTAssertTrue(error.localizedDescription.contains("batch_prepare"))
                XCTAssertFalse(error.localizedDescription.contains("Prepare a new batch"))
            }
            XCTAssertEqual(try batchClaimState(p,batch),before)
            // Changed input gets a fresh ID; the original fixed preparation is reused.
            let command = UUID().uuidString,claimed = try claimFixedBatch(p,batch,nil,command)
            XCTAssertNotEqual(command,rejectedCommand)
            XCTAssertEqual((claimed["claims"] as! [JSON]).count,2)
            XCTAssertEqual(strings(try currentTriage(p,group),"task_ids"),tasks.map {$0["id"] as! String})
            XCTAssertEqual(try call("policy_get",["project_id":p["id"]!])["revision"] as? Int,batch["policy_revision"] as? Int)
            // An identical unknown-outcome retry retains that ID and original attempts.
            let replay = try claimFixedBatch(p,batch,nil,command)
            XCTAssertEqual((replay["claims"] as! [JSON]).compactMap {$0["id"] as? String},(claimed["claims"] as! [JSON]).compactMap {$0["id"] as? String})
        }
    }
    func testBatchClaimPolicyMismatchAndChangedProjectAreAtomic() throws {
        for changedProject in [false,true] {
            for sendsNewRevision in [false,true] {
                let fixture = try preparedPolicyBatch(),p = fixture.project,batch = fixture.batch,oldRevision = int(batch,"policy_revision")
                if changedProject { _ = try call("policy_apply",["project_id":p["id"]!,"expected_revision":p["revision"]!,"policy":["required_gates":[]]]) }
                let before = try batchClaimState(p,batch)
                let supplied = changedProject && !sendsNewRevision ? oldRevision : oldRevision+1
                XCTAssertThrowsError(try call("batch_claim",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":batch["revision"]!,"policy_revision":supplied])) { error in
                    XCTAssertEqual((error as? CoreError)?.code,"POLICY_CHANGED")
                    XCTAssertTrue(error.localizedDescription.contains(changedProject ? "current project policy" : "supplied policy_revision"))
                    if !changedProject {XCTAssertFalse(error.localizedDescription.contains("Prepare a new batch"))}
                }
                XCTAssertEqual(try batchClaimState(p,batch),before)
            }
        }
    }
    func testBatchClaimCatalogRequiresPreparedPositivePolicyRevision() throws {
        let worker = Caller(role:"worker",installation:"batch-catalog",projectIDs:[])
        let tools = try call("tool_catalog",[:],worker)["tools"] as! [JSON]
        let tool = tools.first {$0["name"] as? String == "batch_claim"}!,schema = tool["inputSchema"] as! JSON
        XCTAssertTrue(strings(schema,"required").contains("policy_revision"))
        let spec = (schema["properties"] as! JSON)["policy_revision"] as! JSON
        XCTAssertEqual(spec["type"] as? String,"integer");XCTAssertEqual(spec["minimum"] as? Int,1);XCTAssertEqual(spec["maximum"] as? Int,Int.max)
        let description = tool["description"] as! String
        for text in ["batch_prepare","INVALID_INPUT","new command_id","original command_id","identical input"] {XCTAssertTrue(description.contains(text))}
        for value: Any? in [nil,NSNull(),"1",true,1.5] {
            var input: JSON = ["project_id":"catalog-project","batch_id":"catalog-batch","expected_revision":1,"command_id":UUID().uuidString];input["policy_revision"] = value
            assertCode("INVALID_INPUT") {try self.router.validateInput("batch_claim",input,worker)}
        }
        let workSchema = tools.first {$0["name"] as? String == "work_claim"}!["inputSchema"] as! JSON
        XCTAssertFalse(strings(workSchema,"required").contains("policy_revision"))
    }
    func testBatchSnapshotSurvivesLiveMembershipEditsAndKeepsExclusiveClaims() throws {
        orchestrateBatchTriages = true // CL-125 rule 6: claims keep tickets in an orchestrated Triage.
        let p = try project(),first = try ready(p,task(p,"One")),second = try ready(p,task(p,"Two")),later = try ready(p,task(p,"Later")),group = try triage(p)
        try addTriage(p,group,first);try addTriage(p,group,second)
        let batch = try prepareImplementationBatch(p,group,[first,second]),frozen = batch["members"] as! [JSON]
        let current = try currentTriage(p,group)
        _ = try call("group_membership",["project_id":p["id"]!,"group_id":group["id"]!,"expected_revision":current["revision"]!,"task_id":second["id"]!,"action":"remove"])
        try addTriage(p,group,later)
        let claimed = try claimFixedBatch(p,batch),claims = claimed["claims"] as! [JSON]
        XCTAssertEqual(Set(claims.compactMap {($0["task"] as? JSON)?["id"] as? String}),[first["id"] as! String,second["id"] as! String])
        XCTAssertNil(try call("task_get",["project_id":p["id"]!,"task_id":later["id"]!])["active_attempt_id"])
        XCTAssertEqual(Set(strings(try currentTriage(p,group),"task_ids")),[first["id"] as! String,later["id"] as! String])
        let after = try call("batch_get",["project_id":p["id"]!,"batch_id":batch["id"]!])
        XCTAssertEqual(try jsonString(frozen),try jsonString(after["members"]!));XCTAssertEqual(after["triage_revision"] as? Int,batch["triage_revision"] as? Int)
        let history = try currentTriage(p,group)["membership_history"] as! [JSON]
        let old = history.first {$0["task_id"] as? String == second["id"] as? String}!
        XCTAssertNotNil(old["originating_triage_revision"]);XCTAssertEqual((old["exit"] as? JSON)?["reason"] as? String,"removed")
        assertCode("CLAIM_CONFLICT") { _ = try self.claimFixedBatch(p,batch) }
    }
    func testBatchClaimRejectsStaleMemberWithoutPartialClaimsOrHistory() throws {
        let p = try project(),first = try ready(p,task(p)),second = try ready(p,task(p)),group = try triage(p)
        try addTriage(p,group,first);try addTriage(p,group,second);let batch = try prepareImplementationBatch(p,group,[first,second])
        _ = try call("task_edit",["project_id":p["id"]!,"task_id":second["id"]!,"expected_revision":second["revision"]!,"patch":["brief":"Changed after preparation"]])
        let before = try call("snapshot")
        assertCode("REVISION_CONFLICT") { _ = try self.claimFixedBatch(p,batch) }
        let after = try call("snapshot")
        for key in ["tasks","attempts","groups","events"] { XCTAssertEqual(try jsonString(before[key]!),try jsonString(after[key]!)) }
    }
    func testBatchClaimLostReplyRotatesAllTokensWithoutPersistingPlaintext() throws {
        let p = try project(),first = try ready(p,task(p)),second = try ready(p,task(p)),group = try triage(p)
        try addTriage(p,group,first);try addTriage(p,group,second)
        let batch = try prepareImplementationBatch(p,group,[first,second]),command = UUID().uuidString,original = try claimFixedBatch(p,batch,nil,command),replayed = try claimFixedBatch(p,batch,nil,command)
        let oldClaims = original["claims"] as! [JSON],claims = replayed["claims"] as! [JSON]
        XCTAssertEqual(oldClaims.compactMap {$0["id"] as? String},claims.compactMap {$0["id"] as? String})
        for index in claims.indices {
            XCTAssertNotEqual(claims[index]["claim_token"] as? String,oldClaims[index]["claim_token"] as? String)
            _ = try call("work_checkpoint",["project_id":p["id"]!,"attempt_id":claims[index]["id"]!,"claim_token":claims[index]["claim_token"]!,"progress":"Recovered original atomic batch"])
        }
        let durable = try router.dbQueue.read {try String.fetchOne($0,sql:"SELECT result FROM commands WHERE command_id=?",arguments:[command])!}
        XCTAssertFalse(durable.contains("claim_token"))
    }
    func testBatchSubmissionRequiresWholeSetAndRollsBackAnyInvalidMember() throws {
        let p = try project(),first = try ready(p,task(p)),second = try ready(p,task(p)),group = try triage(p)
        try addTriage(p,group,first);try addTriage(p,group,second)
        let batch = try prepareImplementationBatch(p,group,[first,second]),claims = try claimFixedBatch(p,batch)["claims"] as! [JSON]
        let firstInput = try batchArtifactInput(p,claims[0]);var secondInput = try batchArtifactInput(p,claims[1]);secondInput["acceptance_revision"] = 999
        let before = try call("snapshot")
        assertCode("REVISION_CONFLICT") { _ = try self.call("batch_submit",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"members":[firstInput]]) }
        assertCode("EVIDENCE_STALE") { _ = try self.call("batch_submit",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"members":[firstInput,secondInput]]) }
        let after = try call("snapshot");for key in ["tasks","attempts","groups","events","manifests"] { XCTAssertEqual(try jsonString(before[key]!),try jsonString(after[key]!)) }
        secondInput["acceptance_revision"] = 1
        _ = try call("batch_submit",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"members":[firstInput,secondInput]])
        try assertEmptyTriage(p,group)
    }
    func testBatchPassCompletesIndependentlyAndOnlyFailedTicketIsRetriaged() throws {
        let p = try project(),first = try ready(p,task(p,"Pass")),second = try ready(p,task(p,"Needs fix")),group = try triage(p)
        try addTriage(p,group,first);try addTriage(p,group,second)
        let batch = try prepareImplementationBatch(p,group,[first,second]),claims = try claimFixedBatch(p,batch)["claims"] as! [JSON],inputs = try claims.map {try batchArtifactInput(p,$0)}
        let submitted = try call("batch_submit",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"members":inputs])
        XCTAssertEqual((submitted["results"] as! [JSON]).first?["title"] as? String,"Pass")
        XCTAssertEqual(submitted["triage_key"] as? String,group["key"] as? String)
        let reviewGroup = try triage(p,"Independent review phase",phase:"review");try addTriage(p,reviewGroup,first);try addTriage(p,reviewGroup,second)
        let reviewer = Caller(role:"owner",installation:"independent-batch-review",projectIDs:[]),reviewBatch = try prepareReviewBatch(p,reviewGroup,[first,second],reviewer),reviews = try claimFixedBatch(p,reviewBatch,reviewer)["claims"] as! [JSON]
        let verdicts: [JSON] = reviews.enumerated().map { index,review in
            var input: JSON = ["attempt_id":review["id"]!,"claim_token":review["claim_token"]!,"review_request_id":review["review_request_id"]!,"target_manifest_id":review["manifest_id"]!,"gate":"review","verdict":index == 0 ? "pass" : "reject"]
            if index == 1 { input["findings"] = [["client_ref":"broken","description":"Second result still fails its stated outcome"]] };return input
        }
        let reviewed = try call("batch_review_record",["project_id":p["id"]!,"batch_id":reviewBatch["id"]!,"expected_revision":1,"members":verdicts],reviewer)
        XCTAssertEqual((reviewed["results"] as! [JSON]).first?["key"] as? String,first["key"] as? String)
        XCTAssertEqual((reviewed["results"] as! [JSON]).first?["title"] as? String,"Pass")
        // The passing review itself marks its ticket Done (CL-137); nothing is left for batch completion.
        XCTAssertEqual(try call("task_get",["project_id":p["id"]!,"task_id":first["id"]!])["status_category"] as? String,"done")
        let result = try call("batch_complete_passing",batchPassingCompletionInput(p,batch))
        XCTAssertEqual(strings(result,"completed_task_ids"),[])
        let retry = try call("batch_retriage_remaining",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1])
        XCTAssertEqual(strings(retry,"task_ids"),[second["id"] as! String]);XCTAssertEqual(strings(retry["triage"] as! JSON,"task_ids"),[second["id"] as! String])
        try assertEmptyTriage(p,group);try assertEmptyTriage(p,reviewGroup)
    }
    func testPhaseCompletionOverridesLegacyMilestoneAndZeroGateCompletionStaysHonest() throws {
        var p = try project();p = try call("policy_apply",["project_id":p["id"]!,"expected_revision":p["revision"]!,"policy":["required_gates":[]]])
        let task = try ready(p,self.task(p)),group = try triage(p);try addTriage(p,group,task,"review_accepted")
        let batch = try prepareImplementationBatch(p,group,[task]),claims = try claimFixedBatch(p,batch)["claims"] as! [JSON]
        _ = try call("batch_submit",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"members":[try batchArtifactInput(p,claims[0])]])
        try assertEmptyTriage(p,group)
        let reviewGroup = try triage(p,"Zero-gate review handling",phase:"review");try addTriage(p,reviewGroup,task,"review_accepted")
        assertCode("DIRECTION_CURSOR_REQUIRED") { _ = try self.call("batch_complete_passing",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1]) }
        _ = try call("batch_complete_passing",batchPassingCompletionInput(p,batch))
        let history = try currentTriage(p,reviewGroup)["membership_history"] as! [JSON]
        XCTAssertEqual((history[0]["exit"] as! JSON)["label"] as? String,"No review required")
        XCTAssertFalse(bool(try currentTriage(p,group),"active_navigation"))
    }
    func testArchivedTriagePreservesTicketsAndCannotPrepareNewWork() throws {
        let p = try project(),task = try ready(p,self.task(p)),group = try triage(p);try addTriage(p,group,task)
        let current = try currentTriage(p,group),archived = try call("triage_edit",["project_id":p["id"]!,"group_id":group["id"]!,"expected_revision":current["revision"]!,"archived":true])
        XCTAssertFalse(bool(archived,"active_navigation"));XCTAssertEqual(strings(archived,"task_ids"),[task["id"] as! String])
        XCTAssertFalse(bool(try call("task_get",["project_id":p["id"]!,"task_id":task["id"]!]),"archived"))
        assertCode("INVALID_INPUT") { _ = try self.prepareImplementationBatch(p,group,[task]) }
    }
    func testTaskInTwoPreparedBatchesStillHasOnlyOneExclusiveClaim() throws {
        orchestrateBatchTriages = true // CL-125 rule 6: claims keep tickets in an orchestrated Triage.
        // CL-125 rule 4: a ticket is in one Triage, so both preparations come from that Triage.
        let p = try project(),task = try ready(p,self.task(p)),first = try triage(p,"First")
        try addTriage(p,first,task)
        let firstBatch = try prepareImplementationBatch(p,first,[task]),secondBatch = try prepareImplementationBatch(p,first,[task]),claim = try claimFixedBatch(p,firstBatch)
        assertCode("REVISION_CONFLICT") { _ = try self.claimFixedBatch(p,secondBatch) }
        let attempts = try call("snapshot")["attempts"] as! [JSON]
        XCTAssertEqual(attempts.filter {$0["state"] as? String == "active"}.count,1)
        XCTAssertEqual(try call("task_get",["project_id":p["id"]!,"task_id":task["id"]!])["active_attempt_id"] as? String,(claim["claims"] as! [JSON])[0]["id"] as? String)
        XCTAssertEqual(strings(try currentTriage(p,first),"task_ids").count,1)
    }
    func testReviewBatchPinsRequestRevisionAndImmutableManifestDigest() throws {
        let value = try submittedArtifact(),p = value.project,group = try triage(p,phase:"review"),reviewer = Caller(role:"owner",installation:"frozen-request-review",projectIDs:[])
        try addTriage(p,group,value.task)
        let batch = try prepareReviewBatch(p,group,[value.task],reviewer),member = (batch["members"] as! [JSON])[0]
        try router.dbQueue.write { db in
            var request = try router.scoped(db,member["review_request_id"] as! String,p["id"] as! String,type:"review_request");request = router.revised(request);try router.save(db,request,type:"review_request")
        }
        assertCode("REVISION_CONFLICT") { _ = try self.claimFixedBatch(p,batch,reviewer) }
        let newBatch = try prepareReviewBatch(p,group,[value.task],reviewer)
        try router.dbQueue.write { db in
            var manifest = try router.scoped(db,value.submission["manifest_id"] as! String,p["id"] as! String,type:"manifest");manifest["digest"] = "corrupted";try router.save(db,manifest,type:"manifest")
        }
        assertCode("REVIEW_TARGET_MISMATCH") { _ = try self.claimFixedBatch(p,newBatch,reviewer) }
        XCTAssertNil(try call("task_get",["project_id":p["id"]!,"task_id":value.task["id"]!])["active_attempt_id"])
    }
    func testExplicitProjectBatchHoldLeavesPassesAcceptedWithoutRetriagingThem() throws {
        var p = try project();p = try call("policy_apply",["project_id":p["id"]!,"expected_revision":p["revision"]!,"policy":["required_gates":["review"],"review_batch_policy":"hold_passing_for_batch"]])
        let first = try ready(p,task(p,"Pass held by project")),second = try ready(p,task(p,"Failed")),group = try triage(p)
        try addTriage(p,group,first);try addTriage(p,group,second)
        let batch = try prepareImplementationBatch(p,group,[first,second]),claims = try claimFixedBatch(p,batch)["claims"] as! [JSON]
        _ = try call("batch_submit",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"members":try claims.map {try batchArtifactInput(p,$0)}])
        let reviewGroup = try triage(p,"Review under hold policy",phase:"review");try addTriage(p,reviewGroup,first);try addTriage(p,reviewGroup,second)
        let reviewer = Caller(role:"owner",installation:"hold-policy-review",projectIDs:[]),reviewBatch = try prepareReviewBatch(p,reviewGroup,[first,second],reviewer),reviewClaims = try claimFixedBatch(p,reviewBatch,reviewer)["claims"] as! [JSON]
        let verdicts: [JSON] = reviewClaims.enumerated().map { index,claim in ["attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"review_request_id":claim["review_request_id"]!,"target_manifest_id":claim["manifest_id"]!,"gate":"review","verdict":index == 0 ? "pass" : "reject"] }
        _ = try call("batch_review_record",["project_id":p["id"]!,"batch_id":reviewBatch["id"]!,"expected_revision":1,"members":verdicts],reviewer)
        let result = try call("batch_complete_passing",batchPassingCompletionInput(p,batch))
        XCTAssertTrue(strings(result,"completed_task_ids").isEmpty);XCTAssertEqual(strings(result,"held_task_ids"),[first["id"] as! String])
        let retry = try call("batch_retriage_remaining",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1])
        XCTAssertEqual(strings(retry,"task_ids"),[second["id"] as! String])
        XCTAssertEqual(try call("task_get",["project_id":p["id"]!,"task_id":first["id"]!])["status_category"] as? String,"review")
    }
    func testBatchCompletionDoesNotRefreshPastAnUnseenOwnerDirection() throws {
        var p = try project();p = try call("policy_apply",["project_id":p["id"]!,"expected_revision":p["revision"]!,"policy":["required_gates":[]]])
        let task = try ready(p,self.task(p)),group = try triage(p);try addTriage(p,group,task)
        let batch = try prepareImplementationBatch(p,group,[task]),claims = try claimFixedBatch(p,batch)["claims"] as! [JSON]
        _ = try call("batch_submit",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"members":[try batchArtifactInput(p,claims[0])]])
        let observed = try batchPassingCompletionInput(p,batch)
        _ = try call("message_send",["project_id":p["id"]!,"task_id":task["id"]!,"body":"Check the new owner constraint before closing.","requires_action":true])
        let result = try call("batch_complete_passing",observed)
        XCTAssertTrue(strings(result,"completed_task_ids").isEmpty);XCTAssertEqual((result["blockers"] as! [JSON])[0]["code"] as? String,"USER_DIRECTION_PENDING")
        XCTAssertNotEqual(try call("task_get",["project_id":p["id"]!,"task_id":task["id"]!])["status_category"] as? String,"done")
    }
    func testCompletedSourceBatchMemberStaysDoneWhenRejectedSiblingChangesSource() throws {
        // A fresh owned normal-path fixture avoids /var→/private/var aliasing;
        // it never writes immutable source captures or any real enrolled store.
        router = nil;try FileManager.default.removeItem(at:directory)
        let parent = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first!.appendingPathComponent("ChecklistSyntheticTests")
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        guard parent.path == parent.resolvingSymlinksInPath().path else {throw XCTSkip("A symlink-free fixture parent is required")}
        directory = parent.appendingPathComponent("batch-source-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        router = try TestStore.router(root:directory.appendingPathComponent("service"))
        let workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        try Data("first source".utf8).write(to:workspace.appendingPathComponent("a.txt"))
        try Data("second source".utf8).write(to:workspace.appendingPathComponent("b.txt"))
        let p = try call("project_create",["name":"Source batch","key_prefix":"SB","root_path":workspace.path])
        let first = try ready(p,task(p,"Pass")),second = try ready(p,task(p,"Needs fix")),group = try triage(p)
        try addTriage(p,group,first);try addTriage(p,group,second)
        let batch = try prepareImplementationBatch(p,group,[first,second],scopes:[[["path":"a.txt","access":"write"]],[["path":"b.txt","access":"write"]]])
        let claims = try claimFixedBatch(p,batch)["claims"] as! [JSON]
        let inputs: [JSON] = claims.map {claim in
            ["attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"acceptance_revision":1,"evidence_manifest":["kind":"source","source_capture":JSON()]]
        }
        _ = try call("batch_submit",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"members":inputs])
        let reviewGroup = try triage(p,"Independent review phase",phase:"review");try addTriage(p,reviewGroup,first);try addTriage(p,reviewGroup,second)
        let reviewer = Caller(role:"owner",installation:"independent-batch-review",projectIDs:[]),reviewBatch = try prepareReviewBatch(p,reviewGroup,[first,second],reviewer),reviews = try claimFixedBatch(p,reviewBatch,reviewer)["claims"] as! [JSON]
        let verdicts: [JSON] = reviews.enumerated().map { index,review in
            var input: JSON = ["attempt_id":review["id"]!,"claim_token":review["claim_token"]!,"review_request_id":review["review_request_id"]!,"target_manifest_id":review["manifest_id"]!,"gate":"review","verdict":index == 0 ? "pass" : "reject"]
            if index == 1 { input["findings"] = [["client_ref":"broken","description":"Second result still fails its stated outcome"]] };return input
        }
        _ = try call("batch_review_record",["project_id":p["id"]!,"batch_id":reviewBatch["id"]!,"expected_revision":1,"members":verdicts],reviewer)
        // The passing review itself marks its ticket Done (CL-137); nothing is left for batch completion.
        XCTAssertEqual(try call("task_get",["project_id":p["id"]!,"task_id":first["id"]!])["status_category"] as? String,"done")
        let result = try call("batch_complete_passing",batchPassingCompletionInput(p,batch))
        XCTAssertEqual(strings(result,"completed_task_ids"),[])
        try Data("rework changes the shared captured tree".utf8).write(to:workspace.appendingPathComponent("b.txt"))
        let changed = try call("batch_get",["project_id":p["id"]!,"batch_id":batch["id"]!])
        let completed = (changed["outcomes"] as! [JSON]).first {$0["task_id"] as? String == first["id"] as? String}!
        XCTAssertEqual(completed["state"] as? String,"completed","Unrelated sibling changes preserve scoped target freshness")
        XCTAssertEqual(completed["accepted"] as? Bool,true)
        XCTAssertEqual(completed["completed"] as? Bool,true,"A sibling’s rework must not reopen a completed ticket")
        let retry = try call("batch_retriage_remaining",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1])
        XCTAssertEqual(strings(retry,"task_ids"),[second["id"] as! String]);XCTAssertEqual(strings(retry["triage"] as! JSON,"task_ids"),[second["id"] as! String])
        try assertEmptyTriage(p,group);try assertEmptyTriage(p,reviewGroup)
    }

    func testBatchOnlyReviewerSideBlockedRetainsTriages() throws {
        orchestrateBatchTriages = true // CL-125 rule 6: claims keep tickets in an orchestrated Triage.
        for kind in ["blocked","not_run","evidence_missing","implementation_blocked"] {
            let verdict = kind == "implementation_blocked" ? "blocked" : kind
            let returned = kind != "blocked"
            for batched in [true,false] {
                let value = try preparedSubmittedArtifact(),p = value.project,group = try triage(p,phase:"review")
                try addTriage(p,group,value.task)
                let reviewer = Caller(role:"owner",installation:"non-final-"+verdict,projectIDs:[]),batch = try prepareReviewBatch(p,group,[value.task],reviewer)
                let claim = (try claimFixedBatch(p,batch,reviewer)["claims"] as! [JSON])[0]
                var input: JSON = ["attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"review_request_id":claim["review_request_id"]!,"target_manifest_id":claim["manifest_id"]!,"gate":"review","verdict":verdict]
                if returned { input["reason"] = "The selected check needs its inputs" }
                if kind == "implementation_blocked" { input["blocked_on"] = "implementation" }
                if verdict == "not_run" { input["check"] = "Inspect result" }
                if batched { _ = try call("batch_review_record",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"members":[input]],reviewer) }
                else { input["project_id"] = p["id"];_ = try call("review_record",input,reviewer) }
                // CL-125 rules 8 and 10: every verdict keeps the ticket in its orchestrated Triage; no other return Triage is recorded.
                XCTAssertEqual(strings(try currentTriage(p,group),"task_ids"),[value.task["id"] as! String],kind)
                let request = try router.dbQueue.read {try router.record($0,claim["review_request_id"] as! String,type:"review_request")}
                XCTAssertEqual(request["state"] as? String,returned ? "returned" : "queued")
                let task = try call("task_get",["project_id":p["id"]!,"task_id":value.task["id"]!])
                XCTAssertNil(task["active_attempt_id"],"Owner-only submissions have no native implementing holder")
                XCTAssertEqual(task["status_category"] as? String,returned ? "queued" : "review")
                let history = try call("history_list",["project_id":p["id"]!,"task_id":value.task["id"]!])
                let departures = (history["events"] as! [JSON]).filter {$0["kind"] as? String == "task_left_triage"}
                XCTAssertEqual(departures.count,0,kind)
            }
        }
    }
    func testBatchPartialReleaseKeepsOtherClaimAndSubmitsOnlyLiveMembers() throws {
        orchestrateBatchTriages = true // CL-125 rule 6: claims keep tickets in an orchestrated Triage.
        let p = try project(),first = try ready(p,task(p,"Release")),second = try ready(p,task(p,"Continue")),group = try triage(p)
        try addTriage(p,group,first);try addTriage(p,group,second)
        let batch = try prepareImplementationBatch(p,group,[first,second]),claims = try claimFixedBatch(p,batch)["claims"] as! [JSON]
        let beforeOther = try call("task_get",["project_id":p["id"]!,"task_id":second["id"]!]),beforeClaim = try router.dbQueue.read {try router.record($0,claims[1]["id"] as! String,type:"attempt")}
        let result = try call("batch_release",["project_id":p["id"]!,"batch_id":batch["id"]!,"members":[["attempt_id":claims[0]["id"]!,"claim_token":claims[0]["claim_token"]!]],"reason":"Continue in a later pass"])
        XCTAssertEqual(strings(result,"released_task_ids"),[first["id"] as! String]);XCTAssertEqual(int(result["triage_effect"] as! JSON,"removed_count"),0)
        XCTAssertEqual(try jsonString(beforeOther),try jsonString(call("task_get",["project_id":p["id"]!,"task_id":second["id"]!])))
        XCTAssertEqual(try jsonString(beforeClaim),try router.dbQueue.read {try jsonString(router.record($0,claims[1]["id"] as! String,type:"attempt"))})
        let released = try router.dbQueue.read {try router.record($0,claims[0]["id"] as! String,type:"attempt")}
        XCTAssertEqual(released["state"] as? String,"released");XCTAssertEqual(released["reason"] as? String,"Continue in a later pass")
        XCTAssertEqual(try call("task_get",["project_id":p["id"]!,"task_id":first["id"]!])["status_category"] as? String,"queued")
        XCTAssertEqual(strings(try currentTriage(p,group),"task_ids").count,2)
        let events = try call("snapshot")["events"] as! [JSON]
        XCTAssertTrue(events.contains {$0["kind"] as? String == "batch_released" && ($0["data"] as? JSON)?["reason"] as? String == "Continue in a later pass"})
        XCTAssertTrue(events.contains {$0["kind"] as? String == "work_released" && $0["entity_id"] as? String == first["id"] as? String && ($0["data"] as? JSON)?["reason"] as? String == "Continue in a later pass"})
        let input = try batchArtifactInput(p,claims[1])
        assertCode("REVISION_CONFLICT") { _ = try self.call("batch_submit",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"members":[input,input]]) }
        _ = try call("batch_submit",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"members":[input]])
        // CL-125 rule 10: submission keeps the ticket in its orchestrated Triage.
        XCTAssertEqual(Set(strings(try currentTriage(p,group),"task_ids")),[first["id"] as! String,second["id"] as! String])
    }
    func testBatchFullReleaseAndInvalidSelectionsAreAtomic() throws {
        orchestrateBatchTriages = true // CL-125 rule 6: claims keep tickets in an orchestrated Triage.
        let p = try project(),tasks = try [ready(p,task(p)),ready(p,task(p))],group = try triage(p)
        for task in tasks { try addTriage(p,group,task) }
        let batch = try prepareImplementationBatch(p,group,tasks),claims = try claimFixedBatch(p,batch)["claims"] as! [JSON]
        let foreignTask = try ready(p,task(p)),foreignGroup = try triage(p,"Other batch");try addTriage(p,foreignGroup,foreignTask)
        let foreignBatch = try prepareImplementationBatch(p,foreignGroup,[foreignTask]),foreign = (try claimFixedBatch(p,foreignBatch)["claims"] as! [JSON])[0]
        let inputs: [JSON] = claims.map {["attempt_id":$0["id"]!,"claim_token":$0["claim_token"]!]}
        let before = try call("snapshot")
        assertCode("INVALID_INPUT") { _ = try self.call("batch_release",["project_id":p["id"]!,"batch_id":batch["id"]!,"members":inputs,"reason":"  "]) }
        assertCode("STALE_CLAIM") { _ = try self.call("batch_release",["project_id":p["id"]!,"batch_id":batch["id"]!,"members":[inputs[0],["attempt_id":foreign["id"]!,"claim_token":foreign["claim_token"]!]],"reason":"Wrong batch"]) }
        assertCode("INVALID_INPUT") { _ = try self.call("batch_release",["project_id":p["id"]!,"batch_id":batch["id"]!,"members":[inputs[0],inputs[0]],"reason":"Duplicate"]) }
        let after = try call("snapshot");for key in ["tasks","attempts","groups","events"] {XCTAssertEqual(try jsonString(before[key]!),try jsonString(after[key]!))}
        _ = try call("batch_release",["project_id":p["id"]!,"batch_id":batch["id"]!,"members":inputs,"reason":"Release full pass"])
        XCTAssertEqual(strings(try currentTriage(p,group),"task_ids").count,2)
        for task in tasks { let current = try call("task_get",["project_id":p["id"]!,"task_id":task["id"]!]);XCTAssertNil(current["active_attempt_id"]);XCTAssertEqual(current["status_category"] as? String,"queued") }
    }
    func testReviewBatchReleaseKeepsReviewAndRecordsOnlyRemainingLiveVerdict() throws {
        orchestrateBatchTriages = true // CL-125 rule 6: claims keep tickets in an orchestrated Triage.
        let p = try project(),tasks = try [ready(p,task(p)),ready(p,task(p))],implementation = try triage(p)
        for task in tasks {try addTriage(p,implementation,task)}
        let batch = try prepareImplementationBatch(p,implementation,tasks),claims = try claimFixedBatch(p,batch)["claims"] as! [JSON]
        _ = try call("batch_submit",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"members":try claims.map {try batchArtifactInput(p,$0)}])
        let group = try triage(p,phase:"review");for task in tasks {try addTriage(p,group,task)}
        let reviewer = Caller(role:"owner",installation:"partial-review-release",projectIDs:[]),reviewBatch = try prepareReviewBatch(p,group,tasks,reviewer),reviews = try claimFixedBatch(p,reviewBatch,reviewer)["claims"] as! [JSON]
        _ = try call("batch_release",["project_id":p["id"]!,"batch_id":reviewBatch["id"]!,"members":[["attempt_id":reviews[0]["id"]!,"claim_token":reviews[0]["claim_token"]!]],"reason":"Another reviewer can continue"],reviewer)
        XCTAssertEqual(try call("task_get",["project_id":p["id"]!,"task_id":tasks[0]["id"]!])["status_category"] as? String,"review")
        let request = try router.dbQueue.read {try router.record($0,reviews[0]["review_request_id"] as! String,type:"review_request")};XCTAssertEqual(request["state"] as? String,"queued")
        let claim = reviews[1],input: JSON = ["attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"review_request_id":claim["review_request_id"]!,"target_manifest_id":claim["manifest_id"]!,"gate":"review","verdict":"blocked"]
        _ = try call("batch_review_record",["project_id":p["id"]!,"batch_id":reviewBatch["id"]!,"expected_revision":1,"members":[input]],reviewer)
        XCTAssertEqual(strings(try currentTriage(p,group),"task_ids").count,2)
    }

}
