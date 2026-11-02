import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

extension TicketLifecycleCleanupTests {
    private func cl394History(_ project: JSON,count: Int,data: String = "{}") throws {
        let pid = project["id"] as! String
        try router.dbQueue.write {db in
            try db.execute(sql:"WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<?) INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data) SELECT ?||i,?,?,'fixture','cl394_fixture','2026-10-01T00:00:00Z',? FROM n",arguments:[count,uuid() + "-",pid,pid,data])
        }
    }
    private func cl394Maintenance(_ project: JSON) throws -> JSON {
        try XCTUnwrap(try call("ticket_cleanup_receipts",["project_id":project["id"]!])["maintenance"] as? JSON)
    }
    private func cl394AssertLimit(_ project: JSON,name: String,maximum: Int) throws {
        let maintenance = try cl394Maintenance(project),planning = try XCTUnwrap(maintenance["planning"] as? JSON)
        XCTAssertEqual(planning["state"] as? String,"refused")
        XCTAssertEqual(planning["admitted_count"] as? Int,0)
        XCTAssertEqual(planning["refused_count"] as? Int,1)
        let limits = try XCTUnwrap(planning["limits"] as? [JSON])
        XCTAssertEqual(limits.count,1);XCTAssertEqual(limits.first?["name"] as? String,name)
        XCTAssertEqual(limits.first?["maximum"] as? Int,maximum)
        XCTAssertEqual((maintenance["preparation"] as? JSON)?["state"] as? String,"committed","Writer completion remains separate from selection refusal")
    }
    func testCL394HistoryRowLimitIsVisibleAndRepeatedRefusalAddsNoHistory() throws {
        let (project,_,_) = try fixture(),pid = project["id"] as! String
        try cl394History(project,count:100001)
        let time = Date()
        try router.runTicketLifecycleCleanup(at:time)
        try cl394AssertLimit(project,name:"history_rows",maximum:100000)
        func counts() throws -> [Int] {try router.dbQueue.read {db in
            [try Int.fetchOne(db,sql:"SELECT count(*) FROM events")!,try Int.fetchOne(db,sql:"SELECT count(*) FROM records WHERE type='storage_job'")!]
        }}
        let before = try counts()
        try router.dbQueue.write {try $0.execute(sql:"UPDATE metadata SET value='0' WHERE key=?",arguments:["ticket-cleanup-next:" + pid])}
        try router.runTicketLifecycleCleanup(at:time.addingTimeInterval(61))
        XCTAssertEqual(try counts(),before)
        let planning = try XCTUnwrap(try cl394Maintenance(project)["planning"] as? JSON)
        XCTAssertEqual(planning["receipt_written"] as? Bool,false)
        try cl394AssertLimit(project,name:"history_rows",maximum:100000)
        // A later open-ticket chunk must not erase evidence of the refusal.
        let task = try router.dbQueue.read {try XCTUnwrap(self.router.records($0,type:"task",project:pid).first)}
        try mark(project,task,category:"queued")
        try router.dbQueue.write {try $0.execute(sql:"UPDATE metadata SET value='0' WHERE key=?",arguments:["ticket-cleanup-next:" + pid])}
        try router.runTicketLifecycleCleanup(at:time.addingTimeInterval(182))
        let later = try XCTUnwrap(try cl394Maintenance(project)["planning"] as? JSON)
        XCTAssertEqual(later["state"] as? String,"idle")
        XCTAssertEqual(((later["last_refusal"] as? JSON)?["limits"] as? [JSON])?.first?["name"] as? String,"history_rows")
        print("CL394_REPEAT_NOOP new_events=0 new_receipts=0 repeated_passes=1")
    }
    func testCL394HistoryTokenLimitIsVisible() throws {
        let (project,_,_) = try fixture()
        // 1000 rows, each with >2000 traversal nodes: exceed the aggregate
        // token budget without the event-row or per-payload bound.
        let data = try jsonString(["values":[Int](repeating:0,count:2001)])
        try cl394History(project,count:1000,data:data)
        try router.runTicketLifecycleCleanup()
        try cl394AssertLimit(project,name:"history_tokens",maximum:2000000)
    }
    func testCL394CommandRowLimitIsVisible() throws {
        let (project,_,_) = try fixture(category:"canceled",age:20)
        try router.dbQueue.write {db in
            try db.execute(sql:"WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<100001) INSERT INTO commands(principal,command_id,digest,result) SELECT 'fixture',?||i,'fixture','{}' FROM n",arguments:[uuid() + "-"])
        }
        try router.runTicketLifecycleCleanup()
        try cl394AssertLimit(project,name:"command_rows",maximum:100000)
    }
    func testCL394IdenticalEmptyPassSkipsReceiptButChangedResultWritesOne() throws {
        let (project,task,_) = try fixture(category:"queued"),pid = project["id"] as! String
        func run() throws {
            try router.dbQueue.write {try $0.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,'0')",arguments:["ticket-cleanup-next:" + pid])}
            try router.runTicketLifecycleCleanup()
        }
        func count() throws -> Int {try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT count(*) FROM events WHERE kind='ticket_cleanup_pass' AND project_id=?",arguments:[pid])!}}
        try run();let first = try count()
        try run();XCTAssertEqual(try count(),first)
        var current = try read(task)
        current["revision"] = int(current,"revision") + 1
        try write {try self.router.save($0,current,type:"task")}
        try run();XCTAssertEqual(try count(),first + 1)
    }
    func testCL403IdenticalMultiChunkSweepSkipsEachReceiptAndChangedChunkWritesOne() throws {
        let (project,_,_) = try fixture(category:"queued"),pid = project["id"] as! String
        for index in 0..<32 {_ = try call("task_create",["project_id":pid,"title":"Open sweep member \(index)"])}
        func count() throws -> Int {try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT count(*) FROM events WHERE kind='ticket_cleanup_pass' AND project_id=?",arguments:[pid])!}}
        func sweep() throws {
            for _ in 0..<2 {
                try router.dbQueue.write {try $0.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,'0')",arguments:["ticket-cleanup-next:" + pid])}
                try router.runTicketLifecycleCleanup()
            }
        }
        try sweep();XCTAssertEqual(try count(),2)
        try sweep();XCTAssertEqual(try count(),2,"Both unchanged chunks must skip, even though their selected tickets differ")
        try write {db in
            var changed = try XCTUnwrap(self.router.records(db,type:"task",project:pid).last)
            changed["revision"] = int(changed,"revision") + 1
            try self.router.save(db,changed,type:"task")
        }
        try sweep();XCTAssertEqual(try count(),3,"Only the changed chunk writes again")
    }

}
