import XCTest
@testable import ChecklistCore

final class HumanGateDirectionTests: XCTestCase {
    var root: URL!
    var router: CommandRouter!
    let owner = Caller(role:"owner",installation:"human-gate-directions",projectIDs:[])
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);router = try CommandRouter(root:root) }
    override func tearDownWithError() throws { router = nil;try? FileManager.default.removeItem(at:root) }
    @discardableResult func call(_ method: String,_ params: JSON = [:]) throws -> JSON {
        var input = params;if !CommandRouter.readMethods.contains(method) { input["command_id"] = uuid() }
        return try router.handle(method:method,params:input,caller:owner)["data"] as! JSON
    }
    func assertCode(_ code: String,_ body: () throws -> Void,file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertThrowsError(try body(),file:file,line:line) {XCTAssertEqual(($0 as? CoreError)?.code,code,file:file,line:line)}
    }
    func fixture() throws -> (project:JSON,task:JSON,request:JSON,artifact:JSON) {
        var project = try call("project_create",["name":"Human gate directions","key_prefix":"HGD"])
        project = try call("policy_apply",["project_id":project["id"]!,"expected_revision":project["revision"]!,"policy":["required_gates":["human_approval"]]])
        var task = try call("task_create",["project_id":project["id"]!,"title":"Inspect the exact candidate","brief":"Approve the exact managed original"])
        task = try call("task_edit",["project_id":project["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"patch":["readiness":"ready"]])
        let attempt = try call("work_claim",["project_id":project["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!])
        let path = root.appendingPathComponent("candidate.txt");try Data("Immutable approval target".utf8).write(to:path)
        let artifact = try call("attachment_add",["project_id":project["id"]!,"task_id":task["id"]!,"path":path.path])
        let submitted = try call("work_submit",["project_id":project["id"]!,"attempt_id":attempt["id"]!,"claim_token":attempt["claim_token"]!,"acceptance_revision":1,"evidence_manifest":["artifact_refs":[["artifact_id":artifact["id"]!,"sha256":artifact["sha256"]!]]]])
        task = submitted["task"] as! JSON
        let request = try call("human_request_create",["project_id":project["id"]!,"task_id":task["id"]!,"target_attachment_id":artifact["id"]!,"questions":[["id":"approve","type":"approval","prompt":"Inspect this exact original"]],"file_requests":[["id":"evidence","prompt":"Optional inspection evidence","required":false,"kind":"file"]]])
        return (project,task,request,artifact)
    }
    func approval(_ value: (project:JSON,task:JSON,request:JSON,artifact:JSON), context: JSON? = nil) throws -> JSON {
        var input: JSON = ["project_id":value.project["id"]!,"request_id":value.request["id"]!,"expected_revision":value.request["revision"]!,"target_sha256":value.artifact["sha256"]!,"answers":[["question_id":"approve","result":"approved"]]]
        if let context { input["direction_cursor"] = context["direction_cursor"];input["expected_task_revision"] = (context["task"] as! JSON)["revision"] }
        return input
    }
    func context(_ value: (project:JSON,task:JSON,request:JSON,artifact:JSON)) throws -> JSON {try call("task_context",["project_id":value.project["id"]!,"task_id":value.task["id"]!])}
    func state(_ value: (project:JSON,task:JSON,request:JSON,artifact:JSON)) throws -> String {
        try router.dbQueue.read { db in
            let pid = value.project["id"] as! String
            let snapshot: JSON = ["task":try router.record(db,value.task["id"] as! String,type:"task"),"request":try router.record(db,value.request["id"] as! String,type:"request"),"gate":try router.record(db,value.request["review_request_id"] as! String,type:"review_request"),"reviews":try router.records(db,type:"review",project:pid),"attachments":try router.records(db,type:"attachment",project:pid)]
            return try jsonString(snapshot)
        }
    }

    func testCompleteGateAnswerRequiresObservedCursorAndTaskRevisionEvenWithoutDirections() throws {
        let value = try fixture(),before = try state(value)
        let missing = try approval(value)
        assertCode("DIRECTION_CURSOR_REQUIRED") {_ = try self.call("human_request_answer",missing)}
        XCTAssertEqual(try state(value),before)
        let observed = try context(value)
        var missingRevision = try approval(value,context:observed);missingRevision.removeValue(forKey:"expected_task_revision")
        assertCode("REVISION_REQUIRED") {_ = try self.call("human_request_answer",missingRevision)}
        XCTAssertEqual(try state(value),before)
        var staleRevision = try approval(value,context:observed);staleRevision["expected_task_revision"] = int(observed["task"] as! JSON,"revision")-1
        assertCode("REVISION_CONFLICT") {_ = try self.call("human_request_answer",staleRevision)}
        XCTAssertEqual(try state(value),before)
        XCTAssertEqual((try call("human_request_answer",approval(value,context:observed)))["gate_outcome"] as? String,"pass")
    }

    func testDirectionArrivingAfterApprovalFormBlocksVerdictAndFileImportWithoutReleasingSlot() throws {
        let value = try fixture(),observed = try context(value)
        let note = try call("message_send",["project_id":value.project["id"]!,"task_id":value.task["id"]!,"body":"Inspect the newly requested constraint first","requires_action":true])
        let evidence = root.appendingPathComponent("inspection.txt");try Data("Owner inspection evidence".utf8).write(to:evidence)
        var input = try approval(value,context:observed)
        input["files"] = [["file_request_id":"evidence","paths":[evidence.path],"mode":"managed"]]
        let before = try state(value)
        assertCode("USER_DIRECTION_PENDING") {_ = try self.call("human_request_answer",input)}
        XCTAssertEqual(try state(value),before)
        let current = try context(value)
        XCTAssertEqual((current["task"] as! JSON)["active_verification_request_id"] as? String,value.request["id"] as? String)
        _ = try call("direction_waive",["project_id":value.project["id"]!,"message_id":note["id"]!,"expected_revision":note["revision"]!,"reason":"The new constraint does not apply to this candidate"])
        let afterWaiver = try state(value)
        assertCode("CURSOR_RESET") {_ = try self.call("human_request_answer",input)}
        XCTAssertEqual(try state(value),afterWaiver)
        let fresh = try context(value);input["direction_cursor"] = fresh["direction_cursor"];input["expected_task_revision"] = (fresh["task"] as! JSON)["revision"]
        XCTAssertEqual((try call("human_request_answer",input))["gate_outcome"] as? String,"pass")
        XCTAssertNil((try context(value)["task"] as! JSON)["active_verification_request_id"])
    }

    func testRelevantApprovedDecisionArrivingAfterFormCannotPassGate() throws {
        let value = try fixture(),observed = try context(value)
        let settings = try call("project_settings_get",["project_id":value.project["id"]!])
        _ = try call("project_edit",["project_id":value.project["id"]!,"expected_revision":settings["revision"]!,"pinned_decisions":["Inspect accessibility before accepting this candidate"]])
        let before = try state(value)
        assertCode("USER_DIRECTION_PENDING") {_ = try self.call("human_request_answer",self.approval(value,context:observed))}
        XCTAssertEqual(try state(value),before)
    }

    func testPendingDirectionStillAllowsNonGateAnswerAndNonVerdictApprovalResponses() throws {
        let value = try fixture()
        _ = try call("message_send",["project_id":value.project["id"]!,"task_id":value.task["id"]!,"body":"New direction remains pending","requires_action":true])
        var answer = try approval(value);answer["response"] = "clarification";answer["explanation"] = "I have not checked this target";answer["answers"] = [["question_id":"approve","result":"not_checked"]]
        let unchecked = try call("human_request_answer",answer)
        XCTAssertEqual(unchecked["state"] as? String,"pending");XCTAssertNil(unchecked["gate_verdict_id"])
        let clarification = try call("human_request_answer",["project_id":value.project["id"]!,"request_id":value.request["id"]!,"expected_revision":unchecked["revision"]!,"response":"clarification","explanation":"Need a closer view"])
        XCTAssertEqual(clarification["state"] as? String,"pending")
        XCTAssertEqual((try context(value)["task"] as! JSON)["active_verification_request_id"] as? String,value.request["id"] as? String)
        let plainTask = try call("task_create",["project_id":value.project["id"]!,"title":"Ordinary answer","brief":"Keep nongate answers possible"])
        let plainRequest = try call("human_request_create",["project_id":value.project["id"]!,"task_id":plainTask["id"]!,"title":"Ordinary detail question","questions":[["id":"q","prompt":"Which detail?"]]])
        _ = try call("message_send",["project_id":value.project["id"]!,"task_id":plainTask["id"]!,"body":"Another unresolved direction","requires_action":true])
        let plainAnswer = try call("human_request_answer",["project_id":value.project["id"]!,"request_id":plainRequest["id"]!,"expected_revision":1,"answers":[["question_id":"q","text":"Use the saved detail"]]])
        XCTAssertEqual(plainAnswer["state"] as? String,"answered")
    }
}
