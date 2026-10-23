import XCTest
import GRDB
@testable import ChecklistCore

final class TicketLifecycleCleanupTests: XCTestCase {
    var directory: URL!
    var router: CommandRouter!
    let owner = Caller(role:"owner",installation:"lifecycle-fixture",projectIDs:[])
    let defaults: JSON = ["done_evidence_enabled":true,"closed_purge_enabled":true,"closed_days":15]
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("checklist-lifecycle-" + uuid())
        router = try CommandRouter(root:directory.appendingPathComponent("store"))
    }
    override func tearDownWithError() throws {try router?.closeStore();router = nil;try? FileManager.default.removeItem(at:directory)}
    func call(_ method: String,_ p: JSON) throws -> JSON {
        var p = p;if !CommandRouter.readMethods.contains(method) {p["command_id"] = uuid()}
        return try router.handle(method:method,params:p,caller:owner)["data"] as! JSON
    }
    func write(_ body: (Database) throws -> Void) throws {
        try ArchiveStorageGate.withExclusive(root:router.root) {_ in try router.dbQueue.writeWithoutTransaction {db in try router.withValidatedDomainTransaction(db) {try body(db);return .commit}}}
    }
    func fixture(category: String = "done",age: Int = 0) throws -> (JSON,JSON,JSON) {
        let workspace = directory.appendingPathComponent("workspace-" + uuid());try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let p = try call("project_create",["name":"Synthetic lifecycle","key_prefix":"LC","root_path":workspace.path])
        let t = try call("task_create",["project_id":p["id"]!,"title":"Synthetic closed work"])
        let source = workspace.appendingPathComponent("evidence.txt");try Data("owned evidence".utf8).write(to:source)
        let a = try call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path,"mode":"managed_copy"])
        try mark(p,t,category:category,age:age)
        return (p,try read(t),a)
    }
    func read(_ task: JSON) throws -> JSON {try router.dbQueue.read {try router.record($0,task["id"] as! String,type:"task")}}
    func mark(_ p: JSON,_ t: JSON,category: String,age: Int = 0) throws {
        try write {db in
            var value = try self.router.record(db,t["id"] as! String,type:"task")
            value["status_id"] = try self.router.status(db,p["id"] as! String,category)["id"]!
            value["updated_at"] = ISO8601DateFormatter().string(from:Date().addingTimeInterval(-Double(age)*86400));value["revision"] = int(value,"revision")+1
            try self.router.save(db,value,type:"task")
            try db.execute(sql:"UPDATE events SET occurred_at=? WHERE entity_id=?",arguments:[value["updated_at"] as! String,t["id"] as! String])
        }
    }
    func selection(_ p: JSON,settings: JSON? = nil,at time: Date = Date()) throws -> JSON {
        try router.ticketCleanupMaintenanceLock.withLock {
            try router.readers!.read {db in
                var project = try router.record(db,p["id"] as! String,type:"project")
                if let settings {project["ticket_cleanup"] = settings}
                return try router.ticketCleanupSelection(db,project:project,at:time).selection
            }
        }
    }
    func configure(_ p: JSON,settings: JSON? = nil) throws -> JSON {
        let current = try router.dbQueue.read {try router.record($0,p["id"] as! String,type:"project")}
        return try call("project_settings_save",["project_id":p["id"]!,"expected_revision":current["revision"]!,"ticket_cleanup":settings ?? defaults])
    }
    func pass(at time: Date = Date()) throws {try router.runTicketLifecycleCleanup(at:time)}
    func finish() throws {
        for _ in 0..<40 {
            let pending = try router.dbQueue.read {try router.records($0,type:"storage_job").contains {$0["kind"] as? String == "ticket_object_delete" && $0["state"] as? String == "pending"}}
            if !pending {return};router.ticketCleanupYieldAt = nil;try router.runStorageMaintenance()
        }
        XCTFail("Fixture deletion did not settle")
    }
    func receipts(_ p: JSON) throws -> [JSON] {try call("ticket_cleanup_receipts",["project_id":p["id"]!])["receipts"] as! [JSON]}
    func testDefaultsStartAutomaticallyWithoutPreviewOrActivationIncludingRestart() throws {
        let (p,t,a) = try fixture(age:20)
        let settings = router.ticketCleanupSettings(p)
        XCTAssertEqual(settings["closed_days"] as? Int,15)
        XCTAssertEqual(settings["done_evidence_enabled"] as? Bool,true)
        XCTAssertEqual(settings["closed_purge_enabled"] as? Bool,true)
        XCTAssertNil(p["ticket_cleanup_activated_at"])
        XCTAssertFalse(CommandRouter.readMethods.contains("ticket_cleanup_preview"))
        let root = router.root;try router.closeStore();router = try CommandRouter(root:root)
        // Startup exposes an immediate service maintenance deadline, without doing
        // a first-install graph traversal before the service can accept requests.
        XCTAssertLessThanOrEqual(try XCTUnwrap(router.nextArchiveCleanupDeadline()).timeIntervalSinceNow,0.2)
        try router.runStorageMaintenance();try finish()
        XCTAssertTrue(bool(try read(t),"purged"));XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String))
        XCTAssertFalse(try receipts(p).isEmpty)
    }
    func testDoneDeletesOwnedBytesKeepsTicketNotesAndImmutableMetadataAndReportsActualBytes() throws {
        let (p,t,a) = try fixture()
        let note = try call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"Retained history"])
        _ = try configure(p);try pass();try finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String));XCTAssertFalse(bool(try read(t),"purged"))
        let saved = try router.dbQueue.read {try router.record($0,a["id"] as! String,type:"attachment")}
        for key in ["name","sha256"] {XCTAssertEqual(saved[key] as? String,a[key] as? String)}
        XCTAssertEqual((saved["size"] as? NSNumber)?.int64Value,(a["size"] as? NSNumber)?.int64Value)
        XCTAssertEqual(saved["availability"] as? String,"original_cleaned")
        XCTAssertNoThrow(try router.dbQueue.read {try router.record($0,note["id"] as! String,type:"message")})
        let receipt = try XCTUnwrap(receipts(p).first),summary = receipt["summary"] as! JSON
        XCTAssertEqual((summary["removed_bytes"] as? NSNumber)?.int64Value,14);XCTAssertEqual(receipt["bytes_state"] as? String,"completed")
        XCTAssertEqual(summary["physical_reclamation"] as? String,"unmeasured")
        XCTAssertNoThrow(try call("backup_create",["path":directory.appendingPathComponent("backup").path]))
    }
    func testOnlyAgedClosedTicketsPurgeOpenAndRecentlyChangedTicketsStay() throws {
        for category in ["queued","active","review","blocked","parked","done","canceled"] {
            let (p,t,a) = try fixture(category:category,age:20)
            let settings: JSON = ["done_evidence_enabled":false,"closed_purge_enabled":true,"closed_days":15]
            _ = try configure(p,settings:settings);try pass();try finish()
            let closed = ["done","canceled"].contains(category)
            XCTAssertEqual(bool(try read(t),"purged"),closed,category)
            XCTAssertEqual(FileManager.default.fileExists(atPath:a["path"] as! String),!closed,category)
        }
        let (p,t,_) = try fixture(category:"canceled",age:20)
        _ = try call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"A recent note resets age"])
        _ = try configure(p);try pass();XCTAssertFalse(bool(try read(t),"purged"))
    }
    func testProjectSwitchesAndDaysAreIndependentValidatedAndRevisionChecked() throws {
        let (p,t,a) = try fixture(age:20)
        let off: JSON = ["done_evidence_enabled":false,"closed_purge_enabled":false,"closed_days":1]
        _ = try configure(p,settings:off);try pass();XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String));XCTAssertFalse(bool(try read(t),"purged"))
        for raw: JSON in [["done_evidence_enabled":1,"closed_purge_enabled":true,"closed_days":15],["done_evidence_enabled":true,"closed_purge_enabled":true,"closed_days":0],["done_evidence_enabled":true,"closed_purge_enabled":true,"closed_days":1.5]] {
            XCTAssertThrowsError(try router.validateTicketCleanupSettings(raw))
        }
        let one: JSON = ["done_evidence_enabled":false,"closed_purge_enabled":true,"closed_days":25]
        _ = try configure(p,settings:one);try pass();XCTAssertFalse(bool(try read(t),"purged"))
        XCTAssertThrowsError(try call("project_settings_save",["project_id":p["id"]!,"expected_revision":p["revision"]!,"ticket_cleanup":off]))
    }
    func testReopenAndNewKeepOriginalOrReaderHoldWinAtFinalUnlinkAfterRestart() throws {
        for protection in ["reopen","keep","reader","foreign"] {
            let (p,t,a) = try fixture();_ = try configure(p);try pass()
            try write {db in
                switch protection {
                case "reopen":var task = try self.router.record(db,t["id"] as! String,type:"task");task["status_id"] = try self.router.status(db,p["id"] as! String,"queued")["id"]!;try self.router.save(db,self.router.revised(task),type:"task")
                case "keep":var attachment = try self.router.record(db,a["id"] as! String,type:"attachment");attachment["keep_original"] = true;try self.router.save(db,self.router.revised(attachment),type:"attachment")
                case "reader":try self.router.save(db,["id":uuid(),"project_id":p["id"]!,"task_id":t["id"]!,"kind":"reader","state":"active","attachment_id":a["id"]!,"revision":1],type:"storage_hold")
                default:try self.router.save(db,["id":uuid(),"project_id":p["id"]!,"artifact_id":a["id"]!,"revision":1],type:"manifest")
                }
            }
            let root = router.root;try router.closeStore();router = nil;router = try CommandRouter(root:root);try finish()
            XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String),protection)
            XCTAssertGreaterThan((try receipts(p).first?["summary"] as? JSON)?["retained_count"] as? Int ?? 0,0,protection)
        }
    }
    func testExistingKeepExternalAndCrossProjectSharedBytesAreKeptWithReasons() throws {
        let (p,t,a) = try fixture()
        try write {db in var value = try self.router.record(db,a["id"] as! String,type:"attachment");value["keep_original"] = true;try self.router.save(db,self.router.revised(value),type:"attachment")}
        _ = try configure(p);try pass();try finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
        let first = try XCTUnwrap(receipts(p).first),summary = first["summary"] as! JSON
        XCTAssertNotNil((summary["retained_reasons"] as? JSON)?["keep_original"])
        XCTAssertFalse(bool(try read(t),"purged"))
    }
    func testSemanticRollbackNeverDeletesAndCommittedIntentResumesOnRestart() throws {
        let (p,t,a) = try fixture();_ = try configure(p)
        try router.dbQueue.write {db in try db.execute(sql:"CREATE TRIGGER lifecycle_fixture_stop BEFORE INSERT ON records WHEN json_extract(NEW.data,'$.cause')='ticket_cleanup_pass' BEGIN SELECT RAISE(ABORT,'fixture rollback'); END")}
        XCTAssertThrowsError(try pass());XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String));XCTAssertFalse(bool(try read(t),"purged"))
        try router.dbQueue.write {try $0.execute(sql:"DROP TRIGGER lifecycle_fixture_stop")}
        try expireCleanupBackoff();try pass();let root = router.root;try router.closeStore();router = nil;router = try CommandRouter(root:root);try finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String))
    }
    func testPendingOwnerInspectionBlocksBothRulesAndAppearsInReceipt() throws {
        let (p,t,a) = try fixture(age:20)
        try write {db in try self.router.save(db,["id":uuid(),"project_id":p["id"]!,"task_id":t["id"]!,"state":"pending","revision":1],type:"request")}
        let v = try selection(p),item = try XCTUnwrap((v["items"] as? [JSON])?.first)
        XCTAssertEqual(item["action"] as? String,"keep");XCTAssertEqual(item["reason"] as? String,"OWNER_REQUEST_PENDING")
        _ = try configure(p);try pass();try finish();XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String));XCTAssertFalse(bool(try read(t),"purged"))
    }
    func testReceiptScopeAndSettingsSaveNeedsNoPreview() throws {
        let (p,t,_) = try fixture()
        _ = try call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"Ordinary changes need no cleanup preview"])
        _ = try configure(p);try pass();try finish();let id = try XCTUnwrap(receipts(p).first?["id"])
        let (other,_,_) = try fixture()
        XCTAssertThrowsError(try call("ticket_cleanup_receipts",["project_id":other["id"]!,"receipt_id":id]))
    }
    func testLargeBacklogIsBoundedAndCursorSurvivesRestart() throws {
        let (p,_,_) = try fixture(category:"canceled",age:20)
        for _ in 0..<12 {
            let t = try call("task_create",["project_id":p["id"]!,"title":"Synthetic backlog"]);try mark(p,t,category:"canceled",age:20)
        }
        _ = try configure(p);let v = try selection(p)
        XCTAssertEqual((v["items"] as? [JSON])?.filter {$0["action"] as? String == "purge"}.count,1)
        try pass();XCTAssertEqual(try router.dbQueue.read {try router.records($0,type:"task",project:p["id"] as? String).filter {bool($0,"purged")}.count},1)
        let root = router.root;try router.closeStore();router = nil;router = try CommandRouter(root:root)
        for i in 1...12 {try pass(at:Date().addingTimeInterval(Double(i)))};XCTAssertEqual(try router.dbQueue.read {try router.records($0,type:"task",project:p["id"] as? String).filter {bool($0,"purged")}.count},13)
    }
}

