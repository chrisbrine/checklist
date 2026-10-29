import XCTest
import Foundation
import GRDB
import Darwin
@testable import ChecklistCore

/// Explicit real-copy qualification, separate from template/unit evidence. No
/// Keychain, slot, live-root access, direct SQL writes, timing barriers or path rewrite.
final class BackupWriteAdmissionStoreCopyTests: XCTestCase {
    func testOnlineBackupOnExplicitOwnedRealStoreCopy() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CHECKLIST_P320_STORE_COPY"],
              let outputPath = environment["CHECKLIST_P320_RESULT"] else {
            throw XCTSkip("Requires a complete snapshot_seed owned copy and an explicit result path.")
        }
        let checkout = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
        let root = URL(fileURLWithPath:path,isDirectory:true).resolvingSymlinksInPath()
        let allowed = checkout.appendingPathComponent(".local/P320-qualification/data",isDirectory:true)
        guard root == allowed,FileManager.default.fileExists(atPath:root.appendingPathComponent("checklist-store.identity.json").path) else {
            throw CoreError("QUALIFICATION_COPY_REQUIRED","Use snapshot_seed into this checkout's .local/P320-qualification/data.")
        }
        let output = URL(fileURLWithPath:outputPath),state = P320CopyMeasurements(output:output)
        state.put("root",root.path);state.put("load_start",p320Load());state.put("started_at",now())
        state.put("scope","Core router on complete owned real backup copy; no native app, AX, XPC or Keychain qualification")
        state.put("forced_migration",false)
        try state.save()
        let startup = ProcessInfo.processInfo.systemUptime
        let lease = try StorageServiceLease(root:root)
        let router = try CommandRouter(root:root,serviceLease:lease)
        defer {try? router.closeStore()}
        state.put("startup_seconds",ProcessInfo.processInfo.systemUptime-startup)
        state.put("startup_succeeded",true)
        let owner = Caller(role:"owner",installation:"p320-owned-copy-qualification",projectIDs:[])
        let selected: JSON = try router.dbQueue.read { db in
            guard let row = try Row.fetchOne(db,sql:"SELECT " + CommandRouter.canonicalRecordColumns + " FROM records WHERE type='task' AND COALESCE(json_extract(data,'$.trashed'),0)=0 AND COALESCE(json_extract(data,'$.purged'),0)=0 ORDER BY rowid DESC LIMIT 1") else {
                throw CoreError("QUALIFICATION_COPY_REQUIRED","Owned real store has no editable task.")
            }
            return try GRDBRecordEnvelopeAdapter.decode(row).object
        }
        let task = try XCTUnwrap(selected["id"] as? String),project = try XCTUnwrap(selected["project_id"] as? String)
        let revision = try XCTUnwrap(selected["revision"] as? Int)
        state.put("selected_project_id",project);state.put("selected_task_id",task)
        let baselineInputs: [(String,JSON)] = [("service_info",[:]),("task_get",["project_id":project,"task_id":task]),("workspace_page",["project_id":project,"surface":"overview","limit":20])]
        for (method,input) in baselineInputs {
            let started = ProcessInfo.processInfo.systemUptime
            _ = try router.handle(method:method,params:input,caller:owner)
            state.append("baseline_reads",["method":method,"seconds":ProcessInfo.processInfo.systemUptime-started])
        }
        try state.save()
        let writesReady = DispatchSemaphore(value:0),readsReady = DispatchSemaphore(value:0)
        let writesDone = DispatchSemaphore(value:0),readsDone = DispatchSemaphore(value:0)
        let noteCommand = uuid(),editCommand = uuid(),noteBody = "P320 owned-copy note " + uuid(),editedTitle = "P320 owned-copy edit " + uuid()
        state.put("write_command_ids",[noteCommand,editCommand])
        let noteInput: JSON = ["project_id":project,"task_id":task,"command_id":noteCommand,"kind":"note","body":noteBody]
        let editInput: JSON = ["project_id":project,"task_id":task,"command_id":editCommand,"expected_revision":revision,"title":editedTitle]
        DispatchQueue.global().async {
            defer {writesDone.signal()}
            guard writesReady.wait(timeout:.now()+120) == .success else {state.append("traffic_errors","Writer lease was not observed within 120 seconds.");return}
            for (method,input) in [("message_send",noteInput),("task_edit",editInput)] {
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    let reply = try router.handle(method:method,params:input,caller:owner)
                    state.append("write_responses",["method":method,"command_id":input["command_id"]!,"seconds":ProcessInfo.processInfo.systemUptime-started,"reply":reply,"load":p320Load()])
                } catch {state.append("traffic_errors",["method":method,"error":String(describing:error),"seconds":ProcessInfo.processInfo.systemUptime-started])}
            }
            // Bounded test-only receipt observation; no provider/runtime polling.
            for command in [noteCommand,editCommand] {
                let end = ProcessInfo.processInfo.systemUptime+60
                var terminal = false
                repeat {
                    do {
                        let reply = try router.handle(method:"command_status",params:["project_id":project,"command_id":command],caller:owner)
                        let status = (reply["data"] as? JSON)?["state"] as? String
                        if status == "applied" || status == "failed" {
                            state.append("write_receipts",["command_id":command,"reply":reply]);terminal = true;break
                        }
                    } catch {state.append("traffic_errors",["method":"command_status","error":String(describing:error)]);break}
                    usleep(50_000)
                } while ProcessInfo.processInfo.systemUptime<end
                if !terminal {state.append("traffic_errors",["command_id":command,"error":"No terminal command receipt within 60 seconds."])}
            }
        }
        DispatchQueue.global().async {
            defer {readsDone.signal()}
            guard readsReady.wait(timeout:.now()+120) == .success else {state.append("traffic_errors","Read start was not observed within 120 seconds.");return}
            var rounds = 0
            repeat {
                for (method,input) in baselineInputs {
                    let started = ProcessInfo.processInfo.systemUptime
                    do {
                        let reply = try router.handle(method:method,params:input,caller:owner)
                        state.append("backup_reads",["method":method,"seconds":ProcessInfo.processInfo.systemUptime-started,"write_admission":reply["write_admission"] ?? NSNull(),"load":p320Load()])
                    } catch {state.append("traffic_errors",["method":method,"error":String(describing:error),"seconds":ProcessInfo.processInfo.systemUptime-started])}
                }
                rounds += 1
                if !state.finished {usleep(2_000_000)}
            } while !state.finished && rounds<900
        }
        var budget = StorageSnapshotBudget.production()
        let measurement = budget.measurement
        budget.observe = { event in
            state.count(event)
            if ["writer_lease_acquired","backup_done","writer_lease_released","capture_released","inventory_started","inventory_finished","copying_objects","directories_synchronized","manifest_written","before_publish","published_before_parent_flush"].contains(event) {
                state.append("backup_events",["event":event,"uptime":ProcessInfo.processInfo.systemUptime,"load":p320Load()])
            }
            if event == "writer_lease_acquired" {writesReady.signal();readsReady.signal()}
            if ["capture_released","inventory_started","inventory_finished","copying_objects","manifest_written","before_publish"].contains(event) {
                state.put("current_phase",event)
                if event == "capture_released" {state.put("writer_lease_seconds",measurement.writerLeaseSeconds)}
                try state.save()
            }
        }
        let destination = root.deletingLastPathComponent().appendingPathComponent("online-backup-" + uuid(),isDirectory:true)
        let backupStarted = ProcessInfo.processInfo.systemUptime
        do {
            let response = try router.executeStorageBackup(params:["command_id":uuid(),"path":destination.path],caller:owner,budget:budget)
            state.put("backup_response",response);state.put("backup_complete",true)
        } catch {state.put("backup_error",String(describing:error));state.put("backup_complete",false)}
        state.put("backup_seconds",ProcessInfo.processInfo.systemUptime-backupStarted)
        state.put("writer_lease_seconds",budget.measurement.writerLeaseSeconds)
        state.put("writer_lease_under_five_seconds",budget.measurement.writerLeaseSeconds<5)
        state.finished = true
        let joinedWrites = writesDone.wait(timeout:.now()+125) == .success
        let joinedReads = readsDone.wait(timeout:.now()+125) == .success
        state.put("traffic_joined",joinedWrites && joinedReads)
        try state.save()
        guard joinedWrites && joinedReads else {throw CoreError("QUALIFICATION_INCOMPLETE","Traffic did not finish; retain the owned copy and result.")}
        let observed = try router.dbQueue.read { db -> JSON in
            let note = try Int.fetchOne(db,sql:"SELECT MIN(seq) FROM events WHERE kind='message_saved' AND entity_id=? AND actor=? AND json_extract(data,'$.message_id') IN (SELECT id FROM records WHERE type='message' AND json_extract(data,'$.body')=?)",arguments:[task,owner.principal,noteBody])
            let edit = try Int.fetchOne(db,sql:"SELECT MIN(seq) FROM events WHERE kind='task_edited' AND entity_id=? AND actor=? AND seq>?",arguments:[task,owner.principal,note ?? -1])
            let current = try router.record(db,task,type:"task")
            return ["note_applied":note != nil,"edit_applied":current["title"] as? String == editedTitle,"applied_in_arrival_order":note != nil && edit != nil && note!<edit!]
        }
        for (key,value) in observed {state.put(key,value)}
        let writes = state.rows("write_responses")
        state.put("both_writes_returned_within_one_second",writes.count == 2 && writes.allSatisfy {($0["seconds"] as? Double ?? .infinity)<1})
        state.put("both_writes_reported_queued",writes.count == 2 && writes.allSatisfy {($0["reply"] as? JSON)?["command_outcome"] as? String == "queued"})
        state.put("load_after_online",p320Load())
        try state.save()
        if state.flag("backup_complete") {
            let raw = try Data(contentsOf:destination.appendingPathComponent("manifest.json")),manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:raw)
            let verificationStarted = ProcessInfo.processInfo.systemUptime
            let verified = try StorageSnapshot.reconcile(parent:destination.deletingLastPathComponent(),operation:try XCTUnwrap(UUID(uuidString:manifest.operationID)),publicationName:destination.lastPathComponent,budget:.production())
            state.put("independent_verification_seconds",ProcessInfo.processInfo.systemUptime-verificationStarted)
            state.put("backup_verifies_exactly",verified.manifestSHA256 == ChecklistCore.hash(raw))
            state.put("manifest_object_count",manifest.objects.count);state.put("manifest_database_bytes",manifest.databaseSize)
            state.put("manifest_record_families",manifest.recordFamilies ?? [:]);state.put("manifest_table_rows",manifest.tableRows ?? [:])
            try state.save()
        }
        if environment["CHECKLIST_P320_PROTECTED_COPY"] == "1" {
            let identity = try StoreIdentityReceipt.decode(Data(contentsOf:root.appendingPathComponent("checklist-store.identity.json")))
            let operation = UUID(),parent = root.deletingLastPathComponent().appendingPathComponent("protected",isDirectory:true)
            try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
            let protectedStarted = ProcessInfo.processInfo.systemUptime
            let receipt = try ArchiveStorageGate.withExclusive(root:root) { permit in
                try StorageSnapshot.build(StorageSnapshotSource(source:root,parent:parent,storeID:identity.logical_store_id,permit:permit),operation:operation,budget:.production())
            }
            state.put("protected_snapshot_seconds",ProcessInfo.processInfo.systemUptime-protectedStarted)
            let protected = parent.appendingPathComponent(StorageSnapshot.names(operation).published,isDirectory:true)
            let verified = try StorageSnapshot.reconcile(parent:parent,operation:operation,budget:.production())
            state.put("protected_snapshot_verified",receipt.manifestSHA256 == verified.manifestSHA256)
            state.put("protected_snapshot_path",protected.path)
            state.put("protected_scope","Exact StorageSnapshot.build used by prepareUpgrade; no schema downgrade or migration rehearsal was fabricated")
        }
        state.put("load_end",p320Load());state.put("finished_at",now());try state.save()
        print("P320_OWNED_COPY_QUALIFICATION " + output.path)
        XCTAssertTrue(state.flag("backup_complete"));XCTAssertTrue(state.flag("backup_verifies_exactly"))
        XCTAssertTrue(state.flag("writer_lease_under_five_seconds"));XCTAssertTrue(state.flag("both_writes_returned_within_one_second"))
        XCTAssertTrue(state.flag("note_applied"));XCTAssertTrue(state.flag("edit_applied"));XCTAssertTrue(state.flag("applied_in_arrival_order"))
        XCTAssertTrue(state.errorsEmpty,"See the explicit qualification result for each traffic failure.")
        if environment["CHECKLIST_P320_PROTECTED_COPY"] == "1" {XCTAssertTrue(state.flag("protected_snapshot_verified"))}
    }
}

