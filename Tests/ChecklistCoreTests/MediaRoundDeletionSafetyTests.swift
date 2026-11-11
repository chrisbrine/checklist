import ChecklistTestSupport
import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

extension MediaRoundDeletionTests {
    /// Keep the read snapshot pinned while another enrolled session writes a
    /// bounded steady stream. The old store-wide data_version fence would fail.
    func testNarrowFenceAllowsSteadyUnrelatedSessionWritesDuringPreparation() throws {
        let f = try Fixture(),round = try cancel(f,f.round(f.type(checks.schema())))
        let task = try results.task(f),other = try results.session(f,"media-deletion-unrelated-writer")
        var config = Configuration();config.readonly = true
        let observer = try DatabaseQueue(path:f.root.appendingPathComponent("checklist.sqlite").path,configuration:config)
        defer {try? observer.close()}
        let beforeVersion = try observer.read {try Int64.fetchOne($0,sql:"PRAGMA data_version")!}
        var afterWritesVersion = beforeVersion
        f.router.mediaRoundDeletionPreparationProbe = {
            for index in 0..<24 {
                _ = try self.results.call(f,"message_send",["task_id":task["id"]!,"kind":"note","body":"Unrelated steady write \(index)"],as:other)
                Thread.sleep(forTimeInterval:0.002)
            }
            afterWritesVersion = try observer.read {try Int64.fetchOne($0,sql:"PRAGMA data_version")!}
        }
        defer {f.router.mediaRoundDeletionPreparationProbe = nil}
        let deleted = try worker(f,"media_round_delete",input(f,round))
        XCTAssertEqual(deleted["deleted"] as? Bool,true)
        XCTAssertEqual(try f.rows("message").filter {($0["body"] as? String ?? "").hasPrefix("Unrelated steady write")}.count,24)
        XCTAssertNotEqual(afterWritesVersion,beforeVersion,"Confirms the strict CL-446 fence would reject these unrelated commits before deletion commits")
        XCTAssertGreaterThanOrEqual(deleted["preparation_seconds"] as? Double ?? -1,0)
    }

    func testNarrowFenceRejectsSameRevisionOwnedPayloadChangeWithoutRemovingAnything() throws {
        let f = try Fixture(),round = try cancel(f,f.round(f.type(checks.schema())))
        var afterWrite = ""
        f.router.mediaRoundDeletionPreparationProbe = {
            try f.router.dbQueue.writeWithoutTransaction {db in
                try f.router.withValidatedDomainTransaction(db) {
                    var value = try f.router.record(db,round["id"] as! String,type:"media_round")
                    value["title"] = "Intervening same-revision edit"
                    try f.router.save(db,value,type:"media_round");return .commit
                }
            }
            afterWrite = try f.allState()
        }
        defer {f.router.mediaRoundDeletionPreparationProbe = nil}
        checks.checkError("MEDIA_CONTEXT_CHANGED") {try self.worker(f,"media_round_delete",self.input(f,round))}
        XCTAssertEqual(try f.allState(),afterWrite)
        XCTAssertEqual(try f.record(round["id"] as! String,"media_round")["title"] as? String,"Intervening same-revision edit")
    }

    func testNarrowFenceRejectsNewReferenceFromAnotherProjectWithoutRemovingAnything() throws {
        let f = try Fixture(),round = try cancel(f,f.round(f.type(checks.schema())))
        var afterWrite = ""
        f.router.mediaRoundDeletionPreparationProbe = {
            try f.router.dbQueue.writeWithoutTransaction {db in
                try f.router.withValidatedDomainTransaction(db) {
                    try f.router.save(db,["id":"00000000-0000-0000-0000-000000000449","project_id":"00000000-0000-0000-0000-000000000448","revision":1,"references":[round["id"]!]],type:"message")
                    return .commit
                }
            }
            afterWrite = try f.allState()
        }
        defer {f.router.mediaRoundDeletionPreparationProbe = nil}
        checks.checkError("MEDIA_CONTEXT_CHANGED") {try self.worker(f,"media_round_delete",self.input(f,round))}
        XCTAssertEqual(try f.allState(),afterWrite)
        XCTAssertEqual(try f.record(round["id"] as! String,"media_round")["state"] as? String,"canceled")
    }

