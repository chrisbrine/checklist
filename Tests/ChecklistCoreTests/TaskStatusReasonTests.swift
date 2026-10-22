import XCTest
import GRDB
@testable import ChecklistCore

extension CoreTests {
    func testStatusReasonSetProjectsEverywhereSurvivesNotesAndClearsWithHistory() throws {
        let p = try project(), initial = try ready(p,task(p))
        let scope: JSON = ["project_id":p["id"]!,"task_id":initial["id"]!]
        let text = "Waiting for installed evidence.\nKeep the complete explanation."
        var params = scope;params["expected_revision"] = initial["revision"];params["action"] = "block";params["reason"] = text
        let blocked = try call("task_transition",params)
        let reason = try XCTUnwrap(blocked["status_reason"] as? JSON)
        XCTAssertEqual(reason["text"] as? String,text);XCTAssertEqual(reason["actor"] as? String,owner.principal)
        XCTAssertEqual(reason["actor_display"] as? String,"You");XCTAssertNotNil(ISO8601DateFormatter().date(from:reason["at"] as? String ?? ""))
        _ = try call("message_send",scope.merging(["body":"A note must not replace the reason"]) {_,new in new})
        let edited = try call("task_edit",scope.merging(["expected_revision":blocked["revision"]!,"patch":["title":"Updated title","planned_assignee":"human"]]) {_,new in new})
        let sources: [JSON] = [
            try call("task_get",scope),
            try call("task_context",scope)["task"] as! JSON,
            try call("task_context",scope.merging(["detail_level":"ui"]) {_,new in new})["task"] as! JSON,
            ((try call("task_list",["project_id":p["id"]!,"view":["surface":"tickets","status_filter":"all","tag_filter":"all","group_by":"none","order_by":"manual"]])["tickets_page"] as! JSON)["tasks"] as! [JSON]).first!,
            (try call("snapshot")["tasks"] as! [JSON]).first!,
            (try call("task_list",["project_id":p["id"]!])["tasks"] as! [JSON]).first!,
            (try call("workspace_page",["project_id":p["id"]!,"surface":"human_tasks"])["rows"] as! [JSON]).first!
        ]
        for task in sources {XCTAssertEqual(try jsonString(task["status_reason"] as! JSON),try jsonString(reason))}
        let queued = try call("task_transition",scope.merging(["expected_revision":edited["revision"]!,"action":"queue"]) {_,new in new})
        XCTAssertNil(queued["status_reason"])
        XCTAssertNil((try call("task_context",scope)["task"] as! JSON)["status_reason"])
        let history = try call("history_list",scope)["events"] as! [JSON]
        XCTAssertTrue(history.contains {($0["data"] as? JSON)?["reason"] as? String == text})
    }

    func testStatusReasonReleaseAndBatchReleaseClearOnNextClaim() throws {
        let p = try project(), first = try ready(p,task(p)), second = try ready(p,task(p)), group = try triage(p)
        try addTriage(p,group,first);try addTriage(p,group,second)
        let batch = try prepareImplementationBatch(p,group,[first,second]), claims = try claimFixedBatch(p,batch)["claims"] as! [JSON]
        let released = try call("batch_release",["project_id":p["id"]!,"batch_id":batch["id"]!,"members":claims.map {["attempt_id":$0["id"]!,"claim_token":$0["claim_token"]!]},"reason":"Wait for another build"])
        for task in released["results"] as! [JSON] {
            XCTAssertEqual(task["status_category"] as? String,"queued")
            XCTAssertEqual((task["status_reason"] as? JSON)?["text"] as? String,"Wait for another build")
        }
        let groupRows = try call("workspace_page",["project_id":p["id"]!,"surface":"triage_tasks","record_id":group["id"]!])["rows"] as! [JSON]
        XCTAssertEqual(groupRows.count,2)
        XCTAssertTrue(groupRows.allSatisfy {($0["status_reason"] as? JSON)?["text"] as? String == "Wait for another build"})
        let current = try call("task_get",["project_id":p["id"]!,"task_id":first["id"]!])
        let claim = try call("work_claim",["project_id":p["id"]!,"task_id":first["id"]!,"expected_revision":current["revision"]!,"phase":"implementation"])
        XCTAssertNil((claim["task"] as! JSON)["status_reason"])
        let single = try call("work_release",["project_id":p["id"]!,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"reason":"Waiting for owner input"])
        XCTAssertEqual((single["status_reason"] as? JSON)?["text"] as? String,"Waiting for owner input")
        let scope: JSON = ["project_id":p["id"]!,"task_id":first["id"]!]
        XCTAssertEqual(((try call("task_context",scope)["task"] as! JSON)["status_reason"] as? JSON)?["text"] as? String,"Waiting for owner input")
        let history = try call("history_list",scope)["events"] as! [JSON]
        let reasons = history.compactMap {($0["data"] as? JSON)?["reason"] as? String}
        XCTAssertTrue(reasons.contains("Wait for another build"));XCTAssertTrue(reasons.contains("Waiting for owner input"))
    }

