import ChecklistTestSupport
import XCTest
import GRDB
import Darwin
import SQLite3
@testable import ChecklistCore

private final class CleanupTraffic: @unchecked Sendable {
    let lock = NSLock()
    private var stopped = false
    private var writes = 0
    private var peak: UInt64 = 0
    func stop() {lock.withLock {stopped = true}}
    var isStopped: Bool {lock.withLock {stopped}}
    var count: Int {lock.withLock {writes}}
    var peakBytes: UInt64 {lock.withLock {peak}}
    func recordWrite() {lock.withLock {writes += 1}}
    func sample(_ value: UInt64) {lock.withLock {peak = max(peak,value)}}
}

extension TicketLifecycleCleanupTests {
    func testProjectedInventoryRetainsCompleteOwnedChildrenAndForeignReferences() throws {
        let (p,t,a) = try fixture(),pid = p["id"] as! String,tid = t["id"] as! String
        let other = try call("task_create",["project_id":pid,"title":"Reference owner"])
        let parent = uuid(),child = uuid(),foreign = uuid(),padding = String(repeating:"payload-",count:4096)
        try write {db in
            var attachment = try self.router.record(db,a["id"] as! String,type:"attachment")
            attachment["private_metadata"] = padding
            try self.router.save(db,self.router.revised(attachment),type:"attachment")
            try self.router.save(db,["id":parent,"project_id":pid,"task_id":tid,"revision":1,"body":padding],type:"message")
            try self.router.save(db,["id":child,"project_id":pid,"message_id":parent,"revision":1,"body":padding],type:"message")
            try self.router.save(db,["id":foreign,"project_id":pid,"task_id":other["id"]!,"revision":1,"body":padding,"nested":["attachment":a["id"]!]],type:"message")
        }
        let inventory = try router.readers!.read {try self.router.ticketCleanupInventory($0,task:t)}
        for id in [parent,child,foreign] {
            XCTAssertEqual(inventory.rows.first {$0.id == id}?.value["body"] as? String,padding)
        }
        let attachment = try XCTUnwrap(inventory.rows.first {$0.id == a["id"] as! String})
        XCTAssertEqual(attachment.value["private_metadata"] as? String,padding)
        XCTAssertNotNil(attachment.value["path"])
        XCTAssertTrue(inventory.tokens[Data(foreign.utf8)]?.contains(Data((a["id"] as! String).utf8)) == true)
        try pass();try finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String),"A nested reference outside the selected ownership still retains its bytes")
    }

    func testProjectedUnrelatedPayloadStillValidatesCompleteUTF8() throws {
        let (p,t,a) = try fixture(),id = uuid()
        var bytes = Data("{\"id\":\"\(id)\",\"project_id\":\"\(p["id"]!)\",\"revision\":1,\"body\":\"".utf8)
        bytes.append(Data(repeating:120,count:32768));bytes.append(0xff);bytes.append(Data("\"}".utf8))
        try write {db in
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES(?,?,'message',1,CAST(? AS TEXT))",arguments:[id,p["id"] as! String,bytes])
        }
        XCTAssertThrowsError(try router.readers!.read {try self.router.ticketCleanupInventory($0,task:t)}) {
            XCTAssertEqual(($0 as? CoreError)?.code,"CANONICAL_RECORD_INVALID")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
    }

    func testProjectedUnrelatedPayloadStillRejectsUnpairedSurrogateEscape() throws {
        let (p,t,a) = try fixture(),id = uuid(),padding = String(repeating:"x",count:32768)
        let raw = "{\"id\":\"\(id)\",\"project_id\":\"\(p["id"]!)\",\"revision\":1,\"body\":\"\(padding)\",\"value\":\"\\ud800\"}"
        XCTAssertThrowsError(try JSONSerialization.jsonObject(with:Data(raw.utf8)))
        try write {db in
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT json_valid(?)",arguments:[raw]),1)
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES(?,?,'message',1,?)",arguments:[id,p["id"] as! String,raw])
        }
        XCTAssertThrowsError(try router.readers!.read {try self.router.ticketCleanupInventory($0,task:t)}) {
            XCTAssertEqual(($0 as? CoreError)?.code,"CANONICAL_RECORD_INVALID")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
    }

    func testProjectedReferenceKeysIncludeCapturePrefixesAndTypedDigests() throws {
        let (p,t,a) = try fixture(),pid = p["id"] as! String,capture = uuid(),foreign = uuid(),hold = uuid()
        let path = "source-captures/" + pid + "/" + capture + "/source",padding = String(repeating:"payload-",count:4096)
        try write {db in
            try self.router.save(db,["id":capture,"project_id":pid,"task_id":t["id"]!,"revision":1,"snapshot_path":path,"files":[]],type:"source_capture")
            try self.router.save(db,["id":foreign,"project_id":pid,"revision":1,"nested":[path + "/retained.txt":padding]],type:"message")
            try self.router.save(db,["id":hold,"project_id":pid,"revision":1,"kind":"reader","state":"active","nested":[a["sha256"] as! String:padding]],type:"storage_hold")
        }
        let inventory = try router.readers!.read {try self.router.ticketCleanupInventory($0,task:t)}
        XCTAssertNotNil(inventory.rows.first {$0.id == foreign},"A capture path in a JSON key is still a reference")
        XCTAssertNotNil(inventory.rows.first {$0.id == hold},"A typed hold's digest in a JSON key still protects the object")
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info(),count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to:&info) {pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)}
        }
        XCTAssertEqual(result,KERN_SUCCESS)
        return info.resident_size
    }

    private func peakResidentBytes() -> Int64 {
        var usage = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF,&usage),0)
        return Int64(usage.ru_maxrss) // Darwin reports bytes.
    }
    func testPreparationProgressUnderConstantUnrelatedWritesAndBoundsMemory() throws {
        try QualificationSuite.requireEnabled()
        let (p,_,_) = try fixture(),pid = p["id"] as! String
        for n in 0..<2 {
            let task = try call("task_create",["project_id":pid,"title":"Selected ticket \(n)"])
            let source = directory.appendingPathComponent("selected-\(n).txt")
            try Data("selected \(n)".utf8).write(to:source)
            _ = try call("attachment_add",["project_id":pid,"task_id":task["id"]!,"path":source.path,"mode":"managed_copy"])
            try mark(p,task,category:"done")
        }
        let unrelated = try call("task_create",["project_id":pid,"title":"Unrelated active traffic"]),other = unrelated["id"] as! String
        // Live-shaped corpus: thousands of records, 2,000 managed attachments,
        // 128 MiB of JSON payload. Insert one row at a time; do not retain a corpus
        // in the fixture itself or measure fixture construction as preparation.
        let payload = String(repeating:"large-payload-",count:2048),files = try StorageObjectFiles(root:router.root)
        try write {db in
            for n in 0..<5000 {
                let id = uuid()
                var value: JSON = ["id":id,"project_id":pid,"task_id":other,"revision":1,"body":payload + String(n)]
                let type = n < 2000 ? "attachment" : "message"
                if type == "attachment" {
                    let path = "objects/" + id + ".txt",bytes = Data("synthetic bytes".utf8)
                    try files.writeNew(path,bytes:bytes)
                    value["path"] = path;value["mode"] = "managed";value["sha256"] = ChecklistCore.hash(bytes);value["size"] = bytes.count;value["name"] = id
                }
                try self.router.save(db,value,type:type)
            }
        }
        let before = TicketLifecycleCleanupTests.residentBytes(),traffic = CleanupTraffic(),fixtureRouter = router!, trafficCaller = owner
        let writer = expectation(description:"constant unrelated writer"),sampler = expectation(description:"bounded preparation RSS sampler")
        DispatchQueue.global(qos:.utility).async {
            defer {writer.fulfill()}
            while !traffic.isStopped {
                do {
                    _ = try fixtureRouter.handle(method:"message_send",params:["command_id":uuid(),"project_id":pid,"task_id":other,"body":"Constant unrelated traffic"],caller:trafficCaller)
                    traffic.recordWrite()
                } catch {XCTFail("Concurrent writer failed: \(error)");break}
                Thread.sleep(forTimeInterval:0.005)
            }
        }
        DispatchQueue.global(qos:.utility).async {
            defer {sampler.fulfill()}
            while !traffic.isStopped {traffic.sample(TicketLifecycleCleanupTests.residentBytes());Thread.sleep(forTimeInterval:0.005)}
        }
        var committed = 0
        for attempt in 0..<3 {
            try write {db in try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?, '0')",arguments:["ticket-cleanup-next:" + pid])}
            let preparationBefore = TicketLifecycleCleanupTests.residentBytes(),writesBefore = traffic.count
            try router.withTicketCleanupPreparation({db in
                let prepared = try self.router.prepareTicketLifecycleCleanup(db)
                // Exceed the former 256-row change budget during EVERY snapshot,
                // and keep writing through its actual commit boundary.
                let deadline = Date().addingTimeInterval(30)
                while traffic.count-writesBefore < 300,Date() < deadline {Thread.sleep(forTimeInterval:0.002)}
                XCTAssertGreaterThanOrEqual(traffic.count-writesBefore,300)
                return prepared
            }) {db,_,prepared in
                committed += 1
                try self.router.commitTicketLifecycleCleanup(db,prepared:prepared,at:Date())
            }
            print("CL193_PREPARATION attempt=\(attempt+1) unrelated_writes=\(traffic.count-writesBefore) rss_before=\(preparationBefore) rss_after=\(TicketLifecycleCleanupTests.residentBytes()) sampled_peak=\(traffic.peakBytes)")
        }
        traffic.stop();wait(for:[writer,sampler],timeout:10)
        let after = TicketLifecycleCleanupTests.residentBytes(),growth = after > before ? after-before : 0
        print("CL193_CONTENTION records=5000 attachments=2000 json_payload_bytes=\(payload.utf8.count * 5000) preparations=3 commits=\(committed) rss_before=\(before) rss_after=\(after) rss_growth=\(growth) sampled_peak_rss=\(traffic.peakBytes) process_high_water_rss=\(peakResidentBytes()) writes=\(traffic.count)")
        XCTAssertEqual(committed,3,"Unrelated writes must not fence any prepared pass")
        XCTAssertLessThan(traffic.peakBytes-before,128 * 1024 * 1024,"Transient preparation memory must stay bounded under constant writes")
    }
}

