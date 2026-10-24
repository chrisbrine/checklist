import Foundation
import GRDB
import Darwin

/// Internal storage ownership, not a media round or an authorization supplied by a type name.
/// No method in this file is in the MCP/native dispatch catalog. Media activation waits for
/// the lossless history registry and the complete owner slice (CL-111/112/113).
enum MediaAttachmentOwnerKind: String { case intake = "media_intake", draftItem = "media_draft_item", target = "media_target" }
struct MediaAttachmentOwner {
    let id: String
    let kind: MediaAttachmentOwnerKind
    let revision: Int
}
struct PreparedAttachmentOriginal {
    let attachment: JSON
    let identity: FileIdentity
}
struct MediaAttachmentReadLease {
    let id: String
    let attachment: JSON
    let expiresAt: Date
}

extension CommandRouter {
    /// The future media transaction creates its storage anchor together with its domain record.
    /// An anchor alone never represents a published round, accepted decision or permission to import.
    func createMediaAttachmentOwner(_ db: Database, permit: ArchiveStoragePermit, project: String,
                                    kind: MediaAttachmentOwnerKind, caller: Caller) throws -> MediaAttachmentOwner {
        try requireMediaStorageTransaction(db,permit:permit)
        _ = try scope(db,["project_id":project],caller,write:true)
        try worker(caller)
        if !caller.isOwner {
            guard caller.sessionID != nil else { throw CoreError("FORBIDDEN","A current worker session is required.") }
            _ = try callerSessionGeneration(db,caller,project:project)
        }
        if kind == .target { try owner(caller) }
        let id = uuid()
        try save(db,["id":id,"project_id":project,"kind":"media_attachment_owner","owner_kind":kind.rawValue,
                     "state":kind == .target ? "draft" : "active","revision":1,"author":caller.principal,"created_at":now()],type:"storage_job")
        return .init(id:id,kind:kind,revision:1)
    }
    func requireMediaStorageTransaction(_ db: Database, permit: ArchiveStoragePermit) throws {
        try permit.requireRoot(root)
        guard db.isInsideTransaction else { throw CoreError("STORAGE_TRANSACTION_REQUIRED","Ownership must commit with the canonical command and manifest.") }
    }
    func mediaAttachmentOwner(_ db: Database, project: String, owner: MediaAttachmentOwner, caller: Caller, write: Bool = false) throws -> JSON {
        _ = try scope(db,["project_id":project],caller,write:write)
        guard caller.role != "assistant" else { throw CoreError("FORBIDDEN","Media storage is not an assistant capability.") }
        if !caller.isOwner {
            guard caller.sessionID != nil else { throw CoreError("FORBIDDEN","A current registered worker session is required.") }
            _ = try callerSessionGeneration(db,caller,project:project)
        }
        let record = try scoped(db,owner.id,project,type:"storage_job")
        guard record["kind"] as? String == "media_attachment_owner", record["owner_kind"] as? String == owner.kind.rawValue,
              int(record,"revision") == owner.revision, ["active","draft","published"].contains(record["state"] as? String ?? "") else { throw CoreError("ATTACHMENT_OWNER_STALE","The current same-project owner reference is required.") }
        if write && (owner.kind == .target || !EnvelopeStorageIdentity.equal(record["author"] as? String,caller.principal)) { try self.owner(caller) }
        return record
    }
    /// Hashing happens without a SQL writer or deletion gate. Publication checks this exact
    /// observation again under the shared gate; cleanup winning first cannot publish absent bytes.
    func prepareAttachmentOriginals(project: String, attachmentIDs: [String], caller: Caller) throws -> [PreparedAttachmentOriginal] {
        guard !attachmentIDs.isEmpty,attachmentIDs.count <= 200,Set(attachmentIDs.map { Data($0.utf8) }).count == attachmentIDs.count else { throw CoreError("INVALID_INPUT","Select 1 to 200 distinct attachments.") }
        let attachments = try dbQueue.read { db -> [JSON] in
            _ = try self.scope(db,["project_id":project],caller)
            return try attachmentIDs.map { id in
                let a = try self.scoped(db,id,project,type:"attachment")
                // A raw taskless attachment ID cannot bypass its canonical owner reference.
                guard let taskID = a["task_id"] as? String,!bool(a,"unlinked") else { throw CoreError("ATTACHMENT_REFERENCE_REQUIRED","Select a current task attachment or an owned reference.") }
                _ = try self.scoped(db,taskID,project,type:"task")
                return a
            }
        }
        return try attachments.map(prepareAttachmentOriginal)
    }
    func prepareAttachmentOriginal(_ attachment: JSON) throws -> PreparedAttachmentOriginal {
        guard attachment["mode"] as? String == "managed",attachment["availability"] as? String == "available",
              let path = attachment["path"] as? String,let sha = attachment["sha256"] as? String else { throw CoreError("MANAGED_ORIGINAL_UNAVAILABLE","An exact managed original is required.") }
        let relative = try managedRelative(path,family:"objects")
        guard let identity = try managedIdentity(path) else { throw CoreError("MANAGED_ORIGINAL_UNAVAILABLE","An exact managed original is required.") }
        let bytes = try StorageObjectFiles(root:root).read(relative,maximum:500 * 1024 * 1024)
        guard bytes.count == int(attachment,"size"),hash(bytes) == sha,(try? managedIdentity(path)) == identity else { throw CoreError("SOURCE_CHANGED","The original changed during preparation.") }
        return .init(attachment:attachment,identity:identity)
    }
    func validatePreparedAttachment(_ db: Database,project: String,prepared: PreparedAttachmentOriginal) throws -> JSON {
        let previous = prepared.attachment
        let a = try scoped(db,previous["id"] as! String,project,type:"attachment")
        guard a["mode"] as? String == "managed",a["availability"] as? String == "available",
              int(a,"revision") == int(previous,"revision"),EnvelopeStorageIdentity.equal(a["path"] as? String,previous["path"] as? String),
              a["sha256"] as? String == previous["sha256"] as? String,let path = a["path"] as? String,let identity = try? managedIdentity(path),identity == prepared.identity else { throw CoreError("MANAGED_ORIGINAL_UNAVAILABLE","The prepared original is unavailable or changed; nothing was published.") }
        // Check descriptor-relative containment as well as the earlier content observation.
        // lstat alone would follow an intermediate directory swapped to a symlink.
        let relative = try managedRelative(path,family:"objects")
        try StorageObjectFiles(root:root).openRegular(relative) { fd in
            var info = stat()
            guard fstat(fd,&info) == 0,UInt64(info.st_dev) == prepared.identity.device,UInt64(info.st_ino) == prepared.identity.inode,
                  Int64(info.st_size) == prepared.identity.size,info.st_mtimespec.tv_sec == prepared.identity.modifiedSeconds,
                  info.st_mtimespec.tv_nsec == prepared.identity.modifiedNanoseconds else { throw CoreError("SOURCE_CHANGED","The managed original changed before publication.") }
        }
        return a
    }
    func addMediaAttachmentReference(_ db: Database,project: String,owner: MediaAttachmentOwner,attachment: JSON,caller: Caller) throws -> JSON {
        let id = uuid()
        let reference: JSON = ["id":id,"project_id":project,"kind":"media_reference","owner_id":owner.id,"owner_kind":owner.kind.rawValue,
            "attachment_id":attachment["id"]!,"sha256":attachment["sha256"]!,"size":attachment["size"]!,"state":"active","revision":1,"author":caller.principal,"created_at":now()]
        try save(db,reference,type:"storage_hold");return reference
    }
    func adoptTaskAttachments(_ db: Database,permit: ArchiveStoragePermit,project: String,owner: MediaAttachmentOwner,
                             prepared: [PreparedAttachmentOriginal],caller: Caller,releaseReadHoldIDs: [String] = []) throws -> [JSON] {
        try requireMediaStorageTransaction(db,permit:permit)
        let anchor = try mediaAttachmentOwner(db,project:project,owner:owner,caller:caller,write:true)
        guard owner.kind != .target,anchor["state"] as? String == "active",!prepared.isEmpty,prepared.count <= 200,Set(prepared.compactMap { ($0.attachment["id"] as? String).map { Data($0.utf8) } }).count == prepared.count,
              releaseReadHoldIDs.count <= 200 else { throw CoreError("INVALID_INPUT","Adopt into an active intake or Draft item first.") }
        let attachments = try prepared.map { value -> JSON in
            let a = try validatePreparedAttachment(db,project:project,prepared:value)
            guard a["task_id"] is String,!bool(a,"unlinked") else { throw CoreError("ATTACHMENT_REFERENCE_REQUIRED","A source task link is required.") };return a
        }
        let references = try attachments.map { try addMediaAttachmentReference(db,project:project,owner:owner,attachment:$0,caller:caller) }
        // Replacement references exist before the source reader holds are relinquished, in this transaction.
        for id in releaseReadHoldIDs { try releaseMediaReadHold(db,permit:permit,project:project,id:id,caller:caller,attachmentIDs:Set(attachments.compactMap { $0["id"] as? String }.map { Data($0.utf8) })) }
        return references
    }
    func mediaAttachmentReference(_ db: Database,project: String,id: String,owner: MediaAttachmentOwner,caller: Caller) throws -> (JSON,JSON) {
        _ = try mediaAttachmentOwner(db,project:project,owner:owner,caller:caller)
        let reference = try scoped(db,id,project,type:"storage_hold")
        guard reference["kind"] as? String == "media_reference",reference["state"] as? String == "active",
              EnvelopeStorageIdentity.equal(reference["owner_id"] as? String,owner.id),reference["owner_kind"] as? String == owner.kind.rawValue,
              let aid = reference["attachment_id"] as? String else { throw CoreError("ATTACHMENT_REFERENCE_REQUIRED","A current authorized owner reference is required.") }
        let a = try scoped(db,aid,project,type:"attachment")
        guard a["mode"] as? String == "managed",a["availability"] as? String == "available",
              a["sha256"] as? String == reference["sha256"] as? String,int(a,"size") == int(reference,"size") else { throw CoreError("MANAGED_ORIGINAL_UNAVAILABLE","This reference's original is unavailable.") }
        return (reference,a)
    }
    func prepareOwnedAttachmentOriginals(project: String,owner: MediaAttachmentOwner,referenceIDs: [String],caller: Caller) throws -> [PreparedAttachmentOriginal] {
        guard !referenceIDs.isEmpty,referenceIDs.count <= 200,Set(referenceIDs.map { Data($0.utf8) }).count == referenceIDs.count else { throw CoreError("INVALID_INPUT","Select distinct owned references.") }
        let values = try dbQueue.read { db in try referenceIDs.map { try self.mediaAttachmentReference(db,project:project,id:$0,owner:owner,caller:caller).1 } }
        return try values.map(prepareAttachmentOriginal)
    }
    /// Called INSIDE the future publication command's transaction/receipt boundary. Any failed
    /// manifest/receipt write rolls back new references, old releases and the owner transition together.
    func transferMediaAttachmentReferences(_ db: Database,permit: ArchiveStoragePermit,project: String,source: MediaAttachmentOwner,
        referenceIDs: [String],destination: MediaAttachmentOwner,prepared: [PreparedAttachmentOriginal],caller: Caller,
        commitManifest: ([JSON]) throws -> Void) throws -> (MediaAttachmentOwner,[JSON]) {
        try requireMediaStorageTransaction(db,permit:permit)
        _ = try mediaAttachmentOwner(db,project:project,owner:source,caller:caller,write:true)
        var target = try mediaAttachmentOwner(db,project:project,owner:destination,caller:caller,write:true)
        guard source.kind != .target,!EnvelopeStorageIdentity.equal(source.id,destination.id),
              (destination.kind == .target ? target["state"] as? String == "draft" : target["state"] as? String == "active"),
              !referenceIDs.isEmpty,referenceIDs.count <= 200,referenceIDs.count == prepared.count,
              Set(referenceIDs.map { Data($0.utf8) }).count == referenceIDs.count else { throw CoreError("INVALID_INPUT","Invalid ownership handover.") }
        var old: [JSON] = [],new: [JSON] = []
        for (id,prepared) in zip(referenceIDs,prepared) {
            let (reference,a) = try mediaAttachmentReference(db,project:project,id:id,owner:source,caller:caller)
            guard EnvelopeStorageIdentity.equal(a["id"] as? String,prepared.attachment["id"] as? String) else { throw CoreError("SOURCE_CHANGED","Prepared selection changed.") }
            _ = try validatePreparedAttachment(db,project:project,prepared:prepared)
            old.append(reference);new.append(try addMediaAttachmentReference(db,project:project,owner:destination,attachment:a,caller:caller))
        }
        try commitManifest(new)
        for var reference in old { reference["state"] = "released";try save(db,revised(reference),type:"storage_hold") }
        if destination.kind == .target { target["state"] = "published";target = revised(target);try save(db,target,type:"storage_job") }
        return (.init(id:destination.id,kind:destination.kind,revision:int(target,"revision")),new)
    }
    func acquireMediaAttachmentReadLease(project: String,referenceID: String,owner: MediaAttachmentOwner,caller: Caller,seconds: Int = 300) throws -> MediaAttachmentReadLease {
        guard (1...300).contains(seconds) else { throw CoreError("INVALID_INPUT","Reader leases last 1 to 300 seconds.") }
        return try ArchiveStorageGate.withExclusive(root:root) { permit in
            try dbQueue.write { db in
                try self.requireMediaStorageTransaction(db,permit:permit)
                let (_,a) = try self.mediaAttachmentReference(db,project:project,id:referenceID,owner:owner,caller:caller)
                guard let path = a["path"] as? String,(try? self.managedIdentity(path)) != nil else { throw CoreError("MANAGED_ORIGINAL_UNAVAILABLE","The original is unavailable.") }
                let id = uuid(),expiry = Date().addingTimeInterval(Double(seconds))
                try self.save(db,["id":id,"project_id":project,"kind":"reader","attachment_id":a["id"]!,"owner_reference_id":referenceID,
                    "state":"active","expires_at":expiry.timeIntervalSince1970,"author":caller.principal,"incarnation":self.incarnation,"session_generation":try self.callerSessionGeneration(db,caller,project:project),"revision":1,"created_at":now()],type:"storage_hold")
                return .init(id:id,attachment:self.ownerManagedPathProjection(a,caller:caller),expiresAt:expiry)
            }
        }
    }
    func releaseMediaReadHold(_ db: Database,permit: ArchiveStoragePermit,project: String,id: String,caller: Caller,attachmentIDs: Set<Data>? = nil) throws {
        try requireMediaStorageTransaction(db,permit:permit)
        _ = try scope(db,["project_id":project],caller)
        var hold = try scoped(db,id,project,type:"storage_hold")
        let generation = try callerSessionGeneration(db,caller,project:project)
        guard hold["kind"] as? String == "reader",EnvelopeStorageIdentity.equal(hold["author"] as? String,caller.principal),
              (hold["incarnation"] == nil && caller.isOwner || hold["incarnation"] as? String == incarnation && hold["session_generation"] as? String == generation),
              let aid = hold["attachment_id"] as? String,attachmentIDs == nil || attachmentIDs!.contains(Data(aid.utf8)) else { throw CoreError("FORBIDDEN","Only this caller's matching reader lease can be released.") }
        if hold["state"] as? String == "active" { hold["state"] = "released";try save(db,revised(hold),type:"storage_hold") }
    }
    func readMediaAttachment(project: String,referenceID: String,owner: MediaAttachmentOwner,caller: Caller,maximum: Int = 8 * 1024 * 1024) throws -> Data {
        guard (0...8 * 1024 * 1024).contains(maximum) else { throw CoreError("INVALID_INPUT","Invalid read bound.") }
        let lease = try acquireMediaAttachmentReadLease(project:project,referenceID:referenceID,owner:owner,caller:caller)
        defer { try? ArchiveStorageGate.withExclusive(root:root) { permit in try dbQueue.write { db in try self.releaseMediaReadHold(db,permit:permit,project:project,id:lease.id,caller:caller) } } }
        let a = lease.attachment
        let bytes = try managedRead(a["path"] as! String,family:"objects",maximum:maximum)
        guard bytes.count == int(a,"size"),hash(bytes) == a["sha256"] as? String else { throw CoreError("SOURCE_CHANGED","The original no longer matches this reference.") }
        return bytes
    }
}