private final class P320CopyMeasurements: @unchecked Sendable {
    private let lock = NSLock()
    private var values: JSON = [:]
    private var lists: [String:[Any]] = [:]
    private var counts: [String:Int] = [:]
    private var done = false
    let output: URL
    init(output:URL) {self.output = output}
    var finished: Bool {get {lock.withLock {done}} set {lock.withLock {done = newValue}}}
    func put(_ key:String,_ value:Any) {lock.withLock {values[key] = value}}
    func append(_ key:String,_ value:Any) {lock.withLock {lists[key,default:[]].append(value)}}
    func count(_ event:String) {lock.withLock {counts[event,default:0] += 1}}
    func rows(_ key:String) -> [JSON] {lock.withLock {lists[key] as? [JSON] ?? []}}
    func flag(_ key:String) -> Bool {lock.withLock {values[key] as? Bool ?? false}}
    var errorsEmpty: Bool {lock.withLock {(lists["traffic_errors"] ?? []).isEmpty}}
    func save() throws {
        let snapshot = lock.withLock { () -> JSON in
            var snapshot = values
            for (key,list) in lists {snapshot[key] = list}
            snapshot["event_counts"] = counts
            return snapshot
        }
        try JSONSerialization.data(withJSONObject:snapshot,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]).write(to:output,options:.atomic)
    }
}
private func p320Load() -> [Double] {
    var values = [Double](repeating:0,count:3)
    _ = values.withUnsafeMutableBufferPointer {getloadavg($0.baseAddress!,3)}
    return values
}