extension TicketLifecycleCleanupTests {
    func testDoneCapturePreviewsAndLinksCleanWithoutChangingManifestAndBackupRemainsValid() throws {
        let (p,t,a) = try fixture(),pid = p["id"] as! String,tid = t["id"] as! String,cid = uuid(),mid = uuid()
        let path = "source-captures/" + pid + "/" + cid + "/source",previewPath = "objects/" + uuid() + ".preview.png"
        let data = Data("source evidence".utf8),files = try StorageObjectFiles(root:router.root)
        let capture: JSON = ["id":cid,"project_id":pid,"task_id":tid,"revision":1,"snapshot_path":path,"files":[["path":"a.txt","kind":"file","sha256":ChecklistCore.hash(data),"size":data.count],["path":"alias.txt","kind":"symlink","target":"a.txt","sha256":ChecklistCore.hash(Data("a.txt".utf8))]]]
        let manifest: JSON = ["id":mid,"project_id":pid,"task_id":tid,"revision":1,"evidence":["source_capture":capture]]
        try files.writeNew(path + "/a.txt",bytes:data);try files.writeLink(path + "/alias.txt",target:"a.txt");try files.writeNew(String(path.dropLast(7)) + "/manifest.json",bytes:Data(try jsonString(capture).utf8));try files.writeNew(previewPath,bytes:Data("preview".utf8))
        try write {db in
            try self.router.save(db,capture,type:"source_capture");try self.router.save(db,manifest,type:"manifest")
            var attachment = try self.router.record(db,a["id"] as! String,type:"attachment");attachment["preview_path"] = previewPath;try self.router.save(db,self.router.revised(attachment),type:"attachment")
        }
        _ = try configure(p);try pass();try finish()
        XCTAssertFalse(try files.regularOrLinkExists(path + "/a.txt"));XCTAssertFalse(try files.regularOrLinkExists(path + "/alias.txt"));XCTAssertFalse(try files.regularOrLinkExists(previewPath))
        XCTAssertEqual(try router.dbQueue.read {try jsonString(router.record($0,mid,type:"manifest"))},try jsonString(manifest))
        let summary = try XCTUnwrap(receipts(p).first?["summary"] as? JSON)
        XCTAssertEqual(summary["removed_count"] as? Int,5)
        XCTAssertNoThrow(try call("backup_create",["path":directory.appendingPathComponent("capture-backup").path]))
        XCTAssertThrowsError(try call("attachment_read",["project_id":pid,"attachment_id":a["id"]!,"representation":"original"]))
    }
    func testDoneThenAgedPurgeDoesNotLetCleanupReceiptsKeepPrivateRecords() throws {
        let (p,t,a) = try fixture();_ = try configure(p);try pass();try finish()
        try mark(p,t,category:"done",age:20)
        try router.dbQueue.write {try $0.execute(sql:"DELETE FROM metadata WHERE key=?",arguments:["ticket-cleanup-next:" + (p["id"] as! String)])}
        try pass();try finish();XCTAssertTrue(bool(try read(t),"purged"))
        XCTAssertThrowsError(try router.dbQueue.read {try router.record($0,a["id"] as! String,type:"attachment")})
        // Earlier receipt and exact filename/hash/length accounting survive purge.
        let all = try receipts(p);XCTAssertGreaterThanOrEqual(all.count,2)
        XCTAssertTrue(all.contains {($0["summary"] as? JSON)?["removed_count"] as? Int == 1})
    }
    func testExternalSharedAndBackupHeldBytesStayAndDisabledRuleStopsQueuedDeletion() throws {
        for protection in ["external","shared","backup","disable"] {
            let (p,t,a) = try fixture()
            if protection == "external" {
                try write {db in var value = try self.router.record(db,a["id"] as! String,type:"attachment");value["mode"] = "external_reference";try self.router.save(db,self.router.revised(value),type:"attachment")}
            } else if protection == "shared" {
                let (other,ot,_) = try fixture(category:"queued")
                try write {db in var value = try self.router.record(db,a["id"] as! String,type:"attachment");value["id"] = uuid();value["project_id"] = other["id"]!;value["task_id"] = ot["id"]!;try self.router.save(db,value,type:"attachment")}
            } else if protection == "backup" {_ = try call("backup_create",["path":directory.appendingPathComponent("protected-" + uuid()).path])}
            let project = try configure(p);try pass();if protection == "shared" {try pass()}
            if protection == "disable" {_ = try call("project_settings_save",["project_id":p["id"]!,"expected_revision":project["revision"]!,"ticket_cleanup":["done_evidence_enabled":false,"closed_purge_enabled":false,"closed_days":15]])}
            try finish();XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String),protection);XCTAssertFalse(bool(try read(t),"purged"))
            let summary = try XCTUnwrap(receipts(p).first?["summary"] as? JSON)
            XCTAssertGreaterThan(summary["retained_count"] as? Int ?? 0,0,protection)
        }
    }
    func testDoneTransitionCommitsRecoveryWakeAfterAnEarlierScan() throws {
        let (p,t,_) = try fixture(category:"queued");_ = try configure(p);try pass()
        try mark(p,t,category:"done")
        let next = try router.dbQueue.read {try String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-next:" + (p["id"] as! String)])}
        XCTAssertEqual(next,"0")
        try pass();try finish()
        XCTAssertTrue(try receipts(p).contains {($0["summary"] as? JSON)?["removed_count"] as? Int == 1})
    }
}


