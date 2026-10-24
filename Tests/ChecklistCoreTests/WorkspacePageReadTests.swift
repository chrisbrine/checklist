import XCTest
import GRDB
@testable import ChecklistCore

extension CoreTests {
    func testWorkspacePagesRetainExactScopeCountsAndFiniteContinuation()throws {
        let p=try project("Page scope"),foreign=try project("Foreign page"),t=try task(p)
        let pid=p["id"] as! String,tid=t["id"] as! String
        try router.dbQueue.writeWithoutTransaction {db in try router.withValidatedDomainTransaction(db) {
            for i in 0..<121 {try router.save(db,["id":"request-page-\(i)","project_id":pid,"task_id":tid,"title":"Owner question \(i)","state":"pending","blocking":i%2==0,"created_at":"2026-01-01T00:00:00Z","revision":1],type:"request")}
            try router.save(db,["id":"foreign-question","project_id":foreign["id"]!,"title":"PRIVATE QUERY MARKER","state":"pending","revision":1],type:"request")
            return .commit
        }}
        var cursor:String?,ids:[String]=[],pages=0
        repeat {
            var query:JSON=["project_id":pid,"surface":"requests","limit":50];query["cursor"]=cursor
            let page=try call("workspace_page",query),rows=page["rows"] as! [JSON]
            XCTAssertEqual(page["total"] as? Int,121);XCTAssertLessThanOrEqual(rows.count,50)
            XCTAssertFalse(try jsonString(page).contains("PRIVATE QUERY MARKER"))
            XCTAssertTrue(rows.allSatisfy {$0["task_key"] as? String == t["key"] as? String})
            ids += rows.compactMap {$0["id"] as? String};cursor=page["next_cursor"] as? String;pages += 1
            XCTAssertLessThanOrEqual(pages,3)
        } while cursor != nil
        XCTAssertEqual(ids.count,121);XCTAssertEqual(Set(ids).count,121)
        let worker=Caller(role:"worker",installation:"workspace-page-worker",projectIDs:[pid],workspace:directory.path)
        let before=try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM cursors")}
        XCTAssertThrowsError(try call("workspace_page",["project_id":pid,"surface":"requests"],worker))
        let after=try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM cursors")}
        XCTAssertEqual(before,after)
    }
    func testWorkspaceNeedsYouCountIsGlobalUnfilteredAndExcludesEveryClosedState() throws {
        let p = try project("Count scope"), foreign = try project("Foreign count"), t = try task(p), owned = try task(foreign)
        let pid = p["id"] as! String
        try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {
            for (id, project, state, snoozed) in [("visible",pid,"pending",false),("hidden",pid,"pending",true),("foreign",foreign["id"] as! String,"pending",false),
                                                  ("answered",pid,"answered",false),("canceled",pid,"canceled",false),("superseded",pid,"superseded",false),("resolved",pid,"resolved",false)] {
                try router.save(db,["id":id,"project_id":project,"task_id":t["id"]!,"title":id,"state":state,"owner_snoozed":snoozed,"revision":1],type:"request")
            }
            var task = owned; task["planned_assignee"] = "human"
            try router.save(db,task,type:"task")
            return .commit
        }}
        for surface in ["requests","human_tasks","epics","overview"] {
            let page = try call("workspace_page",["project_id":pid,"surface":surface,"text":"no matching row","limit":1])
            XCTAssertEqual(page["needs_you_count"] as? Int,4,surface)
            if let groups = page["groups"] as? [String:JSON] {
                for (name,group) in groups { XCTAssertNil(group["needs_you_count"],"Shared count occurs once: \(name)") }
            } else { XCTAssertEqual(page["total"] as? Int,0) }
        }
        _ = try call("human_request_cancel",["project_id":pid,"request_id":"visible","expected_revision":1])
        let refreshed = try call("workspace_page",["project_id":pid,"surface":"requests"])
        XCTAssertEqual(refreshed["total"] as? Int,0)
        XCTAssertEqual(refreshed["needs_you_count"] as? Int,3)
    }
    func testWorkspaceActivityAndSelectedRecordNeverInstallForeignCorpus()throws {
        let p=try project("Activity scope"),foreign=try project("Other activity"),t=try task(p)
        let pid=p["id"] as! String,tid=t["id"] as! String
        try router.dbQueue.writeWithoutTransaction {db in try router.withValidatedDomainTransaction(db) {
            try router.save(db,["id":"selected-request","project_id":pid,"task_id":tid,"title":"Selected","state":"pending","revision":1],type:"request")
            try router.save(db,["id":"foreign-request","project_id":foreign["id"]!,"title":"PRIVATE selected","state":"pending","revision":1],type:"request")
            for _ in 0..<155 {try router.event(db,caller:owner,project:pid,entity:tid,kind:"task_edited")}
            try router.event(db,caller:owner,project:foreign["id"] as? String,entity:nil,kind:"PRIVATE_activity")
            return .commit
        }}
        let selected=try call("workspace_page",["project_id":pid,"surface":"record","record_id":"selected-request"])
        XCTAssertEqual((selected["rows"] as! [JSON]).count,1)
        XCTAssertEqual(((selected["rows"] as! [JSON]).first?["selected_task"] as? JSON)?["id"] as? String,tid)
        let refused=try call("workspace_page",["project_id":pid,"surface":"record","record_id":"foreign-request"])
        XCTAssertEqual((refused["rows"] as! [JSON]).count,0)
        let first=try call("workspace_page",["project_id":pid,"surface":"activity","limit":50])
        XCTAssertEqual((first["rows"] as! [JSON]).count,50)
        XCTAssertFalse(try jsonString(first).contains("PRIVATE"))
        let second=try call("workspace_page",["project_id":pid,"surface":"activity","limit":50,"cursor":first["next_cursor"]!])
        XCTAssertEqual((second["rows"] as! [JSON]).count,50)
        XCTAssertThrowsError(try call("workspace_page",["project_id":foreign["id"]!,"surface":"activity","cursor":first["next_cursor"]!]))
    }
    func testWorkspaceEpicRowsHaveTruthfulCountsAndExplicitMembershipPages()throws {
        let p=try call("project_create",["name":"Scoped Epic","key_prefix":"EP","root_path":directory.path]),t=try task(p)
        let pid=p["id"] as! String,tid=t["id"] as! String
        let epic=try call("epic_create",["project_id":pid,"name":"Scoped Epic"])
        try router.dbQueue.writeWithoutTransaction {db in try router.withValidatedDomainTransaction(db) {
            var task=try router.record(db,tid,type:"task");task["epic_id"]=epic["id"];task=router.revised(task);try router.save(db,task,type:"task")
            return .commit
        }}
        let list=try call("workspace_page",["project_id":pid,"surface":"epics"])
        XCTAssertEqual((list["rows"] as! [JSON]).first {$0["id"] as? String == epic["id"] as? String}?["ticket_count"] as? Int,1)
        let members=try call("workspace_page",["project_id":pid,"surface":"epic_tasks","record_id":epic["id"]!])
        XCTAssertEqual((members["rows"] as! [JSON]).compactMap {$0["id"] as? String},[tid])
        let candidates=try call("workspace_page",["project_id":pid,"surface":"epic_candidates","record_id":epic["id"]!])
        XCTAssertFalse((candidates["rows"] as! [JSON]).contains {$0["id"] as? String==tid})
        // The canonical envelope join must not make any supported ordering
        // ambiguous. Exercise real SQL for every owner grouping/order and the
        // default worker page, with finite continuation and no omitted rows.
        let other=try task(p),otherID=other["id"] as! String
        for grouping in ["none","status","epic"] {
            for ordering in ["manual","priority","updated_desc"] {
                var cursor:String?,ids:[String]=[],pages=0
                repeat {
                    var params:JSON=["project_id":pid,"limit":1,"view":["surface":"tickets","status_filter":"all","tag_filter":"all","group_by":grouping,"order_by":ordering]]
                    params["cursor"]=cursor
                    let page=try call("task_list",params)["tickets_page"] as! JSON
                    XCTAssertEqual(page["matched_count"] as? Int,2)
                    ids += (page["tasks"] as! [JSON]).compactMap {$0["id"] as? String}
                    cursor=page["next_cursor"] as? String;pages += 1
                    XCTAssertLessThanOrEqual(pages,2)
                } while cursor != nil && pages<3
                XCTAssertEqual(Set(ids),Set([tid,otherID]));XCTAssertEqual(ids.count,2)
            }
        }
        let worker=Caller(role:"worker",installation:"workspace-order-worker",projectIDs:[pid],workspace:directory.path)
        let first=try call("task_list",["project_id":pid,"limit":1],worker)
        let second=try call("task_list",["project_id":pid,"limit":1,"cursor":first["next_cursor"]!],worker)
        XCTAssertEqual(Set(((first["tasks"] as! [JSON])+(second["tasks"] as! [JSON])).compactMap {$0["id"] as? String}),Set([tid,otherID]))
    }
}
