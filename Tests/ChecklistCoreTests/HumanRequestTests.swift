import XCTest
@testable import ChecklistCore

final class HumanRequestTests: XCTestCase {
    var root: URL!
    var router: CommandRouter!
    let owner = Caller(role:"owner",installation:"human-request-tests",projectIDs:[])
    override func setUpWithError() throws {
        root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/ChecklistQualification/CL-147").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        router = try CommandRouter(root:root)
    }
    override func tearDownWithError() throws { router = nil; try? FileManager.default.removeItem(at:root) }
    @discardableResult func call(_ method: String,_ params: JSON = [:],_ caller: Caller? = nil) throws -> JSON {
        var p = params; if !CommandRouter.readMethods.contains(method) { p["command_id"] = uuid() }
        return try router.handle(method:method,params:fixtureTaskInput(router,method:method,input:p),caller:caller ?? owner)["data"] as! JSON
    }
    func fixture() throws -> (JSON,JSON) {
        let workspace = root.appendingPathComponent("workspace"); try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let p = try call("project_create",["name":"Requests","key_prefix":"RQ","root_path":workspace.path])
        let t = try call("task_create",["project_id":p["id"]!,"title":"Human dependency","brief":"Record an explicit human answer"])
        return (p,t)
    }
    func requester(_ p: JSON,_ label: String) throws -> Caller {
        let sid = uuid(); _ = try call("session_register",["project_id":p["id"]!,"session_id":sid,"role":"worker","provider":"codex","installation":label])
        return Caller(role:"worker",installation:label,projectIDs:[p["id"] as! String],sessionID:sid,workspace:p["root_path"] as? String)
    }
    func assertCode(_ code: String,_ body: () throws -> Void,file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertThrowsError(try body(),file:file,line:line) { XCTAssertEqual(($0 as? CoreError)?.code,code,file:file,line:line) }
    }
    func contractJSON(_ path: String) throws -> JSON {
        let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONSerialization.jsonObject(with:Data(contentsOf:repo.appendingPathComponent(path))) as! JSON
    }
    func testDocumentedExampleCreatesAndRevisesThroughAgentValidation() throws {
        let (p,t) = try fixture(),worker = try requester(p,"documented-example")
        let form = try contractJSON("examples/human-request.json")
        var input = form; input["project_id"] = p["id"]!; input["task_id"] = t["id"]!
        let created = try call("human_request_create",input,worker)
        for key in form.keys { XCTAssertEqual(try jsonString([created[key]!]),try jsonString([form[key]!]),key) }
        var patch = form; patch["title"] = "Choose again after new references"
        let revised = try call("human_request_revise",["project_id":p["id"]!,"request_id":created["id"]!,"expected_revision":created["revision"]!,"patch":patch,"reason":"Documented form revision"],worker)
        XCTAssertEqual(revised["form_revision"] as? Int,2)
        XCTAssertNotEqual(revised["form_identity"] as? String,created["form_identity"] as? String)
        XCTAssertEqual(revised["title"] as? String,patch["title"] as? String)
    }
    func testSchemaFieldsAndEnumsStayInStepWithAgentCatalogAndService() throws {
        let schema = try contractJSON("contracts/human-request.schema.json")
        let definitions = schema["$defs"] as! JSON
        let properties = schema["properties"] as! JSON
        XCTAssertEqual(Set(properties.keys),Set(CommandRouter.requestFormKeys + ["review_request_id","target_manifest_id"] + CommandRouter.requestSupersedeKeys))
        XCTAssertEqual(Set(((definitions["patch"] as! JSON)["properties"] as! JSON).keys),Set(properties.keys).subtracting(CommandRouter.requestSupersedeKeys))
        let (p,t) = try fixture(),worker = try requester(p,"schema-enums")
        let catalog = router.toolCatalog(worker)
        let create = try XCTUnwrap(catalog.first { $0["name"] as? String == "human_request_create" })
        XCTAssertEqual(Set(((create["inputSchema"] as! JSON)["properties"] as! JSON).keys),Set(properties.keys).union(["project_id","task_id","command_id","expected_revision"]))
        for name in ["human_request_create","human_request_revise"] {
            let description = catalog.first { $0["name"] as? String == name }!["description"] as! String
            for field in properties.keys where name == "human_request_create" || !CommandRouter.requestSupersedeKeys.contains(field) { XCTAssertTrue(description.contains(field),"\(name): \(field)") }
        }
        let questionProps = (definitions["question"] as! JSON)["properties"] as! JSON
        for type in (questionProps["type"] as! JSON)["enum"] as! [String] {
            var question: JSON = ["id":"q","prompt":"Choose explicitly","type":type]
            if type == "choice" { question["options"] = [["id":"a","label":"A"]] }
            _ = try call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"blocking":false,"questions":[question]],worker)
        }
        let fileProps = (definitions["fileRequest"] as! JSON)["properties"] as! JSON
        for field in ["kind","selection"] {
            for kind in (fileProps[field] as! JSON)["enum"] as! [String] {
                _ = try call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"blocking":false,"file_requests":[["id":"f","prompt":"Select source",field:kind]]],worker)
            }
        }
    }
    func testObsoleteRequestShapeFailsClearlyOnCreateAndRevise() throws {
        let (p,t) = try fixture(),worker = try requester(p,"old-shape")
        let base: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"blocking":false,"questions":[["id":"q","prompt":"Input"]]]
        for key in ["request_spec","purpose","blocking_scope","target"] {
            var bad = base; bad[key] = [:]
            XCTAssertThrowsError(try call("human_request_create",bad,worker)) { error in
                XCTAssertEqual((error as? CoreError)?.code,"INVALID_INPUT")
                XCTAssertEqual((error as? CoreError)?.message,"Unknown fields are not accepted by this command.")
            }
        }
        let created = try call("human_request_create",base,worker)
        let badForms: [(JSON,String)] = [
            (["questions":[["id":"q","label":"Old prompt","type":"text"]]],"prompt is required."),
            (["questions":[["id":"q","prompt":"Old type","type":"single_choice"]]],"Unsupported question type."),
            (["questions":[["id":"q","prompt":"Old type","type":"long_text"]]],"Unsupported question type."),
            (["file_requests":[["id":"f","prompt":"Old selection","selection":"file_or_directory"]]],"Choose a file, directory or either selection.")]
        for (form,message) in badForms {
            var bad = base; for (key,value) in form { bad[key] = value }
            for (method,input) in [("human_request_create",bad),("human_request_revise",["project_id":p["id"]!,"request_id":created["id"]!,"expected_revision":created["revision"]!,"patch":form])] {
                XCTAssertThrowsError(try call(method,input,worker)) { error in
                    XCTAssertEqual((error as? CoreError)?.code,"INVALID_INPUT"); XCTAssertEqual((error as? CoreError)?.message,message)
                }
            }
        }
    }
    func testOriginalRequesterCanReviseAndCancelWithFormHistoryAndExactRevision() throws {
        let (p,t) = try fixture(),worker = try requester(p,"original"),other = try requester(p,"other")
        let r = try call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"questions":[["id":"q","type":"check","prompt":"Run original check"]]],worker)
        let edit: JSON = ["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":1,"patch":["questions":[["id":"q","type":"check","prompt":"Run changed check"]]],"reason":"Expected result changed"]
        assertCode("FORBIDDEN") { _ = try self.call("human_request_revise",edit,other) }
        let revised = try call("human_request_revise",edit,worker)
        XCTAssertEqual(revised["form_revision"] as? Int,2); XCTAssertNotEqual(revised["form_identity"] as? String,r["form_identity"] as? String)
        XCTAssertEqual((revised["form_history"] as! [JSON]).count,1)
        XCTAssertEqual(((revised["form_history"] as! [JSON])[0]["questions"] as! [JSON])[0]["prompt"] as? String,"Run original check")
        assertCode("REVISION_CONFLICT") { _ = try self.call("human_request_revise",edit,worker) }
        assertCode("REQUEST_CHANGED") { _ = try self.call("human_request_answer",["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":revised["revision"]!,"form_identity":r["form_identity"]!,"answers":[["question_id":"q","result":"passed"]]]) }
        let canceled = try call("human_request_cancel",["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":revised["revision"]!,"reason":"No longer needed"],worker)
        XCTAssertEqual(canceled["state"] as? String,"canceled")
    }
    func testRevocationCannotRegainRequesterEditAuthority() throws {
        let (p,t) = try fixture(),worker = try requester(p,"old")
        let r = try call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"questions":[["id":"q","prompt":"Choose"]]],worker)
        let session = try router.dbQueue.read { try router.record($0,worker.sessionID!,type:"session") }
        _ = try call("session_update",["project_id":p["id"]!,"session_id":worker.sessionID!,"expected_revision":session["revision"]!,"state":"ended"])
        XCTAssertThrowsError(try call("human_request_cancel",["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":1],worker))
        XCTAssertEqual(try call("human_request_cancel",["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":1])["state"] as? String,"canceled")
    }
    func testClarificationCannotDoNotCheckedAndSnoozeRemainUnresolved() throws {
        let (p,t) = try fixture()
        var r = try call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"questions":[["id":"q","type":"check","prompt":"Run this manual command","command":["text":"echo checked","working_directory":"/tmp","expected_result":"checked"]]]])
        let taskRevision = t["revision"] as! Int
        r = try call("human_request_snooze",["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":r["revision"]!,"snoozed":true])
        XCTAssertEqual(r["state"] as? String,"pending"); XCTAssertEqual(r["owner_snoozed"] as? Bool,true); XCTAssertNil(r["snooze_until"])
        for action in ["clarification","cannot_do"] {
            let answers: [JSON] = [["question_id":"q","result":"not_checked"]]
            r = try call("human_request_answer",["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":r["revision"]!,"response":action,"answers":answers,"explanation":"I have not run this"])
            XCTAssertEqual(r["state"] as? String,"pending"); XCTAssertNil(r["gate_outcome"])
        }
        let current = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!]); XCTAssertEqual(current["revision"] as? Int,taskRevision)
        XCTAssertEqual((r["responses"] as! [JSON]).count,2)
        XCTAssertEqual(((r["responses"] as! [JSON]).last!)["origin"] as? String,"human_ui")
    }
    func testIncompleteSendNamesMissingItemAndSavesNoResponseNoteOrDelivery() throws {
        let (p,t) = try fixture(), worker = try requester(p,"missing-check")
        let r = try call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"questions":[["id":"check","type":"check","prompt":"Keyboard navigation is turned on"]],"file_requests":[["id":"file","prompt":"Select the keyboard report"]]],worker)
        let before = try router.dbQueue.read { db in try jsonString(try ["request","message","delivery","attachment","storage_job"].flatMap { try router.records(db,type:$0) }) }
        let base: JSON = ["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":1,"response":"answered","explanation":"No, I decline"]
        for answers: [JSON] in [[],[["question_id":"check","result":""]]] {
            var input = base; input["answers"] = answers
            XCTAssertThrowsError(try call("human_request_answer",input)) {
                XCTAssertEqual(($0 as? CoreError)?.code,"ANSWER_INCOMPLETE")
                XCTAssertTrue(($0 as? CoreError)?.message.contains("Keyboard navigation is turned on") == true)
            }
            XCTAssertEqual(try router.dbQueue.read { db in try jsonString(try ["request","message","delivery","attachment","storage_job"].flatMap { try router.records(db,type:$0) }) },before)
        }
        var missingFile = base; missingFile["answers"] = [["question_id":"check","result":"declined"]]
        XCTAssertThrowsError(try call("human_request_answer",missingFile)) {
            XCTAssertEqual(($0 as? CoreError)?.code,"ANSWER_INCOMPLETE")
            XCTAssertTrue(($0 as? CoreError)?.message.contains("Select the keyboard report") == true)
        }
        XCTAssertEqual(try router.dbQueue.read { db in try jsonString(try ["request","message","delivery","attachment","storage_job"].flatMap { try router.records(db,type:$0) }) },before)
    }
    func testDeclinedCheckAndApprovalCloseRequestAndReachRequesterWithPendingCount() throws {
        let (p,t) = try fixture(), worker = try requester(p,"decline-recipient")
        for type in ["check","approval"] {
            let r = try call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"title":"Decline \(type)","questions":[["id":"q","type":type,"prompt":"Decline \(type)?"]]],worker)
            let before = try call("task_context",["project_id":p["id"]!,"task_id":t["id"]!])
            XCTAssertEqual((before["counts"] as? JSON)?["pending_requests"] as? Int,1)
            let answered = try call("human_request_answer",["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":1,"response":"answered","answers":[["question_id":"q","result":"declined"]]])
            XCTAssertEqual(answered["state"] as? String,"answered")
            XCTAssertEqual(answered["needs_you_count"] as? Int,0)
            let response = (answered["responses"] as! [JSON]).last!
            XCTAssertEqual(response["complete"] as? Bool,true)
            XCTAssertEqual((response["answers"] as! [JSON])[0]["result"] as? String,"declined")
            XCTAssertEqual(((answered["message"] as! JSON)["deliveries"] as! [JSON]).first?["recipient_session_id"] as? String,worker.sessionID)
            let context = try call("task_context",["project_id":p["id"]!,"task_id":t["id"]!],worker)
            XCTAssertEqual((context["counts"] as? JSON)?["pending_requests"] as? Int,0)
            XCTAssertEqual((((context["requests"] as! [JSON]).first!["responses"] as! [JSON]).last!["answers"] as! [JSON])[0]["result"] as? String,"declined")
        }
    }
    func testSendNotCheckedPreservesOwnerWordsAndReachesRequesterWithoutCompleting() throws {
        let (p,_) = try fixture(), worker = try requester(p,"not-checked-recipient")
        for type in ["check","approval"] {
            for required in [true,false] {
                let t = try call("task_create",["project_id":p["id"]!,"title":"Inspect \(type) \(required)","brief":"Record owner response"])
                let r = try call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"questions":[["id":"q","type":type,"prompt":"Inspect \(type) \(required)","required":required]]],worker)
                let base: JSON = ["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":1,"response":"answered","answers":[["question_id":"q","result":"not_checked"]]]
                for explanation in [""," \n "] {
                    var invalid = base; invalid["explanation"] = explanation
                    assertCode("ANSWER_INCOMPLETE") { _ = try self.call("human_request_answer",invalid) }
                }
                var input = base; input["explanation"] = "I could not inspect this build. Please provide access."
                let saved = try call("human_request_answer",input)
                XCTAssertEqual(saved["state"] as? String,"pending"); XCTAssertNil(saved["gate_outcome"])
                let response = (saved["responses"] as! [JSON]).last!
                XCTAssertEqual(response["complete"] as? Bool,false)
                XCTAssertEqual(response["action"] as? String,"answered")
                XCTAssertEqual(response["explanation"] as? String,input["explanation"] as? String)
                XCTAssertEqual((response["answers"] as! [JSON])[0]["result"] as? String,"not_checked")
                XCTAssertEqual(((saved["message"] as! JSON)["deliveries"] as! [JSON]).first?["recipient_session_id"] as? String,worker.sessionID)
                let context = try call("task_context",["project_id":p["id"]!,"task_id":t["id"]!],worker)
                let read = (context["requests"] as! [JSON]).first { $0["id"] as? String == r["id"] as? String }!
                let stored = (read["responses"] as! [JSON]).last!
                XCTAssertEqual(stored["explanation"] as? String,input["explanation"] as? String)
                XCTAssertEqual((stored["answers"] as! [JSON])[0]["result"] as? String,"not_checked")
                let current = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!])
                XCTAssertEqual(current["revision"] as? Int,t["revision"] as? Int)
            }
        }
    }
    func testMixedOptionalSelectionsValidateEverySelectedAnswerAndFile() throws {
        let (p,t) = try fixture(),file = root.appendingPathComponent("pick.txt"); try Data("original".utf8).write(to:file)
        let r = try call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"questions":[["id":"required","type":"text","prompt":"Decision"],["id":"optional","type":"choice","prompt":"Optional choice","required":false,"allow_custom":true,"multiple":true,"options":[["id":"a","label":"A"]]]],"file_requests":[["id":"optional_file","prompt":"Optional file","kind":"file","required":false]]])
        let base: JSON = ["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":1]
        var bad = base; bad["answers"] = [["question_id":"required","text":"Decision"],["question_id":"optional","option_ids":["a","a"]]]
        assertCode("ANSWER_INCOMPLETE") { _ = try self.call("human_request_answer",bad) }
        bad["answers"] = [["question_id":"required","text":"Decision"],["question_id":"optional","result":"approved"]]
        assertCode("INVALID_INPUT") { _ = try self.call("human_request_answer",bad) }
        bad["answers"] = [["question_id":"required","text":"Decision"]]; bad["files"] = [["file_request_id":"optional_file","paths":[root.appendingPathComponent("missing").path]]]
        assertCode("FILE_ACCESS_REQUIRED") { _ = try self.call("human_request_answer",bad) }
        bad["files"] = [["file_request_id":"optional_file","paths":[root.path]]]
        assertCode("ANSWER_INCOMPLETE") { _ = try self.call("human_request_answer",bad) }
        bad["files"] = [["file_request_id":"unknown","paths":[file.path]]]
        assertCode("REQUEST_CHANGED") { _ = try self.call("human_request_answer",bad) }
        var valid = base; valid["answers"] = [["question_id":"required","text":"Decision"],["question_id":"optional","option_ids":["a"],"custom_text":"and custom"]]; valid["files"] = [["file_request_id":"optional_file","paths":[file.path],"mode":"reference","path_sha256":[file.path:ChecklistCore.hash(Data("original".utf8))]]]
        let answered = try call("human_request_answer",valid)
        XCTAssertEqual(answered["state"] as? String,"answered")
        let response = (answered["responses"] as! [JSON])[0]
        XCTAssertEqual((response["answers"] as! [JSON]).count,2); XCTAssertEqual((response["files"] as! [JSON])[0]["mode"] as? String,"reference")
    }
    func testChangedSelectionPreservesPendingRequestAndManagedCopyIsExplicit() throws {
        let (p,t) = try fixture(),file = root.appendingPathComponent("selected.txt"); try Data("old".utf8).write(to:file)
        let r = try call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"file_requests":[["id":"file","prompt":"Provide source","kind":"file"]]])
        var input: JSON = ["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":1,"files":[["file_request_id":"file","paths":[file.path],"mode":"managed","path_sha256":[file.path:ChecklistCore.hash(Data("old".utf8))]]]]
        try Data("new".utf8).write(to:file)
        assertCode("SOURCE_CHANGED") { _ = try self.call("human_request_answer",input) }
        let before = try call("task_context",["project_id":p["id"]!,"task_id":t["id"]!]); XCTAssertEqual((before["requests"] as! [JSON])[0]["state"] as? String,"pending"); XCTAssertTrue((before["attachments"] as! [JSON]).isEmpty)
        input["files"] = [["file_request_id":"file","paths":[file.path],"mode":"managed","path_sha256":[file.path:ChecklistCore.hash(Data("new".utf8))]]]
        let answer = try call("human_request_answer",input),response = (answer["responses"] as! [JSON])[0]
        let refs = ((response["files"] as! [JSON])[0])["artifact_refs"] as! [JSON]
        XCTAssertEqual(refs.count,1)
        let attachment = try call("attachment_read",["project_id":p["id"]!,"attachment_id":refs[0]["artifact_id"]!])
        XCTAssertEqual(attachment["mode"] as? String,"managed"); XCTAssertNotEqual(attachment["path"] as? String,file.path)
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"new")
        XCTAssertTrue((response["answers"] as! [JSON]).isEmpty)
    }
    func testAnswerQueuesOriginalAndCurrentHandlerWithGenerationWithoutRevivingEndedRequester() throws {
        let (p,originalTask) = try fixture(),original = try requester(p,"original"),handler = try requester(p,"handler")
        let t = try call("task_edit",["project_id":p["id"]!,"task_id":originalTask["id"]!,"expected_revision":originalTask["revision"]!,"patch":["readiness":"ready"]])
        _ = try call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"phase":"implementation"],handler)
        let request = try call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"questions":[["id":"q","prompt":"Decision"]]],original)
        let answer = try call("human_request_answer",["project_id":p["id"]!,"request_id":request["id"]!,"expected_revision":1,"answers":[["question_id":"q","text":"Proceed"]]])
        let deliveries = (answer["message"] as! JSON)["deliveries"] as! [JSON]
        XCTAssertEqual(Set(deliveries.compactMap {$0["recipient_session_id"] as? String}),Set([original.sessionID!,handler.sessionID!]))
        XCTAssertTrue(deliveries.allSatisfy {$0["state"] as? String == "queued" && $0["recipient_authorization_generation"] != nil})
        let response = (answer["responses"] as! [JSON])[0]; XCTAssertNotNil(response["created_at"]); XCTAssertNotNil(response["form_identity"]); XCTAssertEqual(answer["continuation_delivery"] as? String,"queued_for_pickup")
        let session = try router.dbQueue.read { try router.record($0,original.sessionID!,type:"session") }
        _ = try call("session_update",["project_id":p["id"]!,"session_id":original.sessionID!,"expected_revision":session["revision"]!,"state":"ended"])
        let next = try call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"title":"Another decision","questions":[["id":"q","prompt":"Another decision"]]],handler)
        let nextAnswer = try call("human_request_answer",["project_id":p["id"]!,"request_id":next["id"]!,"expected_revision":1,"answers":[["question_id":"q","text":"Still proceed"]]])
        XCTAssertEqual(((nextAnswer["message"] as! JSON)["deliveries"] as! [JSON]).count,1)
        XCTAssertEqual(try router.dbQueue.read { try router.record($0,original.sessionID!,type:"session")["state"] as? String },"ended")
    }
    func testHumanGateRevisionTransferIsAtomicAndOldAnswersCannotApproveNewForm() throws {
        let (originalProject,originalTask) = try fixture()
        let p = try call("policy_apply",["project_id":originalProject["id"]!,"expected_revision":originalProject["revision"]!,"policy":["required_gates":["human_approval"],"routing_preset":"shared"]])
        let t = try call("task_edit",["project_id":p["id"]!,"task_id":originalTask["id"]!,"expected_revision":originalTask["revision"]!,"patch":["readiness":"ready"]])
        let attempt = try call("work_claim",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!])
        let file = root.appendingPathComponent("candidate.txt"); try Data("candidate".utf8).write(to:file)
        let artifact = try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":file.path])
        _ = try call("work_submit",["project_id":p["id"]!,"attempt_id":attempt["id"]!,"claim_token":attempt["claim_token"]!,"acceptance_revision":1,"evidence_manifest":["artifact_refs":[["artifact_id":artifact["id"]!,"sha256":artifact["sha256"]!]]]])
        let r = try call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"target_attachment_id":artifact["id"]!,"questions":[["id":"approve","type":"approval","prompt":"Inspect candidate"]]])
        let invalid: JSON = ["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":1,"patch":["title":"Replacement","review_request_id":"missing"]]
        assertCode("NOT_FOUND") { _ = try self.call("human_request_revise",invalid) }
        let currentTask = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!]); XCTAssertEqual(currentTask["active_verification_request_id"] as? String,r["id"] as? String)
        let after = try router.dbQueue.read { try router.record($0,r["id"] as! String,type:"request") }; XCTAssertEqual(after["revision"] as? Int,1)
        let gate = try router.dbQueue.read { try router.record($0,r["review_request_id"] as! String,type:"review_request") }; XCTAssertEqual(gate["state"] as? String,"human_pending")
        let changed = try call("human_request_revise",["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":1,"patch":["questions":[["id":"approve","type":"approval","prompt":"Inspect changed expectation"]]]])
        XCTAssertEqual(changed["review_request_id"] as? String,r["review_request_id"] as? String)
        assertCode("REQUEST_CHANGED") { _ = try self.call("human_request_answer",["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":changed["revision"]!,"form_identity":r["form_identity"]!,"target_sha256":artifact["sha256"]!,"answers":[["question_id":"approve","result":"approved"]]]) }
        let approvalContext = try call("task_context",["project_id":p["id"]!,"task_id":t["id"]!])
        let answer = try call("human_request_answer",["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":changed["revision"]!,"expected_task_revision":(approvalContext["task"] as! JSON)["revision"]!,"direction_cursor":approvalContext["direction_cursor"]!,"form_identity":changed["form_identity"]!,"target_sha256":artifact["sha256"]!,"answers":[["question_id":"approve","result":"approved"]]])
        XCTAssertEqual(answer["gate_outcome"] as? String,"pass")
    }
}
