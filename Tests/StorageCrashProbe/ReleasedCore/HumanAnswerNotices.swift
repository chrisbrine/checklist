import Foundation
import GRDB

extension CommandRouter {
    /// Live delivery observation, added after command receipt persistence, including on replay.
    /// It never acknowledges a delivery, changes a request or grants work authority.
    func addingHumanAnswerNotices(_ db: Database, output: JSON, params: JSON, caller: Caller) throws -> JSON {
        guard caller.role == "worker",let sid = caller.sessionID else { return output }
        let requested = params["project_id"] as? String
        let projects = requested.map {[$0]} ?? Array(Set(caller.projectIDs)).sorted()
        var pending: [JSON] = []
        for pid in projects {
            guard caller.projectIDs.contains(pid) else { continue }
            do { _ = try scope(db,["project_id":pid],caller) }
            catch let error as CoreError where ["FORBIDDEN","ROOT_MISMATCH","NOT_FOUND"].contains(error.code) { continue }
            guard let session = try noticeRecord(db,sid,pid,type:"session"),
                  session["provider"] as? String == "codex",session["role"] as? String == "worker",
                  canReceive(session,project:pid) else { continue }
            let generation = sessionGeneration(session)
            let rows = try Row.fetchAll(db,sql:"""
                SELECT d.data FROM records d JOIN records m ON m.id=json_extract(d.data,'$.message_id')
                WHERE d.type='delivery' AND d.project_id=? AND m.type='message' AND m.project_id=?
                  AND json_extract(d.data,'$.recipient_session_id')=?
                  AND json_extract(d.data,'$.recipient_authorization_generation')=?
                  AND COALESCE(json_extract(d.data,'$.state'),'queued') NOT IN ('acknowledged','addressed')
                  AND json_extract(m.data,'$.origin')='human_ui'
                  AND json_type(m.data,'$.human_request_id')='text'
                  AND json_type(m.data,'$.human_response_id')='text'
                ORDER BY d.rowid LIMIT 9
                """,arguments:[pid,pid,sid,generation])
            for row in rows {
                let delivery = jsonObject(row["data"])
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
                      (try noticeRecord(db,tid,pid,type:"task")) != nil else { continue }
                let action = response["action"] as? String ?? "answered"
                guard ["answered","send","clarification","clarify","cannot_do"].contains(action) else { continue }
                let item: JSON = ["project_id":pid,"task_id":tid,"request_id":requestID,"response_id":responseID,"form_revision":int(response,"form_revision",default:1),"current_form_revision":int(request,"form_revision",default:1),"current_request_state":request["state"] ?? "unknown","response_action":action,"response_complete":bool(response,"complete"),"message_id":mid,"delivery_id":delivery["id"]!,"delivery_state":delivery["state"] ?? "queued"]
                pending.append(item)
            }
        }
        guard !pending.isEmpty else { return output }
        let notices: JSON = ["schema_version":1,"status":"pending_pickup","observation":"live_recipient_delivery_state_not_cached_command_outcome","channel":"authenticated_tool_result","native_codex_wake_qualified":false,"items":Array(pending.prefix(8)),"has_more":pending.count > 8]
        var result = output
        if var data = result["data"] as? JSON { data["_checklist"] = ["pending_human_answers":notices];result["data"] = data }
        return result
    }

    private func noticeRecord(_ db: Database, _ id: String, _ project: String, type: String) throws -> JSON? {
        do { return try scoped(db,id,project,type:type) }
        catch let error as CoreError where error.code == "NOT_FOUND" { return nil }
    }

    func addingHumanAnswerNoticeFailure(_ output: JSON, caller: Caller) -> JSON {
        guard caller.role == "worker",caller.sessionID != nil,!caller.projectIDs.isEmpty else { return output }
        var result = output
        if var data = result["data"] as? JSON {
            data["_checklist"] = ["pending_human_answers":["schema_version":1,"status":"unavailable","channel":"authenticated_tool_result","native_codex_wake_qualified":false,"items":[],"has_more":false]]
            result["data"] = data
        }
        return result
    }
}
