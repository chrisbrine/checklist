import Foundation
import GRDB
import Darwin

extension CommandRouter {
    /// Read-lane inventory only. Finalized imports can own originals and previews
    /// before an attachment commits, so attachment rows alone are insufficient.
    /// The enclosing deletion must remove these jobs under the object gate, after
    /// revalidating this database snapshot. A stale importer then cannot publish.
    func mediaRoundDeletionImportObjects(_ db: Database,jobs: [JSON]) throws -> [JSON] {
        let files = try StorageObjectFiles(root:root)
        var result: [JSON] = []
        func append(_ value: JSON) throws {
            guard result.count < 100000 else {throw CoreError("CLEANUP_INVENTORY_LIMIT","The media import inventory exceeds its safe bound; files retained.")}
            result.append(value)
        }
        func incomplete() -> CoreError {
            CoreError("MEDIA_CAPTURE_INCOMPLETE","A media import has incomplete file ownership; nothing was removed.")
        }
        func directoryExists(_ path: String) throws -> Bool {
            let parent: Int32,name: String
            do {(parent,name) = try files.parent(path)}
            catch {if StorageFolderAccess.isMissing(error) {return false};throw error}
            defer {Darwin.close(parent)}
            var info = stat()
            if fstatat(parent,name,&info,AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT {return false}
                throw incomplete()
            }
            guard info.st_mode & S_IFMT == S_IFDIR else {throw incomplete()}
            return true
        }
        func staging(_ path: String,jobID: String,attachmentID: String,representation: String,expected: JSON? = nil) throws {
            guard try managedImportExists(files,path) else {return}
            let size = try files.openRegular(path) {descriptor -> Int64 in
                var info = stat()
                guard fstat(descriptor,&info) == 0,info.st_size >= 0 else {throw incomplete()}
                return Int64(info.st_size)
            }
            var value: JSON = ["owner_ids":[attachmentID,jobID].sorted(),"representation":representation,
                "kind":"file","executable":false,"state":"retained","size":size,
                "stored_path":path,"relative_path":path,"name":URL(fileURLWithPath:path).lastPathComponent,
                "reasons":["staging_requires_import_recovery"]]
            // The verified byte executor admits objects/, not staging/. Retain
            // the recorded checksum as context, without granting it executable
            // sha256 authority or making backup capture claim committed media.
            if let sha = expected?["sha256"] as? String {value["recorded_sha256"] = sha}
            if let size = expected?["size"] {value["recorded_size"] = size}
            try append(value)
        }
        for job in jobs {
            guard job["kind"] as? String == "attachment_import",job["attachment_owner_id"] is String,
                  let jobID = job["id"] as? String,let pid = job["project_id"] as? String,
                  let attachmentID = job["attachment_id"] as? String,UUID(uuidString:attachmentID) != nil,
                  let principal = job["parent_principal"] as? String,
                  let command = job["parent_command_id"] as? String,
                  jobID == (try managedImportKey(principal:principal,command:command)),
                  ["reserved","staging","finalized","committed","repair_required","settled"].contains(job["state"] as? String ?? "") else {throw incomplete()}
            let objects: [JSON]
            if job["objects"] != nil {
                do {objects = try managedImportObjects(job)} catch {throw incomplete()}
            } else {
                guard ["reserved","settled"].contains(job["state"] as? String ?? ""),
                      let final = job["object_relative_path"] as? String else {throw incomplete()}
                let prefix = "objects/project-" + hash(Data(pid.utf8)) + "/" + attachmentID
                guard final == prefix || final.hasPrefix(prefix + ".") && String(final.dropFirst(prefix.count + 1)).range(of:"^[A-Za-z0-9]{1,16}$",options:.regularExpression) != nil,
                      try !managedImportExists(files,final),try !managedImportExists(files,final + ".preview.png") else {throw incomplete()}
                objects = []
            }
            var attachment: JSON?
            if let row = try Row.fetchOne(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE id=CAST(? AS TEXT) AND type='attachment'",arguments:[Data(attachmentID.utf8)]) {
                let stored = try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"attachment")
                guard EnvelopeStorageIdentity.equal(stored.projectID,pid) else {throw incomplete()}
                attachment = stored.object
            }
            for object in objects {
                guard let final = object["final"] as? String,let representation = object["representation"] as? String else {throw incomplete()}
                var candidate: JSON = ["id":attachmentID,"project_id":pid,"mode":"managed","path":final,
                    "sha256":object["sha256"]!,"size":object["size"]!,"media_cleanup_round_id":jobID]
                if representation == "original",let attachment {candidate["keep_original"] = bool(attachment,"keep_original")}
                for var value in try ticketObjectDeletionObjects(db,owned:[("attachment",candidate)]) {
                    value["representation"] = representation;value["owner_ids"] = [attachmentID,jobID].sorted()
                    try append(value)
                }
            }
            let directory = "staging/attachment-imports/" + jobID
            guard try directoryExists(directory) else {continue}
            let byName = Dictionary(uniqueKeysWithValues:objects.compactMap {object -> (String,JSON)? in
                guard let name = object["representation"] as? String else {return nil};return (name,object)
            })
            let names = try managedDirectoryEntries(files,relative:directory)
            guard names.count <= 100000 else {throw CoreError("CLEANUP_INVENTORY_LIMIT","The media import staging inventory exceeds its safe bound; files retained.")}
            for name in names.sorted() {
                if let object = byName[name] {
                    try staging(directory + "/" + name,jobID:jobID,attachmentID:attachmentID,representation:"staging_" + name,expected:object)
                    continue
                }
                let representation = ["original","preview"].first {name.hasPrefix($0 + ".partial-") && UUID(uuidString:String(name.dropFirst(($0 + ".partial-").count))) != nil}
                guard let representation,byName[representation] != nil else {throw incomplete()}
                try staging(directory + "/" + name,jobID:jobID,attachmentID:attachmentID,representation:"partial_" + representation)
            }
        }
        return result
    }
}
