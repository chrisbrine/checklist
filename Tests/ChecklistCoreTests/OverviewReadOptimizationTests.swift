import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

final class OverviewReadOptimizationTests: XCTestCase {
    func testCombinedOverviewBatchesCleanupCountsAndCoverageWithoutChangingPages() throws {
        let fixture = try ReadPerformanceFixture("CL-296-overview-batch"), router = fixture.router
        let project = try fixture.call("project_create",["name":"Combined pages","key_prefix":"CP"])
        let pid = project["id"] as! String
        let task = try fixture.call("task_create",["project_id":pid,"title":"Done today","brief":"Keep both digest pages identical"])
        let tid = task["id"] as! String
        try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {
            var value = try router.record(db,tid,type:"task")
            value["status_id"] = try router.records(db,type:"status",project:pid).first {$0["category"] as? String == "done"}!["id"]
            value["completed_at"] = ISO8601DateFormatter().string(from:Date())
            try router.save(db,router.revised(value),type:"task")
            try router.save(db,["id":"cleaned-original","project_id":pid,"task_id":tid,"mode":"managed","availability":"original_cleaned","revision":1],type:"attachment")
            return .commit
        }}
        try router.dbQueue.read { db in
            var statements: [String] = []
            db.trace {if case .statement(let statement) = $0 {statements.append(statement.sql)}}
            let since = "2026-01-01T00:00:00Z"
            let combined = try router.workspacePage(db,["project_id":pid,"surface":"overview","since":since],fixture.owner)
            db.trace(options:[])
            XCTAssertEqual(statements.filter {$0.contains("COUNT(*) clean_count")}.count,1,"Batch cleanup facts for all selected groups in the pinned read")
            XCTAssertEqual(statements.filter {$0.contains("FROM events") && $0.contains("json_each")}.count,1,"All groups share the same scope and pinned coverage")
            let groups = try XCTUnwrap(combined["groups"] as? JSON)
            for (surface,limit) in CommandRouter.overviewGroupLimits {
                var single = try router.workspacePage(db,["project_id":pid,"surface":surface,"since":since,"limit":limit],fixture.owner)
                for field in ["projects","service","content_cursor","needs_you_count"] {single.removeValue(forKey:field)}
                XCTAssertEqual(try jsonString(try XCTUnwrap(groups[surface] as? JSON)),try jsonString(single),surface)
            }
            for surface in ["needs_done_today","completed_since"] {
                let rows = (groups[surface] as! JSON)["rows"] as! [JSON]
                XCTAssertEqual(rows.first?["cleaned_original_count"] as? Int,1)
            }
        }
    }

    func testWorkspaceCoverageChecksNewestEventBeforeScanningScopedHistory() throws {
        let fixture = try ReadPerformanceFixture("CL-296-coverage")
        let memory = try DatabaseQueue()
        try memory.write { db in
            try SchemaMigrations.installStorageCollation(db)
            try db.execute(sql:"CREATE TABLE events(seq INTEGER PRIMARY KEY,project_id TEXT COLLATE checklist_storage_v2,entity_id TEXT, data TEXT); CREATE INDEX events_scope ON events(project_id,entity_id,seq)")
            let projects = try jsonString(["selected", "selected\0suffix"])
            func check(_ expected: Int, scansHistory: Bool) throws {
                var statements: [String] = []
                db.trace {if case .statement(let statement) = $0 {statements.append(statement.sql)}}
                let actual = try fixture.router.workspaceCoverage(db,projectsJSON:projects)
                db.trace(options:[])
                XCTAssertEqual(actual,expected)
                XCTAssertEqual(statements.contains {$0.contains("MAX(latest)")},scansHistory,"Only an out-of-scope newest event needs the scoped history fallback")
                XCTAssertEqual(actual,try Int.fetchOne(db,sql:"SELECT COALESCE(MAX(seq),0) FROM events WHERE project_id IS NULL OR project_id IN (SELECT value FROM json_each(?))",arguments:[projects]))
            }
            try check(0,scansHistory:true)
            try db.execute(sql:"INSERT INTO events VALUES(1,'selected','ticket','{}')")
            try check(1,scansHistory:false)
            try db.execute(sql:"INSERT INTO events VALUES(2,'foreign','ticket','{}')")
            try check(1,scansHistory:true)
            try db.execute(sql:"INSERT INTO events VALUES(3,NULL,'global','{}')")
            try check(3,scansHistory:false)
            try db.execute(sql:"INSERT INTO events VALUES(4,CAST(? AS TEXT),'ticket','{}')",arguments:[Data("selected\0suffix".utf8)])
            try check(4,scansHistory:false)
            try db.execute(sql:"INSERT INTO events VALUES(5,'selected-suffix','foreign','{}')")
            try check(4,scansHistory:true)
        }
    }

    func testReadOnlyBatchClaimProjectionProfile() throws {
        try QualificationSuite.requireEnabled()
        guard let path = ProcessInfo.processInfo.environment["CHECKLIST_READ_ONLY_DATABASE"],
              let fixturePath = ProcessInfo.processInfo.environment["CHECKLIST_BATCH_PROFILE_FIXTURE"] else {
            throw XCTSkip("Requires an owned read-only backup and recorded native batch fixture")
        }
        let native = try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:fixturePath))) as? JSON)
        let tasks = try XCTUnwrap(native["tasks"] as? [JSON]).map {task -> JSON in
            var task = task
            task.removeValue(forKey:"active_attempt_id")
            task.removeValue(forKey:"active_verification_request_id")
            return task
        }
        let fixture = try ReadPerformanceFixture("CL-279-read-profile")
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in
            try SchemaMigrations.installStorageCollation(db)
            CommandRouter.installTicketSearchFunctions(db)
        }
        let pool = try DatabasePool(path:path,configuration:configuration)
        defer {try? pool.close()}
        let caller = Caller(role:"owner",installation:"CL-279-read-profile",projectIDs:[])
        var load = [Double](repeating:0,count:3)
        getloadavg(&load,3)
        print("CL-279 read-only approximation: recorded native preclaim task dictionaries, no transient attempts/created records, no snapshot cache (writer projection behavior), owner diagnostic caller, load=\(load)")
        let components = ProcessInfo.processInfo.environment["CHECKLIST_BATCH_PROFILE_COMPONENT"] == "category_direct_status" ? ["category_direct_status"] : ["prerequisite_guard","category_projection","category_direct_status","response_projection","compact_context"]
        for name in components {
            try pool.read { db in
                var profiles: [(String,TimeInterval)] = []
                db.trace(options:.profile) {event in
                    if case .profile(let statement,let duration) = event {profiles.append((statement.sql,duration))}
                }
                defer {db.trace(options:[])}
                let started = ProcessInfo.processInfo.systemUptime
                for task in tasks {
                    switch name {
                    case "prerequisite_guard":try fixture.router.requirePrerequisitesSatisfied(db,task:task)
                    case "category_projection":_ = try fixture.router.taskProjection(db,task)["status_category"] as? String ?? "queued"
                    case "category_direct_status":_ = try fixture.router.implementationClaimCategory(db,task:task)
                    case "response_projection":_ = try fixture.router.taskProjection(db,task)
                    default:_ = try fixture.router.compactTaskContext(db,task:task,caller:caller)
                    }
                }
                print("CL-279 component=\(name) members=\(tasks.count) wall_ms=\((ProcessInfo.processInfo.systemUptime-started)*1000) statements=\(profiles.count)")
                var totals: [String:(Int,TimeInterval)] = [:]
                for (sql,duration) in profiles {
                    let prior = totals[sql] ?? (0,0)
                    totals[sql] = (prior.0+1,prior.1+duration)
                }
                for (sql,total) in totals.sorted(by:{$0.value.1 > $1.value.1}).prefix(10) {
                    print("CL-279 SQL component=\(name) count=\(total.0) total_ms=\(total.1*1000) \(sql)")
                }
            }
        }
    }

    func testOwnerNeedsCountsKeepPredicatesAndUseNarrowFamilyEnumeration() throws {
        let fixture = try ReadPerformanceFixture("CL-281-owner-counts")
        let memory = try DatabaseQueue()
        try memory.write { db in
            try SchemaMigrations.installStorageCollation(db)
            try db.execute(sql:"CREATE TABLE records(id TEXT COLLATE checklist_storage_v2 PRIMARY KEY,project_id TEXT COLLATE checklist_storage_v2,type TEXT COLLATE checklist_storage_v2,data TEXT); CREATE INDEX records_scope ON records(project_id,type)")
            func insert(_ type:String,_ id:String,_ project:String,_ value:JSON) throws {
                try db.execute(sql:"INSERT INTO records VALUES(CAST(? AS TEXT),CAST(? AS TEXT),CAST(? AS TEXT),?)",arguments:[Data(id.utf8),Data(project.utf8),Data(type.utf8),try jsonString(value)])
            }
            for category in ["queued","active","done","completed","canceled",LegacyStoredValue.canceled] {
                try insert("status","status-"+category,"p",["category":category])
            }
            try insert("status","archived-queued","archived-project",["category":"queued"])
            for (index,state) in ["pending","unknown","answered","canceled",LegacyStoredValue.canceled,"superseded","resolved"].enumerated() {
                try insert("request","request-\(index)","p",["state":state])
            }
            try insert("request","missing-state","p",[:])
            try insert("request","snoozed","p",["state":"pending","owner_snoozed":true])
            try insert("request","archived-project-request","archived-project",["state":"pending"])
            var tasks: [JSON] = [
                ["status_id":"status-queued","planned_assignee":"human"],
                ["status_id":"status-active","planned_assignee":["kind":"human"]],
                ["status_id":"status-queued","assignee":"human"],
                ["status_id":"missing","planned_assignee":"human"],
                ["status_id":"status-queued","planned_assignee":"agent"],
                ["status_id":"status-queued","planned_assignee":"human","archived":true],
                ["status_id":"status-queued","planned_assignee":"human","trashed":true]
            ]
            for category in ["done","completed","canceled",LegacyStoredValue.canceled] {
                tasks.append(["status_id":"status-"+category,"planned_assignee":"human"])
            }
            for (index,task) in tasks.enumerated() {try insert("task","task-\(index)","p",task)}
            // A status from another project remains an unknown status here;
            // the owner digest does not silently drop that task or scope.
            try insert("task","foreign-status","other",["status_id":"status-done","planned_assignee":"human"])
            try insert("task","archived-project-task","archived-project",["status_id":"archived-queued","planned_assignee":"human"])
            try insert("request\0suffix","other-family-request","p",["state":"pending"])
            try insert("task\0suffix","other-family-task","p",["status_id":"status-queued","planned_assignee":"human"])
            var statements: [String] = []
            db.trace {if case .statement(let statement) = $0 {statements.append(statement.sql)}}
            let counts = try fixture.router.ownerNeedsYouCounts(db)
            db.trace(options:[])
            XCTAssertEqual(counts.requests,5)
            XCTAssertEqual(counts.tasks,6)
            let previousRequests = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE type='request' AND COALESCE(json_extract(data,'$.state'),'') NOT IN ('answered','canceled','\(LegacyStoredValue.canceled)','superseded','resolved')")
            let previousTasks = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records t LEFT JOIN records s ON s.id=json_extract(t.data,'$.status_id') AND s.project_id=t.project_id AND s.type='status' WHERE t.type='task' AND COALESCE(json_extract(t.data,'$.archived'),0)=0 AND COALESCE(json_extract(t.data,'$.trashed'),0)=0 AND COALESCE(json_extract(s.data,'$.category'),'') NOT IN ('done','completed','canceled','\(LegacyStoredValue.canceled)') AND (json_extract(t.data,'$.planned_assignee')='human' OR json_extract(t.data,'$.planned_assignee.kind')='human' OR json_extract(t.data,'$.assignee')='human')")
            XCTAssertEqual(counts.requests,previousRequests)
            XCTAssertEqual(counts.tasks,previousTasks)
            XCTAssertEqual(statements.count,2)
            for sql in statements {
                let plan = try Row.fetchAll(db,sql:"EXPLAIN QUERY PLAN "+sql).map {$0["detail"] as String}
                XCTAssertTrue(plan.contains {$0.contains("COVERING INDEX records_scope")},plan.joined(separator:"\n"))
                XCTAssertTrue(plan.contains {$0.contains("USING INTEGER PRIMARY KEY (rowid=?)")},plan.joined(separator:"\n"))
                XCTAssertFalse(plan.contains {$0.contains("SCAN t") || ($0.contains("SCAN records") && !$0.contains("COVERING INDEX"))},plan.joined(separator:"\n"))
            }
        }
    }

    func testPinnedWorkspaceAggregateAndProjectionSurviveConcurrentCommit() throws {
        let fixture = try ReadPerformanceFixture("CL-281-pinned"), router = fixture.router
        let project = try fixture.call("project_create",["name":"Pinned page","key_prefix":"PIN"])
        let pid = project["id"] as! String
        let task = try fixture.call("task_create",["project_id":pid,"title":"Pinned task","brief":"Pinned facts"])
        let tid = task["id"] as! String
        let oldStatus = try router.dbQueue.read {db in try router.records(db,type:"status",project:pid).first {$0["category"] as? String == "done"}!["id"] as! String}
        try fixture.save([("status",["id":"fresh-done","project_id":pid,"name":"Fresh done","category":"done","revision":1])])
        try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {
            var value = try router.record(db,tid,type:"task")
            value["status_id"] = oldStatus
            value["completed_at"] = ISO8601DateFormatter().string(from:Date())
            try router.save(db,router.revised(value),type:"task")
            return .commit
        }}
        // Every observation field is accessed under lock, and the worker joins before teardown.
        final class Observation: @unchecked Sendable {
            let lock = NSLock()
            var result: Result<JSON,Error>?
        }
        let observation = Observation(), counted = DispatchSemaphore(value:0), resume = DispatchSemaphore(value:0)
        let finished = expectation(description:"Pinned aggregate and projection finish")
        let readers = try XCTUnwrap(router.readers), owner = fixture.owner
        DispatchQueue.global().async {
            defer {finished.fulfill()}
            let result = Result {try readers.read {db in try router.readSnapshotCache.withSnapshot(db,caller:owner) {
                db.trace(options:.profile) {event in
                    if case .profile(let statement,_) = event, statement.sql.contains("COUNT(*) clean_count") {
                        counted.signal()
                        XCTAssertEqual(resume.wait(timeout:.now()+10),.success)
                    }
                }
                defer {db.trace(options:[])}
                return try router.workspacePage(db,["project_id":pid,"surface":"needs_done_today","limit":5],owner)
            }}}
            observation.lock.withLock {observation.result = result}
            counted.signal()
        }
        defer {resume.signal()}
        // These are deadlock guards, not latency acceptance budgets. The read
        // pauses at its aggregate query so the commit order is deterministic.
        XCTAssertEqual(counted.wait(timeout:.now()+10),.success)
        try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {
            try router.save(db,["id":"concurrent-cleaned","project_id":pid,"task_id":tid,"mode":"managed","availability":"original_cleaned","revision":1],type:"attachment")
            var value = try router.record(db,tid,type:"task")
            value["status_id"] = "fresh-done"
            try router.save(db,router.revised(value),type:"task")
            return .commit
        }}
        resume.signal()
        wait(for:[finished],timeout:10)
        let old = try XCTUnwrap(observation.lock.withLock {observation.result}).get()
        let oldTask = try XCTUnwrap((old["rows"] as? [JSON])?.first)
        XCTAssertEqual(oldTask["status_id"] as? String,oldStatus)
        XCTAssertEqual(oldTask["cleaned_original_count"] as? Int,0)
        let current = try fixture.call("workspace_page",["project_id":pid,"surface":"needs_done_today","limit":5])
        let currentTask = try XCTUnwrap((current["rows"] as? [JSON])?.first)
        XCTAssertEqual(currentTask["status_id"] as? String,"fresh-done")
        XCTAssertEqual(currentTask["cleaned_original_count"] as? Int,1)
    }

    func testGlobalProjectCatalogUsesNarrowIndexAndRetainsOpaqueOrder() throws {
        let fixture = try ReadPerformanceFixture("CL-281-catalog")
        // Opaque IDs include normalization-equivalent and embedded-NUL values.
        // Their storage identity and insertion order must survive enumeration.
        let ids = ["catalog-é", "catalog-e\u{301}", "catalog\0suffix"]
        try fixture.save(ids.enumerated().map {index,id in
            ("project",["id":id,"project_id":id,"name":"Catalog \(index)","key_prefix":"C\(index)","revision":1] as JSON)
        })
        try fixture.router.dbQueue.read { db in
            var statements: [String] = []
            db.trace {if case .statement(let statement) = $0 {statements.append(statement.sql)}}
            let projects = try fixture.router.records(db,type:"project")
            db.trace(options:[])
            XCTAssertEqual(projects.compactMap {$0["id"] as? String}.map {Data($0.utf8)},ids.map {Data($0.utf8)})
            let sql = try XCTUnwrap(statements.first)
            let plan = try Row.fetchAll(db,sql:"EXPLAIN QUERY PLAN "+sql,arguments:[Data("project".utf8)]).map {$0["detail"] as String}.joined(separator:"\n")
            XCTAssertTrue(plan.contains("COVERING INDEX records_scope"),plan)
            XCTAssertTrue(plan.contains("USING INTEGER PRIMARY KEY (rowid=?)"),plan)
            XCTAssertFalse(plan.contains("SCAN records\n") || plan.hasSuffix("SCAN records"),plan)
        }
    }

    /// Opt-in qualification only: the default suite never reads an installation
    /// or asserts a machine-dependent wall-clock budget.
    func testReadOnlyOverviewQueryProfile() throws {
        try QualificationSuite.requireEnabled()
        guard let path = ProcessInfo.processInfo.environment["CHECKLIST_READ_ONLY_DATABASE"] else {
            throw XCTSkip("Requires an explicitly selected read-only backup")
        }
        let fixture = try ReadPerformanceFixture("CL-281-profile")
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in
            try SchemaMigrations.installStorageCollation(db)
            CommandRouter.installTicketSearchFunctions(db)
        }
        let pool = try DatabasePool(path: path, configuration: configuration)
        defer { try? pool.close() }
        let owner = Caller(role: "owner", installation: "CL-281-profile", projectIDs: [])
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        print("CL-281 load=\(load)")
        let surfaces = ProcessInfo.processInfo.environment["CHECKLIST_OVERVIEW_PROFILE_SURFACE"] == "overview" ? ["overview"] : ["overview", "completed_since", "needs_pickup"]
        for surface in surfaces {
            try pool.read { db in
                var profiles: [(String, TimeInterval)] = []
                db.trace(options: .profile) { event in
                    if case .profile(let statement, let duration) = event {
                        profiles.append((statement.sql, duration))
                    }
                }
                defer { db.trace(options: []) }
                let started = ProcessInfo.processInfo.systemUptime
                _ = try fixture.router.readSnapshotCache.withSnapshot(db, caller: owner) {
                    try fixture.router.workspacePage(db, ["surface": surface, "since": "2026-10-22T00:00:00Z"], owner)
                }
                print("CL-281 surface=\(surface) wall_ms=\((ProcessInfo.processInfo.systemUptime-started)*1000) statements=\(profiles.count)")
                var totals: [String: (Int, TimeInterval)] = [:]
                for (sql, duration) in profiles {
                    let old = totals[sql] ?? (0, 0)
                    totals[sql] = (old.0 + 1, old.1 + duration)
                }
                for (sql, total) in totals.sorted(by: { $0.value.1 > $1.value.1 }).prefix(12) {
                    print("CL-281 SQL count=\(total.0) total_ms=\(total.1*1000) \(sql)")
                }
            }
        }
    }
}