    func testNarrowFenceRejectsNewPendingLinkedOwnerRequestWithoutRemovingAnything() throws {
        let f = try Fixture(),task = try results.task(f),round = try f.round(f.type(checks.schema()))
        _ = try results.link(f,round,task);_ = try cancel(f,round)
        var afterWrite = ""
        f.router.mediaRoundDeletionPreparationProbe = {
            _ = try self.results.call(f,"human_request_create",["task_id":task["id"]!,"title":"New owner question","blocking":false,"questions":[["id":"q","type":"text","prompt":"Keep this pass?"]]])
            afterWrite = try f.allState()
        }
        defer {f.router.mediaRoundDeletionPreparationProbe = nil}
        checks.checkError("MEDIA_CONTEXT_CHANGED") {try self.worker(f,"media_round_delete",self.input(f,round))}
        XCTAssertEqual(try f.allState(),afterWrite)
    }

    /// Exercise the real Done handoff first, which is how CL-449's reported
    /// captures become ordinary ticket attachments on installed stores.
    func ticketCapture(_ f: Fixture,category: String) throws -> (JSON,JSON,JSON) {
        let task = try results.task(f),round = try imageRound(f,"terminal-ticket-\(category).png")
        _ = try results.link(f,round,task);_ = try f.publish(round);try f.acceptEach(round)
        try MediaLinkedTaskCleanupTests().done(f,task)
        if category != "done" {
            try f.router.dbQueue.writeWithoutTransaction {db in
                try f.router.withValidatedDomainTransaction(db) {
                    var current = try f.router.record(db,task["id"] as! String,type:"task")
                    current["status_id"] = try f.router.status(db,f.project,category)["id"]!
                    try f.router.save(db,f.router.revised(current),type:"task");return .commit
                }
            }
        }
        return (try f.get(round),try f.record(task["id"] as! String,"task"),try XCTUnwrap(f.rows("attachment").first))
    }