extension CommandRouter {
    func prepareMediaAttachmentImport(project: String,owner: MediaAttachmentOwner,commandID: String,path: String,caller: Caller,expectedSHA256: String? = nil) throws -> ManagedAttachmentPreparation? {
        var params: JSON = ["project_id":project,"command_id":commandID,"path":path,"owner_id":owner.id,"owner_kind":owner.kind.rawValue,"owner_revision":owner.revision]
        params["expected_sha256"] = expectedSHA256
        return try prepareManagedAttachmentImport(method:"internal_media_attachment_capture",params:params,caller:caller,access:managedImportAccessOutsideWriter(),mediaOwner:owner)
    }
    /// The enclosing command transaction must commit the semantic receipt as well. This shares
    /// ordinary import staging/finalization and has no public entry point or synthetic task link.
    func commitMediaAttachmentImport(_ db: Database,permit: ArchiveStoragePermit,project: String,owner: MediaAttachmentOwner,
                                    prepared: ManagedAttachmentPreparation,caller: Caller) throws -> JSON {
        try requireMediaStorageTransaction(db,permit:permit)
        try validateMediaAttachmentImport(db,project:project,owner:owner,prepared:prepared,caller:caller)
        try save(db,prepared.attachment,type:"attachment")
        let reference = try addMediaAttachmentReference(db,project:project,owner:owner,attachment:prepared.attachment,caller:caller)
        var job = prepared.job
        job["state"] = "committed";job["completed_at"] = now();try save(db,revised(job),type:"storage_job")
        return reference
    }
    /// Shared by the prepared intake writer; identity/presence checks only, never hashing.
    func validateMediaAttachmentImport(_ db: Database,project: String,owner: MediaAttachmentOwner,
                                      prepared: ManagedAttachmentPreparation,caller: Caller) throws {
        let anchor = try mediaAttachmentOwner(db,project:project,owner:owner,caller:caller,write:true)
        guard owner.kind != .target,anchor["state"] as? String == "active" else { throw CoreError("ATTACHMENT_OWNER_STALE","Capture owner changed.") }
        let job = try scoped(db,prepared.job["id"] as! String,project,type:"storage_job")
        try validateManagedImportOwner(job,principal:caller.principal,command:prepared.command,digest:prepared.digest,project:project,task:nil,
                                      generation:callerSessionGeneration(db,caller,project:project),mediaOwner:owner)
        guard int(job,"revision") == int(prepared.job,"revision"),job["state"] as? String == "finalized",
              EnvelopeStorageIdentity.equal(job["attachment_id"] as? String,prepared.attachment["id"] as? String),
              prepared.attachment["attachment_owner_id"] as? String == owner.id,prepared.attachment["task_id"] == nil else { throw managedImportFailure("final_ownership_changed") }
        let files = try StorageObjectFiles(root:root)
        for object in try managedImportObjects(job) where object["representation"] as? String == "original" || job["preview_available"] as? Bool == true {
            let final = object["final"] as! String
            guard let observed = prepared.observations[final],(try? managedIdentity(final)) == observed else { throw managedImportFailure("prepared_original_changed") }
            try verifyManagedImportPresence(files,final,object)
        }
    }
    /// Fence first, then remove this job's staging under the same gate as every file
    /// creation/publication. A failed cleanup retains the fence for retry/startup recovery.
    func cancelMediaAttachmentImport(project: String,owner: MediaAttachmentOwner,commandID: String,caller: Caller) throws -> JSON {
        try ArchiveStorageGate.withExclusive(root:root) { permit in
            try dbQueue.writeWithoutTransaction { db in
                _ = try self.mediaAttachmentOwner(db,project:project,owner:owner,caller:caller,write:true)
                let key = try self.managedImportKey(principal:caller.principal,command:commandID)
                var job = try self.scoped(db,key,project,type:"storage_job")
                guard job["kind"] as? String == "attachment_import",EnvelopeStorageIdentity.equal(job["parent_principal"] as? String,caller.principal),
                      EnvelopeStorageIdentity.equal(job["attachment_owner_id"] as? String,owner.id),
                      (["reserved","staging","finalized"].contains(job["state"] as? String ?? "") || job["settled_reason"] as? String == "canceled_media_staging") else { throw CoreError("IMPORT_ALREADY_COMMITTED","A committed capture is retained by its canonical references.") }
                try permit.requireRoot(self.root)
                if job["settled_reason"] as? String != "canceled_media_staging" {
                    // Commit before any unlink: even an I/O error or restart cannot
                    // let an older preparation recreate, link or finalize this job.
                    try self.withValidatedDomainTransaction(db) {
                        job["state"] = "settled";job["settled_reason"] = "canceled_media_staging"
                        job["cancellation_cleanup_complete"] = false;job = self.revised(job)
                        try self.save(db,job,type:"storage_job");return .commit
                    }
                }
                return try self.finishCanceledMediaImport(db,job:job)
            }
        }
    }

