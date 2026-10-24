import Foundation
@testable import ChecklistCore

/// Existing fixtures that test other behavior create a real synthetic Epic too.
/// Required-Epic negative tests deliberately call the router without this helper.
func appFixtureTaskInput(_ router: CommandRouter,method: String,input: JSON) throws -> JSON {
    guard method == "task_create",input["epic_id"] == nil,let project=input["project_id"] as? String else {return input}
    let owner=Caller(role:"owner",installation:"required-epic-fixture",projectIDs:[])
    let groups=try router.handle(method:"epic_list",params:["project_id":project],caller:owner)["data"] as! JSON
    let current=(groups["groups"] as? [JSON] ?? []).first {!bool($0,"archived")}
    let epic: JSON
    if let current {epic=current}
    else {epic=try router.handle(method:"epic_create",params:["command_id":uuid(),"project_id":project,"name":"Fixture tickets"],caller:owner)["data"] as! JSON}
    var value=input;value["epic_id"]=epic["id"];return value
}