extension CoreTests {
    func testEmptyReservationsAvoidAttemptCorpusWhileConflictsAndProjectGuardsRemain() throws {
        let p = try project("Reservation fast path", "RF"), foreign = try project("Foreign reservation", "FR")
        let pid = p["id"] as! String, candidateTask = try task(p), holderTask = try task(p), foreignTask = try task(foreign)
        let path = directory.appendingPathComponent("reserved").path
        try router.dbQueue.write { db in
            try router.save(db,["id":"reserved-attempt","project_id":pid,"task_id":holderTask["id"]!,"state":"active","principal":"fixture","session_id":"human","phase":"implementation","revision":1,"file_scopes":[["path":path,"access":"write"]],"lane_scopes":[["lane_id":"build","units":1]]],type:"attempt")
        }
        let base: JSON = ["id":"candidate-attempt","project_id":pid,"task_id":candidateTask["id"]!,"file_scopes":[JSON](),"lane_scopes":[JSON]()]
        try router.dbQueue.read { db in
            var queries: [String] = []
            db.trace {if case .statement(let statement) = $0 {queries.append(statement.sql)}}
            try router.validateWorkReservations(db,candidate:base)
            var readOnly = base;readOnly["file_scopes"] = [["path":path,"access":"read"]]
            try router.validateWorkReservations(db,candidate:readOnly)
            db.trace(options:[])
            XCTAssertEqual(queries.count,2,"Each fast path still validates its project")
            XCTAssertFalse(queries.contains {$0.contains("FROM records WHERE type = CAST(? AS TEXT)")},"Empty/read-only reservations must not enumerate historical attempts")
            var write = base;write["file_scopes"] = [["path":path,"access":"write"]]
            assertCode("SCOPE_CONFLICT") {try router.validateWorkReservations(db,candidate:write)}
            var lane = base;lane["lane_scopes"] = [["lane_id":"build","units":1]]
            assertCode("LANE_FULL") {try router.validateWorkReservations(db,candidate:lane)}
            for projectID in ["missing-project",foreignTask["id"] as! String] {
                var invalid = base;invalid["project_id"] = projectID
                assertCode("NOT_FOUND") {try router.validateWorkReservations(db,candidate:invalid)}
            }
        }
        let worker = Caller(role:"worker",installation:"foreign-reservation-test",projectIDs:[pid],workspace:directory.path)
        assertCode("FORBIDDEN") {_ = try call("work_claim",["project_id":foreign["id"]!,"task_id":foreignTask["id"]!,"expected_revision":foreignTask["revision"]!],worker)}
        try router.dbQueue.write { db in
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES('malformed-project','foreign-owner','project',1,?)",arguments:[try jsonString(["id":"malformed-project","project_id":"foreign-owner","revision":1])])
        }
        try router.dbQueue.read { db in
            var malformed = base;malformed["project_id"] = "malformed-project"
            assertCode("CANONICAL_RECORD_INVALID") {try router.validateWorkReservations(db,candidate:malformed)}
        }
    }

