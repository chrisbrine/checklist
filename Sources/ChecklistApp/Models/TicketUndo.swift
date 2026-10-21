import Foundation

/// A single-ticket inverse is valid only against the exact action result.
struct TicketUndo {
    let method: String
    let parameters: [String: Any]
    let revision: Int
    let restoresArchive: Bool

    func available(task: Record, files: [Record]) -> Bool {
        RecordIdentity(task.id) == RecordIdentity(parameters["task_id"] as? String ?? "") && RecordIdentity(task.string("project_id")) == RecordIdentity(parameters["project_id"] as? String ?? "") && task.integer("revision") == revision && task.string("active_attempt_id").isEmpty && task.string("active_verification_request_id").isEmpty && (!restoresArchive || task.integer("cleaned_original_count",fallback:-1) == 0 && !files.contains {$0.string("availability") == "original_cleaned"})
    }
    static func archive(_ result: [String: Any], action: String) -> TicketUndo? {
        guard let revision = (result["revision"] as? NSNumber)?.intValue,
              let id = result["id"] as? String,let project = result["project_id"] as? String,
              let inverse = ["archive":"unarchive","trash":"restore"][action] else {return nil}
        if action == "archive",(result["cleaned_original_count"] as? Int ?? -1) != 0 {return nil}
        return TicketUndo(method:"task_archive",parameters:["project_id":project,"task_id":id,"expected_revision":revision,"action":inverse,"undo":true],revision:revision,restoresArchive:action == "archive")
    }
    static func transition(_ result: [String: Any], previous: Record) -> TicketUndo? {
        let category = previous.string("status_category")
        // Done still requires fresh completion gates. No status edit may invent them.
        guard ["queued","canceled"].contains(category),let revision = (result["revision"] as? NSNumber)?.intValue else {return nil}
        let params: [String:Any] = ["project_id":previous.string("project_id"),"task_id":previous.id,"expected_revision":revision,"target_status_id":previous.string("status_id"),"reason":"Undo the previous ticket change"]
        return TicketUndo(method:"task_transition",parameters:params,revision:revision,restoresArchive:false)
    }
}