    func testStatusReasonReviewReleaseHasAttributionAndClearsOnReclaim() throws {
        let p = try project(), tasks = try [ready(p,task(p)),ready(p,task(p))], group = try triage(p)
        for task in tasks {try addTriage(p,group,task)}
        let batch = try prepareImplementationBatch(p,group,tasks), claims = try claimFixedBatch(p,batch)["claims"] as! [JSON]
        _ = try call("batch_submit",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"members":try claims.map {try batchArtifactInput(p,$0)}])
        let reviewGroup = try triage(p,phase:"review")
        for task in tasks {try addTriage(p,reviewGroup,task)}
        let reviewer = Caller(role:"owner",installation:"status-reason-reviewer",projectIDs:[])
        let prepared = try prepareReviewBatch(p,reviewGroup,tasks,reviewer), reviews = try claimFixedBatch(p,prepared,reviewer)["claims"] as! [JSON]
        let release = try call("work_release",["project_id":p["id"]!,"attempt_id":reviews[0]["id"]!,"claim_token":reviews[0]["claim_token"]!,"reason":"Another reviewer should check the native build"],reviewer)
        XCTAssertEqual(release["status_category"] as? String,"review")
        let reason = try XCTUnwrap(release["status_reason"] as? JSON)
        XCTAssertEqual(reason["actor"] as? String,reviewer.principal)
        XCTAssertEqual(reason["text"] as? String,"Another reviewer should check the native build")
        let reclaimed = try call("work_claim",["project_id":p["id"]!,"task_id":tasks[0]["id"]!,"expected_revision":release["revision"]!,"phase":"review","review_request_id":reviews[0]["review_request_id"]!,"target_manifest_id":reviews[0]["manifest_id"]!,"gate":"review"],reviewer)
        XCTAssertNil((reclaimed["task"] as! JSON)["status_reason"])
    }

    func testStatusReasonLegacyIndexedReadIgnoresOtherHistoryAndStatusBoundaries() throws {
        let p = try project(), t = try ready(p,task(p)), tid = t["id"] as! String, pid = p["id"] as! String
        let queued = t["status_id"] as! String
        try router.dbQueue.write {db in
            let sql = "INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data) VALUES (?,?,?,?,?,?,?)"
            // Legacy release: no newly captured display or status ID.
            try db.execute(sql:sql,arguments:[UUID().uuidString,pid,tid,"legacy:worker","work_released","2026-10-22T20:00:00Z","{\"reason\":\"Legacy release\"}"])
            for index in 0..<250 {
                try db.execute(sql:sql,arguments:[UUID().uuidString,pid,tid,"legacy:worker","note","2026-10-22T20:00:00Z","not decoded"])
                try db.execute(sql:sql,arguments:[UUID().uuidString,pid,"other-\(index)","other","work_released","2026-10-22T20:00:00Z","not decoded"])
            }
        }
        let reason = try call("task_get",["project_id":pid,"task_id":tid])["status_reason"] as! JSON
        XCTAssertEqual(reason["text"] as? String,"Legacy release");XCTAssertEqual(reason["actor"] as? String,"legacy:worker");XCTAssertEqual(reason["actor_display"] as? String,"Agent")
        for kind in ["work_claimed","work_submitted","task_completed","claim_revoked","review_reject","human_approval_reject","work_released_native_closure"] {
            try router.dbQueue.write {db in
                try router.event(db,caller:owner,project:pid,entity:tid,kind:kind)
                XCTAssertNil(try router.currentStatusReason(db,task:t),kind)
            }
        }
        // Status ID mismatch must not revive a historical reason (e.g. taxonomy remap).
        try router.dbQueue.write {db in
            try router.event(db,caller:owner,project:pid,entity:tid,kind:"status_changed",data:["reason":"Same status"])
            var other = t;other["status_id"] = "different-from-" + queued
            XCTAssertNil(try router.currentStatusReason(db,task:other))
            let plan = try Row.fetchAll(db,sql:"EXPLAIN QUERY PLAN SELECT data FROM events WHERE project_id=? AND entity_id=? AND kind IN ('task_transitioned','work_released') ORDER BY seq DESC LIMIT 1",arguments:[pid,tid])
            XCTAssertTrue(plan.contains {($0["detail"] as String).contains("events_scope")})
        }
    }
}

extension CoreTests {
    func testStatusReasonSelectableListFieldShowsAndClears() throws {
        let p = try project(), initial = try ready(p,task(p)), pid = p["id"]!, tid = initial["id"]!
        let scope: JSON = ["project_id":pid,"task_id":tid]
        let list: JSON = ["project_id":pid,"fields":["status_reason"]]
        XCTAssertNil((try call("task_list",list)["tasks"] as! [JSON])[0]["status_reason"])
        let blocked = try call("task_transition",scope.merging(["expected_revision":initial["revision"]!,"action":"block","reason":"Waiting for the native runner"]) {_,new in new})
        let row = (try call("task_list",list)["tasks"] as! [JSON])[0]
        XCTAssertEqual(Set(row.keys),["id","key","revision","status_reason"])
        XCTAssertEqual((row["status_reason"] as? JSON)?["text"] as? String,"Waiting for the native runner")
        let empty = try call("task_list",list.merging(["keys":["missing"]]) {_,new in new})
        XCTAssertTrue((empty["tasks"] as! [JSON]).isEmpty)
        _ = try call("task_transition",scope.merging(["expected_revision":blocked["revision"]!,"action":"queue"]) {_,new in new})
        let cleared = (try call("task_list",list)["tasks"] as! [JSON])[0]
        XCTAssertNil(cleared["status_reason"])
        XCTAssertEqual(Set(cleared.keys),["id","key","revision"])
    }
}
