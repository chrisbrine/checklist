import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

final class ScopedTaskRecordsTests:XCTestCase {
    private var root:URL!
    private var router:CommandRouter!
    private var pid=""
    private var tid=""
    private let owner=Caller(role:"owner",installation:"scoped-context-fixture",projectIDs:[])
    override func setUpWithError()throws {
        let parent=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first!.appendingPathComponent("ChecklistSyntheticTests")
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        root=parent.appendingPathComponent("CL20-scoped-"+UUID().uuidString)
        router=try TestStore.router(root:root)
        pid=try call("project_create",["name":"Scoped synthetic","key_prefix":"SC","root_path":root.path])["id"] as! String
        tid=try call("task_create",["project_id":pid,"title":"Selected"])["id"] as! String
    }
    override func tearDownWithError()throws {router=nil;try? FileManager.default.removeItem(at:root)}
    private func call(_ method:String,_ p:JSON,_ caller:Caller?=nil)throws->JSON {
        var p=p;if !CommandRouter.readMethods.contains(method) {p["command_id"]=UUID().uuidString}
        return try router.handle(method:method,params:fixtureTaskInput(router,method:method,input:p),caller:caller ?? owner)["data"] as! JSON
    }
    private func write(_ body:(Database)throws->Void)throws {
        try router.dbQueue.writeWithoutTransaction {db in try router.withValidatedDomainTransaction(db) {try body(db);return .commit}}
    }
    func testSummaryScopesBeforeDecodeAndKeepsExactCountsAndContinuation()throws {
        let other=try call("task_create",["project_id":pid,"title":"Unrelated"])["id"] as! String
        try write {db in
            for i in 0..<81 {try router.save(db,["id":"selected-note-\(i)","project_id":pid,"task_id":tid,"body":"selected","revision":1],type:"message")}
            // Valid SQL/JSON envelope belonging to another task is intentionally
            // mismatched. A project-wide decode would fail this selected read.
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES (?,?,?,?,?)",arguments:["corrupt-unrelated",pid,"finding",1,try jsonString(["id":"wrong-id","project_id":pid,"task_id":other,"revision":1])])
        }
        let worker=Caller(role:"worker",installation:"scoped-worker",projectIDs:[pid],workspace:root.path)
        let summary=try call("task_context",["project_id":pid,"task_id":tid],worker)
        XCTAssertEqual((summary["counts"] as? JSON)?["messages"] as? Int,81)
        XCTAssertEqual((summary["recent_messages"] as? [JSON])?.count,10)
        XCTAssertEqual((summary["recent_messages"] as? [JSON])?.compactMap {$0["id"] as? String},(71..<81).map {"selected-note-\($0)"})
        XCTAssertEqual(summary["truncated"] as? Bool,true)
        XCTAssertFalse(try jsonString(summary).contains("corrupt-unrelated"))
        let first=try call("task_context",["project_id":pid,"task_id":tid,"detail_level":"full"],worker)
        let next=try call("task_context",["project_id":pid,"task_id":tid,"history_cursor":first["next_history_cursor"]!],worker)
        let ids=((first["records"] as! [JSON])+(next["records"] as! [JSON])).compactMap {$0["id"] as? String}
        XCTAssertEqual(ids.count,81);XCTAssertEqual(Set(ids).count,81)
    }
    func testLongAttachmentHistoryPagesWithoutMakingCurrentAuthorityIncomplete()throws {
        try write {db in for i in 0..<251 {try router.save(db,["id":"old-file-\(i)","project_id":pid,"task_id":tid,"name":"synthetic metadata","revision":1,"availability":"available"],type:"attachment")}}
        let display=try call("task_context",["task_id":tid,"detail_level":"ui"])
        let current=try call("task_context",["task_id":tid,"detail_level":"ui_records","selected_context_cursor":display["context_cursor"]!])
        XCTAssertEqual(current["complete"] as? Bool,true)
        XCTAssertEqual(current["current_scope_only"] as? Bool,true)
        XCTAssertEqual((current["history_counts"] as? JSON)?["attachments"] as? Int,251)
        XCTAssertEqual(((current["collections"] as! JSON)["attachments"] as! [JSON]).count,0)
        var cursor:String?,ids:[String]=[],pages=0
        repeat {
            var p:JSON=["task_id":tid,"detail_level":"ui_history","records_family":"attachment","selected_context_cursor":display["context_cursor"]!]
            p["cursor"]=cursor
            let page=try call("task_context",p);let rows=page["rows"] as! [JSON]
            XCTAssertLessThanOrEqual(rows.count,50);XCTAssertEqual(page["total"] as? Int,251)
            ids += rows.compactMap {$0["id"] as? String};cursor=page["next_cursor"] as? String;pages += 1
            XCTAssertLessThanOrEqual(pages,6)
        } while cursor != nil
        XCTAssertEqual(ids.count,251);XCTAssertEqual(Set(ids).count,251)
        let worker=Caller(role:"worker",installation:"scoped-worker",projectIDs:[pid],workspace:root.path)
        XCTAssertThrowsError(try call("task_context",["project_id":pid,"task_id":tid,"detail_level":"ui_history"],worker))
    }
    func testCompactBatchReferencesStayScopedAndFullContinuationRetainsNewestBatch()throws {
        let other=try call("task_create",["project_id":pid,"title":"Unrelated"])["id"] as! String
        try write {db in
            try router.save(db,["id":"scoped-epic","project_id":pid,"kind":"epic","name":"Selected Epic","revision":1],type:"group")
            try router.save(db,["id":"scoped-triage","project_id":pid,"kind":"triage","name":"Selected Triage","phase":"implementation","members":[["task_id":tid]],"revision":1],type:"group")
            var task=try router.scoped(db,tid,pid,type:"task");task["epic_id"]="scoped-epic";task["revision"]=2;try router.save(db,task,type:"task")
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES (?,?,?,?,?)",arguments:["corrupt-unrelated-task",pid,"task",1,try jsonString(["id":"different-task","project_id":pid,"status_id":task["status_id"]!,"revision":1])])
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES (?,?,?,?,?)",arguments:["corrupt-unrelated-membership",pid,"triage_membership_interval",1,try jsonString(["id":"different-membership","project_id":pid,"triage_id":"unrelated","revision":1])])
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES (?,?,?,?,?)",arguments:["corrupt-unrelated-attempt",pid,"attempt",1,try jsonString(["id":"different","project_id":pid,"task_id":other,"revision":1])])
            for i in 0..<11 {try router.save(db,["id":"batch-\(i)","project_id":pid,"phase":"implementation","members":[["task_id":tid,"task_revision":1]],"revision":1,"created_at":"2026-01-01T00:00:00Z"],type:"batch")}
        }
        let worker=Caller(role:"worker",installation:"scoped-worker",projectIDs:[pid],workspace:root.path)
        let summary=try call("task_context",["project_id":pid,"task_id":tid],worker),refs=summary["batches"] as! [JSON]
        XCTAssertEqual((summary["epic"] as? JSON)?["id"] as? String,"scoped-epic")
        XCTAssertEqual((summary["triages"] as? [JSON])?.first?["id"] as? String,"scoped-triage")
        XCTAssertEqual(summary["batch_count"] as? Int,11);XCTAssertEqual(refs.count,10)
        XCTAssertEqual(refs.last?["id"] as? String,"batch-10");XCTAssertEqual(refs.first?["id"] as? String,"batch-1")
        XCTAssertTrue(refs.allSatisfy{$0["outcomes_loaded"] as? Bool==false && $0["members_complete"] as? Bool==false})
        XCTAssertTrue(refs.allSatisfy{$0["triage_key"] is NSNull},"Legacy batches without a Triage ID have no display key.")
        let full=try call("task_context",["project_id":pid,"task_id":tid,"detail_level":"full"],worker)
        let ids=(full["records"] as! [JSON]).filter{$0["record_type"] as? String=="batch"}.compactMap{$0["id"] as? String}
        XCTAssertEqual(ids.count,11);XCTAssertEqual(Set(ids).count,11);XCTAssertTrue(ids.contains("batch-0"));XCTAssertTrue(ids.contains("batch-10"))
        XCTAssertFalse(try jsonString(summary).contains("corrupt-unrelated-attempt"))
    }
    func testOptionalTriageKeysAndSubjectsTolerateMissingOrCorruptReferences()throws {
        try write {db in
            try router.save(db,["id":"legacy-triage","project_id":pid,"kind":"triage","key":"SC-T7","name":"Legacy","revision":1],type:"group")
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES (?,?,?,?,?)",arguments:["corrupt-triage",pid,"group",1,try jsonString(["id":"different-group","project_id":pid,"revision":1])])
            XCTAssertEqual(router.batchTriageKey(db,["triage_key":"STORED-T2"]),"STORED-T2")
            XCTAssertEqual(router.batchTriageKey(db,["project_id":pid,"triage_id":"legacy-triage"]),"SC-T7")
            for batch:JSON in [[:],["triage_id":"legacy-triage"],["project_id":pid,"triage_id":NSNull()],["project_id":pid,"triage_id":"missing"],["project_id":pid,"triage_id":"corrupt-triage"],["project_id":"other-project","triage_id":"legacy-triage"]] {
                XCTAssertNil(router.batchTriageKey(db,batch))
            }
            let empty=try router.batchProjection(db,["id":"partial-batch","project_id":pid,"members":[]])
            XCTAssertTrue(empty["triage_key"] is NSNull)
            for (field,kind,id) in [("task_id","ticket","missing-ticket"),("triage_id","triage","missing-triage"),("epic_id","epic","missing-epic"),("triage_id","triage","corrupt-triage")] {
                let subject=try router.subject(db,message:["project_id":pid,field:id])
                XCTAssertEqual(subject["kind"] as? String,kind);XCTAssertEqual(subject["id"] as? String,id)
                XCTAssertTrue(subject["key"] is NSNull);XCTAssertEqual(subject["title"] as? String,"")
                XCTAssertEqual(subject["project_id"] as? String,pid)
            }
        }
    }
    func testBlockingRequestBeyondCompactPreviewStillControlsWorkerNextAction()throws {
        try write {db in
            for i in 0..<28 {try router.save(db,["id":"pending-\(i)","project_id":pid,"task_id":tid,"state":"pending","blocking":i==27,"revision":1],type:"request")}
        }
        let worker=Caller(role:"worker",installation:"scoped-worker",projectIDs:[pid],workspace:root.path)
        let summary=try call("task_context",["project_id":pid,"task_id":tid],worker)
        XCTAssertEqual(summary["next_action"] as? String,"await_human_answer")
        XCTAssertEqual((summary["counts"] as! JSON)["pending_requests"] as? Int,28)
        XCTAssertEqual((summary["pending_requests"] as! [JSON]).count,25)
        XCTAssertTrue(summary["truncated"] as? Bool ?? false)
    }
    func testHistoricalWorkerRosterDoesNotBlockCurrentAuthorityButCurrentOverflowDoes()throws {
        try write {db in
            for i in 0..<221 {
                let sid="ended-session-\(i)"
                try router.save(db,["id":sid,"project_id":pid,"project_ids":[pid],"role":"worker","provider":"codex","state":"ended","authorization_generation":"old","revision":1],type:"session")
                try router.save(db,["id":"old-link-\(i)","project_id":pid,"task_id":tid,"session_id":sid,"session_authorization_generation":"old","state":"linked","revision":1],type:"task_session")
                try router.save(db,["id":"old-alias-\(i)","project_id":pid,"task_id":tid,"state":"retired","revision":1],type:"task_alias")
            }
            try router.save(db,["id":"current-worker","project_id":pid,"project_ids":[pid],"role":"worker","provider":"codex","state":"active","authorization_generation":"current","execution_domain":"actual-fixture","revision":1],type:"session")
            try router.save(db,["id":"current-link","project_id":pid,"task_id":tid,"session_id":"current-worker","session_authorization_generation":"current","execution_domain":"actual-fixture","state":"linked","revision":1],type:"task_session")
        }
        let display=try call("task_context",["task_id":tid,"detail_level":"ui"])
        let current=try call("task_context",["task_id":tid,"detail_level":"ui_records","selected_context_cursor":display["context_cursor"]!])
        let collections=current["collections"] as! JSON
        XCTAssertEqual(current["complete"] as? Bool,true)
        XCTAssertEqual((collections["sessions"] as! [JSON]).compactMap{$0["id"] as? String},["current-worker"])
        XCTAssertEqual((collections["task_sessions"] as! [JSON]).compactMap{$0["id"] as? String},["current-link"])
        XCTAssertEqual((collections["task_aliases"] as! [JSON]).count,0)
        XCTAssertEqual((current["history_counts"] as! JSON)["task_sessions"] as? Int,222)
        let roster=try call("workspace_page",["project_id":pid,"surface":"worker_sessions","include_archived":true])
        XCTAssertEqual(roster["total"] as? Int,221);XCTAssertEqual((roster["rows"] as! [JSON]).count,50);XCTAssertNotNil(roster["next_cursor"] as? String)
        try write {db in for i in 0..<201 {try router.save(db,["id":"current-finding-\(i)","project_id":pid,"task_id":tid,"state":"open","revision":1],type:"finding")}}
        let fresh=try call("task_context",["task_id":tid,"detail_level":"ui"])
        let excessive=try call("task_context",["task_id":tid,"detail_level":"ui_records","selected_context_cursor":fresh["context_cursor"]!])
        XCTAssertEqual(excessive["complete"] as? Bool,false,"A genuinely excessive current gate set remains fail-closed")
        XCTAssertEqual((excessive["counts"] as! JSON)["findings"] as? Int,201)
    }
    func testAppliedReviewPolicyLoadsOnlyItsExactRetainedRevision()throws {
        try write {db in
            var task=try router.scoped(db,tid,pid,type:"task")
            let project=try router.record(db,pid,type:"project"),revision=(project["policy_revision"] as? Int) ?? 1
            let snapshot=try router.currentReviewRequirementSnapshot(project:project,task:task)
            if try router.records(db,type:"policy_revision",project:pid).isEmpty {try router.save(db,["id":"selected-policy","project_id":pid,"policy_revision":revision,"policy":project["policy"]!,"revision":1],type:"policy_revision")}
            try router.save(db,["id":"applied-review","project_id":pid,"task_id":tid,"phase":"review","state":"active","manifest_id":"selected-manifest","review_requirement_snapshot":snapshot,"revision":1],type:"attempt")
            task["active_attempt_id"]="applied-review";task["current_manifest_id"]="selected-manifest";task["revision"]=2;try router.save(db,task,type:"task")
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES (?,?,?,?,?)",arguments:["unrelated-malformed-policy",pid,"policy_revision",1,try jsonString(["id":"different-policy","project_id":pid,"policy_revision":revision+1,"revision":1])])
        }
        let summary=try call("task_context",["project_id":pid,"task_id":tid])
        XCTAssertEqual((summary["review_requirements"] as? JSON)?["state"] as? String,"applied")
    }
    func testCommittedCoverageStatusIsBoundedScopedAndMatchesNeedPredicates() throws {
        try write {db in
            let statuses = try router.records(db,type:"status",project:pid)
            let review = statuses.first {$0["category"] as? String == "review"}!
            var task = try router.scoped(db,tid,pid,type:"task")
            task["status_id"] = review["id"];task["revision"] = 2
            task["current_manifest_id"] = "coverage-manifest"
            task.removeValue(forKey:"active_attempt_id")
            try router.save(db,task,type:"task")
            try router.save(db,["id":"coverage-review","project_id":pid,"task_id":tid,
                "manifest_id":"coverage-manifest","state":"queued","gate":"review","revision":1],type:"review_request")
        }
        let coverage = try router.dbQueue.read {db -> JSON in
            let end = try Int.fetchOne(db,sql:"SELECT MAX(seq) FROM events") ?? 0
            // Existing fixture events establish a non-reset cursor before a new event.
            return try router.ticketChangeCoverage(db,after:max(1,end-1),through:end)
        }
        XCTAssertNotNil(coverage["status_updates"])
        try router.dbQueue.write {db in
            let before = try Int.fetchOne(db,sql:"SELECT MAX(seq) FROM events") ?? 0
            try router.event(db,caller:owner,project:pid,entity:tid,kind:"task_status_changed")
            let after = try Int.fetchOne(db,sql:"SELECT MAX(seq) FROM events") ?? 0
            let result = try router.ticketChangeCoverage(db,after:before,through:after)
            XCTAssertEqual(result["store_incarnation"] as? String,router.incarnation)
            let updates = result["status_updates"] as! [JSON]
            XCTAssertEqual(updates.count,1)
            let value = updates[0]["task"] as! JSON
            XCTAssertEqual(value["id"] as? String,tid)
            XCTAssertEqual(value["project_id"] as? String,pid)
            XCTAssertEqual(value["revision"] as? Int,2)
            XCTAssertEqual(value["status_category"] as? String,"review")
            XCTAssertNil(value["brief"]);XCTAssertNil(value["title"])
            let expected = try CommandRouter.needSurfaces.filter {surface in
                let page = try router.workspacePage(db,["project_id":pid,"surface":surface],owner)
                return (page["rows"] as! [JSON]).contains {$0["id"] as? String == tid}
            }
            XCTAssertEqual(Set(updates[0]["surfaces"] as! [String]),Set(expected))
            XCTAssertTrue(expected.contains("needs_review"))
            let reset = try router.ticketChangeCoverage(db,after:0,through:after)
            XCTAssertNil(reset["status_updates"])
        }
    }