extension TicketLifecycleCleanupTests {
    func expireCleanupBackoff() throws {
        router.ticketCleanupRetryAt = nil;router.ticketCleanupFailure = nil;router.ticketCleanupYieldAt = nil
        try write {db in
            let keys = try String.fetchAll(db,sql:"SELECT key FROM metadata WHERE key LIKE 'ticket-cleanup-preparation:%'")
            for key in keys {
                var state = jsonObject(try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[key]) ?? "{}")
                state["next_attempt_at"] = "2000-01-01T00:00:00Z"
                try db.execute(sql:"UPDATE metadata SET value=? WHERE key=?",arguments:[try jsonString(state),key])
            }
        }
    }
    func testSelectedTicketFenceSkipsOnlyThatTicketAndBackoffSurvivesRestart() throws {
        let (p,t,a) = try fixture(),pid = p["id"] as! String
        let other = try call("task_create",["project_id":pid,"title":"Another Done ticket"])
        let source = directory.appendingPathComponent("other.txt");try Data("other".utf8).write(to:source)
        _ = try call("attachment_add",["project_id":pid,"task_id":other["id"]!,"path":source.path,"mode":"managed_copy"])
        try mark(p,other,category:"done")
        var committed = false
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketLifecycleCleanup(db)
            _ = try self.call("message_send",["project_id":pid,"task_id":t["id"]!,"body":"Selected ticket changed"])
            return prepared
        }) {_,_,_ in committed = true}
        XCTAssertFalse(committed);XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
        let maintenance = try call("ticket_cleanup_receipts",["project_id":pid])["maintenance"] as! JSON
        let attempt = maintenance["preparation"] as! JSON
        XCTAssertEqual(maintenance["state"] as? String,"deferred")
        XCTAssertNotNil(attempt["attempted_at"]);XCTAssertNotNil(attempt["last_failed_at"])
        XCTAssertTrue((attempt["last_failure_reason"] as? String ?? "").contains("concurrent write"))
        let next = try XCTUnwrap(ISO8601DateFormatter().date(from:attempt["next_attempt_at"] as! String))
        XCTAssertGreaterThan(next.timeIntervalSinceNow,55)
        var attempts = 0
        for _ in 0..<100 {
            try router.withTicketCleanupPreparation({db -> TicketCleanupPreparedPass? in
                let prepared = try self.router.prepareTicketLifecycleCleanup(db)
                if prepared != nil {attempts += 1};return prepared
            }) {_,_,_ in XCTFail("Backoff must not commit")}
        }
        XCTAssertEqual(attempts,0)
        let root = router.root;try router.closeStore();router = try TestStore.router(root:root)
        try router.runStorageMaintenance()
        let restarted = try call("ticket_cleanup_receipts",["project_id":pid])["maintenance"] as! JSON
        XCTAssertEqual((restarted["preparation"] as? JSON)?["attempt_count"] as? Int,attempt["attempt_count"] as? Int)
        try expireCleanupBackoff();try pass(at:Date().addingTimeInterval(1))
        let items = try receipts(p).flatMap {$0["items"] as? [JSON] ?? []}
        XCTAssertTrue(items.contains {$0["task_id"] as? String == t["id"] as? String && $0["reason"] as? String == "fenced_by_concurrent_write"})
        XCTAssertTrue(items.contains {$0["task_id"] as? String == other["id"] as? String && $0["action"] as? String == "done_evidence"},"\(items)")
    }
    func testByteDeletionProgressesUnderUnrelatedWritesButNewForeignReferenceFences() throws {
        let (p,t,a) = try fixture(),pid = p["id"] as! String
        let other = try call("task_create",["project_id":pid,"title":"Unrelated writer"])
        try pass()
        var committed = 0
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketObjectDeletion(db)
            _ = try self.call("message_send",["project_id":pid,"task_id":other["id"]!,"body":"Unrelated to bytes"])
            return prepared
        }) {db,permit,prepared in committed += 1;try self.router.processTicketObjectDeletionIntents(db,permit:permit,prepared:prepared)}
        XCTAssertEqual(committed,1);XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String))
        let (q,_,b) = try fixture();try pass()
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketObjectDeletion(db)
            try self.write {writer in
                try self.router.save(writer,["id":uuid(),"project_id":q["id"]!,"revision":1,"path":b["path"]!],type:"message")
            }
            return prepared
        }) {_,_,_ in XCTFail("A new path reference must fence unlink")}
        XCTAssertTrue(FileManager.default.fileExists(atPath:b["path"] as! String))
        XCTAssertFalse(bool(try read(t),"purged"))
    }
}