    /// Caller holds the root gate, outside a long writer transaction. Only exact
    /// recorded stages and UUID partials in this import's private directory qualify.
    /// Retained final bytes are observed lengths, never assumed descriptor lengths.
    @discardableResult func finishCanceledMediaImport(_ db: Database,job initial: JSON) throws -> JSON {
        var job = initial
        guard job["kind"] as? String == "attachment_import",job["state"] as? String == "settled",
              job["settled_reason"] as? String == "canceled_media_staging" else { throw managedImportFailure("cancellation_fence_missing") }
        if job["cancellation_cleanup_complete"] as? Bool == true,let receipt = job["cancellation_receipt"] as? JSON { return receipt }
        let files = try StorageObjectFiles(root:root)
        let objects = job["objects"] == nil ? [] : try managedImportObjects(job)
        var reclaimed = 0,retained = 0,unavailable = 0,unavailableFinal = 0
        func length(_ path: String) throws -> Int {
            try files.openRegular(path) { file in
                var info = stat()
                guard fstat(file,&info) == 0,info.st_size >= 0 else { throw self.managedImportFailure("cancellation_observation_failed") }
                return Int(info.st_size)
            }
        }
        for object in objects {
            let stage = object["stage"] as! String,final = object["final"] as! String
            if try managedImportExists(files,stage) {
                let bytes = try length(stage)
                try removeManagedImportStage(db,files:files,path:stage);reclaimed += bytes
            } else { unavailable += 1 }
            if try managedImportExists(files,final) { retained += try length(final) }
            else { unavailableFinal += 1 }
        }
        if let first = objects.first {
            let directory = (first["stage"] as! String).split(separator:"/").dropLast().joined(separator:"/")
            let entries: [String]
            do { entries = try managedDirectoryEntries(files,relative:directory) }
            catch { if StorageFolderAccess.isMissing(error) { entries = [] } else { throw error } }
            for name in entries {
                guard objects.contains(where: { object in
                    let prefix = (object["representation"] as! String) + ".partial-"
                    return name.hasPrefix(prefix) && UUID(uuidString:String(name.dropFirst(prefix.count))) != nil
                }) else { continue }
                let partial = directory + "/" + name,bytes = try length(partial)
                try removeManagedImportStage(db,files:files,path:partial);reclaimed += bytes
            }
        }
        let receipt: JSON = ["state":"canceled","reclaimed_staging_logical_bytes":reclaimed,"retained_final_logical_bytes":retained,
                             "unavailable_staging_count":unavailable,"unavailable_final_count":unavailableFinal,"physical_reclamation":"unmeasured"]
        try withValidatedDomainTransaction(db) {
            job["cancellation_cleanup_complete"] = true;job["cancellation_receipt"] = receipt
            try self.save(db,self.revised(job),type:"storage_job");return .commit
        }
        return receipt
    }
}
