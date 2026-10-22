import XCTest
import GRDB
@testable import ChecklistCore

/// Prepared only. Requires the exact frozen CL19 validated-transaction producer,
/// explicit cleanup_job family and project-authorized dispatch/catalog fragments.
/// Internal preview setup is synthetic, not a native preview or archive receipt claim.
final class ArchiveCleanupJobsIntegrationTests: XCTestCase {
    var directory: URL!
    var router: CommandRouter!
    let owner = Caller(role:"owner",installation:"cleanup-job-fixture",projectIDs:[])
    override func setUpWithError() throws {
        let base = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("ChecklistCoreTests",isDirectory:true)
        directory = base.appendingPathComponent(UUID().uuidString)
        router = try CommandRouter(root:directory)
    }
    override func tearDownWithError() throws {router = nil;try? FileManager.default.removeItem(at:directory)}
    func call(_ method: String,_ p: JSON,command: String? = nil) throws -> JSON {
        var params = p;if !CommandRouter.readMethods.contains(method) {params["command_id"] = command ?? UUID().uuidString}
        let output = try router.handle(method:method,params:params,caller:owner)
        return try XCTUnwrap(output["data"] as? JSON)
    }
    func transaction<T>(_ body: (Database) throws -> T) throws -> T {
        var value: T?
        try router.dbQueue.writeWithoutTransaction {db in
            try router.withValidatedDomainTransaction(db) {value = try body(db);return .commit}
        }
        return try XCTUnwrap(value)
    }
    func fixture() throws -> (project: JSON,task: JSON,attachment: JSON,plan: ArchiveRetentionPlan,previewID: String) {
        let p = try call("project_create",["name":"Cleanup unit","key_prefix":"CJ"])
        let t = try call("task_create",["project_id":p["id"]!,"title":"Owned fixture"])
        let file = directory.appendingPathComponent("original.txt");try Data("owned fixture".utf8).write(to:file)
        let a = try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":file.path])
        let fact = try ArchiveAttachmentFact(id:a["id"] as! String,logicalOriginalBytes:ArchiveCleanupJob.integer(a["size"]))
        let config = try ArchiveRetentionConfiguration(preset:.cleanLargeManagedOnArchive,largeOriginalBytes:1,retainedBudgetBytes:0)
        let plan = try ArchiveRetentionPlanner.make(configuration:config,facts:[fact]),previewID = UUID().uuidString
        let basis: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"task_revision":t["revision"]!,"settings_revision":p["settings_revision"]!,"preview_id":previewID,"originals":[["attachment_id":a["id"]!,"sha256":a["sha256"]!,"logical_bytes":a["size"]!,"attachment_revision":a["revision"]!]]]
        try transaction {db in try router.save(db,["id":UUID().uuidString,"project_id":p["id"]!,"task_id":t["id"]!,"record_type":"cleanup_preview","revision":1,"cleanup_preview_id":previewID,"task_revision":t["revision"]!,"settings_revision":p["settings_revision"]!,"cleanup_job_plan_sha256":ChecklistCore.hash(Data(try jsonString(basis).utf8))],type:"cleanup_preview")}
        return (p,t,a,plan,previewID)
    }
    func enqueue(_ f: (project: JSON,task: JSON,attachment: JSON,plan: ArchiveRetentionPlan,previewID: String)) throws -> JSON {
        try transaction {db in try XCTUnwrap(router.enqueueArchiveCleanupJob(db,task:f.task,settingsRevision:ArchiveCleanupJob.integer(f.project["settings_revision"]),previewID:f.previewID,plan:f.plan,nowMS:router.archiveCleanupNowMS(),notBeforeMS:router.archiveCleanupNowMS() + CommandRouter.archiveCleanupGraceMS,caller:owner))}
    }
    func testRealOwnerCancelReceiptReplayIsStableAndNeverTouchesOriginal() throws {
        let f = try fixture(),job = try enqueue(f),pid = f.project["id"] as! String,jid = job["id"] as! String
        let before = try Data(contentsOf:URL(fileURLWithPath:f.attachment["path"] as! String))
        let currentProject = try router.dbQueue.read {try router.record($0,pid,type:"project")}
        _ = try call("project_archive",["project_id":pid,"expected_revision":currentProject["revision"]!,"archived":true])
        // Archived project still permits protective cancellation; retry would remain a write.
        let command = UUID().uuidString,input: JSON = ["project_id":pid,"cleanup_job_id":jid,"expected_revision":1]
        let first = try call("cleanup_job_cancel",input,command:command)
        let replay = try call("cleanup_job_cancel",input,command:command)
        XCTAssertEqual(try ArchiveCleanupJob.integer(first["revision"]),Int64(2));XCTAssertEqual(replay["revision"] as? Int,2);XCTAssertEqual(replay["state"] as? String,"canceled")
        let stored = try call("cleanup_job_get",["project_id":pid,"cleanup_job_id":jid])
        XCTAssertEqual(try ArchiveCleanupJob.integer(stored["revision"]),Int64(2));XCTAssertEqual(stored["physical_reclamation"] as? String,"unmeasured")
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:f.attachment["path"] as! String)),before)
        var changed = input;changed["expected_revision"] = 2
        XCTAssertThrowsError(try call("cleanup_job_cancel",changed,command:command)) {XCTAssertEqual(($0 as? CoreError)?.code,"IDEMPOTENCY_CONFLICT")}
    }
    func testWorkerWrongProjectAndNonIntegralRevisionCannotCancelJob() throws {
        let f = try fixture(),job = try enqueue(f),pid = f.project["id"] as! String,jid = job["id"] as! String
        let worker = Caller(role:"worker",installation:"fixture-worker",projectIDs:[pid])
        XCTAssertTrue(router.toolCatalog(worker).contains {$0["name"] as? String == "cleanup_job_cancel"})
        XCTAssertThrowsError(try transaction {db in try router.archiveCleanupJobCommand(db,["project_id":pid,"cleanup_job_id":jid,"expected_revision":1],worker,"cleanup_job_cancel")}) {XCTAssertEqual(($0 as? CoreError)?.code,"ROOT_MISMATCH")}
        let other = try call("project_create",["name":"Other","key_prefix":"OTHER"])
        XCTAssertThrowsError(try call("cleanup_job_get",["project_id":other["id"]!,"cleanup_job_id":jid]))
        for bad in [true,1.5] as [Any] {XCTAssertThrowsError(try call("cleanup_job_cancel",["project_id":pid,"cleanup_job_id":jid,"expected_revision":bad]))}
        XCTAssertEqual(try call("cleanup_job_get",["project_id":pid,"cleanup_job_id":jid])["state"] as? String,"queued")
    }
    func testSettingsBoundPreviewAndActualTransactionRollbackPreventOrphanJob() throws {
        let f = try fixture()
        XCTAssertThrowsError(try transaction {db in try router.enqueueArchiveCleanupJob(db,task:f.task,settingsRevision:999,previewID:f.previewID,plan:f.plan,nowMS:router.archiveCleanupNowMS(),notBeforeMS:router.archiveCleanupNowMS() + CommandRouter.archiveCleanupGraceMS,caller:owner)})
        XCTAssertThrowsError(try transaction {db in try router.enqueueArchiveCleanupJob(db,task:f.task,settingsRevision:ArchiveCleanupJob.integer(f.project["settings_revision"]),previewID:"unrecorded",plan:f.plan,nowMS:router.archiveCleanupNowMS(),notBeforeMS:router.archiveCleanupNowMS() + CommandRouter.archiveCleanupGraceMS,caller:owner)})
        try router.dbQueue.writeWithoutTransaction {db in
            try router.withValidatedDomainTransaction(db) {
                _ = try router.enqueueArchiveCleanupJob(db,task:f.task,settingsRevision:ArchiveCleanupJob.integer(f.project["settings_revision"]),previewID:f.previewID,plan:f.plan,nowMS:router.archiveCleanupNowMS(),notBeforeMS:router.archiveCleanupNowMS() + CommandRouter.archiveCleanupGraceMS,caller:owner)
                return .rollback
            }
        }
        XCTAssertEqual(try router.dbQueue.read {try router.records($0,type:"cleanup_job",project:f.project["id"] as? String).count},0)
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.attachment["path"] as! String))
    }
    func testRealReaderLeaseRemainsHeldAndIncompleteGraphNeverBecomesDeletionReady() throws {
        let f = try fixture(),job = try enqueue(f),pid = f.project["id"] as! String,jid = job["id"] as! String,aid = f.attachment["id"] as! String
        try transaction {db in var task = try router.record(db,f.task["id"] as! String,type:"task");task["archived"] = true;try router.save(db,router.revised(task),type:"task")}
        let read = try call("attachment_read",["project_id":pid,"attachment_id":aid,"representation":"original"])
        XCTAssertNotNil(read["read_hold_id"])
        let observed = try transaction {db in try router.observeArchiveCleanupHolds(db,projectID:pid,jobID:jid,attachmentIDs:[aid],nowMS:try ArchiveCleanupJob.integer(job["not_before_ms"]),caller:owner)}
        XCTAssertEqual(observed["state"] as? String,"held")
        let item = try XCTUnwrap((observed["items"] as? [JSON])?.first)
        XCTAssertTrue((item["holds"] as? [String] ?? []).contains("activeReader"));XCTAssertTrue((item["holds"] as? [String] ?? []).contains("referenceGraphUnavailable"))
        XCTAssertEqual(try ArchiveCleanupJob.integer(observed["removed_logical_original_bytes"]),Int64(0))
        XCTAssertEqual(observed["deletion_outcome_recorded"] as? Bool,false)
        XCTAssertEqual(observed["original_restoration"] as? String,"not_evaluated")
        XCTAssertNil(observed["all_originals_still_undoable"])
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.attachment["path"] as! String))
    }

}
