import ChecklistTestSupport
import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

/// CL-344: archive cleanup's reference scan reads a snapshot before the writer;
/// the archive transaction only checks a fence. Synthetic disposable stores only.
final class ArchiveCleanupScanFenceTests: XCTestCase {
    var directory: URL!
    var router: CommandRouter!
    let owner = Caller(role:"owner",installation:"archive-scan-fence-tests",projectIDs:[])
    override func setUpWithError() throws {
        let parent = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .resolvingSymlinksInPath().appendingPathComponent("ChecklistQualification/CL-344")
        directory = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        router = try TestStore.router(root:directory.appendingPathComponent("store"))
    }
    override func tearDownWithError() throws { router = nil;try? FileManager.default.removeItem(at:directory) }
    func call(_ method: String,_ input: JSON) throws -> JSON {
        var p = input;if !CommandRouter.readMethods.contains(method) {p["command_id"] = UUID().uuidString}
        let reply = try router.handle(method:method,params:fixtureTaskInput(router,method:method,input:p),caller:owner)
        return try XCTUnwrap(reply["data"] as? JSON)
    }
    func fixture(count: Int = 2) throws -> (project: JSON,task: JSON,files: [JSON]) {
        var p = try call("project_create",["name":"Scan fence fixture","key_prefix":"SF"])
        p = try call("project_settings_save",["project_id":p["id"]!,"expected_revision":p["revision"]!,"ticket_cleanup":["done_evidence_enabled":false,"closed_purge_enabled":false,"closed_days":15]])
        p = try call("archive_storage_settings",["project_id":p["id"]!,"expected_revision":p["revision"]!,"settings_revision":p["settings_revision"]!,"archive_storage":["preset":"clean_large_managed_on_archive","large_original_bytes":1,"retained_budget_bytes":0]])
        let t = try call("task_create",["project_id":p["id"]!,"title":"Owned originals"])
        var files: [JSON] = []
        for i in 0..<count {
            let source = directory.appendingPathComponent("source-\(i).bin");try Data(repeating:UInt8(i + 1),count:64).write(to:source)
            files.append(try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path]))
        }
        return (p,try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!]),files)
    }
    func archive(_ f: (project: JSON,task: JSON,files: [JSON])) throws {
        let preview = try call("attachment_cleanup_preview",["project_id":f.project["id"]!,"task_id":f.task["id"]!])
        let task = try call("task_get",["project_id":f.project["id"]!,"task_id":f.task["id"]!])
        _ = try call("task_archive",["project_id":f.project["id"]!,"task_id":f.task["id"]!,"expected_revision":task["revision"]!,"action":"archive","cleanup":true,"cleanup_preview_id":preview["cleanup_preview_id"]!])
    }
    func jobs(_ f: (project: JSON,task: JSON,files: [JSON])) throws -> [ArchiveCleanupJob] {
        try router.dbQueue.read {db in try router.records(db,type:"cleanup_job",project:f.project["id"] as? String).map {try ArchiveCleanupJob(record:$0)}}
    }
    /// Runs body on another thread while the archive scan is paused; the writer must be free.
    func concurrently(_ body: @escaping () throws -> Void) -> () -> Void {
        { [unowned self] in
            let done = DispatchSemaphore(value:0);var failure: Error?
            DispatchQueue.global().async { do {try body()} catch {failure = error};done.signal() }
            XCTAssertEqual(done.wait(timeout:.now() + 20),.success,"A concurrent write must not wait for the archive scan")
            XCTAssertNil(failure)
            _ = self
        }
    }
    func writeTask(_ id: String,_ change: @escaping (inout JSON) -> Void) throws {
        try router.dbQueue.writeWithoutTransaction {db in try self.router.withValidatedDomainTransaction(db) {
            var t = try self.router.record(db,id,type:"task");change(&t);try self.router.save(db,self.router.revised(t),type:"task");return .commit
        }}
    }

    func testScanRunsOutsideWriterUnrelatedWriteCommitsAndPlanMatchesWriterScan() throws {
        let f = try fixture(),other = try call("task_create",["project_id":f.project["id"]!,"title":"Unrelated"])
        // The unchanged in-writer observation and the prepared snapshot give the same facts.
        let before = try router.dbQueue.read {db in try router.archiveRetentionFacts(db,task:router.record(db,f.task["id"] as! String,type:"task"),considerArchiving:true)}
        let prepared = try XCTUnwrap(router.prepareArchiveCleanupScan(method:"task_archive",params:["project_id":f.project["id"]!,"task_id":f.task["id"]!,"cleanup":true]))
        router.finishArchiveCleanupScan(prepared)
        let after = try router.dbQueue.read {db in try router.archiveRetentionFacts(db,task:router.record(db,f.task["id"] as! String,type:"task"),considerArchiving:true,currentGraph:prepared.rows)}
        XCTAssertEqual(before.map {"\($0)"},after.map {"\($0)"})
        XCTAssertEqual(before.count,2)
        var observed = 0
        router.archiveCleanupScanObserver = concurrently {
            observed += 1
            try self.writeTask(other["id"] as! String) {$0["title"] = "Written during scan"}
        }
        try archive(f)
        router.archiveCleanupScanObserver = nil
        XCTAssertEqual(observed,2,"Preview and archive each scan before the writer")
        XCTAssertEqual(try jobs(f).count,1);XCTAssertEqual(try jobs(f).first?.items.count,2)
        XCTAssertEqual(try call("task_get",["project_id":f.project["id"]!,"task_id":other["id"]!])["title"] as? String,"Written during scan")
        XCTAssertEqual(try call("task_get",["project_id":f.project["id"]!,"task_id":f.task["id"]!])["archived"] as? Bool,true)
    }

    func testChangedOriginalBetweenScanAndCommitRefusesAndRetryUsesCurrentHolds() throws {
        let f = try fixture()
        let preview = try call("attachment_cleanup_preview",["project_id":f.project["id"]!,"task_id":f.task["id"]!])
        let held = f.files[0]["id"] as! String
        router.archiveCleanupScanObserver = concurrently {
            try self.router.dbQueue.writeWithoutTransaction {db in try self.router.withValidatedDomainTransaction(db) {
                var a = try self.router.record(db,held,type:"attachment");a["keep_original"] = true;try self.router.save(db,self.router.revised(a),type:"attachment");return .commit
            }}
        }
        let task = try call("task_get",["project_id":f.project["id"]!,"task_id":f.task["id"]!])
        XCTAssertThrowsError(try call("task_archive",["project_id":f.project["id"]!,"task_id":f.task["id"]!,"expected_revision":task["revision"]!,"action":"archive","cleanup":true,"cleanup_preview_id":preview["cleanup_preview_id"]!])) {error in
            XCTAssertEqual((error as? CoreError)?.code,"CLEANUP_CONCURRENT_WRITE")
            XCTAssertEqual((error as? CoreError)?.details["retry"] as? Bool,true)
        }
        router.archiveCleanupScanObserver = nil
        XCTAssertEqual(try call("task_get",["project_id":f.project["id"]!,"task_id":f.task["id"]!])["archived"] as? Bool,false)
        XCTAssertTrue(try jobs(f).isEmpty)
        try archive(f)
        let job = try XCTUnwrap(try jobs(f).first)
        XCTAssertEqual(job.items.map(\.original.id.text),[f.files[1]["id"] as! String],"The retry observes Keep original")
    }

    func testNewReferenceToOriginalBetweenScanAndCommitRefuses() throws {
        let f = try fixture(count:1)
        let preview = try call("attachment_cleanup_preview",["project_id":f.project["id"]!,"task_id":f.task["id"]!])
        router.archiveCleanupScanObserver = concurrently {
            // A new live ticket whose payload names the original is a shared live reference.
            _ = try self.call("task_create",["project_id":f.project["id"]!,"title":f.files[0]["id"] as! String])
        }
        let task = try call("task_get",["project_id":f.project["id"]!,"task_id":f.task["id"]!])
        XCTAssertThrowsError(try call("task_archive",["project_id":f.project["id"]!,"task_id":f.task["id"]!,"expected_revision":task["revision"]!,"action":"archive","cleanup":true,"cleanup_preview_id":preview["cleanup_preview_id"]!])) {error in
            XCTAssertEqual((error as? CoreError)?.code,"CLEANUP_CONCURRENT_WRITE")
        }
        router.archiveCleanupScanObserver = nil
        XCTAssertTrue(try jobs(f).isEmpty)
    }

    /// Scaled timing: 50,000 synthetic records. Before = the unchanged in-writer
    /// scan; after = the archive's writer phase (end of the snapshot scan to reply).
    func testScaledArchiveWriteHoldBeforeAndAfter() throws {
        try QualificationSuite.requireEnabled()
        let f = try fixture(count:3),filler = try call("task_create",["project_id":f.project["id"]!,"title":"Filler owner"])
        let pid = f.project["id"] as! String,tid = filler["id"] as! String
        try router.dbQueue.writeWithoutTransaction {db in try self.router.withValidatedDomainTransaction(db) {
            let template: JSON = ["id":"00000000-0000-4000-8000-000000000000","project_id":pid,"task_id":tid,"revision":1,"body":String(repeating:"synthetic note text ",count:50),"refs":["a","b","c"]]
            try self.router.save(db,template,type:"message")
            try db.execute(sql:"""
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<49999)
                INSERT INTO records(id,project_id,type,revision,data)
                SELECT printf('00000000-0000-4000-8000-%012d',i),project_id,type,revision,json_set(data,'$.id',printf('00000000-0000-4000-8000-%012d',i))
                FROM n,records WHERE records.id='00000000-0000-4000-8000-000000000000'
                """)
            return .commit
        }}
        let task = try router.dbQueue.read {db in try router.record(db,f.task["id"] as! String,type:"task")}
        var start = ProcessInfo.processInfo.systemUptime
        try router.dbQueue.writeWithoutTransaction {db in try self.router.withValidatedDomainTransaction(db) {
            _ = try self.router.archiveRetentionFacts(db,task:task,considerArchiving:true);return .rollback
        }}
        let before = ProcessInfo.processInfo.systemUptime - start
        var scanEnd: TimeInterval = 0,scans = 0
        router.archiveCleanupScanObserver = {scanEnd = ProcessInfo.processInfo.systemUptime;scans += 1}
        start = ProcessInfo.processInfo.systemUptime
        let preview = try call("attachment_cleanup_preview",["project_id":pid,"task_id":f.task["id"]!])
        let previewTotal = ProcessInfo.processInfo.systemUptime - start,previewHold = ProcessInfo.processInfo.systemUptime - scanEnd
        XCTAssertEqual(scans,1,"A first preview's writer continuation prepares one snapshot scan")
        start = ProcessInfo.processInfo.systemUptime
        _ = try call("task_archive",["project_id":pid,"task_id":f.task["id"]!,"expected_revision":task["revision"]!,"action":"archive","cleanup":true,"cleanup_preview_id":preview["cleanup_preview_id"]!])
        let total = ProcessInfo.processInfo.systemUptime - start,after = ProcessInfo.processInfo.systemUptime - scanEnd
        router.archiveCleanupScanObserver = nil
        print("CL-344 scaled records=50001 write_hold_before=\(before)s archive_write_hold_after_upper_bound=\(after)s archive_command_total=\(total)s preview_write_hold_after_upper_bound=\(previewHold)s preview_command_total=\(previewTotal)s")
        XCTAssertLessThan(previewHold,before,"The preview writer phase must not include the reference scan")
        XCTAssertEqual(try jobs(f).first?.items.count,3)
        XCTAssertLessThan(after,before,"The archive writer phase must not include the reference scan")
    }

    /// CL-344 items 1-2 (qualification): 50,000+ records and one Done ticket with 64
    /// managed attachments. 128 notes on that ticket name the originals (id and object
    /// path), so all 64 go through archiveRetentionFacts -> completeArchiveCleanupHolds
    /// inside the writer, and the fence id and target sets grow with the 64 originals
    /// and the 128 notes (the printed fence_ids/fence_targets give the sizes).
    /// A test-only SQLite profile trace on the writer connection times the archive's
    /// write transaction (no production probe). A writer and three readers loop on
    /// other threads for the whole command, including the snapshot scan.
    func testQualificationSixtyFourAttachmentArchiveHoldConcurrentWriterAndReads() throws {
        try QualificationSuite.requireEnabled()
        let clock = {ProcessInfo.processInfo.systemUptime},setupStart = clock()
        let f = try fixture(count:64),pid = f.project["id"] as! String,tid = f.task["id"] as! String
        let filler = try call("task_create",["project_id":pid,"title":"Filler owner"]),other = try call("task_create",["project_id":pid,"title":"Concurrent writer target"])
        let fid = filler["id"] as! String,oid = other["id"] as! String
        try router.dbQueue.writeWithoutTransaction {db in try self.router.withValidatedDomainTransaction(db) {
            let template: JSON = ["id":"00000000-0000-4000-8000-000000000000","project_id":pid,"task_id":fid,"revision":1,"body":String(repeating:"synthetic note text ",count:50),"refs":["a","b","c"]]
            try self.router.save(db,template,type:"message")
            try db.execute(sql:"""
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<49999)
                INSERT INTO records(id,project_id,type,revision,data)
                SELECT printf('00000000-0000-4000-8000-%012d',i),project_id,type,revision,json_set(data,'$.id',printf('00000000-0000-4000-8000-%012d',i))
                FROM n,records WHERE records.id='00000000-0000-4000-8000-000000000000'
                """)
            for (i,file) in f.files.enumerated() {
                for (j,token) in [file["id"] as! String,file["path"] as! String].enumerated() {
                    try self.router.save(db,["id":String(format:"00000000-0000-4000-9000-%012d",i * 2 + j),"project_id":pid,"task_id":tid,"revision":1,"body":"Evidence note","refs":[token]],type:"message")
                }
            }
            return .commit
        }}
        // Fixture write: the ticket is Done (task_complete needs submitted work evidence).
        let doneStatus = try XCTUnwrap(try router.dbQueue.read {db in try self.router.records(db,type:"status",project:pid).first {$0["category"] as? String == "done"}})
        try writeTask(tid) {$0["status_id"] = doneStatus["id"];$0["status_category"] = "done"}
        XCTAssertEqual(try call("task_get",["project_id":pid,"task_id":tid])["status_category"] as? String,"done")
        let recordCount = try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM records") ?? 0}
        XCTAssertGreaterThanOrEqual(recordCount,50_000)
        let setup = clock() - setupStart

        // The concurrent writer: task_edit commands on another ticket.
        var otherRevision = other["revision"]!,editNumber = 0
        func edit() throws {
            editNumber += 1
            let r = try call("task_edit",["project_id":pid,"task_id":oid,"expected_revision":otherRevision,"patch":["title":"Concurrent edit \(editNumber)"]])
            otherRevision = r["revision"]!
        }
        let baseline = try (0..<10).map {_ -> TimeInterval in let s = clock();try edit();return clock() - s}
        var s = clock()
        let preview = try call("attachment_cleanup_preview",["project_id":pid,"task_id":tid])
        let previewTotal = clock() - s

        // Phase decomposition of the same writer functions on a prepared scan (rolled back).
        s = clock()
        let prepared = try XCTUnwrap(router.prepareArchiveCleanupScan(method:"task_archive",params:["project_id":pid,"task_id":tid,"cleanup":true]))
        var phases: [String:TimeInterval] = ["scan":clock() - s],factCount = 0
        let fenceSizes = (prepared.fenceIDs.count,prepared.targets.count,prepared.rows.count)
        try router.dbQueue.writeWithoutTransaction {db in try self.router.withValidatedDomainTransaction(db) {
            let task = try self.router.record(db,tid,type:"task")
            let attachments = try self.router.scopedTaskRows(db,type:"attachment",task:task).filter {!bool($0,"unlinked")}
            var p = clock();try prepared.validate(db,tokens:self.router.archiveCleanupTokens(attachments));phases["fence"] = clock() - p
            p = clock();let index = try ArchiveCleanupReferenceIndex(prepared.rows);phases["index"] = clock() - p
            p = clock()
            for a in attachments {_ = try self.router.completeArchiveCleanupHolds(db,attachment:a,task:task,considerArchiving:true,currentGraph:prepared.rows,currentIndex:index)}
            phases["holds_64"] = clock() - p
            p = clock();factCount = try self.router.archiveRetentionFacts(db,task:task,considerArchiving:true,currentGraph:prepared.rows).count;phases["facts"] = clock() - p
            return .rollback
        }}
        router.finishArchiveCleanupScan(prepared)
        XCTAssertEqual(factCount,64,"Every attachment goes through completeArchiveCleanupHolds")

        // Test-only probe: profile every statement on the writer connection.
        final class Trace {let lock = NSLock();var events: [(at: TimeInterval,sql: String,duration: TimeInterval)] = []}
        let trace = Trace()
        try router.dbQueue.writeWithoutTransaction {db in db.trace(options:.profile) {event in
            guard case let .profile(statement,duration) = event else {return}
            let at = ProcessInfo.processInfo.systemUptime,sql = statement.sql
            trace.lock.lock();trace.events.append((at,sql,duration));trace.lock.unlock()
        }}
        final class Box {
            let lock = NSLock();var stop = false;var writes: [(start: TimeInterval,end: TimeInterval)] = [];var reads: [String:[TimeInterval]] = [:];var failures: [String] = []
            var stopped: Bool {lock.lock();defer {lock.unlock()};return stop}
            func record(_ body: () -> Void) {lock.lock();body();lock.unlock()}
        }
        let box = Box(),group = DispatchGroup(),storePath = router.root.appendingPathComponent("checklist.sqlite").path
        var scanEnd: TimeInterval = 0
        router.archiveCleanupScanObserver = {scanEnd = clock()}
        group.enter()
        DispatchQueue.global().async {
            defer {group.leave()}
            while !box.stopped {
                let start = clock()
                do {try edit();let end = clock();box.record {box.writes.append((start,end))}} catch {box.record {box.failures.append("task_edit: \(error)")}}
                Thread.sleep(forTimeInterval:0.02)
            }
        }
        for kind in ["service_info","task_get","new_connection"] {
            group.enter()
            DispatchQueue.global().async {
                defer {group.leave()}
                while !box.stopped {
                    let start = clock()
                    do {
                        switch kind {
                        case "service_info": _ = try self.router.handle(method:"service_info",params:[:],caller:self.owner)
                        case "task_get": _ = try self.call("task_get",["project_id":pid,"task_id":tid])
                        default:
                            var configuration = Configuration();configuration.readonly = true;configuration.busyMode = .timeout(5)
                            configuration.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
                            let connection = try DatabaseQueue(path:storePath,configuration:configuration)
                            _ = try connection.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM records WHERE type='task'")}
                            try connection.close()
                        }
                        let elapsed = clock() - start
                        box.record {box.reads[kind,default:[]].append(elapsed)}
                    } catch {box.record {box.failures.append("\(kind): \(error)")}}
                    Thread.sleep(forTimeInterval:0.01)
                }
            }
        }
        Thread.sleep(forTimeInterval:0.2)
        let current = try call("task_get",["project_id":pid,"task_id":tid])
        let archiveStart = clock(),archiveEnd: TimeInterval
        do {
            _ = try call("task_archive",["project_id":pid,"task_id":tid,"expected_revision":current["revision"]!,"action":"archive","cleanup":true,"cleanup_preview_id":preview["cleanup_preview_id"]!])
            archiveEnd = clock()
        } catch {box.record {box.stop = true};_ = group.wait(timeout:.now() + 60);throw error}
        box.record {box.stop = true}
        XCTAssertEqual(group.wait(timeout:.now() + 60),.success)
        router.archiveCleanupScanObserver = nil
        try router.dbQueue.writeWithoutTransaction {$0.trace(options:.profile,nil)}

        // The archive's write transaction: the one that runs the fence queries.
        var transaction: ArraySlice<(at: TimeInterval,sql: String,duration: TimeInterval)>?,open: Int?
        let events = trace.events
        for (i,e) in events.enumerated() {
            let sql = e.sql.uppercased()
            if sql.hasPrefix("BEGIN") {open = i}
            else if let o = open,sql.hasPrefix("COMMIT") || sql.hasPrefix("END") || sql.hasPrefix("ROLLBACK") && !sql.contains(" TO ") {
                let slice = events[o...i];open = nil
                if slice.contains(where: {$0.sql.contains("archive_cleanup_scan_changes WHERE id IS NULL")}) {transaction = slice}
            }
        }
        let tx = try XCTUnwrap(transaction,"The archive's write transaction ran the fence")
        let txBegin = tx.first!.at - tx.first!.duration,txEnd = tx.last!.at
        let fence = tx.filter {$0.sql.contains("temp.archive_cleanup_scan_changes") || $0.sql.contains("PRAGMA data_version")}
        let fenceStart = fence.first!.at - fence.first!.duration,fenceEnd = fence.last!.at
        let txHold = txEnd - txBegin,writerPhase = archiveEnd - scanEnd,total = archiveEnd - archiveStart,scan = scanEnd - archiveStart

        let writes = box.writes,reads = box.reads,failures = box.failures
        let duringScan = writes.filter {$0.start >= archiveStart && $0.end <= scanEnd}
        let overlapping = writes.filter {$0.end > scanEnd && $0.start < archiveEnd}
        let maxWait = overlapping.map {$0.end - $0.start}.max() ?? 0,baselineMax = baseline.max() ?? 0
        // A write that arrives while the archive holds the gate and writer waits for the
        // rest of that phase, then runs its own command (baseline). 0.25 s covers thread
        // wakeup, the 20 ms loop pause and the journal trigger on its own payload.
        let margin = baselineMax + 0.25
        func stats(_ v: [TimeInterval]) -> String {
            let sorted = v.sorted();guard !sorted.isEmpty else {return "n=0"}
            return String(format:"n=%d p95=%.4fs max=%.4fs",sorted.count,sorted[min(sorted.count - 1,Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)],sorted.last!)
        }
        let job = try XCTUnwrap(try jobs(f).first)
        print(String(format:"CL-344 qualification64 records=%d attachments=64 job_items=%d fence_ids=%d fence_targets=%d scanned_rows=%d setup=%.3fs preview_total=%.3fs",recordCount,job.items.count,fenceSizes.0,fenceSizes.1,fenceSizes.2,setup,previewTotal))
        print(String(format:"CL-344 qualification64 decomposition scan=%.3fs fence=%.4fs index=%.4fs holds_64=%.4fs facts=%.4fs",phases["scan"]!,phases["fence"]!,phases["index"]!,phases["holds_64"]!,phases["facts"]!))
        print(String(format:"CL-344 qualification64 archive total=%.3fs scan=%.3fs writer_phase_upper_bound=%.4fs write_tx_hold=%.4fs tx_statements=%d tx_before_fence=%.4fs tx_fence=%.4fs tx_after_fence=%.4fs commit=%.4fs",total,scan,writerPhase,txHold,tx.count,fenceStart - txBegin,fenceEnd - fenceStart,txEnd - fenceEnd,tx.last!.duration))
        print(String(format:"CL-344 qualification64 writer baseline_max=%.4fs margin=%.4fs writes=%d during_scan=%d overlapping_writer_phase=%d max_wait_overlapping=%.4fs max_any=%.4fs",baselineMax,margin,writes.count,duringScan.count,overlapping.count,maxWait,writes.map {$0.end - $0.start}.max() ?? 0))
        print("CL-344 qualification64 reads service_info \(stats(reads["service_info"] ?? [])); task_get \(stats(reads["task_get"] ?? [])); new_connection \(stats(reads["new_connection"] ?? [])); failures=\(failures.count)")

        XCTAssertEqual(try call("task_get",["project_id":pid,"task_id":tid])["archived"] as? Bool,true)
        XCTAssertEqual(job.items.count,64,"All 64 originals are queued")
        XCTAssertLessThanOrEqual(txHold,5,"The archive's write transaction holds at most 5 s")
        XCTAssertLessThanOrEqual(writerPhase,5,"The archive's gate and writer phase is at most 5 s")
        XCTAssertGreaterThan(duringScan.count,0,"Writes from another caller commit while the snapshot scan runs")
        XCTAssertLessThanOrEqual(maxWait,writerPhase + margin,"A concurrent write waits at most the archive's write hold plus the margin")
        XCTAssertTrue(failures.isEmpty,"\(failures.prefix(5))")
        for kind in ["service_info","task_get","new_connection"] {XCTAssertGreaterThan(reads[kind]?.count ?? 0,0,kind)}
    }

    // MARK: CL-345: the cleanup executor scans a read snapshot before the writer.

    func makeDue(_ f: (project: JSON,task: JSON,files: [JSON])) throws {
        try router.dbQueue.writeWithoutTransaction {db in try self.router.withValidatedDomainTransaction(db) {
            for listed in try self.router.records(db,type:"cleanup_job",project:f.project["id"] as? String) {
                var j = try self.router.record(db,listed["id"] as! String,type:"cleanup_job")
                j["enqueued_at_ms"] = Int64(1);j["not_before_ms"] = Int64(2);j["revision"] = try self.router.nextCleanupJobRevision(j)
                try self.router.save(db,j,type:"cleanup_job")
            }
            return .commit
        }}
    }
    func exists(_ file: JSON) -> Bool { FileManager.default.fileExists(atPath:file["path"] as! String) }
    func deleteIntents() throws -> Int {
        try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM records WHERE type='storage_job' AND json_extract(data,'$.kind')='archive_cleanup_delete'") ?? 0}
    }
    /// The fence miss left the item retryable: no failure, no hold, job not ended.
    func assertRetryable(_ f: (project: JSON,task: JSON,files: [JSON]),file: StaticString = #filePath,line: UInt = #line) throws {
        let job = try XCTUnwrap(try jobs(f).first,file:file,line:line),item = try XCTUnwrap(job.items.first,file:file,line:line)
        XCTAssertTrue(exists(f.files[0]),"No deletion on a fence miss",file:file,line:line)
        XCTAssertEqual(try deleteIntents(),0,"No deletion intent on a fence miss",file:file,line:line)
        XCTAssertNil(item.failure,file:file,line:line);XCTAssertEqual(item.sameFailureCount,0,file:file,line:line);XCTAssertFalse(item.terminal,file:file,line:line)
        XCTAssertFalse([.canceled,.completed,.suspended].contains(job.state),file:file,line:line)
    }

    func testExecutorScanRunsBeforeTheWriterAndUnrelatedWriteCommits() throws {
        let f = try fixture(count:1),other = try call("task_create",["project_id":f.project["id"]!,"title":"Unrelated"])
        try archive(f);try makeDue(f)
        // A command's maintenance tail prepares no scan: the due item waits for the service turn.
        _ = try call("task_create",["project_id":f.project["id"]!,"title":"Command tail"])
        XCTAssertTrue(exists(f.files[0]));XCTAssertEqual(try deleteIntents(),0)
        var observed = 0
        router.archiveCleanupScanObserver = concurrently {
            observed += 1
            try self.writeTask(other["id"] as! String) {$0["title"] = "Written during executor scan"}
        }
        try router.runStorageMaintenance()
        router.archiveCleanupScanObserver = nil
        XCTAssertEqual(observed,1,"The service turn scans once, before the gate and the writer")
        XCTAssertFalse(exists(f.files[0]),"An unrelated write does not miss the fence")
        XCTAssertEqual(try jobs(f).first?.items.first?.terminal,true)
        XCTAssertEqual(try call("task_get",["project_id":f.project["id"]!,"task_id":other["id"]!])["title"] as? String,"Written during executor scan")
    }

    func testExecutorFenceMissFromAnotherConnectionRetriesWithoutDeletion() throws {
        let f = try fixture(count:1);try archive(f);try makeDue(f)
        let path = router.root.appendingPathComponent("checklist.sqlite").path
        router.archiveCleanupScanObserver = concurrently {
            // Another SQLite connection commits while the scan hook runs: no write transaction is open.
            var configuration = Configuration();configuration.busyMode = .timeout(5)
            configuration.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
            let other = try DatabaseQueue(path:path,configuration:configuration)
            try other.write {try $0.execute(sql:"INSERT INTO metadata(key,value) VALUES('cl345-other-connection','1')")}
            try other.close()
        }
        try router.runStorageMaintenance()
        router.archiveCleanupScanObserver = nil
        try assertRetryable(f)
        try router.runStorageMaintenance()
        XCTAssertFalse(exists(f.files[0]),"The next turn rescans and deletes")
        XCTAssertEqual(try jobs(f).first?.items.first?.terminal,true)
    }

    func testExecutorRelevantChangeBetweenScanAndCommitRetriesWithoutDeletion() throws {
        let f = try fixture(count:1);try archive(f);try makeDue(f)
        router.archiveCleanupScanObserver = concurrently {
            try self.writeTask(f.task["id"] as! String) {$0["title"] = "Changed during executor scan"}
        }
        try router.runStorageMaintenance()
        router.archiveCleanupScanObserver = nil
        try assertRetryable(f)
        // A new payload naming the original during the scan also misses the fence.
        router.archiveCleanupScanObserver = concurrently {
            _ = try self.call("task_create",["project_id":f.project["id"]!,"title":f.files[0]["id"] as! String])
        }
        try router.runStorageMaintenance()
        router.archiveCleanupScanObserver = nil
        try assertRetryable(f)
        // The retry decides exactly as the unchanged in-writer complete scan does now.
        let expected = try router.dbQueue.read {db in
            try self.router.completeArchiveCleanupHolds(db,attachment:self.router.record(db,f.files[0]["id"] as! String,type:"attachment"),task:self.router.record(db,f.task["id"] as! String,type:"task"))
        }
        try router.runStorageMaintenance()
        XCTAssertEqual(exists(f.files[0]),!expected.isEmpty,"Holds \(expected)")
        if !expected.isEmpty {XCTAssertEqual(Set(try XCTUnwrap(try jobs(f).first?.items.first).holds),expected)}
    }

    /// Scaled timing: 50,000 synthetic records. Before = one unchanged in-writer
    /// executor admission (full graph, holds and facts); after = the service
    /// turn's gate and writer phase (end of the snapshot scan to return).
    func testScaledExecutorWriteHoldBeforeAndAfter() throws {
        try QualificationSuite.requireEnabled()
        let f = try fixture(count:1),filler = try call("task_create",["project_id":f.project["id"]!,"title":"Filler owner"])
        let pid = f.project["id"] as! String,tid = filler["id"] as! String
        try router.dbQueue.writeWithoutTransaction {db in try self.router.withValidatedDomainTransaction(db) {
            let template: JSON = ["id":"00000000-0000-4000-8000-000000000000","project_id":pid,"task_id":tid,"revision":1,"body":String(repeating:"synthetic note text ",count:50),"refs":["a","b","c"]]
            try self.router.save(db,template,type:"message")
            try db.execute(sql:"""
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<49999)
                INSERT INTO records(id,project_id,type,revision,data)
                SELECT printf('00000000-0000-4000-8000-%012d',i),project_id,type,revision,json_set(data,'$.id',printf('00000000-0000-4000-8000-%012d',i))
                FROM n,records WHERE records.id='00000000-0000-4000-8000-000000000000'
                """)
            return .commit
        }}
        try archive(f);try makeDue(f)
        var start = ProcessInfo.processInfo.systemUptime
        try router.dbQueue.writeWithoutTransaction {db in try self.router.withValidatedDomainTransaction(db) {
            let task = try self.router.record(db,f.task["id"] as! String,type:"task"),a = try self.router.record(db,f.files[0]["id"] as! String,type:"attachment")
            let graph = try self.router.archiveCleanupReferenceRows(db)
            _ = try self.router.completeArchiveCleanupHolds(db,attachment:a,task:task,currentGraph:graph)
            _ = try self.router.archiveRetentionFacts(db,task:task,currentGraph:graph);return .rollback
        }}
        let before = ProcessInfo.processInfo.systemUptime - start
        var scanEnd: TimeInterval = 0
        router.archiveCleanupScanObserver = {scanEnd = ProcessInfo.processInfo.systemUptime}
        start = ProcessInfo.processInfo.systemUptime
        try router.runStorageMaintenance()
        let end = ProcessInfo.processInfo.systemUptime,after = end - scanEnd
        router.archiveCleanupScanObserver = nil
        print("CL-345 scaled records=50001 per_item_write_hold_before=\(before)s (one admission; the old final check scanned again) per_item_write_hold_after_upper_bound=\(after)s service_turn_total=\(end - start)s")
        XCTAssertGreaterThan(scanEnd,0)
        XCTAssertFalse(exists(f.files[0]))
        XCTAssertLessThan(after,before,"The executor's writer phase must not include the reference scan")
    }
}