extension TicketLifecycleCleanupTests {
    func testPublicReceiptsKeepScanSequencesPrivateAndFirstReceiptRemainsAddressable() throws {
        let (p,_,_) = try fixture(age:20)
        let value = try selection(p)
        XCTAssertNil(((value["items"] as! [JSON]).first?["record_impact"] as? JSON)?["known_backup_count"])
        _ = try configure(p);try pass();try finish()
        let listing = try call("ticket_cleanup_receipts",["project_id":p["id"]!])
        let id = try XCTUnwrap(listing["first_pass_receipt_id"] as? String)
        let receipt = try call("ticket_cleanup_receipts",["project_id":p["id"]!,"receipt_id":id])
        XCTAssertTrue((receipt["items"] as! [JSON]).allSatisfy {$0["scan_row"] == nil})
    }
    func testBackupDoesNotSuppressAReappearedPreviewFromAnOldDeletionReceipt() throws {
        let (p,_,a) = try fixture(),path = "objects/" + uuid() + ".preview.png"
        let files = try StorageObjectFiles(root:router.root)
        try files.writeNew(path,bytes:Data("old preview".utf8))
        try write {db in var attachment = try self.router.record(db,a["id"] as! String,type:"attachment");attachment["preview_path"] = path;try self.router.save(db,self.router.revised(attachment),type:"attachment")}
        _ = try configure(p);try pass();try finish();XCTAssertFalse(try files.regularOrLinkExists(path))
        try files.writeNew(path,bytes:Data("reappeared preview".utf8))
        let budget = StorageSnapshotBudget(deadlineUptime:ProcessInfo.processInfo.systemUptime + 30,canceled:{false})
        let inventory = try router.dbQueue.read {try StorageSnapshotAuthority.inventory($0,root:router.root,budget:budget,retainedExists:{try files.regularOrLinkExists($0)})}
        XCTAssertTrue(inventory.objects.contains {$0.relativePath == path})
        XCTAssertNoThrow(try call("backup_create",["path":directory.appendingPathComponent("reappeared-backup").path]))
    }
}