extension TicketLifecycleCleanupTests {
    func testOnePlannedTicketPerStepAndLargeUnrelatedPayloadDoesNotBlockProgress() throws {
        let (p,t,a) = try fixture(),pid = p["id"] as! String
        try write {db in
            try self.router.save(db,["id":uuid(),"project_id":pid,"revision":1,"body":String(repeating:"unrelated-🟢",count:400000)],type:"message")
        }
        try pass();try finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String));XCTAssertFalse(bool(try read(t),"purged"))
        let next = try call("task_create",["project_id":pid,"title":"Aged work after an empty Done ticket"])
        let source = directory.appendingPathComponent("later.txt");try Data("later".utf8).write(to:source)
        let attachment = try call("attachment_add",["project_id":pid,"task_id":next["id"]!,"path":source.path,"mode":"managed_copy"])
        try mark(p,next,category:"done",age:20)
        // The first Done ticket now has no new bytes. It cannot donate its
        // narrowed ownership inventory to the later aged ticket's purge.
        try pass(at:Date().addingTimeInterval(1));try pass(at:Date().addingTimeInterval(2));try finish()
        XCTAssertTrue(bool(try read(next),"purged"));XCTAssertFalse(FileManager.default.fileExists(atPath:attachment["path"] as! String))
    }
    func testOversizedSelectedTicketReportsRefusalWithoutBlockingAnotherProject() throws {
        let (p,t,a) = try fixture(),(q,_,b) = try fixture()
        try write {db in
            try self.router.save(db,["id":uuid(),"project_id":p["id"]!,"task_id":t["id"]!,"revision":1,"body":String(repeating:"selected",count:700000)],type:"message")
        }
        try pass()
        let maintenance = try call("ticket_cleanup_receipts",["project_id":p["id"]!])["maintenance"] as! JSON
        XCTAssertEqual(maintenance["state"] as? String,"deferred")
        XCTAssertEqual((maintenance["preparation"] as? JSON)?["last_failure_reason"] as? String,"CLEANUP_INVENTORY_LIMIT")
        try pass();try finish()
        XCTAssertFalse(try receipts(q).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String));XCTAssertFalse(FileManager.default.fileExists(atPath:b["path"] as! String))
    }
}

