import XCTest
import GRDB
@testable import ChecklistCore

extension CoreTests {
    func triage(_ project: JSON,_ name: String = "Current handling",phase: String = "implementation") throws -> JSON { try call("triage_create",["project_id":project["id"]!,"name":name,"phase":phase,"purpose":"Handle this selected batch together"]) }
    func currentTriage(_ project: JSON,_ group: JSON) throws -> JSON {
        // A plan that empties archives (CL-125 rule 11) and can leave the list; read its stored record then.
        if let listed = (try call("triage_list",["project_id":project["id"]!])["groups"] as! [JSON]).first(where: {$0["id"] as? String == group["id"] as? String}) { return listed }
        return try storedTriage(group)
    }
    func storedTriage(_ group: JSON) throws -> JSON { try router.dbQueue.read { try router.record($0,group["id"] as! String,type:"group") } }
    /// CL-125 rule 6: a synthetic orchestrator conversation starts orchestration of a plan, so claims by sessions that orchestrate nothing keep its tickets.
    @discardableResult func orchestrateTriage(_ project: JSON,_ group: JSON) throws -> Caller {
        let sid = UUID().uuidString,name = "orchestrator-" + String(sid.prefix(8)),pid = project["id"] as! String
        var root = try router.dbQueue.read { try router.record($0,pid,type:"project") }["root_path"] as? String
        if root?.isEmpty ?? true {
            // Synthetic fixture: bind a workspace root so the orchestrator session can connect. Owner calls never check it.
            let folder = directory.appendingPathComponent("orchestrator-root-" + pid,isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);root = folder.path
            try fixtureDomainTransaction { db in var stored = try router.record(db,pid,type:"project");stored["root_path"] = folder.path;try router.save(db,stored,type:"project") }
        }
        var registration: JSON = ["project_id":project["id"]!,"session_id":sid,"provider":"codex","role":"worker","installation":name,"execution_domain":"synthetic:"+name]
        if let root { registration["workspace"] = root }
        _ = try call("session_register",registration)
        let caller = Caller(role:"worker",installation:name,projectIDs:[project["id"] as! String],sessionID:sid,workspace:root,executionDomain:"synthetic:"+name)
        _ = try call("triage_orchestrate",["project_id":project["id"]!,"triage_id":group["id"]!,"expected_revision":try storedTriage(group)["revision"]!,"action":"start"],caller)
        return caller
    }
    /// Batch fixtures prepare from an orchestrated Triage (the dispatch pattern), unless the test already chose its orchestrator.
    func ensureOrchestrated(_ project: JSON,_ group: JSON) throws {
        let stored = try storedTriage(group)
        if router.triageOrchestratorSession(stored) == nil && !bool(stored,"archived") { try orchestrateTriage(project,group) }
    }
    func leftTriageEvents(_ project: JSON,_ task: JSON) throws -> Int {
        (try call("history_list",["project_id":project["id"]!,"task_id":task["id"]!])["events"] as! [JSON]).filter {$0["kind"] as? String == "task_left_triage"}.count
    }
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
    func testIndividualSameStatusAndMetadataKeepTheTicketsOneTriage() throws {
        let p = try project();let task = try task(p);let first = try triage(p),second = try triage(p,"Review together")
        var epic = try call("epic_create",["project_id":p["id"]!,"name":"Persistent subsystem","brief":"Keep context"])
        let source = (try call("epic_list",["project_id":p["id"]!])["groups"] as! [JSON]).first {$0["id"] as? String == task["epic_id"] as? String}!
        epic = try call("group_membership",["project_id":p["id"]!,"group_id":epic["id"]!,"expected_revision":epic["revision"]!,"task_id":task["id"]!,"expected_task_revision":task["revision"]!,"action":"move","from_epic_id":source["id"]!,"from_epic_revision":source["revision"]!])
        let attached = try call("task_get",["project_id":p["id"]!,"task_id":task["id"]!]);try addTriage(p,first,task);try addTriage(p,second,task)
        // CL-125 rule 4: a ticket is in at most one Triage. The second add moves it, and the emptied plan archives with its history.
        XCTAssertTrue(strings(try storedTriage(first),"task_ids").isEmpty);XCTAssertTrue(bool(try storedTriage(first),"archived"))
        let edited = try call("task_edit",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":attached["revision"]!,"patch":["title":"Updated production brief"]])
        _ = try call("message_send",["project_id":p["id"]!,"task_id":task["id"]!,"body":"Note without changing the handling group"])
        let question = try call("human_request_create",["project_id":p["id"]!,"task_id":task["id"]!,"questions":[["id":"q","type":"text","prompt":"Which reference?","required":true]]])
        _ = try call("human_request_answer",["project_id":p["id"]!,"request_id":question["id"]!,"expected_revision":question["revision"]!,"answers":[["question_id":"q","value":"The blue reference"]]])
        XCTAssertEqual(strings(try currentTriage(p,second),"task_ids"),[task["id"] as! String])
        let left = try leftTriageEvents(p,task)
        let marked = try call("task_transition",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":edited["revision"]!,"target_status_id":edited["status_id"]!])
        XCTAssertEqual(marked["status_id"] as? String,edited["status_id"] as? String);XCTAssertEqual(marked["epic_id"] as? String,epic["id"] as? String)
        // Rule 8: a status action, including same-status marking, keeps membership.
        XCTAssertEqual(strings(try currentTriage(p,second),"task_ids"),[task["id"] as! String]);XCTAssertEqual(try leftTriageEvents(p,task),left)
    }
    func testTriageOrdinaryStatusIsAtomicDerivedAndRetainsAllMemberships() throws {
        let p = try project();let first = try task(p,"Input bug"),second = try task(p,"Menu bug");let group = try triage(p)
        let parked = try call("status_create",["project_id":p["id"]!,"name":"Parked · art reference","category":"parked"])
        let marked = try call("task_transition",["project_id":p["id"]!,"task_id":first["id"]!,"expected_revision":first["revision"]!,"target_status_id":parked["id"]!])
        try addTriage(p,group,marked);try addTriage(p,group,second)
        XCTAssertEqual(try currentTriage(p,group)["status_state"] as? String,"mixed")
        let result = try call("triage_transition",triageInput(p,group,["target_status_id":parked["id"]!]))
        XCTAssertEqual(strings(result,"changed_task_ids"),[second["id"] as! String]);XCTAssertEqual(strings(result,"unchanged_task_ids"),[first["id"] as! String]);XCTAssertFalse(bool(result,"no_op"))
        let current = result["triage"] as! JSON;XCTAssertEqual(current["status_state"] as? String,"uniform");XCTAssertEqual(current["status_id"] as? String,parked["id"] as? String);XCTAssertEqual(strings(current,"task_ids").count,2)
        XCTAssertEqual(Set(strings(try currentTriage(p,group),"task_ids")),[first["id"] as! String,second["id"] as! String])
        let again = try call("triage_transition",triageInput(p,group,["target_status_id":parked["id"]!]))
        XCTAssertTrue(bool(again,"no_op"));XCTAssertEqual(again["reason"] as? String,"already_at_target");XCTAssertEqual((again["triage"] as! JSON)["revision"] as? Int,current["revision"] as? Int)
        let empty = try triage(p,"Empty batch");let noop = try call("triage_transition",triageInput(p,empty))
        XCTAssertTrue(bool(noop,"no_op"));XCTAssertEqual(noop["reason"] as? String,"empty_triage");XCTAssertEqual((noop["triage"] as! JSON)["status_state"] as? String,"empty")
        let defaultMember = try call("group_membership",["project_id":p["id"]!,"group_id":empty["id"]!,"expected_revision":empty["revision"]!,"task_id":first["id"]!]);XCTAssertEqual((defaultMember["members"] as! [JSON])[0]["task_id"] as? String,first["id"] as? String)
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
        // TicketRetirement.requireRetirementSafe: holder release, reasoned takeover or verified-stop recovery.
        XCTAssertThrowsError(try call("triage_transition",input)) { error in
            let e = error as! CoreError;XCTAssertEqual(e.code,"TRIAGE_TRANSITION_BLOCKED");XCTAssertTrue(e.message.contains(second["key"] as! String))
            let blocker = (e.details["blockers"] as? [JSON])?.first { $0["task_id"] as? String == second["id"] as? String };XCTAssertEqual(blocker?["code"] as? String,"CLAIM_CONFLICT")
            for guidance in ["work_release","work_takeover with a reason","recovery after a verified stop"] { XCTAssertTrue(e.message.contains(guidance),guidance) }
        }
        let after = try call("snapshot");for key in ["tasks","groups","events"] { XCTAssertEqual(try jsonString(["rows":before[key]!]),try jsonString(["rows":after[key]!]),key) }
        let context = try call("task_context",["project_id":p["id"]!,"task_id":second["id"]!]);XCTAssertEqual((context["task"] as! JSON)["active_attempt_id"] as? String,claim["id"] as? String)
    }
    func testIndividualWorkflowStatusActionsKeepOrchestratedTriageMembership() throws {
        let p = try project();let task = try ready(p,task(p));let group = try triage(p);try orchestrateTriage(p,group);try addTriage(p,group,task)
        let tid = task["id"] as! String
        func members() throws -> [String] { strings(try currentTriage(p,group),"task_ids") }
        // CL-125 rules 6 and 8: claims by a session that orchestrates nothing and every status action keep the ticket in the orchestrated Triage.
        var claim = try call("work_claim",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!]);XCTAssertEqual(try members(),[tid])
        _ = try call("work_checkpoint",["project_id":p["id"]!,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"progress":"Continue current handling"]);XCTAssertEqual(try members(),[tid])
        var current = try call("work_release",["project_id":p["id"]!,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"reason":"Hand off safely"]);XCTAssertEqual(try members(),[tid])
        claim = try call("work_claim",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":current["revision"]!])
        current = try call("work_recover",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":(claim["task"] as! JSON)["revision"]!,"action":"confirm_stopped_revoke","reason":"Owner verified stopped","observation_refs":["synthetic explicit stop receipt"],"file_state_refs":["fixture has no reserved file scopes; no remaining writer"]]);XCTAssertEqual(try members(),[tid])
        claim = try call("work_claim",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":current["revision"]!])
        let submission = try submitTriageArtifact(p,task,claim);XCTAssertEqual(try members(),[tid])
        // Rule 10: submission records the implementing Triage as the return Triage.
        let member = (try storedTriage(group)["members"] as? [JSON] ?? []).first {$0["task_id"] as? String == tid}
        XCTAssertEqual(member?["return_triage_id"] as? String,group["id"] as? String)
        let submitted = submission["task"] as! JSON;let rid = strings(submission,"review_request_ids")[0]
        _ = try call("review_request",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":submitted["revision"]!,"target_manifest_id":submission["manifest_id"]!,"gate":"review"]);XCTAssertEqual(try members(),[tid])
        let reviewer = Caller(role:"owner",installation:"independent-review",projectIDs:[])
        let review = try call("work_claim",["project_id":p["id"]!,"task_id":task["id"]!,"expected_revision":submitted["revision"]!,"phase":"review","review_request_id":rid,"target_manifest_id":submission["manifest_id"]!,"gate":"review"],reviewer);XCTAssertEqual(try members(),[tid])
        _ = try call("review_record",["project_id":p["id"]!,"attempt_id":review["id"]!,"claim_token":review["claim_token"]!,"review_request_id":rid,"target_manifest_id":submission["manifest_id"]!,"gate":"review","verdict":"pass"],reviewer)
        // A pass that marks the ticket Done leaves the Triage; a pass without Done keeps it.
        let finished = try call("task_get",["project_id":p["id"]!,"task_id":task["id"]!])
        XCTAssertEqual(try members(),finished["status_category"] as? String == "done" ? [] : [tid])
    }
    func testHumanApprovalVerdictLeavesTriagesButUnfinishedAnswerRetainsThem() throws {
        for verdict in ["approved","changes_requested","declined"] {
            let value = try submittedArtifact(gates:["human_approval"]);let p = value.project;let group = try triage(p,phase:"review");try addTriage(p,group,value.task)
            var request = try humanApproval(value)
            request = try call("human_request_answer",try observedGateAnswer(["project_id":p["id"]!,"request_id":request["id"]!,"expected_revision":request["revision"]!,"target_sha256":value.artifact["sha256"]!,"response":"clarification","explanation":"I have not checked this target","answers":[["question_id":"approve","value":"not_checked"]]], task:value.task))
            XCTAssertEqual(strings(try currentTriage(p,group),"task_ids"),[value.task["id"] as! String])
            _ = try call("human_request_answer",try observedGateAnswer(["project_id":p["id"]!,"request_id":request["id"]!,"expected_revision":request["revision"]!,"target_sha256":value.artifact["sha256"]!,"answers":[["question_id":"approve","value":verdict]]], task:value.task));try assertEmptyTriage(p,group)
        }
    }
    func testTriageDoneHonorsGatesAndRemovesAllTriagesOnlyAfterAtomicSuccess() throws {
        // The project hold override keeps approved tickets in Review for this Triage completion (CL-137).
        let value = try submittedArtifact(gates:["human_approval"],holdPassing:true);let p = value.project;let first = value.task;let second = try ready(p,task(p,"Other completion target"));let claim = try call("work_claim",["project_id":p["id"]!,"task_id":second["id"]!,"expected_revision":second["revision"]!]);_ = try submitTriageArtifact(p,second,claim)
        let request = try humanApproval(value);_ = try call("human_request_answer",try observedGateAnswer(["project_id":p["id"]!,"request_id":request["id"]!,"expected_revision":request["revision"]!,"target_sha256":value.artifact["sha256"]!,"answers":[["question_id":"approve","value":"approved"]]], task:value.task))
        let group = try triage(p,phase:"review");try addTriage(p,group,first);try addTriage(p,group,second)
        let epic = (try call("epic_list",["project_id":p["id"]!])["groups"] as! [JSON]).first {$0["id"] as? String == first["epic_id"] as? String}!
        let before = try call("snapshot")
        assertCode("TRIAGE_TRANSITION_BLOCKED") { _ = try self.call("triage_transition",self.triageInput(p,group,["action":"complete"])) }
        let after = try call("snapshot");for key in ["tasks","groups","events"] { XCTAssertEqual(try jsonString(["rows":before[key]!]),try jsonString(["rows":after[key]!]),key) }
        let context = try call("task_context",["project_id":p["id"]!,"task_id":second["id"]!]);let artifact = (context["attachments"] as! [JSON])[0]
        let secondRequest = try call("human_request_create",["project_id":p["id"]!,"task_id":second["id"]!,"title":"Approve the other completion target","target_attachment_id":artifact["id"]!,"questions":[["id":"approve","type":"approval","prompt":"Inspect the exact original on the other completion target","required":true]]])
        _ = try call("human_request_answer",try observedGateAnswer(["project_id":p["id"]!,"request_id":secondRequest["id"]!,"expected_revision":secondRequest["revision"]!,"target_sha256":artifact["sha256"]!,"answers":[["question_id":"approve","value":"approved"]]], task:second))
        // CL-125 rule 8: the individual approval keeps the second ticket in this Triage.
        XCTAssertTrue(strings(try currentTriage(p,group),"task_ids").contains(second["id"] as! String))
        let done = try call("status_create",["project_id":p["id"]!,"name":"Production accepted","category":"done"])
        let result = try call("triage_transition",triageInput(p,group,["target_status_id":done["id"]!]))
        XCTAssertEqual(Set(strings(result,"completed_task_ids")),[first["id"] as! String,second["id"] as! String]);try assertEmptyTriage(p,group)
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
        _ = try call("task_transition",["project_id":pid,"task_id":task["id"]!,"expected_revision":marked["revision"]!,"target_status_id":marked["status_id"]!],worker);XCTAssertEqual(strings(try currentTriage(p,group),"task_ids"),[task["id"] as! String])
    }
}
