import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

extension TicketLifecycleCleanupTests {
    func testP321ChunkAdmitsEveryEligibleTicketAndComposesGroupPurges() throws {
        let (project,first,_) = try fixture(category:"canceled",age:20),pid = project["id"] as! String
        var tasks = [first]
        for n in 1..<32 {
            let task = try call("task_create",["project_id":pid,"title":"Closed batch member \(n)"])
            try mark(project,task,category:"canceled",age:20);tasks.append(task)
        }
        let groupID = uuid()
        try write {db in
            try self.router.save(db,["id":groupID,"project_id":pid,"revision":1,"kind":"triage","task_ids":tasks.map {$0["id"] as! String},"members":tasks.map {["task_id":$0["id"]!]}],type:"group")
        }
        try pass()
        let receipt = try XCTUnwrap(receipts(project).first)
        XCTAssertEqual((receipt["items"] as? [JSON])?.filter {$0["action"] as? String == "purge"}.count,32)
        for task in tasks {XCTAssertTrue(bool(try read(task),"purged"))}
        let group = try router.dbQueue.read {try self.router.record($0,groupID,type:"group")}
        XCTAssertEqual(strings(group,"task_ids"),[])
        XCTAssertTrue((group["members"] as? [JSON] ?? []).isEmpty,"A later prepared purge cannot restore an earlier member")
    }

    func testP321SweepCoversAllEligibleTicketsWhileUnrelatedNotesCommit() throws {
        let (project,first,_) = try fixture(category:"canceled",age:20),pid = project["id"] as! String
        let traffic = try call("task_create",["project_id":pid,"title":"Ordinary note traffic"])
        var eligible = [first]
        for n in 1..<65 {
            let task = try call("task_create",["project_id":pid,"title":"Sweep member \(n)"])
            try mark(project,task,category:"canceled",age:20);eligible.append(task)
        }
        var chunks = 0,writes = 0
        for step in 0..<4 {
            var more = false
            let clock = Date().addingTimeInterval(Double(step))
            try router.withTicketCleanupPreparation({db in
                let prepared = try self.router.prepareTicketLifecycleCleanup(db,at:clock)
                if prepared != nil {
                    _ = try self.call("message_send",["project_id":pid,"task_id":traffic["id"]!,"body":"Concurrent ordinary note \(step)"])
                    writes += 1
                }
                return prepared
            }) {db,_,prepared in
                XCTAssertLessThanOrEqual((prepared.selection["items"] as? [JSON] ?? []).count,32)
                chunks += 1;more = bool(prepared.selection,"more")
                try self.router.commitTicketLifecycleCleanup(db,prepared:prepared,at:clock)
            }
            if !more {break}
        }
        XCTAssertEqual(chunks,3);XCTAssertEqual(writes,3)
        for task in eligible {XCTAssertTrue(bool(try read(task),"purged"))}
        XCTAssertTrue(try router.dbQueue.read {try self.router.ticketCleanupRetries($0,project:pid)}.isEmpty)
        XCTAssertFalse(bool(try read(traffic),"purged"))
    }

