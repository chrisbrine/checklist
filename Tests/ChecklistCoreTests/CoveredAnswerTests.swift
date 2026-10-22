import XCTest
@testable import ChecklistCore

final class CoveredAnswerTests: XCTestCase {
    var root: URL!
    var router: CommandRouter!
    let owner = Caller(role:"owner",installation:"covered-answer-tests",projectIDs:[])
    override func setUpWithError() throws {
        root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/CoveredAnswerTests/\(uuid())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        router = try CommandRouter(root:root)
    }
    override func tearDownWithError() throws { router = nil; try? FileManager.default.removeItem(at:root) }
    @discardableResult func call(_ method: String,_ params: JSON,_ caller: Caller? = nil) throws -> JSON {
        var p = params; if !CommandRouter.readMethods.contains(method) { p["command_id"] = uuid() }
        return try router.handle(method:method,params:p,caller:caller ?? owner)["data"] as! JSON
    }
    func fixture() throws -> (JSON,JSON,Caller) {
        let workspace = root.appendingPathComponent("workspace");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let project = try call("project_create",["name":"Covered answers","key_prefix":"CA","root_path":workspace.path])
        let task = try call("task_create",["project_id":project["id"]!,"title":"First ticket"])
        let sid = uuid()
        _ = try call("session_register",["project_id":project["id"]!,"session_id":sid,"role":"worker","provider":"codex","installation":"covered-worker"])
        return (project,task,Caller(role:"worker",installation:"covered-worker",projectIDs:[project["id"] as! String],sessionID:sid,workspace:workspace.path))
    }
    func input(_ project: JSON,_ task: JSON,title: String = "Owner decision",prompt: String = "Choose a direction",type: String = "text") -> JSON {
        ["project_id":project["id"]!,"task_id":task["id"]!,"title":title,"blocking":false,"questions":[["id":"q","prompt":prompt,"type":type]]]
    }
    func answer(_ request: JSON,value: String = "Use blue",type: String = "text") throws -> JSON {
        try call("human_request_answer",["project_id":request["project_id"]!,"request_id":request["id"]!,"expected_revision":request["revision"]!,"answers":[["question_id":"q",type == "text" ? "text" : "result":value]]])
    }
    @discardableResult func covered(_ p: JSON,_ worker: Caller,file: StaticString = #filePath,line: UInt = #line) -> CoreError? {
        do { _ = try call("human_request_create",p,worker); XCTFail("Expected coverage refusal",file:file,line:line) }
        catch let error as CoreError { XCTAssertEqual(error.code,"COVERED_BY_EARLIER_ANSWER",file:file,line:line); return error }
        catch { XCTFail("\(error)",file:file,line:line) }
        return nil
    }
    func testSameTicketApprovalListsEarlierAnswerIncludingNeedsChanges() throws {
        let (p,t,w) = try fixture()
        for outcome in ["approved","changes_requested","declined"] {
            var original = input(p,t,title:"Earlier \(outcome)",prompt:"Approve \(outcome)?",type:"approval")
            if outcome != "approved" {
                let prior = try call("task_context",["project_id":p["id"]!,"task_id":t["id"]!])["requests"] as! [JSON]
                original["supersedes_answer_id"] = prior[0]["id"]!; original["supersede_reason"] = "Candidate changed"
            }
            let r = try answer(call("human_request_create",original,w),value:outcome,type:"approval")
            let response = (r["responses"] as! [JSON])[0]
            let error = try XCTUnwrap(covered(input(p,t,title:"Different title",prompt:"Approve a different candidate?",type:"approval"),w))
            let matches = try XCTUnwrap(error.details["matches"] as? [JSON])
            let match = try XCTUnwrap(matches.first {$0["request_id"] as? String == r["id"] as? String})
            for key in ["request_id","answer_id","task_id","key","title","matching_question_text","answer_summary","answered_at"] { XCTAssertTrue(error.message.contains("\(match[key]!)"),key) }
            XCTAssertEqual(match["answer_id"] as? String,response["id"] as? String)
            XCTAssertEqual(match["task_id"] as? String,t["id"] as? String)
            XCTAssertEqual((match["answers"] as! [JSON])[0]["result"] as? String,outcome)
        }
    }
    func testProjectWideNormalizedTitleAndQuestionMatchesAcrossTickets() throws {
        let (p,t,w) = try fixture(),other = try call("task_create",["project_id":p["id"]!,"title":"Second ticket"])
        let r = try answer(call("human_request_create",input(p,t,title:"  Owner\tDirection \n",prompt:"Which\n color?"),w))
        for candidate in [input(p,other,title:"OWNER direction",prompt:"Unrelated prompt"),input(p,other,title:"Different",prompt:"  WHICH color?  "),input(p,other,title:"which color?",prompt:"Different prompt"),input(p,other,title:"Different title",prompt:"owner direction")] {
            let matches = try XCTUnwrap(covered(candidate,w)?.details["matches"] as? [JSON])
            XCTAssertEqual(matches.count,1); XCTAssertEqual(matches[0]["request_id"] as? String,r["id"] as? String)
        }
    }
    func testOtherProjectAndUnmatchedRequestsAreAllowed() throws {
        let (p,t,w) = try fixture()
        _ = try answer(call("human_request_create",input(p,t),w))
        let other = try call("project_create",["name":"Other project","key_prefix":"OT"]),task = try call("task_create",["project_id":other["id"]!,"title":"Other ticket"])
        XCTAssertEqual(try call("human_request_create",input(other,task))["state"] as? String,"pending")
        XCTAssertEqual(try call("human_request_create",input(p,t,title:"A fresh decision",prompt:"New question"),w)["state"] as? String,"pending")
    }
    func testSupersedeAcceptsAnswerOrRequestIDAndPersistsInReads() throws {
        let (p,t,w) = try fixture(),r = try answer(call("human_request_create",input(p,t),w))
        for id in [r["id"]!, (r["responses"] as! [JSON])[0]["id"]!] {
            var candidate = input(p,t);candidate["supersedes_answer_id"] = id;candidate["supersede_reason"] = "New owner requirements changed the candidate"
            let created = try call("human_request_create",candidate,w)
            let requests = try call("task_context",["project_id":p["id"]!,"task_id":t["id"]!],w)["requests"] as! [JSON]
            let stored = try XCTUnwrap(requests.first {$0["id"] as? String == created["id"] as? String})
            XCTAssertEqual(stored["supersedes_answer_id"] as? String,id as? String)
            XCTAssertEqual(stored["supersede_reason"] as? String,candidate["supersede_reason"] as? String)
        }
    }
    func testWrongIDMissingOrEmptyReasonAndUnmatchedSupersedeAreInvalid() throws {
        let (p,t,w) = try fixture(),r = try answer(call("human_request_create",input(p,t),w))
        for extra: JSON in [["supersedes_answer_id":"wrong","supersede_reason":"Changed"],["supersedes_answer_id":r["id"]!,"supersede_reason":" \n "],["supersedes_answer_id":r["id"]!],["supersede_reason":"Changed"]] {
            var candidate = input(p,t);candidate.merge(extra) { _,new in new }
            XCTAssertThrowsError(try call("human_request_create",candidate,w)) { XCTAssertEqual(($0 as? CoreError)?.code,"INVALID_INPUT") }
        }
        var fresh = input(p,t,title:"Fresh",prompt:"Fresh question");fresh["supersedes_answer_id"] = r["id"]!;fresh["supersede_reason"] = "Changed"
        XCTAssertThrowsError(try call("human_request_create",fresh,w)) { XCTAssertEqual(($0 as? CoreError)?.code,"INVALID_INPUT") }
    }
    func testCanceledAndClarificationWithoutAnAnswerDoNotCover() throws {
        let (p,t,w) = try fixture(),r = try call("human_request_create",input(p,t),w)
        let clarified = try call("human_request_answer",["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":r["revision"]!,"response":"clarify","explanation":"Need more context"])
        _ = try call("human_request_cancel",["project_id":p["id"]!,"request_id":r["id"]!,"expected_revision":clarified["revision"]!],w)
        XCTAssertEqual(try call("human_request_create",input(p,t),w)["state"] as? String,"pending")
    }
}