extension TicketLifecycleCleanupTests {
    func testInvalidPersistedSettingsAndUnknownUpdateTimeCannotAuthorizePurge() throws {
        let (p,t,a) = try fixture(category:"canceled",age:20)
        _ = try configure(p)
        try write {db in
            var task = try self.router.record(db,t["id"] as! String,type:"task");task.removeValue(forKey:"updated_at");try self.router.save(db,task,type:"task")
        }
        XCTAssertEqual((try selection(p)["items"] as! [JSON]).first?["reason"] as? String,"unknown_change_time")
        try pass();XCTAssertFalse(bool(try read(t),"purged"))
        try write {db in
            var project = try self.router.record(db,p["id"] as! String,type:"project");project["ticket_cleanup"] = ["done_evidence_enabled":"invalid","closed_purge_enabled":true,"closed_days":0];try self.router.save(db,project,type:"project")
        }
        try pass(at:Date().addingTimeInterval(100000));try finish()
        XCTAssertFalse(bool(try read(t),"purged"));XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
    }
    func testEnrolledWorkerCanSaveSettingsWithAgentProvenanceAndOwnerOnlySwitchIsEnforced() throws {
        let (p,_,_) = try fixture(),pid = p["id"] as! String,sid = uuid()
        _ = try call("session_register",["project_id":pid,"session_id":sid,"provider":"codex","role":"worker","label":"Synthetic cleanup worker"])
        let worker = Caller(role:"worker",installation:"lifecycle-worker",projectIDs:[pid],sessionID:sid,workspace:p["root_path"] as? String)
        _ = try router.handle(method:"project_settings_save",params:["command_id":uuid(),"project_id":pid,"expected_revision":p["revision"]!,"ticket_cleanup":defaults],caller:worker)
        let event = try router.dbQueue.read {try String.fetchOne($0,sql:"SELECT data FROM events WHERE project_id=? AND kind='project_settings_saved' ORDER BY seq DESC LIMIT 1",arguments:[pid])}
        XCTAssertEqual(jsonObject(event ?? "{}")["origin"] as? String,"agent")
        var current = try call("project_settings_get",["project_id":pid]),policy = current["policy"] as! JSON;policy["agent_rule_changes"] = "owner_only"
        _ = try call("policy_apply",["project_id":pid,"expected_revision":current["revision"]!,"policy":policy])
        current = try call("project_settings_get",["project_id":pid])
        XCTAssertThrowsError(try router.handle(method:"project_settings_save",params:["command_id":uuid(),"project_id":pid,"expected_revision":current["revision"]!,"ticket_cleanup":["done_evidence_enabled":false,"closed_purge_enabled":false,"closed_days":15]],caller:worker)) {XCTAssertEqual(($0 as? CoreError)?.code,"HUMAN_CHANNEL_REQUIRED")}
    }
}


extension TicketLifecycleCleanupTests {
    func testClosedTicketPurgesAtExactlyNDaysAndNotBefore() throws {
        let (p,t,_) = try fixture(category:"canceled",age:15)
        let changed = try XCTUnwrap(ISO8601DateFormatter().date(from:try read(t)["updated_at"] as! String))
        let boundary = changed.addingTimeInterval(15 * 86400)
        try pass(at:boundary.addingTimeInterval(-0.001))
        XCTAssertFalse(bool(try read(t),"purged"))
        _ = try configure(p)
        try pass(at:boundary)
        XCTAssertTrue(bool(try read(t),"purged"))
    }
    func testDoneEvidenceOnlyAndPurgeOnlySettings() throws {
        let (p,t,a) = try fixture(age:20)
        _ = try configure(p,settings:["done_evidence_enabled":true,"closed_purge_enabled":false,"closed_days":15])
        try pass();try finish()
        XCTAssertFalse(bool(try read(t),"purged"));XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String))
        let (other,old,oldFile) = try fixture(age:20)
        _ = try configure(other,settings:["done_evidence_enabled":false,"closed_purge_enabled":true,"closed_days":15])
        try pass();try finish()
        XCTAssertTrue(bool(try read(old),"purged"));XCTAssertFalse(FileManager.default.fileExists(atPath:oldFile["path"] as! String))
        let (young,yt,ya) = try fixture()
        _ = try configure(young,settings:["done_evidence_enabled":false,"closed_purge_enabled":true,"closed_days":15])
        try pass();try finish()
        XCTAssertFalse(bool(try read(yt),"purged"));XCTAssertTrue(FileManager.default.fileExists(atPath:ya["path"] as! String))
    }
    func testConcurrentWriteInvalidatesPreparedPassBeforeAnyAdmission() throws {
        let (p,_,a) = try fixture()
        var committed = false
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketLifecycleCleanup(db)
            _ = try self.configure(p,settings:["done_evidence_enabled":false,"closed_purge_enabled":false,"closed_days":15])
            return prepared
        }) {_,_,_ in committed = true}
        XCTAssertFalse(committed)
        XCTAssertTrue(try receipts(p).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
    }
    func testLargeAutomaticFirstPassKeepsConcurrentReadAndWriteUnderTwoSeconds() throws {
        let (p,t,_) = try fixture(category:"queued"),pid = p["id"] as! String
        let files = try StorageObjectFiles(root:router.root),bytes = Data("x".utf8),sha = ChecklistCore.hash(bytes)
        var captures: [JSON] = [],tasks: [JSON] = []
        let done = try router.dbQueue.read {try router.status($0,pid,"done")["id"]!}
        // 60 Done tickets, 30,000 actual managed source objects, plus sidecars.
        for n in 0..<60 {
            let tid = uuid(),cid = uuid(),path = "source-captures/" + pid + "/" + cid + "/source"
            let fixtureDirectory = router.root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at:fixtureDirectory,withIntermediateDirectories:true)
            var entries: [JSON] = []
            for i in 0..<500 {
                let name = "file-" + String(i) + ".txt"
                try bytes.write(to:fixtureDirectory.appendingPathComponent(name))
                entries.append(["path":name,"kind":"file","size":1,"sha256":sha])
            }
            let capture: JSON = ["id":cid,"project_id":pid,"task_id":tid,"revision":1,"snapshot_path":path,"files":entries]
            try files.writeNew(String(path.dropLast(7)) + "/manifest.json",bytes:Data(try jsonString(capture).utf8))
            captures.append(capture)
            tasks.append(["id":tid,"project_id":pid,"key":"LC-PERF-" + String(n),"title":"Synthetic large cleanup","status_id":done,"revision":1,"updated_at":now()])
        }
        try write {db in
            for task in tasks {try self.router.save(db,task,type:"task")}
            for capture in captures {try self.router.save(db,capture,type:"source_capture")}
        }
        let prepared = DispatchSemaphore(value:0),release = DispatchSemaphore(value:0),finished = expectation(description:"background first pass")
        let fixtureRouter = router!
        DispatchQueue.global(qos:.utility).async {
            defer {finished.fulfill()}
            do {
                // Pause a real read snapshot after expensive selection, while
                // the request must still answer and a write must still commit.
                try fixtureRouter.withTicketCleanupPreparation({db in
                    prepared.signal()
                    let pass = try fixtureRouter.prepareTicketLifecycleCleanup(db)
                    guard release.wait(timeout:.now()+10) == .success else {throw CoreError("FIXTURE_TIMEOUT","Concurrent fixture did not finish.")}
                    return pass
                }) {db,_,pass in try fixtureRouter.commitTicketLifecycleCleanup(db,prepared:pass,at:Date())}
            } catch {XCTFail("Background preparation failed: \(error)")}
        }
        XCTAssertEqual(prepared.wait(timeout:.now()+60),.success)
        let started = Date()
        _ = try call("task_get",["project_id":pid,"task_id":t["id"]!])
        let readSeconds = Date().timeIntervalSince(started)
        let writing = Date()
        _ = try call("message_send",["project_id":pid,"task_id":t["id"]!,"body":"Concurrent ordinary write during first cleanup pass"])
        let writeSeconds = Date().timeIntervalSince(writing)
        release.signal();wait(for:[finished],timeout:15)
        XCTAssertLessThan(readSeconds,2);XCTAssertLessThan(writeSeconds,2)
        // Unrelated writes no longer discard this one-ticket pass. A following
        // pump deletes one file using its independently fenced read observation.
        // The manual preparation above already consumed its lifecycle turn.
        router.ticketCleanupLifecycleTurn = false
        try router.runStorageMaintenance()
        XCTAssertEqual(try receipts(p).filter {($0["items"] as? [JSON] ?? []).contains {$0["action"] as? String == "done_evidence"}}.count,1)
        XCTAssertGreaterThan((try receipts(p).first?["summary"] as? JSON)?["removed_count"] as? Int ?? 0,0)
        print("CL193_PERFORMANCE managed_objects=30060 done_tickets=60 read_seconds=\(readSeconds) write_seconds=\(writeSeconds) bound_seconds=2")
    }
}


