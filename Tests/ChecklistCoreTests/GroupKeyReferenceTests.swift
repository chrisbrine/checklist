import XCTest
import GRDB
@testable import ChecklistCore

extension CoreTests {
    private func groupReferenceFixtureWrite(_ body: (Database) throws -> Void) throws {
        try router.dbQueue.writeWithoutTransaction { db in
            try router.withValidatedDomainTransaction(db) {try body(db);return .commit}
        }
    }
    func testTriageTransitionBlockersConflictsAndSnapshotsNameTickets() throws {
        let p = try project("Blocked group","BG"),a = try task(p,"First title"),b = try task(p,"Second title"),g = try triage(p)
        try addTriage(p,g,a);try addTriage(p,g,b)
        let group = try currentTriage(p,g)
        var cursors:[String:String] = [:]
        for task in [a,b] {cursors[task["id"] as! String] = try call("task_context",["project_id":p["id"]!,"task_id":task["id"]!])["direction_cursor"] as? String}
        let input:JSON = ["project_id":p["id"]!,"triage_id":g["id"]!,"expected_revision":group["revision"]!,"expected_member_revisions":Dictionary(uniqueKeysWithValues:[a,b].map {($0["id"] as! String,$0["revision"]!)}),"action":"complete","expected_direction_cursors":cursors]
        XCTAssertThrowsError(try call("triage_transition",input)) { error in
            let error = error as! CoreError;XCTAssertEqual(error.code,"TRIAGE_TRANSITION_BLOCKED")
            for field in ["blockers","member_snapshot"] {let rows = error.details[field] as! [JSON];XCTAssertEqual(rows.count,2);XCTAssertTrue(rows.allSatisfy {$0["key"] is String && $0["title"] is String})}
            XCTAssertTrue(error.message.contains("BG-1 \"First title\""))
        }
        _ = try call("task_edit",["project_id":p["id"]!,"task_id":a["id"]!,"expected_revision":a["revision"]!,"patch":["title":"Renamed title"]])
        XCTAssertThrowsError(try call("triage_transition",input)) { error in
            let error = error as! CoreError;XCTAssertEqual(error.code,"REVISION_CONFLICT")
            let row = (error.details["blockers"] as! [JSON])[0];XCTAssertEqual(row["key"] as? String,"BG-1");XCTAssertEqual(row["title"] as? String,"Renamed title")
        }
    }
    func testAgentReferenceBoundsAndQuotesCustomKeysAndMentions() throws {
        let title = "Hello\n\"world\"\u{202E}@worker" + String(repeating:"🙂",count:1000)
        let text = AgentReference.text(key:"bad\nkey: @owner",title:title)
        XCTAssertFalse(text.contains("\n"));XCTAssertFalse(text.contains("\u{202E}"));XCTAssertFalse(text.contains("@"))
        XCTAssertTrue(text.contains("\\u0040"));XCTAssertLessThanOrEqual(AgentReference.sanitized(title).count,160)
        XCTAssertLessThanOrEqual(AgentReference.sanitized(title).utf8.count,640)
        XCTAssertEqual(try JSONSerialization.jsonObject(with:Data(AgentReference.quoted("\"@a\n").utf8),options:.fragmentsAllowed) as? String,"\"@a")
    }
    func testGroupKeysNumberKindsAndProjectsSeparatelyAndStayStable() throws {
        let p = try project("Groups","GK"), other = try project("Other","OT"), pid = p["id"]!
        let e = try call("epic_create",["project_id":pid,"name":"First epic"])
        let t = try task(p), g = try call("triage_create",["project_id":pid,"name":"First triage"])
        XCTAssertEqual(t["key"] as? String,"GK-1");XCTAssertEqual(g["key"] as? String,"GK-T1");XCTAssertEqual(e["key"] as? String,"GK-E1")
        XCTAssertEqual(try call("triage_create",["project_id":other["id"]!,"name":"Other"])["key"] as? String,"OT-T1")
        _ = try call("triage_edit",["project_id":pid,"triage_id":g["id"]!,"expected_revision":g["revision"]!,"name":"Renamed","archived":true])
        let currentProject = try call("project_list")["projects"] as! [JSON]
        _ = try call("project_edit",["project_id":pid,"expected_revision":currentProject.first {$0["id"] as? String == pid as? String}!["revision"]!,"key_prefix":"NEW"])
        let listed = try call("triage_list",["project_id":pid,"key":"gk-t1"])["groups"] as! [JSON]
        XCTAssertEqual(listed.count,1);XCTAssertEqual(listed[0]["name"] as? String,"Renamed");XCTAssertEqual(listed[0]["key"] as? String,"GK-T1")
        XCTAssertEqual(try call("triage_create",["project_id":pid,"name":"Next"])["key"] as? String,"NEW-T2")
        XCTAssertEqual(try call("epic_create",["project_id":pid,"name":"Next epic"])["key"] as? String,"NEW-E2")
        XCTAssertEqual(try task(p)["key"] as? String,"NEW-2")
        let missing = try call("epic_list",["project_id":pid,"key":"not-present"])["groups"] as! [JSON];XCTAssertTrue(missing.isEmpty)
        try groupReferenceFixtureWrite { db in var duplicate = e;duplicate["id"] = uuid();duplicate["key"] = "gk-e1";try router.save(db,duplicate,type:"group") }
        XCTAssertThrowsError(try call("epic_list",["project_id":pid,"key":"GK-E1"])) { XCTAssertEqual(($0 as? CoreError)?.code,"AMBIGUOUS_GROUP") }
    }
    func testGroupKeyBackfillCreationOrderIdempotenceHighWaterAndRestart() throws {
        let p = try project("Legacy","LG"),pid = p["id"] as! String
        try groupReferenceFixtureWrite { db in
            for (id,date,kind,key) in [("b","2000-01-01","triage",""),("a","2000-01-01","triage",""),("c","1999-01-01","triage",""),("e","2000-01-01","epic",""),("old","1998-01-01","triage","OLD-T9")] {
                var group: JSON = ["id":id,"project_id":pid,"name":id,"kind":kind,"revision":1,"created_at":date,"members":[],"archived":true]
                if !key.isEmpty {group["key"] = key};try router.save(db,group,type:"group")
            }
            try GroupKeys.backfill(db)
            for (id,key) in [("c","LG-T10"),("a","LG-T11"),("b","LG-T12"),("e","LG-E1"),("old","OLD-T9")] {XCTAssertEqual(try router.record(db,id,type:"group")["key"] as? String,key)}
            XCTAssertEqual(try router.record(db,pid,type:"project")["next_triage_number"] as? Int,13)
            let before = try SchemaMigrations.contentFingerprint(db);try GroupKeys.backfill(db);XCTAssertEqual(try SchemaMigrations.contentFingerprint(db),before)
        }
        try router.closeStore();router = try CommandRouter(root:directory)
        XCTAssertEqual(try call("triage_create",["project_id":pid,"name":"After restart"])["key"] as? String,"LG-T13")
    }
    func testGroupKeysInContextPagesBatchReceiptsHistoryAndEffects() throws {
        let p = try project("Projection","PJ"),a = try ready(p,task(p,"First")),b = try ready(p,task(p,"Second")),g = try call("triage_create",["project_id":p["id"]!,"name":"Pass"]),e = (try call("epic_list",["project_id":p["id"]!])["groups"] as! [JSON])[0]
        try addTriage(p,g,a);try addTriage(p,g,b)
        _ = try call("group_membership",["project_id":p["id"]!,"group_id":e["id"]!,"expected_revision":e["revision"]!,"task_id":a["id"]!,"action":"add"])
        let context = try call("task_context",["project_id":p["id"]!,"task_id":a["id"]!])
        XCTAssertEqual((context["epic"] as? JSON)?["key"] as? String,"PJ-E1")
        XCTAssertEqual((context["triages"] as? [JSON])?.first?["key"] as? String,"PJ-T1")
        let view:JSON = ["surface":"tickets","status_filter":"all","tag_filter":"all","group_by":"none","order_by":"manual"]
        let page = try call("task_list",["project_id":p["id"]!,"view":view])["tickets_page"] as! JSON
        XCTAssertEqual((page["triages"] as! [JSON]).first?["key"] as? String,"PJ-T1")
        XCTAssertEqual((page["epics"] as! [JSON]).first?["key"] as? String,"PJ-E1")
        let workspace = try call("workspace_page",["project_id":p["id"]!,"surface":"epics"])
        XCTAssertEqual((workspace["rows"] as! [JSON]).first?["key"] as? String,"PJ-E1")
        let selected = try call("task_context",["project_id":p["id"]!,"task_id":a["id"]!,"detail_level":"ui"])
        XCTAssertTrue((((selected["collections"] as! JSON)["groups"] as! [JSON])).allSatisfy {!($0["key"] as? String ?? "").isEmpty})
        let tools = try call("tool_catalog")["tools"] as! [JSON]
        for name in ["triage_list","epic_list"] { let tool = tools.first {$0["name"] as? String == name}!;XCTAssertNotNil(((tool["inputSchema"] as! JSON)["properties"] as! JSON)["key"]) }
        let current = try currentTriage(p,g)
        let batch = try call("batch_prepare",["project_id":p["id"]!,"triage_id":g["id"]!,"expected_revision":current["revision"]!,"phase":"implementation","tasks":[a,b].map { ["task_id":$0["id"]!,"expected_revision":(try! call("task_get",["project_id":p["id"]!,"task_id":$0["id"]!]))["revision"]!] }])
        XCTAssertEqual(batch["triage_key"] as? String,"PJ-T1");XCTAssertEqual((batch["members"] as? [JSON])?.first?["title"] as? String,"First")
        let claimed = try call("batch_claim",["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"policy_revision":batch["policy_revision"]!])
        XCTAssertEqual(claimed["triage_key"] as? String,"PJ-T1");XCTAssertEqual((claimed["claims"] as? [JSON])?.first?["key"] as? String,a["key"] as? String)
        let history = try call("history_list",["project_id":p["id"]!,"triage_id":g["id"]!])
        XCTAssertTrue((history["events"] as! [JSON]).allSatisfy {($0["subject"] as? JSON)?["key"] as? String == "PJ-T1"})
        let effects = try router.dbQueue.read {try router.currentTriageMemberships($0,project:p["id"] as! String)}
        XCTAssertEqual(effects.first?["triage_key"] as? String,"PJ-T1")
    }
    func testInboxSubjectsAndServiceContextAndHumanResponseNotesNameTicket() throws {
        let p = try call("project_create",["name":"Reference project","key_prefix":"RP","root_path":directory.path]),t = try task(p,"Hostile\n\"title\"\u{202E}"),pid = p["id"] as! String
        let sid = uuid();_ = try call("session_register",["project_id":pid,"session_id":sid,"provider":"codex","role":"worker","installation":"refs","workspace":directory.path])
        let worker = Caller(role:"worker",installation:"refs",projectIDs:[pid],sessionID:sid,workspace:directory.path)
        let note = try call("message_send",["project_id":pid,"task_id":t["id"]!,"body":"Ordinary","recipient":["kind":"session","session_id":sid]])
        let inbox = try call("session_inbox",["project_id":pid],worker),delivery = (inbox["deliveries"] as! [JSON])[0],subject = delivery["subject"] as! JSON
        XCTAssertEqual(subject["kind"] as? String,"ticket");XCTAssertEqual(subject["key"] as? String,t["key"] as? String);XCTAssertEqual(subject["title"] as? String,t["title"] as? String);XCTAssertEqual(subject["project_name"] as? String,"Reference project")
        XCTAssertEqual(try jsonString((delivery["message"] as! JSON)["subject"] as! JSON),try jsonString(subject));XCTAssertEqual((inbox["messages"] as! [JSON])[0]["id"] as? String,note["id"] as? String)
        let request = try call("human_request_create",["project_id":pid,"task_id":t["id"]!,"title":"Question","questions":[["id":"q","prompt":"Which?"]]])
        _ = try call("human_request_answer",["project_id":pid,"request_id":request["id"]!,"expected_revision":request["revision"]!,"answers":[["question_id":"q","text":"Answer"]]])
        try router.dbQueue.read {db in
            let response = try router.records(db,type:"message",project:pid).first {$0["human_request_id"] as? String == request["id"] as? String}!
            XCTAssertTrue((response["body"] as! String).contains("RP-1 \"Hostile\\\"title\\\"\""))
        }
        try groupReferenceFixtureWrite { db in
            let old = try router.record(db,pid,type:"project");var updated = old;updated["brief"] = "New direction";updated["brief_revision"] = int(old,"brief_revision") + 1
            try router.propagateProjectContextChange(db,old:old,updated:updated,caller:owner)
            let contextNote = try router.records(db,type:"message",project:pid).first {$0["kind"] as? String == "project_context_changed"}!
            XCTAssertTrue((contextNote["body"] as! String).contains(AgentReference.text(t,projectName:"Reference project")))
        }
        let g = try call("triage_create",["project_id":pid,"name":"Handling"])
        _ = try call("message_send",["project_id":pid,"task_id":t["id"]!,"triage_id":g["id"]!,"body":"Group note","recipient":["kind":"session","session_id":sid]])
        let groupInbox = try call("session_inbox",["project_id":pid],worker)
        XCTAssertTrue((groupInbox["messages"] as! [JSON]).contains {($0["subject"] as? JSON)?["key"] as? String == "RP-T1"})
    }
}
