import Foundation
import GRDB

extension CommandRouter {
    /// Run the real completion guards without retaining a status, departure or event.
    func completionPreview(_ db: Database, task: JSON, caller: Caller) throws -> JSON {
        let pid = task["project_id"] as! String
        do {
            try db.inSavepoint {
                _ = try work(db,["project_id":pid,"task_id":task["id"]!,"expected_revision":task["revision"]!,"direction_cursor":try cursor(db,caller:caller,scope:directionCursorScope(db,task:task,caller:caller))],caller,"task_complete",operation:.triage)
                return .rollback
            }
            return ["eligible":true,"blockers":[],"task_revision":task["revision"]!,"manifest_id":task["current_manifest_id"] ?? NSNull()]
        } catch let failure as CoreError {
            return ["eligible":false,"blockers":[["code":failure.code,"message":failure.message,"details":failure.details]],"task_revision":task["revision"]!,"manifest_id":task["current_manifest_id"] ?? NSNull()]
        }
    }
}
