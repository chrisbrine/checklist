import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

/// CL-392: one project must not hold every cleanup turn, a limit refusal must
/// not repeat every minute, and cleanup's own outcome rows must not stop cleanup.
extension TicketLifecycleCleanupTests {
    private func setDue(_ pid: String,at time: Double = 0) throws {
        try router.dbQueue.write {try $0.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-next:" + pid,String(time)])}
    }
    private func preparedProject() throws -> String? {
        try router.ticketCleanupMaintenanceLock.withLock {
            try router.readers!.read {try self.router.prepareTicketLifecycleCleanup($0)?.selection["project_id"] as? String}
        }
    }
    private func addEvents(_ pid: String,count: Int,kind: String,entity: String,data: String) throws {
        try router.dbQueue.write {db in
            try db.execute(sql:"WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<?) INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data) SELECT ?||i,?,?,'fixture',?,?,? FROM n",arguments:[count,uuid() + "-",pid,entity,kind,"2026-10-01T00:00:00Z",data])
        }
    }
    private func retry(_ pid: String,_ tid: String) throws -> TicketCleanupRetry? {
        try router.dbQueue.read {try self.router.ticketCleanupRetryEntries($0,project:pid)[tid]}
    }

    func testCL392DueProjectsTakeTurnsWhileTheFirstProjectStaysDue() throws {
        let (first,_,_) = try fixture(),(second,_,_) = try fixture()
        let a = first["id"] as! String,b = second["id"] as! String
        var served: [String] = []
        // No commit: a preparation that never succeeds keeps both projects due.
        for _ in 0..<4 {
            try setDue(a);try setDue(b)
            served.append(try XCTUnwrap(try preparedProject()))
        }
        XCTAssertEqual(Set(served),[a,b])
        XCTAssertEqual(served[0],served[2]);XCTAssertEqual(served[1],served[3]);XCTAssertNotEqual(served[0],served[1])
    }

    func testCL392EarliestDueProjectGoesFirstWhenNoneWasServed() throws {
        let (first,_,_) = try fixture(),(second,_,_) = try fixture()
        let a = first["id"] as! String,b = second["id"] as! String
        router.ticketCleanupProjectTurns = [:]
        try setDue(a,at:200);try setDue(b,at:100)
        XCTAssertEqual(try preparedProject(),b)
    }

    func testCL392LaterProjectCleansWhileAnEarlierProjectStaysDue() throws {
        let (first,_,_) = try fixture(),(second,_,file) = try fixture()
        let a = first["id"] as! String
        for _ in 0..<2 {try setDue(a);try router.runTicketLifecycleCleanup()}
        try finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath:file["path"] as! String))
        XCTAssertTrue(try receipts(second).contains {($0["summary"] as? JSON)?["removed_count"] as? Int == 1})
    }

    func testCL392LimitRefusalDoublesToOneHourAndADoneWakeStartsAgain() throws {
        var count = 0
        for expected in [60.0,120,240,480,960,1920,3600,3600] {
            let time = Date(timeIntervalSince1970:1000)
            let value = TicketCleanupRetry(refusedAfter:TicketCleanupRetry(deadline:0,token:"t",refusals:count),at:time)
            XCTAssertEqual(value.deadline,1000 + expected,accuracy:0.001);count += 1;XCTAssertEqual(value.refusals,count)
        }
        XCTAssertEqual(TicketCleanupRetry(refusedAfter:nil,at:Date(timeIntervalSince1970:0)).deadline,60,accuracy:0.001)

        let (project,task,_) = try fixture(),pid = project["id"] as! String,tid = task["id"] as! String
        try addEvents(pid,count:100001,kind:"history_fixture",entity:pid,data:"{}")
        var time = Date().addingTimeInterval(1)
        try router.runTicketLifecycleCleanup(at:time)
        let firstRetry = try XCTUnwrap(try retry(pid,tid))
        XCTAssertEqual(firstRetry.refusals,1);XCTAssertEqual(firstRetry.deadline,time.timeIntervalSince1970 + 60,accuracy:0.001)
        try setDue(pid);time = Date(timeIntervalSince1970:firstRetry.deadline + 1)
        try router.runTicketLifecycleCleanup(at:time)
        let secondRetry = try XCTUnwrap(try retry(pid,tid))
        XCTAssertEqual(secondRetry.refusals,2);XCTAssertEqual(secondRetry.deadline,time.timeIntervalSince1970 + 120,accuracy:0.001)
        // The value survives its stored form.
        XCTAssertEqual(try jsonString(secondRetry.value).contains("refusals"),true)

        try mark(project,task,category:"queued");try mark(project,task,category:"done")
        let woken = try XCTUnwrap(try retry(pid,tid))
        XCTAssertEqual(woken.refusals,0);XCTAssertLessThanOrEqual(woken.deadline,Date().timeIntervalSince1970)
        time = Date().addingTimeInterval(1)
        try router.runTicketLifecycleCleanup(at:time)
        let restarted = try XCTUnwrap(try retry(pid,tid))
        XCTAssertEqual(restarted.refusals,1);XCTAssertEqual(restarted.deadline,time.timeIntervalSince1970 + 60,accuracy:0.001)
    }

    func testCL392ConcurrentWriteFenceKeepsItsSixtySecondRetry() throws {
        let (project,task,_) = try fixture(),pid = project["id"] as! String,tid = task["id"] as! String
        let time = Date()
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketLifecycleCleanup(db,at:time)
            try self.write {db in
                var value = try self.router.record(db,tid,type:"task");value["revision"] = int(value,"revision") + 1
                try self.router.save(db,value,type:"task")
            }
            return prepared
        }) {db,_,prepared in try self.router.commitTicketLifecycleCleanup(db,prepared:prepared,at:time)}
        let value = try XCTUnwrap(try retry(pid,tid))
        XCTAssertEqual(value.refusals,0);XCTAssertEqual(value.deadline,time.timeIntervalSince1970 + 60,accuracy:0.001)
    }

    func testCL392OutcomeRowsOfOtherTicketsDoNotCountAgainstTheHistoryLimit() throws {
        let (project,task,_) = try fixture(),pid = project["id"] as! String
        let foreign = "{\"origin\":\"automatic_cleanup\",\"receipt_id\":\"\(uuid())\",\"removed_bytes\":1,\"state\":\"removed\",\"task_id\":\"\(uuid())\"}"
        try addEvents(pid,count:100001,kind:"ticket_evidence_cleanup_outcome",entity:pid,data:foreign)
        let items = try XCTUnwrap(try selection(project)["items"] as? [JSON])
        let item = try XCTUnwrap(items.first {$0["task_id"] as? String == task["id"] as? String})
        XCTAssertEqual(item["action"] as? String,"done_evidence",item["reason"] as? String ?? "")
        // The manual plan reads the same rows through its own scan.
        XCTAssertNoThrow(try router.readers!.read {try self.router.ticketPurgePlan($0,task:self.read(task))})
    }

    func testCL392OutcomeRowThatNamesARemovalKeyStaysInThePlan() throws {
        let (project,task,_) = try fixture(),pid = project["id"] as! String,tid = task["id"] as! String
        let message = uuid(),other = uuid()
        try write {db in try self.router.save(db,["id":message,"project_id":pid,"task_id":tid,"revision":1,"body":"Owned"],type:"message")}
        func outcome(task: String,receipt: String) -> String {"{\"origin\":\"automatic_cleanup\",\"receipt_id\":\"\(receipt)\",\"removed_bytes\":1,\"state\":\"removed\",\"task_id\":\"\(task)\"}"}
        try addEvents(pid,count:1,kind:"ticket_evidence_cleanup_outcome",entity:pid,data:outcome(task:tid,receipt:other))
        try addEvents(pid,count:1,kind:"ticket_evidence_cleanup_outcome",entity:pid,data:outcome(task:other,receipt:message))
        try addEvents(pid,count:1,kind:"ticket_evidence_cleanup_outcome",entity:message,data:outcome(task:other,receipt:other))
        try addEvents(pid,count:1,kind:"ticket_evidence_cleanup_outcome",entity:pid,data:outcome(task:other,receipt:"foreign-receipt"))
        try addEvents(pid,count:1,kind:"ticket_evidence_cleanup_outcome",entity:pid,data:"not json \(tid)")
        try router.readers!.read {db in
            let current = try self.router.record(db,tid,type:"task")
            let batch = try self.router.ticketCleanupInventories(db,tasks:[current])
            let inventory = try XCTUnwrap(batch.inventories[tid])
            let graph = try self.router.ticketPurgeReferenceGraph(task:current,inventory:inventory)
            let observation = try self.router.ticketCleanupEventObservation(db,tasks:[current],inventories:batch.inventories,referenceGraphs:[tid:graph])
            XCTAssertNil(observation.errors[tid])
            let manual = try self.router.ticketPurgePlan(db,task:current,inventory:inventory)
            let observed = try self.router.ticketPurgePlan(db,task:current,inventory:inventory,historyObservation:observation,referenceGraph:graph)
            XCTAssertEqual(manual.digest,observed.digest)
            let rows = observed.events.filter {($0["data"] as String).contains("automatic_cleanup")}.map {$0["data"] as String}
            XCTAssertTrue(rows.contains(outcome(task:tid,receipt:other)))
            XCTAssertTrue(rows.contains(outcome(task:other,receipt:message)))
            XCTAssertTrue(rows.contains(outcome(task:other,receipt:other)))
            XCTAssertFalse(rows.contains(outcome(task:other,receipt:"foreign-receipt")))
        }
    }
}
