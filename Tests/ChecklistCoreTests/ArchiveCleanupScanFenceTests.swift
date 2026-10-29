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
}