extension CoveredAnswerTests {
    func testReviewerNotCheckedThenCanceledDoesNotCoverApproval() throws {
        let (p,t,w) = try fixture()
        let original = try call("human_request_create",input(p,t,title:"Old candidate",prompt:"Approve old candidate?",type:"approval"),w)
        let unchecked = try call("human_request_answer",["project_id":p["id"]!,"request_id":original["id"]!,"expected_revision":original["revision"]!,"response":"clarification","explanation":"Not checked","answers":[["question_id":"q","result":"not_checked"]]])
        XCTAssertEqual(unchecked["state"] as? String,"pending")
        XCTAssertEqual((unchecked["responses"] as! [JSON])[0]["complete"] as? Bool,false)
        _ = try call("human_request_cancel",["project_id":p["id"]!,"request_id":unchecked["id"]!,"expected_revision":unchecked["revision"]!],w)
        let next = try call("human_request_create",input(p,t,title:"New candidate",prompt:"Approve new candidate?",type:"approval"),w)
        XCTAssertEqual(next["state"] as? String,"pending")
    }
    func testReviewerUnansweredOptionalApprovalDoesNotCoverApproval() throws {
        let (p,t,w) = try fixture()
        var params = input(p,t,title:"Earlier text decision",prompt:"Tell us the theme")
        params["questions"] = [["id":"q","prompt":"Tell us the theme","type":"text"],["id":"optional","prompt":"Optional old approval?","type":"approval","required":false]]
        let original = try call("human_request_create",params,w)
        let answered = try answer(original)
        XCTAssertEqual(answered["state"] as? String,"answered")
        XCTAssertEqual((answered["responses"] as! [JSON])[0]["answers"] as? [JSON] != nil,true)
        XCTAssertEqual(((answered["responses"] as! [JSON])[0]["answers"] as! [JSON]).count,1)
        let next = try call("human_request_create",input(p,t,title:"New approval decision",prompt:"Approve this candidate?",type:"approval"),w)
        XCTAssertEqual(next["state"] as? String,"pending")
    }
}
