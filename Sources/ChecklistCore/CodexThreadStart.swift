import Foundation
import ChecklistProviders
import GRDB

/// CL-241: an enrolled agent asks its own Codex host to start a visible ticket conversation.
/// The service never starts a model, app-server or CLI runtime. It prepares the scoped prompt
/// and records only the outcome that the caller's host returned. Attachment stays with the new
/// thread's own bootstrap; this command never assigns or claims work.
extension CommandRouter {
    static let codexThreadHostRoute = "codex_app.create_thread"
    static let codexThreadOutcomes: Set<String> = ["created","unavailable","refused","failed"]

    /// The same text as ChecklistHandoff.instruction (ChecklistIPC); Core cannot import IPC.
    func ticketThreadInstruction(key: String,title: String,root: String,projectID: String,taskID: String) throws -> String {
        let args = try JSONSerialization.data(withJSONObject:["project_id":projectID,"task_id":taskID],options:[.sortedKeys])
        let json = String(decoding:args,as:UTF8.self)
        return "Use Checklist for \(key): \(title). Work in \(root). Run \(cliCommand) connect --task \(taskID) from that workspace; it registers this actual thread and attaches it to the ticket. Then run \(cliCommand) call task_context '\(json)' to read the task, project rules and notes. Run checklist tools for the supported schemas. Connecting alone does not claim or assign work."
    }

    func codexThreadStart(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        guard c.role != "assistant" else { throw CoreError("FORBIDDEN","Assistant connections cannot start ticket conversations.") }
        let pid = try scope(db,p,c,write:true),ticket = try task(db,p,pid),project = try record(db,pid,type:"project")
        let tid = ticket["id"] as? String ?? "",key = ticket["key"] as? String ?? tid,root = project["root_path"] as? String ?? ""
        let instruction = try ticketThreadInstruction(key:key,title:ticket["title"] as? String ?? "task",root:root,projectID:pid,taskID:tid)
        var fallback: JSON = ["kind":"copy_instruction","instruction":instruction,"owner_send_required":true]
        if let url = providerPlugins.plugin("codex", requiring: .composer)?.composeURL(instruction:instruction,workspace:root) {
            fallback["kind"] = "composer_owner_send";fallback["compose_url"] = url.absoluteString
        }
        var response: JSON = ["task_id":tid,"key":key,"provider":"codex","host_route":Self.codexThreadHostRoute,"claim_acquired":false,"assignment_changed":false]
        guard let outcome = p["host_outcome"] as? String else {
            response["state"] = "prepared";response["started"] = false;response["fallback"] = fallback
            response["host_request"] = ["tool":Self.codexThreadHostRoute,"prompt":instruction,"workspace":root]
            response["limitation"] = "Nothing has started. Call your own Codex host tool \(Self.codexThreadHostRoute) with this prompt and workspace, then call codex_thread_start again with host_outcome and the host-returned thread_id. Without that host tool, report host_outcome unavailable and use the fallback."
            return response
        }
        guard Self.codexThreadOutcomes.contains(outcome) else { throw CoreError("INVALID_INPUT","host_outcome must be created, unavailable, refused or failed.") }
        let thread = (p["thread_id"] as? String).map { $0.lowercased() }
        let detail = p["host_detail"] as? String
        var data: JSON = ["host_route":Self.codexThreadHostRoute,"outcome":outcome,"requested_by_session":c.sessionID ?? c.role,"claim_acquired":false,"assignment_changed":false]
        if let detail, !detail.isEmpty { data["host_detail"] = detail;response["host_detail"] = detail }
        if outcome == "created" {
            guard let thread, !thread.isEmpty else { throw CoreError("HOST_THREAD_IDENTITY_REQUIRED","A started conversation is recorded only with the thread identity that the Codex host returned.") }
            guard thread.range(of:"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",options:.regularExpression) != nil else { throw CoreError("INVALID_INPUT","thread_id must be the host-returned Codex thread UUID.") }
            guard thread != c.sessionID?.lowercased() else { throw CoreError("INVALID_INPUT","thread_id must identify the new conversation, not the requesting one.") }
            data["thread_id"] = thread;data["attachment_state"] = "pending_self_attach"
            try event(db,caller:c,project:pid,entity:tid,kind:"codex_thread_requested",data:data)
            response["state"] = "host_created";response["started"] = true;response["thread_id"] = thread;response["attachment_state"] = "pending_self_attach"
            response["limitation"] = "The Codex host returned this new thread. It attaches itself to the ticket when it runs connect --task; this record does not attach, assign or claim."
            return response
        }
        guard thread == nil else { throw CoreError("INVALID_INPUT","A thread_id is recorded only with host_outcome created.") }
        try event(db,caller:c,project:pid,entity:tid,kind:"codex_thread_requested",data:data)
        response["state"] = outcome;response["started"] = false;response["fallback"] = fallback
        response["limitation"] = "The Codex host route was \(outcome); no conversation started. Use the fallback: the owner opens the prepared composer and presses Send."
        return response
    }
}
