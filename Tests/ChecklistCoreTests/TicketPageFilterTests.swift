import XCTest
import GRDB
@testable import ChecklistCore

final class TicketPageFilterTests: XCTestCase {
    private var root: URL!
    private var router: CommandRouter!
    private var project = ""
    private let owner = Caller(role:"owner",installation:"ticket-filter-tests",projectIDs:[])
    override func setUpWithError() throws {
        // macOS /var and /tmp paths traverse a symlink that storage admission rejects; use the test cache root.
        root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ChecklistQualification/CL-16/filter-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        router = try CommandRouter(root:root)
        project = try call("project_create",["name":"Synthetic filters", "key_prefix":"FILTER", "root_path":root.path])["id"] as! String
        try save(["id":"queued", "project_id":project, "name":"Queued", "category":"queued", "revision":1], type:"status")
        for id in ["art", "bug"] { try save(["id":id,"project_id":project,"name":id,"revision":1],type:"tag") }
        try save(["id":"epic","project_id":project,"kind":"epic","name":"Engine","revision":1],type:"group")
        try task("one", tags:["art","bug"], assignee:["kind":"agent","session_id":"planned-worker"], epic:"epic")
        try task("two", tags:["art"], assignee:"human")
        try task("three", tags:[])
        try save(["id":"triage", "project_id":project,"kind":"triage","phase":"implementation","name":"Pair", "task_ids":["one","two"],"revision":1],type:"group")
    }
    override func tearDownWithError() throws { router = nil; try? FileManager.default.removeItem(at:root) }
    private func call(_ method:String, _ params:JSON) throws -> JSON {
        var params = params; if !CommandRouter.readMethods.contains(method) { params["command_id"] = UUID().uuidString }
        return try router.handle(method:method,params:params,caller:owner)["data"] as! JSON
    }
    private func save(_ value:JSON,type:String) throws { try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) { try router.save(db,fixtureDomainValue(router,db:db,value:value,type:type),type:type); return .commit } } }
    private func task(_ id:String,tags:[String],assignee:Any? = nil,epic:String? = nil, attempt:String? = nil) throws {
        var value:JSON = ["id":id,"project_id":project,"key":id,"title":"Find \(id)","brief":"Synthetic","status_id":"queued","readiness":"ready","tag_ids":tags,"revision":1,"order":1,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"]
        value["planned_assignee"] = assignee; value["epic_id"] = epic; value["active_attempt_id"] = attempt
        try save(value,type:"task")
        if epic == nil {try router.dbQueue.writeWithoutTransaction {db in try db.execute(sql:"UPDATE records SET data=json_remove(data,'$.epic_id') WHERE id=?",arguments:[id])}} // Owned pre-rule read fixture.
    }
    private func page(_ filters:JSON = [:],text:String = "") throws -> JSON {
        var view:JSON = ["surface":"tickets","status_filter":"all","tag_filter":"all","group_by":"none","order_by":"manual"]
        view.merge(filters) { _,new in new }
        return try call("task_list",["project_id":project,"text":text,"view":view,"limit":100])["tickets_page"] as! JSON
    }
    private func ids(_ filters:JSON = [:],text:String = "") throws -> Set<String> { Set((try page(filters,text:text)["tasks"] as! [JSON]).compactMap { $0["id"] as? String }) }
    func testTagAnyAllNoneCombineWithTextStatusAndScope() throws {
        XCTAssertEqual(try ids(["tag_ids":["art","bug"],"tag_mode":"any"]),["one","two"])
        XCTAssertEqual(try ids(["tag_ids":["art","bug"],"tag_mode":"all"]),["one"])
        XCTAssertEqual(try ids(["tag_ids":["art","bug"],"tag_mode":"none"]),["three"])
        XCTAssertEqual(try ids(["tag_ids":["art"],"tag_mode":"all","status_filter":"ready"],text:"Find two"),["two"])
        XCTAssertEqual(try ids(["tag_ids":[],"tag_mode":"none"]),["one","two","three"])
        let empty = try page(["tag_ids":["missing"],"tag_mode":"any"])
        XCTAssertEqual(empty["matched_count"] as? Int,0); XCTAssertEqual(empty["scoped_count"] as? Int,3)
        XCTAssertEqual(try ids(["status_filter":"blocked"]),[])
        let foreign = try call("project_create",["name":"Other scope", "key_prefix":"OTHER"])["id"] as! String
        let foreignStatus = try router.dbQueue.read { try router.records($0,type:"status",project:foreign).first! }
        try save(["id":"foreign-ticket","project_id":foreign,"title":"Find foreign","status_id":foreignStatus["id"]!,"tag_ids":[String](),"readiness":"ready","revision":1],type:"task")
        XCTAssertEqual(try ids(),["one","two","three"])
        XCTAssertEqual(try page()["scoped_count"] as? Int,3)
    }
    func testPlannedCurrentHandlerEpicAndTriageAreIndependent() throws {
        XCTAssertEqual(try ids(["planned_assignee":"planned-worker"]),["one"])
        XCTAssertEqual(try ids(["planned_assignee":"agent"]),["one"])
        XCTAssertEqual(try ids(["planned_assignee":"human"]),["two"])
        XCTAssertEqual(try ids(["planned_assignee":"unassigned"]),["three"])
        XCTAssertEqual(try ids(["epic_id":"epic"]),["one"])
        XCTAssertEqual(try ids(["epic_id":"none","triage_id":"triage"]),["two"])
        XCTAssertEqual(try ids(["triage_id":"none"]),["three"])
        try save(["id":"live-attempt","project_id":project,"task_id":"one","state":"active","session_id":"actual-worker","revision":1],type:"attempt")
        try task("one",tags:["art","bug"],assignee:["kind":"agent","session_id":"planned-worker"],epic:"epic",attempt:"live-attempt")
        XCTAssertEqual(try ids(["actual_assignee":"actual-worker"]),["one"])
        XCTAssertEqual(try ids(["actual_assignee":"planned-worker"]),[])
        XCTAssertEqual(try ids(["actual_assignee":"unassigned"]),["two","three"])
        XCTAssertEqual(try ids(["actual_assignee":"agent"]),["one"])
        try save(["id":"live-attempt","project_id":project,"task_id":"one","state":"finished","session_id":"actual-worker","revision":2],type:"attempt")
        XCTAssertEqual(try ids(["actual_assignee":"actual-worker"]),[])
        XCTAssertEqual(try ids(["actual_assignee":"unassigned"]),["one","two","three"])
    }
    func testFilterValidationAndCursorBinding() throws {
        for invalid:JSON in [["tag_mode":"some"],["tag_ids":["art","art"]],["tag_ids":"art"],["epic_id":5],["triage_id":""],["unexpected":true]] {
            XCTAssertThrowsError(try page(invalid)) { XCTAssertEqual(($0 as? CoreError)?.code,"INVALID_INPUT") }
        }
        let view:JSON = ["surface":"tickets","status_filter":"all","tag_filter":"all","group_by":"none","order_by":"manual","tag_ids":["art"],"tag_mode":"any"]
        let first = try call("task_list",["project_id":project,"view":view,"limit":1])["tickets_page"] as! JSON
        var changed = view; changed["tag_mode"] = "none"
        XCTAssertThrowsError(try call("task_list",["project_id":project,"view":changed,"limit":1,"cursor":first["next_cursor"]!])) { XCTAssertEqual(($0 as? CoreError)?.code,"CURSOR_RESET") }
        XCTAssertEqual((try page()["filter_triages"] as! [JSON]).first?["name"] as? String,"Pair")
    }
    func testAttemptFilterLookupUsesPrimaryKey() throws {
        let plans = try router.dbQueue.read { try Row.fetchAll($0,sql:"EXPLAIN QUERY PLAN SELECT t.id FROM records t WHERE t.project_id=? AND t.type='task' AND (SELECT json_extract(a.data,'$.session_id') FROM records a WHERE a.id=json_extract(t.data,'$.active_attempt_id') AND a.project_id=t.project_id AND a.type='attempt' AND json_extract(a.data,'$.state')='active')=?",arguments:[project,"worker"]) }
        let details = plans.compactMap { $0["detail"] as String? }.joined(separator:"\n")
        XCTAssertTrue(details.contains("records_scope"),details)
        XCTAssertFalse(details.contains("SCAN a"),details)
        XCTAssertTrue(details.contains("SEARCH a USING INDEX"),details)
        let canonicalPlans = try router.dbQueue.read { try Row.fetchAll($0,sql:"EXPLAIN QUERY PLAN WITH authorized AS (SELECT value id FROM json_each(?)), selected AS MATERIALIZED (SELECT t.id,t.project_id FROM records t JOIN authorized a ON t.project_id=a.id WHERE t.type='task' LIMIT 20) SELECT canonical.data FROM selected matching LEFT JOIN records canonical ON canonical.id=matching.id AND canonical.project_id=matching.project_id AND canonical.type='task'",arguments:[try jsonString([project])]) }
        let canonical = canonicalPlans.compactMap { $0["detail"] as String? }.joined(separator:"\n")
        XCTAssertTrue(canonical.contains("records_scope"),canonical)
        XCTAssertTrue(canonical.contains("SEARCH canonical USING INDEX"),canonical)
        XCTAssertFalse(canonical.contains("SCAN canonical"),canonical)
    }
}
