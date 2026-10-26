import Foundation
import GRDB

extension CommandRouter {
    /// Run the real completion guards without retaining a status, departure or event.
    func completionPreview(_ db: Database, task: JSON, caller: Caller) throws -> JSON {
        let record = try StoredTaskRecord(task)
        let revision = try StoredRecord(task, family: "task").requiredValue("revision")
        let manifestID = task["current_manifest_id"] ?? NSNull()
        do {
            try db.inSavepoint {
                let input: JSON = [
                    "project_id":record.projectID,"task_id":record.id,"expected_revision":revision,
                    "direction_cursor":try cursor(db,caller:caller,scope:directionCursorScope(db,task:task,caller:caller))
                ]
                _ = try work(db,input,caller,"task_complete",operation:.triage)
                return .rollback
            }
            return ["eligible":true,"blockers":[],"task_revision":revision,"manifest_id":manifestID]
        } catch let failure as CoreError {
            let blocker: JSON = ["code":failure.code,"message":failure.message,"details":failure.details]
            return ["eligible":false,"blockers":[blocker],"task_revision":revision,"manifest_id":manifestID]
        }
    }
}
