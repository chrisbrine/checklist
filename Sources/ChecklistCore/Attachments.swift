import Foundation
import CoreFoundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

extension CommandRouter {
    func attachmentWrite(_ db: Database,_ p: JSON,_ c: Caller,_ method: String) throws -> JSON {
        let pid = try scope(db,p,c,write:true)
        try assistantPermission(c,pid,"post_notes_on_request")
        if method == "attachment_update" {
            var a = try scoped(db,try text(p,"attachment_id"),pid,type:"attachment"); try revision(p,a)
            guard a["task_id"] is String else { throw CoreError("MEDIA_STORAGE_UNAVAILABLE","Taskless media commands are not enabled.") }
            switch p["action"] as? String ?? "describe" {
            case "describe": a["description"] = try text(p,"description",required:false)
            case "keep_original": a["keep_original"] = true
            case "release_own_hold": try owner(c); a["keep_original"] = false
            case "unlink": a["unlinked"] = true
            case "restore_link": a["unlinked"] = false
            default: throw CoreError("INVALID_INPUT","Unsupported attachment operation.")
            }
            a = revised(a); try save(db,a,type:"attachment"); return a
        }
        let task = try self.task(db,p,pid)
        if !["reference","external_reference"].contains(p["mode"] as? String ?? "managed") {
            return try commitManagedAttachmentImport(db,p,c,task:task)
        }
        let source = p["source"] as? JSON ?? [:]
        let rawPath = p["path"] as? String ?? source["path"] as? String ?? ""
        guard !rawPath.isEmpty else { throw CoreError("FILE_ACCESS_REQUIRED","Choose a local file.") }
        let path: String
        let project = try record(db,pid,type:"project")
        if source["kind"] as? String == "workspace_file",!rawPath.hasPrefix("/"),let root = project["root_path"] as? String { path = canonical(URL(fileURLWithPath:root).appendingPathComponent(rawPath).path) } else { path = canonical(rawPath) }
        if !c.isOwner { guard let workspace = c.workspace,containsPath(canonical(workspace),path),let projectRoot = project["root_path"] as? String,containsPath(projectRoot,path) else { throw CoreError("FILE_ACCESS_REQUIRED","Agent file imports must stay inside its enrolled workspace.") } }
        let url = URL(fileURLWithPath:path); let values = try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
        guard values.isRegularFile == true else { throw CoreError("INVALID_INPUT","Attach a regular file. Directories can be provided as human-request references.") }
        guard (values.fileSize ?? 0) <= 500 * 1024 * 1024 else { throw CoreError("FILE_TOO_LARGE","This local importer accepts files up to 500 MiB.") }
        let digest: String, size: Int
        if let prepared = commandPreparation.referenceImport,prepared.path == path,prepared.digest == hash(Data((method + (try jsonString(p))).utf8)) {
            // Read and hashed before the writer (CL-71); the unchanged content identity stands for
            // the bytes. A changed file fails here without a second read inside the writer (finding b906f027).
            guard FileIdentity(path:path) == prepared.identity else { throw CoreError("SOURCE_CHANGED","The file changed during import. Retry the import.") }
            digest = prepared.sha256; size = prepared.size
        } else {
            let bytes: Data
            if c.isOwner { bytes = try Data(contentsOf:url,options:.mappedIfSafe) }
            else {
                // The containment check above used a resolved path; the read must not follow a later swap.
                bytes = try SafeFileRead.read(path,maximum:500 * 1024 * 1024,allowedRoots:agentReadRoots(c,project:project)).bytes
            }
            digest = hash(bytes); size = bytes.count
        }
        if let expected = p["expected_sha256"] as? String,expected != digest { throw CoreError("SOURCE_CHANGED","The file changed before import.") }
        let modeInput = p["mode"] as? String ?? "managed"; let mode = ["reference","external_reference"].contains(modeInput) ? "external_reference" : "managed"
        let id = uuid()
        let a: JSON = ["id":id,"project_id":pid,"task_id":task["id"]!,"artifact_id":id,"name":p["name"] ?? url.lastPathComponent,"description":p["description"] ?? "","mode":mode,"path":path,"sha256":digest,"size":size,"availability":"available","keep_original":false,"unlinked":false,"revision":1,"created_at":now(),"author":c.principal,"origin":c.isOwner ? "human_ui" : c.role]
        try save(db,a,type:"attachment"); try event(db,caller:c,project:pid,entity:task["id"] as? String,kind:"attachment_added",data:["attachment_id":id,"name":a["name"]!]); var response = a
        if !c.isOwner { response.removeValue(forKey:"path"); response.removeValue(forKey:"preview_path") }; return response
    }
    func attachmentRead(_ db: Database,_ p: JSON,_ c: Caller,_ method: String) throws -> JSON {
        let pid = try scope(db,p,c)
        if method == "attachment_read" {
            var a = try scoped(db,try text(p,"attachment_id"),pid,type:"attachment")
            guard a["task_id"] is String else { throw CoreError("ATTACHMENT_REFERENCE_REQUIRED","Taskless originals require a current owner reference; media commands are not enabled.") }
            let representation = p["representation"] as? String ?? "metadata"
            if representation == "metadata" { if !c.isOwner { a.removeValue(forKey:"path"); a.removeValue(forKey:"preview_path") }; return a }
            let selected = representation == "preview" ? (a["preview_path"] as? String ?? a["path"] as? String) : a["path"] as? String
            let managedOriginal = representation == "original" && a["mode"] as? String == "managed"
            func observed(_ failure: CoreError,path: String) -> Error {
                guard managedOriginal else { return failure }
                return ManagedOriginalReadFailure(projectID:pid,attachmentID:a["id"] as! String,revision:int(a,"revision"),path:selected ?? path,sha256:a["sha256"] as? String,failure:failure)
            }
            guard let stored = selected else { throw CoreError("ORIGINAL_CLEANED","The original is unavailable; its metadata is retained.") }
            let readsManaged = a["mode"] as? String == "managed" || representation == "preview" && a["preview_path"] != nil
            let path: String
            if readsManaged {
                do { path = try managedURL(stored,family:"objects").path }
                catch let failure as CoreError { throw observed(failure,path:stored) }
            } else { path = stored }
            if !readsManaged,!FileManager.default.fileExists(atPath:path) { throw observed(CoreError("ORIGINAL_CLEANED","The original is unavailable; its metadata is retained."),path:path) }
            if representation != "metadata" {
                let bytes: Data
                do {
                    if readsManaged {
                        bytes = try managedRead(stored,family:"objects",maximum:c.isOwner ? 500 * 1024 * 1024 : 8 * 1024 * 1024)
                    } else if c.isOwner { bytes = try Data(contentsOf:URL(fileURLWithPath:path),options:.mappedIfSafe) }
                    else {
                        // Agents receive the bytes. A stored path is opened without following a
                        // swapped symlink and must still resolve inside the store or the workspace.
                        let project = try record(db,pid,type:"project")
                        let roots = a["mode"] as? String == "managed" ? [canonical(root.path)] : agentReadRoots(c,project:project)
                        bytes = try SafeFileRead.read(path,maximum:8 * 1024 * 1024,allowedRoots:roots).bytes
                    }
                }
                catch let refusal as CoreError where !c.isOwner && refusal.code == "FILE_TOO_LARGE" { throw CoreError("FILE_TOO_LARGE","This file exceeds the bounded MCP read limit.") }
                catch {
                    guard managedOriginal else { throw error }
                    // Attribute only the actual managed-original open/read. Raw
                    // Cocoa descriptions can contain paths and are not public.
                    throw observed(CoreError("MANAGED_ORIGINAL_UNAVAILABLE","The managed original could not be read.",details:["reason":"original_open_or_read_failed"]),path:path)
                }
                // Without a separate preview file, a "preview" read returns the original's
                // bytes and so needs the same immutable identity check.
                let separatePreview = representation == "preview" && a["preview_path"] is String
                guard separatePreview || hash(bytes) == a["sha256"] as? String else { throw observed(CoreError("SOURCE_CHANGED","The original no longer matches its immutable identity."),path:path) }
                if representation == "original", a["mode"] as? String == "managed", a["availability"] as? String == "unavailable" {
                    a["availability"] = "available"; a.removeValue(forKey:"availability_error"); a = revised(a); try save(db,a,type:"attachment")
                    if let job = a["storage_job_id"] as? String { managedImportRecoveryFailures.removeValue(forKey:Data(job.utf8)) }
                }
                if c.isOwner {
                    a["url"] = path
                    if representation == "original",a["mode"] as? String == "managed" {
                        let holdID = uuid(),expiry = Date().addingTimeInterval(300)
                        try save(db,["id":holdID,"project_id":pid,"kind":"reader","attachment_id":a["id"]!,"state":"active","expires_at":expiry.timeIntervalSince1970,"author":c.principal,"revision":1,"created_at":now()],type:"storage_hold")
                        a["read_hold_id"] = holdID;a["read_hold_expires_at"] = ISO8601DateFormatter().string(from:expiry)
                    }
                } else { guard bytes.count <= 8 * 1024 * 1024 else { throw CoreError("FILE_TOO_LARGE","This file exceeds the bounded MCP read limit.") }; a["content_base64"] = bytes.base64EncodedString() }
            }
            if !c.isOwner { a.removeValue(forKey:"path"); a.removeValue(forKey:"preview_path") }; return a
        }
        let t = try task(db,p,pid); let attachments = try records(db,type:"attachment",project:pid).filter { $0["task_id"] as? String == t["id"] as? String && !bool($0,"unlinked") }
        if method == "attachment_cleanup_preview" { return try cleanupPreview(db,task:t) }
        return ["attachments":attachments.map { a -> JSON in var a = a; if !c.isOwner { a.removeValue(forKey:"path"); a.removeValue(forKey:"preview_path") }; return a }]
    }
    /// An agent may read only where its actual workspace and the enrolled project root overlap.
    func agentReadRoots(_ c: Caller,project: JSON) -> [String] {
        guard let workspace = c.workspace.map(canonical),let projectRoot = (project["root_path"] as? String).map(canonical),!projectRoot.isEmpty else { return [] }
        if containsPath(workspace,projectRoot) { return [projectRoot] }
        if containsPath(projectRoot,workspace) { return [workspace] }
        return []
    }
    func cleanupPreview(_ db: Database,task: JSON) throws -> JSON {
        try archiveRetentionPreview(db,task:task)
    }
    func cleanupHoldReasons(_ db: Database,attachment: JSON,task: JSON) throws -> [String] {
        let pid = task["project_id"] as! String,tid = task["id"] as! String,id = attachment["id"] as! String
        var reasons: [String] = []
        if bool(attachment,"keep_original") { reasons.append("Keep original") }
        if task["active_attempt_id"] != nil || task["active_verification_request_id"] != nil { reasons.append("Active work or verification") }
        if try records(db,type:"request",project:pid).contains(where: {$0["task_id"] as? String == tid && $0["state"] as? String == "pending" && $0["target_attachment_id"] as? String == id}) { reasons.append("Pending human inspection") }
        if let mid = task["current_manifest_id"] as? String,let manifest = try? scoped(db,mid,pid,type:"manifest"),((manifest["evidence"] as? JSON)?["artifact_refs"] as? [JSON] ?? []).contains(where: {$0["artifact_id"] as? String == id}),try records(db,type:"review_request",project:pid).contains(where: {$0["task_id"] as? String == tid && $0["manifest_id"] as? String == mid && ["queued","active","human_pending","blocked"].contains($0["state"] as? String ?? "")}) { reasons.append("Current review target") }
        for hold in try records(db,type:"storage_hold") where hold["state"] as? String == "active" {
            if let expiry = hold["expires_at"] as? Double,expiry <= Date().timeIntervalSince1970 { continue }
            if hold["attachment_id"] as? String == id || strings(hold,"attachment_ids").contains(id) { reasons.append(hold["kind"] as? String == "backup" ? "Backup capture" : "Active reader") }
        }
        return Array(Set(reasons)).sorted()
    }
    func releaseAttachmentRead(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try owner(c);let pid = try scope(db,p,c);var hold = try scoped(db,try text(p,"read_hold_id"),pid,type:"storage_hold")
        guard hold["kind"] as? String == "reader" else { throw CoreError("FORBIDDEN","This is not a reader lease.") }
        hold["state"] = "released";hold = revised(hold);try save(db,hold,type:"storage_hold");return hold
    }
    func exportProject(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        throw CoreError("STORAGE_BOUNDARY_REQUIRED","Project export requires a protected capture outside the command transaction.")
    }

