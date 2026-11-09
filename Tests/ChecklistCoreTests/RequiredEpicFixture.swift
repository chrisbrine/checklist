import Foundation
import GRDB
@testable import ChecklistCore

/// Existing fixtures that test other behavior create a real synthetic Epic too.
/// Required-Epic negative tests deliberately call the router without this helper.
func fixtureTaskInput(_ router: CommandRouter,method: String,input: JSON) throws -> JSON {
    guard method == "task_create",input["epic_id"] == nil,let project=input["project_id"] as? String else {return input}
    let owner=Caller(role:"owner",installation:"required-epic-fixture",projectIDs:[])
    // Preparation needs only an existing Epic ID. Avoid projecting the full
    // Epic list and every member ticket before each unrelated task_create.
    // Re-read current rows so archived/deleted Epics cannot leak across cases.
    let current=try router.dbQueue.read {db in
        try router.records(db,type:"group",project:project).first {$0["kind"] as? String == "epic" && !bool($0,"archived")}
    }
    let epic: JSON
    if let current {epic=current}
    else {epic=try router.handle(method:"epic_create",params:["command_id":uuid(),"project_id":project,"name":"Fixture tickets"],caller:owner)["data"] as! JSON}
    var value=input;value["epic_id"]=epic["id"];return value
}

/// Low-level synthetic projection fixtures also satisfy the domain invariant.
func fixtureDomainValue(_ router:CommandRouter,db:Database,value:JSON,type:String) throws -> JSON {
    guard type == "task",value["epic_id"] == nil,!bool(value,"purged"),let pid=value["project_id"] as? String else {return value}
    let id="fixture-primary-epic:"+pid
    if (try? router.record(db,id,type:"group")) == nil {
        try router.save(db,["id":id,"project_id":pid,"revision":1,"kind":"epic","name":"Fixture tickets"],type:"group")
    }
    var result=value;result["epic_id"]=id;return result
}
