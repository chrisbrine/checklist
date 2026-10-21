import XCTest
import GRDB
@testable import ChecklistCore

extension CoreTests {
    func triage(_ project: JSON,_ name: String = "Current handling",phase: String = "implementation") throws -> JSON { try call("triage_create",["project_id":project["id"]!,"name":name,"phase":phase,"purpose":"Handle this selected batch together"]) }
    func currentTriage(_ project: JSON,_ group: JSON) throws -> JSON { try (call("triage_list",["project_id":project["id"]!])["groups"] as! [JSON]).first {$0["id"] as? String == group["id"] as? String}! }
    @discardableResult func addTriage(_ project: JSON,_ group: JSON,_ task: JSON,_ milestone: String = "manual") throws -> JSON {
        let current = try currentTriage(project,group)
        return try call("group_membership",["project_id":project["id"]!,"group_id":group["id"]!,"expected_revision":current["revision"]!,"task_id":task["id"]!,"action":"add","exit_milestone":milestone])
    }
    func triageInput(_ project: JSON,_ group: JSON,_ selector: JSON = ["action":"defer"]) throws -> JSON {
        let current = try currentTriage(project,group);var revisions: JSON = [:],directions: JSON = [:]
        for id in strings(current,"task_ids") { revisions[id] = try call("task_get",["project_id":project["id"]!,"task_id":id])["revision"]!;directions[id] = try call("task_context",["project_id":project["id"]!,"task_id":id])["direction_cursor"]! }
        return ["project_id":project["id"]!,"triage_id":group["id"]!,"expected_revision":current["revision"]!,"expected_member_revisions":revisions,"expected_direction_cursors":directions].merging(selector) {_,new in new}
    }
    func assertEmptyTriage(_ project: JSON,_ group: JSON,file: StaticString = #filePath,line: UInt = #line) throws { XCTAssertTrue(strings(try currentTriage(project,group),"task_ids").isEmpty,file:file,line:line) }
    func submitTriageArtifact(_ project: JSON,_ task: JSON,_ claim: JSON) throws -> JSON {
        let path = directory.appendingPathComponent(UUID().uuidString+".txt");try Data("Exact result".utf8).write(to:path)
        let artifact = try call("attachment_add",["project_id":project["id"]!,"task_id":task["id"]!,"path":path.path])
        return try call("work_submit",["project_id":project["id"]!,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"acceptance_revision":1,"evidence_manifest":["artifact_refs":[["artifact_id":artifact["id"]!,"sha256":artifact["sha256"]!]]]])
    }
    func testIndividualSameStatusLeavesAllTriagesButMetadataDoesNot() throws {
        let p = try project();let task = try task(p);let first = try triage(p),second = try triage(p,"Review together")
        var epic = try call("epic_create",["project_id":p["id"]!,"name":"Persistent subsystem","brief":"Keep context"])
        epic = try call("group_membership",["project_id":p["id"]!,"group_id":epic["id"]!,"expected_revision":epic["revision"]!,"task_id":task["id"]!])
        let attached = try call("task_get",["project_id":p["id"]!,"task_id":task["id"]!]);try addTriage(p,first,task);try addTriage(p,second,task,"review_accepted")
        let edited = try call("task_edit",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":attached["revision"]!,"patch":["title":"Updated production brief"]])
        _ = try call("message_send",["project_id":p["id"]!,"task_id":task["id"]!,"body":"Note without changing the handling group"])
        let question = try call("human_request_create",["project_id":p["id"]!,"task_id":task["id"]!,"questions":[["id":"q","type":"text","prompt":"Which reference?","required":true]]])
        _ = try call("human_request_answer",["project_id":p["id"]!,"request_id":question["id"]!,"expected_revision":question["revision"]!,"answers":[["question_id":"q","value":"The blue reference"]]])
        XCTAssertEqual(strings(try currentTriage(p,first),"task_ids"),[task["id"] as! String]);XCTAssertEqual(strings(try currentTriage(p,second),"task_ids"),[task["id"] as! String])
        let marked = try call("task_transition",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":edited["revision"]!,"target_status_id":edited["status_id"]!])
        XCTAssertEqual(marked["status_id"] as? String,edited["status_id"] as? String);XCTAssertEqual(marked["epic_id"] as? String,epic["id"] as? String)
        try assertEmptyTriage(p,first);try assertEmptyTriage(p,second)
        let history = try call("history_list",["project_id":p["id"]!,"task_id":task["id"]!]);XCTAssertEqual((history["events"] as! [JSON]).filter {$0["kind"] as? String == "task_left_triage"}.count,2)
    }
    func testTriageOrdinaryStatusIsAtomicDerivedAndRetainsAllMemberships() throws {
        let p = try project();let first = try task(p,"Input bug"),second = try task(p,"Menu bug");let group = try triage(p),other = try triage(p,"Another current batch")
        let parked = try call("status_create",["project_id":p["id"]!,"name":"Parked · art reference","category":"parked"])
        let marked = try call("task_transition",["project_id":p["id"]!,"task_id":first["id"]!,"expected_revision":first["revision"]!,"target_status_id":parked["id"]!])
        try addTriage(p,group,marked);try addTriage(p,group,second);try addTriage(p,other,marked)
        XCTAssertEqual(try currentTriage(p,group)["status_state"] as? String,"mixed")
        let result = try call("triage_transition",triageInput(p,group,["target_status_id":parked["id"]!]))
        XCTAssertEqual(strings(result,"changed_task_ids"),[second["id"] as! String]);XCTAssertEqual(strings(result,"unchanged_task_ids"),[first["id"] as! String]);XCTAssertFalse(bool(result,"no_op"))
        let current = result["triage"] as! JSON;XCTAssertEqual(current["status_state"] as? String,"uniform");XCTAssertEqual(current["status_id"] as? String,parked["id"] as? String);XCTAssertEqual(strings(current,"task_ids").count,2)
        XCTAssertEqual(strings(try currentTriage(p,other),"task_ids"),[first["id"] as! String])
        let again = try call("triage_transition",triageInput(p,group,["target_status_id":parked["id"]!]))
        XCTAssertTrue(bool(again,"no_op"));XCTAssertEqual(again["reason"] as? String,"already_at_target");XCTAssertEqual((again["triage"] as! JSON)["revision"] as? Int,current["revision"] as? Int)
        let empty = try triage(p,"Empty batch");let noop = try call("triage_transition",triageInput(p,empty))
        XCTAssertTrue(bool(noop,"no_op"));XCTAssertEqual(noop["reason"] as? String,"empty_triage");XCTAssertEqual((noop["triage"] as! JSON)["status_state"] as? String,"empty")
        let defaultMember = try call("group_membership",["project_id":p["id"]!,"group_id":empty["id"]!,"expected_revision":empty["revision"]!,"task_id":first["id"]!]);XCTAssertEqual((defaultMember["members"] as! [JSON])[0]["exit_milestone"] as? String,"implementation_submitted")
    }
    func testTriageRejectsStaleMembershipMemberRevisionsScopeAndAssistant() throws {
        let p = try project();let first = try task(p),second = try task(p);let group = try triage(p);try addTriage(p,group,first)
        var input = try triageInput(p,group);try addTriage(p,group,second)
        assertCode("REVISION_CONFLICT") { _ = try self.call("triage_transition",input) }
        input = try triageInput(p,group);input["expected_member_revisions"] = [first["id"] as! String:first["revision"]!]
        assertCode("REVISION_CONFLICT") { _ = try self.call("triage_transition",input) }
        input = try triageInput(p,group);let stale = input
        _ = try call("task_edit",["project_id":p["id"]!,"task_id":first["id"]!,"expected_revision":first["revision"]!,"patch":["brief":"Updated while the batch menu was open"]])
        assertCode("REVISION_CONFLICT") { _ = try self.call("triage_transition",stale) }
        input = try triageInput(p,group);var bad = input;bad["retain_triage"] = true
        let assistant = Caller(role:"assistant",installation:"assistant",projectIDs:[p["id"] as! String],assistantGrants:[p["id"] as! String:fullAssistantPermissions])
        assertCode("FORBIDDEN") { _ = try self.call("triage_transition",bad,assistant) }
        let foreign = try project("Other");let foreignStatus = try call("status_create",["project_id":foreign["id"]!,"name":"Other parked","category":"parked"])
        input.removeValue(forKey:"action");input["target_status_id"] = foreignStatus["id"]!
        assertCode("NOT_FOUND") { _ = try self.call("triage_transition",input) }
        let statuses = try call("taxonomy_get",["project_id":p["id"]!])["statuses"] as! [JSON]
        for category in ["active","review"] { let status = statuses.first {$0["category"] as? String == category}!;let protected = try triageInput(p,group,["target_status_id":status["id"]!]);assertCode("INVALID_TRANSITION") { _ = try self.call("triage_transition",protected) } }
        XCTAssertEqual(strings(try currentTriage(p,group),"task_ids").count,2)
    }
    func testTriageBlockedMemberRollsBackEveryTicketAndHistory() throws {
        let p = try project();let first = try task(p,"Safe to park"),second = try ready(p,task(p,"Claimed by work session"));let claim = try call("work_claim",["project_id":p["id"]!,"task_id":second["id"]!,"expected_revision":second["revision"]!]);let group = try triage(p)
        try addTriage(p,group,first);try addTriage(p,group,second)
        let before = try call("snapshot");let input = try triageInput(p,group)
        XCTAssertThrowsError(try call("triage_transition",input)) { error in let e = error as! CoreError;XCTAssertEqual(e.code,"TRIAGE_TRANSITION_BLOCKED");XCTAssertTrue(e.message.contains(second["key"] as! String));XCTAssertTrue(e.message.contains("Release or recover")) }
        let after = try call("snapshot");for key in ["tasks","groups","events"] { XCTAssertEqual(try jsonString(["rows":before[key]!]),try jsonString(["rows":after[key]!]),key) }
        let context = try call("task_context",["project_id":p["id"]!,"task_id":second["id"]!]);XCTAssertEqual((context["task"] as! JSON)["active_attempt_id"] as? String,claim["id"] as? String)
    }
    func testIndividualWorkflowStatusActionsAlwaysLeaveTriages() throws {
        let p = try project();let task = try ready(p,task(p));let group = try triage(p);try addTriage(p,group,task)
        var claim = try call("work_claim",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!]);try assertEmptyTriage(p,group)
        try addTriage(p,group,task);_ = try call("work_checkpoint",["project_id":p["id"]!,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"progress":"Continue current handling"]);XCTAssertEqual(strings(try currentTriage(p,group),"task_ids").count,1)
        var current = try call("work_release",["project_id":p["id"]!,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"reason":"Hand off safely"]);try assertEmptyTriage(p,group)
        claim = try call("work_claim",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":current["revision"]!]);try addTriage(p,group,task)
        current = try call("work_recover",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":(claim["task"] as! JSON)["revision"]!,"action":"confirm_stopped_revoke","reason":"Owner verified stopped","observation_refs":["synthetic explicit stop receipt"],"file_state_refs":["fixture has no reserved file scopes; no remaining writer"]]);try assertEmptyTriage(p,group)
        claim = try call("work_claim",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":current["revision"]!]);try addTriage(p,group,task)
        let submission = try submitTriageArtifact(p,task,claim);try assertEmptyTriage(p,group)
        let submitted = submission["task"] as! JSON;let rid = strings(submission,"review_request_ids")[0];let reviewGroup = try triage(p,"Review phase",phase:"review");try addTriage(p,reviewGroup,task)
        _ = try call("review_request",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":submitted["revision"]!,"target_manifest_id":submission["manifest_id"]!,"gate":"review"]);try assertEmptyTriage(p,reviewGroup)
        let reviewer = Caller(role:"owner",installation:"independent-review",projectIDs:[])
        let review = try call("work_claim",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":submitted["revision"]!,"phase":"review","review_request_id":rid,"target_manifest_id":submission["manifest_id"]!,"gate":"review"],reviewer)
        try addTriage(p,reviewGroup,task);_ = try call("review_record",["project_id":p["id"]!,"attempt_id":review["id"]!,"claim_token":review["claim_token"]!,"review_request_id":rid,"target_manifest_id":submission["manifest_id"]!,"gate":"review","verdict":"pass"],reviewer);try assertEmptyTriage(p,reviewGroup)
    }
    func testHumanApprovalVerdictLeavesTriagesButUnfinishedAnswerRetainsThem() throws {
        for verdict in ["approved","changes_requested"] {
            let value = try submittedArtifact(gates:["human_approval"]);let p = value.project;let group = try triage(p,phase:"review");try addTriage(p,group,value.task)
            var request = try humanApproval(value)
            request = try call("human_request_answer",try observedGateAnswer(["project_id":p["id"]!,"request_id":request["id"]!,"expected_revision":request["revision"]!,"target_sha256":value.artifact["sha256"]!,"answers":[["question_id":"approve","value":"not_checked"]]], task:value.task))
            XCTAssertEqual(strings(try currentTriage(p,group),"task_ids"),[value.task["id"] as! String])
            _ = try call("human_request_answer",try observedGateAnswer(["project_id":p["id"]!,"request_id":request["id"]!,"expected_revision":request["revision"]!,"target_sha256":value.artifact["sha256"]!,"answers":[["question_id":"approve","value":verdict]]], task:value.task));try assertEmptyTriage(p,group)
        }
    }
    func testTriageDoneHonorsGatesAndRemovesAllTriagesOnlyAfterAtomicSuccess() throws {
        // The project hold override keeps approved tickets in Review for this Triage completion (CL-137).
        let value = try submittedArtifact(gates:["human_approval"],holdPassing:true);let p = value.project;let first = value.task;let second = try ready(p,task(p,"Other completion target"));let claim = try call("work_claim",["project_id":p["id"]!,"task_id":second["id"]!,"expected_revision":second["revision"]!]);_ = try submitTriageArtifact(p,second,claim)
        let request = try humanApproval(value);_ = try call("human_request_answer",try observedGateAnswer(["project_id":p["id"]!,"request_id":request["id"]!,"expected_revision":request["revision"]!,"target_sha256":value.artifact["sha256"]!,"answers":[["question_id":"approve","value":"approved"]]], task:value.task))
        let group = try triage(p,phase:"review"),other = try triage(p,"Also tracked here",phase:"review");try addTriage(p,group,first);try addTriage(p,group,second);try addTriage(p,other,first,"review_accepted")
        var epic = try call("epic_create",["project_id":p["id"]!,"name":"Persistent results"]);epic = try call("group_membership",["project_id":p["id"]!,"group_id":epic["id"]!,"expected_revision":epic["revision"]!,"task_id":first["id"]!])
        let before = try call("snapshot")
        assertCode("TRIAGE_TRANSITION_BLOCKED") { _ = try self.call("triage_transition",self.triageInput(p,group,["action":"complete"])) }
        let after = try call("snapshot");for key in ["tasks","groups","events"] { XCTAssertEqual(try jsonString(["rows":before[key]!]),try jsonString(["rows":after[key]!]),key) }
        let context = try call("task_context",["project_id":p["id"]!,"task_id":second["id"]!]);let artifact = (context["attachments"] as! [JSON])[0]
        let secondRequest = try call("human_request_create",["project_id":p["id"]!,"task_id":second["id"]!,"target_attachment_id":artifact["id"]!,"questions":[["id":"approve","type":"approval","prompt":"Inspect this exact original","required":true]]])
        _ = try call("human_request_answer",try observedGateAnswer(["project_id":p["id"]!,"request_id":secondRequest["id"]!,"expected_revision":secondRequest["revision"]!,"target_sha256":artifact["sha256"]!,"answers":[["question_id":"approve","value":"approved"]]], task:second))
        // The individual approval itself removes the second ticket; deliberately put it back in this new batch.
        try addTriage(p,group,second);try addTriage(p,other,second)
        let done = try call("status_create",["project_id":p["id"]!,"name":"Production accepted","category":"done"])
        let result = try call("triage_transition",triageInput(p,group,["target_status_id":done["id"]!]))
        XCTAssertEqual(Set(strings(result,"completed_task_ids")),[first["id"] as! String,second["id"] as! String]);try assertEmptyTriage(p,group);try assertEmptyTriage(p,other)
        let completed = try call("task_get",["project_id":p["id"]!,"task_id":first["id"]!]);XCTAssertEqual(completed["status_id"] as? String,done["id"] as? String);XCTAssertEqual(completed["epic_id"] as? String,epic["id"] as? String)
    }
    func testWorkerCatalogAndExecutionAllowGroupStatusWithoutRetentionOverride() throws {
        let workspace = directory.appendingPathComponent("group-scope");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let p = try call("project_create",["name":"Scoped batch","key_prefix":"BAT","root_path":workspace.path]);let pid = p["id"] as! String
        let sid = UUID().uuidString;_ = try call("session_register",["project_id":pid,"session_id":sid,"role":"worker","provider":"codex","installation":"group-worker"])
        let worker = Caller(role:"worker",installation:"group-worker",projectIDs:[pid],sessionID:sid,workspace:workspace.path)
        let task = try task(p),group = try triage(p);try addTriage(p,group,task)
        let catalog = try call("tool_catalog",[:],worker)["tools"] as! [JSON];let command = catalog.first {$0["name"] as? String == "triage_transition"}!
        XCTAssertTrue((command["description"] as! String).contains("EVERY"));XCTAssertTrue(strings(command["inputSchema"] as! JSON,"required").contains("expected_member_revisions"))
        var input = try triageInput(p,group);input["retain_triage"] = true
        assertCode("INVALID_INPUT") { _ = try self.call("triage_transition",input,worker) }
        input.removeValue(forKey:"retain_triage");let result = try call("triage_transition",input,worker);XCTAssertEqual(strings((result["triage"] as! JSON),"task_ids"),[task["id"] as! String])
        let marked = try call("task_get",["project_id":pid,"task_id":task["id"]!],worker)
        _ = try call("task_transition",["project_id":pid,"task_id":task["id"]!,"expected_revision":marked["revision"]!,"target_status_id":marked["status_id"]!],worker);try assertEmptyTriage(p,group)
    }
}