    /// The root permit protects capture through publication; scoped reader holds also
    /// name the exact attachment identities. Only metadata and receipts use a writer
    /// transaction. Large copies/hashes run with no SQL transaction open (CL-71).
    func executeProjectExport(_ db: Database,_ p: JSON,_ c: Caller,permit: ArchiveStoragePermit,observe: (String) throws -> Void = { _ in }) throws -> JSON {
        try owner(c);try permit.requireRoot(root)
        guard !db.isInsideTransaction else { throw CoreError("STORAGE_BOUNDARY_REQUIRED","Export cannot copy files in a writer transaction.") }
        let command = try text(p,"command_id",max:100)
        guard UUID(uuidString:command) != nil else { throw CoreError("INVALID_INPUT","command_id must be a UUID.") }
        let digest = hash(Data(("export_project" + (try jsonString(p))).utf8))
        var captured: JSON = [:], replay: JSON?, pid = "", holds: [String] = []
        try withValidatedDomainTransaction(db) {
            pid = try self.scope(db,p,c)
            try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:c)
            if let row = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[c.principal,command]) {
                guard row["digest"] as String == digest else { throw CoreError("IDEMPOTENCY_CONFLICT","This command ID already belongs to another original intent.") }
                replay = jsonObject(row["result"])
                if Self.isPrunedResult(replay ?? [:]) { throw Self.expiredCommandError(command) }
                return .commit
            }
            captured = try self.projectExportRecords(db,pid:pid)
            for attachment in captured["attachment"] as? [JSON] ?? [] where attachment["mode"] as? String == "managed" && attachment["availability"] as? String == "available" {
                let id = uuid();holds.append(id)
                try self.save(db,["id":id,"project_id":pid,"kind":"reader","purpose":"project_export","attachment_id":attachment["id"]!,
                    "sha256":attachment["sha256"]!,"size":attachment["size"]!,"state":"active","author":c.principal,
                    "expires_at":Date().addingTimeInterval(300).timeIntervalSince1970,"revision":1,"created_at":now()],type:"storage_hold")
            }
            return .commit
        }
        if var replay { replay["replayed"] = true;return replay }
        defer {
            try? db.inTransaction {
                for id in holds { var hold = try self.record(db,id,type:"storage_hold");hold["state"] = "released";try self.save(db,self.revised(hold),type:"storage_hold") }
                return .commit
            }
        }
        try observe("captured")
        let path = canonical(try text(p,"path")),destination = URL(fileURLWithPath:path),parent = destination.deletingLastPathComponent()
        let partial = parent.appendingPathComponent("." + destination.lastPathComponent + ".checklist-export-" + uuid())
        let publication = ExportPublication(destination:destination,principal:c.principal,command:command,digest:digest,partial:partial,journal:"staging/pending-exports/" + uuid() + ".json")
        if FileManager.default.fileExists(atPath:path) {
            guard publication.isOwnUncommittedExport() else { throw CoreError("DESTINATION_EXISTS","Choose a new export directory.") }
            try FileManager.default.removeItem(at:destination)
        }
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        try publication.recordPending(StorageObjectFiles(root:root))
        do {
            try FileManager.default.createDirectory(at:partial,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            try writeProjectExport(captured,directory:partial)
            try publication.writeMarker(in:partial)
            guard renamex_np(partial.path,destination.path,UInt32(RENAME_EXCL)) == 0 else { throw CoreError("DESTINATION_EXISTS","Choose a new export directory.") }
            exportPublications.append(publication)
        } catch {
            try? FileManager.default.removeItem(at:partial);publication.forgetPending(root:root);throw error
        }
        try observe("published")
        var output: JSON = [:]
        try withValidatedDomainTransaction(db) {
            _ = try self.scope(db,p,c)
            try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:c)
            output = ["data":["path":path,"project_id":pid,"format":"checklist-project","restore_supported":false],
                "command_id":command,"event_cursor":try self.cursor(db,caller:c,scope:self.authorizationScope(db,c))]
            try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[c.principal,command,digest,try jsonString(output)])
            return .commit
        }
        return output
    }
    /// After the command: a committed export loses its owner marker and pending record; an
    /// export whose command has no receipt (the transaction or the receipt rolled back) is removed.
    func finishExportPublications(_ exports: [ExportPublication]) {
        guard !exports.isEmpty else { return }
        try? ArchiveStorageGate.withExclusive(root:root) { _ in
            for export in exports {
                let committed = try? dbQueue.read { db in try self.exportReceiptCommitted(db,export:export) }
                // Unknown outcome: the marker and the pending record stay for startup or a same-command retry.
                if let committed { reconcileExport(export,committed:committed) }
            }
        }
    }
    /// No receipt means rollback cleanup; an exact receipt means commit cleanup.
    /// A receipt for another intent is uncertain and authorizes neither cleanup path.
    func exportReceiptCommitted(_ db: Database,export: ExportPublication) throws -> Bool? {
        guard let digest = try String.fetchOne(db,sql:"SELECT digest FROM commands WHERE principal=CAST(? AS TEXT) AND command_id=CAST(? AS TEXT)",arguments:[Data(export.principal.utf8),Data(export.command.utf8)]) else { return false }
        return EnvelopeStorageIdentity.equal(digest,export.digest) ? true : nil
    }
    /// Shared by the post-command path and the startup sweep. The pending record goes only
    /// after its cleanup is complete, so a later startup retries a removal that failed, for
    /// example while the export parent was not writable (finding 2e21045b).
    /// A destination whose ownership cannot be read (for example an unreadable marker) also
    /// keeps its record; nothing is removed until the marker can be read (finding 4b933bf0).
    func reconcileExport(_ export: ExportPublication,committed: Bool) {
        var complete = true
        if committed {
            switch export.ownership() { case .own: complete = removeExportItem(export.marker); case .unknown: complete = false; case .foreign: break }
        } else if let partial = export.partial, export.ownsPartialName(partial) {
            // The published folder goes back to its recorded private name in one rename, so a
            // removal that stops partway leaves no folder at the destination without its marker.
            complete = removeExportItem(partial)
            if complete {
                switch export.ownership() {
                case .own: complete = renamex_np(export.destination.path,partial.path,UInt32(RENAME_EXCL)) == 0 && removeExportItem(partial)
                case .unknown: complete = false
                case .foreign: break
                }
            }
        } else {
            switch export.ownership() { case .own: complete = removeExportItem(export.destination); case .unknown: complete = false; case .foreign: break }
        }
        if complete { export.forgetPending(root:root) }
    }
    /// True when nothing is left at `item`.
    private func removeExportItem(_ item: URL) -> Bool {
        var info = stat()
        if lstat(item.path,&info) != 0 { return errno == ENOENT }
        try? FileManager.default.removeItem(at:item)
        return lstat(item.path,&info) != 0 && errno == ENOENT
    }
    static let projectExportTypes = ["policy_revision","task","relation","task_alias","status","tag","message","conversation","delivery","request","group","attachment","review","review_request","finding","finding_resolution","manifest","attempt","session","task_session","source_capture","source_execution","batch","batch_claim","triage_membership_interval","triage_membership_exit","project_context_revision","direction_disposition","checkpoint","policy_proposal","taxonomy_revision","storage_job","storage_hold"] + MediaRecordRegistry.families.sorted()

    func projectExportRecords(_ db: Database,pid: String) throws -> JSON {
        // Validate ALL project envelopes before applying the portable projection. An
        // unknown required family must fail, rather than vanish behind an allowlist.
        let envelopes = try MediaRecordRegistry.envelopes(db,project:pid)
        try MediaRecordRegistry.validate(envelopes)
        var exported: JSON = ["format":"checklist-project","schema_version":1,"exported_at":now(),"project":try record(db,pid,type:"project")]
        for type in Self.projectExportTypes {
            var values = try records(db,type:type,project:pid)
            if type == "storage_hold" { values = values.filter { $0["kind"] as? String == "media_reference" } }
            if type == "storage_job" {
                values = values.filter { $0["kind"] as? String == "media_attachment_owner" || $0["kind"] as? String == "attachment_import" && $0["attachment_owner_id"] is String }
            }
            for i in values.indices {
                if type == "attachment",values[i]["mode"] as? String == "managed",values[i]["availability"] as? String == "available" {
                    guard let path = values[i]["path"] as? String,
                          let sha = values[i]["sha256"] as? String,sha.utf8.count == 64,
                          sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                          let size = values[i]["size"] as? NSNumber,CFGetTypeID(size) != CFBooleanGetTypeID(),
                          size.stringValue == "0" || (try? EnvelopeInteger.positiveExact(size.stringValue)) != nil else {
                        throw CoreError("MEDIA_CAPTURE_INCOMPLETE","An available original has incomplete capture metadata.")
                    }
                    _ = try managedRelative(path,family:"objects")
                }
                for key in ["token_hash","incarnation","session_generation","authorization_generation"] { values[i].removeValue(forKey:key) }
                if type == "session" { values[i]["project_ids"] = [pid] }
            }
            exported[type] = values
        }
        var included = Set([Data(pid.utf8)])
        for type in Self.projectExportTypes {
            for value in exported[type] as? [JSON] ?? [] { if let id = value["id"] as? String { included.insert(Data(id.utf8)) } }
        }
        for envelope in envelopes where MediaRecordRegistry.families.contains(envelope.type) {
            for reference in envelope.object["record_references"] as? [JSON] ?? [] {
                guard let id = reference["id"] as? String,included.contains(Data(id.utf8)) else {
                    throw CoreError("MEDIA_CAPTURE_INCOMPLETE","A required media dependency is excluded from portable project export.")
                }
            }
        }
        let jobs = exported["storage_job"] as? [JSON] ?? []
        exported["media_capture"] = ["format":1,"staging_bytes_included":false,"ownership":"committed_only",
            "uncommitted_import_job_ids":jobs.filter { $0["kind"] as? String == "attachment_import" && $0["state"] as? String != "committed" }.compactMap { $0["id"] as? String }]
        let profileIDs = Set((exported["session"] as? [JSON] ?? []).compactMap {$0["profile_id"] as? String})
        exported["profiles"] = try records(db,type:"profile").filter {profileIDs.contains($0["id"] as? String ?? "")}
        exported["events"] = try Row.fetchAll(db,sql:"SELECT id,entity_id,actor,kind,occurred_at,data FROM events WHERE project_id=? ORDER BY seq",arguments:[pid]).map { row -> JSON in ["id":row["id"] as String,"entity_id":row["entity_id"] as String? ?? "","actor":row["actor"] as String,"kind":row["kind"] as String,"occurred_at":row["occurred_at"] as String,"data":jsonObject(row["data"])] }
        return exported
    }
    func writeProjectExport(_ captured: JSON,directory: URL) throws {
        var exported = captured
        if var project = exported["project"] as? JSON,let iconPath = project["icon_path"] as? String,let asset = project["icon_asset"] as? JSON {
            let bytes = try managedRead(iconPath,family:"icons",maximum:5 * 1024 * 1024);guard hash(bytes) == asset["sha256"] as? String else { throw CoreError("SOURCE_CHANGED","The project icon failed checksum validation.") }
            let relative = "icons/"+(asset["id"] as! String)+".png";try FileManager.default.createDirectory(at:directory.appendingPathComponent("icons"),withIntermediateDirectories:true);try bytes.write(to:directory.appendingPathComponent(relative),options:.atomic);project["icon_path"] = relative;exported["project"] = project
        }
        for type in Self.projectExportTypes {
            var values = exported[type] as? [JSON] ?? []
            for i in values.indices {
                if type == "attachment",values[i]["mode"] as? String == "managed",values[i]["availability"] as? String == "available",let original = values[i]["path"] as? String {
                    let bytes = try managedRead(original,family:"objects",maximum:500 * 1024 * 1024)
                    guard hash(bytes) == values[i]["sha256"] as? String,bytes.count == int(values[i],"size") else { throw CoreError("SOURCE_CHANGED","An export object failed checksum validation.") }
                    let relative = "objects/"+(values[i]["id"] as! String);try FileManager.default.createDirectory(at:directory.appendingPathComponent("objects"),withIntermediateDirectories:true);try bytes.write(to:directory.appendingPathComponent(relative),options:.atomic);values[i]["path"] = relative
                }
                if type == "attachment",let path = values[i]["preview_path"] as? String {
                    let bytes = try managedRead(path,family:"objects",maximum:500 * 1024 * 1024)
                    let relative = "previews/"+(values[i]["id"] as! String)+".png";try FileManager.default.createDirectory(at:directory.appendingPathComponent("previews"),withIntermediateDirectories:true);try bytes.write(to:directory.appendingPathComponent(relative),options:.atomic);values[i]["preview_path"] = relative
                }
                if type == "source_capture" { values[i] = try exportSourceCapture(values[i],directory:directory) }
                if type == "source_execution" { values[i] = try exportSourceExecution(values[i],directory:directory) }
                if type == "manifest" { values[i] = try exportSourceManifest(values[i]) }
            }
            exported[type] = values
        }
        try Data((try jsonString(exported)).utf8).write(to:directory.appendingPathComponent("project.json"),options:.atomic)
    }
    func backup(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        // Public handle intercepts backup_create before entering its semantic
        // transaction; keep direct dispatch from creating a metadata-only copy.
        throw StoreRecovery.required("backup_requires_storage_boundary")
    }
}

