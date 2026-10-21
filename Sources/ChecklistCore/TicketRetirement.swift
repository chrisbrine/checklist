import Foundation
import GRDB

extension CommandRouter {
    /// A status edit has no authority to stop a native process or its accepted children.
    func requireRetirementSafe(_ db: Database, task: JSON) throws {
        let pid = task["project_id"] as! String, tid = task["id"] as! String
        let live = try Bool.fetchOne(db, sql: """
        SELECT EXISTS(SELECT 1 FROM records WHERE project_id=? AND
          ((type='attempt' AND json_extract(data,'$.task_id')=? AND json_extract(data,'$.state')='active')
           OR (type='review_request' AND json_extract(data,'$.task_id')=? AND json_extract(data,'$.state') IN ('active','claimed','human_pending'))))
        """, arguments: [pid,tid,tid]) ?? false
        guard task["active_attempt_id"] == nil, task["active_verification_request_id"] == nil, !live else {
            throw CoreError("CLAIM_CONFLICT", "Active work cannot be ended by editing a ticket. Use work_release as the holder, work_takeover with a reason, or recovery after a verified stop; then retry.")
        }
        guard try unresolvedSourceExecutions(db,taskID:tid).isEmpty else {
            throw CoreError("SOURCE_EXECUTION_ACTIVE", "Verify that source execution stopped and recover it before canceling, reassigning or removing this ticket.")
        }
    }

    func requireArchiveUndoSafe(_ db: Database, task: JSON) throws {
        let cleaned = try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM records WHERE type='attachment' AND project_id=? AND json_extract(data,'$.task_id')=? AND json_extract(data,'$.availability')='original_cleaned')",arguments:[task["project_id"] as! String,task["id"] as! String]) ?? false
        guard !cleaned else { throw CoreError("UNDO_UNAVAILABLE","Archive cleanup removed original bytes. Unarchive can restore ticket visibility, but cannot restore those files.") }
    }

}