extension TicketLifecycleCleanupTests {
    func testAutomaticPurgePreservesByteExactNULRecordIdentity() throws {
        let (p,t,_) = try fixture(age:20),pid = p["id"] as! String
        let other = try call("task_create",["project_id":pid,"title":"Unrelated owner"]),prefix = uuid(),owned = prefix + "\0owned"
        try write {db in
            try self.router.save(db,["id":prefix,"project_id":pid,"task_id":other["id"]!,"revision":1,"body":"Must remain"],type:"message")
            try self.router.save(db,["id":owned,"project_id":pid,"task_id":t["id"]!,"revision":1,"body":"Selected private note"],type:"message")
        }
        try pass()
        XCTAssertTrue(bool(try read(t),"purged"))
        XCTAssertNoThrow(try router.dbQueue.read {try router.record($0,prefix,type:"message")})
        XCTAssertThrowsError(try router.dbQueue.read {try router.record($0,owned,type:"message")})
    }
}

extension TicketLifecycleCleanupTests {
    func testLargeUnrelatedOwnershipHeaderStaysBounded() throws {
        let (p,_,a) = try fixture()
        try write {db in
            try self.router.save(db,["id":uuid(),"project_id":p["id"]!,"revision":1,"kind":String(repeating:"unrelated",count:700000),"body":"Large optional header value"],type:"message")
        }
        try pass();try finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String))
    }
}

extension TicketLifecycleCleanupTests {
    func testSelectedPayloadAndHistoryPreparationHasBoundedPeak() throws {
        try QualificationSuite.requireEnabled()
        let (p,t,_) = try fixture(age:20),pid = p["id"] as! String,tid = t["id"] as! String
        try write {db in
            try self.router.save(db,["id":uuid(),"project_id":pid,"task_id":tid,"revision":1,"body":String(repeating:"s",count:3 * 1024 * 1024)],type:"message")
            let text = String(repeating:"historical",count:4096)
            for _ in 0..<128 {
                try self.router.event(db,caller:self.owner,project:pid,entity:pid,kind:"fixture_unrelated_history",data:["body":text])
                try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[self.owner.principal,uuid(),"fixture",try jsonString(["data":["body":text]])])
            }
        }
        let before = TicketLifecycleCleanupTests.residentBytes(),sample = CleanupTraffic(),finished = expectation(description:"selected payload memory sample")
        DispatchQueue.global(qos:.utility).async {
            defer {finished.fulfill()}
            while !sample.isStopped {sample.sample(TicketLifecycleCleanupTests.residentBytes());Thread.sleep(forTimeInterval:0.005)}
        }
        try pass();sample.stop();wait(for:[finished],timeout:5)
        XCTAssertTrue(bool(try read(t),"purged"))
        XCTAssertLessThan(sample.peakBytes > before ? sample.peakBytes-before : 0,128 * 1024 * 1024)
        print("CL193_SELECTED_MEMORY selected_payload_bytes=3145728 history_rows=256 rss_before=\(before) sampled_peak_rss=\(sample.peakBytes) process_high_water_rss=\(peakResidentBytes())")
    }
}

extension TicketLifecycleCleanupTests {
    func testDigestOnlyLateHoldFencesButUnrelatedDigestMentionDoesNot() throws {
        let (p,_,a) = try fixture(),pid = p["id"] as! String
        let other = try call("task_create",["project_id":pid,"title":"Other work"])
        var admitted = false
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketLifecycleCleanup(db)
            _ = try self.call("message_send",["project_id":pid,"task_id":other["id"]!,"body":a["sha256"]!])
            return prepared
        }) {db,_,prepared in admitted = true;try self.router.commitTicketLifecycleCleanup(db,prepared:prepared,at:Date())}
        XCTAssertTrue(admitted)
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketObjectDeletion(db)
            try self.write {writer in try self.router.save(writer,["id":uuid(),"project_id":pid,"revision":1,"kind":"reader","state":"active","sha256":a["sha256"]!],type:"storage_hold")}
            return prepared
        }) {_,_,_ in XCTFail("Digest-only hold must fence unlink")}
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
        try expireCleanupBackoff();try finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
    }
}