extension TicketLifecycleCleanupTests {
    func testHoldAddedDuringBytePreparationInvalidatesUnlinkAndRefreshesCachedReferences() throws {
        let (p,t,a) = try fixture();try pass()
        var committed = false
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketObjectDeletion(db)
            try self.write {writer in
                try self.router.save(writer,["id":uuid(),"project_id":p["id"]!,"task_id":t["id"]!,"attachment_id":a["id"]!,"kind":"reader","state":"active","revision":1],type:"storage_hold")
            }
            return prepared
        }) {db,permit,prepared in
            committed = true
            try self.router.processTicketObjectDeletionIntents(db,permit:permit,prepared:prepared)
        }
        XCTAssertFalse(committed);XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
        try expireCleanupBackoff();try finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
        XCTAssertNotNil((try receipts(p).first?["summary"] as? JSON)?["retained_reasons"] as? JSON)
        let objects = (try receipts(p).first?["items"] as? [JSON])?.first?["byte_deletion"] as? JSON
        XCTAssertTrue((objects?["objects"] as? [JSON] ?? []).contains {strings($0,"reasons").contains("reader_lease")})
    }
}

extension TicketLifecycleCleanupTests {
    func testAutomaticRulesAlsoApplyToArchivedProjects() throws {
        for age in [0,20] {
            let (p,t,a) = try fixture(age:age)
            try write {db in
                var project = try self.router.record(db,p["id"] as! String,type:"project")
                project["archived"] = true;try self.router.save(db,self.router.revised(project),type:"project")
            }
            try pass();try finish()
            XCTAssertEqual(bool(try read(t),"purged"),age == 20)
            XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String))
        }
    }
    func testClosedPurgeUsesRewrittenBatchReferenceTokensForExclusiveCaptureBytes() throws {
        let (p,t,_) = try fixture(age:20),pid = p["id"] as! String,tid = t["id"] as! String,cid = uuid(),mid = uuid(),bid = uuid()
        let path = "source-captures/" + pid + "/" + cid + "/source",bytes = Data("batch evidence".utf8)
        let capture: JSON = ["id":cid,"project_id":pid,"task_id":tid,"revision":1,"snapshot_path":path,"files":[["path":"a.txt","kind":"file","size":bytes.count,"sha256":ChecklistCore.hash(bytes)]]]
        let files = try StorageObjectFiles(root:router.root)
        try files.writeNew(path + "/a.txt",bytes:bytes);try files.writeNew(String(path.dropLast(7)) + "/manifest.json",bytes:Data(try jsonString(capture).utf8))
        try write {db in
            try self.router.save(db,capture,type:"source_capture")
            try self.router.save(db,["id":mid,"project_id":pid,"task_id":tid,"revision":1,"evidence":["source_capture":capture]],type:"manifest")
            try self.router.save(db,["id":bid,"project_id":pid,"revision":1,"members":[["task_id":tid,"target_manifest_id":mid]]],type:"batch")
        }
        try pass();try finish()
        XCTAssertTrue(bool(try read(t),"purged"));XCTAssertFalse(try files.regularOrLinkExists(path + "/a.txt"))
        let batch = try router.dbQueue.read {try router.record($0,bid,type:"batch")}
        XCTAssertTrue((batch["members"] as? [JSON] ?? []).isEmpty)
    }
    func testLargeFileVerificationYieldsWriterAndChangedPinnedFileIsRetained() throws {
        let (p,t,a) = try fixture(),pid = p["id"] as! String,path = a["path"] as! String
        let bytes = Data(repeating:0x61,count:128 * 1024 * 1024),sha = ChecklistCore.hash(bytes)
        try bytes.write(to:URL(fileURLWithPath:path))
        try write {db in
            var attachment = try self.router.record(db,a["id"] as! String,type:"attachment")
            attachment["size"] = bytes.count;attachment["sha256"] = sha
            try self.router.save(db,self.router.revised(attachment),type:"attachment")
        }
        try pass()
        let started = DispatchSemaphore(value:0),release = DispatchSemaphore(value:0),finished = expectation(description:"large byte preparation")
        let fixtureRouter = router!
        DispatchQueue.global(qos:.utility).async {
            defer {finished.fulfill()}
            do {
                try fixtureRouter.withTicketCleanupPreparation({db in
                    started.signal()
                    let prepared = try fixtureRouter.prepareTicketObjectDeletion(db)
                    _ = release.wait(timeout:.now()+10)
                    return prepared
                }) {db,permit,prepared in try fixtureRouter.processTicketObjectDeletionIntents(db,permit:permit,prepared:prepared)}
            } catch {XCTFail("Large verification failed: \(error)")}
        }
        XCTAssertEqual(started.wait(timeout:.now()+10),.success)
        let reading = Date();_ = try call("task_get",["project_id":pid,"task_id":t["id"]!]);let readSeconds = Date().timeIntervalSince(reading)
        let writing = Date();_ = try call("message_send",["project_id":pid,"task_id":t["id"]!,"body":"Ordinary write during large file verification"]);let writeSeconds = Date().timeIntervalSince(writing)
        release.signal();wait(for:[finished],timeout:20)
        XCTAssertLessThan(readSeconds,2);XCTAssertLessThan(writeSeconds,2)
        try expireCleanupBackoff()
        // A fresh pinned descriptor must still refuse a pathname modified after
        // its hash, even when its byte length stays exactly the same.
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketObjectDeletion(db)
            let file = try FileHandle(forWritingTo:URL(fileURLWithPath:path));try file.write(contentsOf:Data([0x62]));try file.close()
            return prepared
        }) {db,permit,prepared in try self.router.processTicketObjectDeletionIntents(db,permit:permit,prepared:prepared)}
        try finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath:path))
        XCTAssertEqual((try receipts(p).first?["summary"] as? JSON)?["retained_count"] as? Int,1)
        print("CL193_LARGE_FILE bytes=\(bytes.count) read_seconds=\(readSeconds) write_seconds=\(writeSeconds) bound_seconds=2")
    }
}

