import XCTest
import GRDB
import Darwin
@testable import ChecklistCore

/// Actual shared importer, canonical transactions, object gate and cleanup executor;
/// all stores/sources are owned synthetic fixtures with a real existing parent.
final class AttachmentOwnershipTests: XCTestCase {
    private func canceledImport(atGate boundary: Int, afterGate: Bool = false, beforeFinalization: Bool = false) throws {
        let f = try StorageFixture(), p = try f.project(), o = try anchor(f,p,.intake), pid = p["id"] as! String
        let source = f.workspace.appendingPathComponent("original.bin"), bytes = Data(repeating:91,count:8192)
        try bytes.write(to:source)
        let command = UUID().uuidString
        let params: JSON = ["project_id":pid,"command_id":command,"path":source.path,"owner_id":o.id,"owner_kind":o.kind.rawValue,"owner_revision":o.revision]
        var access: CommandRouter.ManagedImportAccess? = f.router!.managedImportAccessOutsideWriter()
        var gateCount = 0, writeCount = 0, receipt: JSON?
        func cancel() throws { receipt = try f.router!.cancelMediaAttachmentImport(project:pid,owner:o,commandID:command,caller:f.owner) }
        var interleaved: CommandRouter.ManagedImportAccess? = .init(read:access!.read,write: { body in
            writeCount += 1
            if beforeFinalization && writeCount == 3 { try cancel() }
            try access!.write(body)
        },underGate: { body in
            gateCount += 1
            if !beforeFinalization && gateCount == boundary && !afterGate { try cancel() }
            try access!.underGate(body)
            if !beforeFinalization && gateCount == boundary && afterGate { try cancel() }
        })
        XCTAssertThrowsError(try f.router!.prepareManagedAttachmentImport(method:"internal_media_attachment_capture",params:params,caller:f.owner,access:interleaved!,mediaOwner:o)) { error in
            XCTAssertEqual((error as? CoreError)?.code,"MANAGED_IMPORT_CANCELED")
        }
        let canceled = try XCTUnwrap(receipt)
        XCTAssertEqual(canceled["state"] as? String,"canceled")
        let published = afterGate || beforeFinalization
        XCTAssertEqual(canceled["reclaimed_staging_logical_bytes"] as? Int,boundary == 1 && !beforeFinalization ? 0 : bytes.count)
        XCTAssertEqual(canceled["retained_final_logical_bytes"] as? Int,published ? bytes.count : 0)
        XCTAssertEqual(canceled["unavailable_staging_count"] as? Int,boundary <= 2 && !beforeFinalization ? 1 : 0)
        XCTAssertEqual(canceled["unavailable_final_count"] as? Int,published ? 0 : 1)
        XCTAssertEqual(canceled["physical_reclamation"] as? String,"unmeasured")
        XCTAssertEqual(try jsonString(canceled),try jsonString(f.router!.cancelMediaAttachmentImport(project:pid,owner:o,commandID:command,caller:f.owner)))
        let key = try f.router!.managedImportKey(principal:f.owner.principal,command:command)
        let job = try get(f,key,"storage_job"), object = try XCTUnwrap(f.router!.managedImportObjects(job).first)
        let stage = f.root.appendingPathComponent(object["stage"] as! String), final = f.root.appendingPathComponent(object["final"] as! String)
        XCTAssertEqual(job["state"] as? String,"settled")
        XCTAssertEqual(job["settled_reason"] as? String,"canceled_media_staging")
        XCTAssertFalse(FileManager.default.fileExists(atPath:stage.path))
        XCTAssertEqual(FileManager.default.fileExists(atPath:final.path),published)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath:stage.deletingLastPathComponent().path)) ?? [],[])
        XCTAssertEqual(try Data(contentsOf:source),bytes)
        XCTAssertThrowsError(try f.router!.prepareMediaAttachmentImport(project:pid,owner:o,commandID:command,path:source.path,caller:f.owner))
        interleaved = nil; access = nil
        try f.reopen()
        XCTAssertFalse(FileManager.default.fileExists(atPath:stage.path))
        XCTAssertEqual(FileManager.default.fileExists(atPath:final.path),published)
        XCTAssertEqual(try get(f,key,"storage_job")["state"] as? String,"settled")
        XCTAssertEqual(try Data(contentsOf:source),bytes)
    }
    func testCancelBeforePartialCreationFencesPreparation() throws { try canceledImport(atGate:1) }
    func testCancelBetweenPartialWriteAndStagePublicationFencesPreparation() throws { try canceledImport(atGate:2) }
    func testCancelBeforeFinalLinkFencesPreparation() throws { try canceledImport(atGate:3) }
    func testCancelAfterPublicationRetainsOnlyReportedFinalBytes() throws { try canceledImport(atGate:3,afterGate:true) }
    func testCancelBeforeFinalizationCannotRecordFinalized() throws { try canceledImport(atGate:3,beforeFinalization:true) }
    func testCancelCleanupFailureKeepsFenceAndStartupRemovesOnlyOwnedStaging() throws {
        let f = try StorageFixture(), p = try f.project(), o = try anchor(f,p,.intake), pid = p["id"] as! String
        let source = f.workspace.appendingPathComponent("original.bin"), bytes = Data(repeating:37,count:64)
        try bytes.write(to:source)
        let command = UUID().uuidString
        let prepared = try XCTUnwrap(f.router!.prepareMediaAttachmentImport(project:pid,owner:o,commandID:command,path:source.path,caller:f.owner))
        let object = try XCTUnwrap(f.router!.managedImportObjects(prepared.job).first)
        let stage = f.root.appendingPathComponent(object["stage"] as! String), final = f.root.appendingPathComponent(object["final"] as! String)
        try FileManager.default.removeItem(at:stage)
        try FileManager.default.createSymbolicLink(at:stage,withDestinationURL:source)
        let partial = URL(fileURLWithPath:stage.path + ".partial-" + UUID().uuidString)
        let unrelated = stage.deletingLastPathComponent().appendingPathComponent("unrelated.partial-not-a-uuid")
        try Data(repeating:1,count:5).write(to:partial)
        try Data(repeating:2,count:7).write(to:unrelated)
        // Receipt lengths must describe observed files even if their descriptor differs.
        try Data(repeating:3,count:17).write(to:final)
        XCTAssertThrowsError(try f.router!.cancelMediaAttachmentImport(project:pid,owner:o,commandID:command,caller:f.owner))
        let fenced = try get(f,prepared.job["id"] as! String,"storage_job")
        XCTAssertEqual(fenced["settled_reason"] as? String,"canceled_media_staging")
        XCTAssertEqual(fenced["cancellation_cleanup_complete"] as? Bool,false)
        XCTAssertThrowsError(try f.router!.prepareMediaAttachmentImport(project:pid,owner:o,commandID:command,path:source.path,caller:f.owner))
        XCTAssertThrowsError(try tx(f) { db,permit in try f.router!.commitMediaAttachmentImport(db,permit:permit,project:pid,owner:o,prepared:prepared,caller:f.owner) })
        XCTAssertEqual(try Data(contentsOf:source),bytes)
        // Remove only the unsafe synthetic obstruction; startup owns the pending cleanup.
        try FileManager.default.removeItem(at:stage)
        try f.reopen()
        let recovered = try get(f,prepared.job["id"] as! String,"storage_job")
        XCTAssertEqual(recovered["cancellation_cleanup_complete"] as? Bool,true)
        let receipt = try XCTUnwrap(recovered["cancellation_receipt"] as? JSON)
        XCTAssertEqual(receipt["reclaimed_staging_logical_bytes"] as? Int,5)
        XCTAssertEqual(receipt["retained_final_logical_bytes"] as? Int,17)
        XCTAssertEqual(receipt["unavailable_staging_count"] as? Int,1)
        XCTAssertEqual(receipt["unavailable_final_count"] as? Int,0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:partial.path))
        XCTAssertEqual(try Data(contentsOf:unrelated),Data(repeating:2,count:7))
        XCTAssertEqual(try Data(contentsOf:source),bytes)
    }
    func tx<T>(_ f: StorageFixture,_ body: (Database,ArchiveStoragePermit) throws -> T) throws -> T {
        try ArchiveStorageGate.withExclusive(root:f.root) { permit in try f.router!.dbQueue.write { db in try body(db,permit) } }
    }
    func anchor(_ f: StorageFixture,_ p: JSON,_ kind: MediaAttachmentOwnerKind) throws -> MediaAttachmentOwner {
        try tx(f) { db,permit in try f.router!.createMediaAttachmentOwner(db,permit:permit,project:p["id"] as! String,kind:kind,caller:f.owner) }
    }
    func fixture() throws -> (StorageFixture,JSON,JSON,JSON) {
        let f = try StorageFixture();var p = try f.project();let t = try f.task(p)
        p = try f.call("archive_storage_settings",["project_id":p["id"]!,"expected_revision":p["revision"]!,"settings_revision":p["settings_revision"]!,"archive_storage":["preset":"clean_large_managed_on_archive","large_original_bytes":1,"retained_budget_bytes":0]])["data"] as! JSON
        let source = f.workspace.appendingPathComponent("source.bin");try Data(repeating:37,count:128).write(to:source)
        let a = try f.call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path])["data"] as! JSON
        return (f,p,t,a)
    }
    func adopt(_ f: StorageFixture,_ p: JSON,_ a: JSON,_ owner: MediaAttachmentOwner) throws -> JSON {
        let prepared = try f.router!.prepareAttachmentOriginals(project:p["id"] as! String,attachmentIDs:[a["id"] as! String],caller:f.owner)
        return try tx(f) { db,permit in try f.router!.adoptTaskAttachments(db,permit:permit,project:p["id"] as! String,owner:owner,prepared:prepared,caller:f.owner)[0] }
    }
    func archiveAndDue(_ f: StorageFixture,_ p: JSON,_ t: JSON) throws -> JSON {
        let preview = try f.call("attachment_cleanup_preview",["project_id":p["id"]!,"task_id":t["id"]!])["data"] as! JSON
        _ = try f.call("task_archive",["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!,"action":"archive","cleanup":true,"cleanup_preview_id":preview["cleanup_preview_id"]!])
        return try tx(f) { db,_ in
            var job = try XCTUnwrap(f.router!.records(db,type:"cleanup_job",project:p["id"] as? String).last)
            job["enqueued_at_ms"] = Int64(1);job["not_before_ms"] = Int64(2);job["revision"] = try f.router!.nextCleanupJobRevision(job);try f.router!.save(db,job,type:"cleanup_job");return job
        }
    }
    func get(_ f: StorageFixture,_ id: String,_ type: String) throws -> JSON { try f.router!.dbQueue.read { try f.router!.record($0,id,type:type) } }
    func testTasklessAccessRequiresExactCurrentSameProjectOwnerAndReference() throws {
        let (f,p,_,a) = try fixture(),owner = try anchor(f,p,.draftItem),reference = try adopt(f,p,a,owner),pid = p["id"] as! String
        XCTAssertEqual(try f.router!.readMediaAttachment(project:pid,referenceID:reference["id"] as! String,owner:owner,caller:f.owner),Data(repeating:37,count:128))
        let other = try anchor(f,p,.draftItem)
        for probe in [a["id"] as! String,a["path"] as! String,a["sha256"] as! String,"media_target"] {
            XCTAssertThrowsError(try f.router!.acquireMediaAttachmentReadLease(project:pid,referenceID:probe,owner:owner,caller:f.owner))
        }
        XCTAssertThrowsError(try f.router!.acquireMediaAttachmentReadLease(project:pid,referenceID:reference["id"] as! String,owner:other,caller:f.owner))
        let foreign = try f.call("project_create",["name":"Other","key_prefix":"OT"])["data"] as! JSON
        XCTAssertThrowsError(try f.router!.acquireMediaAttachmentReadLease(project:foreign["id"] as! String,referenceID:reference["id"] as! String,owner:owner,caller:f.owner))
        try tx(f) { db,_ in var r = try f.router!.record(db,owner.id,type:"storage_job");r["state"] = "released";try f.router!.save(db,f.router!.revised(r),type:"storage_job") }
        XCTAssertThrowsError(try f.router!.readMediaAttachment(project:pid,referenceID:reference["id"] as! String,owner:owner,caller:f.owner))
    }
    func testUnregisteredRevokedOrWrongWorkspaceCannotUseOwnedReferences() throws {
        let (f,p,_,a) = try fixture(),o = try anchor(f,p,.draftItem),r = try adopt(f,p,a,o),pid = p["id"] as! String
        let absent = Caller(role:"worker",installation:"missing",projectIDs:[pid],sessionID:"unknown",workspace:f.workspace.path)
        XCTAssertThrowsError(try f.router!.readMediaAttachment(project:pid,referenceID:r["id"] as! String,owner:o,caller:absent))
        let sid = UUID().uuidString
        try tx(f) { db,_ in try f.router!.save(db,["id":sid,"project_id":pid,"project_ids":[pid],"state":"revoked","authorization_generation":"old","revision":1],type:"session") }
        let revoked = Caller(role:"worker",installation:"revoked",projectIDs:[pid],sessionID:sid,workspace:f.workspace.path)
        XCTAssertThrowsError(try f.router!.readMediaAttachment(project:pid,referenceID:r["id"] as! String,owner:o,caller:revoked))
        let wrong = Caller(role:"worker",installation:"wrong",projectIDs:[pid],sessionID:sid,workspace:f.base.path)
        XCTAssertThrowsError(try f.router!.readMediaAttachment(project:pid,referenceID:r["id"] as! String,owner:o,caller:wrong))
    }
    func testPublicationBeforeCleanupRetainsExactOriginalAndReleasesOnlySourceReference() throws {
        let (f,p,t,a) = try fixture()
        _ = try archiveAndDue(f,p,t)
        let source = try anchor(f,p,.draftItem),r = try adopt(f,p,a,source),target = try anchor(f,p,.target),pid = p["id"] as! String
        let prepared = try f.router!.prepareOwnedAttachmentOriginals(project:pid,owner:source,referenceIDs:[r["id"] as! String],caller:f.owner)
        let manifestID = UUID().uuidString
        let published = try tx(f) { db,permit in try f.router!.transferMediaAttachmentReferences(db,permit:permit,project:pid,source:source,referenceIDs:[r["id"] as! String],destination:target,prepared:prepared,caller:f.owner) { references in
            XCTAssertEqual(try f.router!.record(db,r["id"] as! String,type:"storage_hold")["state"] as? String,"active")
            XCTAssertEqual(references[0]["state"] as? String,"active")
            try f.router!.save(db,["id":manifestID,"project_id":pid,"revision":1,"attachment_reference_ids":references.map { $0["id"]! }],type:"manifest")
        } }
        XCTAssertEqual(try get(f,r["id"] as! String,"storage_hold")["state"] as? String,"released")
        try f.router!.runStorageMaintenance()
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
        XCTAssertEqual(try f.router!.readMediaAttachment(project:pid,referenceID:published.1[0]["id"] as! String,owner:published.0,caller:f.owner),Data(repeating:37,count:128))
        XCTAssertEqual((try get(f,manifestID,"manifest")["attachment_reference_ids"] as? [String])?.count,1)
        XCTAssertThrowsError(try tx(f) { db,permit in try f.router!.transferMediaAttachmentReferences(db,permit:permit,project:pid,source:source,referenceIDs:[r["id"] as! String],destination:published.0,prepared:prepared,caller:f.owner,commitManifest:{_ in}) })
    }
    func testCleanupBeforeAdoptionRefusesAbsentBytesAndPreservesPriorManifest() throws {
        let (f,p,t,a) = try fixture(),o = try anchor(f,p,.draftItem),pid = p["id"] as! String
        let prepared = try f.router!.prepareAttachmentOriginals(project:pid,attachmentIDs:[a["id"] as! String],caller:f.owner)
        _ = try archiveAndDue(f,p,t);try f.router!.runStorageMaintenance()
        XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String))
        let before = try f.router!.dbQueue.read { try f.router!.records($0,type:"storage_hold",project:pid).count }
        XCTAssertThrowsError(try tx(f) { db,permit in try f.router!.adoptTaskAttachments(db,permit:permit,project:pid,owner:o,prepared:prepared,caller:f.owner) })
        XCTAssertEqual(try f.router!.dbQueue.read { try f.router!.records($0,type:"storage_hold",project:pid).count },before)
    }
    func testLateManifestAndReceiptFailureRollbackWholeHandover() throws {
        let (f,p,_,a) = try fixture(),source = try anchor(f,p,.intake),r = try adopt(f,p,a,source),target = try anchor(f,p,.target),pid = p["id"] as! String
        let prepared = try f.router!.prepareOwnedAttachmentOriginals(project:pid,owner:source,referenceIDs:[r["id"] as! String],caller:f.owner)
        let count = try f.router!.dbQueue.read { try f.router!.records($0,type:"storage_hold",project:pid).count }
        let manifest = UUID().uuidString
        for late in [false,true] {
            XCTAssertThrowsError(try tx(f) { db,permit in
                _ = try f.router!.transferMediaAttachmentReferences(db,permit:permit,project:pid,source:source,referenceIDs:[r["id"] as! String],destination:target,prepared:prepared,caller:f.owner) { refs in
                    try f.router!.save(db,["id":manifest,"project_id":pid,"revision":1,"references":refs.map { $0["id"]! }],type:"manifest")
                    if !late { throw CoreError("SQLITE_FULL","Owned injected full-disk boundary") }
                }
                // Equivalent late command-receipt failure: the transaction must roll back the transfer too.
                throw CoreError("SQLITE_IOERR","Owned injected receipt failure")
            })
            XCTAssertEqual(try get(f,r["id"] as! String,"storage_hold")["state"] as? String,"active")
            XCTAssertEqual(try get(f,target.id,"storage_job")["state"] as? String,"draft")
            XCTAssertThrowsError(try get(f,manifest,"manifest"))
            XCTAssertEqual(try f.router!.dbQueue.read { try f.router!.records($0,type:"storage_hold",project:pid).count },count)
        }
    }
    func testPreparedBytesChangedAndExternalReferenceNeverPublish() throws {
        let (f,p,_,a) = try fixture(),o = try anchor(f,p,.draftItem),pid = p["id"] as! String
        let prepared = try f.router!.prepareAttachmentOriginals(project:pid,attachmentIDs:[a["id"] as! String],caller:f.owner)
        try Data(repeating:99,count:128).write(to:URL(fileURLWithPath:a["path"] as! String))
        XCTAssertThrowsError(try tx(f) { db,permit in try f.router!.adoptTaskAttachments(db,permit:permit,project:pid,owner:o,prepared:prepared,caller:f.owner) })
        var external = a;external["mode"] = "external_reference"
        XCTAssertThrowsError(try f.router!.prepareAttachmentOriginal(external))
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.workspace.appendingPathComponent("source.bin").path))
    }
    func testReaderBackupAndKeepOriginalHoldsSurviveReferenceRelease() throws {
        let (f,p,t,a) = try fixture()
        _ = try archiveAndDue(f,p,t)
        let o = try anchor(f,p,.draftItem),r = try adopt(f,p,a,o),pid = p["id"] as! String
        let lease = try f.router!.acquireMediaAttachmentReadLease(project:pid,referenceID:r["id"] as! String,owner:o,caller:f.owner)
        try tx(f) { db,_ in
            var ref = try f.router!.record(db,r["id"] as! String,type:"storage_hold");ref["state"] = "released";try f.router!.save(db,f.router!.revised(ref),type:"storage_hold")
            try f.router!.save(db,["id":UUID().uuidString,"kind":"backup","state":"active","attachment_id":a["id"]!,"revision":1],type:"storage_hold")
        }
        let kept = try f.call("attachment_update",["project_id":pid,"attachment_id":a["id"]!,"expected_revision":a["revision"]!,"action":"keep_original"])["data"] as! JSON
        try f.router!.runStorageMaintenance()
        let reasons = try f.router!.dbQueue.read { db in try f.router!.completeArchiveCleanupHolds(db,attachment:kept,task:f.router!.record(db,t["id"] as! String,type:"task")) }
        XCTAssertTrue(reasons.contains(.activeReader));XCTAssertTrue(reasons.contains(.backupCapture));XCTAssertTrue(reasons.contains(.keepOriginal))
        XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
        XCTAssertEqual(lease.attachment["sha256"] as? String,a["sha256"] as? String)
        try tx(f) { db,permit in try f.router!.releaseMediaReadHold(db,permit:permit,project:pid,id:lease.id,caller:f.owner) }
        XCTAssertEqual(try get(f,lease.id,"storage_hold")["state"] as? String,"released")
    }
    func testTasklessCaptureUsesExistingImporterNoTaskAndCancelPreservesExternalSource() throws {
        let f = try StorageFixture(),p = try f.project(),o = try anchor(f,p,.intake),pid = p["id"] as! String
        let source = f.workspace.appendingPathComponent("media.bin"),bytes = Data(repeating:17,count:64);try bytes.write(to:source)
        let command = UUID().uuidString
        let prepared = try XCTUnwrap(f.router!.prepareMediaAttachmentImport(project:pid,owner:o,commandID:command,path:source.path,caller:f.owner))
        XCTAssertNil(prepared.attachment["task_id"]);XCTAssertEqual(prepared.job["attachment_owner_id"] as? String,o.id)
        XCTAssertEqual(try f.router!.dbQueue.read { try f.router!.records($0,type:"task",project:pid).count },0)
        let receipt = try f.router!.cancelMediaAttachmentImport(project:pid,owner:o,commandID:command,caller:f.owner)
        XCTAssertEqual(receipt["reclaimed_staging_logical_bytes"] as? Int,64);XCTAssertEqual(receipt["retained_final_logical_bytes"] as? Int,64)
        XCTAssertEqual(try Data(contentsOf:source),bytes)
        XCTAssertThrowsError(try tx(f) { db,permit in try f.router!.commitMediaAttachmentImport(db,permit:permit,project:pid,owner:o,prepared:prepared,caller:f.owner) })
    }
    func testTasklessCaptureCommitAndSourceDisappearanceRetry() throws {
        let f = try StorageFixture(),p = try f.project(),o = try anchor(f,p,.draftItem),pid = p["id"] as! String
        let source = f.workspace.appendingPathComponent("media.bin");try Data(repeating:19,count:128).write(to:source)
        let command = UUID().uuidString,first = try XCTUnwrap(f.router!.prepareMediaAttachmentImport(project:pid,owner:o,commandID:command,path:source.path,caller:f.owner))
        try FileManager.default.removeItem(at:source)
        let second = try XCTUnwrap(f.router!.prepareMediaAttachmentImport(project:pid,owner:o,commandID:command,path:source.path,caller:f.owner))
        XCTAssertEqual(first.attachment["id"] as? String,second.attachment["id"] as? String)
        let reference = try tx(f) { db,permit in try f.router!.commitMediaAttachmentImport(db,permit:permit,project:pid,owner:o,prepared:second,caller:f.owner) }
        XCTAssertEqual(try f.router!.readMediaAttachment(project:pid,referenceID:reference["id"] as! String,owner:o,caller:f.owner),Data(repeating:19,count:128))
        XCTAssertThrowsError(try f.call("attachment_read",["project_id":pid,"attachment_id":second.attachment["id"]!,"representation":"original"]))
        XCTAssertEqual((try f.call("export_project",["project_id":pid,"path":f.base.appendingPathComponent("owned-export").path])["data"] as? JSON)?["format"] as? String,"checklist-project")
        XCTAssertThrowsError(try f.call("internal_media_attachment_capture",["project_id":pid]))
    }
    func testSameGateSerializesPublicationAndContendingCleanup() throws {
        let (f,p,t,a) = try fixture();let job = try archiveAndDue(f,p,t)
        let source = try anchor(f,p,.draftItem),r = try adopt(f,p,a,source),target = try anchor(f,p,.target),pid = p["id"] as! String
        let prepared = try f.router!.prepareOwnedAttachmentOriginals(project:pid,owner:source,referenceIDs:[r["id"] as! String],caller:f.owner)
        let router = try XCTUnwrap(f.router) // Joined below before fixture teardown.
        let entered = DispatchSemaphore(value:0),finished = DispatchSemaphore(value:0)
        var published: (MediaAttachmentOwner,[JSON])!
        try ArchiveStorageGate.withExclusive(root:f.root) { permit in
            DispatchQueue.global().async { entered.signal();defer { finished.signal() };try? router.runStorageMaintenance() }
            XCTAssertEqual(entered.wait(timeout:.now()+3),.success)
            XCTAssertEqual(finished.wait(timeout:.now()+0.05),.timedOut)
            published = try f.router!.dbQueue.write { db in
                try f.router!.transferMediaAttachmentReferences(db,permit:permit,project:pid,source:source,referenceIDs:[r["id"] as! String],destination:target,prepared:prepared,caller:f.owner,commitManifest:{ _ in })
            }
        }
        XCTAssertEqual(finished.wait(timeout:.now()+5),.success)
        let final = try ArchiveCleanupJob(record:get(f,job["id"] as! String,"cleanup_job"))
        XCTAssertTrue(final.items[0].holds.contains(.sharedLiveReference));XCTAssertEqual(final.state,.held)
        XCTAssertEqual(try f.router!.readMediaAttachment(project:pid,referenceID:published.1[0]["id"] as! String,owner:published.0,caller:f.owner),Data(repeating:37,count:128))
    }
    func testAdoptionReplacesSourceReaderHoldAndWrongLeaseRollsBack() throws {
        let (f,p,_,a) = try fixture(),o = try anchor(f,p,.intake),pid = p["id"] as! String
        let read = try f.call("attachment_read",["project_id":pid,"attachment_id":a["id"]!,"representation":"original"])["data"] as! JSON
        let holdID = read["read_hold_id"] as! String
        let prepared = try f.router!.prepareAttachmentOriginals(project:pid,attachmentIDs:[a["id"] as! String],caller:f.owner)
        XCTAssertThrowsError(try tx(f) { db,permit in try f.router!.adoptTaskAttachments(db,permit:permit,project:pid,owner:o,prepared:prepared,caller:f.owner,releaseReadHoldIDs:["foreign"]) })
        XCTAssertEqual(try f.router!.dbQueue.read { try f.router!.records($0,type:"storage_hold",project:pid).filter { $0["kind"] as? String == "media_reference" }.count },0)
        let refs = try tx(f) { db,permit in try f.router!.adoptTaskAttachments(db,permit:permit,project:pid,owner:o,prepared:prepared,caller:f.owner,releaseReadHoldIDs:[holdID]) }
        XCTAssertEqual(refs[0]["state"] as? String,"active");XCTAssertEqual(try get(f,holdID,"storage_hold")["state"] as? String,"released")
    }
    func testInterruptedCaptureRollbackChangedFinalAndSafeCancel() throws {
        let f = try StorageFixture(),p = try f.project(),o = try anchor(f,p,.intake),pid = p["id"] as! String
        let source = f.workspace.appendingPathComponent("original.bin"),bytes = Data(repeating:7,count:256);try bytes.write(to:source)
        let command = UUID().uuidString,prepared = try XCTUnwrap(f.router!.prepareMediaAttachmentImport(project:pid,owner:o,commandID:command,path:source.path,caller:f.owner))
        XCTAssertThrowsError(try tx(f) { db,permit in
            _ = try f.router!.commitMediaAttachmentImport(db,permit:permit,project:pid,owner:o,prepared:prepared,caller:f.owner)
            throw CoreError("INTERRUPTED","Owned failure after attachment/reference write")
        })
        XCTAssertThrowsError(try get(f,prepared.attachment["id"] as! String,"attachment"))
        XCTAssertEqual(try get(f,prepared.job["id"] as! String,"storage_job")["state"] as? String,"finalized")
        // A same-size replacement after hashing cannot be published as the earlier bytes.
        try Data(repeating:8,count:256).write(to:f.router!.managedURL(prepared.attachment["path"] as! String,family:"objects"))
        XCTAssertThrowsError(try tx(f) { db,permit in try f.router!.commitMediaAttachmentImport(db,permit:permit,project:pid,owner:o,prepared:prepared,caller:f.owner) })
        let original = (prepared.job["objects"] as! [JSON]).first { $0["representation"] as? String == "original" }!,stage = f.root.appendingPathComponent(original["stage"] as! String)
        try FileManager.default.removeItem(at:stage);try FileManager.default.createSymbolicLink(at:stage,withDestinationURL:source)
        XCTAssertThrowsError(try f.router!.cancelMediaAttachmentImport(project:pid,owner:o,commandID:command,caller:f.owner))
        XCTAssertEqual(try Data(contentsOf:source),bytes)
    }

    func testPublicationRefusesAnIntermediateSymlinkEvenWhenFileIdentityMatches() throws {
        let (f,p,_,a) = try fixture(),o = try anchor(f,p,.draftItem),pid = p["id"] as! String
        let prepared = try f.router!.prepareAttachmentOriginals(project:pid,attachmentIDs:[a["id"] as! String],caller:f.owner)
        let directory = URL(fileURLWithPath:a["path"] as! String).deletingLastPathComponent(),moved = directory.deletingLastPathComponent().appendingPathComponent("retained-" + UUID().uuidString)
        try FileManager.default.moveItem(at:directory,to:moved);try FileManager.default.createSymbolicLink(at:directory,withDestinationURL:moved)
        XCTAssertEqual(FileIdentity(path:a["path"] as! String),prepared[0].identity)
        XCTAssertThrowsError(try tx(f) { db,permit in try f.router!.adoptTaskAttachments(db,permit:permit,project:pid,owner:o,prepared:prepared,caller:f.owner) })
        XCTAssertEqual(try f.router!.dbQueue.read { try f.router!.records($0,type:"storage_hold",project:pid).filter { $0["kind"] as? String == "media_reference" }.count },0)
    }
    func testCurrentRegisteredWorkerReadsWithoutOwningOrPublishingTheTarget() throws {
        let (f,p,_,a) = try fixture(),o = try anchor(f,p,.draftItem),r = try adopt(f,p,a,o),pid = p["id"] as! String,sid = UUID().uuidString
        try tx(f) { db,_ in try f.router!.save(db,["id":sid,"project_id":pid,"project_ids":[pid],"state":"active","authorization_generation":"current","revision":1],type:"session") }
        let worker = Caller(role:"worker",installation:"reader",projectIDs:[pid],sessionID:sid,workspace:f.workspace.path)
        XCTAssertEqual(try f.router!.readMediaAttachment(project:pid,referenceID:r["id"] as! String,owner:o,caller:worker),Data(repeating:37,count:128))
        XCTAssertThrowsError(try tx(f) { db,permit in try f.router!.createMediaAttachmentOwner(db,permit:permit,project:pid,kind:.target,caller:worker) })
    }

}