extension TicketLifecycleCleanupTests {
    func testProjectWriteDependencies() throws {
        let (p,_,_) = try fixture(),pid = p["id"] as! String
        let other = try call("task_create",["project_id":pid,"title":"Traffic"])
        let before = try router.dbQueue.read {try self.router.record($0,pid,type:"project")}
        try router.dbQueue.writeWithoutTransaction {try TicketCleanupChanges.install($0)}
        defer {try? router.dbQueue.writeWithoutTransaction {try TicketCleanupChanges.remove($0)}}
        _ = try call("message_send",["project_id":pid,"task_id":other["id"]!,"body":"Ordinary note"])
        _ = try call("task_edit",["project_id":pid,"task_id":other["id"]!,"expected_revision":other["revision"]!,"patch":["title":"Edited traffic"]])
        let after = try router.dbQueue.read {try self.router.record($0,pid,type:"project")}
        print("CL193_PROJECT_DIFF " + String(describing:Set(before.keys).union(after.keys).filter {String(describing:before[$0]) != String(describing:after[$0])}))
        let changes = try router.dbQueue.read {try Row.fetchAll($0,sql:"SELECT * FROM ticket_cleanup_changes WHERE id=CAST(? AS BLOB)",arguments:[Data(pid.utf8)])}
        print("CL193_PROJECT_WRITES " + String(describing:changes))
        XCTAssertEqual(try jsonString(before),try jsonString(after))
    }

    func testProjectCounterWriteMustNotFenceCleanup() throws {
        let (p,_,a) = try fixture(),pid = p["id"] as! String
        let counterEpic = try call("epic_create",["project_id":p["id"]!,"name":"Concurrent writer ticket"])
        var committed = false
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketLifecycleCleanup(db)
            _ = try self.call("task_create",["project_id":pid,"title":"Unrelated counter allocation","epic_id":counterEpic["id"]!])
            return prepared
        }) {db,_,prepared in
            committed = true
            try self.router.commitTicketLifecycleCleanup(db,prepared:prepared,at:Date())
        }
        XCTAssertTrue(committed,"Project ticket counters are not cleanup policy")
        try finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String))
    }

    func testBackupDescriptorStreamingHasBoundedAllocations() throws {
        try QualificationSuite.requireEnabled()
        let (p,_,_) = try fixture()
        try write {db in
            let objects = (0..<72760).map {n in ["path":"objects/diagnostic-\(n)","sha256":String(repeating:"a",count:64),"size":1] as JSON}
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('backup-generation:diagnostic',?)",arguments:[try jsonString(["state":"complete","objects":objects])])
        }
        var baseline: UInt64 = 0
        for n in 0..<8 {
            try router.readers!.read {db in
                _ = try self.router.ticketCleanupBackupRetentionIndex(db,objects:[])
                var current: Int32 = 0,high: Int32 = 0
                sqlite3_db_status(db.sqliteConnection,SQLITE_DBSTATUS_CACHE_USED,&current,&high,0)
                let rss = TicketLifecycleCleanupTests.residentBytes()
                if n == 0 {baseline = rss}
                XCTAssertLessThan(rss,baseline + 64 * 1024 * 1024)
                XCTAssertLessThan(current,32 * 1024 * 1024)
                print("CL193_ALLOCATION attempt=\(n) rss=\(TicketLifecycleCleanupTests.residentBytes()) sqlite_cache=\(current) sqlite_peak=\(high)")
            }
        }
        _ = p
    }
}


