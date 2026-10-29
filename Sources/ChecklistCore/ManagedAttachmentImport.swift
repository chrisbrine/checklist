import Foundation
import GRDB
import Darwin
import ImageIO
import UniformTypeIdentifiers

/// One pending parent per authenticated principal/command. This is not a
/// completed command receipt, a backup hold or permission to retry a command.
struct ManagedAttachmentPreparation {
    let job: JSON
    let attachment: JSON
    let principal: String
    let command: String
    let digest: String
    var observations: [String:FileIdentity] = [:]
}

/// Internal failed-read basis; never serialized into a public error or receipt.
/// Only the exact managed original inspected by attachmentRead can be marked.
struct ManagedOriginalReadFailure: Error {
    let projectID: String
    let attachmentID: String
    let revision: Int
    let path: String
    let sha256: String?
    let failure: CoreError
}

extension CommandRouter {
    func managedImportFailure(_ reason: String) -> CoreError {
        CoreError("MANAGED_IMPORT_RECOVERY_REQUIRED", "The managed import was retained for recovery. No incomplete object was published as available.", details: ["reason": reason])
    }
    func managedImportKey(principal: String, command: String) throws -> String {
        "managed-import-" + hash(Data((try jsonString(["principal": principal, "command_id": command])).utf8))
    }
    func managedImportReceipt(_ db: Database, principal: String, command: String, digest: String) throws -> JSON? {
        guard let row = try Row.fetchOne(db, sql: "SELECT digest,result FROM commands WHERE principal=CAST(? AS TEXT) AND command_id=CAST(? AS TEXT)", arguments: [Data(principal.utf8),Data(command.utf8)]) else { return nil }
        guard EnvelopeStorageIdentity.equal(row["digest"] as String,digest) else { throw CoreError("IDEMPOTENCY_CONFLICT", "This command ID was already used with different input.") }
        return jsonObject(row["result"])
    }

