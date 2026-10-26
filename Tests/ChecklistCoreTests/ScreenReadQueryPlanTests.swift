import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

/// SQL comes from production pure-read dispatch, including cursor/authority reads,
/// not a hand-maintained approximation of the screen queries. Synthetic data only.
final class ScreenReadQueryPlanTests: XCTestCase {
    func testRealSizeScreenReadQueryPlans() throws {
        try QualificationSuite.requireEnabled()
        let f = try ReadPerformanceFixture("CL-280-plans"), r = f.router
        let project = try f.call("project_create", ["name":"Query plans", "key_prefix":"PLAN"])
        let pid = project["id"] as! String
        let statuses = try r.dbQueue.read { try r.records($0, type:"status", project:pid) }
        var rows: [(String, JSON)] = [("group", ["id":"plan-epic", "project_id":pid, "kind":"epic", "name":"Plan fixture", "revision":1])]
        for i in 0..<542 {
            rows.append(("task", ["id":"plan-task-\(i)", "project_id":pid, "title":"Ticket \(i)", "key":"PLAN-\(i)", "kind":"work", "epic_id":"plan-epic", "status_id":statuses[i % statuses.count]["id"]!, "readiness":"ready", "brief":String(repeating:"brief ", count:100), "revision":1, "created_at":"2026-01-01T00:00:00Z", "updated_at":"2026-01-01T00:00:00Z", "completed_at":"2026-01-02T00:00:00Z"]))
        }
        for i in 0..<227 {
            rows.append(("group", ["id":"plan-triage-\(i)", "project_id":pid, "kind":"triage", "phase":"implementation", "name":"Triage \(i)", "task_ids":["plan-task-\(i)", "plan-task-\(i+1)"], "revision":1, "archived":false]))
        }
        for i in 0..<8300 {
            rows.append(("message", ["id":"plan-message-\(i)", "project_id":pid, "task_id":"plan-task-\(i % 542)", "body":String(repeating:"history ", count:50), "revision":1]))
        }
        for i in 0..<800 {
            rows.append(("review", ["id":"plan-review-\(i)", "project_id":pid, "task_id":"plan-task-\(i % 542)", "revision":1, "verdict":"pass", "created_at":"2026-01-01T00:00:00Z"]))
        }
        try f.save(rows)
        try r.dbQueue.write { db in
            for i in 0..<8300 {
                try r.event(db, caller:f.owner, project:pid, entity:"plan-task-\(i % 542)", kind:"fixture_note")
            }
        }
        let surfaces = ["overview", "completed_since", "human_tasks", "needs_active", "needs_done_today", "needs_pickup", "needs_quiet", "needs_recovery", "needs_review", "recent_reviews", "requests", "epics"]
        let view: JSON = ["surface":"tickets", "status_filter":"all", "tag_filter":"all", "group_by":"status", "order_by":"manual"]
        var cases: [(String, String, JSON)] = surfaces.map {
            ("workspace_page/" + $0, "workspace_page", ["surface":$0, "since":"2026-01-01T00:00:00Z"])
        }
        cases += [
            ("triage_list/full", "triage_list", ["project_id":pid]),
            ("triage_list/summary", "triage_list", ["project_id":pid, "fields":["name", "status_category", "member_count"]]),
            ("task_list/full", "task_list", ["project_id":pid]),
            ("task_list/tickets", "task_list", ["project_id":pid, "view":view, "limit":100]),
            ("task_list/summary", "task_list", ["project_id":pid, "limit":50, "fields":["title", "status_id", "status_category", "epic_id"]]),
            ("task_list/project_switch", "task_list", ["view":view, "limit":50]),
            ("epic_list", "epic_list", ["project_id":pid]),
            ("task_context/ui", "task_context", ["project_id":pid, "task_id":"plan-task-0", "detail_level":"ui"]),
            ("task_context/summary", "task_context", ["project_id":pid, "task_id":"plan-task-0", "detail_level":"summary"])
        ]
        print("CL-280 fixture tasks=542 triages=227 messages=8300 reviews=800 events=8300 (plus template/bootstrap rows)")
        for (name, method, params) in cases {
            let trace = QueryTrace()
            var config = Configuration(); config.readonly = true; config.maximumReaderCount = 1
            config.prepareDatabase { db in
                try SchemaMigrations.installStorageCollation(db)
                try CommandRouter.installTicketSearchFunctions(db)
                db.trace { if case .statement(let statement) = $0 { trace.append(statement.expandedSQL) } }
            }
            let pool = try DatabasePool(path:r.root.appendingPathComponent("checklist.sqlite").path, configuration:config)
            defer { try? pool.close() }
            for iteration in 0..<2 {
                trace.clear()
                _ = try r.executePureRead(pool, method:method, params:params, caller:f.owner)
                let statements = trace.statements()
                XCTAssertFalse(statements.isEmpty, name)
                try pool.read { db in
                    // Stop tracing before EXPLAIN so its SQL cannot feed back into the trace.
                    db.trace(nil)
                    defer { db.trace { if case .statement(let statement) = $0 { trace.append(statement.expandedSQL) } } }
                    for table in ["records", "events"] {
                        let indexes = try Row.fetchAll(db, sql:"PRAGMA index_list(\(table))")
                        print("CL-280 \(name) iteration=\(iteration) indexes \(table): \(indexes)")
                    }
                    let executions = Dictionary(grouping:statements, by:{$0}).mapValues(\.count)
                    for sql in executions.keys.sorted() {
                        let plan = try Row.fetchAll(db, sql:"EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }
                        let corpusScans = try Self.fullScanTables(db, sql:sql)
                        let indexes = plan.compactMap { detail -> String? in
                            if detail.contains("USING ") || detail.contains("PRIMARY KEY") { return detail }
                            if detail.hasPrefix("SEARCH events") { return detail + " (implicit INTEGER PRIMARY KEY seq)" }
                            return nil
                        }
                        print("CL-280 \(name) iteration=\(iteration) executions=\(executions[sql]!) SQL=\(sql) INDEX_ACCESS=\(indexes.isEmpty ? ["none (see scan notes)"] : indexes) CORPUS_FULL_SCANS=\(corpusScans.sorted()) PLAN=\(plan)")
                        for detail in plan where detail.hasPrefix("SCAN ") && !Self.indexableFullScan(sql:sql, detail:detail, corpusScans:corpusScans) {
                            print("CL-280 scan note: \(detail); no constrained leading corpus index key (or virtual/derived/small table)")
                        }
                        for detail in plan {
                            XCTAssertFalse(Self.indexableFullScan(sql:sql, detail:detail, corpusScans:corpusScans), "\(name): \(detail) SQL=\(sql)")
                        }
                    }
                }
            }
        }
    }

    /// Only leading storage keys qualify: records(id) / records(project_id,type),
    /// events(seq) / events(project_id,entity_id,seq). JSON/type-only predicates
    /// have no matching leading key. Virtual tables/CTEs are not corpus scans.
    private static func indexableFullScan(sql: String, detail: String, corpusScans: Set<String> = ["records", "events"]) -> Bool {
        let words = detail.lowercased().split(separator:" ").map(String.init)
        guard words.count >= 2, words[0] == "scan" else { return false }
        let alias = words[1]
        let source = sql.lowercased()
        for (table, keys) in [("records", ["id", "project_id"]), ("events", ["seq", "project_id"])] {
            guard corpusScans.contains(table) else { continue }
            let tablePattern = "\\b(?:from|join)\\s+" + table + "\\s+(?:as\\s+)?" + NSRegularExpression.escapedPattern(for:alias) + "\\b"
            guard alias == table || (source.range(of:tablePattern, options:.regularExpression) != nil && !["where", "join", "on"].contains(alias)) else { continue }
            for key in keys {
                let prefix = alias == table ? "(?<![\\w.])(?:" + table + "\\.)?" : "\\b" + NSRegularExpression.escapedPattern(for:alias) + "\\."
                let predicate = prefix + key + "\\s*(?:=|>=|<=|>|<|\\bin\\s*\\(|\\bis\\s+null\\b)"
                if source.range(of:predicate, options:.regularExpression) != nil { return true }
            }
        }
        return false
    }

    /// EQP names aliases, including reused CTE aliases. VDBE cursor roots tell us
    /// whether a Rewind scans a main-schema table/index or only an ephemeral CTE.
    /// This avoids treating `SCAN g` on materialized Triages as `records g`.
    private static func fullScanTables(_ db: Database, sql: String) throws -> Set<String> {
        let roots = Dictionary(uniqueKeysWithValues:try Row.fetchAll(db, sql:"SELECT rootpage,tbl_name FROM sqlite_schema WHERE tbl_name IN ('records','events') AND type IN ('table','index')").map { ($0["rootpage"] as Int, $0["tbl_name"] as String) })
        var cursors: [Int:String] = [:]
        var scanned: Set<String> = []
        let bytecode = try Row.fetchAll(db, sql:"EXPLAIN " + sql)
        let reverseCursors = Set(bytecode.filter { ($0["opcode"] as String) == "Prev" }.map { $0["p1"] as Int })
        for row in bytecode {
            let opcode: String = row["opcode"], cursor: Int = row["p1"]
            switch opcode {
            case "OpenRead", "ReopenIdx":
                cursors[cursor] = (row["p3"] as Int) == 0 ? roots[row["p2"] as Int] : nil
            case "OpenEphemeral", "OpenAutoindex", "OpenPseudo", "Close": cursors[cursor] = nil
            case "OpenDup": cursors[cursor] = cursors[row["p2"] as Int]
            case "Rewind": if let table = cursors[cursor] { scanned.insert(table) }
            case "Last" where reverseCursors.contains(cursor): if let table = cursors[cursor] { scanned.insert(table) }
            default: break
            }
        }
        return scanned
    }

    func testScanGuardUsesOnlyApplicableLeadingKeys() throws {
        XCTAssertTrue(Self.indexableFullScan(sql:"SELECT r.data FROM records r WHERE r.project_id IN ('p') AND r.type='task'", detail:"SCAN r"))
        XCTAssertTrue(Self.indexableFullScan(sql:"SELECT data FROM records WHERE id='t'", detail:"SCAN records"))
        XCTAssertTrue(Self.indexableFullScan(sql:"SELECT * FROM events e WHERE e.project_id='p'", detail:"SCAN e"))
        XCTAssertFalse(Self.indexableFullScan(sql:"SELECT data FROM records WHERE type='project'", detail:"SCAN records"))
        XCTAssertFalse(Self.indexableFullScan(sql:"SELECT data FROM records WHERE json_extract(data,'$.task_id')='t'", detail:"SCAN records"))
        XCTAssertFalse(Self.indexableFullScan(sql:"SELECT data FROM records WHERE type='project' AND EXISTS (SELECT 1 FROM events e WHERE e.project_id='p')", detail:"SCAN records"))
        XCTAssertFalse(Self.indexableFullScan(sql:"SELECT r.data FROM records r WHERE r.type='project' AND EXISTS (SELECT 1 FROM events e WHERE e.project_id='p')", detail:"SCAN r"))
        XCTAssertFalse(Self.indexableFullScan(sql:"SELECT value FROM json_each('[]')", detail:"SCAN json_each VIRTUAL TABLE INDEX 1:"))
        XCTAssertFalse(Self.indexableFullScan(sql:"SELECT data FROM records WHERE id='t'", detail:"SEARCH records USING INDEX sqlite_autoindex_records_1 (id=?)"))
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql:"CREATE TABLE records(id TEXT PRIMARY KEY, project_id TEXT, type TEXT); CREATE INDEX records_scope ON records(project_id,type)")
            let forced = "SELECT * FROM records NOT INDEXED WHERE project_id='p'"
            let scans = try Self.fullScanTables(db, sql:forced)
            XCTAssertEqual(scans, ["records"])
            let forcedPlan = try Row.fetchAll(db, sql:"EXPLAIN QUERY PLAN " + forced).map { $0["detail"] as String }
            XCTAssertTrue(forcedPlan.contains { Self.indexableFullScan(sql:forced, detail:$0, corpusScans:scans) })
            let reverse = forced + " ORDER BY rowid DESC"
            XCTAssertEqual(try Self.fullScanTables(db, sql:reverse), ["records"])
            let cte = "WITH triages AS MATERIALIZED (SELECT * FROM records g WHERE g.project_id='p') SELECT * FROM triages g"
            let cteScans = try Self.fullScanTables(db, sql:cte)
            XCTAssertTrue(cteScans.isEmpty)
            let ctePlan = try Row.fetchAll(db, sql:"EXPLAIN QUERY PLAN " + cte).map { $0["detail"] as String }
            XCTAssertTrue(ctePlan.contains("SCAN g"))
            XCTAssertFalse(ctePlan.contains { Self.indexableFullScan(sql:cte, detail:$0, corpusScans:cteScans) })
        }
    }
}

private final class QueryTrace {
    private let lock = NSLock()
    private var queries: [String] = []
    func append(_ sql: String) {
        let leading = sql.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
        guard leading.hasPrefix("SELECT ") || leading.hasPrefix("WITH ") else { return }
        lock.lock(); defer { lock.unlock() }; queries.append(sql)
    }
    func clear() { lock.lock(); defer { lock.unlock() }; queries.removeAll() }
    func statements() -> [String] { lock.lock(); defer { lock.unlock() }; return queries }
}