extension TicketLifecycleCleanupTests {
    @discardableResult
    func cacheExecution(_ project: JSON,_ task: JSON,sourceSHA: String = String(repeating:"a",count:64)) throws -> (JSON,String) {
        let cid = uuid(),id = uuid(),toolchain = ChecklistCore.hash(Data("synthetic Swift toolchain".utf8))
        let path = "source-build-cache/" + ChecklistCore.hash(Data((sourceSHA + toolchain).utf8))
        let execution: JSON = ["id":id,"project_id":project["id"]!,"task_id":task["id"]!,"source_capture_id":cid,"revision":1,"tool":"swift_test","state":"completed","toolchain_sha256":toolchain,"process_stop_unverified":false]
        try write {db in
            try self.router.save(db,["id":cid,"project_id":project["id"]!,"task_id":task["id"]!,"revision":1,"sha256":sourceSHA,"snapshot_path":"unavailable","files":[]],type:"source_capture")
            try self.router.save(db,execution,type:"source_execution")
        }
        return (execution,path)
    }

    func testSchemaThreeStartupWithProtectedSnapshotsSeveralProjectsAndCacheArmsWithoutOtherWork() throws {
        let (p,_,_) = try fixture()
        _ = try fixture(category:"queued")
        _ = try fixture(category:"canceled")
        let (_,path) = try cacheExecution(p,try router.dbQueue.read {try router.records($0,type:"task",project:p["id"] as! String)[0]})
        try StorageObjectFiles(root:router.root).writeNew(path + "/checkouts/package/file",bytes:Data("cache".utf8))
        try FileManager.default.createDirectory(at:router.root.appendingPathComponent("backups/old-protected-snapshot"),withIntermediateDirectories:true)
        let root = router.root;try router.closeStore();router = try CommandRouter(root:root)
        XCTAssertEqual(try router.dbQueue.read {try Int.fetchOne($0,sql:"PRAGMA user_version")},3)
        XCTAssertFalse(try StorageSnapshotRetention.isActive(root:root))
        XCTAssertLessThan(try XCTUnwrap(router.nextArchiveCleanupDeadline()).timeIntervalSinceNow,0.2)
        try router.runStorageMaintenance()
        XCTAssertFalse(try receipts(p).isEmpty)
    }