    /// Shared by the actual ordinary and typed-pairing receipt transactions.
    /// A pending parent owns its principal+UUID before there is a receipt.
    /// The caller's current scope is checked before any intent observation.
    func requirePendingCommandIntent(_ db: Database,command: String,digest: String,caller: Caller) throws {
        try requirePendingOperationIntent(db,command:command,digest:digest,caller:caller)
        try requirePendingStorageCommand(db,command:command,digest:digest,caller:caller)
        try requirePendingExportIntent(command:command,digest:digest,caller:caller)
        let key = try managedImportKey(principal:caller.principal,command:command)
        let base = " FROM records WHERE id=CAST(? AS TEXT) AND type='storage_job'"
        var allowed = "", arguments: [DatabaseValueConvertible] = [Data(key.utf8)]
        if !caller.isOwner {
            allowed = caller.projectIDs.isEmpty ? " AND 0" : " AND project_id IN (" + caller.projectIDs.map {_ in "CAST(? AS TEXT)"}.joined(separator:",") + ")"
            arguments += caller.projectIDs.map { Data($0.utf8) as DatabaseValueConvertible }
        }
        guard let row = try Row.fetchOne(db,sql:"SELECT " + Self.canonicalRecordColumns + base + allowed,arguments:StatementArguments(arguments)) else {
            // An out-of-grant parent cannot become a free UUID. Observe only
            // existence, not its payload, digest, project or error contents.
            if try Int.fetchOne(db,sql:"SELECT COUNT(*)" + base,arguments:[Data(key.utf8)]) != 0 { throw CoreError("FORBIDDEN", "The pending command is outside the current grant.") }
            return
        }
        let job = try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"storage_job").object
        guard let pid = job["project_id"] as? String else { throw managedImportFailure("invalid_pending_parent") }
        _ = try scope(db,["project_id":pid],caller)
        guard db.isInsideTransaction, job["kind"] as? String == "attachment_import", EnvelopeStorageIdentity.equal(job["parent_principal"] as? String,caller.principal), EnvelopeStorageIdentity.equal(job["parent_command_id"] as? String,command) else { throw managedImportFailure("invalid_pending_parent") }
        guard job["intent_digest"] as? String == digest else { throw CoreError("IDEMPOTENCY_CONFLICT", "This command ID already belongs to another original intent.") }
        // Work/session freshness belongs to the real method's existing gates.
        // Same-intent completed replay keeps its existing authority projection.
    }

    /// Database access for one import preparation. Outside the writer (the normal path),
    /// each read is a short read and each state change a short write under the object gate;
    /// the large source read, hashing, preview and copy run between them with no lock (CL-71).
    struct ManagedImportAccess {
        let read: ((Database) throws -> Void) throws -> Void
        let write: ((Database) throws -> Void) throws -> Void
        let underGate: (() throws -> Void) throws -> Void
        var folderAccess = StorageFolderAccess()
        var observeSourceIdentity: (FileIdentity) -> Void = { _ in }
    }
    func managedImportAccessOutsideWriter() -> ManagedImportAccess {
        ManagedImportAccess(read: { body in try self.readForPreparation(body) },
            write: { body in try ArchiveStorageGate.withExclusive(root: self.root) { _ in try self.dbQueue.writeWithoutTransaction(body) } },
            underGate: { body in try ArchiveStorageGate.withExclusive(root: self.root) { _ in try body() } })
    }
    /// For a caller that already holds the writer (direct internal use).
    func managedImportAccess(inside db: Database) -> ManagedImportAccess {
        ManagedImportAccess(read: { body in try body(db) }, write: { body in try body(db) }, underGate: { body in try body() })
    }

    /// A failed preparation retains its durable job and never mints a receipt.
    func prepareManagedAttachmentImport(_ db: Database, method: String, params p: JSON, caller c: Caller) throws -> ManagedAttachmentPreparation? {
        try prepareManagedAttachmentImport(method: method, params: p, caller: c, access: managedImportAccess(inside: db))
    }
    func prepareManagedAttachmentImport(method: String, params p: JSON, caller c: Caller, access: ManagedImportAccess, mediaOwner: MediaAttachmentOwner? = nil) throws -> ManagedAttachmentPreparation? {
        guard (method == "attachment_add" || (method == "internal_media_attachment_capture" && mediaOwner != nil)), !["reference","external_reference"].contains(p["mode"] as? String ?? "managed") else { return nil }
        var pid = "", task: JSON = [:], command = "", digest = "", replay = false, path = "", generation = ""
        try access.read { db in
            pid = try self.scope(db,p,c,write:true)
            try self.assistantPermission(c,pid,"post_notes_on_request")
            if let mediaOwner {
                let anchor = try self.mediaAttachmentOwner(db,project:pid,owner:mediaOwner,caller:c,write:true)
                guard mediaOwner.kind != .target,anchor["state"] as? String == "active" else { throw CoreError("INVALID_INPUT","Capture into an active intake or Draft item.") }
            } else { task = try self.task(db,p,pid) }
            command = try text(p,"command_id",max:100)
            guard UUID(uuidString:command) != nil else { throw CoreError("INVALID_INPUT", "command_id must be a UUID.") }
            digest = hash(Data((method + (try jsonString(p))).utf8))
            // Scope precedes the receipt lookup, just as in ordinary handle.
            if try self.managedImportReceipt(db,principal:c.principal,command:command,digest:digest) != nil { replay = true; return }
            let source = p["source"] as? JSON ?? [:], raw = p["path"] as? String ?? source["path"] as? String ?? ""
            guard !raw.isEmpty else { throw CoreError("FILE_ACCESS_REQUIRED", "Choose a local file.") }
            let project = try self.record(db,pid,type:"project")
            if source["kind"] as? String == "workspace_file", !raw.hasPrefix("/"), let base = project["root_path"] as? String {
                path = try StorageFolderAccess.lexicalPath(base + "/" + raw)
            } else { path = try StorageFolderAccess.lexicalPath(raw) }
            if !c.isOwner {
                guard let workspace = c.workspace, containsPath(try StorageFolderAccess.lexicalPath(workspace),path), let base = project["root_path"] as? String, containsPath(try StorageFolderAccess.lexicalPath(base),path) else { throw CoreError("FILE_ACCESS_REQUIRED", "Agent file imports must stay inside its enrolled workspace.") }
            }
            generation = try self.callerSessionGeneration(db,c,project:pid)
        }
        if replay { return nil }
        let sourceURL = URL(fileURLWithPath:path)
        let key = try managedImportKey(principal:c.principal,command:command)
        var job: JSON = [:]
        // Lookup and reservation share the actual SQL transaction. Parent
        // identity is principal+command, across project/kind/target.
        try access.write { db in
            try self.withValidatedDomainTransaction(db) {
            do { job = try self.record(db,key,type:"storage_job") }
            catch let error as CoreError where error.code == "NOT_FOUND" {
                let id = uuid(), suffix = sourceURL.pathExtension.range(of:"^[A-Za-z0-9]{1,16}$",options:.regularExpression) != nil ? "." + sourceURL.pathExtension : ""
                // Physical namespace only. SQL project identity remains the exact
                // opaque original; no normalization, filename identity or dedup grant.
                let namespace = "project-" + hash(Data(pid.utf8))
                job = ["id":key,"project_id":pid,"kind":"attachment_import","parent_principal":c.principal,"parent_command_id":command,"intent_digest":digest,"incarnation":self.incarnation,"session_generation":generation,"attachment_id":id,"object_relative_path":"objects/" + namespace + "/" + id + suffix,"state":"reserved","revision":1,"created_at":now()]
                if let mediaOwner { job["attachment_owner_id"] = mediaOwner.id;job["attachment_owner_kind"] = mediaOwner.kind.rawValue }
                else { job["task_id"] = (try StoredRecord(task, family: "ManagedAttachmentImport").requiredValue("id")) }
                try self.save(db,job,type:"storage_job")
            }
            return .commit
            }
        }
        func saveProgress(_ next: JSON) throws {
            try access.write { db in try self.withValidatedDomainTransaction(db) { try self.saveManagedImportProgress(db,next); return .commit } }
        }
        // Called only while the object gate is held. A canceled job is a durable
        // fence, including when this preparation still holds an older snapshot.
        func requireCurrentPreparation(_ db: Database) throws {
            let current = try self.record(db,key,type:"storage_job")
            try self.requireManagedImportNotCanceled(current)
            guard ["reserved","staging","finalized"].contains(current["state"] as? String ?? ""), int(current,"revision") == int(job,"revision") else {
                throw CoreError("REVISION_CONFLICT", "The pending import changed. Reconcile the original command ID.")
            }
        }
        func requireCurrentUnderGate() throws { try access.read(requireCurrentPreparation) }
        try requireManagedImportNotCanceled(job)
        guard job["intent_digest"] as? String == digest else { throw CoreError("IDEMPOTENCY_CONFLICT", "This command ID was already used with different input.") }
        try validateManagedImportOwner(job,principal:c.principal,command:command,digest:digest,project:pid,task:task["id"] as? String,generation:generation,mediaOwner:mediaOwner)
        guard let attachmentID = job["attachment_id"] as? String, UUID(uuidString:attachmentID) != nil, let original = job["object_relative_path"] as? String, let created = job["created_at"] as? String, !created.isEmpty else { throw managedImportFailure("invalid_parent_shape") }
        guard ["reserved","staging","finalized"].contains(job["state"] as? String ?? "") else { throw managedImportFailure("completed_job_without_matching_receipt") }
        var verifiedFinal: [String:FileIdentity] = [:]
        func preparedValue(_ value: JSON) throws -> ManagedAttachmentPreparation {
            let objects = try managedImportObjects(value)
            guard let originalObject = objects.first(where: {$0["representation"] as? String == "original"}) else {
                throw managedImportFailure("original_descriptor_missing")
            }
            var attachment: JSON = ["id":attachmentID,
                "project_id":pid,
                "artifact_id":attachmentID,
                "name":p["name"] ?? sourceURL.lastPathComponent,
                "description":p["description"] ?? "",
                "mode":"managed",
                "path":original,
                "sha256":(try StoredRecord(originalObject,
                family: "ManagedAttachmentImport").requiredValue("sha256")),
                "size":(try StoredRecord(originalObject,
                family: "ManagedAttachmentImport").requiredValue("size")),
                "availability":"available",
                "keep_original":false,
                "unlinked":false,
                "revision":1,
                "created_at":created,
                "author":c.principal,
                "origin":c.isOwner ? "human_ui" : c.role,
                "storage_job_id":key]
            if let mediaOwner { attachment["attachment_owner_id"] = mediaOwner.id }
            else { attachment["task_id"] = (try StoredRecord(task, family: "ManagedAttachmentImport").requiredValue("id")) }
            if value["preview_available"] as? Bool == true, let preview = objects.first(where: {$0["representation"] as? String == "preview"}) { attachment["preview_path"] = preview["final"] }
            else if objects.contains(where: {$0["representation"] as? String == "preview"}) { attachment["preview_availability"] = "unavailable" }
            var prepared = ManagedAttachmentPreparation(job:value,attachment:attachment,principal:c.principal,command:command,digest:digest)
            for object in objects where object["representation"] as? String == "original" || value["preview_available"] as? Bool == true {
                let final = (try StoredRecord(object, family: "ManagedAttachmentImport").string("final"))
                guard let identity = verifiedFinal[final],(try? managedIdentity(final)) == identity else { throw managedImportFailure("prepared_original_missing_or_changed") }
                prepared.observations[final] = identity
            }
            return prepared
        }
        let files = try StorageObjectFiles(root:root,folderAccess:access.folderAccess)
        if job["state"] as? String == "finalized", job["objects"] == nil { throw managedImportFailure("invalid_finalized_authority") }
        if job["objects"] != nil {
            let objects = try managedImportObjects(job)
            guard let originalObject = objects.first(where: {$0["representation"] as? String == "original"}) else {
                throw managedImportFailure("original_descriptor_missing")
            }
            let final = (try StoredRecord(originalObject, family: "ManagedAttachmentImport").string("final"))
            let retained = try managedImportExists(files,final)
            if job["state"] as? String == "finalized" || retained {
                guard retained else { throw managedImportFailure("finalized_original_missing") }
                if let expected = p["expected_sha256"] as? String, expected != originalObject["sha256"] as? String { throw CoreError("SOURCE_CHANGED", "The retained original does not match the original command's expected identity.") }
                verifiedFinal[final] = try verifyManagedImportFile(files,final,originalObject)
                try synchronizeManagedImportPublication(files,path:final)
                if let preview = objects.first(where: {$0["representation"] as? String == "preview"}) {
                    do {
                        verifiedFinal[(try StoredRecord(preview,
                            family: "ManagedAttachmentImport").string("final"))] = try verifyManagedImportFile(files,
                            (try StoredRecord(preview,
                            family: "ManagedAttachmentImport").string("final")),
                            preview)
                        try synchronizeManagedImportPublication(files,path:(try StoredRecord(preview, family: "ManagedAttachmentImport").string("final")))
                        job["preview_available"] = true
                    } catch { job["preview_available"] = false }
                }
                // Explicit same-intent retry uses retained, verified bytes after
                // current authority checks. The chooser/workspace source can be gone.
                job["state"] = "finalized"; job = revised(job)
                job.removeValue(forKey:"last_error_code"); job.removeValue(forKey:"last_error_at")
                try saveProgress(job)
                return try preparedValue(job)
            }
        }
        // Open before any Foundation file observation can enter the protected
        // source folder. Descriptor validation/read below supplies type and size.
        let sourceFiles = try StorageObjectFiles(root:sourceURL.deletingLastPathComponent(),folderAccess:access.folderAccess)
        let bytes = try readManagedImportSource(sourceFiles, sourceURL:sourceURL, access:access)
        let sha = hash(bytes)
        guard bytes.count <= 500 * 1024 * 1024 else { throw CoreError("FILE_TOO_LARGE", "This local importer accepts files up to 500 MiB.") }
        if let expected = p["expected_sha256"] as? String, expected != sha { throw CoreError("SOURCE_CHANGED", "The file changed before import.") }
        if let expected = job["sha256"] as? String, expected != sha { throw CoreError("SOURCE_CHANGED", "The source no longer matches this pending command's staged identity.") }
        var payloads: [String:Data] = ["original":bytes]
        if job["objects"] == nil, let preview = managedImportPreview(bytes) { payloads["preview"] = preview }
        if job["objects"] == nil {
            let objects: [JSON] = payloads.keys.sorted().map { name in
                let data = payloads[name]!
                return ["representation":name,"stage":"staging/attachment-imports/" + key + "/" + name,"final":original + (name == "preview" ? ".preview.png" : ""),"sha256":hash(data),"size":data.count]
            }
            job["sha256"] = sha; job["size"] = bytes.count; job["objects"] = objects; job["state"] = "staging"; job = revised(job)
            try saveProgress(job)
        }
        let objects = try managedImportObjects(job)
        for object in objects {
            do {
            let stage = (try StoredRecord(object, family: "ManagedAttachmentImport").string("stage")), final = (try StoredRecord(object, family: "ManagedAttachmentImport").string("final"))
            if try managedImportExists(files,final) {
                verifiedFinal[final] = try verifyManagedImportFile(files,final,object)
                // A previous publication may have stopped before parent flush.
                try synchronizeManagedImportPublication(files,path:final)
                if object["representation"] as? String == "preview" { job["preview_available"] = true }
                continue
            }
            try stageManagedImportObject(
                files, object:object, stage:stage, bytes:bytes, payloads:&payloads, access:access,
                requireCurrentPreparation:requireCurrentPreparation, requireCurrentUnderGate:requireCurrentUnderGate)
            try verifyManagedImportFile(files,stage,object)
            // Links share the object gate order with reader grants, backups and cleanup unlinks.
            try access.underGate {
                try requireCurrentUnderGate()
                try self.publishManagedImportFile(files,stage:stage,final:final)
            }
            verifiedFinal[final] = try verifyManagedImportFile(files,final,object)
            if object["representation"] as? String == "preview" { job["preview_available"] = true }
            } catch {
                if (error as? CoreError)?.code == "MANAGED_IMPORT_CANCELED" { throw error }
                guard object["representation"] as? String == "preview" else { throw error }
                // Retain its descriptor/uncertain bytes, but do not advertise
                // this optional representation or block the valid original.
                job["preview_available"] = false
            }
        }
        guard hash(try sourceFiles.read(sourceURL.lastPathComponent,maximum:500 * 1024 * 1024)) == sha else { throw CoreError("SOURCE_CHANGED", "The source changed during import.") }
        job["state"] = "finalized"; job = revised(job)
        job.removeValue(forKey:"last_error_code"); job.removeValue(forKey:"last_error_at")
        try saveProgress(job)
        return try preparedValue(job)
    }

    /// Reads through the already opened source authority; the caller retains it for the final reread.
    private func readManagedImportSource(
        _ sourceFiles: StorageObjectFiles, sourceURL: URL, access: ManagedImportAccess
    ) throws -> Data {
        do {
            let size = try sourceFiles.openRegular(sourceURL.lastPathComponent) { descriptor -> Int64 in
                guard let identity = FileIdentity(descriptor:descriptor) else { throw StorageSnapshotFailure.unsupportedAuthority }
                access.observeSourceIdentity(identity)
                return identity.size
            }
            guard size <= 500 * 1024 * 1024 else { throw CoreError("FILE_TOO_LARGE", "This local importer accepts files up to 500 MiB.") }
            return try sourceFiles.read(sourceURL.lastPathComponent,maximum:500 * 1024 * 1024)
        } catch StorageSnapshotFailure.io {
            throw CoreError("FILE_ACCESS_REQUIRED",
                "The selected original ‘\(sourceURL.path)’ cannot be read. Check folder access or privacy/sync availability and retry the original command ID.")
        }
        catch StorageSnapshotFailure.unsupportedAuthority { throw CoreError("INVALID_INPUT", "Attach a regular file.") }
        catch StorageSnapshotFailure.limit { throw CoreError("FILE_TOO_LARGE", "This local importer accepts files up to 500 MiB.") }
    }

    /// Repairs or creates only the recorded unpublished stage. The caller owns final publication.
    private func stageManagedImportObject(
        _ files: StorageObjectFiles, object: JSON, stage: String, bytes: Data,
        payloads: inout [String:Data], access: ManagedImportAccess,
        requireCurrentPreparation: (Database) throws -> Void,
        requireCurrentUnderGate: () throws -> Void
    ) throws {
        if try managedImportExists(files,stage) {
            do { try verifyManagedImportFile(files,stage,object) }
            catch {
                // Only an unpublished, job-owned stage may be replaced.
                // A reference from any canonical attachment wins over cleanup.
                try access.write { db in
                    try requireCurrentPreparation(db)
                    try self.removeManagedImportStage(db,files:files,path:stage)
                }
            }
        }
        if !(try managedImportExists(files,stage)) {
            let representation = (try StoredRecord(object, family: "ManagedAttachmentImport").string("representation"))
            if payloads[representation] == nil, representation == "preview" { payloads[representation] = managedImportPreview(bytes) }
            guard let data = payloads[representation], hash(data) == object["sha256"] as? String,
                  data.count == int(object,"size") else {
                throw managedImportFailure("staged_representation_not_reproducible")
            }
            // A backup verifies a recorded stage when it exists, so the stage name
            // appears only complete: written under a private name, renamed under the gate.
            let partial = stage + ".partial-" + uuid()
            do {
                var file: Int32 = -1
                try access.underGate {
                    try requireCurrentUnderGate()
                    file = try self.createManagedImportPartial(files,path:partial)
                }
                // Cancellation can unlink this private entry while its open inode is
                // written. No writer or object gate is held during the large copy.
                do {
                    defer { Darwin.close(file) }
                    try self.writeManagedImportPartial(file,bytes:data)
                }
                try access.underGate {
                    try requireCurrentUnderGate()
                    try self.renameManagedImportStage(files,from:partial,to:stage)
                }
            } catch {
                try? access.underGate { _ = try self.removeManagedFile(files,relative:partial) }
                throw error
            }
        }
    }

    private func createManagedImportPartial(_ files: StorageObjectFiles,path: String) throws -> Int32 {
        let (directory,name) = try files.parent(path,create:true)
        defer { Darwin.close(directory) }
        let file = openat(directory,name,O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard file >= 0 else { throw managedImportFailure("partial_creation_failed") }
        guard fsync(directory) == 0 else { Darwin.close(file);throw managedImportFailure("partial_creation_flush_uncertain") }
        return file
    }
    private func writeManagedImportPartial(_ file: Int32,bytes: Data) throws {
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(file,raw.baseAddress!.advanced(by:offset),raw.count-offset)
                if count < 0,errno == EINTR { continue }
                guard count > 0 else { throw managedImportFailure("partial_write_failed") }
                offset += count
            }
        }
        try StorageObjectFiles.flush(file)
    }
    func requireManagedImportNotCanceled(_ job: JSON) throws {
        guard job["settled_reason"] as? String != "canceled_media_staging" else {
            throw CoreError("MANAGED_IMPORT_CANCELED", "This import was canceled. Its staging cannot be recreated or published.")
        }
    }

    func renameManagedImportStage(_ files: StorageObjectFiles,from partial: String,to stage: String) throws {
        let (source,sourceName) = try files.parent(partial), (destination,destinationName) = try files.parent(stage)
        defer { Darwin.close(source); Darwin.close(destination) }
        guard renameatx_np(source,sourceName,destination,destinationName,UInt32(RENAME_EXCL)) == 0, fsync(destination) == 0 else { throw managedImportFailure("stage_publication_failed") }
    }

    func recordManagedImportPreparationFailure(_ db: Database,method: String,params p: JSON,caller c: Caller,error: Error) throws {
        guard method == "attachment_add", !["reference","external_reference"].contains(p["mode"] as? String ?? "managed") else { return }
        let pid = try scope(db,p,c,write:true), command = try text(p,"command_id",max:100)
        let digest = hash(Data((method + (try jsonString(p))).utf8)), key = try managedImportKey(principal:c.principal,command:command)
        var job = try scoped(db,key,pid,type:"storage_job")
        guard EnvelopeStorageIdentity.equal(job["parent_principal"] as? String,c.principal), job["intent_digest"] as? String == digest, ["reserved","staging","finalized"].contains(job["state"] as? String ?? "") else { return }
        let code = (error as? CoreError)?.code ?? "MANAGED_IMPORT_IO_FAILED"
        let allowed: Set<String> = ["SOURCE_CHANGED","FILE_TOO_LARGE","FILE_ACCESS_REQUIRED","MANAGED_IMPORT_RECOVERY_REQUIRED"]
        job["last_error_code"] = allowed.contains(code) ? code : "MANAGED_IMPORT_IO_FAILED"; job["last_error_at"] = now()
        try withValidatedDomainTransaction(db) { try self.saveManagedImportProgress(db,self.revised(job)); return .commit }
        // If storage cannot accept this observation, the caller's original
        // failure and previously durable pending state remain authoritative.
    }

    func commitManagedAttachmentImport(_ db: Database,_ p: JSON,_ c: Caller,task: JSON) throws -> JSON {
        guard let prepared = managedAttachmentPreparation, EnvelopeStorageIdentity.equal(prepared.principal,c.principal), EnvelopeStorageIdentity.equal(prepared.command,p["command_id"] as? String), prepared.digest == hash(Data(("attachment_add" + (try jsonString(p))).utf8)) else { throw managedImportFailure("missing_preparation") }
        let pid = (try StoredRecord(task, family: "ManagedAttachmentImport").string("project_id"))
        var job = try scoped(db,(try StoredRecord(prepared.job, family: "ManagedAttachmentImport").string("id")),pid,type:"storage_job")
        try validateManagedImportOwner(job,
            principal:c.principal,
            command:prepared.command,
            digest:prepared.digest,
            project:pid,
            task:((try StoredRecord(task,
            family: "ManagedAttachmentImport").string("id"))),
            generation:try callerSessionGeneration(db,
            c,
            project:pid))
        let objects = try managedImportObjects(job)
        guard let relativePath = job["object_relative_path"] as? String, int(job,"revision") == int(prepared.job,"revision"), job["state"] as? String == "finalized", EnvelopeStorageIdentity.equal(job["attachment_id"] as? String,prepared.attachment["id"] as? String), job["sha256"] as? String == prepared.attachment["sha256"] as? String, (try? managedRelative(prepared.attachment["path"] as? String ?? "",family:"objects")) == relativePath, try managedImportReceipt(db,principal:c.principal,command:prepared.command,digest:prepared.digest) == nil else { throw managedImportFailure("final_ownership_or_receipt_changed") }
        let files = try StorageObjectFiles(root:root)
        // The bytes were hashed after publication, before this transaction (CL-71). Here only
        // their presence and size are checked, so the transaction commits metadata only.
        for object in objects where object["representation"] as? String == "original" || job["preview_available"] as? Bool == true { try verifyManagedImportPresence(files,
            (try StoredRecord(object,
            family: "ManagedAttachmentImport").string("final")),
            object) }
        let attachment = prepared.attachment
        try save(db,attachment,type:"attachment")
        try event(db,
            caller:c,
            project:pid,
            entity:task["id"] as? String,
            kind:"attachment_added",
            data:["attachment_id":(try StoredRecord(attachment,
            family: "ManagedAttachmentImport").requiredValue("id")),
            "name":(try StoredRecord(attachment,
            family: "ManagedAttachmentImport").requiredValue("name"))])
        job["state"] = "committed"; job["completed_at"] = now(); try saveManagedImportProgress(db,revised(job))
        // The enclosing unchanged handle callback adds event cursor and command
        // receipt in THIS transaction. Any late failure rolls all three back.
        var response = attachment
        if !c.isOwner { response.removeValue(forKey:"path"); response.removeValue(forKey:"preview_path") }
        return response
    }

    /// Actual read/compare/write inside the caller's SQL transaction. A second
    /// cooperative router cannot replace a pending parent's object identity or
    /// overwrite a newer preparation/recovery outcome with an equal revision.
    private func saveManagedImportProgress(_ db: Database,_ next: JSON) throws {
        let current = try record(db,(try StoredRecord(next, family: "ManagedAttachmentImport").string("id")),type:"storage_job")
        try requireManagedImportNotCanceled(current)
        guard db.isInsideTransaction, int(current,"revision") + 1 == int(next,"revision"), EnvelopeStorageIdentity.equal(current["attachment_id"] as? String,next["attachment_id"] as? String), EnvelopeStorageIdentity.equal(current["parent_principal"] as? String,next["parent_principal"] as? String), current["parent_command_id"] as? String == next["parent_command_id"] as? String, current["intent_digest"] as? String == next["intent_digest"] as? String else { throw CoreError("REVISION_CONFLICT", "The pending import changed. Reconcile the original command ID.") }
        try save(db,next,type:"storage_job")
    }

    func validateManagedImportOwner(_ job: JSON,principal: String,command: String,digest: String,project: String,task: String?,generation: String,mediaOwner: MediaAttachmentOwner? = nil) throws {
        guard job["kind"] as? String == "attachment_import", EnvelopeStorageIdentity.equal(job["parent_principal"] as? String,principal), EnvelopeStorageIdentity.equal(job["parent_command_id"] as? String,command), job["intent_digest"] as? String == digest, EnvelopeStorageIdentity.equal(job["project_id"] as? String,project), EnvelopeStorageIdentity.equal(job["task_id"] as? String,task), EnvelopeStorageIdentity.equal(job["attachment_owner_id"] as? String,mediaOwner?.id),
              EnvelopeStorageIdentity.equal(job["attachment_owner_kind"] as? String,mediaOwner?.kind.rawValue), job["incarnation"] as? String == incarnation, job["session_generation"] as? String == generation, job["id"] as? String == (try managedImportKey(principal:principal,command:command)) else { throw managedImportFailure("pending_parent_ownership_changed") }
    }
    func managedImportObjects(_ job: JSON) throws -> [JSON] {
        guard let key = job["id"] as? String, let id = job["attachment_id"] as? String, UUID(uuidString:id) != nil, let pid = job["project_id"] as? String, let original = job["object_relative_path"] as? String, let objects = job["objects"] as? [JSON], objects.count >= 1, objects.count <= 2 else { throw managedImportFailure("invalid_object_authority") }
        let prefix = "objects/project-" + hash(Data(pid.utf8)) + "/" + id
        guard original == prefix || (original.hasPrefix(prefix + ".") && String(original.dropFirst(prefix.count + 1)).range(of:"^[A-Za-z0-9]{1,16}$",options:.regularExpression) != nil) else { throw managedImportFailure("invalid_object_authority") }
        var names: Set<String> = []
        for object in objects {
            guard let name = object["representation"] as? String, ["original","preview"].contains(name), names.insert(name).inserted, object["stage"] as? String == "staging/attachment-imports/" + key + "/" + name, object["final"] as? String == original + (name == "preview" ? ".preview.png" : ""), let sha = object["sha256"] as? String, sha.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil, let count = object["size"] as? Int, count >= 0, count <= (name == "original" ? 500 * 1024 * 1024 : 8 * 1024 * 1024) else { throw managedImportFailure("invalid_object_authority") }
        }
        guard names.contains("original") else { throw managedImportFailure("missing_original_authority") }
        guard let originalObject = objects.first(where: {$0["representation"] as? String == "original"}), originalObject["sha256"] as? String == job["sha256"] as? String, int(originalObject,"size",default:-1) == int(job,"size",default:-2) else { throw managedImportFailure("original_identity_mismatch") }
        return objects
    }
    func managedImportPreview(_ bytes: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData,nil), let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:512,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output,UTType.png.identifier as CFString,1,nil) else { return nil }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination), output.length <= 8 * 1024 * 1024 else { return nil }
        return output as Data
    }
    func managedImportExists(_ files: StorageObjectFiles,_ path: String) throws -> Bool {
        let directory: Int32, name: String
        do { (directory,name) = try files.parent(path) }
        catch { if StorageFolderAccess.isMissing(error) { return false };throw error }
        defer { Darwin.close(directory) }
        var info = stat()
        if fstatat(directory,name,&info,AT_SYMLINK_NOFOLLOW) != 0 { guard errno == ENOENT else { throw managedImportFailure("object_observation_failed") }; return false }
        guard info.st_mode & S_IFMT == S_IFREG else { throw managedImportFailure("substituted_object_refused") }
        return true
    }
    func verifyManagedImportPresence(_ files: StorageObjectFiles,_ path: String,_ object: JSON) throws {
        let size = try files.openRegular(path) { file -> Int in var info = stat(); guard fstat(file,&info) == 0 else { throw managedImportFailure("object_observation_failed") }; return Int(info.st_size) }
        guard size == int(object,"size") else { throw managedImportFailure("object_checksum_mismatch") }
    }
    @discardableResult func verifyManagedImportFile(_ files: StorageObjectFiles,_ path: String,_ object: JSON) throws -> FileIdentity {
        let family = path.hasPrefix("staging/") ? "staging" : "objects"
        guard let identity = try managedIdentity(path,family:family) else { throw managedImportFailure("object_observation_failed") }
        let data = try files.read(path,maximum:int(object,"size"))
        guard data.count == int(object,"size"), hash(data) == object["sha256"] as? String,(try? managedIdentity(path,family:family)) == identity else { throw managedImportFailure("object_checksum_mismatch") }
        return identity
    }
    func publishManagedImportFile(_ files: StorageObjectFiles,stage: String,final: String) throws {
        let (source,name) = try files.parent(stage), (destination,target) = try files.parent(final,create:true)
        defer { Darwin.close(source); Darwin.close(destination) }
        guard linkat(source,name,destination,target,0) == 0 else { throw managedImportFailure("object_publication_failed") }
        guard fsync(destination) == 0, fsync(source) == 0 else { throw managedImportFailure("object_publication_flush_uncertain") }
    }
    func synchronizeManagedImportPublication(_ files: StorageObjectFiles,path: String) throws {
        let (directory,_) = try files.parent(path); defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else { throw managedImportFailure("object_publication_flush_uncertain") }
    }
    func removeManagedImportStage(_ db: Database,files: StorageObjectFiles,path: String) throws {
        let absolute = root.appendingPathComponent(path).path
        guard try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE type='attachment' AND CASE WHEN json_valid(data) THEN json_extract(data,'$.path')=CAST(? AS TEXT) COLLATE BINARY OR json_extract(data,'$.preview_path')=CAST(? AS TEXT) COLLATE BINARY OR json_extract(data,'$.path')=CAST(? AS TEXT) COLLATE BINARY OR json_extract(data,'$.preview_path')=CAST(? AS TEXT) COLLATE BINARY ELSE 1 END",arguments:[Data(absolute.utf8),Data(absolute.utf8),Data(path.utf8),Data(path.utf8)]) == 0 else { throw managedImportFailure("staging_reference_retained") }
        guard try managedImportExists(files,path) else { return }
        try StorageSnapshotRetention.requireNoCapture(root:files.root)
        let (directory,name) = try files.parent(path); defer { Darwin.close(directory) }
        guard unlinkat(directory,name,0) == 0, fsync(directory) == 0 else { throw managedImportFailure("stage_cleanup_pending") }
    }

    func persistManagedAttachmentReadFailure(_ db: Database,method: String,params p: JSON,caller c: Caller,error: Error) throws {
        guard method == "attachment_read", p["representation"] as? String == "original", let observation = error as? ManagedOriginalReadFailure else { return }
        try withValidatedDomainTransaction(db) {
            let pid = try self.scope(db,p,c), aid = try text(p,"attachment_id")
            var attachment = try self.scoped(db,aid,pid,type:"attachment")
            // Reauthorize and compare the original failed-read basis after
            // rollback. An unrelated error or a newer identity is not damage.
            guard EnvelopeStorageIdentity.equal(pid,observation.projectID), EnvelopeStorageIdentity.equal(aid,observation.attachmentID), int(attachment,"revision") == observation.revision, EnvelopeStorageIdentity.equal(attachment["path"] as? String,observation.path), EnvelopeStorageIdentity.equal(attachment["sha256"] as? String,observation.sha256), attachment["mode"] as? String == "managed", attachment["availability"] as? String == "available" else { return .commit }
            attachment["availability"] = "unavailable"; attachment["availability_error"] = observation.failure.code
            try self.save(db,self.revised(attachment),type:"attachment")
            if let id = attachment["storage_job_id"] as? String {
                var job = try self.scoped(db,id,pid,type:"storage_job")
                guard EnvelopeStorageIdentity.equal(job["attachment_id"] as? String,attachment["id"] as? String) else { throw self.managedImportFailure("read_recovery_reference_changed") }
                job["state"] = "repair_required"; try self.saveManagedImportProgress(db,self.revised(job))
            }
            return .commit
        }
    }

    /// Rebuildable, connection-local selection. Every writer path (including
    /// direct SQL, UPSERT, REPLACE and rollback) updates it in the same transaction.
    /// Retained settled/other jobs can contain hundreds of MB of JSON; reparsing
    /// that corpus after every ordinary note is not recovery work.
    @discardableResult func ensureManagedImportRecoveryIndex(_ db: Database) throws -> Bool {
        if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM temp.sqlite_master WHERE type='table' AND name='checklist_import_recovery')") == true {return true}
        // Empty/small fixture stores need no TEMP schema until the first job.
        // The sole writer constructs the complete selection before recovering it.
        guard try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM main.records WHERE type='storage_job')") == true else {return false}
        func candidate(_ prefix: String) -> String {
            "CASE WHEN json_valid(\(prefix)data) THEN CASE WHEN json_type(\(prefix)data)='object' THEN json_extract(\(prefix)data,'$.state') IN ('committed','repair_required') ELSE 1 END ELSE 1 END"
        }
        try db.inSavepoint {
            try db.execute(sql:"CREATE TEMP TABLE checklist_import_recovery(record_rowid INTEGER PRIMARY KEY,source_id BLOB NOT NULL UNIQUE)")
            try db.execute(sql:"INSERT INTO checklist_import_recovery SELECT rowid,CAST(id AS BLOB) FROM main.records WHERE type='storage_job' AND " + candidate(""))
            for action in ["INSERT","UPDATE","DELETE"] {
                let rows = action == "INSERT" ? ["NEW"] : action == "DELETE" ? ["OLD"] : ["OLD","NEW"]
                let remove = rows.map {"DELETE FROM checklist_import_recovery WHERE record_rowid=\($0).rowid OR source_id=CAST(\($0).id AS BLOB);"}.joined()
                let insert = action == "DELETE" ? "" : "INSERT INTO checklist_import_recovery SELECT NEW.rowid,CAST(NEW.id AS BLOB) WHERE NEW.type='storage_job' AND " + candidate("NEW.") + " ON CONFLICT(record_rowid) DO UPDATE SET source_id=excluded.source_id;"
                try db.execute(sql:"CREATE TEMP TRIGGER checklist_import_recovery_" + action.lowercased() + " AFTER " + action + " ON main.records BEGIN " + remove + insert + " END")
            }
            return .commit
        }
        return true
    }

    /// Bounded metadata recovery; never publishes a pending attachment or deletes
    /// a finalized original. Referenced objects and uncertain jobs are retained.
    func reconcileManagedAttachmentImports(_ db: Database) throws -> StorageMaintenanceWarning? {
        guard try ensureManagedImportRecoveryIndex(db) else {return nil}
        let rows = try Row.fetchAll(db,sql:"SELECT r.rowid AS maintenance_position," + Self.canonicalColumns(alias:"r") + " FROM temp.checklist_import_recovery i CROSS JOIN main.records r ON r.rowid=i.record_rowid AND CAST(r.id AS BLOB)=i.source_id WHERE i.record_rowid>? AND r.type='storage_job' ORDER BY i.record_rowid LIMIT 32",arguments:[managedImportMaintenanceAfterRow])
        managedImportMaintenanceAfterRow = rows.count == 32 ? (rows.last!["maintenance_position"] as Int64) : 0
        var warning: StorageMaintenanceWarning?
        for row in rows {
            let key: Data = row["_envelope_id_bytes"] ?? Data()
            if managedImportRecoveryFailures[key,default:0] >= 2 { warning = .suspended; continue }
            do {
                let job = try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"storage_job").object
                try reconcileManagedAttachmentImport(db,job:job)
                managedImportRecoveryFailures.removeValue(forKey:key)
            } catch {
                let failures = min(managedImportRecoveryFailures[key,default:0] + 1,2)
                managedImportRecoveryFailures[key] = failures
                if failures == 2 { warning = .suspended }
                else if warning == nil { warning = .retryPending }
            }
        }
        return warning
    }
    private func reconcileManagedAttachmentImport(_ db: Database,job initial: JSON) throws {
        var job = initial
        guard job["kind"] as? String == "attachment_import" else { return }
        guard ["committed","repair_required"].contains(job["state"] as? String ?? "") else { return }
        let objects = try managedImportObjects(job),
            pid = (try StoredRecord(job,
            family: "ManagedAttachmentImport").string("project_id")),
            aid = (try StoredRecord(job,
            family: "ManagedAttachmentImport").string("attachment_id"))
        guard let principal = job["parent_principal"] as? String, let command = job["parent_command_id"] as? String, let digest = job["intent_digest"] as? String, let receipt = try managedImportReceipt(db,principal:principal,command:command,digest:digest), let result = receipt["data"] as? JSON, EnvelopeStorageIdentity.equal(result["id"] as? String,aid) else { throw managedImportFailure("committed_receipt_missing") }
        var attachment = try scoped(db,aid,pid,type:"attachment")
        guard attachment["storage_job_id"] as? String == job["id"] as? String, attachment["sha256"] as? String == job["sha256"] as? String, (try? managedRelative(attachment["path"] as? String ?? "",family:"objects")) == job["object_relative_path"] as? String else { throw managedImportFailure("committed_reference_changed") }
        let files = try StorageObjectFiles(root:root)
        guard let original = objects.first(where: {$0["representation"] as? String == "original"}) else {
            throw managedImportFailure("original_descriptor_missing")
        }
        do { try verifyManagedImportFile(files,(try StoredRecord(original, family: "ManagedAttachmentImport").string("final")),original) }
        catch {
            try withValidatedDomainTransaction(db) {
                attachment["availability"] = "unavailable"; try self.save(db,self.revised(attachment),type:"attachment")
                job["state"] = "repair_required"; try self.saveManagedImportProgress(db,self.revised(job)); return .commit
            }
            throw managedImportFailure("committed_object_unavailable")
        }
        var previewUnavailable = false
        if job["preview_available"] as? Bool == true, let preview = objects.first(where: {$0["representation"] as? String == "preview"}) {
            do { try verifyManagedImportFile(files,(try StoredRecord(preview, family: "ManagedAttachmentImport").string("final")),preview) }
            catch { previewUnavailable = true }
        }
        for object in objects { try removeManagedImportStage(db,files:files,path:(try StoredRecord(object, family: "ManagedAttachmentImport").string("stage"))) }
        try withValidatedDomainTransaction(db) {
            let restoreOriginal = attachment["availability"] as? String == "unavailable"
            if restoreOriginal { attachment["availability"] = "available"; attachment.removeValue(forKey:"availability_error") }
            if previewUnavailable { attachment.removeValue(forKey:"preview_path"); attachment["preview_availability"] = "unavailable"; job["preview_available"] = false }
            if restoreOriginal || previewUnavailable { try self.save(db,self.revised(attachment),type:"attachment") }
            job["state"] = "settled"; try self.saveManagedImportProgress(db,self.revised(job)); return .commit
        }
    }
}