extension TicketLifecycleCleanupTests {
    func testChangeIndexBudgetRetainsBytesAndDoesNotInterruptWriter() throws {
        let (p,_,a) = try fixture()
        let counterEpic = try call("epic_create",["project_id":p["id"]!,"name":"Concurrent writer ticket"])
        var committed = false
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketLifecycleCleanup(db)
            try self.router.dbQueue.writeWithoutTransaction {writer in
                try writer.execute(sql:"WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<40000) INSERT INTO ticket_cleanup_edges SELECT CAST(i AS BLOB),0 FROM n")
                XCTAssertLessThanOrEqual(try Int.fetchOne(writer,sql:"SELECT units FROM ticket_cleanup_budget")!,TicketCleanupChanges.rowLimit)
                XCTAssertLessThanOrEqual(try Int.fetchOne(writer,sql:"SELECT bytes FROM ticket_cleanup_budget")!,TicketCleanupChanges.byteLimit)
            }
            _ = try self.call("task_create",["project_id":p["id"]!,"title":"Writer still commits after index limit","epic_id":counterEpic["id"]!])
            return prepared
        }) {_,_,_ in committed = true}
        XCTAssertFalse(committed)
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
        let state = try router.dbQueue.read {try self.router.ticketCleanupPreparationState($0,project:p["id"] as! String)}
        XCTAssertEqual(state["last_failure_reason"] as? String,"fenced by concurrent write to change index budget")
    }

    func testProjectCleanupSettingsAndForeignWorkspaceRootStillFence() throws {
        let (p,_,a) = try fixture(),(q,_,_) = try fixture()
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketLifecycleCleanup(db)
            _ = try self.configure(p,settings:["done_evidence_enabled":false,"closed_purge_enabled":false,"closed_days":15])
            return prepared
        }) {_,_,_ in XCTFail("Changed cleanup policy must fence")}
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
        _ = try configure(p);try expireCleanupBackoff()
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketLifecycleCleanup(db)
            try self.write {writer in
                var foreign = try self.router.record(writer,q["id"] as! String,type:"project")
                foreign["root_path"] = self.router.root.path
                try self.router.save(writer,self.router.revised(foreign),type:"project")
            }
            return prepared
        }) {_,_,_ in XCTFail("Changed foreign workspace protection must fence")}
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
    }

    private func cpuSeconds() -> Double {
        var usage = rusage();XCTAssertEqual(getrusage(RUSAGE_SELF,&usage),0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)/1000000
    }

    func testSustainedWritersBoundRSSCPUAndBackoff() throws {
        try QualificationSuite.requireEnabled()
        guard let duration = Double(ProcessInfo.processInfo.environment["CL193_SOAK_SECONDS"] ?? "360"),duration >= 180 else {throw XCTSkip("Qualification soak duration must be at least 180 seconds")}
        let (p,t,a) = try fixture(),pid = p["id"] as! String
        let trafficEpic = try call("epic_create",["project_id":pid,"name":"Independent traffic"])
        let trafficEpicID = trafficEpic["id"] as! String
        let other = try call("task_create",["project_id":pid,"title":"Independent traffic ticket","epic_id":trafficEpicID]),otherID = other["id"] as! String
        try write {db in
            try autoreleasepool {
                let payload = String(repeating:"unrelated-payload-",count:1536)
                for n in 0..<5000 {
                    let id = uuid()
                    try self.router.save(db,["id":id,"project_id":pid,"task_id":otherID,"revision":1,"body":payload + String(n)],type:n < 2000 ? "attachment" : "message")
                }
                let objects = (0..<72760).map {n in ["path":"objects/soak-\(n)","sha256":String(repeating:"a",count:64),"size":1] as JSON}
                try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('backup-generation:soak',?)",arguments:[try jsonString(["state":"complete","objects":objects])])
            }
        }
        let traffic = CleanupTraffic(),fixtureRouter = router!, trafficCaller = owner,started = Date(),initialCPU = cpuSeconds()
        var workers: [XCTestExpectation] = []
        for worker in 0..<3 {
            let done = expectation(description:"sustained writer \(worker)");workers.append(done)
            DispatchQueue.global(qos:.utility).async {
                defer {done.fulfill()}
                while !traffic.isStopped {
                    do {try autoreleasepool {
                        _ = try fixtureRouter.handle(method:"message_send",params:["command_id":uuid(),"project_id":pid,"task_id":otherID,"body":"Sustained unrelated writer \(worker)"],caller:trafficCaller)
                        // Actual ticket creation writes the project's next_number.
                        _ = try fixtureRouter.handle(method:"task_create",params:["command_id":uuid(),"project_id":pid,"title":"Counter traffic \(worker)","epic_id":trafficEpicID],caller:trafficCaller)
                        traffic.recordWrite()
                    }} catch {XCTFail("Sustained writer: \(error)");return}
                    Thread.sleep(forTimeInterval:2)
                }
            }
        }
        let sampler = expectation(description:"sustained RSS sampler");workers.append(sampler)
        DispatchQueue.global(qos:.utility).async {
            defer {sampler.fulfill()}
            while !traffic.isStopped {traffic.sample(TicketLifecycleCleanupTests.residentBytes());Thread.sleep(forTimeInterval:0.01)}
        }
        let reader = expectation(description:"sustained reader");workers.append(reader)
        DispatchQueue.global(qos:.utility).async {
            defer {reader.fulfill()}
            while !traffic.isStopped {
                do {try autoreleasepool {_ = try fixtureRouter.handle(method:"task_get",params:["project_id":pid,"task_id":otherID],caller:trafficCaller)}} catch {XCTFail("Sustained reader: \(error)");return}
                Thread.sleep(forTimeInterval:2)
            }
        }
        defer {traffic.stop();wait(for:workers,timeout:15)}
        var armed = try router.nextArchiveCleanupDeadline()
        var nextSample = 0.0,nextReset = 0.0,nextRefusal = duration/2,minuteStart = started,minuteCPU = initialCPU
        var minutePeaks: [UInt64] = [],minutePeak: UInt64 = 0,commitsObserved = 0,refusals = 0,backoffAttempts: Int?,lastAttempts = 0
        var postAttemptRSS: [UInt64] = [],backoffStart: Date?,backoffCPU = 0.0,backoffWindows = 0,firstNewPass: Double?
        while Date().timeIntervalSince(started) < duration {
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < duration/2,elapsed >= nextReset {
                _ = try configure(p);nextReset += 30;armed = try router.nextArchiveCleanupDeadline()
            }
            if elapsed >= nextRefusal {
                if let began = backoffStart {
                    let rate = (cpuSeconds()-backoffCPU)*60/Date().timeIntervalSince(began)
                    print("CL193_BACKOFF cpu_seconds_per_minute=\(rate) wall_seconds=\(Date().timeIntervalSince(began))")
                    XCTAssertLessThan(rate,20,"Whole process including ordinary traffic must stay below one third of a core in backoff")
                    backoffWindows += 1
                }
                try expireCleanupBackoff();_ = try configure(p)
                try router.withTicketCleanupPreparation({db in
                    let prepared = try self.router.prepareTicketLifecycleCleanup(db)
                    _ = try self.call("message_send",["project_id":pid,"task_id":t["id"]!,"body":"Deliberate selected-ticket conflict"])
                    return prepared
                }) {_,_,_ in XCTFail("Selected-ticket conflict cannot commit")}
                let state = try router.dbQueue.read {try self.router.ticketCleanupPreparationState($0,project:pid)}
                XCTAssertEqual(state["state"] as? String,"deferred")
                let rss = TicketLifecycleCleanupTests.residentBytes()
                if let first = postAttemptRSS.first {
                    XCTAssertLessThan(rss,first + 64 * 1024 * 1024,"Drained preparation memory cannot grow with repeated attempts")
                }
                postAttemptRSS.append(rss);backoffStart = Date();backoffCPU = cpuSeconds()
                backoffAttempts = int(state,"attempt_count");refusals += 1;nextRefusal = Date().timeIntervalSince(started) + 59
                armed = try router.nextArchiveCleanupDeadline()
            }
            if let deadline = armed,deadline <= Date() {try router.runStorageMaintenance();armed = try router.nextArchiveCleanupDeadline()}
            if elapsed >= nextSample {
                let rss = TicketLifecycleCleanupTests.residentBytes();traffic.sample(rss);minutePeak = max(minutePeak,rss)
                let state = try router.dbQueue.read {try self.router.ticketCleanupPreparationState($0,project:pid)}
                lastAttempts = int(state,"attempt_count")
                if let expected = backoffAttempts,let retry = (state["next_attempt_at"] as? String).flatMap({ISO8601DateFormatter().date(from:$0)}),retry > Date() {XCTAssertEqual(lastAttempts,expected,"Backoff must not start preparations")}
                let receipts = try self.receipts(p)
                commitsObserved = max(commitsObserved,receipts.count)
                if receipts.count > 1,firstNewPass == nil {firstNewPass = elapsed}
                XCTAssertLessThan(traffic.peakBytes,768 * 1024 * 1024,"Hard process RSS bound, including active preparation sampled every 10 ms")
                print("CL193_SOAK sample_seconds=\(Int(elapsed)) rss=\(rss) cpu_seconds=\(cpuSeconds()-initialCPU) writes=\(traffic.count) attempts=\(lastAttempts) receipts=\(receipts.count) state=\(state["state"] ?? "none")")
                fflush(stdout);nextSample += 1
            }
            if Date().timeIntervalSince(minuteStart) >= 60 {
                let wall = Date().timeIntervalSince(minuteStart),cpu = cpuSeconds(),rate = (cpu-minuteCPU)*60/wall
                print("CL193_SOAK_MINUTE elapsed=\(Int(elapsed)) cpu_seconds_per_minute=\(rate) peak_rss=\(minutePeak)")
                XCTAssertLessThan(rate,45,"Maintenance must yield between productive units")
                minutePeaks.append(minutePeak);minutePeak = 0;minuteStart = Date();minuteCPU = cpu
            }
            Thread.sleep(forTimeInterval:0.05)
        }
        print("CL193_SOAK_RESULT duration=\(Date().timeIntervalSince(started)) peak_rss=\(traffic.peakBytes) process_high_water=\(peakResidentBytes()) writes=\(traffic.count) attempts=\(lastAttempts) receipts=\(commitsObserved) refusals=\(refusals) minute_peaks=\(minutePeaks) drained_attempt_rss=\(postAttemptRSS) backoff_windows=\(backoffWindows) first_new_pass_seconds=\(firstNewPass ?? -1)")
        XCTAssertGreaterThan(commitsObserved,1);XCTAssertGreaterThan(backoffWindows,0);XCTAssertLessThan(firstNewPass ?? .infinity,300);XCTAssertGreaterThan(refusals,1);XCTAssertGreaterThan(traffic.count,Int(duration))
        XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String))
    }
}


