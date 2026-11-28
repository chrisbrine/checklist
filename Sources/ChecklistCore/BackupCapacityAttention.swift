import Foundation
import GRDB

extension CommandRouter {
    private static let backupCapacityAttentionKey = "storage-backup-capacity-attention"

    func backupCapacityAttention(_ db: Database) throws -> JSON? {
        try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key=?",
                            arguments: [Self.backupCapacityAttentionKey]).map { jsonObject($0) }
    }

    /// One owner attention item for the current unresolved refusal. The backup
    /// reservation stays held until this write finishes, so a newer verified
    /// backup cannot clear the item before an older failure records it.
    func recordBackupCapacityAttention(command: String?, error: Error) {
        guard let command, let error = error as? CoreError,
              ["BACKUP_CAPACITY_EXCEEDED", "BACKUP_DEADLINE_EXCEEDED"].contains(error.code) else { return }
        do {
            try dbQueue.write { db in
                var item: JSON = ["command_id": command, "error_code": error.code, "failed_at": now()]
                for key in ["reason", "next_step", "measured_bytes", "measured_objects", "required_free_bytes", "available_bytes"] {
                    item[key] = error.details[key]
                }
                try db.execute(sql: "INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",
                               arguments: [Self.backupCapacityAttentionKey, try jsonString(item)])
                let caller = Caller(role: "owner", installation: Self.doneEvidenceBackupInstallation, projectIDs: [])
                try event(db, caller: caller, project: nil, entity: nil, kind: "backup_capacity_attention", data: ["error_code": error.code])
            }
        } catch {
            fputs("Backup capacity attention could not be recorded. The backup failure remains in its command result.\n", stderr)
        }
    }

    func clearBackupCapacityAttention(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM metadata WHERE key=?", arguments: [Self.backupCapacityAttentionKey])
    }
}
