import Foundation
import GRDB

extension CommandRouter {
    /// Read selectors, not authority: preparation and claim still validate the stored target and contributors.
    func reviewBatchInputs(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        let pid = try scope(db,p,c),group = try scoped(db,try text(p,"triage_id"),pid,type:"group")
        guard group["kind"] as? String == "triage",triagePhase(group) == "review" else { throw CoreError("TRIAGE_PHASE_CONFLICT","review_batch_inputs requires a Review Triage.") }
        let requests = try records(db,type:"review_request",project:pid).enumerated().sorted {
            let first = $0.element["created_at"] as? String ?? "",second = $1.element["created_at"] as? String ?? ""
            return first == second ? $0.offset < $1.offset : first < second
        }.map { $0.element }
        var tasks: [JSON] = [],notReady: [JSON] = []
        for id in triageMemberIDs(group) {
            let task = try scoped(db,id,pid,type:"task"),identity: JSON = ["task_id":id,"key":task["key"] ?? ""]
            func unavailable(_ reason: String) -> JSON { var row = identity;row["reason"] = reason;return row }
            let taskRequests = requests.filter {$0["task_id"] as? String == id}
            if task["active_attempt_id"] != nil || task["active_verification_request_id"] != nil || taskRequests.contains(where: {["active","human_pending"].contains($0["state"] as? String ?? "")}) { notReady.append(unavailable("review already claimed"));continue }
            let open = taskRequests.filter {$0["state"] as? String == "queued"}
            guard !open.isEmpty else { notReady.append(unavailable("no open review request"));continue }
            var selected: String? = nil
            for request in open {
                if let selected { notReady.append(unavailable("batch_prepare accepts one request per task; chose oldest ready request \(selected), omitted \(request["id"]!)"));continue }
                if request["gate"] as? String == "human_approval" { notReady.append(unavailable("human approval requires the owner channel"));continue }
                let manifest: JSON
                do { manifest = try validateManifestTarget(db,task:task,manifestID:try text(request,"manifest_id")) }
                catch let error as CoreError { notReady.append(unavailable("target stale: \(error.message)"));continue }
                let author: JSON = ["session_id":manifest["author_session_id"] ?? NSNull()]
                let contributors = Set(([author] + (manifest["contributors"] as? [JSON] ?? [])).compactMap {$0["session_id"] as? String}).sorted()
                selected = request["id"] as? String
                tasks.append(["task_id":id,"key":task["key"] ?? "","expected_revision":task["revision"]!,"review_request_id":request["id"]!,"target_manifest_id":manifest["id"]!,"gate":request["gate"]!,"contributor_session_ids":contributors])
            }
        }
        return ["triage_id":group["id"]!,"triage_key":group["key"] ?? "","triage_name":group["name"] ?? "","triage_revision":group["revision"]!,"phase":"review","tasks":tasks,"not_ready":notReady]
    }
}
