import Foundation
import GRDB

/// Only batch preparation/dispatch constructs this context. It is never a public
/// parameter or a reusable permission: each selected top-level attempt has one ID.
struct BatchClaimContext {
    let batch: JSON
    let attemptIDs: [String:String]
    init(batch: JSON) {
        self.batch = batch
        attemptIDs = Dictionary(uniqueKeysWithValues:(batch["members"] as? [JSON] ?? []).map {($0["task_id"] as! String,UUID().uuidString.lowercased())})
    }
}

extension CommandRouter {
    func installBatchContext(_ context: BatchClaimContext,attempt: inout JSON) throws {
        let batch = context.batch,tid = attempt["task_id"] as! String
        guard batch["project_id"] as? String == attempt["project_id"] as? String,
              batch["phase"] as? String == attempt["phase"] as? String,
              let id = context.attemptIDs[tid],
              let member = (batch["members"] as? [JSON])?.first(where: {$0["task_id"] as? String == tid}),
              try jsonString(member["file_scopes"] ?? []) == jsonString(attempt["file_scopes"] ?? []) else {
            throw CoreError("SCOPE_CONFLICT","A frozen batch scope changed its canonical identity. Prepare afresh before claiming.",details:["task_id":tid,"batch_id":batch["id"] ?? ""])
        }
        attempt["id"] = id;attempt["batch_id"] = batch["id"];attempt["batch_digest"] = batch["digest"]
    }

    func sharesFrozenBatchWrite(_ db: Database,_ candidate: JSON,_ other: JSON,path: String,reserved: String,context: BatchClaimContext?) throws -> Bool {
        guard candidate["phase"] as? String == "implementation",other["phase"] as? String == "implementation",
              candidate["parent_attempt_id"] == nil,other["parent_attempt_id"] == nil,
              let pid = candidate["project_id"] as? String,pid == other["project_id"] as? String,
              let bid = candidate["batch_id"] as? String,bid == other["batch_id"] as? String,
              let digest = candidate["batch_digest"] as? String,digest == other["batch_digest"] as? String,
              let sid = candidate["session_id"] as? String,sid != "human",
              candidate["incarnation"] as? String == incarnation else { return false }
        for key in ["principal","session_id","session_authorization_generation","execution_domain","incarnation"] {
            guard let value = candidate[key] as? String,!value.isEmpty,value == other[key] as? String else { return false }
        }
        let session = try scoped(db,sid,pid,type:"session")
        guard canReceive(session,project:pid),sessionGeneration(session) == candidate["session_authorization_generation"] as? String,
              session["execution_domain"] as? String == candidate["execution_domain"] as? String else { return false }
        let batch: JSON,ids: Set<String>
        if let context = context {
            batch = context.batch;ids = Set(context.attemptIDs.values)
            guard context.attemptIDs[candidate["task_id"] as! String] == candidate["id"] as? String,
                  context.attemptIDs[other["task_id"] as! String] == other["id"] as? String else { return false }
        } else {
            batch = try scoped(db,bid,pid,type:"batch")
            guard let dispatch = try records(db,type:"batch_claim",project:pid).first(where: {$0["batch_id"] as? String == bid && $0["batch_digest"] as? String == digest}) else { return false }
            ids = Set(strings(dispatch,"attempt_ids"))
        }
        guard batch["id"] as? String == bid,batch["digest"] as? String == digest,batch["phase"] as? String == "implementation",
              ids.contains(candidate["id"] as! String),ids.contains(other["id"] as! String),candidate["task_id"] as? String != other["task_id"] as? String else { return false }
        // Scope adjustment may retain/narrow frozen writes. A copied batch ID,
        // child/transfer attempt or newly expanded shared write grants no exemption.
        for (attempt,key) in [(candidate,path),(other,reserved)] {
            guard let member = (batch["members"] as? [JSON])?.first(where: {$0["task_id"] as? String == attempt["task_id"] as? String}),
                  (member["file_scopes"] as? [JSON] ?? []).contains(where: {$0["access"] as? String == "write" && containsPath($0["canonical_key"] as? String ?? "",key)}) else { return false }
        }
        return true
    }

    func reservationTicketLabel(_ db: Database,_ attempt: JSON) throws -> String {
        let task = try scoped(db,attempt["task_id"] as! String,attempt["project_id"] as! String,type:"task")
        return "\(task["key"] as? String ?? "Ticket") (\(task["id"] as! String))"
    }
    func reservationConflictDetails(_ db: Database,_ candidate: JSON,_ other: JSON,path: String,reserved: String) throws -> JSON {
        var details: JSON = ["path":path,"reserved_path":reserved]
        for (prefix,attempt) in [("candidate",candidate),("conflicting",other)] {
            // Keep cross-project reservations exclusive without disclosing foreign metadata.
            if prefix == "conflicting",candidate["project_id"] as? String != other["project_id"] as? String { continue }
            let task = try scoped(db,attempt["task_id"] as! String,attempt["project_id"] as! String,type:"task")
            details[prefix+"_task_id"] = task["id"];details[prefix+"_key"] = task["key"]
            details[prefix+"_batch_id"] = attempt["batch_id"];details[prefix+"_batch_digest"] = attempt["batch_digest"]
        }
        return details
    }
}
