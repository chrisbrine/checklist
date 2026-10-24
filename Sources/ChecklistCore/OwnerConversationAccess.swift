import Foundation
import GRDB

extension CommandRouter {
    /// Owner intent revokes authorization immediately; it is not OS stop evidence.
    func ownerConversationAccess(_ db: Database, _ p: JSON, _ c: Caller, _ method: String) throws -> JSON {
        try owner(c)
        let pid = try scope(db,p,c,write:true), sid = try text(p,"session_id")
        let historyEntity: String
        if let tid = p["task_id"] as? String { _ = try scoped(db,tid,pid,type:"task"); historyEntity = tid }
        else { historyEntity = sid }
        var session = try scoped(db,sid,pid,type:"session")
        try revision(p,session)
        guard session["role"] as? String == "worker",
              session["installation"] as? String == (try text(p,"installation")) else {
            throw CoreError("RECIPIENT_CHANGED","Refresh this conversation before changing its access.")
        }
        let attempts = try Row.fetchAll(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='attempt' AND project_id=? AND json_extract(data,'$.session_id')=? COLLATE BINARY AND json_extract(data,'$.state')='active'",arguments:[pid,sid])
            .map { try GRDBRecordEnvelopeAdapter.decode($0,expectedType:"attempt").object }
        if method == "connection_allow" {
            guard bool(session,"owner_revoked") else { throw CoreError("INVALID_TRANSITION","Only an owner-disconnected conversation can be allowed again.") }
            guard attempts.isEmpty else { throw CoreError("OWNER_DISCONNECT_PENDING","Recover the stopped claims and their source checks before allowing this conversation again.") }
            session["owner_revoked"] = false
            session.removeValue(forKey:"owner_disconnect_pending_attempt_ids")
            // Remain unauthorized until the service verifies the actual native caller
            // and commits a fresh enrollment/credential. No old claim is revived.
            session["owner_reconnect_allowed"] = true
            session["state"] = "revoked"
            session["authorization_generation"] = uuid()
            try save(db,revised(session),type:"session")
            try event(db,caller:c,project:pid,entity:historyEntity,kind:"owner_conversation_allowed",data:["session_id":sid])
            return ["allowed":true,"session_id":sid,"state":"reconnect_pending"]
        }
        guard session["state"] as? String == "connected" || bool(session,"owner_revoked") || bool(session,"owner_reconnect_allowed") else {
            throw CoreError("INVALID_TRANSITION","Only a connected or owner-disconnected conversation can be disconnected.")
        }
        session["state"] = "revoked"; session["owner_revoked"] = true
        session.removeValue(forKey:"owner_reconnect_allowed")
        session["authorization_generation"] = uuid()
        session["owner_disconnected_at"] = now()
        var released: [String] = [], pending: [String] = []
        // Descendants held by this same conversation release before their parent.
        let parents = Dictionary(uniqueKeysWithValues:attempts.compactMap { a in
            (a["parent_attempt_id"] as? String).map { (a["id"] as! String,$0) }
        })
        func depth(_ id: String) -> Int { var id=id, count=0; while let parent=parents[id],count<32 { count += 1; id=parent }; return count }
        for var attempt in attempts.sorted(by: { depth($0["id"] as! String) > depth($1["id"] as! String) }) {
            let aid = attempt["id"] as! String, tid = attempt["task_id"] as! String
            do { try requireNoSourceExecutions(db,attempt:attempt); try requireNoWritableChildren(db,attempt:attempt) }
            catch let error as CoreError where ["SOURCE_EXECUTION_ACTIVE","CHILD_WRITERS_ACTIVE"].contains(error.code) {
                pending.append(aid)
                try event(db,caller:c,project:pid,entity:tid,kind:"owner_disconnect_release_pending",data:["session_id":sid,"attempt_id":aid,"reason":error.code])
                continue
            }
            if let rid = attempt["review_request_id"] as? String {
                var request = try scoped(db,rid,pid,type:"review_request")
                let task = try scoped(db,tid,pid,type:"task")
                request["state"] = task["current_manifest_id"] as? String == request["manifest_id"] as? String ? "queued" : "superseded"
                try save(db,revised(request),type:"review_request")
            }
            attempt["state"] = "released"; attempt["reason"] = "The owner disconnected this conversation."
            attempt["owner_disconnected_at"] = now(); attempt.removeValue(forKey:"token_hash")
            try save(db,revised(attempt),type:"attempt")
            var task = try scoped(db,tid,pid,type:"task")
            if task["active_attempt_id"] as? String == aid {
                task.removeValue(forKey:"active_attempt_id"); task["status_id"] = try status(db,pid,"queued")["id"]
                task = revised(task); try save(db,task,type:"task")
                try recordTicketStatusAction(db,task:task,caller:c)
            }
            try event(db,caller:c,project:pid,entity:tid,kind:"work_released",data:["session_id":sid,"attempt_id":aid,"reason":attempt["reason"]!,"owner_disconnect":true])
            released.append(aid)
        }
        let deliveries = try Row.fetchAll(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='delivery' AND project_id=? AND json_extract(data,'$.recipient_session_id')=? COLLATE BINARY",arguments:[pid,sid])
        for row in deliveries {
            var delivery = try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"delivery").object
            guard !["acknowledged","addressed"].contains(delivery["state"] as? String ?? ""), delivery["owner_disconnect_ref"] == nil else { continue }
            delivery["owner_disconnect_ref"] = p["command_id"]; delivery["owner_disconnected_at"] = now()
            try save(db,revised(delivery),type:"delivery")
            let message = try scoped(db,delivery["message_id"] as! String,pid,type:"message")
            try event(db,caller:c,project:pid,entity:message["task_id"] as? String ?? message["conversation_id"] as? String ?? message["id"] as? String,
                      kind:"message_delivery_fenced",data:["delivery_id":delivery["id"]!,"message_id":delivery["message_id"]!,"recipient_session_id":sid,
                      "recipient_authorization_generation":delivery["recipient_authorization_generation"] ?? "","owner_disconnect_ref":p["command_id"]!])
        }
        session["owner_disconnect_pending_attempt_ids"] = pending
        try save(db,revised(session),type:"session")
        try event(db,caller:c,project:pid,entity:historyEntity,kind:"owner_conversation_disconnected",data:["session_id":sid,"released_attempt_ids":released,"pending_attempt_ids":pending])
        return ["disconnected":true,"session_id":sid,"released_attempt_ids":released,"pending_attempt_ids":pending]
    }

    /// Explicit Allow again permits a verified native bootstrap, including the
    /// same still-running host. Automatic closure resumption remains separate.
    public func reconnectOwnerAllowedSession(_ resumption: NativeSessionResumption, caller: Caller) throws -> [String:Any] {
        try owner(caller)
        guard caller.installation == "native-thread-bootstrap", !resumption.newInstallation.isEmpty,
              !resumption.newExecutionDomain.isEmpty, resumption.newInstallation != resumption.oldInstallation else {
            throw CoreError("FORBIDDEN","Only a fresh verified native connection can use the owner's Allow again.")
        }
        let lease = try storageAdmission.acquire(); defer { lease.finish() }
        return try ArchiveStorageGate.withExclusive(root:root) { _ in
            try dbQueue.writeWithoutTransaction { db in
                var result: JSON = [:]
                try self.withValidatedDomainTransaction(db) {
                    var session = try self.scoped(db,resumption.sessionID,resumption.projectID,type:"session")
                    guard session["installation"] as? String == resumption.oldInstallation,
                          session["execution_domain"] as? String == resumption.oldExecutionDomain,
                          session["provider"] as? String == resumption.provider, session["role"] as? String == "worker",
                          ["revoked","ended"].contains(session["state"] as? String ?? ""), !bool(session,"owner_revoked"), bool(session,"owner_reconnect_allowed") else {
                        throw CoreError("CONNECTION_REVOKED","This conversation has no current owner permission to reconnect.")
                    }
                    session["installation"] = resumption.newInstallation; session["execution_domain"] = resumption.newExecutionDomain
                    session["state"] = "connected"; session["authorization_generation"] = uuid(); session["last_seen"] = now()
                    session.removeValue(forKey:"owner_reconnect_allowed")
                    if let closure = session.removeValue(forKey:"native_closure_ref") as? String {
                        session["prior_native_closure_refs"] = strings(session,"prior_native_closure_refs") + [closure]
                    }
                    session.removeValue(forKey:"ended_at")
                    result = self.revised(session); try self.save(db,result,type:"session")
                    try self.event(db,caller:caller,project:resumption.projectID,entity:resumption.sessionID,kind:"owner_allowed_conversation_reconnected")
                    return .commit
                }
                return result
            }
        }
    }
}
