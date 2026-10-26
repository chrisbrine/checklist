import Foundation
import GRDB

extension CommandRouter {
    /// Only matching envelopes are decoded; old batches need not load every
    /// historical attempt payload just to render a lifecycle summary.
    func batchRelatedRecord(_ db: Database,_ batch: JSON,type: String) throws -> JSON? {
        let record = StoredRecord(batch, family: "batch")
        let projectID = try record.string("project_id")
        let batchID = try record.string("id")
        let sql =
            "SELECT " + Self.canonicalRecordColumns
            + " FROM records WHERE type=? AND project_id=CAST(? AS TEXT)"
            + " AND json_extract(data,'$.batch_id')=CAST(? AS TEXT) COLLATE BINARY ORDER BY rowid LIMIT 1"
        let row = try Row.fetchOne(db, sql: sql, arguments: [type, Data(projectID.utf8), Data(batchID.utf8)])
        return try row.map {try GRDBRecordEnvelopeAdapter.decode($0).object}
    }
    func batchDisposition(_ db: Database,_ batch: JSON) throws -> JSON? {
        try batchRelatedRecord(db,batch,type:"batch_disposition")
    }
    func batchWasClaimed(_ db: Database,_ batch: JSON) throws -> Bool {
        try batchRelatedRecord(db,batch,type:"batch_claim") != nil || batchRelatedRecord(db,batch,type:"attempt") != nil
    }
    func requireBatchNotDiscarded(_ db: Database,_ batch: JSON) throws {
        if let disposition = try batchDisposition(db,batch) {
            throw CoreError(
                "BATCH_DISCARDED", "This preparation was discarded. Prepare a fresh batch before continuing.",
                details: [
                    "batch_id": try StoredRecord(batch, family: "batch").string("id"),
                    "disposition_id": try StoredRecord(disposition, family: "batch_disposition").string("id"),
                    "reason": disposition["reason"] ?? "",
                ]
            )
        }
    }
    func batchLifecycle(_ db: Database,_ batch: JSON) throws -> JSON {
        let dispatch = try batchRelatedRecord(db,batch,type:"batch_claim")
        let disposition = try batchDisposition(db,batch)
        return ["lifecycle":disposition == nil ? (try (dispatch != nil || batchRelatedRecord(db,batch,type:"attempt") != nil) ? "claimed" : "prepared") : "discarded",
                "dispatch":dispatch as Any? ?? NSNull(),"disposition":disposition as Any? ?? NSNull()]
    }
    /// Planning disposition only. The command transaction serializes this admission
    /// with dispatch, and the original frozen batch bytes/revision never change.
    func batchDiscard(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try worker(c);let pid = try scope(db,p,c,write:true)
        if !c.isOwner {
            guard let sid = c.sessionID else { throw CoreError("FORBIDDEN","A scoped eligible work session is required.") }
            _ = try eligibleWorkSession(db,id:sid,project:pid)
            _ = try callerSessionGeneration(db,c,project:pid)
        }
        let batch = try scoped(db,try text(p,"batch_id"),pid,type:"batch");try revision(p,batch)
        let reason = try text(p,"reason")
        let record = StoredRecord(batch, family: "batch")
        let batchID = try record.string("id")
        guard !(try batchWasClaimed(db, batch)) else {
            throw CoreError(
                "BATCH_ALREADY_CLAIMED",
                "This batch was dispatched and cannot be discarded, even after release or completion. "
                    + "Use the live work lifecycle for claimed batches.",
                details: ["batch_id": batchID]
            )
        }
        if try batchDisposition(db,batch) == nil {
            let disposition: JSON = [
                "id": uuid(), "project_id": pid, "batch_id": batchID,
                "batch_digest": try record.requiredValue("digest"), "triage_id": try record.requiredValue("triage_id"),
                "disposition": "discarded", "actor": c.principal, "session_id": c.sessionID ?? "human",
                "reason": reason, "created_at": now(), "revision": 1,
            ]
            try save(db,disposition,type:"batch_disposition")
            try event(db,caller:c,project:pid,entity:batch["triage_id"] as? String,kind:"batch_discarded",data:disposition)
        }
        return try batchProjection(db,batch)
    }
}
