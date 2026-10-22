import XCTest
import GRDB
@testable import ChecklistCore

/// Synthetic controls for the measured owner and worker page projections.
final class TicketPagePerformanceTests: XCTestCase {
    private var directory: URL!
    private var router: CommandRouter!
    private var pid = ""
    private let owner = Caller(role:"owner",installation:"page-performance-tests",projectIDs:[])
    private var worker: Caller { Caller(role:"worker",installation:"page-performance-worker",projectIDs:[pid],workspace:directory.path) }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CL20-page-perf-"+UUID().uuidString)
        router = try CommandRouter(root:directory)
        pid = try call("project_create",["name":"Synthetic Performance","key_prefix":"PERF","root_path":directory.path])["id"] as! String
        try save(["id":"q","project_id":pid,"name":"Queued","category":"queued","revision":1],"status")
        try save(["id":"a","project_id":pid,"name":"Active","category":"active","revision":1],"status")
    }
    override func tearDownWithError() throws { router = nil; try? FileManager.default.removeItem(at:directory) }
    private func call(_ method: String,_ input: JSON,_ caller: Caller? = nil) throws -> JSON {
        var p = input
        if !CommandRouter.readMethods.contains(method) { p["command_id"] = UUID().uuidString }
        return try router.handle(method:method,params:p,caller:caller ?? owner)["data"] as! JSON
    }
    private func save(_ row: JSON,_ type: String) throws {
        // Status/task/group fixtures use the same complete domain boundary as commands.
        try router.dbQueue.writeWithoutTransaction { db in
            try router.withValidatedDomainTransaction(db) {
                try router.save(db,row,type:type)
                return .commit
            }
        }
    }
    private func task(_ id: String, status: String = "q", activeAttempt: Bool = false) throws {
        var row: JSON = ["id":id,"project_id":pid,"title":id,"key":id,"brief":"Synthetic brief","status_id":status,"revision":1,"readiness":"ready","order":1,"archived":false,"trashed":false,"tag_ids":[String](),"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"]
        if activeAttempt { row["active_attempt_id"] = "synthetic-attempt" }
        try save(row,"task")
    }
    private func view(text: String = "", limit: Int = 1, cursor: Any? = nil) throws -> JSON {
        var p: JSON = ["project_id":pid,"limit":limit,"text":text,"view":["surface":"tickets","status_filter":"all","tag_filter":"all","group_by":"none","order_by":"manual"]]
        if let cursor { p["cursor"] = cursor }
        return try call("task_list",p)["tickets_page"] as! JSON
    }
    private func trace(_ body: () throws -> JSON) throws -> (JSON,[String]) {
        var statements: [String] = []
        // CL-72 moved task_list to the read-only pool. This sequential fixture
        // has one reader; tracing the writer observes none of the page queries.
        let readers = try XCTUnwrap(router.readers)
        try readers.read { db in
            db.trace(options:[.statement]) { if case .statement(let statement) = $0 { statements.append(statement.sql) } }
        }
        defer { try? readers.read {$0.trace(nil)} }
        return (try body(),statements)
    }

    func testOwnerWindowSharesSelectionAndKeepsEmptyAndHeaderTotals() throws {
        try task("one"); try task("two",status:"a")
        try save(["id":"triage","project_id":pid,"kind":"triage","phase":"implementation","name":"Window Group","purpose":"","task_ids":["one","two"],"revision":1,"archived":false],"group")
        let (first,sql) = try trace {try view()}
        XCTAssertEqual(sql.filter {$0.hasPrefix("WITH input AS")}.count,1,"Page/count/Triage hydration must not repeat the selection corpus")
        XCTAssertEqual((first["tasks"] as! [JSON]).count,0)
        XCTAssertEqual(first["matched_count"] as? Int,2); XCTAssertEqual(first["scoped_count"] as? Int,2)
        let triage = (first["triages"] as! [JSON]).first!
        XCTAssertEqual(triage["member_count"] as? Int,2); XCTAssertEqual(triage["matching_count"] as? Int,2)
        XCTAssertEqual(triage["status_state"] as? String,"mixed"); XCTAssertTrue(triage["status_id"] is NSNull)
        XCTAssertEqual(triage["page_member_ids"] as? [String],[]); XCTAssertEqual(triage["members_complete"] as? Bool,false)
        let next = try view(cursor:first["next_cursor"]!)
        XCTAssertEqual((next["tasks"] as! [JSON]).count,1)
        XCTAssertEqual((next["triages"] as! [JSON]).first?["matching_count"] as? Int,2)
        XCTAssertTrue(next["previous_cursor"] is String)
        let (empty,emptySQL) = try trace {try view(text:"NO-MATCH-SENTINEL")}
        XCTAssertEqual(emptySQL.filter {$0.hasPrefix("WITH input AS")}.count,1)
        XCTAssertEqual((empty["tasks"] as! [JSON]).count,0); XCTAssertEqual((empty["triages"] as! [JSON]).count,0)
        XCTAssertEqual(empty["matched_count"] as? Int,0); XCTAssertEqual(empty["scoped_count"] as? Int,2)
        XCTAssertEqual(empty["has_more"] as? Bool,false); XCTAssertTrue(empty["next_cursor"] is NSNull)

        // The LIMIT+1 group's bad member cannot poison a page that has not
        // selected that group yet. Selecting it must preserve the refusal.
        try save(["id":"overflow","project_id":pid,"kind":"triage","phase":"implementation","name":"ZZ Overflow","task_ids":["one","missing"],"revision":1,"archived":false],"group")
        let bounded = try view(limit:3)
        XCTAssertEqual((bounded["triages"] as! [JSON]).compactMap {$0["id"] as? String},["triage"])
        XCTAssertEqual(bounded["has_more"] as? Bool,true)
        let before = try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM cursors")}
        XCTAssertThrowsError(try view(limit:3,cursor:bounded["next_cursor"]!)) { error in
            XCTAssertEqual((error as? CoreError)?.code,"NOT_FOUND")
        }
        let after = try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM cursors")}
        XCTAssertEqual(before,after)

        // New CAST/join coverage: exact note task references, ordered joined
        // bodies, and an authorized-project fence before matching any note.
        try task("é"); try task("e\u{301}")
        for (id,taskID,body) in [("note-1","é","JoinPart é"),("note-2","é","Tail"),("note-3","e\u{301}","DifferentNote")] {
            try save(["id":id,"project_id":pid,"task_id":taskID,"body":body,"revision":1],"message")
        }
        let joined = try view(text:"E\u{301} Tail",limit:10)
        XCTAssertEqual((joined["tasks"] as! [JSON]).map {Data(($0["id"] as! String).utf8)},[Data("é".utf8)])
        XCTAssertEqual(joined["matched_count"] as? Int,1)
        let distinct = try view(text:"DifferentNote",limit:10)
        XCTAssertEqual((distinct["tasks"] as! [JSON]).map {Data(($0["id"] as! String).utf8)},[Data("e\u{301}".utf8)])
        XCTAssertEqual(distinct["matched_count"] as? Int,1)
        XCTAssertEqual(try view(text:"DifferentNote Tail")["matched_count"] as? Int,0)
        let foreign = try call("project_create",["name":"Foreign Notes","key_prefix":"FN"])["id"] as! String
        try save(["id":"foreign-note","project_id":foreign,"task_id":"é","body":"FOREIGN-NOTE-ONLY","revision":1],"message")
        let noLeak = try view(text:"FOREIGN-NOTE-ONLY")
        XCTAssertEqual(noLeak["matched_count"] as? Int,0); XCTAssertFalse(try jsonString(noLeak).contains("FOREIGN-NOTE-ONLY"))
    }

    func testWorkerBulkProjectionBoundsPointReadsAndKeepsByteDistinctTargets() throws {
        var ids: [String] = []
        for i in 0..<24 { let id = "row-"+String(format:"%02d",i); ids.append(id); try task(id,status:i==23 ? "a":"q") }
        try save(["id":"triage","project_id":pid,"kind":"triage","phase":"implementation","name":"Bulk Group","task_ids":ids,"revision":1,"archived":false],"group")
        try save(["id":"done","project_id":pid,"name":"Done","category":"done","revision":1],"status")
        try task("é",status:"done"); try task("e\u{301}")
        for (source,target,edge) in [(ids[0],"é","edge-done"),(ids[1],"e\u{301}","edge-blocked")] {
            try save(["id":edge,"project_id":pid,"source_task_id":source,"target_task_id":target,"relation":"depends_on","state":"active","required":true,"revision":1],"relation")
        }
        let (reply,sql) = try trace {try call("task_list",["project_id":pid,"limit":24],worker)}
        let tasks = reply["tasks"] as! [JSON]
        XCTAssertEqual(tasks.compactMap {$0["id"] as? String},ids)
        XCTAssertTrue(tasks.allSatisfy {$0["active_attention"] as? Bool == true})
        XCTAssertEqual(tasks[0]["prerequisites_satisfied"] as? Bool,true)
        XCTAssertEqual(tasks[1]["prerequisites_satisfied"] as? Bool,false)
        // Canonical reads include envelope witnesses and byte-exact CAST bindings.
        let pointReads = sql.filter {$0.contains(" FROM records WHERE id = CAST(? AS TEXT)")}
        XCTAssertLessThanOrEqual(pointReads.count,20,"Point reads must not grow with member-by-task projection")
        let groupRead = "SELECT " + CommandRouter.canonicalRecordColumns + " FROM records WHERE type = CAST(? AS TEXT) AND project_id = CAST(? AS TEXT) ORDER BY rowid"
        XCTAssertEqual(sql.filter {$0 == groupRead}.count,1,"Group corpus loads once per request")
        XCTAssertTrue(tasks.allSatisfy {$0["completion_eligibility"] == nil})
    }

    func testWorkerAttentionDefersMissingMembersUntilItsShortCircuitNeedsThem() throws {
        try task("first",activeAttempt:true); try task("second")
        var group: JSON = ["id":"broken","project_id":pid,"kind":"triage","phase":"implementation","name":"Missing Member","task_ids":["missing","first","second"],"revision":1,"archived":false]
        try save(group,"group")
        let first = try call("task_list",["project_id":pid,"limit":1],worker)
        XCTAssertEqual((first["tasks"] as! [JSON]).first?["active_attention"] as? Bool,true)
        let before = try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM cursors")}
        XCTAssertThrowsError(try call("task_list",["project_id":pid,"limit":1,"cursor":first["next_cursor"]!],worker)) { error in
            XCTAssertEqual((error as? CoreError)?.code,"NOT_FOUND")
        }
        let after = try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM cursors")}
        XCTAssertEqual(before,after,"Failure cannot publish continuation state")
        group["orchestration"] = ["state":"active"]; try save(group,"group")
        let allowed = try call("task_list",["project_id":pid,"limit":1,"cursor":first["next_cursor"]!],worker)
        XCTAssertEqual((allowed["tasks"] as! [JSON]).first?["active_attention"] as? Bool,true)
    }

    func testSplitEventGenerationIgnoresForeignEventsAndRejectsGlobalChanges() throws {
        try task("one"); try task("two")
        let foreign = try call("project_create",["name":"Foreign","key_prefix":"FOREIGN"])["id"] as! String
        let first = try call("task_list",["project_id":pid,"limit":1],worker)
        try router.dbQueue.write {try router.event($0,caller:owner,project:foreign,entity:nil,kind:"foreign_change")}
        let second = try call("task_list",["project_id":pid,"limit":1,"cursor":first["next_cursor"]!],worker)
        XCTAssertEqual((second["tasks"] as! [JSON]).first?["id"] as? String,"two")
        try router.dbQueue.write {try router.event($0,caller:owner,project:pid,entity:nil,kind:"authorized_change")}
        XCTAssertThrowsError(try call("task_list",["project_id":pid,"limit":1,"cursor":first["next_cursor"]!],worker)) { error in
            XCTAssertEqual((error as? CoreError)?.code,"CURSOR_RESET")
        }
        let fresh = try call("task_list",["project_id":pid,"limit":1],worker)
        try router.dbQueue.write {try router.event($0,caller:owner,project:nil,entity:nil,kind:"global_change")}
        XCTAssertThrowsError(try call("task_list",["project_id":pid,"limit":1,"cursor":fresh["next_cursor"]!],worker)) { error in
            XCTAssertEqual((error as? CoreError)?.code,"CURSOR_RESET")
        }
    }
}
