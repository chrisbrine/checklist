import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

/// Selected-context scope and bounded history controls.
final class SelectedTicketReadTests: XCTestCase {
    private var root: URL!
    private var router: CommandRouter!
    private var pid = ""
    private let tid = "é"
    private let owner = Caller(role:"owner",installation:"selected-ticket-tests",projectIDs:[])
    override func setUpWithError() throws {
        let parent=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first!.appendingPathComponent("ChecklistSyntheticTests")
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        root=parent.appendingPathComponent("CL20-selected-"+UUID().uuidString)
        router = try TestStore.router(root:root)
        pid = try call("project_create",["name":"Synthetic Selected","key_prefix":"S","root_path":root.path])["id"] as! String
        try write {db in
            try router.save(db,["id":"queued","project_id":pid,"name":"Queued","category":"queued","revision":1],type:"status")
            for id in [tid,"e\u{301}"] {
                try router.save(db,fixtureDomainValue(router,db:db,value:["id":id,"project_id":pid,"key":id,"title":"Synthetic "+id,"brief":"","status_id":"queued","readiness":"ready","revision":1,"tag_ids":[String](),"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"],type:"task"),type:"task")
            }
        }
    }
    override func tearDownWithError() throws {router = nil;try? FileManager.default.removeItem(at:root)}
    private func call(_ method: String,_ values: JSON,_ caller: Caller? = nil) throws -> JSON {
        var p = values
        if !CommandRouter.readMethods.contains(method) {p["command_id"] = UUID().uuidString}
        return try router.handle(method:method,params:p,caller:caller ?? owner)["data"] as! JSON
    }
    private func write(_ body:(Database)throws->Void)throws {
        try router.dbQueue.writeWithoutTransaction {db in
            try router.withValidatedDomainTransaction(db) {try body(db);return .commit}
        }
    }
    private func selected(_ cursor: String? = nil) throws -> JSON {
        var p: JSON = ["task_id":tid,"detail_level":"ui"]
        if let cursor {p["history_cursor"] = cursor}
        return try call("task_context",p)
    }
    func testSelectedMessagesBoundedScopedAndContinuedWithoutCorpus() throws {
        let foreign = try call("project_create",["name":"Other","key_prefix":"O"])["id"] as! String
        try write {db in
            for i in 0..<101 {try router.save(db,["id":"m-\(i)","project_id":pid,"task_id":tid,"body":"selected \(i)","revision":1,"created_at":"2026-01-01T00:00:00Z"],type:"message")}
            try router.save(db,["id":"alias-note","project_id":pid,"task_id":"e\u{301}","body":"NOT-SELECTED","revision":1],type:"message")
            try router.save(db,["id":"foreign-note","project_id":foreign,"task_id":tid,"body":"PRIVATE","revision":1],type:"message")
            try router.save(db,["id":"foreign-delivery","project_id":foreign,"message_id":"m-100","recipient_session_id":"PRIVATE","revision":1],type:"delivery")
        }
        let first = try selected();let rows = (first["collections"] as! JSON)["messages"] as! [JSON]
        XCTAssertEqual(rows.count,50);XCTAssertEqual((first["counts"] as! JSON)["messages"] as? Int,101)
        XCTAssertFalse(try jsonString(first).contains("PRIVATE"));XCTAssertFalse(try jsonString(first).contains("NOT-SELECTED"))
        _ = try call("task_edit",["project_id":pid,"task_id":"e\u{301}","expected_revision":1,"patch":["title":"Unrelated task changed between pages","brief":"Unrelated synthetic task outcome"]])
        let second = try selected(first["next_history_cursor"] as? String)
        let third = try selected(second["next_history_cursor"] as? String)
        let all = [first,second,third].flatMap {($0["collections"] as! JSON)["messages"] as! [JSON]}.compactMap {$0["id"] as? String}
        XCTAssertEqual(all.count,101);XCTAssertEqual(Set(all).count,101)
        XCTAssertFalse(third["has_more_messages"] as? Bool ?? true)
        XCTAssertThrowsError(try call("task_context",["task_id":"e\u{301}","detail_level":"ui","history_cursor":first["next_history_cursor"]!]))
        _ = try call("message_send",["project_id":pid,"task_id":tid,"body":"New selected message changes the offset frontier"])
        XCTAssertThrowsError(try selected(first["next_history_cursor"] as? String)) {error in
            XCTAssertEqual((error as? CoreError)?.code,"CURSOR_RESET")
        }
        let updated = try selected()
        XCTAssertEqual((updated["counts"] as? JSON)?["messages"] as? Int,102)
    }
    func testSelectedProjectionKeepsMemberAttentionAndExactDependencies() throws {
        try write {db in
            try router.save(db,["id":"active-triage","project_id":pid,"kind":"triage","name":"Synthetic","members":[["task_id":tid]],"orchestration":["state":"active"],"revision":1],type:"group")
            try router.save(db,["id":"dependency","project_id":pid,"source_task_id":tid,"target_task_id":"e\u{301}","relation":"depends_on","state":"active","required":true,"revision":1],type:"relation")
        }
        let result = try selected();let task = result["task"] as! JSON
        XCTAssertEqual(task["active_attention"] as? Bool,true)
        XCTAssertEqual(task["prerequisites_satisfied"] as? Bool,false)
        XCTAssertEqual((task["prerequisites"] as? [JSON])?.compactMap {$0["relation_id"] as? String},["dependency"])
        let groups = (result["collections"] as! JSON)["groups"] as! [JSON]
        XCTAssertEqual(Set(groups.compactMap {$0["id"] as? String}),["fixture-primary-epic:"+pid,"active-triage"])
        XCTAssertEqual(groups.first {$0["id"] as? String == "active-triage"}?["members_complete"] as? Bool,false)
    }
    func testOwnerContextModesRefuseWorkerBeforeReadEffects() throws {
        let worker = Caller(role:"worker",installation:"synthetic-selected-worker",projectIDs:[pid],workspace:root.path)
        let before = try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM cursors")}
        for level in ["ui","ui_records"] {
            XCTAssertThrowsError(try call("task_context",["project_id":pid,"task_id":tid,"detail_level":level],worker))
        }
        XCTAssertThrowsError(try call("task_context",["project_id":pid,"task_id":tid,"selected_context_cursor":"fabricated"],worker))
        let after = try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM cursors")}
        XCTAssertEqual(before,after)
        let tools = try router.handle(method:"tool_catalog",params:[:],caller:worker)["data"] as! JSON
        let context = (tools["tools"] as! [JSON]).first {$0["name"] as? String == "task_context"}!
        XCTAssertNil(((context["inputSchema"] as! JSON)["properties"] as! JSON)["selected_context_cursor"])
    }
    func testWorkExpansionBindsContextAndRefusesIncompleteAuthority() throws {
        let initial = try selected()
        XCTAssertThrowsError(try call("task_context",["task_id":tid,"detail_level":"ui_records"]))
        let valid = try call("task_context",["task_id":tid,"detail_level":"ui_records","selected_context_cursor":initial["context_cursor"]!])
        XCTAssertEqual(valid["complete"] as? Bool,true)
        try write {db in
            // Policy/context events need not bump the selected task revision.
            try router.event(db,caller:owner,project:pid,entity:pid,kind:"project_context_changed")
        }
        XCTAssertThrowsError(try call("task_context",["task_id":tid,"detail_level":"ui_records","selected_context_cursor":initial["context_cursor"]!]))
        try write {db in
            for i in 0..<201 {try router.save(db,["id":"attachment-\(i)","project_id":pid,"task_id":tid,"name":"synthetic","revision":1],type:"attachment")}
        }
        let fresh = try selected()
        let incomplete = try call("task_context",["task_id":tid,"detail_level":"ui_records","selected_context_cursor":fresh["context_cursor"]!])
        XCTAssertEqual(incomplete["complete"] as? Bool,true,"Historical rows are read separately from current gate authority")
        XCTAssertEqual(((incomplete["collections"] as! JSON)["attachments"] as! [JSON]).count,0)
        XCTAssertEqual((incomplete["history_counts"] as! JSON)["attachments"] as? Int,201)
    }
    func testUnrelatedMutationResetsCurrentAndHistoryForArchivedAndUnarchivedTickets() throws {
        for archived in [false,true] {
            try write {db in
                var task = try router.record(db,tid,type:"task");task["archived"] = archived;try router.save(db,task,type:"task")
                if !archived {for i in 0..<51 {try router.save(db,["id":"history-\(i)","project_id":pid,"task_id":tid,"revision":1,"evidence":[:]],type:"manifest")}}
            }
            let initial = try selected(),context = initial["context_cursor"]!
            XCTAssertEqual((initial["task"] as? JSON)?["archived"] as? Bool,archived)
            let history = try call("task_context",["task_id":tid,"detail_level":"ui_history","records_family":"manifest","selected_context_cursor":context])
            let revision = try call("task_get",["project_id":pid,"task_id":"e\u{301}"])["revision"]!
            _ = try call("task_edit",["project_id":pid,"task_id":"e\u{301}","expected_revision":revision,"patch":["title":"Unrelated change","brief":"Synthetic outcome"]])
            for level in ["ui_records","ui_history"] {
                XCTAssertThrowsError(try call("task_context",["task_id":tid,"detail_level":level,"records_family":"manifest","selected_context_cursor":context])) {
                    XCTAssertEqual(($0 as? CoreError)?.code,"CURSOR_RESET")
                }
            }
            let fresh = try selected()
            XCTAssertEqual((fresh["task"] as? JSON)?["revision"] as? Int,(initial["task"] as? JSON)?["revision"] as? Int)
            XCTAssertNotEqual(fresh["context_cursor"] as? String,context as? String)
            XCTAssertEqual(try call("task_context",["task_id":tid,"detail_level":"ui_records","selected_context_cursor":fresh["context_cursor"]!])["complete"] as? Bool,true)
            XCTAssertThrowsError(try call("task_context",["task_id":tid,"detail_level":"ui_history","records_family":"manifest","selected_context_cursor":fresh["context_cursor"]!,"cursor":history["next_cursor"]!])) {
                XCTAssertEqual(($0 as? CoreError)?.code,"CURSOR_RESET")
            }
            let restarted = try call("task_context",["task_id":tid,"detail_level":"ui_history","records_family":"manifest","selected_context_cursor":fresh["context_cursor"]!])
            XCTAssertEqual((restarted["rows"] as? [JSON])?.count,50);XCTAssertTrue(restarted["previous_cursor"] is NSNull)
        }
    }
    func testReviewTargetHistoryIncludesPreviousImagesWithIdenticalHashesAndMeasuresWithoutActionAuthority() throws {
        let hash = String(repeating:"a",count:64)
        try write { db in
            for round in 1...2 {
                var refs: [JSON] = []
                for view in ["front","rear","corner"] {
                    let id = "\(view)-\(round)"
                    try router.save(db,["id":id,"project_id":pid,"task_id":tid,"name":"\(view)-round\(round).png","sha256":hash,"mode":"managed","availability":"available","size":100,"revision":1],type:"attachment")
                    refs.append(["artifact_id":id,"sha256":hash,"view_name":view])
                }
                // Same timestamp: insertion order, not timestamp or content hash, orders rounds.
                try router.save(db,["id":"round-\(round)","project_id":pid,"task_id":tid,"created_at":"2026-01-01T00:00:00Z","evidence":["artifact_refs":refs,"measures":[["name":"Triangles","unit":"triangles","before":32000,"after":round == 1 ? 26000 : 24000,"limit":25000]]],"revision":1],type:"manifest")
            }
            var task = try router.record(db,tid,type:"task"); task["current_manifest_id"] = "round-2"; try router.save(db,task,type:"task")
            try router.save(db,["id":"other-target","project_id":pid,"task_id":"e\u{301}","evidence":[:],"revision":1],type:"manifest")
        }
        let initial = try selected()
        let data = try call("task_context",["task_id":tid,"detail_level":"ui_records","selected_context_cursor":initial["context_cursor"]!])
        let collections = try XCTUnwrap(data["collections"] as? JSON)
        XCTAssertEqual((collections["manifests"] as? [JSON])?.count,1,"Current action records stay separate")
        let history = try XCTUnwrap(collections["review_target_history"] as? JSON)
        let targets = try XCTUnwrap(history["manifests"] as? [JSON])
        XCTAssertEqual(targets.compactMap {$0["id"] as? String},["round-1","round-2"])
        XCTAssertEqual(targets.last?["previous_manifest_id"] as? String,"round-1")
        let files = try XCTUnwrap(history["attachments"] as? [JSON])
        XCTAssertEqual(Set(files.compactMap {$0["id"] as? String}).count,6)
        XCTAssertEqual(Set(files.compactMap {$0["sha256"] as? String}),[hash])
        let measures = (targets.first?["evidence"] as? JSON)?["measures"] as? [JSON]
        XCTAssertEqual(measures?.first?["after"] as? Int,26000)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(data))
    }

}
