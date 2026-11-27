import Foundation
import GRDB
import Darwin

extension CommandRouter {
    /// Pure receipt validation, before any retained Trash pathname is opened.
    /// A copy keeps its incarnation, so that alone cannot authorize a destination.
    /// Legacy destinations without a root binding stay unavailable; never adopt
    /// them by stamping the copy's current root onto historical authority.
    func mediaCleanupTrashBindingFailure(_ receipt: JSON,allowUnboundPageTargets: Bool = false) -> String? {
        let objects = receipt["objects"] as? [JSON] ?? []
        let pending = objects.filter {$0["disposal"] as? String == "trash" && $0["state"] as? String == "pending"}
        guard !pending.isEmpty else {return nil}
        guard receipt["media_trash_directory"] != nil || objects.contains(where:{$0["trash_path"] != nil}) else {return nil}
        guard let source = receipt["media_trash_source_root"] as? String,Data(source.utf8) == Data(root.path.utf8) else {return "trash_source_root_unproven"}
        guard let stored = receipt["media_trash_directory"] as? String,stored.hasPrefix("/"),
              (try? StorageObjectFiles.parts(stored,absolute:true)) != nil,
              let id = receipt["id"] as? String else {return "trash_intent_invalid"}
        let directory = URL(fileURLWithPath:stored,isDirectory:true)
        let folder = "Checklist-media-" + hash(Data((incarnation + ":" + id).utf8)),name = directory.lastPathComponent
        guard name == folder || name.hasPrefix(folder + "-") && UUID(uuidString:String(name.dropFirst(folder.count + 1))) != nil else {return "trash_intent_invalid"}
        for object in pending {
            guard let path = object["relative_path"] as? String,path.hasPrefix("objects/"),
                  (try? StorageObjectFiles.parts(path)) != nil,object["kind"] as? String == "file" else {return "trash_intent_invalid"}
            if allowUnboundPageTargets,object["trash_path"] == nil {continue}
            guard let target = object["trash_path"] as? String else {return "trash_intent_invalid"}
            let expected = directory.appendingPathComponent(hash(Data(path.utf8)) + "-" + URL(fileURLWithPath:path).lastPathComponent).path
            guard Data(target.utf8) == Data(expected.utf8) else {return "trash_intent_invalid"}
        }
        return nil
    }

    /// A durable media Trash intent owns reconciliation of this exact original.
    /// Its source may already have moved before the SQL outcome commits. Import
    /// recovery must not turn that deliberate absence into a new repair owner;
    /// the cleanup read lane still has to prove the retained Trash destination.
    func mediaTrashIntentOwnsImportRecovery(_ db: Database,attachment: JSON) throws -> Bool {
        guard attachment["media_cleanup_round_id"] is String,let id = attachment["id"] as? String,
              let pid = attachment["project_id"] as? String,let stored = attachment["path"] as? String,
              let sha = attachment["sha256"] as? String,let size = (attachment["size"] as? NSNumber)?.int64Value else {return false}
        let path = try managedRelative(stored,family:"objects")
        let rows = try Row.fetchCursor(db,sql:"""
            WITH parents AS (
                SELECT id,project_id,data FROM records
                WHERE type='storage_job' AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.kind')=?
                AND json_type(data,'$.media_trash_directory')='text'
            ), descriptors AS (
                SELECT json_extract(parent.data,'$.media_trash_directory') AS directory,o.value AS object
                FROM parents parent,json_each(parent.data,'$.objects') o
                WHERE json_extract(parent.data,'$.descriptor_page_generation') IS NULL
                UNION ALL
                SELECT json_extract(parent.data,'$.media_trash_directory') AS directory,o.value AS object
                FROM parents parent JOIN records page ON \(TicketCleanupDescriptorPages.activeSQL),json_each(page.data,'$.objects') o
            )
            SELECT directory,json_extract(object,'$.trash_path') AS target FROM descriptors
            WHERE json_extract(object,'$.disposal')='trash' AND json_extract(object,'$.representation')='original'
              AND json_extract(object,'$.state') IN ('pending','removed','already_missing')
              AND json_extract(object,'$.relative_path')=CAST(? AS TEXT) COLLATE BINARY
              AND json_extract(object,'$.sha256')=? AND json_extract(object,'$.size')=?
              AND EXISTS(SELECT 1 FROM json_each(object,'$.owner_ids') owner WHERE CAST(owner.value AS BLOB)=CAST(? AS BLOB))
            """,arguments:[Data(pid.utf8),Self.ticketObjectDeletionKind,Data(path.utf8),sha,size,Data(id.utf8)])
        while let row = try rows.next() {
            guard let directory: String = row["directory"],let target: String = row["target"] else {continue}
            let expected = URL(fileURLWithPath:directory,isDirectory:true).appendingPathComponent(hash(Data(path.utf8)) + "-" + URL(fileURLWithPath:path).lastPathComponent).path
            if Data(target.utf8) == Data(expected.utf8) {return true}
        }
        return false
    }

