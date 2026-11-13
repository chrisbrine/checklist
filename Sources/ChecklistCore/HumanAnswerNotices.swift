import Foundation
import ChecklistProviders
import GRDB

extension CommandRouter {
    /// Live delivery observation, added after command receipt persistence, including on replay.
    /// It never acknowledges a delivery, changes a request or grants work authority.
    func addingHumanAnswerNotices(_ db: Database, output: JSON, params: JSON, caller: Caller) throws -> JSON {
        // CL-410 F8: each step reports its own failure. A failed note step keeps a good answer notice.
        var result = output
        do { result = try humanAnswerNotices(db, output:output, params:params, caller:caller) }
        catch { result = addingNoticeFailure(db, output, caller:caller, keys:["pending_human_answers"]) }
        do { return try addingPendingNoteNotices(db, output:result, params:params, caller:caller) }
        catch { return addingNoticeFailure(db, result, caller:caller, keys:["pending_notes"]) }
    }

    private func humanAnswerNotices(_ db: Database, output: JSON, params: JSON, caller: Caller) throws -> JSON {
        guard caller.role == "worker",let sid = caller.sessionID else { return output }
        let requested = params["project_id"] as? String
        var seenProjects: Set<Data> = []
        let projects = requested.map {[$0]} ?? caller.projectIDs.filter { seenProjects.insert(Data($0.utf8)).inserted }.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var pending: [JSON] = []
        for pid in projects {
            guard caller.projectIDs.contains(where: { EnvelopeStorageIdentity.equal($0,pid) }) else { continue }
            do { _ = try scope(db,["project_id":pid],caller) }
            catch let error as CoreError where ["FORBIDDEN","ROOT_MISMATCH","NOT_FOUND"].contains(error.code) { continue }
            guard let session = try noticeRecord(db,sid,pid,type:"session"),
                  providerPlugins.plugin(session["provider"] as? String ?? "", requiring: .answerNotice) != nil,session["role"] as? String == "worker",
                  canReceive(session,project:pid) else { continue }
            let generation = sessionGeneration(session)
            let rows = try self.fetchStoreRows(db,sql:"""
                SELECT d.id AS id,d.project_id AS project_id,d.type AS type,d.revision AS revision,d.data AS data,
                       CAST(d.id AS BLOB) AS _envelope_id_bytes,CAST(d.project_id AS BLOB) AS _envelope_project_id_bytes,
                       CAST(d.type AS BLOB) AS _envelope_type_bytes,CAST(d.data AS BLOB) AS _envelope_data_bytes
                FROM records d LEFT JOIN records m
                  ON m.id = CASE WHEN json_valid(d.data) THEN json_extract(d.data,'$.message_id') ELSE NULL END
                 AND m.type='message' AND m.project_id = CAST(? AS TEXT)
                WHERE d.type='delivery' AND d.project_id = CAST(? AS TEXT)
                  AND CASE WHEN json_valid(d.data) THEN CASE WHEN json_type(d.data)='object' THEN
                    (json_extract(d.data,'$.recipient_session_id') = CAST(? AS TEXT) COLLATE BINARY
                     AND json_extract(d.data,'$.recipient_authorization_generation') = CAST(? AS TEXT) COLLATE BINARY
                     AND COALESCE(json_extract(d.data,'$.state'),'queued') NOT IN ('acknowledged','addressed'))
                    ELSE 0 END ELSE 0 END
                  AND CASE WHEN m.id IS NULL THEN 0
                    WHEN json_valid(m.data) THEN CASE WHEN json_type(m.data)='object' THEN
                      (json_extract(m.data,'$.origin')='human_ui'
                       AND json_type(m.data,'$.human_request_id')='text'
                       AND json_type(m.data,'$.human_response_id')='text')
                    ELSE 1 END ELSE 1 END
                ORDER BY d.rowid LIMIT 9
                """,arguments:[Data(pid.utf8),Data(pid.utf8),Data(sid.utf8),Data(generation.utf8)])
            for row in rows {
                // A malformed delivery names no recipient, so no route can give it to this
                // worker, and treating it as a candidate would hide every good answer in the
                // project (CL-414). A valid delivery to this worker with a malformed message can
                // be an answer. It cannot establish an empty pickup observation; the enclosing
                // post-commit decorator marks this unavailable for this worker alone.
                let delivery = try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"delivery").object
                guard delivery["recipient_session_id"] as? String == sid,
                      delivery["recipient_authorization_generation"] as? String == generation,
                      !["acknowledged","addressed"].contains(delivery["state"] as? String ?? ""),
                      let mid = delivery["message_id"] as? String,
                      let message = try noticeRecord(db,mid,pid,type:"message"),message["origin"] as? String == "human_ui",
                      let requestID = message["human_request_id"] as? String,
                      let responseID = message["human_response_id"] as? String,
                      let tid = message["task_id"] as? String,
                      let request = try noticeRecord(db,requestID,pid,type:"request"),request["task_id"] as? String == tid,
                      let response = (request["responses"] as? [JSON] ?? []).first(where: {$0["id"] as? String == responseID}),
                      response["origin"] as? String == "human_ui",int(response,"form_revision",default:1) == int(message,"form_revision",default:1),
                      let task = try noticeRecord(db,tid,pid,type:"task") else { continue }
                let action = response["action"] as? String ?? "answered"
                guard ["answered","send","clarification","clarify","cannot_do"].contains(action) else { continue }
                let project = try record(db,pid,type:"project")
                let item: JSON = ["project_name":project["name"] ?? "","task_key":task["key"] ?? "","task_title":task["title"] ?? "","project_id":pid,"task_id":tid,
                    "request_id":requestID,"response_id":responseID,"form_revision":int(response,"form_revision",default:1),"current_form_revision":int(request,"form_revision",
                    default:1),"current_request_state":request["state"] ?? "unknown","response_action":action,"response_complete":bool(response,"complete"),"message_id":mid,
                    "delivery_id":(try StoredRecord(delivery, family: "HumanAnswerNotices").requiredValue("id")),"delivery_state":delivery["state"] ?? "queued"]
                pending.append(item)
            }
        }
        guard !pending.isEmpty else { return output }
        let notices: JSON = ["schema_version":1,"status":"pending_pickup","observation":"live_recipient_delivery_state_not_cached_command_outcome","channel":"authenticated_tool_result","native_codex_wake_qualified":false,"items":Array(pending.prefix(8)),"has_more":pending.count > 8]
        var result = output
        if var data = result["data"] as? JSON { var metadata = data["_checklist"] as? JSON ?? [:];metadata["pending_human_answers"] = notices;data["_checklist"] = metadata;result["data"] = data }
        return result
    }

    private func noticeRecord(_ db: Database, _ id: String, _ project: String, type: String) throws -> JSON? {
        do { return try scoped(db,id,project,type:type) }
        catch let error as CoreError where error.code == "NOT_FOUND" { return nil }
    }

    func addingHumanAnswerNoticeFailure(_ db: Database, _ output: JSON, caller: Caller) -> JSON {
        addingNoticeFailure(db,output,caller:caller,keys:["pending_human_answers","pending_notes"])
    }

    private func addingNoticeFailure(_ db: Database, _ output: JSON, caller: Caller, keys: [String]) -> JSON {
        guard caller.role == "worker",let sid = caller.sessionID,caller.projectIDs.contains(where: { pid in
            let session: JSON
            do { session = try scoped(db,sid,pid,type:"session") }
            catch let error as CoreError where ["FORBIDDEN","ROOT_MISMATCH","NOT_FOUND"].contains(error.code) { return false }
            catch { return true } // A session read error is no proof of an empty inbox.
            return session["provider"] as? String == "codex" && canReceive(session,project:pid)
        }) else { return output }
        return markingNotices(output,keys:keys)
    }

    /// No read connection was available, so the provider cannot be read. A worker sees unavailable, not an empty inbox.
    func addingRecipientNoticesUnavailable(_ output: JSON, caller: Caller) -> JSON {
        guard caller.role == "worker",caller.sessionID != nil else { return output }
        return markingNotices(output,keys:["pending_human_answers","pending_notes"])
    }

    private func markingNotices(_ output: JSON, keys: [String]) -> JSON {
        var result = output
        if var data = result["data"] as? JSON {
            var metadata = data["_checklist"] as? JSON ?? [:]
            let unavailable: JSON = ["schema_version":1,"status":"unavailable","channel":"authenticated_tool_result","native_codex_wake_qualified":false,"items":[],"has_more":false]
            for key in keys { metadata[key] = unavailable }
            data["_checklist"] = metadata
            result["data"] = data
        }
        return result
    }
}
