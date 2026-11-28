import Darwin
import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

extension PurgeByteDeletionTests {
    func testCL514MediaAuthorityTraversalChecksThePurgeDeadline() throws {
        _ = try fixture()
        var checks = 0
        XCTAssertThrowsError(try router.readForPreparation { db in
            try router.ticketCleanupValidateMediaAuthority(db,check:{
                checks += 1
                if checks == 2 { throw CoreError("QUALIFICATION_DEADLINE","Stop the media authority scan.") }
            })
        }) { error in
            XCTAssertEqual((error as? CoreError)?.code,"QUALIFICATION_DEADLINE")
        }
        XCTAssertEqual(checks,2)
    }
}

extension TicketRetirementTests {
    func testCL514ManualPurgeAboveFormerSelectedLimitsRetiresExactReceipts() throws {
        try qualifySelectedManualPurge(router,owner:owner,scope:"component")
    }
}

private func qualifySelectedManualPurge(_ router: CommandRouter,owner: Caller,scope: String) throws {
    func call(_ method: String,_ input: JSON) throws -> JSON {
        var input = input
        if !CommandRouter.readMethods.contains(method) {input["command_id"] = uuid()}
        return try XCTUnwrap(router.handle(method:method,params:fixtureTaskInput(router,method:method,input:input),caller:owner)["data"] as? JSON)
    }
    let (baselineRecords,baselineEvents,baselineReceipts) = try router.dbQueue.read {db in
        (try Int.fetchOne(db,sql:"SELECT count(*) FROM records") ?? 0,try Int.fetchOne(db,sql:"SELECT count(*) FROM events") ?? 0,
         try Int.fetchOne(db,sql:"SELECT count(*) FROM commands") ?? 0)
    }
    let projectInput: JSON = ["name":"Purge resources qualification " + uuid(),"key_prefix":"PQUAL"]
    let project = try call("project_create",projectInput)
    let pid = try XCTUnwrap(project["id"] as? String)
    let task = try call("task_create",["project_id":pid,"title":"Synthetic purge resource qualification"])
    let tid = try XCTUnwrap(task["id"] as? String)
    let foreign = try call("project_create",["name":"Foreign purge resources qualification " + uuid(),"key_prefix":"FRN"])
    let foreignID = try XCTUnwrap(foreign["id"] as? String)
    let message = uuid() + "-", history = uuid() + "-", principal = "cl514-selected-" + uuid(), foreignPrincipal = "cl514-foreign-" + uuid()
    let count = 4_300
    let numberRows = "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<?) "
    let foreignEvent = try jsonString(["reference":message + "1","text":"Foreign history"])
    let foreignReceipt = try jsonString(["text":"Quoted content " + message + "1"])
    let privatePayload = try jsonString(["error":["message":"Private operation text without a record identifier"]])
    let localError = uuid(),foreignError = uuid()
    let clock = ProcessInfo.processInfo.systemUptime
    try router.dbQueue.write {db in
        try db.execute(sql:numberRows + """
            INSERT INTO records(id,project_id,type,revision,data) SELECT ?||i,?,'message',1,
                json_object('id',?||i,'project_id',?,'task_id',?,'revision',1,'body','Private selected note') FROM n
            """,arguments:[count,message,pid,message,pid,tid])
        try db.execute(sql:numberRows + """
            INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data)
            SELECT ?||i,?,?,'fixture','cl514_selected','2026-10-01T00:00:00Z',
                json_object('reference',?||i,'body','Private selected event') FROM n
            """,arguments:[count,history,pid,pid,message])
        try db.execute(sql:numberRows + """
            INSERT INTO commands(principal,command_id,digest,result)
            SELECT ?,?||i,'receipt-'||i,json_object('data',json_object(?||i,'Private selected receipt')) FROM n
            """,arguments:[count,principal,message,message])
        try db.execute(sql:"INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data) VALUES(?,?,?,'fixture','cl514_foreign','2026-10-01T00:00:00Z',?)",
                       arguments:[uuid(),foreignID,foreignID,foreignEvent])
        try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES(?,?,'foreign',?)",
                       arguments:[foreignPrincipal,message + "1",foreignReceipt])
        for (project,receipt) in [(pid,localError),(foreignID,foreignError)] {
            let command = uuid(),operation = CommandRouter.commandOperationID(principal:principal,command:command)
            let digest = ChecklistCore.hash(Data(command.utf8))
            try router.saveOperation(db,["operation_id":operation,"command_id":command,"principal":principal,"digest":digest,
                                         "method":"attachment_cleanup_preview","project_id":project,"state":"failed",
                                         "error_result_command_id":receipt,"incarnation":router.incarnation])
            try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES(?,?,?,?)",
                           arguments:[principal,receipt,ChecklistCore.hash(Data(("operation-error:" + digest).utf8)),privatePayload])
        }
    }
    let current = try call("task_get",["project_id":pid,"task_id":tid])
    let trashed = try call("task_archive",["project_id":pid,"task_id":tid,"expected_revision":current["revision"]!,"action":"trash"])
    let identity: JSON = ["project_id":pid,"task_id":tid,"expected_revision":trashed["revision"]!]
    let previewStart = ProcessInfo.processInfo.systemUptime
    let preview = try call("task_purge_preview",identity)
    let previewSeconds = ProcessInfo.processInfo.systemUptime - previewStart
    let impact = try XCTUnwrap(preview["impact"] as? JSON)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(impact["removed_record_count"] as? Int),count)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(impact["history_events"] as? Int),count)
    var input = identity
    input["preview_digest"] = preview["digest"]
    input["command_id"] = uuid()
    var phases: [String:TimeInterval] = [:]
    let start = ProcessInfo.processInfo.systemUptime
    let result = try router.handle(method:"task_purge",params:input,caller:owner,observeOperationWriterWait:nil,
                                   observeStoragePhase:{phase,seconds in phases[phase] = seconds})
    let confirmSeconds = ProcessInfo.processInfo.systemUptime - start
    let counts = try XCTUnwrap((result["data"] as? JSON)?["counts"] as? JSON)
    XCTAssertEqual(counts["removed_records"] as? Int,impact["removed_record_count"] as? Int)
    XCTAssertEqual(counts["scrubbed_history_events"] as? Int,impact["history_events"] as? Int)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(counts["expired_command_results"] as? Int),count)
    try router.dbQueue.read {db in
        XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT count(*) FROM records WHERE id GLOB ?",arguments:[message + "*"]),0)
        XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT count(*) FROM events WHERE kind='cl514_selected' AND project_id=? AND data='{}'",arguments:[pid]),count)
        XCTAssertEqual(try String.fetchOne(db,sql:"SELECT data FROM events WHERE kind='cl514_foreign' AND project_id=?",arguments:[foreignID]),foreignEvent)
        XCTAssertEqual(try Int.fetchOne(db,sql:"""
            SELECT count(*) FROM commands WHERE principal=? AND result=?
                AND digest='receipt-'||substr(command_id,?)
            """,arguments:[principal,CommandRouter.prunedResult,message.utf8.count + 1]),count)
        XCTAssertEqual(try String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[foreignPrincipal,message + "1"]),foreignReceipt)
        XCTAssertEqual(try String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[principal,localError]),CommandRouter.prunedResult)
        XCTAssertEqual(try String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[principal,foreignError]),privatePayload)
    }
    let writerSeconds = try XCTUnwrap(phases["domain_transaction_ms"]),gateWaitSeconds = try XCTUnwrap(phases["object_gate_wait_ms"])
    let gateHoldSeconds = try XCTUnwrap(phases["object_gate_hold_ms"]),writerHoldSeconds = try XCTUnwrap(phases["storage_writer_hold_ms"])
    let eventSeconds = try XCTUnwrap(phases["purge_event_observation_ms"]),receiptSeconds = try XCTUnwrap(phases["purge_receipt_observation_ms"])
    let planSeconds = try XCTUnwrap(phases["purge_plan_ms"]),backupSeconds = try XCTUnwrap(phases["purge_backup_observation_ms"])
    var usage = rusage()
    XCTAssertEqual(getrusage(RUSAGE_SELF,&usage),0)
    var load = [Double](repeating:0,count:3)
    XCTAssertEqual(load.withUnsafeMutableBufferPointer {getloadavg($0.baseAddress,3)},3)
    print("CL514_PURGE_SELECTED scope=\(scope) utc=\(ISO8601DateFormatter().string(from:Date())) load=\(load) baseline_records=\(baselineRecords) baseline_events=\(baselineEvents) baseline_receipts=\(baselineReceipts) selected_records=\(count) selected_events=\(count) selected_receipts=\(count) fixture_total_seconds=\(ProcessInfo.processInfo.systemUptime-clock) preview_seconds=\(previewSeconds) confirmation_seconds=\(confirmSeconds) plan_seconds=\(planSeconds) event_seconds=\(eventSeconds) command_receipt_seconds=\(receiptSeconds) backup_observation_seconds=\(backupSeconds) writer_transaction_seconds=\(writerSeconds) writer_hold_seconds=\(writerHoldSeconds) object_gate_wait_seconds=\(gateWaitSeconds) object_gate_hold_seconds=\(gateHoldSeconds) peak_process_rss_bytes=\(usage.ru_maxrss)")
}