    func testCompactClaimContextKeepsAttemptWindowPriorHandlerAndUsableDirectionCursor() throws {
        let p = try project("Claim context window", "CW"), pid = p["id"] as! String
        let t = try ready(p,task(p,"Claim window")), tid = t["id"] as! String
        try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {
            for index in 0..<30 {
                try router.save(db,["id":"window-attempt-\(index)","project_id":pid,"task_id":tid,"principal":owner.principal,"session_id":"human","state":"released","phase":"implementation","revision":1,"started_at":"2026-10-25T00:00:00Z"],type:"attempt")
            }
            return .commit
        }}
        var statements: [String] = []
        try router.dbQueue.read {db in db.trace {if case .statement(let statement) = $0 {statements.append(statement.expandedSQL)}}}
        let claim: JSON
        do {claim = try call("work_claim",["project_id":pid,"task_id":tid,"expected_revision":t["revision"]!,"phase":"implementation"])}
        catch {try? router.dbQueue.read {$0.trace(options:[])};throw error}
        try router.dbQueue.read {$0.trace(options:[])}
        let context = try XCTUnwrap(claim["context"] as? JSON), attempts = try XCTUnwrap(context["attempts"] as? [JSON])
        XCTAssertEqual(attempts.compactMap {$0["id"] as? String},(6..<30).map {"window-attempt-\($0)"}+[claim["id"] as! String])
        XCTAssertEqual((context["prior_handler"] as? JSON)?["id"] as? String,"window-attempt-29")
        XCTAssertEqual((context["counts"] as? JSON)?["attempts"] as? Int,31)
        XCTAssertEqual(context["truncated"] as? Bool,true)
        XCTAssertEqual(context["next_action"] as? String,"continue_implementation")
        let windows = statements.filter {$0.contains("WHERE type='attempt'") && $0.contains("AND (1) ORDER BY rowid DESC LIMIT 26")}
        XCTAssertEqual(windows.count,1,"The compatibility section must reuse the same newest-26 attempt window")
        try router.dbQueue.read { db in
            let current = try router.record(db,tid,type:"task"), exactAttempt = try router.scoped(db,claim["id"] as! String,pid,type:"attempt")
            try router.validateDirectionCursor(db,params:["direction_cursor":context["direction_cursor"]!],task:current,caller:owner,attempt:exactAttempt)
        }
        let checkpoint = try call("work_checkpoint",["project_id":pid,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"direction_cursor":context["direction_cursor"]!,"progress":"The exact fresh claim cursor remains usable."])
        XCTAssertNotNil(checkpoint["checkpoint_id"])
        try router.dbQueue.read { db in
            let current = try router.record(db,tid,type:"task")
            let fallback = try router.directionCursorScope(db,task:current,caller:owner)
            for explicit in [["id":claim["id"]!] as JSON,[:],["id":42],["id":NSNull()]] {
                var queries: [String] = []
                db.trace {if case .statement(let statement) = $0 {queries.append(statement.sql)}}
                let actual = try router.directionCursorScope(db,task:current,caller:owner,attempt:explicit)
                db.trace(options:[])
                XCTAssertEqual(actual,fallback)
                let callerLookups = queries.filter {$0.contains("json_extract(data,'$.state')='active' AND json_extract(data,'$.principal')=?")}
                XCTAssertEqual(callerLookups.count,explicit["id"] is String ? 0 : 1)
            }
            var queries: [String] = []
            db.trace {if case .statement(let statement) = $0 {queries.append(statement.sql)}}
            let emptyID = try router.directionCursorScope(db,task:current,caller:owner,attempt:["id":""])
            db.trace(options:[])
            XCTAssertTrue(emptyID.hasPrefix(pid+":directions:"+tid+"::"),"An explicit String ID retains the prior empty-string semantics")
            XCTAssertFalse(queries.contains {$0.contains("json_extract(data,'$.principal')=?")})
        }
    }

    func testCompactContextCountsRemainExactBelowAtAndAboveWindowLimits() throws {
        let p = try project("Context count boundaries", "CB"), pid = p["id"] as! String
        for (caseIndex,population) in [(25,true),(26,true),(27,true),(10,false),(11,false),(12,false)].enumerated() {
            let (count,allFamilies) = population
            let t = try ready(p,task(p,"Boundary \(caseIndex)")), tid = t["id"] as! String
            let prefix = "boundary-\(caseIndex)-"
            try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {
                for index in 0..<count {
                    let common: JSON = ["project_id":pid,"task_id":tid,"revision":1]
                    var message = common;message["id"] = prefix+"message-\(index)";message["body"] = "Fixture note";message["created_at"] = "2026-10-25T00:00:00Z";message["origin"] = allFamilies ? "human_ui" : "agent";message["requires_action"] = allFamilies;message["addressed"] = false
                    try router.save(db,message,type:"message")
                    if allFamilies {
                        for (type,state) in [("finding","open"),("request","pending"),("review_request","queued"),("attempt","released")] {
                            var value = common;value["id"] = prefix+type+"-\(index)";value["state"] = state
                            if type == "attempt" {value["principal"] = owner.principal;value["session_id"] = "human";value["phase"] = "implementation"}
                            try router.save(db,value,type:type)
                        }
                    }
                }
                return .commit
            }}
            try router.dbQueue.read { db in
                let raw = try router.record(db,tid,type:"task")
                var statements: [String] = []
                db.trace {if case .statement(let statement) = $0 {statements.append(statement.expandedSQL)}}
                let context = try router.compactTaskContext(db,task:raw,caller:owner)
                db.trace(options:[])
                let counts = try XCTUnwrap(context["counts"] as? JSON), familyCount = allFamilies ? count : 0
                for key in ["unresolved_directions","unresolved_findings","pending_requests","pending_reviews","attempts","blocking_findings"] {XCTAssertEqual(counts[key] as? Int,familyCount,"\(caseIndex):\(key)")}
                XCTAssertEqual(counts["messages"] as? Int,count)
                XCTAssertEqual(counts["direction_deliveries"] as? Int,0)
                XCTAssertEqual(context["truncated"] as? Bool,count>10)
                XCTAssertEqual(context["next_action"] as? String,allFamilies ? "address_owner_directions" : "claim_work")
                let recent = try XCTUnwrap(context["recent_messages"] as? [JSON])
                XCTAssertEqual(recent.compactMap {$0["id"] as? String},(max(0,count-10)..<count).map {prefix+"message-\($0)"})
                let history = try XCTUnwrap(context["attempts"] as? [JSON])
                XCTAssertEqual(history.compactMap {$0["id"] as? String},allFamilies ? (max(0,count-25)..<count).map {prefix+"attempt-\($0)"} : [])
                let fullAttemptCounts = statements.filter {$0.hasPrefix("SELECT COUNT(*) FROM records WHERE type='attempt'") && $0.contains("AND (1)")}
                XCTAssertEqual(fullAttemptCounts.count,allFamilies && count>=26 ? 1 : 0)
                let fullMessageCounts = statements.filter {$0.hasPrefix("SELECT COUNT(*) FROM records WHERE type='message'") && $0.contains("AND (1)")}
                XCTAssertEqual(fullMessageCounts.count,count>=11 ? 1 : 0)
            }
        }
    }

    func testImplementationClaimCategoryMatchesProjectionAndPreservesStatusRefusals() throws {
        let p = try project("Claim category", "CC"), other = try project("Other category", "OC")
        let pid = p["id"] as! String, value = try task(p)
        let statuses = try router.dbQueue.read {try router.records($0,type:"status",project:pid)}
        let foreign = try router.dbQueue.read {try router.records($0,type:"status",project:other["id"] as? String).first!}
        func outcome(_ body:() throws -> String) -> String {
            do {return "category:" + (try body())}
            catch let error as CoreError {return "error:" + error.code}
            catch {return "unexpected:" + String(describing:error)}
        }
        try router.dbQueue.read { db in
            let raw = try router.record(db,value["id"] as! String,type:"task")
            var cases: [(String,JSON,String)] = []
            for category in ["queued","blocked","active","parked","done"] {
                var task = raw
                task["status_id"] = try XCTUnwrap(statuses.first {$0["category"] as? String == category})["id"]
                cases.append((category,task,"category:"+category))
            }
            for (name,statusID) in [("missing","missing-status"),("foreign",foreign["id"] as! String),("wrong family",pid),("empty","")] {
                var task = raw;task["status_id"] = statusID
                cases.append((name,task,"error:NOT_FOUND"))
            }
            var absent = raw;absent.removeValue(forKey:"status_id")
            cases.append(("absent legacy",absent,"category:queued"))
            absent["status_category"] = "blocked"
            cases.append(("absent legacy category",absent,"category:blocked"))
            var nontext = raw;nontext["status_id"] = 42
            cases.append(("nontext legacy",nontext,"category:queued"))
            for (name,task,expected) in cases {
                let original = outcome {try router.taskProjection(db,task)["status_category"] as? String ?? "queued"}
                let direct = outcome {try router.implementationClaimCategory(db,task:task)}
                XCTAssertEqual(original,expected,name)
                XCTAssertEqual(direct,original,name)
            }
        }
        // The same canonical decoder still refuses malformed referenced status
        // rows before category eligibility can authorize a claim.
        try router.dbQueue.write { db in
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES(?,?,'status',1,?)",arguments:["malformed-status",pid,try jsonString(["id":"different-id","project_id":pid,"revision":1,"category":"queued"])])
        }
        try router.dbQueue.read { db in
            var malformed = try router.record(db,value["id"] as! String,type:"task")
            malformed["status_id"] = "malformed-status"
            XCTAssertEqual(outcome {try router.taskProjection(db,malformed)["status_category"] as? String ?? "queued"},"error:CANONICAL_RECORD_INVALID")
            XCTAssertEqual(outcome {try router.implementationClaimCategory(db,task:malformed)},"error:CANONICAL_RECORD_INVALID")
        }
    }

    func testImplementationClaimsStillAllowQueuedBlockedAndRejectActiveParked() throws {
        let p = try project("Claim eligibility", "CE"), pid = p["id"] as! String
        let statuses = try router.dbQueue.read {try router.records($0,type:"status",project:pid)}
        for category in ["queued","blocked","active","parked"] {
            let created = try ready(p,task(p,category))
            var current = created
            try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {
                var value = try router.record(db,created["id"] as! String,type:"task")
                value["status_id"] = try XCTUnwrap(statuses.first {$0["category"] as? String == category})["id"]
                value = router.revised(value)
                try router.save(db,value,type:"task")
                current = value
                return .commit
            }}
            let params: JSON = ["project_id":pid,"task_id":current["id"]!,"expected_revision":current["revision"]!,"phase":"implementation"]
            if ["queued","blocked"].contains(category) {
                let claim = try call("work_claim",params)
                XCTAssertEqual((claim["task"] as? JSON)?["status_category"] as? String,"active")
                XCTAssertNotNil(claim["claim_token"] as? String)
                XCTAssertNotNil(claim["context"] as? JSON)
            } else {
                assertCode("INVALID_TRANSITION") {_ = try call("work_claim",params)}
                try router.dbQueue.read { db in
                    let unchanged = try router.record(db,current["id"] as! String,type:"task")
                    XCTAssertEqual(unchanged["revision"] as? Int,current["revision"] as? Int)
                    XCTAssertNil(unchanged["active_attempt_id"])
                    XCTAssertEqual(try router.scopedTaskCount(db,type:"attempt",task:unchanged),0)
                }
            }
        }
    }

    func testWorkspaceTaskPageSharesCleanupCountsAndKeepsFreshProjectionFacts() throws {
        let p = try project("Overview cleanup counts", "OC"), pid = p["id"] as! String
        let first = try ready(p,task(p,"First")), second = try ready(p,task(p,"Second")), third = try ready(p,task(p,"Third"))
        try router.dbQueue.write { db in
            for (index,task) in [first,first,third].enumerated() {
                try router.save(db,["id":"cleaned-\(index)","project_id":pid,"task_id":task["id"]!,"mode":"managed","availability":"original_cleaned","revision":1],type:"attachment")
            }
            try router.save(db,["id":"available","project_id":pid,"task_id":second["id"]!,"mode":"managed","availability":"available","revision":1],type:"attachment")
        }
        let readers = try XCTUnwrap(router.readers)
        var statements: [String] = []
        try readers.read { db in
            db.trace { if case .statement(let statement) = $0 {statements.append(statement.sql)} }
        }
        let page: JSON
        do {page = try call("workspace_page",["project_id":pid,"surface":"needs_pickup","limit":3])}
        catch {try? readers.read {$0.trace(options:[])};throw error}
        try readers.read {$0.trace(options:[])}
        let rows = try XCTUnwrap(page["rows"] as? [JSON])
        XCTAssertEqual(rows.count,3)
        let actual = Dictionary(uniqueKeysWithValues:rows.map {($0["id"] as! String,$0["cleaned_original_count"] as! Int)})
        XCTAssertEqual(actual,[first["id"] as! String:2,second["id"] as! String:0,third["id"] as! String:1])
        let countReads = statements.filter {$0.contains("FROM records WHERE type='attachment'") && $0.contains("COUNT(*)")}
        XCTAssertEqual(countReads.count,1,"Page projection must not scan attachment history once per displayed task or repeat it for health")
        try router.dbQueue.read { db in
            for task in [first,second,third] {
                let raw = try router.record(db,task["id"] as! String,type:"task")
                let projected = try router.selectedTaskProjection(db,task:raw)
                let listed = try XCTUnwrap(rows.first {$0["id"] as? String == task["id"] as? String})
                XCTAssertEqual(try jsonString(projected),try jsonString(listed),"The page must retain the selected projection's health, status and prerequisite facts")
            }
        }
        // The next pinned snapshot must recompute the aggregate even when a
        // maintenance write did not emit an event or revise the ticket.
        try router.dbQueue.write { db in
            try router.save(db,["id":"later-cleaned","project_id":pid,"task_id":second["id"]!,"mode":"managed","availability":"original_cleaned","revision":1],type:"attachment")
        }
        let refreshed = try call("workspace_page",["project_id":pid,"surface":"needs_pickup","limit":3])["rows"] as! [JSON]
        XCTAssertEqual(refreshed.first {$0["id"] as? String == second["id"] as? String}?["cleaned_original_count"] as? Int,1)
    }
}

