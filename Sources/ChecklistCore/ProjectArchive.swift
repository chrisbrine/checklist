import Foundation
import GRDB

extension CommandRouter {
    /// CL-130: archiving a project must not strand work. Active claims (implementation, review and
    /// delegated child work), active owner checks and pending owner requests get an explicit outcome
    /// first: the holder finishes, releases or hands off, and the owner answers or cancels.
    func requireNoActiveProjectWork(_ db: Database,project pid: String) throws {
        let tasks = try records(db,type:"task",project:pid)
        func key(_ id: Any?) -> String { tasks.first { $0["id"] as? String == id as? String }?["key"] as? String ?? "a ticket" }
        let attempts = try records(db,type:"attempt",project:pid).filter { $0["state"] as? String == "active" }
        let checks = tasks.filter { $0["active_verification_request_id"] != nil }
        let requests = try records(db,type:"request",project:pid).filter { $0["state"] as? String == "pending" }
        var reasons: [String] = []
        let claimed = Array(Set(attempts.map { key($0["task_id"]) })).sorted()
        if !claimed.isEmpty { reasons.append("active work on \(claimed.joined(separator:", ")) (the holder finishes, releases or hands it off)") }
        let checked = checks.compactMap { $0["key"] as? String }.sorted()
        if !checked.isEmpty { reasons.append("an owner check on \(checked.joined(separator:", "))") }
        let asked = Array(Set(requests.map { key($0["task_id"]) })).sorted()
        if !asked.isEmpty { reasons.append("open owner requests on \(asked.joined(separator:", ")) (answer or cancel them)") }
        guard reasons.isEmpty else {
            throw CoreError("CLAIM_CONFLICT","This project cannot be archived yet. It has " + reasons.joined(separator:"; ") + ".",
                            details:["active_attempt_task_keys":claimed,"active_check_task_keys":checked,"pending_request_task_keys":asked])
        }
    }
}
