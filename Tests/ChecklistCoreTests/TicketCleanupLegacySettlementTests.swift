import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

extension TicketLifecycleCleanupTests {
    func testLegacySettlementsWakeTheirTicketsWithoutRestartingTheOrdinarySweep() throws {
        let (project,first,attachment) = try fixture(),pid = project["id"] as! String
        var legacyTasks = [first],closed = [first]
        for n in 1..<70 {
            let task = try call("task_create",["project_id":pid,"title":"Legacy settlement scan \(n)"])
            if n < 3 {
                let source = directory.appendingPathComponent("legacy-\(n).txt")
                try Data("Legacy payload \(n)".utf8).write(to:source)
                _ = try call("attachment_add",["project_id":pid,"task_id":task["id"]!,"path":source.path,"mode":"managed_copy"])
            }
            try mark(project,task,category:n < 3 ? "done" : "canceled")
            closed.append(task)
            if n < 3 {legacyTasks.append(task)}
        }
        try pass()
        let firstItems = try XCTUnwrap(receipts(project).first?["items"] as? [JSON])
        let before = try router.dbQueue.read {db in
            try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-cursor:" + pid])
        }
        XCTAssertNotEqual(before,"0")
        let sweepDeadline = try router.dbQueue.read {try String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-sweep-next:" + pid])}
        let legacyIDs = Set(legacyTasks.map {$0["id"] as! String})
        try write {db in
            // Empty fingerprints make each old job retain its own file before
            // policy-v2 replanning, as in the retained legacy store receipts.
            let jobs = try self.router.records(db,type:"storage_job")
            for task in legacyTasks {
                var job = try XCTUnwrap(jobs.first {$0["cause"] as? String == "done_evidence" && $0["task_id"] as? String == task["id"] as? String})
                job["owned_record_fingerprints"] = [:] as [String:String]
                job.removeValue(forKey:"cleanup_policy_version")
                try self.router.save(db,self.router.revised(job),type:"storage_job")
            }
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-next:" + pid,String(Date().addingTimeInterval(3600).timeIntervalSince1970)])
        }
        XCTAssertTrue(try router.runTicketObjectDeletionCohort())
        XCTAssertTrue(FileManager.default.fileExists(atPath:attachment["path"] as! String))
        try router.dbQueue.read {db in
            XCTAssertEqual(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-cursor:" + pid]),before)
            XCTAssertEqual(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-sweep-next:" + pid]),sweepDeadline)
            let retries = try self.router.ticketCleanupRetryEntries(db,project:pid)
            XCTAssertEqual(Set(retries.keys),legacyIDs)
            XCTAssertEqual(Set(retries.values.map(\.token)).count,legacyIDs.count)
            XCTAssertTrue(retries.values.allSatisfy {$0.deadline <= Date().timeIntervalSince1970})
            let next = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-next:" + pid])
            XCTAssertLessThanOrEqual(try XCTUnwrap(next.flatMap(Double.init)),Date().timeIntervalSince1970)
        }
        var observed = Set(firstItems.compactMap {$0["task_id"] as? String}),replanned = Set<String>()
        for step in 1...4 {
            let selected = try selection(project,at:Date().addingTimeInterval(Double(step)))
            if step == 1 {
                XCTAssertGreaterThan((selected["next_cursor"] as? NSNumber)?.int64Value ?? 0,Int64(before ?? "0") ?? 0)
                XCTAssertTrue(bool(selected,"more"))
                XCTAssertEqual(Set(strings(selected,"attempted_retry_ids")),legacyIDs)
            }
            try router.runTicketLifecycleCleanup(at:Date().addingTimeInterval(Double(step)))
            let items = try XCTUnwrap(receipts(project).first?["items"] as? [JSON])
            observed.formUnion(items.compactMap {$0["task_id"] as? String})
            replanned.formUnion(items.filter {$0["action"] as? String == "done_evidence"}.compactMap {$0["task_id"] as? String})
            if !bool(selected,"more") {break}
        }
        XCTAssertTrue(Set(closed.map {$0["id"] as! String}).isSubset(of:observed))
        XCTAssertTrue(legacyIDs.isSubset(of:replanned))
        XCTAssertTrue(try router.dbQueue.read {try self.router.ticketCleanupRetryEntries($0,project:pid)}.isEmpty)
    }
}
