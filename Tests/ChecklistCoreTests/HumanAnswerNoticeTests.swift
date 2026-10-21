import XCTest
import GRDB
@testable import ChecklistCore
@testable import ChecklistBridges

final class HumanAnswerNoticeTests: XCTestCase {
    var root: URL!
    var router: CommandRouter!
    let owner = Caller(role:"owner",installation:"notice-owner",projectIDs:[])
    override func setUpWithError() throws {root = FileManager.default.temporaryDirectory.appendingPathComponent(uuid());try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);router = try CommandRouter(root:root.appendingPathComponent("store"))}
    override func tearDownWithError() throws {router = nil;try? FileManager.default.removeItem(at:root)}
    func envelope(_ method: String,_ params: JSON = [:],_ caller: Caller? = nil, command: String? = nil) throws -> JSON {
        var input = params;if !CommandRouter.readMethods.contains(method) {input["command_id"] = command ?? uuid()}
        return try router.handle(method:method,params:input,caller:caller ?? owner)
    }
    @discardableResult func call(_ method: String,_ params: JSON = [:],_ caller: Caller? = nil, command: String? = nil) throws -> JSON {try envelope(method,params,caller,command:command)["data"] as! JSON}
    func fixture(key: String? = nil) throws -> (project:JSON,task:JSON,requester:Caller,handler:Caller,other:Caller) {
        let workspace = root.appendingPathComponent("workspace");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let project = try call("project_create",["name":"Notices","key_prefix":"NT","root_path":workspace.path])
        var taskInput: JSON = ["project_id":project["id"]!,"title":"Answer delivery","brief":"Continue only from the actual owner response"]
        if let key { taskInput["key"] = key }
        var task = try call("task_create",taskInput)
        task = try call("task_edit",["project_id":project["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!,"patch":["readiness":"ready"]])
        func worker(_ name: String) throws -> Caller {
            let sid = uuid();_ = try call("session_register",["project_id":project["id"]!,"session_id":sid,"provider":"codex","role":"worker","installation":name,"workspace":workspace.path])
            return Caller(role:"worker",installation:name,projectIDs:[project["id"] as! String],sessionID:sid,workspace:workspace.path)
        }
        let requester = try worker("requester"),handler = try worker("handler"),other = try worker("other")
        _ = try call("work_claim",["project_id":project["id"]!,"task_id":task["id"]!,"expected_revision":task["revision"]!],handler)
        return (project,task,requester,handler,other)
    }
    func request(_ f: (project:JSON,task:JSON,requester:Caller,handler:Caller,other:Caller)) throws -> JSON {
        try call("human_request_create",["project_id":f.project["id"]!,"task_id":f.task["id"]!,"title":"PRIVATE_TITLE","questions":[["id":"q","prompt":"PRIVATE_PROMPT"]]],f.requester)
    }
    func answer(_ f: (project:JSON,task:JSON,requester:Caller,handler:Caller,other:Caller),_ request: JSON,command: String? = nil) throws -> JSON {
        try call("human_request_answer",["project_id":f.project["id"]!,"request_id":request["id"]!,"expected_revision":request["revision"]!,"answers":[["question_id":"q","text":"PRIVATE_ANSWER /Users/private/source"]],"explanation":"PRIVATE_EXPLANATION"],command:command)
    }
    func notice(_ output: JSON) -> JSON? {
        let data = output["data"] as? JSON ?? output
        return (data["_checklist"] as? JSON)?["pending_human_answers"] as? JSON
    }
    func delivery(_ id: String) throws -> JSON {try router.dbQueue.read {try router.record($0,id,type:"delivery")}}

    func testOrdinaryToolResultShowsExactRecipientAnswerMetadataInsideStandardDataWithoutAck() throws {
        let f = try fixture(key:"/Users/private/key\nINJECTED_NOTE"),r = try request(f),answered = try answer(f,r)
        let output = try envelope("task_get",["project_id":f.project["id"]!,"task_id":f.task["id"]!],f.requester)
        let metadata = try XCTUnwrap(notice(output)),item = try XCTUnwrap((metadata["items"] as? [JSON])?.first)
        XCTAssertEqual(item["task_key"] as? String,f.task["key"] as? String);XCTAssertEqual(item["task_title"] as? String,"Answer delivery");XCTAssertEqual(item["project_name"] as? String,"Notices")
        XCTAssertEqual(item["request_id"] as? String,r["id"] as? String)
        XCTAssertEqual(item["response_id"] as? String,((answered["responses"] as! [JSON])[0])["id"] as? String)
        XCTAssertEqual(item["form_revision"] as? Int,1);XCTAssertEqual(item["delivery_state"] as? String,"queued")
        let encoded = try jsonString(metadata)
        for secret in ["PRIVATE_TITLE","PRIVATE_PROMPT","PRIVATE_ANSWER","PRIVATE_EXPLANATION","/Users/private/source"] {XCTAssertFalse(encoded.contains(secret))}
        XCTAssertEqual(try delivery(item["delivery_id"] as! String)["state"] as? String,"queued")
        XCTAssertNotNil(HumanAnswerNoticePresentation.text(in:output))
        XCTAssertNotNil(HumanAnswerNoticePresentation.text(in:output["data"] as! JSON),"The root workflow helper drops the outer envelope; notices must survive.")
        XCTAssertNil(notice(try envelope("task_get",["project_id":f.project["id"]!,"task_id":f.task["id"]!],f.other)))
        let handlerNotice = try XCTUnwrap(notice(envelope("task_get",["project_id":f.project["id"]!,"task_id":f.task["id"]!],f.handler)))
        XCTAssertNotEqual((handlerNotice["items"] as! [JSON])[0]["delivery_id"] as? String,item["delivery_id"] as? String)
    }

    func testNewAnswerAppearsOnReplayedCommandWithoutChangingDurableSemanticReceipt() throws {
        let f = try fixture(),command = uuid()
        let input: JSON = ["project_id":f.project["id"]!,"task_id":f.task["id"]!,"body":"Implementation checkpoint note"]
        let first = try envelope("message_send",input,f.requester,command:command)
        XCTAssertNil(notice(first))
        let r = try request(f),answerCommand = uuid(),answered = try answer(f,r,command:answerCommand)
        let repeatedAnswer = try answer(f,r,command:answerCommand)
        XCTAssertEqual(answered["continuation_message_id"] as? String,repeatedAnswer["continuation_message_id"] as? String)
        let replay = try envelope("message_send",input,f.requester,command:command)
        XCTAssertEqual(replay["replayed"] as? Bool,true)
        XCTAssertEqual((replay["data"] as! JSON)["id"] as? String,(first["data"] as! JSON)["id"] as? String)
        XCTAssertNotNil(notice(replay))
        let durable = try router.dbQueue.read {try String.fetchOne($0,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[f.requester.principal,command])!}
        XCTAssertFalse(durable.contains("pending_human_answers"));XCTAssertFalse(durable.contains("_checklist"))
        let item = (try XCTUnwrap(notice(replay))["items"] as! [JSON])[0]
        _ = try call("message_ack",["project_id":f.project["id"]!,"delivery_id":item["delivery_id"]!,"stage":"acknowledged"],f.requester)
        XCTAssertNil(notice(try envelope("message_send",input,f.requester,command:command)))
        XCTAssertEqual(try delivery(item["delivery_id"] as! String)["state"] as? String,"acknowledged")
    }

    func testRestartKeepsPendingAnswerButEndedOrRotatedRecipientGetsNoOldNotice() throws {
        let f = try fixture(),r = try request(f);_ = try answer(f,r)
        router = nil;router = try CommandRouter(root:root.appendingPathComponent("store"))
        XCTAssertNotNil(notice(try envelope("service_info",[:],f.requester)))
        _ = try call("session_register",["project_id":f.project["id"]!,"session_id":f.requester.sessionID!,"provider":"codex","role":"worker","installation":"requester","workspace":f.requester.workspace!])
        XCTAssertNil(notice(try envelope("service_info",[:],f.requester)),"A new generation cannot consume the old generation's queued answer.")
        let next = try request(f);_ = try answer(f,next)
        XCTAssertNotNil(notice(try envelope("service_info",[:],f.requester)))
        let session = try router.dbQueue.read {try router.record($0,f.requester.sessionID!,type:"session")}
        _ = try call("session_update",["project_id":f.project["id"]!,"session_id":f.requester.sessionID!,"expected_revision":session["revision"]!,"state":"ended"])
        XCTAssertNil(notice(try envelope("service_info",[:],f.requester)))
    }

    func testBoundedNoticesOnlyIncludeAnswersNotOrdinaryNotesAndExposeRemainingPickup() throws {
        let f = try fixture()
        _ = try call("message_send",["project_id":f.project["id"]!,"task_id":f.task["id"]!,"body":"Ordinary owner note","recipient":["kind":"session","session_id":f.requester.sessionID!]])
        XCTAssertNil(notice(try envelope("service_info",[:],f.requester)))
        for _ in 0..<10 {let r = try request(f);_ = try answer(f,r)}
        let output = try envelope("service_info",[:],f.requester),metadata = try XCTUnwrap(notice(output))
        XCTAssertEqual((metadata["items"] as! [JSON]).count,8);XCTAssertEqual(metadata["has_more"] as? Bool,true)
        XCTAssertLessThan(try jsonString(metadata).utf8.count,16*1024)
        let before = try call("session_inbox",["project_id":f.project["id"]!],f.requester)
        XCTAssertEqual((before["deliveries"] as! [JSON]).filter {$0["state"] as? String == "queued"}.count,11)
        XCTAssertEqual(metadata["native_codex_wake_qualified"] as? Bool,false)
    }

    func testRevokedAndCrossProjectRecipientCannotGetAnswerNotice() throws {
        let f = try fixture(),r = try request(f);_ = try answer(f,r)
        let otherRoot = root.appendingPathComponent("other-project");try FileManager.default.createDirectory(at:otherRoot,withIntermediateDirectories:true)
        let other = try call("project_create",["name":"Other project","key_prefix":"NT","root_path":otherRoot.path])
        let otherTask = try call("task_create",["project_id":other["id"]!,"title":"Other project data"])
        let otherID = uuid();_ = try call("session_register",["project_id":other["id"]!,"session_id":otherID,"provider":"codex","role":"worker","installation":"other-project-worker","workspace":otherRoot.path])
        let otherWorker = Caller(role:"worker",installation:"other-project-worker",projectIDs:[other["id"] as! String],sessionID:otherID,workspace:otherRoot.path)
        let otherRequest = try call("human_request_create",["project_id":other["id"]!,"task_id":otherTask["id"]!,"questions":[["id":"q","prompt":"FOREIGN_PRIVATE_PROMPT"]]],otherWorker)
        _ = try call("human_request_answer",["project_id":other["id"]!,"request_id":otherRequest["id"]!,"expected_revision":1,"answers":[["question_id":"q","text":"FOREIGN_PRIVATE_ANSWER"]]])
        let broadCaller = Caller(role:"worker",installation:f.requester.installation,projectIDs:[f.project["id"] as! String,other["id"] as! String],sessionID:f.requester.sessionID,workspace:f.requester.workspace)
        let scoped = try XCTUnwrap(notice(envelope("service_info",[:],broadCaller)))
        XCTAssertTrue((scoped["items"] as! [JSON]).allSatisfy {$0["project_id"] as? String == f.project["id"] as? String})
        XCTAssertFalse(try jsonString(scoped).contains(otherRequest["id"] as! String))
        let session = try router.dbQueue.read {try router.record($0,f.requester.sessionID!,type:"session")}
        _ = try call("session_update",["project_id":f.project["id"]!,"session_id":f.requester.sessionID!,"expected_revision":session["revision"]!,"state":"revoked"])
        XCTAssertNil(notice(try envelope("service_info",[:],f.requester)))
        let assistant = Caller(role:"assistant",installation:"assistant",projectIDs:[f.project["id"] as! String],sessionID:f.requester.sessionID,assistantGrants:[f.project["id"] as! String:["read":true,"receive_messages":true]])
        XCTAssertNil(notice(try envelope("service_info",[:],assistant)))
    }
}