extension TicketLifecycleCleanupTests {
    func testProjectRevisionAndTimestampDoNotFenceByteContinuationButNewReferenceDoes() throws {
        let (p,_,a) = try fixture(),pid = p["id"] as! String
        try pass()
        var committed = false
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketObjectDeletion(db)
            try self.write {writer in
                let project = try self.router.record(writer,pid,type:"project")
                try self.router.save(writer,self.router.revised(project),type:"project")
            }
            return prepared
        }) {db,permit,value in committed = true;try self.router.processTicketObjectDeletionIntents(db,permit:permit,prepared:value)}
        XCTAssertTrue(committed);XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String))
        let (q,_,b) = try fixture();try pass()
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketObjectDeletion(db)
            try self.write {writer in
                var project = try self.router.record(writer,q["id"] as! String,type:"project")
                project["pinned_decisions"] = [b["path"]!]
                try self.router.save(writer,self.router.revised(project),type:"project")
            }
            return prepared
        }) {_,_,_ in XCTFail("A new project path reference still fences")}
        XCTAssertTrue(FileManager.default.fileExists(atPath:b["path"] as! String))
    }

    func testChangeIndexByteBudgetIsIndependentOfRowBudget() throws {
        try router.dbQueue.writeWithoutTransaction {db in
            try TicketCleanupChanges.install(db);defer {try? TicketCleanupChanges.remove(db)}
            for n in 0..<8 {try db.execute(sql:"INSERT INTO ticket_cleanup_edges VALUES(CAST(?||zeroblob(2097151) AS BLOB),0)",arguments:[n])}
            let units = try Int.fetchOne(db,sql:"SELECT units FROM ticket_cleanup_budget")!
            XCTAssertEqual(units,4);XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT bytes FROM ticket_cleanup_budget"),TicketCleanupChanges.byteLimit)
            XCTAssertEqual(try String.fetchOne(db,sql:"SELECT reason FROM ticket_cleanup_uncertain"),"change index budget")
        }
    }

    func testMaintenanceAlternatesPassesWithPendingBytesAndArmsCPURest() throws {
        let (p,t,_) = try fixture(),pid = p["id"] as! String
        let source = directory.appendingPathComponent("second.txt");try Data("second".utf8).write(to:source)
        _ = try call("attachment_add",["project_id":pid,"task_id":t["id"]!,"path":source.path,"mode":"managed_copy"])
        try pass();_ = try configure(p)
        let before = try receipts(p).count
        router.ticketCleanupLifecycleTurn = false
        try router.runStorageMaintenance()
        XCTAssertGreaterThan(try XCTUnwrap(router.ticketCleanupYieldAt).timeIntervalSinceNow,0)
        let expected = try XCTUnwrap(router.nextArchiveCleanupDeadline())
        XCTAssertGreaterThan(expected.timeIntervalSinceNow,0)
        let attempts = try router.dbQueue.read {try self.router.ticketCleanupPreparationState($0,project:pid)["attempt_count"] as? Int}
        try router.runStorageMaintenance()
        XCTAssertEqual(try router.dbQueue.read {try self.router.ticketCleanupPreparationState($0,project:pid)["attempt_count"] as? Int},attempts,"Rest must not prepare another unit")
        router.ticketCleanupYieldAt = nil
        try router.runStorageMaintenance()
        XCTAssertEqual(try receipts(p).count,before+1,"Due pass must run before the byte backlog drains")
        let pending = try router.dbQueue.read {try self.router.records($0,type:"storage_job",project:pid).contains {$0["cause"] as? String == "done_evidence" && $0["state"] as? String == "pending"}}
        XCTAssertTrue(pending)
        try finish()
    }
}


