import Foundation
import GRDB

extension CommandRouter {
    static let triageStatusMethods: Set<String> = ["work_claim", "work_release", "work_submit", "review_record", "review_draft_submit", "release_set_complete", "review_request", "task_complete", "task_transition", "work_recover", "human_request_answer", "triage_transition", "batch_claim", "batch_release", "batch_submit", "batch_review_record", "batch_complete_passing"]

    func currentTriageMemberships(_ db: Database, project: String) throws -> [JSON] {
        try records(db, type: "group", project: project).filter { $0["kind"] as? String == "triage" }.flatMap { group in
            try triageMemberIDs(group).map {
                [
                    "triage_id": (try StoredRecord(group, family: "group").requiredValue("id")), "triage_key": group["key"] ?? "", "key": group["key"] ?? "",
                    "title": group["name"] ?? "", "triage_name": group["name"] ?? "Triage", "task_id": $0,
                ]
            }
        }
    }

    func triageCommandEffect(_ db: Database, before: [JSON], project: String, method: String) throws -> JSON {
        let after = try currentTriageMemberships(db, project: project)
        let remaining = Set(
            try after.map { "\((try StoredRecord($0, family: "record").requiredValue("triage_id"))):\((try StoredRecord($0, family: "record").requiredValue("task_id")))" })
        let removed = try before.filter {
            !remaining.contains("\((try StoredRecord($0, family: "record").requiredValue("triage_id"))):\((try StoredRecord($0, family: "record").requiredValue("task_id")))")
        }
        return ["removed_memberships": removed, "removed_count": removed.count,
                "reason": removed.isEmpty ? "no_memberships_removed" : (method == "task_complete" || method == "batch_complete_passing" ? "completed" : "status_workflow"),
                "guidance": "Status changes keep Triage membership (CL-125). A ticket leaves its Triage when Done or canceled, when another orchestrator handles it, or when removed; a plan that empties archives. removed_memberships lists the memberships this command closed."]
    }
}