extension CoreTests {
    func testTriageStatusRetentionReadsOnlyDestinationCategory() throws {
        let p = try project("Destination category", "DC"), pid = p["id"] as! String
        let t = try ready(p,task(p)), group = try triage(p)
        try addTriage(p,group,t)
        let before = try currentTriage(p,group)
        try router.dbQueue.write { db in
            let statuses = try router.records(db,type:"status",project:pid)
            // Canceled leaves the Triage since CL-125 (rule 8), like Done.
            for status in statuses where !["done","canceled"].contains(status["category"] as? String ?? "") {
                var destination = try router.record(db,t["id"] as! String,type:"task")
                destination["status_id"] = status["id"]
                // The persisted fallback cannot override a present destination.
                destination["status_category"] = "done"
                var queries: [String] = []
                db.trace {if case .statement(let statement) = $0 {queries.append(statement.sql)}}
                try router.recordTicketStatusAction(db,task:destination,caller:owner,operation:.triage)
                db.trace(options:[])
                XCTAssertEqual(queries.count,1,"A retained status action needs only its destination status")
                XCTAssertTrue(queries[0].contains("WHERE id = CAST(? AS TEXT)"),queries[0])
            }
        }
        XCTAssertEqual(try jsonString(currentTriage(p,group)),try jsonString(before))
        // Done still removes every current handling membership and records its exit.
        let other = try triage(p)
        try addTriage(p,other,t)
        try router.dbQueue.writeWithoutTransaction {db in try router.withValidatedDomainTransaction(db) {
            var destination = try router.record(db,t["id"] as! String,type:"task")
            destination["status_id"] = try router.status(db,pid,"done")["id"]
            try router.recordTicketStatusAction(db,task:destination,caller:owner,operation:.triage)
            return .commit
        }}
        for value in [group,other] {XCTAssertFalse(strings(try currentTriage(p,value),"task_ids").contains(t["id"] as! String))}
        try router.dbQueue.read {db in
            XCTAssertEqual(try router.records(db,type:"triage_membership_exit",project:pid).filter {$0["task_id"] as? String == t["id"] as? String}.count,2)
        }
    }