    func checkTerminalTicketAttachmentIsKept(_ category: String) throws {
        let f = try Fixture();try trash(f)
        let (round,task,attachment) = try ticketCapture(f,category:category)
        let path = try XCTUnwrap(f.router.ownerManagedPathProjection(attachment,caller:f.owner)["path"] as? String)
        let original = try Data(contentsOf:URL(fileURLWithPath:path))
        let notes = try exactRecords(f,["task","message","delivery"])
        let reply = try worker(f,"media_round_delete",input(f,round))
        let kept = try XCTUnwrap((reply["kept_attachments"] as? [JSON])?.first)
        XCTAssertEqual(kept["attachment_id"] as? String,attachment["id"] as? String)
        XCTAssertEqual(kept["task_id"] as? String,task["id"] as? String)
        XCTAssertEqual(kept["task_key"] as? String,task["key"] as? String)
        XCTAssertEqual(kept["status"] as? String,"kept");XCTAssertEqual(kept["reason"] as? String,"kept_with_ticket")
        let retained = try f.record(attachment["id"] as! String,"attachment")
        XCTAssertNil(retained["attachment_owner_id"]);XCTAssertNil(retained["storage_job_id"]);XCTAssertNil(retained["media_cleanup_round_id"])
        let history = try XCTUnwrap(retained["media_capture_history"] as? JSON)
        XCTAssertEqual(history["state"] as? String,"round_deleted")
        XCTAssertEqual(history["round_id"] as? String,round["id"] as? String)
        XCTAssertEqual(history["owner_id"] as? String,attachment["attachment_owner_id"] as? String)
        XCTAssertEqual(history["import_job_id"] as? String,attachment["storage_job_id"] as? String)
        XCTAssertEqual(try exactRecords(f,["task","message","delivery"]),notes)
        XCTAssertTrue(try f.rows("media_round").isEmpty)
        let receipt = try f.record(reply["byte_deletion_receipt_id"] as! String,"storage_job")
        XCTAssertFalse((receipt["objects"] as? [JSON] ?? []).contains {["original","preview"].contains($0["representation"] as? String ?? "") && strings($0,"owner_ids").contains(attachment["id"] as! String)},"Ticket-owned originals/previews never enter round byte cleanup")
        _ = try f.router.runTicketObjectDeletionCohort()
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:path)),original)
        XCTAssertEqual(try jsonString(deletion(f,round)["kept_attachments"]!),try jsonString(reply["kept_attachments"]!))
        try f.router.dbQueue.read {db in try MediaRecordRegistry.validate(MediaRecordRegistry.envelopes(db))}
    }

    func testDoneTicketAttachmentIsKeptWithTicketAndNeverEntersRoundCleanup() throws {try checkTerminalTicketAttachmentIsKept("done")}
    func testCanceledTicketAttachmentIsKeptWithTicketAndNeverEntersRoundCleanup() throws {try checkTerminalTicketAttachmentIsKept("canceled")}

    func testOpenTicketAttachmentStillRefusesAndPreservesEverything() throws {
        let f = try Fixture(),(round,_,attachment) = try ticketCapture(f,category:"active")
        try assertRefusal(f,"MEDIA_ROUND_REFERENCED") {try self.worker(f,"media_round_delete",self.input(f,round))}
        XCTAssertEqual(try jsonString(f.record(attachment["id"] as! String,"attachment")),try jsonString(attachment))
    }

    func testKeptCaptureProvenanceSurvivesExportBackupVerificationAndRestore() throws {
        let f = try Fixture(),(round,_,attachment) = try ticketCapture(f,category:"done")
        _ = try worker(f,"media_round_delete",input(f,round))
        let retained = try f.record(attachment["id"] as! String,"attachment")
        let export = f.base.appendingPathComponent("kept-capture-export"),backup = f.base.appendingPathComponent("kept-capture-backup")
        _ = try results.call(f,"export_project",["path":export.path])
        let exported = try JSONSerialization.jsonObject(with:Data(contentsOf:export.appendingPathComponent("project.json"))) as! JSON
        let exportedAttachment = try XCTUnwrap((exported["attachment"] as? [JSON])?.first {$0["id"] as? String == retained["id"] as? String})
        XCTAssertEqual(try jsonString(exportedAttachment["media_capture_history"]!),try jsonString(retained["media_capture_history"]!))
        _ = try f.router.handle(method:"backup_create",params:["command_id":uuid(),"path":backup.path],caller:f.owner)
        let preview = try f.router.handle(method:"restore_preview",params:["path":backup.path],caller:f.owner)["data"] as! JSON
        let restored = try f.router.handle(method:"restore_create",params:["command_id":uuid(),"path":backup.path,"manifest_sha256":preview["manifest_sha256"]!],caller:f.owner)["data"] as! JSON
        var config = Configuration();config.readonly = true;config.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let database = try DatabaseQueue(path:URL(fileURLWithPath:restored["path"] as! String).appendingPathComponent("checklist.sqlite").path,configuration:config)
        defer {try? database.close()}
        try database.read {db in
            let records = try MediaRecordRegistry.envelopes(db)
            try MediaRecordRegistry.validate(records)
            let restoredAttachment = try XCTUnwrap(records.first {$0.id == attachment["id"] as? String})
            XCTAssertEqual(try jsonString(restoredAttachment.object["media_capture_history"]!),try jsonString(retained["media_capture_history"]!))
            XCTAssertFalse(records.contains {$0.id == round["id"] as? String})
        }
    }

    func testKeptTicketCaptureSurvivesFreshDoneCleanupAndThenPurgesThroughTrash() throws {
        let f = try Fixture();try trash(f)
        let (round,task,attachment) = try ticketCapture(f,category:"done")
        _ = try worker(f,"media_round_delete",input(f,round))
        let path = try XCTUnwrap(f.router.ownerManagedPathProjection(attachment,caller:f.owner)["path"] as? String)
        let plan = try f.router.dbQueue.read {db in try f.router.ticketPurgePlan(db,task:f.router.record(db,task["id"] as! String,type:"task"),doneEvidence:true)}
        let originals = plan.byteDeletion.objects.filter {$0["representation"] as? String == "original"}
        XCTAssertFalse(originals.isEmpty)
        XCTAssertTrue(originals.allSatisfy {strings($0,"reasons").contains("kept_with_ticket")})
        try ticketCleanupBackupTemplate(f.router,objects:plan.byteDeletion.objects)
        try f.router.runTicketLifecycleCleanup()
        _ = try f.router.runTicketObjectDeletionCohort()
        XCTAssertTrue(FileManager.default.fileExists(atPath:path),"Fresh backed-up Done evidence cleanup still keeps the ticket original")
        let current = try f.record(task["id"] as! String,"task")
        let trashed = try results.call(f,"task_archive",["task_id":current["id"]!,"expected_revision":current["revision"]!,"action":"trash"])
        let preview = try results.call(f,"task_purge_preview",["task_id":trashed["id"]!,"expected_revision":trashed["revision"]!])
        _ = try results.call(f,"task_purge",["task_id":trashed["id"]!,"expected_revision":trashed["revision"]!,"preview_digest":preview["digest"]!])
        let purge = try XCTUnwrap(f.rows("storage_job").first {$0["cause"] as? String == "task_purge"})
        XCTAssertTrue((purge["objects"] as? [JSON] ?? []).filter {$0["representation"] as? String == "original"}.allSatisfy {$0["disposal"] as? String == "trash"})
        _ = try f.router.runTicketObjectDeletionCohort()
        XCTAssertFalse(FileManager.default.fileExists(atPath:path))
        let completed = try f.record(purge["id"] as! String,"storage_job")
        let moved = try XCTUnwrap((completed["objects"] as? [JSON])?.first {$0["representation"] as? String == "original"})
        XCTAssertEqual(moved["moved_to_trash"] as? Bool,true)
        XCTAssertTrue(FileManager.default.fileExists(atPath:try XCTUnwrap(moved["trash_path"] as? String)))
    }

    func testKeptCaptureHistoricalTaskDependencyRemainsValidWhenAnotherMediaRootUsesIt() throws {
        let f = try Fixture(),(round,_,attachment) = try ticketCapture(f,category:"done")
        _ = try worker(f,"media_round_delete",input(f,round))
        try ArchiveStorageGate.withExclusive(root:f.root) {permit in
            try f.router.dbQueue.writeWithoutTransaction {db in
                try f.router.withValidatedDomainTransaction(db) {
                    let owner = try f.router.createMediaAttachmentOwner(db,permit:permit,project:f.project,kind:.draftItem,caller:f.owner)
                    _ = try f.router.addMediaAttachmentReference(db,project:f.project,owner:owner,attachment:f.router.record(db,attachment["id"] as! String,type:"attachment"),caller:f.owner)
                    try f.router.ticketCleanupValidateMediaAuthority(db)
                    return .commit
                }
            }
        }
        try f.router.dbQueue.read {try f.router.ticketCleanupValidateMediaAuthority($0)}
    }

    func testArchiveCleanupKeepsHistoricalTicketCapture() throws {
        let f = try Fixture(),(round,task,attachment) = try ticketCapture(f,category:"done")
        _ = try worker(f,"media_round_delete",input(f,round))
        let holds = try f.router.dbQueue.read {db in
            try f.router.completeArchiveCleanupHolds(db,attachment:f.router.record(db,attachment["id"] as! String,type:"attachment"),task:task,considerArchiving:true,currentGraph:[])
        }
        XCTAssertTrue(holds.contains(.mediaTrashRequired))
        try f.router.runStorageMaintenance()
        XCTAssertEqual(try f.record(attachment["id"] as! String,"attachment")["availability"] as? String,"available")
    }

    func testRepeatedHandoffAndDeletionPreserveOriginalCaptureHistory() throws {
        let f = try Fixture(),(first,task,attachment) = try ticketCapture(f,category:"done")
        _ = try worker(f,"media_round_delete",input(f,first))
        let retained = try f.record(attachment["id"] as! String,"attachment")
        let originalHistory = try jsonString(XCTUnwrap(retained["media_capture_history"] as? JSON))
        XCTAssertNotNil((retained["media_capture_history"] as? JSON)?["owner_id"])
        XCTAssertNotNil((retained["media_capture_history"] as? JSON)?["import_job_id"])
        let later = try f.round(f.type(checks.schema())),item = try f.item(later)
        _ = try results.link(f,later,task)
        // An owned historical-adoption seam supplies a retained candidate whose
        // declared dependency is this exact independent ticket attachment. The
        // real completion hook performs its second handoff and adds the marker.
        try f.router.dbQueue.writeWithoutTransaction {db in
            try f.router.withValidatedDomainTransaction(db) {
                let slots: [JSON] = [["slot_id":"text","text":"Independent retained attachment use"]]
                let candidate = f.router.mediaRecord(["item_id":item["id"]!,"slots":slots,"content_signature":try MediaCanonical.signature(slots)],project:f.project,caller:f.owner,references:[try f.router.mediaRef("media_item",f.router.record(db,item["id"] as! String,type:"media_item")),try f.router.mediaRef("attachment",retained)])
                try f.router.mediaWrite(db,candidate,type:"media_candidate");return .commit
            }
        }
        _ = try cancel(f,later)
        try MediaLinkedTaskCleanupTests().done(f,task,changeStatus:false)
        let handed = try f.record(attachment["id"] as! String,"attachment")
        XCTAssertEqual(handed["media_cleanup_round_id"] as? String,later["id"] as? String)
        XCTAssertEqual(try jsonString(handed["media_capture_history"]!),originalHistory)
        _ = try worker(f,"media_round_delete",input(f,later))
        let keptAgain = try f.record(attachment["id"] as! String,"attachment")
        XCTAssertNil(keptAgain["media_cleanup_round_id"])
        XCTAssertEqual(try jsonString(keptAgain["media_capture_history"]!),originalHistory)
        XCTAssertGreaterThan(int(keptAgain,"revision"),int(handed,"revision"))
        XCTAssertEqual(keptAgain["task_id"] as? String,task["id"] as? String)
    }
}
