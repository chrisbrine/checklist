import Foundation
import ChecklistCore

public enum PendingNoteNoticePresentation {
    public static func text(in envelope: [String:Any]) -> String? {
        let data = envelope["data"] as? [String:Any] ?? envelope
        guard let metadata = data["_checklist"] as? [String:Any],let notice = metadata["pending_notes"] as? [String:Any],
              notice["schema_version"] as? Int == 1 else { return nil }
        if notice["status"] as? String == "unavailable" {
            return "Checklist could not refresh pending note notices. Your command result is unchanged. Read your authenticated session_inbox before continuing."
        }
        guard notice["status"] as? String == "pending_pickup",let items = notice["items"] as? [[String:Any]],!items.isEmpty else { return nil }
        let references = items.prefix(8).compactMap { item -> String? in
            guard let project = item["project_id"] as? String,let message = item["message_id"] as? String,
                  UUID(uuidString:project) != nil,UUID(uuidString:message) != nil else { return nil }
            let subject = item["subject"] as? [String:Any] ?? [:]
            return AgentReference.text(key:subject["key"] as? String,title:subject["title"] as? String ?? "") + " (project \(project), message \(message))"
        }
        guard !references.isEmpty else { return nil }
        let more = notice["has_more"] as? Bool == true ? " More notes are available." : ""
        return "Checklist has pending notes: \(references.joined(separator:"; ")).\(more) Read session_inbox in the named project before continuing, then acknowledge only your own delivery after reading it. This notice is not acknowledgment or new work authority."
    }
}
