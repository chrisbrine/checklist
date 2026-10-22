import Foundation
import GRDB

extension CommandRouter {
    static let triageStatusMethods: Set<String> = ["work_claim", "work_release", "work_submit", "review_record", "review_draft_submit", "release_set_complete", "review_request", "task_complete", "task_transition", "work_recover", "human_request_answer", "triage_transition", "batch_claim", "batch_release", "batch_submit", "batch_review_record", "batch_complete_passing"]

    func currentTriageMemberships(_ db: Database, project: String) throws -> [JSON] {
        try records(db, type: "group", project: project).filter { $0["kind"] as? String == "triage" }.flatMap { group in
            triageMemberIDs(group).map { ["triage_id": group["id"]!, "triage_key":group["key"] ?? "", "key":group["key"] ?? "", "title":group["name"] ?? "", "triage_name": group["name"] ?? "Triage", "task_id": $0] }
        }
    }

    func triageCommandEffect(_ db: Database, before: [JSON], project: String, method: String) throws -> JSON {
        let after = try currentTriageMemberships(db, project: project)
        let remaining = Set(after.map { "\($0["triage_id"]!):\($0["task_id"]!)" })
        let removed = before.filter { !remaining.contains("\($0["triage_id"]!):\($0["task_id"]!)") }
        return ["removed_memberships": removed, "removed_count": removed.count,
                "reason": removed.isEmpty ? "no_memberships_removed" : (method == "task_complete" || method == "batch_complete_passing" ? "completed" : "status_workflow"),
                "guidance": "Individual ticket claims, submissions, reviews and releases remove every current Triage membership. Inspect membership and phase first. A planned Implementation Triage may hold Queued tickets; claim its Ready members with batch_prepare and batch_claim so membership stays. Submission finishes that phase; create a separate Review Triage. Use batch_release to retain current memberships; blocked, not_run or evidence_missing batch_review_record verdicts also retain them. While already in Review, review_request retains Review Triage memberships when returning or replacing a request for the same target and gate; a new target or phase change still departs. Batch submission, reject and pass keep their phase departure effects. Done removes completed tickets; rejected cases return for implementation. A group selection or batch ID does not change an individual command's behavior."]
    }
}