/// Explicit stopped-slot qualification. Targets a new synthetic ticket and its
/// managed bytes. The router's storage lease excludes a live service.
final class TicketPurgeOwnedCopyTests: XCTestCase {
    func testCL514ManualPurgeOnOwnedSlotTwo() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CHECKLIST_CL514_SLOT_TWO"] == "1" else {
            throw XCTSkip("Run only on the stopped CL-514 slot 2 owned by this thread.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        let slot = home.appendingPathComponent("Library/Application Support/Checklist Test Instances/slot-2",isDirectory:true)
        let root = slot.appendingPathComponent("data",isDirectory:true)
        func readMarker(_ name: String) throws -> JSON {
            let url = slot.appendingPathComponent(name)
            guard url.path == url.resolvingSymlinksInPath().path else {throw StorageSnapshotFailure.invalidFixture}
            return try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? JSON)
        }
        let metadata = try readMarker("slot.json"),marker = try readMarker(".checklist-workspace.json")
        let session = environment["CODEX_THREAD_ID"]
        guard root.path == root.resolvingSymlinksInPath().path,let session,!session.isEmpty,
              marker["session_id"] as? String == session,marker["released"] as? Bool == false,
              marker["purpose"] as? String == "disposable test slot 2",
              metadata["slot"] as? Int == 2,metadata["mode"] as? String == "stopped",
              (metadata["tickets"] as? [String])?.contains("CL-514") == true,
              (metadata["seed"] as? JSON)?["kind"] as? String == "backup" else {
            throw CoreError("QUALIFICATION_COPY_REQUIRED","Use the owned stopped CL-514 slot 2 seeded from a backup.")
        }
        let workspacePath = try XCTUnwrap(environment["CHECKLIST_CL514_PURGE_WORKSPACE"])
        let workspace = URL(fileURLWithPath:workspacePath,isDirectory:true).resolvingSymlinksInPath()
        let qualification = home.appendingPathComponent("Library/Caches/ChecklistQualification/r13-P514b")
        guard workspace.deletingLastPathComponent().path == qualification.path,
              workspace.lastPathComponent.hasPrefix("purge.") else { throw StorageSnapshotFailure.invalidFixture }
        let projectID = try XCTUnwrap(environment["CHECKLIST_CL514_PURGE_PROJECT"])
        let cli = slot.appendingPathComponent("Checklist Test 2.app/Contents/MacOS/checklist")
        let router = try CommandRouter(root:root,serviceLease:StorageServiceLease(root:root),cliCommand:cli.path)
        defer {try? router.closeStore()}
        let owner = Caller(role:"owner",installation:"cl514-slot-purge",projectIDs:[])
        try router.readForPreparation {db in
            let project = try router.record(db,projectID,type:"project")
            guard project["root_path"] as? String == workspace.path else { throw StorageSnapshotFailure.invalidFixture }
        }
        func call(_ method: String,_ input: JSON) throws -> JSON {
            var input = input
            if !CommandRouter.readMethods.contains(method), input["command_id"] == nil { input["command_id"] = uuid() }
            return try XCTUnwrap(router.handle(method:method,params:fixtureTaskInput(router,method:method,input:input),caller:owner)["data"] as? JSON)
        }
        func measure(_ phase: String, since start: TimeInterval) {
            var usage = rusage()
            _ = getrusage(RUSAGE_SELF,&usage)
            var load = [Double](repeating:0,count:3)
            _ = getloadavg(&load,3)
            let line = "CL514_PURGE_SLOT phase=\(phase) seconds=\(ProcessInfo.processInfo.systemUptime-start) utc=\(now()) load=\(load) peak_rss_bytes=\(usage.ru_maxrss)"
            fputs(line + "\n",stderr)
        }

