import Foundation
import GRDB

extension CommandRouter {
    private static let backupCapacityAttentionKey = "storage-backup-capacity-attention"
    private static let backupMissingAttachmentAttentionKey = "storage-backup-missing-attachment-attention"
    static let backupMissingAttachmentFields = ["project_id","project_name","task_id","ticket_key","attachment_id","attachment_name","representation"]

    func backupCapacityAttention(_ db: Database) throws -> JSON? {
        try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key=?",
                            arguments: [Self.backupCapacityAttentionKey]).map { jsonObject($0) }
    }

    func backupMissingAttachmentAttention(_ db: Database) throws -> JSON? {
        try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",
                            arguments:[Self.backupMissingAttachmentAttentionKey]).map {jsonObject($0)}
    }

    func backupErrorNamingMissingAttachment(_ error: Error, stage: URL, folderAccess: StorageFolderAccess) -> CoreError? {
        guard let failure = error as? StorageSnapshotFailure,case .systemCall(let system) = failure,
              system.code == ENOENT,system.root == root.path,
              let relative = system.path,relative.hasPrefix("objects/") else {return nil}
        let context: JSON?
        do {
            // Database capture is already closed and normalized when source
            // object checks start. Attribute the loss to that exact snapshot,
            // even if the live ticket or attachment has changed since capture.
            let files = try StorageObjectFiles(root:stage,folderAccess:folderAccess)
            guard try files.regularFileExists("database.sqlite") else {return nil}
            var config = Configuration();config.readonly = true
            config.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
            let captured = try DatabaseQueue(path:stage.appendingPathComponent("database.sqlite").path,configuration:config)
            defer {try? captured.close()}
            context = try captured.read { db in
                let absolute = self.root.appendingPathComponent(relative).path
                let rows = try ManagedImportStageReferences.scanAttachmentRows(db,absolute:absolute,relative:relative)
                for row in rows {
                    let record = try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"attachment")
                    let attachment = record.object
                    guard attachment["mode"] as? String == "managed",let projectID = record.projectID else {continue}
                    func namesObject(_ field: String) -> Bool {
                        guard let path = attachment[field] as? String else {return false}
                        return (try? ManagedPaths.relative(path,family:"objects",root:self.root)) == relative
                    }
                    let representation: String
                    if namesObject("path") {representation = "original"}
                    else if namesObject("preview_path") {representation = "preview"}
                    else {continue}
                    let project = try self.record(db,projectID,type:"project")
                    var details: JSON = ["project_id":projectID,"project_name":project["name"] ?? projectID,
                                         "attachment_id":record.id,"attachment_name":attachment["name"] ?? record.id,
                                         "representation":representation]
                    if let task = attachment["task_id"] as? String {
                        details["task_id"] = task
                        if let ticket = try? self.scoped(db,task,projectID,type:"task") {details["ticket_key"] = ticket["key"]}
                    }
                    return details
                }
                return nil
            }
        } catch {return nil}
        guard let context else {return nil}
        let report = StorageFailureReport(failure)
        report.log()
        var details = report.details.merging(context) {_,value in value}
        details["command_outcome"] = "rejected"
        let preview = context["representation"] as? String == "preview"
        let step = preview
            ? "Keep the store and existing backups. Recover the missing preview before running backup_create with a new command ID."
            : "Use attachment_missing_list for the affected project. Recover the original from a verified backup or record the loss with attachment_missing_settle, then run backup_create with a new command ID."
        details["next_step"] = step
        let project = context["project_name"] as? String ?? ""
        let attachment = context["attachment_name"] as? String ?? ""
        let ticket = (context["ticket_key"] as? String ?? context["task_id"] as? String).map {" on ticket " + $0} ?? ""
        let representation = preview ? "preview" : "managed original"
        return CoreError("BACKUP_IO_ERROR","Backup could not find the \(representation) for “\(attachment)”\(ticket) in project “\(project)”. " + report.explanation + " " + step,details:details)
    }

    /// One owner attention item for the current unresolved refusal. The backup
    /// reservation stays held until this write finishes, so a newer verified
    /// backup cannot clear the item before an older failure records it.
    func recordBackupAttention(command: String?, error: Error) {
        guard let command, let error = error as? CoreError else {return}
        let capacity = ["BACKUP_CAPACITY_EXCEEDED","BACKUP_DEADLINE_EXCEEDED"].contains(error.code)
        let missing = error.code == "BACKUP_IO_ERROR" && error.details["reason"] as? String == "file_missing" && error.details["attachment_id"] is String
        guard capacity || missing else {return}
        let key = missing ? Self.backupMissingAttachmentAttentionKey : Self.backupCapacityAttentionKey
        let kind = missing ? "backup_missing_attachment_attention" : "backup_capacity_attention"
        do {
            try dbQueue.write { db in
                var item: JSON = ["command_id": command, "error_code": error.code, "failed_at": now()]
                let fields = missing ? Self.backupMissingAttachmentFields : ["measured_bytes","measured_objects","required_free_bytes","available_bytes"]
                for field in ["reason","next_step"] + fields {
                    item[field] = error.details[field]
                }
                try db.execute(sql: "INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",
                               arguments: [key, try jsonString(item)])
                let caller = Caller(role: "owner", installation: Self.doneEvidenceBackupInstallation, projectIDs: [])
                try event(db,caller:caller,project:nil,entity:nil,kind:kind,data:["error_code":error.code])
            }
        } catch {
            fputs("Backup attention could not be recorded. The backup failure remains in its command result.\n",stderr)
        }
    }

    func clearBackupAttention(_ db: Database) throws {
        try db.execute(sql:"DELETE FROM metadata WHERE key IN (?,?)",
                       arguments:[Self.backupCapacityAttentionKey,Self.backupMissingAttachmentAttentionKey])
    }
}