    func testRealSizeBatchClaimRetainsMembershipAndReleaseFences() throws {
        try QualificationSuite.requireEnabled() // Retained project scale: 250 unrelated records in each of four families.
        let p = try project("Bounded batch effects", "BE"), pid = p["id"] as! String
        let tasks = try [ready(p,task(p,"One")),ready(p,task(p,"Two"))], group = try triage(p)
        for t in tasks {try addTriage(p,group,t)}
        // Template records model a project with retained history and many other
        // containers. These are owned fixtures, never a live-store dependency.
        try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {
            for index in 0..<250 {
                let tid = "unrelated-batch-task-\(index)"
                try router.save(db,["id":tid,"project_id":pid,"title":"Other \(index)","epic_id":tasks[0]["epic_id"]!,"status_id":tasks[0]["status_id"]!,"revision":1],type:"task")
                try router.save(db,["id":"unrelated-batch-group-\(index)","project_id":pid,"kind":"triage","phase":"implementation","members":[["task_id":tid]],"task_ids":[tid],"revision":1],type:"group")
                try router.save(db,["id":"unrelated-batch-attempt-\(index)","project_id":pid,"task_id":tid,"phase":"implementation","state":"released","principal":"fixture","session_id":"human","revision":1],type:"attempt")
                try router.save(db,["id":"unrelated-batch-relation-\(index)","project_id":pid,"source_task_id":tid,"target_task_id":tasks[0]["id"]!,"relation":"related_to","state":"active","revision":1],type:"relation")
            }
            return .commit
        }}
        func current() throws -> JSON {
            try XCTUnwrap((try call("triage_list",["project_id":pid,"triage_id":group["id"]!,"fields":["task_ids"]])["groups"] as? [JSON])?.first)
        }
        // CL-125 rule 6: the owner's batch claim keeps the tickets in an orchestrated Triage.
        try orchestrateTriage(p,group)
        let selected = try tasks.map {value -> JSON in
            let fresh = try call("task_get",["project_id":pid,"task_id":value["id"]!])
            return ["task_id":fresh["id"]!,"expected_revision":fresh["revision"]!]
        }
        let batch = try call("batch_prepare",["project_id":pid,"triage_id":group["id"]!,"expected_revision":current()["revision"]!,"phase":"implementation","tasks":selected])
        let claimed = try claimFixedBatch(p,batch)
        let claims = try XCTUnwrap(claimed["claims"] as? [JSON])
        XCTAssertEqual(claims.count,2)
        XCTAssertEqual(strings(try current(),"task_ids"),tasks.map {$0["id"] as! String})
        for claim in claims {
            let projected = try XCTUnwrap(claim["task"] as? JSON), context = try XCTUnwrap(claim["context"] as? JSON)
            XCTAssertEqual(projected["status_category"] as? String,"active")
            XCTAssertEqual(context["next_action"] as? String,"continue_implementation")
            XCTAssertEqual((context["handler"] as? JSON)?["id"] as? String,claim["id"] as? String)
        }
        assertCode("CLAIM_CONFLICT") {_ = try claimFixedBatch(p,batch)}
        let members = claims.map {["attempt_id":$0["id"]!,"claim_token":$0["claim_token"]!] as JSON}
        var invalid = members; invalid[1]["claim_token"] = "invalid"
        assertCode("STALE_CLAIM") {_ = try call("batch_release",["project_id":pid,"batch_id":batch["id"]!,"members":invalid,"reason":"Must be atomic"])}
        for t in tasks {XCTAssertEqual(try call("task_get",["project_id":pid,"task_id":t["id"]!])["status_category"] as? String,"active")}
        _ = try call("batch_release",["project_id":pid,"batch_id":batch["id"]!,"members":members,"reason":"Fixture complete"])
        XCTAssertEqual(strings(try current(),"task_ids"),tasks.map {$0["id"] as! String})
        for t in tasks {XCTAssertEqual(try call("task_get",["project_id":pid,"task_id":t["id"]!])["status_category"] as? String,"queued")}
        assertCode("STALE_CLAIM") {_ = try call("work_checkpoint",["project_id":pid,"attempt_id":claims[0]["id"]!,"claim_token":claims[0]["claim_token"]!,"progress":"Released claim cannot write"])}
    }
}

