import Foundation
import GRDB

extension CommandRouter {
    func retainPolicy(_ db: Database,project: JSON) throws -> JSON {
        let pid = project["id"] as! String,number = int(project,"policy_revision",default:1),policy = project["policy"] as? JSON ?? [:]
        if let existing = try records(db,type:"policy_revision",project:pid).first(where: {int($0,"policy_revision") == number}) { return existing }
        let snapshot: JSON = ["id":uuid(),"project_id":pid,"policy_revision":number,"policy":policy,"revision":1,"created_at":now()]
        try save(db,snapshot,type:"policy_revision"); return snapshot
    }
    func policyAtRevision(_ db: Database,projectID: String,revision: Int) throws -> JSON {
        if let snapshot = try records(db,type:"policy_revision",project:projectID).first(where: {int($0,"policy_revision") == revision}),let policy = snapshot["policy"] as? JSON { return policy }
        let current = try record(db,projectID,type:"project")
        if int(current,"policy_revision",default:1) == revision { _ = try retainPolicy(db,project:current); return current["policy"] as? JSON ?? [:] }
        // Upgrade existing stores using their immutable durable command outcomes; never guess an older policy from today's settings.
        for row in try Row.fetchAll(db,sql:"SELECT result FROM commands ORDER BY rowid DESC") {
            let outcome = jsonObject(row["result"]),data = outcome["data"] as? JSON ?? [:]
            if data["id"] as? String == projectID,int(data,"policy_revision") == revision,let policy = data["policy"] as? JSON { _ = try retainPolicy(db,project:data); return policy }
        }
        throw CoreError("POLICY_CHANGED","The original policy revision is unavailable. Preserve the attempt and ask the owner to reconcile it before submission.")
    }
    func attemptPolicy(_ db: Database,_ attempt: JSON) throws -> JSON {
        if let policy = attempt["policy_snapshot"] as? JSON { return policy }
        return try policyAtRevision(db,projectID:attempt["project_id"] as! String,revision:int(attempt,"policy_revision",default:1))
    }
    func manifestGates(_ db: Database,_ manifest: JSON) throws -> [String] {
        if let tid = manifest["task_id"] as? String, let task = try? record(db,tid,type:"task") {
            if task["pending_policy_revision"] != nil { throw CoreError("POLICY_ACK_REQUIRED","Explicitly reconcile the changed completion contract before using this target.") }
            if task["completion_policy_manifest_id"] as? String == manifest["id"] as? String, let policy = task["completion_policy_snapshot"] as? JSON { return strings(policy,"required_gates") }
        }
        if let gates = manifest["required_gates"] as? [String] { return gates }
        if let policy = manifest["policy_snapshot"] as? JSON { return strings(policy,"required_gates") }
        if let aid = manifest["attempt_id"] as? String,let attempt = try? record(db,aid,type:"attempt") { return strings(try attemptPolicy(db,attempt),"required_gates") }
        throw CoreError("POLICY_CHANGED","The submitted target has no recoverable policy snapshot. Reconcile its gates explicitly before completion.")
    }
}