        let baseline = try router.readForPreparation {db in
            try ["records","events","commands"].map { table in
                try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM \(table)") ?? 0
            }
        }
        let count = 4_300
        let taskID: String
        let controlID: String
        let controlCommand: String
        let controlNoteID: String
        let managedPath: String
        let selectedCommands: [String]
        let trashed: JSON
        let backup: URL
        let backupData: JSON
        if let existingPath = environment["CHECKLIST_CL514_PURGE_REUSE_BACKUP"] {
            backup = URL(fileURLWithPath:existingPath,isDirectory:true).resolvingSymlinksInPath()
            guard backup.deletingLastPathComponent().path == workspace.path,
                  backup.lastPathComponent.hasPrefix("protected-backup-") else { throw StorageSnapshotFailure.invalidFixture }
            let existing = try router.readForPreparation {db -> (task: String, control: String, command: String,
                note: String, path: String, selected: [String], trashed: JSON, backup: JSON) in
                func latestTicket(_ title: String) throws -> String {
                    try XCTUnwrap(String.fetchOne(db,sql:"""
                        SELECT id FROM records WHERE type='task' AND project_id=? AND json_extract(data,'$.title')=?
                        ORDER BY rowid DESC LIMIT 1
                        """,arguments:[projectID,title]))
                }
                func noteCommands(_ ticket: String) throws -> [Row] {
                    try Row.fetchAll(db,sql:"""
                        SELECT command_id,json_extract(result,'$.data.id') AS note_id FROM commands
                        WHERE principal=? AND json_valid(result) AND json_extract(result,'$.data.task_id')=?
                        AND json_extract(result,'$.data.kind')='note'
                        """,arguments:[owner.principal,ticket])
                }
                let task = try latestTicket("Selected purge qualification notes")
                let control = try latestTicket("Retained purge qualification note")
                let notes = try noteCommands(task)
                let controlNotes = try noteCommands(control)
                guard notes.count == count,controlNotes.count == 1,let note = controlNotes.first else {
                    throw StorageSnapshotFailure.invalidFixture
                }
                let target = try router.record(db,task,type:"task")
                guard target["trashed"] as? Bool == true else {throw StorageSnapshotFailure.invalidFixture}
                let attachment = try XCTUnwrap(router.records(db,type:"attachment",project:projectID).first {
                    $0["task_id"] as? String == task
                })
                let path = try XCTUnwrap(router.ownerManagedPathProjection(attachment,caller:owner)["path"] as? String)
                let raw = try XCTUnwrap(String.fetchOne(db,sql:"""
                    SELECT value FROM metadata WHERE key GLOB 'backup-generation:*'
                    AND json_extract(value,'$.summary.path')=? AND json_extract(value,'$.state')='complete'
                    """,arguments:[backup.path]))
                return (task,control,note["command_id"],note["note_id"],path,notes.map {$0["command_id"]},target,jsonObject(raw))
            }
            taskID = existing.task
            controlID = existing.control
            controlCommand = existing.command
            controlNoteID = existing.note
            managedPath = existing.path
            selectedCommands = existing.selected
            trashed = existing.trashed
            backupData = existing.backup
        } else {
            let target = try call("task_create",["project_id":projectID,"title":"Selected purge qualification notes"])
            let control = try call("task_create",["project_id":projectID,"title":"Retained purge qualification note"])
            taskID = try XCTUnwrap(target["id"] as? String)
            controlID = try XCTUnwrap(control["id"] as? String)
            controlCommand = uuid()
            let controlNote = try call("message_send",["project_id":projectID,"task_id":controlID,"command_id":controlCommand,
                                                       "body":"Keep this other ticket's receipt."])
            controlNoteID = try XCTUnwrap(controlNote["id"] as? String)
            let attachmentSource = workspace.appendingPathComponent("protected-purge-bytes.txt")
            try Data(repeating:0x61,count:1_048_576).write(to:attachmentSource)
            let attachment = try call("attachment_add",["project_id":projectID,"task_id":taskID,"mode":"managed_copy","path":attachmentSource.path])
            managedPath = try XCTUnwrap(attachment["path"] as? String)
            let noteStart = ProcessInfo.processInfo.systemUptime
            var commands: [String] = []
            for index in 0..<count {
                guard ProcessInfo.processInfo.systemUptime - noteStart < 900 else {
                    throw CoreError("QUALIFICATION_DEADLINE","The selected-note fixture did not finish in 900 seconds.")
                }
                let command = uuid()
                _ = try call("message_send",["project_id":projectID,"task_id":taskID,"command_id":command,
                                             "body":"Synthetic purge qualification note \(index)."])
                commands.append(command)
            }
            selectedCommands = commands
            measure("notes_\(count)",since:noteStart)

            let current = try call("task_get",["project_id":projectID,"task_id":taskID])
            trashed = try call("task_archive",["project_id":projectID,"task_id":taskID,"expected_revision":current["revision"]!,"action":"trash"])
            backup = workspace.appendingPathComponent("protected-backup-" + uuid())
            let backupStart = ProcessInfo.processInfo.systemUptime
            let backupReply = try router.executeStorageBackup(params:["path":backup.path,"command_id":uuid()],caller:owner)
            backupData = try XCTUnwrap(backupReply["data"] as? JSON)
            XCTAssertEqual(backupData["status"] as? String,"complete")
            measure("backup",since:backupStart)
        }
        let backupOperation = try XCTUnwrap(backupData["operation_id"] as? String)
        let targetInput: JSON = ["project_id":projectID,"task_id":taskID,"expected_revision":trashed["revision"]!]

