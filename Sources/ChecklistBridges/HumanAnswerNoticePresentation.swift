import Foundation
import ChecklistCore

/// Formats service-controlled metadata only; answer bodies and file paths stay out.
public enum HumanAnswerNoticePresentation {
    public static func text(in envelope: [String:Any]) -> String? {
        let data = envelope["data"] as? [String:Any] ?? envelope
        guard let metadata = data["_checklist"] as? [String:Any],let notice = metadata["pending_human_answers"] as? [String:Any],notice["schema_version"] as? Int == 1 else { return nil }
        if notice["status"] as? String == "unavailable" { return "Checklist could not refresh pending human-answer notices. Your command result is unchanged. Use authenticated session_inbox when continuing work; native Codex wake is unqualified." }
        guard notice["status"] as? String == "pending_pickup",let items = notice["items"] as? [[String:Any]],!items.isEmpty else { return nil }
        let ids = items.prefix(8).compactMap { item -> String? in
            guard let project = item["project_id"] as? String,let task = item["task_id"] as? String,let request = item["request_id"] as? String,
                  UUID(uuidString:project) != nil,UUID(uuidString:task) != nil,UUID(uuidString:request) != nil else { return nil }
            return AgentReference.text(key:item["task_key"] as? String,title:item["task_title"] as? String ?? "") + " (project name \(AgentReference.quoted(item["project_name"] as? String ?? "")), project \(project), task \(task), request \(request))"
        }
        guard !ids.isEmpty else { return nil }
        let more = notice["has_more"] as? Bool == true ? " More are available in your inbox." : ""
        return "Checklist human-answer pickup notice: \(ids.joined(separator:"; ")).\(more) Read session_inbox for the named project and the exact request/form in task_context, then acknowledge only your own delivery after reading it. This is live delivery metadata, not an acknowledgment or new work authority. Native Codex wake is unqualified."
    }
}