    func testStatusCoverageRemainsOwnerOnly() throws {
        let worker = Caller(role:"worker",installation:"coverage-worker",projectIDs:[pid],workspace:root.path)
        XCTAssertThrowsError(try call("changes_wait",["project_id":pid,"include_coverage":true],worker)) {error in
            XCTAssertEqual((error as? CoreError)?.code,"HUMAN_CHANNEL_REQUIRED")
        }
        XCTAssertFalse(try router.ownerChangeCoverageRequested([:],worker))
    }

    func testCoverageOmitsStatusFastPathBeyondOneHundredTasks() throws {
        try write {db in
            let before = try Int.fetchOne(db,sql:"SELECT MAX(seq) FROM events") ?? 0
            let template = try router.scoped(db,tid,pid,type:"task")
            for index in 0..<101 {
                var task = template;let id = "coverage-bound-\(index)";task["id"] = id
                try router.save(db,task,type:"task")
                try router.event(db,caller:owner,project:pid,entity:id,kind:"task_updated")
            }
            let after = try Int.fetchOne(db,sql:"SELECT MAX(seq) FROM events") ?? 0
            let result = try router.ticketChangeCoverage(db,after:before,through:after)
            XCTAssertEqual(result["reset"] as? Bool,false)
            XCTAssertNil(result["status_updates"],"Large catch-up retains ordinary bounded page recovery")
            XCTAssertEqual(((result["changes"] as! [JSON])[0]["task_ids"] as! [String]).count,101)
        }
    }
    func testAffectedCoverageKeepsCheckpointLocalAndExpandsPrerequisiteDependents()throws {
        let dependent=try call("task_create",["project_id":pid,"title":"Dependent"])["id"] as! String
        try write {db in
            try router.save(db,["id":"dependency-edge","project_id":pid,"source_task_id":dependent,"target_task_id":tid,"relation":"depends_on","state":"active","required":true,"revision":1],type:"relation")
        }
        try router.dbQueue.write {db in
            let before=try Int.fetchOne(db,sql:"SELECT MAX(seq) FROM events") ?? 0
            try router.event(db,caller:owner,project:pid,entity:tid,kind:"work_checkpoint")
            let after=try Int.fetchOne(db,sql:"SELECT MAX(seq) FROM events") ?? 0
            let local=try router.ticketChangeCoverage(db,after:before,through:after)
            let change=(local["changes"] as! [JSON]).first!
            XCTAssertEqual(change["families"] as? [String],["work"])
            XCTAssertEqual(change["task_ids"] as? [String],[tid])
            try router.event(db,caller:owner,project:pid,entity:tid,kind:"task_completed")
            let latest=try Int.fetchOne(db,sql:"SELECT MAX(seq) FROM events") ?? 0
            let changed=try router.ticketChangeCoverage(db,after:after,through:latest)
            XCTAssertEqual(Set((changed["changes"] as! [JSON]).first!["task_ids"] as! [String]),Set([tid,dependent]))
            try router.event(db,caller:owner,project:pid,entity:nil,kind:"future_unknown_kind")
            let future=try router.ticketChangeCoverage(db,after:latest,through:latest+1)
            XCTAssertEqual((future["changes"] as! [JSON]).first?["all_tasks"] as? Bool,true)
            XCTAssertEqual((future["changes"] as! [JSON]).first?["families"] as? [String],["all"])
        }
    }
}