        let previewStart = ProcessInfo.processInfo.systemUptime
        let preview = try call("task_purge_preview",targetInput)
        let previewSeconds = ProcessInfo.processInfo.systemUptime-previewStart
        let impact = try XCTUnwrap(preview["impact"] as? JSON)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(impact["removed_record_count"] as? Int),count)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(impact["history_events"] as? Int),count)
        let objects = try XCTUnwrap(impact["byte_deletion_objects"] as? [JSON])
        let original = try XCTUnwrap(objects.first {$0["representation"] as? String == "original"})
        let copyStart = ProcessInfo.processInfo.systemUptime
        try router.readForPreparation {db in
            // A live snapshot seed carries older generation receipts. Their
            // folders stay with the source installation. Verify only this
            // qualification's new copy here. The purge still observes all receipts.
            let raw = try XCTUnwrap(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",
                                                    arguments:["backup-generation:" + backupOperation]))
            let generation = try StorageBackupManifestIndex.generation(jsonObject(raw),root:root)
            XCTAssertEqual(generation.manifest,backupData["manifest_sha256"] as? String)
            let lookup = StorageBackupManifestIndex.Lookup(generations:[generation],legacy:nil)
            var index = StorageBackupRetentionIndex(originals:[],root:root,copyManifests:lookup.manifests,cleanupLookup:lookup)
            index.verifyCopy(for:original)
            let relative = try XCTUnwrap(original["relative_path"] as? String)
            let digest = try XCTUnwrap(original["sha256"] as? String)
            let size = try XCTUnwrap((original["size"] as? NSNumber)?.int64Value)
            let key = StorageBackupRetentionIndex.key(path:relative,sha:digest,size:size)
            let copy = try XCTUnwrap(index.verifiedCopies[key])
            XCTAssertEqual(copy.files.root.path,backup.path)
            let liveInode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath:managedPath)[.systemFileNumber] as? NSNumber)
            XCTAssertNotEqual(try XCTUnwrap(copy.regular).identity.st_ino,liveInode.uint64Value)
            try copy.requireCurrent()
        }
        let protectedCopySeconds = ProcessInfo.processInfo.systemUptime-copyStart

        var input = targetInput
        input["command_id"] = uuid()
        input["preview_digest"] = preview["digest"]
        var phases: [String:TimeInterval] = [:]
        let confirmStart = ProcessInfo.processInfo.systemUptime
        let result = try router.handle(method:"task_purge",params:input,caller:owner,observeOperationWriterWait:nil,
                                       observeStoragePhase:{phases[$0] = $1})
        let confirmationSeconds = ProcessInfo.processInfo.systemUptime-confirmStart
        let data = try XCTUnwrap(result["data"] as? JSON)
        let counts = try XCTUnwrap(data["counts"] as? JSON)
        XCTAssertEqual(counts["removed_records"] as? Int,impact["removed_record_count"] as? Int)
        XCTAssertEqual(counts["scrubbed_history_events"] as? Int,impact["history_events"] as? Int)
        let receipt = try XCTUnwrap(data["byte_deletion"] as? JSON)
        let retained = try XCTUnwrap((receipt["objects"] as? [JSON])?.first {$0["representation"] as? String == "original"})
        let byteState = try XCTUnwrap(retained["state"] as? String)
        XCTAssertEqual(byteState,original["state"] as? String)
        let byteReasons = retained["reasons"] as? [String] ?? []
        if byteState == "retained" {
            XCTAssertTrue(byteReasons.contains {"backup_index_error:FOLDER_ACCESS_UNAVAILABLE:folder_open_failed" == $0})
        } else {
            XCTAssertEqual(byteState,"pending")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath:managedPath))
        try router.readForPreparation {db in
            let commands = try jsonString(["ids":selectedCommands])
            XCTAssertEqual(try Int.fetchOne(db,sql:"""
                SELECT COUNT(*) FROM commands WHERE principal=? AND result=?
                AND command_id IN (SELECT value FROM json_each(?,'$.ids'))
                """,arguments:[owner.principal,CommandRouter.prunedResult,commands]),count)
            XCTAssertEqual(try Int.fetchOne(db,sql:"""
                SELECT COUNT(*) FROM events WHERE project_id=? AND entity_id=? AND kind='message_saved' AND data='{}'
                """,arguments:[projectID,taskID]),count)
            let controlReceipt = try XCTUnwrap(try String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",
                                                                 arguments:[owner.principal,controlCommand]))
            let controlData = jsonObject(controlReceipt)["data"] as? JSON
            XCTAssertEqual(controlData?["id"] as? String,controlNoteID)
            XCTAssertEqual(controlData?["task_id"] as? String,controlID)
        }
        measure("confirmation",since:confirmStart)
        print("CL514_PURGE_SLOT_RESULT " + (try jsonString([
            "baseline_records":baseline[0],"baseline_events":baseline[1],"baseline_receipts":baseline[2],
            "selected_notes":count,"preview_seconds":previewSeconds,"confirmation_seconds":confirmationSeconds,
            "protected_copy_seconds":protectedCopySeconds,"observed_phases_seconds":phases,"counts":counts,
            "byte_state":byteState,"byte_reasons":byteReasons,"backup_operation_id":backupOperation
        ])))
    }
}