/// One export folder that a command published before its receipt committed.
struct ExportPublication {
    static let markerName = ".checklist-export-owner.json"
    let destination: URL
    let principal: String
    let command: String
    let digest: String
    var partial: URL? = nil
    /// Store-relative pending record, written before the partial folder exists.
    var journal: String? = nil
    var marker: URL { destination.appendingPathComponent(Self.markerName) }

    func recordPending(_ files: StorageObjectFiles) throws {
        guard let journal else { return }
        let body: [String: Any] = ["destination": destination.path, "partial": partial?.path ?? "", "principal": principal, "command_id": command, "digest": digest, "source_root":files.root.path, "created_at": ISO8601DateFormatter().string(from: Date())]
        try files.writeNew(journal, bytes: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
    }
    func forgetPending(root: URL) {
        guard let journal, let files = try? StorageObjectFiles(root: root), let (directory, name) = try? files.parent(journal) else { return }
        unlinkat(directory, name, 0); fsync(directory); Darwin.close(directory)
    }
    /// The partial folder is ours only by its exact recorded name beside the destination.
    func ownsPartialName(_ folder: URL) -> Bool {
        folder.deletingLastPathComponent().path == destination.deletingLastPathComponent().path && folder.lastPathComponent.hasPrefix("." + destination.lastPathComponent + ".checklist-export-")
    }
    static func pending(from data: Data, journal: String) -> ExportPublication? {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let destination = body["destination"] as? String, destination.hasPrefix("/"),
              let principal = body["principal"] as? String, let command = body["command_id"] as? String, let digest = body["digest"] as? String else { return nil }
        let partial = (body["partial"] as? String).flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        return ExportPublication(destination: URL(fileURLWithPath: destination), principal: principal, command: command, digest: digest, partial: partial, journal: journal)
    }

    func writeMarker(in folder: URL) throws {
        let body: [String: Any] = ["principal": principal, "command_id": command, "digest": digest]
        try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]).write(to: folder.appendingPathComponent(Self.markerName), options: .withoutOverwriting)
    }

    enum Ownership { case own, foreign, unknown }
    /// `own` only for a real folder (not a symlink) whose regular marker file names this exact
    /// command. `foreign` when nothing is there, the item is not a folder, the marker is missing
    /// or names another command. `unknown` when the folder or marker exists but cannot be read.
    func ownership() -> Ownership {
        guard !command.isEmpty else { return .foreign }
        var info = stat()
        if lstat(destination.path, &info) != 0 { return errno == ENOENT ? .foreign : .unknown }
        guard info.st_mode & S_IFMT == S_IFDIR else { return .foreign }
        if lstat(marker.path, &info) != 0 { return errno == ENOENT ? .foreign : .unknown }
        guard info.st_mode & S_IFMT == S_IFREG else { return .foreign }
        guard let data = try? Data(contentsOf: marker), let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unknown }
        return body["principal"] as? String == principal && body["command_id"] as? String == command && body["digest"] as? String == digest ? .own : .foreign
    }
    func isOwnUncommittedExport() -> Bool { ownership() == .own }
}
