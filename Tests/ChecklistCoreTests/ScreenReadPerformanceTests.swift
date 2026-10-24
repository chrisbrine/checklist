import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

/// Opt-in qualification against an owned copy of a stopped test slot. No live path default.
final class ScreenReadPerformanceTests: XCTestCase {
    func testRealSizeScreenReads() throws {
        try QualificationSuite.requireEnabled()
        let f = try ReadPerformanceFixture("CL-254"), r = f.router
        let project = try f.call("project_create",["name":"Screen performance","key_prefix":"PERF"])
        let pid = project["id"] as! String
        let status = try r.dbQueue.read {try r.records($0,type:"status",project:pid).first!["id"] as! String}
        var rows: [(String,JSON)] = [("group",["id":"fixture-epic","project_id":pid,"kind":"epic","name":"Performance fixture","revision":1])]

        for i in 0..<207 {
            rows.append(("task",["id":"task-\(i)","project_id":pid,"title":"Ticket \(i)","key":"PERF-\(i)","kind":"work","epic_id":"fixture-epic","status_id":status,"readiness":"ready","brief":String(repeating:"brief ",count:100),"revision":1,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"]))
        }
        for i in 0..<104 {
            rows.append(("group",["id":"triage-\(i)","project_id":pid,"name":"Triage \(i)","kind":"triage","phase":"implementation","task_ids":["task-\(i)","task-\(i+1)"],"revision":1,"archived":false]))
        }
        for i in 0..<8300 {
            rows.append(("message",["id":"message-\(i)","project_id":pid,"task_id":"task-\(i%207)","body":String(repeating:"history ",count:50),"revision":1]))
        }
        try f.save(rows)
        let view: JSON = ["surface":"tickets","status_filter":"all","tag_filter":"all","group_by":"status","order_by":"manual"]
        for (method,input) in [("workspace_page",["surface":"overview"] as JSON),("task_list",["project_id":pid,"limit":50,"view":view]),("triage_list",["project_id":pid]),("workspace_page",["surface":"epics","project_id":pid])] {
            for iteration in 0..<2 {
                let start = ProcessInfo.processInfo.systemUptime
                _ = try f.call(method,input)
                let elapsed = ProcessInfo.processInfo.systemUptime-start
                print("CL-254 real-size \(method) iteration=\(iteration) ms=\(elapsed*1000)")
                XCTAssertLessThan(elapsed,iteration == 0 ? 1 : 0.3,method)
            }
        }
    }

    func testOverviewWithRetainedReviewHistory() throws {
        try QualificationSuite.requireEnabled()
        let f = try ReadPerformanceFixture("CL-254-reviews")
        let project = try f.call("project_create",["name":"Review history","key_prefix":"REV"])
        let pid = project["id"] as! String
        try f.save((0..<800).map { i in
            ("review",["id":String(format:"review-%04d",i),"project_id":pid,"revision":1,"verdict":"pass","created_at":"2026-01-01T00:00:00Z"] as JSON)
        })
        let start = ProcessInfo.processInfo.systemUptime
        let page = try f.call("workspace_page",["surface":"recent_reviews"])
        let elapsed = ProcessInfo.processInfo.systemUptime-start
        XCTAssertEqual((page["rows"] as! [JSON]).compactMap {$0["id"] as? String},["review-0799","review-0798","review-0797"])
        print("CL-254 retained 800 reviews ms=\(elapsed*1000)")
        XCTAssertLessThan(elapsed,1)
    }

    /// Never bootstraps the real copy: production pure-read dispatch on a read-only pool.
    func testReadOnlyBackupScreenMeasurements() throws {
        guard let path = ProcessInfo.processInfo.environment["CHECKLIST_READ_ONLY_DATABASE"],
              let pid = ProcessInfo.processInfo.environment["CHECKLIST_READ_BENCHMARK_PROJECT_ID"] else {
            throw XCTSkip("Requires an explicitly selected private backup copy and project")
        }
        let f = try ReadPerformanceFixture("CL-254-read-only")
        var configuration = Configuration(); configuration.readonly = true
        configuration.prepareDatabase { db in
            try SchemaMigrations.installStorageCollation(db)
            try CommandRouter.installTicketSearchFunctions(db)
        }
        let pool = try DatabasePool(path: path, configuration: configuration)
        defer { try? pool.close() }
        let owner = Caller(role: "owner", installation: "CL-254-read-only", projectIDs: [])
        let surfaces = ["overview", "completed_since", "human_tasks", "needs_active", "needs_done_today", "needs_pickup", "needs_quiet", "needs_recovery", "needs_review", "recent_reviews", "requests", "epics"]
        var load = [Double](repeating: 0, count: 3); getloadavg(&load, 3)
        print("P9-r1 load=\(load) database=\(path)")
        for surface in surfaces {
            for iteration in 0..<2 {
                let params: JSON = ["surface": surface, "since": "2026-10-22T00:00:00Z"]
                let start = ProcessInfo.processInfo.systemUptime
                let reply = try f.router.executePureRead(pool, method: "workspace_page", params: params, caller: owner)
                let seconds = ProcessInfo.processInfo.systemUptime - start
                let bytes = try JSONSerialization.data(withJSONObject: reply).count
                print("P9-r1 surface=\(surface) iteration=\(iteration) service_ms=\(seconds * 1000) bytes=\(bytes)")
                XCTAssertLessThan(seconds, 1, surface)
            }
        }
        let view: JSON = ["surface":"tickets", "status_filter":"all", "tag_filter":"all", "group_by":"status", "order_by":"manual"]
        for iteration in 0..<2 {
            let start = ProcessInfo.processInfo.systemUptime
            let reply = try f.router.executePureRead(pool, method: "task_list", params: ["project_id":pid, "view":view, "limit":100], caller:owner)
            print("P9-r1 Tickets iteration=\(iteration) service_ms=\((ProcessInfo.processInfo.systemUptime-start)*1000) bytes=\(try JSONSerialization.data(withJSONObject:reply).count)")
        }
    }

    func testOwnedStoreMeasurements() throws {
        guard let path = ProcessInfo.processInfo.environment["CHECKLIST_READ_BENCHMARK_ROOT"],
              let pid = ProcessInfo.processInfo.environment["CHECKLIST_READ_BENCHMARK_PROJECT_ID"] else { throw XCTSkip("Requires an owned test-slot copy and its project ID") }
        let router = try TestStore.router(root:URL(fileURLWithPath:path))
        defer {try? router.closeStore()}
        let owner = Caller(role:"owner",installation:"CL-254-measurement",projectIDs:[])
        let tid = try router.dbQueue.read {db in try router.records(db,type:"task",project:pid).first?["id"] as? String ?? ""}
        let view: JSON = ["surface":"tickets","status_filter":"all","tag_filter":"all","group_by":"status","order_by":"manual"]
        let cases: [(String,String,JSON)] = [
            ("startup","service_info",[:]), ("Overview","workspace_page",["surface":"overview","since":"2026-10-22T00:00:00Z"]),
            ("Tickets with Triages","task_list",["project_id":pid,"view":view,"limit":50]),
            ("Epics","workspace_page",["project_id":pid,"surface":"epics","limit":50]),
            ("ticket detail","task_context",["project_id":pid,"task_id":tid,"detail_level":"ui"]),
            ("project switch","task_list",["view":view,"limit":50]),
            ("triage_list","triage_list",["project_id":pid]), ("task_list","task_list",["project_id":pid]),
            ("epic_list","epic_list",["project_id":pid])]
        print("CL-254 load \(ProcessInfo.processInfo.environment["CHECKLIST_BENCHMARK_LOAD"] ?? "unrecorded")")
        for (name,method,params) in cases {
            for iteration in 0..<2 {
                let start = ProcessInfo.processInfo.systemUptime
                let reply = try router.handle(method:method,params:params,caller:owner)
                let elapsed = ProcessInfo.processInfo.systemUptime-start
                let bytes = try JSONSerialization.data(withJSONObject:reply).count
                print("CL-254 \(name) \(iteration == 0 ? "cold":"repeat") service_ms=\(elapsed*1000) payload_bytes=\(bytes)")
                let screens: Set<String> = ["Overview","Tickets with Triages","Epics","ticket detail","project switch"]
                XCTAssertLessThan(elapsed,iteration == 1 && screens.contains(name) ? 0.3 : 1,name)
            }
        }
        try router.dbQueue.read {db in
            for sql in ["SELECT data FROM records WHERE type='task' AND project_id='\(pid)'", "SELECT MAX(seq) FROM events WHERE project_id='\(pid)'", "SELECT data FROM records WHERE type='triage_membership_interval' AND project_id='\(pid)'", "SELECT data FROM records WHERE id='\(tid)'"] {
                let plans = try Row.fetchAll(db,sql:"EXPLAIN QUERY PLAN "+sql).map {$0["detail"] as String}
                print("CL-254 plan \(sql): \(plans)")
            }
        }
    }
}