    /// The durable deletion receipt names its exact same-volume Trash entry
    /// before the existing executor can move bytes. A restart reuses that name.
    /// The optional root is an internal owned-fixture seam, never client input.
    func prepareMediaCleanupTrash(_ db: Database,receipt original: JSON,page: TicketBytePageExecution? = nil) throws -> JSON {
        var receipt = original,objects = receipt["objects"] as? [JSON] ?? []
        guard objects.contains(where:{$0["disposal"] as? String == "trash" && $0["state"] as? String == "pending"}) else {return receipt}
        if let reason = mediaCleanupTrashBindingFailure(receipt,allowUnboundPageTargets:page != nil && !bool(receipt,"descriptor_legacy_trash_binding")) {throw CoreError("CLEANUP_TRASH_INVALID","The retained Trash intent has no current instance authority; originals retained.",details:["reason":reason])}
        let id = try StoredRecord(receipt,family:"storage_job").string("id")
        let folderName = "Checklist-media-" + hash(Data((incarnation + ":" + id).utf8))
        let marker: JSON = ["receipt_id":id,"source_root":root.path,"incarnation":incarnation]
        let markerBytes = Data((try jsonString(marker)).utf8)
        var directory: URL
        let files: StorageObjectFiles
        if let stored = receipt["media_trash_directory"] as? String {
            directory = URL(fileURLWithPath:stored,isDirectory:true)
            let name = directory.lastPathComponent
            guard name == folderName || name.hasPrefix(folderName + "-") && UUID(uuidString:String(name.dropFirst(folderName.count + 1))) != nil else {throw CoreError("CLEANUP_TRASH_INVALID","The retained Trash intent requires repair; originals retained.")}
            // Once committed, the exact destination and marker are mandatory.
            // Never recreate a missing durable destination or adopt an orphan.
            files = try StorageObjectFiles(root:directory,folderAccess:.insideTrash)
            guard try files.read("cleanup-owner.json",maximum:16384) == markerBytes else {throw CoreError("CLEANUP_TRASH_INVALID","The retained Trash folder belongs to another intent; originals retained.")}
        } else {
            let trash = try ticketCleanupTrashRoot ?? FileManager.default.url(for:.trashDirectory,in:.userDomainMask,appropriateFor:root,create:true)
            directory = trash.appendingPathComponent(folderName,isDirectory:true)
            let created = mkdir(directory.path,0o700) == 0
            if !created && errno != EEXIST {throw CoreError("CLEANUP_TRASH_UNAVAILABLE","The owned Trash folder could not be created; originals retained.",details:["posix_errno":errno])}
            if !created,let existing = try? StorageObjectFiles(root:directory,folderAccess:.insideTrash),
               let existingMarker = try? existing.read("cleanup-owner.json",maximum:16384),existingMarker == markerBytes {
                files = existing
            } else {
                if !created {
                    // A crash before marker publication can leave an unowned
                    // deterministic folder. Retain it and create a new exclusive
                    // container; no bytes can have moved before intent commit.
                    directory = trash.appendingPathComponent(folderName + "-" + uuid(),isDirectory:true)
                    guard mkdir(directory.path,0o700) == 0 else {throw CoreError("CLEANUP_TRASH_UNAVAILABLE","A fresh owned Trash folder could not be created; originals retained.",details:["posix_errno":errno])}
                }
                files = try StorageObjectFiles(root:directory,folderAccess:.insideTrash)
                try files.writeNew("cleanup-owner.json",bytes:markerBytes);try files.synchronizePublicationDirectory()
            }
        }
        var info = stat(),source = stat()
        guard fstat(files.descriptor,&info) == 0,fstatat(AT_FDCWD,root.path,&source,AT_SYMLINK_NOFOLLOW) == 0,info.st_dev == source.st_dev else {throw CoreError("CLEANUP_TRASH_UNAVAILABLE","Cleanup requires a same-volume Trash destination; originals retained.")}
        var changed = receipt["media_trash_directory"] == nil
        for index in objects.indices where objects[index]["disposal"] as? String == "trash" {
            guard let path = objects[index]["relative_path"] as? String,path.hasPrefix("objects/"),objects[index]["kind"] as? String == "file" else {throw CoreError("CLEANUP_TRASH_INVALID","Only exact regular managed media entries can move to Trash.")}
            let target = directory.appendingPathComponent(hash(Data(path.utf8)) + "-" + URL(fileURLWithPath:path).lastPathComponent).path
            if let previous = objects[index]["trash_path"] as? String {guard previous == target else {throw CoreError("CLEANUP_TRASH_INVALID","The retained Trash destination changed; originals retained.")}}
            else {objects[index]["trash_path"] = target;changed = true}
        }
        if changed {
            receipt["media_trash_directory"] = directory.path;receipt["media_trash_source_root"] = root.path
            receipt["objects"] = objects;receipt = revised(receipt)
            try withValidatedDomainTransaction(db) {
                if let page {receipt = try self.saveTicketBytePage(db,receipt:receipt,execution:page)}
                else {try self.save(db,receipt,type:"storage_job")}
                return .commit
            }
        }
        return receipt
    }
}