    func testDeferredPreparationRecoversAndRoutineTwoFailureLatchCannotStopTicketCleanup() throws {
        let (p,_,a) = try fixture()
        // This reproduces the old global latch independently of migration or any
        // pending archive job. Lifecycle must still get its own startup wake.
        router.storageMaintenanceFallbackFailures = 2
        router.storageMaintenanceRetryAt = Date().addingTimeInterval(60)
        XCTAssertNotNil(try router.nextArchiveCleanupDeadline())
        router.ticketCleanupRetryAt = Date().addingTimeInterval(60)
        router.ticketCleanupFailure = "CLEANUP_READ_LANE_UNAVAILABLE"
        let held = try call("ticket_cleanup_receipts",["project_id":p["id"]!])["maintenance"] as! JSON
        XCTAssertEqual(held["state"] as? String,"deferred");XCTAssertNotNil(held["next_check_at"])
        XCTAssertGreaterThan(try XCTUnwrap(router.nextArchiveCleanupDeadline()).timeIntervalSinceNow,50)
        // Elapsed one-shot retry, without restarting the store or settings edits.
        try expireCleanupBackoff()
        try router.runStorageMaintenance();try finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String))
        XCTAssertNil(router.ticketCleanupFailure)
        router.storageMaintenanceRetryAt = Date().addingTimeInterval(-1)
        try router.runStorageMaintenance()
        XCTAssertEqual(router.storageMaintenanceFallbackFailures,0)
    }

    func testSnapshotRetentionPauseIsVisibleWithNextCheckAndResumesAfterRelease() throws {
        let (p,_,a) = try fixture()
        try StorageSnapshotRetention.withCapture(root:router.root) {_ in
            let result = try call("ticket_cleanup_receipts",["project_id":p["id"]!])
            XCTAssertTrue((result["receipts"] as! [JSON]).isEmpty)
            let state = result["maintenance"] as! JSON
            XCTAssertEqual(state["state"] as? String,"paused");XCTAssertEqual(state["reason"] as? String,"snapshot_retention")
            XCTAssertNotNil(state["next_check_at"]);XCTAssertTrue(state["resume_at"] is NSNull)
            XCTAssertGreaterThan(try XCTUnwrap(router.nextArchiveCleanupDeadline()).timeIntervalSinceNow,50)
            try router.runStorageMaintenance();XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
            XCTAssertEqual(router.storageMaintenanceFallbackFailures,0)
        }
        try router.runStorageMaintenance();try finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String))
    }

    func testExclusiveDoneCacheBytesUseOrdinaryFingerprintsHoldsAndReceipts() throws {
        let (p,t,_) = try fixture(),(execution,path) = try cacheExecution(p,t)
        let files = try StorageObjectFiles(root:router.root),bytes = Data("exclusive cache object".utf8)
        try files.writeNew(path + "/repositories/mirror/pack",bytes:bytes)
        try files.writeLink(path + "/debug",target:"repositories")
        try pass();try finish()
        XCTAssertFalse(try files.regularOrLinkExists(path + "/debug"))
        XCTAssertFalse(try files.regularOrLinkExists(path + "/repositories/mirror/pack"))
        XCTAssertNoThrow(try router.dbQueue.read {try router.record($0,execution["id"] as! String,type:"source_execution")})
        let objects = try receipts(p).flatMap {($0["items"] as? [JSON] ?? []).flatMap {(($0["byte_deletion"] as? JSON)?["objects"] as? [JSON]) ?? []}}
        let cache = try XCTUnwrap(objects.first {$0["relative_path"] as? String == path + "/repositories/mirror/pack"})
        XCTAssertEqual(cache["state"] as? String,"removed");XCTAssertEqual(cache["sha256"] as? String,ChecklistCore.hash(bytes))
        XCTAssertEqual((cache["size"] as? NSNumber)?.intValue,bytes.count)
    }

    func testSharedAndUnownedCachesStayAndReportRecordedReasons() throws {
        let (p,t,_) = try fixture(),(_,path) = try cacheExecution(p,t)
        let (other,open,_) = try fixture(category:"queued")
        let (foreign,_) = try cacheExecution(other,open)
        let (_,foreignPath) = try cacheExecution(other,open,sourceSHA:String(repeating:"c",count:64))
        let files = try StorageObjectFiles(root:router.root),unowned = "source-build-cache/" + String(repeating:"f",count:64)
        try files.writeNew(path + "/checkouts/package/file",bytes:Data("shared".utf8))
        try files.writeNew(unowned + "/repositories/mirror",bytes:Data("unowned".utf8))
        try files.writeNew(foreignPath + "/file",bytes:Data("foreign".utf8))
        try pass();try finish()
        XCTAssertTrue(try files.regularOrLinkExists(path + "/checkouts/package/file"))
        XCTAssertTrue(try files.regularOrLinkExists(unowned + "/repositories/mirror"))
        let retained = try receipts(p).flatMap {$0["source_build_cache"] as? [JSON] ?? []}
        XCTAssertTrue(retained.contains {$0["relative_path"] as? String == path && $0["reason"] as? String == "shared_source_build_cache"})
        XCTAssertTrue(retained.contains {$0["relative_path"] as? String == unowned && $0["reason"] as? String == "unowned_source_build_cache"})
        XCTAssertFalse(retained.contains {$0["relative_path"] as? String == foreignPath})
        let objects = try receipts(p).flatMap {($0["items"] as? [JSON] ?? []).flatMap {(($0["byte_deletion"] as? JSON)?["objects"] as? [JSON]) ?? []}}
        XCTAssertFalse(objects.contains {strings($0,"owner_ids").contains(foreign["id"] as! String) || strings($0,"owner_ids").contains(foreign["source_capture_id"] as! String)})
    }

    func testCacheNewOwnerAndChangedExecutionFingerprintPreventUnlink() throws {
        for newOwner in [false,true] {
            let (p,t,_) = try fixture(),(execution,path) = try cacheExecution(p,t,sourceSHA:ChecklistCore.hash(Data(uuid().utf8)))
            let files = try StorageObjectFiles(root:router.root)
            try files.writeNew(path + "/file",bytes:Data("held".utf8))
            try pass()
            if newOwner {
                let source = try router.dbQueue.read {try router.record($0,execution["source_capture_id"] as! String,type:"source_capture")["sha256"] as! String}
                let (other,open,_) = try fixture(category:"queued");_ = try cacheExecution(other,open,sourceSHA:source)
            } else {
                try write {db in var value = execution;value["revision"] = 2;value["observation"] = "changed";try self.router.save(db,value,type:"source_execution")}
            }
            try finish();XCTAssertTrue(try files.regularOrLinkExists(path + "/file"))
        }
    }
}

extension TicketLifecycleCleanupTests {
    func testTwoRealPreparationCommitFailuresRecoverOnTheNextDeferredWake() throws {
        let (p,_,a) = try fixture()
        try router.dbQueue.writeWithoutTransaction {db in
            try db.execute(sql:"CREATE TEMP TRIGGER cleanup_fixture_failure BEFORE INSERT ON records WHEN NEW.type='storage_job' AND json_extract(NEW.data,'$.cause')='ticket_cleanup_pass' BEGIN SELECT RAISE(ABORT,'synthetic cleanup commit failure'); END")
        }
        for _ in 0..<2 {
            try expireCleanupBackoff()
            XCTAssertThrowsError(try router.runStorageMaintenance())
            XCTAssertNotNil(router.ticketCleanupRetryAt)
            XCTAssertGreaterThan(try XCTUnwrap(router.nextArchiveCleanupDeadline()).timeIntervalSinceNow,50)
            XCTAssertTrue(try receipts(p).isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
        }
        try router.dbQueue.writeWithoutTransaction {try $0.execute(sql:"DROP TRIGGER cleanup_fixture_failure")}
        try expireCleanupBackoff()
        try router.runStorageMaintenance();try finish()
        XCTAssertFalse(try receipts(p).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String))
    }

    func testCacheReaderBackupAndUnsupportedLinkHoldsRetainBytes() throws {
        for hold in ["reader","backup","link"] {
            let (p,t,_) = try fixture(),(execution,path) = try cacheExecution(p,t,sourceSHA:ChecklistCore.hash(Data(uuid().utf8)))
            let files = try StorageObjectFiles(root:router.root),bytes = Data("protected cache".utf8)
            try files.writeNew(path + "/target",bytes:bytes)
            if hold == "link" {
                try files.writeLink(path + "/link",target:"target")
                try write {db in try self.router.save(db,["id":uuid(),"project_id":p["id"]!,"kind":"reader","state":"active","revision":1,"relative_path":path + "/link"],type:"storage_hold")}
            }
            else if hold == "reader" {
                try write {db in try self.router.save(db,["id":uuid(),"project_id":p["id"]!,"kind":"reader","state":"active","revision":1,"owner_id":execution["id"]!],type:"storage_hold")}
            } else {
                try write {db in try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?)",arguments:["backup-generation:" + uuid(),try jsonString(["state":"complete","objects":[["path":path + "/target","sha256":ChecklistCore.hash(bytes),"size":bytes.count]]])])}
            }
            try pass();try finish()
            XCTAssertTrue(try files.regularOrLinkExists(path + "/target"),hold)
            let objects = try receipts(p).flatMap {($0["items"] as? [JSON] ?? []).flatMap {(($0["byte_deletion"] as? JSON)?["objects"] as? [JSON]) ?? []}}
            XCTAssertTrue(objects.contains {$0["relative_path"] as? String == path + "/target" && $0["state"] as? String == "retained"},hold)
        }
    }
}