extension TicketLifecycleCleanupTests {
    func testUnchangedProjectReferenceDoesNotTurnCounterWriteIntoFence() throws {
        let (p,_,a) = try fixture(),pid = p["id"] as! String
        try write {db in
            var project = try self.router.record(db,pid,type:"project")
            project["pinned_decisions"] = [a["path"]!]
            try self.router.save(db,self.router.revised(project),type:"project")
        }
        let counterEpic = try call("epic_create",["project_id":p["id"]!,"name":"Concurrent writer ticket"])
        var committed = false
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketLifecycleCleanup(db)
            _ = try self.call("task_create",["project_id":pid,"title":"Unrelated counter with existing reference","epic_id":counterEpic["id"]!])
            return prepared
        }) {db,_,value in committed = true;try self.router.commitTicketLifecycleCleanup(db,prepared:value,at:Date())}
        XCTAssertTrue(committed)
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String),"Existing project reference still retains its bytes")
    }
}


extension TicketLifecycleCleanupTests {
    func testProjectedReferenceScanBoundsWorkWithManyOwnedTokens() throws {
        try QualificationSuite.requireEnabled()
        let (p,t,_) = try fixture(),pid = p["id"] as! String,tid = t["id"] as! String
        let other = try call("task_create",["project_id":pid,"title":"Unrelated projection corpus"])
        try write {db in
            for _ in 0..<400 {
                try self.router.save(db,["id":uuid(),"project_id":pid,"task_id":tid,"revision":1,"body":"Owned token"],type:"message")
            }
            // Real source captures contribute thousands of typed digest tokens.
            try self.router.save(db,["id":uuid(),"project_id":pid,"task_id":tid,"revision":1,
                "digests":(0..<1500).map {String(format:"%064x",$0)}],type:"message")
            let values = (0..<3000).map {"Unrelated reference value \($0)"}
            for _ in 0..<120 {
                try self.router.save(db,["id":uuid(),"project_id":pid,"task_id":other["id"]!,"revision":1,"values":values],type:"message")
            }
        }
        let started = ProcessInfo.processInfo.systemUptime
        let inventory = try router.readers!.read {try self.router.ticketCleanupInventory($0,task:t)}
        print("CL256_TOKEN_SCAN seconds=\(ProcessInfo.processInfo.systemUptime-started) digests=\(inventory.holdDigests.count)")
        XCTAssertGreaterThanOrEqual(inventory.needles.count,401)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-started,5,"An unrelated JSON leaf must not reparse the complete owned-token set for each prefix check")
    }
}


extension TicketLifecycleCleanupTests {
    func testLongRefusedPreparationRestDoesNotPostponeDurableRetry() throws {
        let (p,_,_) = try fixture(),pid = p["id"] as! String
        try router.beginTicketCleanupPreparation(project:pid)
        try router.recordTicketCleanupPreparationRefusal(project:pid,reason:"CLEANUP_CONCURRENT_WRITE")
        let time = Date(),retry = try router.dbQueue.read {try self.router.ticketCleanupProjectRetry($0,project:pid)}
        router.scheduleTicketCleanupRest(since:time.addingTimeInterval(-300),at:time)
        XCTAssertEqual(router.ticketCleanupYieldAt,try XCTUnwrap(retry))
        XCTAssertLessThanOrEqual(try XCTUnwrap(router.nextArchiveCleanupDeadline()),try XCTUnwrap(retry).addingTimeInterval(0.01))
        let overdue = try XCTUnwrap(retry).addingTimeInterval(1)
        router.scheduleTicketCleanupRest(since:time.addingTimeInterval(-300),at:overdue)
        XCTAssertEqual(router.ticketCleanupYieldAt,overdue,"A retry already due must run without another long rest")
        router.ticketCleanupPreparingProject = nil
        router.ticketCleanupRetryAt = nil
        router.scheduleTicketCleanupRest(since:time.addingTimeInterval(-10),at:time)
        XCTAssertEqual(try XCTUnwrap(router.ticketCleanupYieldAt).timeIntervalSince(time),40,accuracy:0.001,"Successful work retains its four-times-wall-time CPU rest")
    }
}
