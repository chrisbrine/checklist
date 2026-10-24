import XCTest
import GRDB
@testable import ChecklistCore

extension CoreTests {
    private func epicCall(_ method:String,_ input:JSON) throws -> JSON {
        var p=input;if !CommandRouter.readMethods.contains(method) {p["command_id"]=uuid()}
        return try router.handle(method:method,params:p,caller:owner)["data"] as! JSON
    }
    func testRequiredEpicCreateErrorsListChoicesAndLeaveNoTicketOrCounterChange() throws {
        let p=try project(),pid=p["id"] as! String
        let epic=try call("epic_create",["project_id":pid,"name":"Concrete work"])
        for value:Any? in [nil,NSNull(),"","  ",42] {
            var input:JSON=["project_id":pid,"title":"Refuse"]
            input["epic_id"]=value
            XCTAssertThrowsError(try epicCall("task_create",input)) {
                XCTAssertEqual(($0 as? CoreError)?.code,"EPIC_REQUIRED")
                XCTAssertEqual(((($0 as? CoreError)?.details["epics"] as? [JSON])?.first)?["id"] as? String,epic["id"] as? String)
            }
        }
        let created=try epicCall("task_create",["project_id":pid,"title":"Captured","epic_id":epic["id"]!])
        XCTAssertEqual(created["key"] as? String,"T-1");XCTAssertEqual(created["needs_epic"] as? Bool,false)
        let other=try project("Other","O"),foreign=try call("epic_create",["project_id":other["id"]!,"name":"Foreign"])
        assertCode("NOT_FOUND") {_ = try self.epicCall("task_create",["project_id":pid,"title":"No cross-project Epic","epic_id":foreign["id"]!])}
        let triage=try call("triage_create",["project_id":pid,"name":"Handling"])
        assertCode("INVALID_INPUT") {_ = try self.epicCall("task_create",["project_id":pid,"title":"No Triage","epic_id":triage["id"]!])}
    }
    func testRequiredEpicCannotClearEditBulkOrMembershipAndMoveRetainsTriage() throws {
        let p=try project(),pid=p["id"] as! String,t=try task(p)
        let old=try call("epic_list",["project_id":pid])["groups"] as! [JSON]
        for value:Any in [NSNull(),"",42] {assertCode("EPIC_REQUIRED") {_ = try self.epicCall("task_edit",["project_id":pid,"task_id":t["id"]!,"expected_revision":t["revision"]!,"patch":["title":"No change","epic_id":value]])}}
        assertCode("EPIC_REQUIRED") {_ = try self.epicCall("task_bulk_edit",["project_id":pid,"tasks":[["task_id":t["id"]!,"expected_revision":t["revision"]!]],"changes":["kind":"epic","epic_id":NSNull()],"preview":false])}
        assertCode("EPIC_REQUIRED") {_ = try self.epicCall("group_membership",["project_id":pid,"group_id":old[0]["id"]!,"expected_revision":old[0]["revision"]!,"task_id":t["id"]!,"action":"remove"])}
        let target=try call("epic_create",["project_id":pid,"name":"Destination"])
        var triage=try call("triage_create",["project_id":pid,"name":"Implementation"])
        triage=try call("group_membership",["project_id":pid,"group_id":triage["id"]!,"expected_revision":triage["revision"]!,"task_id":t["id"]!,"action":"add"])
        let moved=try epicCall("task_bulk_edit",["project_id":pid,"tasks":[["task_id":t["id"]!,"expected_revision":t["revision"]!]],"changes":["kind":"epic","epic_id":target["id"]!],"preview":false])
        XCTAssertEqual(moved["affected_count"] as? Int,1)
        let read=try epicCall("task_get",["project_id":pid,"task_id":t["id"]!]);XCTAssertEqual(read["epic_id"] as? String,target["id"] as? String);XCTAssertEqual(read["title"] as? String,t["title"] as? String)
        let groups=try call("triage_list",["project_id":pid])["groups"] as! [JSON];XCTAssertTrue(strings(groups.first {$0["id"] as? String == triage["id"] as? String}!,"task_ids").contains(t["id"] as! String))
    }
    func testRequiredEpicLegacyReadsFlagAndRepairAndSharedSaveBoundary() throws {
        let p=try project(),pid=p["id"] as! String,t=try task(p),tid=t["id"] as! String
        // Emulate retained pre-rule bytes, never a production migration or live edit.
        try router.dbQueue.writeWithoutTransaction {db in try db.execute(sql:"UPDATE records SET data=json_remove(data,'$.epic_id') WHERE id=?",arguments:[tid])}
        let read=try epicCall("task_get",["project_id":pid,"task_id":tid]);XCTAssertEqual(read["needs_epic"] as? Bool,true)
        let list=try epicCall("task_list",["project_id":pid,"fields":["needs_epic"]])["tasks"] as! [JSON];XCTAssertEqual(list.first?["needs_epic"] as? Bool,true)
        let context=try epicCall("task_context",["project_id":pid,"task_id":tid]);XCTAssertEqual((context["task"] as? JSON)?["needs_epic"] as? Bool,true)
        assertCode("EPIC_REQUIRED") {_ = try self.epicCall("task_edit",["project_id":pid,"task_id":tid,"expected_revision":t["revision"]!,"patch":["title":"Unrepaired"]])}
        assertCode("EPIC_REQUIRED") {try self.router.dbQueue.writeWithoutTransaction {db in try self.router.withValidatedDomainTransaction(db) {var created=t;created["id"]=uuid();created.removeValue(forKey:"epic_id");try self.router.save(db,created,type:"task");return .commit}}}
        let fixed=try epicCall("task_edit",["project_id":pid,"task_id":tid,"expected_revision":t["revision"]!,"patch":["epic_id":t["epic_id"]!]])
        XCTAssertEqual(fixed["needs_epic"] as? Bool,false)
        // A linked successor's creator explicitly carries the source's primary Epic.
        let successor=try epicCall("task_create",["project_id":pid,"title":"Successor","epic_id":fixed["epic_id"]!])
        XCTAssertEqual(successor["epic_id"] as? String,fixed["epic_id"] as? String)
    }
    func testRequiredEpicArchiveRefusesLiveMembersAndAllowsAfterMove() throws {
        let p=try project(),pid=p["id"] as! String,t=try task(p)
        let epic=(try call("epic_list",["project_id":pid])["groups"] as! [JSON])[0]
        assertCode("EPIC_IN_USE") {_ = try self.epicCall("epic_edit",["project_id":pid,"epic_id":epic["id"]!,"expected_revision":epic["revision"]!,"archived":true])}
        let destination=try call("epic_create",["project_id":pid,"name":"Destination"])
        _ = try epicCall("task_bulk_edit",["project_id":pid,"tasks":[["task_id":t["id"]!,"expected_revision":t["revision"]!]],"changes":["kind":"epic","epic_id":destination["id"]!],"preview":false])
        let source=(try call("epic_list",["project_id":pid])["groups"] as! [JSON]).first {$0["id"] as? String == epic["id"] as? String}!
        let archived=try epicCall("epic_edit",["project_id":pid,"epic_id":source["id"]!,"expected_revision":source["revision"]!,"archived":true]);XCTAssertTrue(bool(archived,"archived"))
    }
    func testRequiredEpicWorkerRefusalsListScopedChoices() throws {
        let workspace=directory.appendingPathComponent("epic-worker-workspace");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let p=try call("project_create",["name":"Scoped worker capture","key_prefix":"W","root_path":workspace.path]),pid=p["id"] as! String,epic=try call("epic_create",["project_id":pid,"name":"Worker work"]),sid=uuid()
        _ = try call("session_register",["project_id":pid,"session_id":sid,"role":"worker","provider":"codex","installation":"required-epic-worker"])
        let worker=Caller(role:"worker",installation:"required-epic-worker",projectIDs:[pid],sessionID:sid,workspace:workspace.path)
        for value:Any? in [nil,NSNull(),"",42] {
            var input:JSON=["command_id":uuid(),"project_id":pid,"title":"Worker capture"];input["epic_id"]=value
            XCTAssertThrowsError(try router.handle(method:"task_create",params:input,caller:worker)) {
                XCTAssertEqual(($0 as? CoreError)?.code,"EPIC_REQUIRED")
                XCTAssertEqual(((($0 as? CoreError)?.details["epics"] as? [JSON])?.first)?["id"] as? String,epic["id"] as? String)
            }
        }
    }

}