extension TicketRetirementTests {
    func testCL514ManualPurgePlanByteBudgetRefusesBeforeWriter() throws {
        let (project,task) = try fixture()
        let pid = try XCTUnwrap(project["id"] as? String),tid = try XCTUnwrap(task["id"] as? String)
        let trashed = try trash(project,task),preview = try call("task_purge_preview",params(project,trashed))
        let padding = String(repeating:"x",count:3 * 1024 * 1024)
        try router.dbQueue.write {db in
            for _ in 0..<4 {
                let id = uuid()
                try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES(?,?,'message',1,json_object('id',?,'project_id',?,'task_id',?,'revision',1,'body',?))",
                               arguments:[id,pid,id,pid,tid,padding])
            }
        }
        func assertSizeRefusal(_ body: () throws -> JSON) {
            XCTAssertThrowsError(try body()) {error in
                let refusal = error as? CoreError
                XCTAssertEqual(refusal?.code,"CLEANUP_INVENTORY_LIMIT")
                XCTAssertEqual(refusal?.details["limit"] as? String,"selected_plan_bytes")
                XCTAssertEqual(refusal?.details["maximum"] as? Int,ManualTicketPurgeBudget.retainedByteLimit)
            }
        }
        assertSizeRefusal {try self.call("task_purge_preview",self.params(project,trashed))}
        var phaseEntered = false
        let input = params(project,trashed).merging(["command_id":uuid(),"preview_digest":preview["digest"]!]) {_,new in new}
        assertSizeRefusal {try self.router.handle(method:"task_purge",params:input,caller:self.owner,observeOperationWriterWait:nil,
                                                 observeStoragePhase:{phase,_ in if phase == "domain_transaction_body_ms" {phaseEntered = true}})}
        XCTAssertFalse(phaseEntered)
        XCTAssertFalse(try read(project,trashed)["purged"] as? Bool ?? false)
        XCTAssertEqual(try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT count(*) FROM records WHERE project_id=? AND type='message'",arguments:[pid])},4)
    }

