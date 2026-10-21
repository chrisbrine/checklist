import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

extension CommandRouter {
    func attachmentWrite(_ db: Database,_ p: JSON,_ c: Caller,_ method: String) throws -> JSON {
        let pid = try scope(db,p,c,write:true)
        try assistantPermission(c,pid,"post_notes_on_request")
        if method == "attachment_update" {
            var a = try scoped(db,try text(p,"attachment_id"),pid,type:"attachment"); try revision(p,a)
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
        let bytes = try Data(contentsOf:url,options:.mappedIfSafe); let digest = hash(bytes)
        if let expected = p["expected_sha256"] as? String,expected != digest { throw CoreError("SOURCE_CHANGED","The file changed before import.") }
        let modeInput = p["mode"] as? String ?? "managed"; let mode = ["reference","external_reference"].contains(modeInput) ? "external_reference" : "managed"
        let id = uuid(); var storedPath = path
        if mode == "managed" {
            // Project-private immutable object paths prevent cross-project dedup disclosure.
            let directory = root.appendingPathComponent("objects").appendingPathComponent(pid)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let suffix = url.pathExtension.range(of:"^[A-Za-z0-9]{1,16}$",options:.regularExpression) != nil ? "."+url.pathExtension : ""
            let object = directory.appendingPathComponent(id+suffix)
            try bytes.write(to:object,options:[.atomic]); storedPath = object.path
            let verify = try Data(contentsOf:url,options:.mappedIfSafe)
            guard hash(verify) == digest else { try? FileManager.default.removeItem(at:object); throw CoreError("SOURCE_CHANGED","The source changed during import.") }
        }
        var a: JSON = ["id":id,"project_id":pid,"task_id":task["id"]!,"artifact_id":id,"name":p["name"] ?? url.lastPathComponent,"description":p["description"] ?? "","mode":mode,"path":storedPath,"sha256":digest,"size":bytes.count,"availability":"available","keep_original":false,"unlinked":false,"revision":1,"created_at":now(),"author":c.principal,"origin":c.isOwner ? "human_ui" : c.role]
        if mode == "managed",let source = CGImageSourceCreateWithData(bytes as CFData,nil),let thumbnail = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:512,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) {
            let preview = URL(fileURLWithPath:storedPath+".preview.png"); if let destination = CGImageDestinationCreateWithURL(preview as CFURL,UTType.png.identifier as CFString,1,nil) { CGImageDestinationAddImage(destination,thumbnail,nil); if CGImageDestinationFinalize(destination) { a["preview_path"] = preview.path } }
        }
        try save(db,a,type:"attachment"); try event(db,caller:c,project:pid,entity:task["id"] as? String,kind:"attachment_added",data:["attachment_id":id,"name":a["name"]!]); var response = a
        if !c.isOwner { response.removeValue(forKey:"path"); response.removeValue(forKey:"preview_path") }; return response
    }
    func attachmentRead(_ db: Database,_ p: JSON,_ c: Caller,_ method: String) throws -> JSON {
        let pid = try scope(db,p,c)
        if method == "attachment_read" {
            var a = try scoped(db,try text(p,"attachment_id"),pid,type:"attachment")
            let representation = p["representation"] as? String ?? "metadata"
            if representation == "metadata" { if !c.isOwner { a.removeValue(forKey:"path"); a.removeValue(forKey:"preview_path") }; return a }
            let selected = representation == "preview" ? (a["preview_path"] as? String ?? a["path"] as? String) : a["path"] as? String
            guard let path = selected,FileManager.default.fileExists(atPath:path) else { throw CoreError("ORIGINAL_CLEANED","The original is unavailable; its metadata is retained.") }
            if representation != "metadata" {
                let bytes = try Data(contentsOf:URL(fileURLWithPath:path),options:.mappedIfSafe); guard representation == "preview" || hash(bytes) == a["sha256"] as? String else { throw CoreError("SOURCE_CHANGED","The original no longer matches its immutable identity.") }
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
    func cleanupPreview(_ db: Database,task: JSON) throws -> JSON {
        let pid = task["project_id"] as! String,tid = task["id"] as! String
        let attachments = try records(db,type:"attachment",project:pid).filter {$0["task_id"] as? String == tid && $0["mode"] as? String == "managed" && $0["availability"] as? String == "available"}
        let held = try attachments.filter { !(try cleanupHoldReasons(db,attachment:$0,task:task)).isEmpty }
        let eligible = attachments.filter { a in !held.contains(where: {$0["id"] as? String == a["id"] as? String}) }.sorted { int($0,"size") > int($1,"size") }
        var retained = attachments.reduce(0) {$0+int($1,"size")}; var clean: [String] = []
        for a in eligible where int(a,"size") >= 20*1024*1024 || retained > 50*1024*1024 { clean.append(a["id"] as! String); retained -= int(a,"size") }
        let fingerprint = hash(Data((try jsonString(attachments.map { ["id":$0["id"]!,"revision":$0["revision"]!] })).utf8))
        let plan: JSON = ["id":uuid(),"project_id":pid,"task_id":tid,"cleanup_preview_id":uuid(),"task_revision":task["revision"]!,"fingerprint":fingerprint,"attachment_ids":clean,"clean_bytes":attachments.filter {clean.contains($0["id"] as! String)}.reduce(0) {$0+int($1,"size")},"retained_bytes":retained,"held_bytes":held.reduce(0) {$0+int($1,"size")},"reason":"Managed originals at least 20 MiB and retained files over the ticket's 50 MiB budget are eligible. Keep-original and active approval targets are protected.","revision":1]
        try save(db,plan,type:"cleanup_preview"); return plan
    }
    func queueCleanup(_ db: Database,task: JSON,previewID: String?) throws {
        let current = try cleanupPreview(db,task:task)
        guard int(current,"clean_bytes") > 0 else { return }
        guard let id = previewID,let preview = try records(db,type:"cleanup_preview",project:task["project_id"] as? String).first(where: {$0["cleanup_preview_id"] as? String == id}),preview["task_id"] as? String == task["id"] as? String,preview["fingerprint"] as? String == current["fingerprint"] as? String,int(preview,"task_revision") == int(task,"revision"),Set(strings(preview,"attachment_ids")) == Set(strings(current,"attachment_ids")) else { throw CoreError("CLEANUP_PREVIEW_REQUIRED","Review the current archive cleanup summary before archiving large files.",details:current) }
        for id in strings(current,"attachment_ids") { var a = try record(db,id,type:"attachment"); a["cleanup_state"] = "pending"; try save(db,revised(a),type:"attachment") }
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
    func processPendingCleanup(_ db: Database) throws {
        for var a in try records(db,type:"attachment") where ["pending","held"].contains(a["cleanup_state"] as? String ?? "") {
            guard a["mode"] as? String == "managed",let path = a["path"] as? String,containsPath(root.appendingPathComponent("objects").path,canonical(path)),let pid = a["project_id"] as? String,let tid = a["task_id"] as? String,let task = try? scoped(db,tid,pid,type:"task") else { continue }
            guard bool(task,"archived") else { a["cleanup_state"] = "canceled";a["cleanup_reason"] = "Task is no longer archived";try save(db,revised(a),type:"attachment");continue }
            let reasons = try cleanupHoldReasons(db,attachment:a,task:task)
            if !reasons.isEmpty {
                if a["cleanup_state"] as? String != "held" || strings(a,"cleanup_hold_reasons") != reasons { a["cleanup_state"] = "held";a["cleanup_hold_reasons"] = reasons;try save(db,revised(a),type:"attachment") }
                continue
            }
            let current = try cleanupPreview(db,task:task)
            guard strings(current,"attachment_ids").contains(a["id"] as! String) else { a["cleanup_state"] = "canceled";a["cleanup_reason"] = "Current storage policy no longer requires pruning this original";try save(db,revised(a),type:"attachment");continue }
            do {
                if FileManager.default.fileExists(atPath:path) { try FileManager.default.removeItem(atPath:path) }
                a["availability"] = "original_cleaned";a["cleanup_state"] = "complete";a["cleaned_at"] = now();a.removeValue(forKey:"cleanup_hold_reasons");try save(db,revised(a),type:"attachment")
                try event(db,caller:Caller(role:"owner",installation:"storage",projectIDs:[]),project:pid,entity:tid,kind:"attachment_original_cleaned",data:["attachment_id":a["id"]!,"reclaimed_bytes":a["size"]!])
            } catch { a["cleanup_state"] = "failed";a["cleanup_error"] = error.localizedDescription;try save(db,revised(a),type:"attachment") }
        }
    }
    func exportProject(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try owner(c); let pid = try scope(db,p,c); let path = canonical(try text(p,"path")); let directory = URL(fileURLWithPath:path)
        guard !FileManager.default.fileExists(atPath:path) else { throw CoreError("DESTINATION_EXISTS","Choose a new export directory.") }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var exported: JSON = ["format":"checklist-project","schema_version":1,"exported_at":now(),"project":try record(db,pid,type:"project")]
        if var project = exported["project"] as? JSON,let iconPath = project["icon_path"] as? String,let asset = project["icon_asset"] as? JSON {
            let bytes = try Data(contentsOf:URL(fileURLWithPath:iconPath)); guard hash(bytes) == asset["sha256"] as? String else { throw CoreError("SOURCE_CHANGED","The project icon failed checksum validation.") }
            let relative = "icons/"+(asset["id"] as! String)+".png";try FileManager.default.createDirectory(at:directory.appendingPathComponent("icons"),withIntermediateDirectories:true);try bytes.write(to:directory.appendingPathComponent(relative),options:.atomic);project["icon_path"] = relative;exported["project"] = project
        }
        for type in ["policy_revision","task","relation","task_alias","status","tag","message","conversation","delivery","request","group","attachment","review","review_request","finding","finding_resolution","manifest","attempt","session","task_session","source_capture","source_execution","batch","batch_claim","triage_membership_interval","triage_membership_exit","project_context_revision","direction_disposition","checkpoint","policy_proposal","taxonomy_revision"] {
            var records = try self.records(db,type:type,project:pid)
            for i in records.indices { records[i].removeValue(forKey:"token_hash"); records[i].removeValue(forKey:"incarnation"); if type == "attachment",records[i]["mode"] as? String == "managed",records[i]["availability"] as? String == "available",let original = records[i]["path"] as? String {
                let bytes = try Data(contentsOf:URL(fileURLWithPath:original)); guard hash(bytes) == records[i]["sha256"] as? String else { throw CoreError("SOURCE_CHANGED","An export object failed checksum validation.") }; let relative = "objects/"+(records[i]["id"] as! String); try FileManager.default.createDirectory(at:directory.appendingPathComponent("objects"),withIntermediateDirectories:true); try bytes.write(to:directory.appendingPathComponent(relative),options:.atomic); records[i]["path"] = relative
            } }
            if type == "attachment" { for i in records.indices { if let path = records[i]["preview_path"] as? String,FileManager.default.fileExists(atPath:path) { let relative = "previews/"+(records[i]["id"] as! String)+".png";try FileManager.default.createDirectory(at:directory.appendingPathComponent("previews"),withIntermediateDirectories:true);try FileManager.default.copyItem(at:URL(fileURLWithPath:path),to:directory.appendingPathComponent(relative));records[i]["preview_path"] = relative } } }
            if type == "source_capture" { for i in records.indices { records[i] = try exportSourceCapture(records[i], directory: directory) } }
            if type == "source_execution" { for i in records.indices { records[i] = try exportSourceExecution(records[i], directory: directory) } }
            if type == "manifest" { for i in records.indices { records[i] = try exportSourceManifest(records[i]) } }
            exported[type] = records
        }
        let profileIDs = Set((exported["session"] as? [JSON] ?? []).compactMap {$0["profile_id"] as? String})
        exported["profiles"] = try records(db,type:"profile").filter {profileIDs.contains($0["id"] as? String ?? "")}
        exported["events"] = try Row.fetchAll(db,sql:"SELECT id,entity_id,actor,kind,occurred_at,data FROM events WHERE project_id=? ORDER BY seq",arguments:[pid]).map { row -> JSON in ["id":row["id"] as String,"entity_id":row["entity_id"] as String? ?? "","actor":row["actor"] as String,"kind":row["kind"] as String,"occurred_at":row["occurred_at"] as String,"data":jsonObject(row["data"])] }
        try Data((try jsonString(exported)).utf8).write(to:directory.appendingPathComponent("project.json"),options:.atomic)
        return ["path":path,"project_id":pid,"format":"checklist-project","restore_supported":false]
    }
    func backup(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try owner(c)
        // Called while the one writer is held, so object copies and committed records cannot diverge.
        let destination = URL(fileURLWithPath:canonical(try text(p,"path")))
        guard !FileManager.default.fileExists(atPath:destination.path) else { throw CoreError("DESTINATION_EXISTS","Choose a new backup directory.") }
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        let protected = try records(db,type:"attachment").filter {$0["mode"] as? String == "managed" && $0["availability"] as? String == "available"}.compactMap {$0["id"] as? String}
        var hold: JSON = ["id":uuid(),"kind":"backup","attachment_ids":protected,"state":"active","revision":1,"created_at":now()]
        try save(db,hold,type:"storage_hold")
        defer { hold["state"] = "released";try? save(db,revised(hold),type:"storage_hold") }
        var projects: [String] = []
        for project in try self.projects(db,c) { let pid = project["id"] as! String; _ = try exportProject(db,["project_id":pid,"path":destination.appendingPathComponent(pid).path],c); projects.append(pid) }
        let manifest: JSON = ["format":"checklist-backup","schema_version":1,"projects":projects,"created_at":now(),"restore_supported":false]
        try Data((try jsonString(manifest)).utf8).write(to:destination.appendingPathComponent("manifest.json"),options:.atomic)
        return ["path":destination.path,"project_count":projects.count,"restore_supported":false]
    }
}