extension CoreTests {
    func testCompactContextReusesNewestManifestWindowAtBothSectionLimits() throws {
        let p = try project("Manifest window reuse", "MW"), pid = p["id"] as! String
        for count in [0,25,26,27,100,101,102] {
            let t = try task(p,"Window \(count)"), tid = t["id"] as! String
            try router.dbQueue.writeWithoutTransaction {db in try router.withValidatedDomainTransaction(db) {
                for index in 0..<count {
                    try router.save(db,["id":"reused-manifest-\(count)-\(index)","project_id":pid,"task_id":tid,"revision":1,"created_at":"2026-10-25T00:00:00Z","evidence":["measures":[["name":"fixture count","unit":"count","after":index,"limit":50]]]],type:"manifest")
                }
                return .commit
            }}
            try router.dbQueue.read {db in
                var queries:[String]=[]
                db.trace {if case .statement(let statement) = $0 {queries.append(statement.expandedSQL)}}
                let context = try router.compactTaskContext(db,task:t,caller:owner)
                db.trace(options:[])
                let history = try XCTUnwrap(context["manifests"] as? [JSON])
                XCTAssertEqual(history.compactMap {$0["id"] as? String},(max(0,count-25)..<count).map {"reused-manifest-\(count)-\($0)"})
                let evidence = try XCTUnwrap(context["evidence_measures"] as? JSON)
                XCTAssertEqual(try jsonString(evidence),try jsonString(router.evidenceMeasuresContext(db,task:t)))
                XCTAssertEqual(evidence["truncated"] as? Bool,count>100)
                XCTAssertEqual(context["truncated"] as? Bool,count>25)
                let reads = queries.filter {$0.contains("FROM records WHERE type='manifest'") && $0.contains("ORDER BY rowid DESC LIMIT")}
                XCTAssertEqual(reads.count,1,"Both consumers must share the same exact newest101 window")
            }
        }
    }

