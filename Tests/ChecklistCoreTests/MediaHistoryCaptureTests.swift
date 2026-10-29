import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

/// Owned in-process storage only: internal media seams, no media dispatch, app or live service.
final class MediaHistoryCaptureTests: XCTestCase {
    final class Fixture {
        // The existing owned storage fixture avoids Foundation's /private/tmp ->
        // /tmp alias rewrite, which the real no-follow object walker correctly refuses.
        let storage: StorageFixture
        let base: URL, root: URL, workspace: URL
        let owner: Caller
        let router: CommandRouter
        let project: String
        init() throws {
            storage = try StorageFixture(fast:true)
            base = storage.base;root = storage.root;workspace = storage.workspace
            owner = storage.owner;router = storage.router!
            project = try storage.project()["id"] as! String
        }
        func tx<T>(_ body: (Database,ArchiveStoragePermit) throws -> T) throws -> T {
            try ArchiveStorageGate.withExclusive(root:root) { permit in try router.dbQueue.write { try body($0,permit) } }
        }
        func call(_ method: String,_ params: JSON) throws -> JSON {
            var p = params;p["command_id"] = UUID().uuidString
            return try router.handle(method:method,params:p,caller:owner)["data"] as! JSON
        }
        func save(_ type: String,_ id: String,_ fields: JSON = [:]) throws -> JSON {
            var value = fields;value["id"] = id;value["project_id"] = project;value["revision"] = 1
            if MediaRecordRegistry.families.contains(type),value["record_references"] == nil { value["record_references"] = [JSON]() }
            try tx { db,_ in try router.save(db,value,type:type) };return value
        }
        func anchor() throws -> MediaAttachmentOwner {
            try tx { db,permit in try router.createMediaAttachmentOwner(db,permit:permit,project:project,kind:.intake,caller:owner) }
        }
        func prepare(_ anchor: MediaAttachmentOwner,_ name: String,_ bytes: Data) throws -> ManagedAttachmentPreparation {
            let source = workspace.appendingPathComponent(name);try bytes.write(to:source)
            return try XCTUnwrap(router.prepareMediaAttachmentImport(project:project,owner:anchor,commandID:UUID().uuidString,path:source.path,caller:owner))
        }
        func commit(_ anchor: MediaAttachmentOwner,_ prepared: ManagedAttachmentPreparation) throws -> JSON {
            try tx { db,permit in try router.commitMediaAttachmentImport(db,permit:permit,project:project,owner:anchor,prepared:prepared,caller:owner) }
        }
        func exported(_ name: String = "export") throws -> JSON {
            let dir = base.appendingPathComponent(name)
            _ = try call("export_project",["project_id":project,"path":dir.path])
            return try JSONSerialization.jsonObject(with:Data(contentsOf:dir.appendingPathComponent("project.json"))) as! JSON
        }
        func backup(_ name: String = "backup") throws -> (URL,StorageSnapshotManifest) {
            let dir = base.appendingPathComponent(name)
            _ = try call("backup_create",["path":dir.path])
            return (dir,try JSONDecoder().decode(StorageSnapshotManifest.self,from:Data(contentsOf:dir.appendingPathComponent("manifest.json"))))
        }
        func readCopy(_ directory: URL) throws -> [DecodedEnvelope] {
            var config = Configuration();config.readonly = true;config.prepareDatabase { try SchemaMigrations.installStorageCollation($0) }
            let copy = try DatabaseQueue(path:directory.appendingPathComponent("database.sqlite").path,configuration:config)
            defer { try? copy.close() };return try copy.read { try MediaRecordRegistry.envelopes($0) }
        }
    }
    func ref(_ type: String,_ id: String,_ revision: Int = 1) -> JSON { ["type":type,"id":id,"revision":revision] }
    func testEveryRegisteredFamilyAndDraftOpenClosedHistoryRoundTrips() throws {
        let f = try Fixture(),owner = try f.anchor(),bytes = Data("immutable media original\n".utf8)
        let prepared = try f.prepare(owner,"original.txt",bytes),reference = try f.commit(owner,prepared)
        var saved: [String:JSON] = [:]
        for type in MediaRecordRegistry.families.sorted() {
            var fields: JSON = ["title":"History \u{65}\u{301}\n", "canonical_basis_base64":Data([0,13,10,255]).base64EncodedString(),"nested":["candidate_ids":["same-name-1","same-name-2"],"literal":"=not a formula"]]
            if type != "media_review_type_revision" { fields["record_references"] = [ref("media_review_type_revision","schema-v1"),ref("media_review_context","context-v1")] }
            if type == "media_review_context" { fields["record_references"] = [ref("media_review_type_revision","schema-v1")] }
            let id = type == "media_review_type_revision" ? "schema-v1" : type == "media_review_context" ? "context-v1" : "record-" + type
            saved[id] = try f.save(type,id,fields)
        }
        saved["schema-v2"] = try f.save("media_review_type_revision","schema-v2",["definition":"new optional field"])
        saved["context-v2"] = try f.save("media_review_context","context-v2",["record_references":[ref("media_review_context","context-v1")],"approved_direction":"new rule"])
        for state in ["draft","open","closed"] {
            let id = "round-" + state
            saved[id] = try f.save("media_round",id,["state":state,"record_references":[ref("media_review_type_revision","schema-v1"),ref("media_review_context","context-v1"),ref("media_round_manifest","record-media_round_manifest")]])
        }
        let preview = f.root.appendingPathComponent("objects/owned-preview.png"),previewBytes = Data([137,80,78,71,13,10])
        try previewBytes.write(to:preview)
        try f.tx { db,_ in
            var a = try f.router.record(db,prepared.attachment["id"] as! String,type:"attachment")
            a["preview_path"] = preview.path;try f.router.save(db,f.router.revised(a),type:"attachment")
        }
        _ = try f.save("attachment","external-only",["mode":"external_reference","path":f.workspace.appendingPathComponent("not-read.bin").path,
            "availability":"available","sha256":String(repeating:"a",count:64),"size":17])
        // Released ownership history and cleaned originals remain data, never fresh availability.
        let cleaned = try f.prepare(owner,"cleaned.txt",Data("cleaned".utf8));_ = try f.commit(owner,cleaned)
        try f.tx { db,_ in
            var a = try f.router.record(db,cleaned.attachment["id"] as! String,type:"attachment")
            a["availability"] = "original_cleaned";try f.router.save(db,f.router.revised(a),type:"attachment")
        }
        try FileManager.default.removeItem(at:f.router.managedURL(cleaned.attachment["path"] as! String,family:"objects"))
        let exported = try f.exported(),(backup,manifest) = try f.backup(),copy = try f.readCopy(backup)
        for type in MediaRecordRegistry.families {
            XCTAssertNotNil(EnvelopeFamily.catalog[type]);XCTAssertTrue(StorageSnapshotAuthority.knownTypes.contains(type));XCTAssertTrue(CommandRouter.diagnosticRecordTypes.contains(type));XCTAssertTrue(CommandRouter.projectExportTypes.contains(type))
            for value in exported[type] as? [JSON] ?? [] {
                XCTAssertEqual(try jsonString(value),try jsonString(saved[value["id"] as! String]!))
                let retained = try XCTUnwrap(copy.first { $0.id == value["id"] as? String && $0.type == type })
                XCTAssertEqual(try jsonString(retained.object),try jsonString(value))
            }
            XCTAssertFalse((exported[type] as! [JSON]).isEmpty,type)
        }
        let attachments = exported["attachment"] as! [JSON],a = attachments.first { $0["id"] as? String == prepared.attachment["id"] as? String }!
        XCTAssertEqual(try Data(contentsOf:f.base.appendingPathComponent("export/" + (a["path"] as! String))),bytes)
        XCTAssertEqual(try Data(contentsOf:f.base.appendingPathComponent("export/" + (a["preview_path"] as! String))),previewBytes)
        let previewObject = try XCTUnwrap(manifest.objects.first { $0.descriptor.authorities.contains("attachment:" + (a["id"] as! String) + ":preview") })
        XCTAssertEqual(try Data(contentsOf:backup.appendingPathComponent("managed/" + previewObject.descriptor.relativePath)),previewBytes)
        XCTAssertTrue(manifest.externalReferences.contains("attachment:external-only"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.base.appendingPathComponent("export/objects/external-only").path))
        XCTAssertTrue(manifest.unavailable.contains { $0.authority == "attachment:" + (cleaned.attachment["id"] as! String) && $0.reason == "original_cleaned" })
        let object = try XCTUnwrap(manifest.objects.first { $0.descriptor.authorities.contains("attachment:" + (a["id"] as! String) + ":original") })
        try FileManager.default.removeItem(at:f.router.managedURL(prepared.attachment["path"] as! String,family:"objects"))
        XCTAssertEqual(try Data(contentsOf:backup.appendingPathComponent("managed/" + object.descriptor.relativePath)),bytes)
        XCTAssertTrue((exported["storage_hold"] as! [JSON]).contains { $0["id"] as? String == reference["id"] as? String })
        XCTAssertTrue((exported["storage_job"] as! [JSON]).contains { $0["id"] as? String == owner.id })
    }
    func testPartialIntakePreservesCommittedRowsAndExplicitRemainderWithoutClaimingStaging() throws {
        let f = try Fixture(),owner = try f.anchor(),committed = try f.prepare(owner,"one.txt",Data("committed".utf8))
        let reference = try f.commit(owner,committed),pending = try f.prepare(owner,"two.txt",Data("not committed".utf8))
        _ = try f.save("media_intake_plan","plan-v1",["included_row_ids":["row-1","row-2","row-3"],"mapping_revision":1])
        _ = try f.save("media_intake_row","row-1",["state":"captured","reference_id":reference["id"]!,"record_references":[ref("storage_hold",reference["id"] as! String)]])
        _ = try f.save("media_intake_row","row-2",["state":"capturing","record_references":[ref("media_intake_plan","plan-v1")]])
        _ = try f.save("media_intake_row","row-3",["state":"failed","error_code":"SOURCE_CHANGED"])
        _ = try f.save("media_intake_chunk","chunk-1",["committed_row_ids":["row-1"],"unresolved_row_ids":["row-2","row-3"],"record_references":[ref("media_intake_row","row-1"),ref("media_intake_row","row-2"),ref("media_intake_row","row-3")]])
        _ = try f.save("media_intake","intake",["state":"partial","committed_count":1,"unresolved_row_ids":["row-2","row-3"],"record_references":[ref("media_intake_plan","plan-v1"),ref("media_intake_chunk","chunk-1")]])
        let staged = try XCTUnwrap((pending.job["objects"] as? [JSON])?.first?["stage"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent(staged).path))
        let exported = try f.exported(),(backup,manifest) = try f.backup()
        XCTAssertEqual((exported["attachment"] as! [JSON]).map { $0["id"] as! String },[committed.attachment["id"] as! String])
        XCTAssertEqual((exported["media_intake"] as! [JSON])[0]["unresolved_row_ids"] as? [String],["row-2","row-3"])
        XCTAssertEqual((exported["media_capture"] as! JSON)["uncommitted_import_job_ids"] as? [String],[pending.job["id"] as! String])
        XCTAssertEqual((exported["media_capture"] as! JSON)["staging_bytes_included"] as? Bool,false)
        XCTAssertFalse(manifest.objects.contains { $0.descriptor.relativePath.hasPrefix("staging/") })
        XCTAssertTrue(manifest.unavailable.contains { $0.reason == "uncommitted_media_capture_staging_excluded" })
        XCTAssertTrue(manifest.objects.contains { $0.descriptor.authorities.contains("storage_job:" + (pending.job["id"] as! String) + ":uncommitted_recovery:original") })
        XCTAssertFalse(manifest.objects.contains { $0.descriptor.authorities.contains("attachment:" + (pending.attachment["id"] as! String) + ":original") })
        XCTAssertFalse(FileManager.default.fileExists(atPath:backup.appendingPathComponent("managed/" + staged).path))
        XCTAssertEqual(try f.readCopy(backup).filter { $0.type == "media_intake_row" }.count,3)
        XCTAssertEqual(try Data(contentsOf:f.workspace.appendingPathComponent("two.txt")),Data("not committed".utf8))
    }
    func testUnknownRequiredFamilyAndUnknownOwnerFailVisibly() throws {
        for unknownOwner in [false,true] {
            let f = try Fixture()
            if unknownOwner { _ = try f.save("storage_job","bad-owner",["kind":"media_attachment_owner","owner_kind":"future_owner","state":"active"]) }
            else {
                try f.tx { db,_ in try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES (?,?,?,1,?)",arguments:["unknown",f.project,"media_future_required",try jsonString(["id":"unknown","project_id":f.project,"revision":1])]) }
            }
            for method in ["export_project","backup_create"] {
                let target = f.base.appendingPathComponent(method)
                XCTAssertThrowsError(try f.call(method,["project_id":f.project,"path":target.path])) { error in
                    XCTAssertTrue(["CANONICAL_RECORD_INVALID","MEDIA_CAPTURE_INCOMPLETE"].contains((error as? CoreError)?.code ?? ""))
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
            }
        }
    }
    func testMissingForeignOrChangedReferencedRevisionRefusesBothCaptures() throws {
        for mode in ["missing","foreign","changed","unknown-family"] {
            let f = try Fixture()
            _ = try f.save("media_review_type_revision","version",["definition":"original"])
            if mode == "foreign" {
                let foreign = try f.call("project_create",["name":"Other","key_prefix":"OT"])["id"] as! String
                try f.tx { db,_ in try f.router.save(db,["id":"foreign-version","project_id":foreign,"revision":1,"record_references":[JSON]()],type:"media_review_type_revision") }
            }
            let target = mode == "missing" ? "missing" : mode == "foreign" ? "foreign-version" : "version"
            _ = try f.save("media_round_manifest","manifest",["record_references":[ref(mode == "unknown-family" ? "media_unknown" : "media_review_type_revision",target,mode == "changed" ? 2 : 1)]])
            XCTAssertThrowsError(try f.exported()) { XCTAssertEqual(($0 as? CoreError)?.code,"MEDIA_CAPTURE_INCOMPLETE") }
            XCTAssertThrowsError(try f.backup()) { XCTAssertEqual(($0 as? CoreError)?.code,"MEDIA_CAPTURE_INCOMPLETE") }
        }
    }
    func testExportBoundaryHasExactScopedHoldsAndCopiesOutsideWriterTransaction() throws {
        let f = try Fixture(),owner = try f.anchor(),prepared = try f.prepare(owner,"read.txt",Data("snapshot".utf8)),reference = try f.commit(owner,prepared)
        _ = try f.save("media_round","round",["state":"open"])
        let foreign = try f.call("project_create",["name":"Foreign","key_prefix":"FO"])["id"] as! String
        try f.tx { db,_ in try f.router.save(db,["id":"foreign-round","project_id":foreign,"revision":1,"state":"draft","record_references":[JSON]()],type:"media_round") }
        let destination = f.base.appendingPathComponent("boundary")
        try ArchiveStorageGate.withExclusive(root:f.root) { permit in
            try f.router.dbQueue.writeWithoutTransaction { db in
                _ = try f.router.executeProjectExport(db,["project_id":f.project,"path":destination.path,"command_id":UUID().uuidString],f.owner,permit:permit,observe:{ point in
                    XCTAssertFalse(db.isInsideTransaction)
                    guard point == "captured" else { return }
                    let holds = try f.router.records(db,type:"storage_hold").filter { $0["purpose"] as? String == "project_export" && $0["state"] as? String == "active" }
                    XCTAssertEqual(holds.count,1);XCTAssertEqual(holds[0]["project_id"] as? String,f.project)
                    XCTAssertEqual(holds[0]["attachment_id"] as? String,prepared.attachment["id"] as? String)
                    XCTAssertEqual(holds[0]["sha256"] as? String,prepared.attachment["sha256"] as? String)
                    XCTAssertEqual(holds[0]["size"] as? Int,8)
                    try db.inTransaction {
                        var r = try f.router.record(db,reference["id"] as! String,type:"storage_hold");r["state"] = "released";try f.router.save(db,f.router.revised(r),type:"storage_hold")
                        var round = try f.router.record(db,"round",type:"media_round");round["state"] = "closed";try f.router.save(db,f.router.revised(round),type:"media_round")
                        return .commit
                    }
                    let reasons = try f.router.completeArchiveCleanupHolds(db,attachment:prepared.attachment,task:["id":"absent-task","project_id":f.project,"archived":true])
                    XCTAssertTrue(reasons.contains(.activeReader))
                })
            }
        }
        f.router.finishExportPublications(f.router.exportPublications);f.router.exportPublications = []
        let exported = try JSONSerialization.jsonObject(with:Data(contentsOf:destination.appendingPathComponent("project.json"))) as! JSON
        XCTAssertEqual((exported["media_round"] as! [JSON]).map { $0["state"] as! String },["open"])
        XCTAssertEqual((exported["storage_hold"] as! [JSON])[0]["state"] as? String,"active")
        XCTAssertFalse(try jsonString(exported).contains("foreign-round"))
        let holds = try f.router.dbQueue.read { try f.router.records($0,type:"storage_hold").filter { $0["purpose"] as? String == "project_export" } }
        XCTAssertTrue(holds.allSatisfy { $0["state"] as? String == "released" })
    }
    func testReaderLeaseSurvivesOwnershipReleaseAndRefusesForeignProject() throws {
        let f = try Fixture(),owner = try f.anchor(),prepared = try f.prepare(owner,"read.txt",Data("held".utf8)),reference = try f.commit(owner,prepared)
        let lease = try f.router.acquireMediaAttachmentReadLease(project:f.project,referenceID:reference["id"] as! String,owner:owner,caller:f.owner)
        let foreign = try f.call("project_create",["name":"Other","key_prefix":"OT"])["id"] as! String
        XCTAssertThrowsError(try f.router.acquireMediaAttachmentReadLease(project:foreign,referenceID:reference["id"] as! String,owner:owner,caller:f.owner))
        try f.tx { db,permit in
            var r = try f.router.record(db,reference["id"] as! String,type:"storage_hold");r["state"] = "released";try f.router.save(db,f.router.revised(r),type:"storage_hold")
            XCTAssertTrue(try f.router.completeArchiveCleanupHolds(db,attachment:prepared.attachment,task:["id":"absent","project_id":f.project,"archived":true]).contains(.activeReader))
            XCTAssertThrowsError(try f.router.releaseMediaReadHold(db,permit:permit,project:foreign,id:lease.id,caller:f.owner))
            try f.router.releaseMediaReadHold(db,permit:permit,project:f.project,id:lease.id,caller:f.owner)
        }
        XCTAssertEqual(try Data(contentsOf:f.router.managedURL(prepared.attachment["path"] as! String,family:"objects")),Data("held".utf8))
    }
    func testMissingAvailableOriginalAndLateReceiptFailureLeaveNoExportOrActiveHolds() throws {
        let f = try Fixture(),owner = try f.anchor(),prepared = try f.prepare(owner,"bytes.txt",Data("available".utf8));_ = try f.commit(owner,prepared)
        let path = try f.router.managedURL(prepared.attachment["path"] as! String,family:"objects")
        try FileManager.default.removeItem(at:path)
        XCTAssertThrowsError(try f.exported())
        XCTAssertThrowsError(try f.backup())
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.base.appendingPathComponent("export").path))
        try Data("available".utf8).write(to:path)
        try f.router.dbQueue.writeWithoutTransaction { try $0.execute(sql:"CREATE TEMP TRIGGER cl111_receipt_failure BEFORE INSERT ON commands BEGIN SELECT RAISE(ABORT,'owned failure');END") }
        XCTAssertThrowsError(try f.exported("receipt-failure"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.base.appendingPathComponent("receipt-failure").path))
        let holds = try f.router.dbQueue.read { try f.router.records($0,type:"storage_hold").filter { $0["purpose"] as? String == "project_export" } }
        XCTAssertEqual(holds.count,2);XCTAssertTrue(holds.allSatisfy { $0["state"] as? String == "released" })
    }
    func testImmutableRevisionsAndReceiptsCannotBeRewritten() throws {
        let f = try Fixture()
        for type in MediaRecordRegistry.immutableFamilies {
            let value = try f.save(type,"immutable-" + type,["basis":"retained"])
            try f.tx { db,_ in try f.router.save(db,value,type:type) }
            XCTAssertThrowsError(try f.save(type,"immutable-" + type,["basis":"rewritten"])) { XCTAssertEqual(($0 as? CoreError)?.code,"CANONICAL_RECORD_INVALID") }
        }
        let exported = try f.exported(),(directory,_) = try f.backup(),copy = try f.readCopy(directory)
        for type in MediaRecordRegistry.immutableFamilies {
            XCTAssertEqual((exported[type] as! [JSON])[0]["basis"] as? String,"retained")
            XCTAssertEqual(copy.first { $0.type == type }?.object["basis"] as? String,"retained")
        }
    }
    func testBackupBoundaryProtectsTasklessBytesAgainstContendingReleaseAndUnlink() throws {
        let f = try Fixture(),owner = try f.anchor(),bytes = Data("protected backup bytes".utf8)
        let prepared = try f.prepare(owner,"backup.txt",bytes),reference = try f.commit(owner,prepared)
        let parent = f.base.appendingPathComponent("protected-snapshots");try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        let identity = try f.router.dbQueue.read { db in try StoreIdentityReceipt.decode(Data(String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='store_identity'")!.utf8)) }
        let started = DispatchSemaphore(value:0),finished = DispatchSemaphore(value:0),operation = UUID()
        let contenderError = LockedTestState<Error?>(nil)
        let router = f.router, root = f.root, holdID = reference["id"] as! String
        let attachmentPath = prepared.attachment["path"] as! String
        var observed = false
        var budget = StorageSnapshotBudget(deadlineUptime:ProcessInfo.processInfo.systemUptime + 30,canceled:{false})
        budget.observe = { boundary in
            guard boundary == "backup_done",!observed else { return };observed = true
            DispatchQueue.global().async {
                started.signal()
                do {
                    try ArchiveStorageGate.withExclusive(root:root) { _ in try router.dbQueue.write { db in
                        var r = try router.record(db,holdID,type:"storage_hold");r["state"] = "released";try router.save(db,router.revised(r),type:"storage_hold")
                    } }
                    try ArchiveStorageGate.withExclusive(root:root) { _ in try FileManager.default.removeItem(at:router.managedURL(attachmentPath,family:"objects")) }
                } catch { contenderError.withLock { $0 = error } }
                finished.signal()
            }
            XCTAssertEqual(started.wait(timeout:.now()+3),.success)
            XCTAssertEqual(finished.wait(timeout:.now()+0.05),.timedOut)
        }
        let receipt = try ArchiveStorageGate.withExclusive(root:f.root) { permit in
            try StorageSnapshot.build(StorageSnapshotSource(source:f.root,parent:parent,storeID:identity.logical_store_id,permit:permit),operation:operation,budget:budget)
        }
        XCTAssertTrue(observed);XCTAssertEqual(finished.wait(timeout:.now()+5),.success);XCTAssertNil(contenderError.snapshot)
        let directory = parent.appendingPathComponent(StorageSnapshot.names(operation).published)
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:Data(contentsOf:directory.appendingPathComponent("manifest.json")))
        let object = try XCTUnwrap(manifest.objects.first { $0.descriptor.authorities.contains("attachment:" + (prepared.attachment["id"] as! String) + ":original") })
        XCTAssertEqual(try Data(contentsOf:directory.appendingPathComponent("managed/" + object.descriptor.relativePath)),bytes)
        XCTAssertEqual(try f.readCopy(directory).first { $0.id == reference["id"] as? String }?.object["state"] as? String,"active")
        XCTAssertEqual(receipt.manifestSHA256,ChecklistCore.hash(try Data(contentsOf:directory.appendingPathComponent("manifest.json"))))
    }

    func testReleasedOwnershipIdentityAndHistoricalVersionRemainExportableAfterHandover() throws {
        let f = try Fixture(),source = try f.anchor(),prepared = try f.prepare(source,"handover.txt",Data("history".utf8)),reference = try f.commit(source,prepared)
        let referenceID = reference["id"] as! String
        _ = try f.save("media_intake_row","captured-row",["state":"captured","record_references":[["type":"storage_hold","id":referenceID]]])
        _ = try f.save("media_item_target","target-v1",["basis":"original","record_references":[["type":"attachment","id":prepared.attachment["id"]!]]])
        let target = try f.tx { db,permit in try f.router.createMediaAttachmentOwner(db,permit:permit,project:f.project,kind:.target,caller:f.owner) }
        let originals = try f.router.prepareOwnedAttachmentOriginals(project:f.project,owner:source,referenceIDs:[referenceID],caller:f.owner)
        _ = try f.tx { db,permit in try f.router.transferMediaAttachmentReferences(db,permit:permit,project:f.project,source:source,referenceIDs:[referenceID],destination:target,prepared:originals,caller:f.owner,commitManifest:{ _ in }) }
        let exported = try f.exported(),(directory,_) = try f.backup(),copy = try f.readCopy(directory)
        XCTAssertEqual((exported["storage_hold"] as! [JSON]).first { $0["id"] as? String == referenceID }?["state"] as? String,"released")
        XCTAssertEqual(copy.first { $0.id == referenceID }?.object["state"] as? String,"released")
        XCTAssertEqual((exported["media_intake_row"] as! [JSON])[0]["state"] as? String,"captured")
        // A historical target cannot silently degrade to an identity-only reference.
        _ = try f.save("media_round","missing-version",["record_references":[["id":"target-v1","type":"media_item_target"]]])
        XCTAssertThrowsError(try f.exported("bad-reference")) { XCTAssertEqual(($0 as? CoreError)?.code,"MEDIA_CAPTURE_INCOMPLETE") }
    }

    func testAvailableOriginalCannotSilentlyOmitRequiredByteMetadata() throws {
        let f = try Fixture()
        _ = try f.save("attachment","pathless-original",["mode":"managed","availability":"available","sha256":String(repeating:"a",count:64),"size":1])
        XCTAssertThrowsError(try f.exported()) { XCTAssertEqual(($0 as? CoreError)?.code,"MEDIA_CAPTURE_INCOMPLETE") }
        XCTAssertThrowsError(try f.backup())
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.base.appendingPathComponent("export").path))
    }

    func testRequiredKnownButNonportableDependencyFailsInsteadOfBeingDropped() throws {
        let f = try Fixture()
        _ = try f.save("cleanup_preview","runtime-only")
        _ = try f.save("media_item","item",["record_references":[ref("cleanup_preview","runtime-only")]])
        XCTAssertThrowsError(try f.exported()) { XCTAssertEqual(($0 as? CoreError)?.code,"MEDIA_CAPTURE_INCOMPLETE") }
        let (directory,_) = try f.backup()
        XCTAssertTrue(try f.readCopy(directory).contains { $0.id == "runtime-only" })
    }

}