extension TicketLifecycleCleanupTests {
    func testUnavailableMaintenanceReadPoolIsReopenedOnDeferredRetry() throws {
        let (p,_,a) = try fixture()
        var configuration = Configuration();configuration.readonly = true
        configuration.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let unavailable = try DatabasePool(path:router.root.appendingPathComponent("checklist.sqlite").path,configuration:configuration)
        router.ticketCleanupNeedsReader = true;router.ticketCleanupReaders = unavailable
        try unavailable.close()
        XCTAssertThrowsError(try router.runStorageMaintenance())
        XCTAssertEqual(router.ticketCleanupFailure,"CLEANUP_READ_LANE_UNAVAILABLE")
        XCTAssertNotNil(try router.nextArchiveCleanupDeadline())
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
        try expireCleanupBackoff()
        try router.runStorageMaintenance();try finish()
        XCTAssertFalse(try receipts(p).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String))
    }
}

extension TicketLifecycleCleanupTests {
    func testFrequentCommandRearmingCannotPostponeTheAutomaticStartupWake() throws {
        let (p,_,_) = try fixture(),start = Date()
        var wake = StorageMaintenanceWakePlan()
        XCTAssertTrue(wake.update(try router.nextArchiveCleanupDeadline()))
        let first = try XCTUnwrap(wake.deadline)
        // Old Coordinator canceled its due timer for every successful read,
        // repeatedly moving a 50-ms startup wake into the future.
        for tick in 1...1000 {
            XCTAssertFalse(wake.update(first.addingTimeInterval(Double(tick)/1000)))
        }
        XCTAssertEqual(wake.deadline,first)
        wake.fired();try router.runStorageMaintenance()
        XCTAssertFalse(try receipts(p).isEmpty)
        XCTAssertTrue(wake.update(start.addingTimeInterval(86400)))
        XCTAssertTrue(wake.update(start.addingTimeInterval(1))) // New earlier work wins.
        XCTAssertTrue(wake.update(nil));XCTAssertNil(wake.deadline)
    }
}

extension TicketLifecycleCleanupTests {
    func testPendingAndRetainedCacheReceiptsDoNotBreakProtectedSnapshotInventory() throws {
        let (p,t,_) = try fixture(),(execution,path) = try cacheExecution(p,t)
        try write {db in
            var capture = try self.router.record(db,execution["source_capture_id"] as! String,type:"source_capture")
            capture["snapshot_path"] = "source-captures/" + (p["id"] as! String) + "/" + (capture["id"] as! String) + "/source"
            try self.router.save(db,self.router.revised(capture),type:"source_capture")
        }
        let files = try StorageObjectFiles(root:router.root)
        try files.writeNew(path + "/file",bytes:Data("rebuildable cache".utf8))
        try pass()
        let destination = directory.appendingPathComponent("cache-pending-backup")
        XCTAssertNoThrow(try call("backup_create",["path":destination.path]))
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:Data(contentsOf:destination.appendingPathComponent("manifest.json")))
        XCTAssertFalse(manifest.objects.contains {$0.descriptor.relativePath.hasPrefix("source-build-cache/")})
        XCTAssertTrue(manifest.unavailable.contains {$0.reason == "rebuildable_source_build_cache"})
        try finish();XCTAssertFalse(try files.regularOrLinkExists(path + "/file"))
        XCTAssertNoThrow(try call("backup_create",["path":directory.appendingPathComponent("cache-completed-backup").path]))
    }
}

extension TicketLifecycleCleanupTests {
    func testHeldCacheDirectoryAliasKeepsItsRecordedDescendants() throws {
        let (p,t,_) = try fixture(),(_,path) = try cacheExecution(p,t)
        let files = try StorageObjectFiles(root:router.root)
        try files.writeNew(path + "/arch/debug/product",bytes:Data("held directory target".utf8))
        try files.writeLink(path + "/debug",target:"arch/debug")
        try files.writeLink(path + "/indirect",target:"arch/debug")
        try files.writeLink(path + "/via-parent",target:"indirect/product")
        try write {db in
            for alias in ["debug","via-parent"] {
                try self.router.save(db,["id":uuid(),"project_id":p["id"]!,"kind":"reader","state":"active","revision":1,"relative_path":path + "/" + alias],type:"storage_hold")
            }
        }
        try pass();try finish()
        XCTAssertTrue(try files.regularOrLinkExists(path + "/debug"))
        XCTAssertTrue(try files.regularOrLinkExists(path + "/via-parent"))
        XCTAssertTrue(try files.regularOrLinkExists(path + "/arch/debug/product"))
    }
}

extension TicketLifecycleCleanupTests {
    func testCacheAliasChainsConvergenceAndCyclesHaveBoundedSafeOutcomes() throws {
        for kind in ["chain","convergent","cycle","directory_cycle"] {
            let (p,t,_) = try fixture(),(_,path) = try cacheExecution(p,t,sourceSHA:ChecklistCore.hash(Data(uuid().utf8)))
            let files = try StorageObjectFiles(root:router.root)
            try files.writeNew(path + "/arch/debug/product",bytes:Data("cache product".utf8))
            if kind == "cycle" {
                try files.writeLink(path + "/debug",target:"alias");try files.writeLink(path + "/alias",target:"debug")
            } else if kind == "directory_cycle" {try files.writeLink(path + "/debug",target:".")}
            else {
                try files.writeLink(path + "/debug",target:"arch/debug")
                if kind == "chain" {try files.writeLink(path + "/alias",target:"debug")}
                else {try files.writeLink(path + "/arch/debug/product-alias",target:"product")}
            }
            try pass();try finish()
            let retained = kind == "cycle" || kind == "directory_cycle"
            XCTAssertEqual(try files.regularOrLinkExists(path + "/debug"),retained,kind)
            XCTAssertEqual(try files.regularOrLinkExists(path + "/arch/debug/product"),retained,kind)
        }
    }
}

extension TicketLifecycleCleanupTests {
    func testLargeCacheAliasInventoryExhaustsOneBoundedClosureBudgetAndRetainsEntry() throws {
        let (p,t,_) = try fixture(),(_,path) = try cacheExecution(p,t)
        let files = try StorageObjectFiles(root:router.root)
        try files.writeNew(path + "/arch/debug/product",bytes:Data("bounded cache".utf8))
        for index in 0..<1500 {try files.writeLink(path + "/alias-" + String(index),target:"arch/debug")}
        try pass();try finish()
        XCTAssertTrue(try files.regularOrLinkExists(path + "/arch/debug/product"))
        XCTAssertTrue(try files.regularOrLinkExists(path + "/alias-0"))
        let objects = try receipts(p).flatMap {($0["items"] as? [JSON] ?? []).flatMap {(($0["byte_deletion"] as? JSON)?["objects"] as? [JSON]) ?? []}}
        XCTAssertTrue(objects.contains {$0["relative_path"] as? String == path + "/arch/debug/product" && strings($0,"reasons").contains("link_closure_unavailable")})
    }
}