    func testTaskProjectionHealthKeepsByteExactPrerequisiteIdentity() throws {
        let p = try project("Projection health identity", "PH"), pid = p["id"] as! String
        let prerequisite = try task(p,"Prerequisite"), template = try ready(p,task(p,"Dependent"))
        let exactID = "health-é", aliasID = "health-e\u{301}"
        try router.dbQueue.writeWithoutTransaction {db in try router.withValidatedDomainTransaction(db) {
            for (id,key) in [(exactID,"PH-opaque-a"),(aliasID,"PH-opaque-b")] {
                var value = template;value["id"] = id;value["key"] = key;value["revision"] = 1
                try router.save(db,value,type:"task")
            }
            try router.save(db,["id":"health-alias-relation","project_id":pid,"source_task_id":aliasID,"target_task_id":prerequisite["id"]!,"relation":"depends_on","required":true,"state":"active","revision":1],type:"relation")
            return .commit
        }}
        try router.dbQueue.read {db in
            let fresh = try router.record(db,exactID,type:"task")
            let expectedHealth = try router.workHealthView(db,task:fresh)
            let projected = try router.taskProjection(db,fresh)
            // The legacy full projection compares Swift strings. Health's exact
            // selected reader must retain its distinct SQL BINARY identities.
            XCTAssertEqual((projected["prerequisite_blockers"] as? [JSON])?.count,1)
            let health = try XCTUnwrap(projected["work_health"] as? JSON)
            XCTAssertEqual(try jsonString(health),try jsonString(expectedHealth))
            XCTAssertFalse((health["known_waits"] as? [JSON] ?? []).contains {$0["kind"] as? String == "dependency"})
        }
    }
}