    func testP321SelectedConflictRetriesOnlyThatTicketAndCommitsOtherPlans() throws {
        let (project,first,firstFile) = try fixture(),pid = project["id"] as! String
        let second = try call("task_create",["project_id":pid,"title":"Other eligible work"])
        let source = directory.appendingPathComponent("other.txt");try Data("other".utf8).write(to:source)
        let secondFile = try call("attachment_add",["project_id":pid,"task_id":second["id"]!,"path":source.path,"mode":"managed_copy"])
        try mark(project,second,category:"done")
        _ = try call("backup_create",["path":directory.appendingPathComponent("conflict-backup").path])
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketLifecycleCleanup(db)
            _ = try self.call("message_send",["project_id":pid,"task_id":first["id"]!,"body":"Concurrent selected note"])
            return prepared
        }) {db,_,prepared in try self.router.commitTicketLifecycleCleanup(db,prepared:prepared,at:Date())}
        let items = try receipts(project).flatMap {$0["items"] as? [JSON] ?? []}
        XCTAssertEqual(items.first {$0["task_id"] as? String == first["id"] as? String}?["reason"] as? String,"fenced_by_concurrent_write")
        XCTAssertEqual(items.first {$0["task_id"] as? String == second["id"] as? String}?["action"] as? String,"done_evidence")
        try finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath:firstFile["path"] as! String))
        XCTAssertFalse(FileManager.default.fileExists(atPath:secondFile["path"] as! String))
        let retry = try router.dbQueue.read {try self.router.ticketCleanupRetries($0,project:pid)}
        XCTAssertEqual(Set(retry.keys),[first["id"] as! String])
        let due = Date(timeIntervalSince1970:try XCTUnwrap(retry.values.first)).addingTimeInterval(1)
        let prepared = try router.readers!.read {try self.router.ticketCleanupSelection($0,project:self.router.record($0,pid,type:"project"),at:due)}
        XCTAssertEqual(strings(prepared.selection,"attempted_retry_ids"),[first["id"] as! String])
        XCTAssertEqual((prepared.selection["items"] as? [JSON])?.count,1,"A retry after the sweep prepares only the fenced ticket")
        XCTAssertEqual((prepared.selection["items"] as? [JSON])?.filter {bool($0,"retry")}.count,1)
    }

    func testP321DoneWakesPreserveMidSweepProgress() throws {
        let (project,first,_) = try fixture(category:"canceled",age:20),pid = project["id"] as! String
        var old: [JSON] = []
        for n in 0..<40 {
            let task = try call("task_create",["project_id":pid,"title":"Ordinary scan \(n)"])
            try mark(project,task,category:"canceled",age:20);old.append(task)
        }
        let wake = try call("task_create",["project_id":pid,"title":"Concurrent Done beyond this chunk"])
        let cursor = try router.dbQueue.read {try Int64.fetchOne($0,sql:"SELECT rowid FROM records WHERE id=?",arguments:[first["id"] as! String])!}
        try router.dbQueue.write {db in
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?),(?,'0')",arguments:["ticket-cleanup-cursor:" + pid,String(cursor),"ticket-cleanup-next:" + pid])
        }
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketLifecycleCleanup(db)
            try self.mark(project,wake,category:"done")
            return prepared
        }) {db,_,prepared in try self.router.commitTicketLifecycleCleanup(db,prepared:prepared,at:Date())}
        let continued = try router.dbQueue.read {try Int64.fetchOne($0,sql:"SELECT CAST(value AS INTEGER) FROM metadata WHERE key=?",arguments:["ticket-cleanup-cursor:" + pid])!}
        XCTAssertGreaterThan(continued,cursor,"A Done wake cannot restart the whole preparation at row zero")
        XCTAssertNotNil(try router.dbQueue.read {try self.router.ticketCleanupRetries($0,project:pid)}[wake["id"] as! String])
        try router.runTicketLifecycleCleanup(at:Date().addingTimeInterval(1))
        for task in old {XCTAssertTrue(bool(try read(task),"purged"))}
    }

    func testP321DoneWakeBacklogReservesOrdinaryScanCapacity() throws {
        let (project,_,_) = try fixture(category:"canceled",age:20),pid = project["id"] as! String
        var cursor: Int64 = 0
        for n in 0..<40 {
            let task = try call("task_create",["project_id":pid,"title":"Queued Done wake \(n)"])
            try mark(project,task,category:"done")
            cursor = try router.dbQueue.read {try Int64.fetchOne($0,sql:"SELECT rowid FROM records WHERE id=?",arguments:[task["id"] as! String])!}
        }
        for n in 0..<20 {
            let task = try call("task_create",["project_id":pid,"title":"Later scan \(n)"])
            try mark(project,task,category:"canceled",age:20)
        }
        try router.dbQueue.write {db in
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?),(?,'0')",arguments:["ticket-cleanup-cursor:" + pid,String(cursor),"ticket-cleanup-next:" + pid])
        }
        let value = try selection(project)
        XCTAssertEqual((value["items"] as? [JSON])?.filter {bool($0,"retry")}.count,16)
        XCTAssertEqual((value["items"] as? [JSON])?.filter {!bool($0,"retry")}.count,16)
        XCTAssertGreaterThan((value["next_cursor"] as? NSNumber)?.int64Value ?? 0,cursor)
    }

    func testP321FreshDoneWakeSurvivesAnAttemptThatObservedTheTicketOpen() throws {
        let (project,task,file) = try fixture(category:"queued"),pid = project["id"] as! String,tid = task["id"] as! String
        let observed = TicketCleanupRetry(at:Date().addingTimeInterval(-1))
        try router.dbQueue.write {db in
            try self.router.saveTicketCleanupRetries(db,project:pid,entries:[tid:observed])
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?),(?,?)",arguments:["ticket-cleanup-next:" + pid,String(observed.deadline),"ticket-cleanup-sweep-next:" + pid,String(Date().addingTimeInterval(86400).timeIntervalSince1970)])
        }
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketLifecycleCleanup(db)
            XCTAssertEqual((prepared?.selection["items"] as? [JSON])?.first?["reason"] as? String,"open_ticket")
            try self.mark(project,task,category:"done")
            return prepared
        }) {db,_,prepared in try self.router.commitTicketLifecycleCleanup(db,prepared:prepared,at:Date())}
        let retained = try router.dbQueue.read {try self.router.ticketCleanupRetryEntries($0,project:pid)[tid]}
        XCTAssertNotNil(retained);XCTAssertNotEqual(retained?.token,observed.token)
        try router.runTicketLifecycleCleanup(at:Date().addingTimeInterval(1));try finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath:file["path"] as! String))
    }

    func testP321UnrelatedDoneTransitionQueuesOnlyItsOwnWakeAndKeepsPreparedPlans() throws {
        let (project,first,file) = try fixture(),pid = project["id"] as! String
        let other = try call("task_create",["project_id":pid,"title":"Concurrent completion"])
        var committed = false
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketLifecycleCleanup(db)
            try self.mark(project,other,category:"done")
            return prepared
        }) {db,_,prepared in
            committed = true;try self.router.commitTicketLifecycleCleanup(db,prepared:prepared,at:Date())
        }
        XCTAssertTrue(committed)
        XCTAssertEqual(try router.dbQueue.read {try String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-cursor:" + pid])},"0")
        let actions = try receipts(project).flatMap {$0["items"] as? [JSON] ?? []}
        XCTAssertEqual(actions.first {$0["task_id"] as? String == first["id"] as? String}?["action"] as? String,"done_evidence")
        try finish();XCTAssertFalse(FileManager.default.fileExists(atPath:file["path"] as! String))
    }
}