    func testCL514ManualPurgeWriterDeadlineRollsBackWholeCommand() throws {
        let (project,task) = try fixture()
        let pid = try XCTUnwrap(project["id"] as? String),tid = try XCTUnwrap(task["id"] as? String)
        let noteCommand = uuid()
        let noteInput: JSON = ["project_id":pid,"task_id":tid,"body":"Private before expiry","command_id":noteCommand]
        _ = try router.handle(method:"message_send",params:noteInput,caller:owner)
        let trashed = try trash(project,task),preview = try call("task_purge_preview",params(project,trashed))
        let command = uuid()
        let input = params(project,trashed).merging(["command_id":command,"preview_digest":preview["digest"]!]) {_,new in new}
        func state() throws -> [String] {try router.dbQueue.read {db in
            let records = try String.fetchAll(db,sql:"SELECT data FROM records WHERE project_id=? AND (id=? OR type IN ('message','storage_job')) ORDER BY id",arguments:[pid,tid])
            let events = try String.fetchAll(db,sql:"SELECT printf('%s:%s',id,data) FROM events WHERE project_id=? ORDER BY seq",arguments:[pid])
            let receipts = try String.fetchAll(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id IN (?,?) ORDER BY command_id",arguments:[owner.principal,noteCommand,command])
            return records + events + receipts
        }}
        let before = try state()
        var wroteBody = false
        XCTAssertThrowsError(try router.handle(method:"task_purge",params:input,caller:owner,observeOperationWriterWait:nil,
                                                  observeStoragePhase:{phase,_ in
            if phase == "domain_transaction_body_ms" {
                wroteBody = true
                Thread.sleep(forTimeInterval:ManualTicketPurgeBudget.writerSeconds + 0.05)
            }
        })) {error in
            XCTAssertEqual((error as? CoreError)?.code,"PURGE_LIMIT")
            XCTAssertEqual((error as? CoreError)?.details["limit"] as? String,"writer_seconds")
        }
        XCTAssertTrue(wroteBody)
        XCTAssertEqual(try state(),before)
        XCTAssertEqual((try router.handle(method:"message_send",params:noteInput,caller:owner))["replayed"] as? Bool,true)
        let retried = try router.handle(method:"task_purge",params:input,caller:owner)
        XCTAssertEqual(((retried["data"] as? JSON)?["task"] as? JSON)?["purged"] as? Bool,true)
        code("COMMAND_RESULT_EXPIRED") {_ = try self.router.handle(method:"message_send",params:noteInput,caller:self.owner)}
    }

    func testCL514ManualPurgeWriterContentionIsRetryable() throws {
        let (project,task) = try fixture()
        let trashed = try trash(project,task),preview = try call("task_purge_preview",params(project,trashed))
        let command = uuid()
        let input = params(project,trashed).merging(["command_id":command,"preview_digest":preview["digest"]!]) {_,new in new}
        let external = try DatabaseQueue(path:router.root.appendingPathComponent("checklist.sqlite").path)
        defer {try? external.close()}
        try external.writeWithoutTransaction {db in
            try db.inTransaction(.immediate) {
                code("STORE_BUSY") {_ = try self.router.handle(method:"task_purge",params:input,caller:self.owner)}
                return .rollback
            }
        }
        XCTAssertFalse(try read(project,trashed)["purged"] as? Bool ?? false)
        let confirmation = try router.handle(method:"task_purge",params:input,caller:owner)
        XCTAssertEqual(((confirmation["data"] as? JSON)?["task"] as? JSON)?["purged"] as? Bool,true)
        XCTAssertEqual((try router.handle(method:"task_purge",params:input,caller:owner))["replayed"] as? Bool,true)
    }
}
