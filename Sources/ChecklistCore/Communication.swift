import Foundation
import GRDB

// Internal call-site purpose, never decoded from message_send JSON or a public flag.
enum MessageWritePurpose: Equatable { case ordinaryNote, trustedHumanResponse }

extension CommandRouter {
    /// The fixed recipient reactions to a note: seen/OK, no, done, looking into it, needs a question.
    static let noteReactions: Set<String> = ["thumbs_up","thumbs_down","done","looking","question"]

    func profileWrite(_ db: Database,_ p: JSON,_ c: Caller,_ method: String) throws -> JSON {
        try owner(c); var r: JSON
        if method == "profile_create" { r = ["id":uuid(),"revision":1,"state":"active","created_at":now(),"kind":"personal_assistant_setup","identity_source":"unqualified_setup","host_identity_verified":false] }
        else { r = try record(db,try text(p,"profile_id"),type:"profile"); try revision(p,r); r = revised(r) }
        if method == "profile_edit",r["identity_source"] as? String == "host" { throw CoreError("HOST_IDENTITY_REQUIRED","This personal assistant identity belongs to its host. Change its name or personality there.") }
        if method == "profile_archive" { r["state"] = "archived" }
        else { r["display_name"] = try text(p,"display_name",max:120); for key in ["avatar","pronouns","personality_summary"] { if let val = p[key] { r[key] = val } }; if let style = r["personality_summary"] as? String,style.count > 800 { throw CoreError("INVALID_INPUT","Personality hints are limited to 800 characters.") } }
        try save(db,r,type:"profile"); try event(db,caller:c,project:nil,entity:r["id"] as? String,kind:"profile_updated"); return r
    }
    func resolve(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        let pid = try scope(db,p,c)
        try assistantPermission(c,pid,"post_notes_on_request")
        guard (p["name"] != nil) != (p["agent_profile_id"] != nil) else { throw CoreError("INVALID_INPUT","Use an exact name or profile ID.") }
        let name = (p["name"] as? String ?? "").precomposedStringWithCanonicalMapping.folding(options:[.caseInsensitive],locale:Locale(identifier:"en_US_POSIX"))
        let profiles = try records(db,type:"profile").filter { r in
            r["state"] as? String == "active" && ((p["agent_profile_id"] as? String).map { $0 == r["id"] as? String } ?? ((r["display_name"] as? String ?? "").precomposedStringWithCanonicalMapping.folding(options:[.caseInsensitive],locale:Locale(identifier:"en_US_POSIX")) == name))
        }
        let sessions = try records(db,type:"session",project:pid)
        var candidates: [JSON] = []
        for profile in profiles {
            for session in sessions where session["profile_id"] as? String == profile["id"] as? String && canReceive(session,project:pid) && qualifiedPersonalAssistant(profile,session) {
                candidates.append(["agent_profile_id":profile["id"]!,"display_name":profile["display_name"]!,"session_id":session["id"]!,"provider":session["provider"] ?? "unknown","surface":"MCP","access_mode":session["role"] as? String == "assistant" ? "observer_messenger" : "worker","availability":session["state"] ?? "unknown","push_available":false])
            }
        }
        guard candidates.count == 1 else {
            let unqualified = profiles.contains { profile in sessions.contains { $0["profile_id"] as? String == profile["id"] as? String && $0["role"] as? String == "assistant" && canReceive($0,project:pid) && !qualifiedPersonalAssistant(profile,$0) } }
            return ["state":candidates.isEmpty ? (unqualified ? "unavailable" : "not_found") : "ambiguous","candidates":candidates,"reason":unqualified ? "This setup record is not a verified connected personal assistant identity. Worker sessions are contacted by their actual session reference." : ""]
        }
        let target = uuid()+uuid(); let candidate = candidates[0]; let session = try record(db,candidate["session_id"] as! String,type:"session")
        let r: JSON = ["id":target,"project_id":pid,"principal":c.principal,"session_id":candidate["session_id"]!,"session_revision":session["revision"]!,"profile_id":candidate["agent_profile_id"]!,"expires_at":Date().timeIntervalSince1970 + 300,"incarnation":incarnation,"task_id":p["task_id"] ?? NSNull(),"revision":1,"sender_authorization_scope":try authorizationScope(db,c)]
        try save(db,r,type:"recipient_target")
        return ["state":"resolved","recipient_target":target,"candidate":candidate,"delivery_capability":"pickup_only","push_available":false]
    }
    /// Omission selects current handlers. Any explicit route must be exact and closed.
    func explicitMessageRecipient(_ p: JSON) throws -> String? {
        guard let value = p["recipient"] else { return nil }
        guard let recipient = value as? JSON, Set(recipient.keys) == ["kind", "session_id"], recipient["kind"] as? String == "session" else {
            throw CoreError("INVALID_INPUT", "An explicit recipient requires exactly kind=session and session_id. Omit recipient for current handlers.")
        }
        return try text(recipient, "session_id", max: 4000)
    }
    func messageWrite(_ db: Database,_ p: JSON,_ c: Caller,_ method: String,purpose: MessageWritePurpose = .ordinaryNote) throws -> JSON {
        let pid = try scope(db,p,c,write:true)
        if purpose == .trustedHumanResponse {
            try owner(c)
            guard method == "message_send",p["recipient"] == nil,p["mention_target"] == nil else {
                throw CoreError("INVALID_INPUT","Trusted human continuations retain their protected internal route.")
            }
        }
        if method == "message_ack" {
            try assistantPermission(c,pid,"receive_messages")
            var delivery = try scoped(db,try text(p,"delivery_id"),pid,type:"delivery")
            guard try deliveryCurrent(db,delivery),c.sessionID != nil,delivery["recipient_session_id"] as? String == c.sessionID else { throw CoreError("FORBIDDEN","Only the exact recipient can acknowledge this delivery.") }
            let stage = p["stage"] as? String ?? "acknowledged"
            guard ["acknowledged","addressed"].contains(stage) else { throw CoreError("INVALID_INPUT","Invalid receipt stage.") }
            // A reaction shows the owner what this recipient did with the note. It is an acknowledgment
            // marker only: it never addresses a direction, grants authority or carries human provenance.
            let reaction = p["reaction"] as? String
            if let reaction { guard Self.noteReactions.contains(reaction) else { throw CoreError("INVALID_INPUT","Use one reaction: thumbs_up, thumbs_down, done, looking or question.") } }
            var disposition: JSON?
            if stage == "addressed" {
                guard c.role != "assistant" else { throw CoreError("FORBIDDEN","Assistants can acknowledge their own copy only.") }
                disposition = try validateDirectionDisposition(db,delivery:delivery,params:p,caller:c)
            }
            let reactionData: JSON = reaction.map { ["reaction":$0] } ?? [:]
            if delivery["state"] as? String == "addressed",stage == "acknowledged" {
                guard let reaction,delivery["reaction"] as? String != reaction else { return delivery }
                delivery["reaction"] = reaction; delivery["reaction_at"] = now(); delivery = revised(delivery); try save(db,delivery,type:"delivery")
                try event(db,caller:c,project:pid,entity:delivery["message_id"] as? String,kind:"message_reaction",data:reactionData); return delivery
            }
            delivery["state"] = stage; delivery[stage+"_at"] = now()
            if let reaction { delivery["reaction"] = reaction; delivery["reaction_at"] = now() }
            delivery = revised(delivery); try save(db,delivery,type:"delivery")
            if let disposition { var message = try scoped(db,delivery["message_id"] as! String,pid,type:"message"); message["addressed"] = true; message["disposition_id"] = disposition["id"]; message["disposition_state"] = "addressed"; delivery["disposition_id"] = disposition["id"]; try save(db,delivery,type:"delivery"); try save(db,revised(message),type:"message") }
            try event(db,caller:c,project:pid,entity:delivery["message_id"] as? String,kind:"message_"+stage,data:reactionData); return delivery
        }
        guard p["triage_id"] == nil || p["epic_id"] == nil else { throw CoreError("INVALID_INPUT","Select at most one Triage or Epic subject.") }
        let explicitSessionID = method == "message_send" ? try explicitMessageRecipient(p) : nil
        let mentionTarget = p["mention_target"] != nil ? try text(p,"mention_target",max:4000) : nil
        if mentionTarget != nil {
            guard method == "message_send",explicitSessionID == nil,!bool(p,"requires_action"),c.role != "assistant" else {
                throw CoreError("INVALID_INPUT","Mention plans are for ordinary worker/owner ticket notes, separately from explicit and protected routes.")
            }
        }
        var ordinaryRoute: OrdinaryMentionRoute?
        if c.isOwner, explicitSessionID != nil, bool(p,"requires_action") { throw CoreError("INVALID_INPUT", "Owner directions must omit recipient so all required handlers receive them.") }
        try assistantPermission(c,pid,"post_notes_on_request")
        if ["correction","retraction"].contains(p["kind"] as? String ?? ""),p["correction_of"] == nil { throw CoreError("INVALID_INPUT","A correction or retraction needs correction_of and text in body.") }
        let body = try text(p,"body",max:65536)
        if !c.isOwner && bool(p,"requires_action") { throw CoreError("HUMAN_CHANNEL_REQUIRED","Only a trusted owner note can create an owner direction.") }
        var taskID: String? = p["task_id"] as? String
        if let tid = taskID { let task = try scoped(db,tid,pid,type:"task"); if let expected = p["expected_attempt_id"] as? String,expected != (task["active_attempt_id"] as? String ?? "") { throw CoreError("RECIPIENT_CHANGED","The handler changed while this note was being drafted. Review the current recipient before sending.") } }
        var recipients: [String] = []; var recipientDetails: [JSON] = []; var conversationID: String?; var profileSnapshot: JSON = [:]
        let ownerReply: JSON? = (p["reply_to"] as? String).flatMap { try? scoped(db,$0,pid,type:"message") }
        if let original = ownerReply,original["reply_sender_session_id"] as? String == "human" {
            guard mentionTarget == nil else { throw CoreError("INVALID_INPUT","Protected owner replies retain their original human route.") }
            guard explicitSessionID == nil else { throw CoreError("INVALID_INPUT", "Replies to an owner note retain their original human route; omit recipient.") }
            guard original["reply_recipient_authorization_generation"] as? String == (try callerSessionGeneration(db,c,project:pid)),original["reply_recipient_session_id"] as? String == c.sessionID,bool(original,"reply_allowed"),!bool(original,"reply_used"),!bool(p,"expects_reply") else { throw CoreError("FORBIDDEN","No unused exact owner reply allowance exists.") }
            var original = original; original["reply_used"] = true; try save(db,revised(original),type:"message"); conversationID = original["conversation_id"] as? String; taskID = original["task_id"] as? String
        } else if method == "agent_message_send" {
            let target = try scoped(db,try text(p,"recipient_target"),pid,type:"recipient_target")
            guard target["sender_authorization_scope"] as? String == (try authorizationScope(db,c)),target["principal"] as? String == c.principal,target["incarnation"] as? String == incarnation,(target["expires_at"] as? Double ?? 0) > Date().timeIntervalSince1970 else { throw CoreError("RECIPIENT_CHANGED","Resolve this named agent again before sending.") }
            let sid = target["session_id"] as! String; let session = try scoped(db,sid,pid,type:"session")
            guard canReceive(session,project:pid),session["profile_id"] as? String == target["profile_id"] as? String,int(session,"revision") == int(target,"session_revision") else { throw CoreError("RECIPIENT_CHANGED","The connection changed; resolve it again.") }
            recipients = [sid]; let profile = try record(db,target["profile_id"] as! String,type:"profile"); profileSnapshot = ["display_name":profile["display_name"] ?? "Agent","provider":session["provider"] ?? "unknown"]
            if let targetTask = target["task_id"] as? String { guard taskID == targetTask else { throw CoreError("RECIPIENT_CHANGED","This route is bound to a different ticket context.") } }
            if let replyID = p["reply_to"] as? String {
                var original = try scoped(db,replyID,pid,type:"message")
                guard original["reply_recipient_authorization_generation"] as? String == (try callerSessionGeneration(db,c,project:pid)),original["reply_sender_authorization_generation"] as? String == sessionGeneration(session),original["reply_recipient_session_id"] as? String == c.sessionID,original["reply_sender_session_id"] as? String == sid,bool(original,"reply_allowed"),!bool(original,"reply_used") else { throw CoreError("FORBIDDEN","There is no unused reply allowance for these exact participants.") }
                guard !bool(p,"expects_reply") else { throw CoreError("FORBIDDEN","A permitted reply cannot authorize another reply.") }
                conversationID = original["conversation_id"] as? String; original["reply_used"] = true; try save(db,revised(original),type:"message")
            } else {
                conversationID = uuid()
                var generations = [sid:sessionGeneration(session)]
                if let sender = c.sessionID { generations[sender] = try callerSessionGeneration(db,c,project:pid) }
                let participants = [sid] + (c.sessionID.map { [$0] } ?? [])
                try save(db,["id":conversationID!,"project_id":pid,"participants":participants,"participant_authorization_generations":generations,"owner_participant":c.isOwner,"revision":1,"created_at":now()],type:"conversation")
            }
        } else {
            guard let tid = taskID else { throw CoreError("INVALID_INPUT","Ticket notes need task_id.") }
            let task = try scoped(db,tid,pid,type:"task")
            if let sid = explicitSessionID {
                guard c.role != "assistant" else { throw CoreError("FORBIDDEN","Assistants contact named agents through scoped routes.") }
                let session = try scoped(db,sid,pid,type:"session"); guard canReceive(session,project:pid) else { throw CoreError("FORBIDDEN","This recipient has no current message-receipt grant.") }; recipients = [sid]
            } else {
                if !bool(p,"requires_action"),c.role != "assistant",purpose == .ordinaryNote {
                    try validateOrdinaryMentionBody(db,project:pid,body:body,mentionTarget:mentionTarget)
                    let route = try ordinaryMessageRoute(db,project:pid,task:task,replyTo:p["reply_to"] as? String,mentionTarget:mentionTarget,caller:c)
                    ordinaryRoute = route; recipientDetails = route.recipients
                } else {
                    recipientDetails = try relevantHandlerRecipients(db,task:task).filter {$0["session_id"] as? String != c.sessionID}
                }
                recipients = recipientDetails.compactMap {$0["session_id"] as? String}
            }
        }
        if c.isOwner,bool(p,"requires_action"),let tid = taskID {
            let relevant = try relevantHandlerRecipients(db,task:scoped(db,tid,pid,type:"task"))
            for recipient in relevant where !recipients.contains(recipient["session_id"] as! String) { recipients.append(recipient["session_id"] as! String); recipientDetails.append(recipient) }
        }
        if p["correction_of"] != nil,let tid = taskID {
            guard method == "message_send",explicitSessionID == nil,mentionTarget == nil else { throw CoreError("INVALID_INPUT","Note corrections use the current ticket handlers; omit recipient and mention_target.") }
            recipientDetails = try relevantHandlerRecipients(db,task:scoped(db,tid,pid,type:"task"))
            recipients = recipientDetails.compactMap {$0["session_id"] as? String}
            ordinaryRoute = nil
        }
        let mid = ordinaryRoute?.messageID ?? uuid(); let origin = c.isOwner ? "human_ui" : (c.role == "assistant" ? "assistant" : "agent")
        var m: JSON = ["id":mid,"project_id":pid,"body":body,"kind":p["kind"] ?? "note","origin":origin,"author":c.principal,"author_display":author(db,c),"author_session_id":c.sessionID ?? "human","requires_action":c.isOwner && bool(p,"requires_action"),"addressed":false,"revision":1,"created_at":now(),"profile_snapshot":profileSnapshot]
        m["original_requester_session_id"] = c.sessionID ?? "human"; m["handler_session_ids_at_send"] = recipients
        if let route = ordinaryRoute { m["ordinary_routing"] = route.mode; m["mentions"] = route.references }
        for (field,kind) in [("triage_id","triage"),("epic_id","epic")] {
            if let id = p[field] as? String { let group = try scoped(db,id,pid,type:"group");guard group["kind"] as? String == kind else { throw CoreError("INVALID_INPUT","Select the matching group kind.") };m[field] = id }
        }
        if let tid = taskID { m["task_id"] = tid }; if let cid = conversationID { m["conversation_id"] = cid }
        if let reply = p["reply_to"] as? String {
            let original = try scoped(db,reply,pid,type:"message")
            guard original["task_id"] as? String == taskID,original["conversation_id"] as? String == conversationID else { throw CoreError("INVALID_INPUT","A reply must retain its original ticket and conversation scope.") }
            for field in ["triage_id","epic_id"] where m[field] == nil { m[field] = original[field] }
            m["reply_to"] = reply; m["original_requester_session_id"] = original["original_requester_session_id"] ?? original["author_session_id"] ?? "human"
        }
        if let correction = p["correction_of"] as? String {
            let original = try scoped(db,correction,pid,type:"message")
            guard original["author"] as? String == c.principal,original["task_id"] as? String == taskID,original["conversation_id"] as? String == conversationID else { throw CoreError("FORBIDDEN","Corrections append to the author's own note in the same ticket or conversation.") }
            try appendNoteRevision(db,original:original,message:&m,params:p,caller:c)
        }
        // The single reply allowance goes to the explicit recipient, or else to the current handler.
        // Recipients are sorted by session ID, so a child or coordinator can come first.
        let replyRecipient = explicitSessionID ?? (recipientDetails.isEmpty ? recipients.first : recipientDetails.first { $0["recipient_role"] as? String == "handler" }?["session_id"] as? String)
        if bool(p,"expects_reply"),let sid = replyRecipient { m["reply_allowed"] = true; m["reply_used"] = false; m["reply_recipient_session_id"] = sid; m["reply_sender_session_id"] = c.sessionID ?? "human";m["reply_recipient_authorization_generation"] = sessionGeneration(try scoped(db,sid,pid,type:"session"));m["reply_sender_authorization_generation"] = try callerSessionGeneration(db,c,project:pid) }
        try save(db,m,type:"message")
        if let health = try reconcileHealthReply(db,reply:m,caller:c) { m["health_reconciliation"] = health }
        let details = ordinaryRoute?.recipients ?? recipients.map {sid in recipientDetails.first {$0["session_id"] as? String == sid} ?? ["session_id":sid,"recipient_role":"recipient"]}
        let deliveries = ordinaryRoute != nil
            ? try queueOrdinaryDeliveries(db,message:m,recipients:details)
            : try queueDirectionDeliveries(db,message:m,recipients:details)
        try event(db,caller:c,project:pid,entity:taskID ?? conversationID,kind:"message_saved",data:["message_id":mid,"origin":origin])
        m["subject"] = try subject(db,message:m);m["deliveries"] = deliveries; m["delivery_status"] = recipients.isEmpty ? "saved_for_pickup" : "queued"; m["native_push"] = false; return m
    }
    /// Ticket-scoped receipt metadata only: this is never a recipient inbox read.
    func messageDeliveryList(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        let pid = try scope(db,p,c), tid = try text(p,"task_id"), mid = try text(p,"message_id")
        _ = try scoped(db,tid,pid,type:"task")
        let message = try scoped(db,mid,pid,type:"message")
        guard message["task_id"] as? String == tid else { throw CoreError("NOT_FOUND","This note is not available on this ticket.") }
        let rows = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='delivery' AND project_id=? AND json_extract(data,'$.message_id')=? COLLATE BINARY ORDER BY rowid",arguments:[pid,mid])
        let deliveries = try rows.map { row -> JSON in
            let delivery = try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"delivery").object
            // Keep transport receipts, reply allowances, note bodies and credentials private.
            let fields = ["id","message_id","recipient_session_id","recipient_authorization_generation","push_state","host_status","created_at","updated_at","delivered_at","acknowledged_at","addressed_at","host_status_at"]
            var result = delivery.filter { fields.contains($0.key) }
            let state = delivery["state"] as? String ?? "queued"
            result["state"] = ["acknowledged","addressed"].contains(state) ? "acknowledged" : (state == "delivered" ? "delivered" : "queued")
            if let closure = try deliveryNativeClosure(db,delivery) {
                result["state"] = "fenced"; result["native_closure_ref"] = closure["id"]
                result["fenced_at"] = closure["observed_at"]
            }
            return result
        }
        var result: JSON = ["message_id":mid,"task_id":tid,"deliveries":deliveries]
        // No recipient exists yet; do not invent a delivery ID or generation.
        if deliveries.isEmpty { result["delivery_status"] = "saved_for_pickup"; result["created_at"] = message["created_at"] }
        return result
    }

    /// Includes historical closures after the conversation has resumed with a new generation.
    func deliveryNativeClosure(_ db: Database,_ delivery: JSON) throws -> JSON? {
        guard !["acknowledged","addressed"].contains(delivery["state"] as? String ?? ""),
              let pid = delivery["project_id"] as? String, let sid = delivery["recipient_session_id"] as? String,
              let generation = delivery["recipient_authorization_generation"] as? String else { return nil }
        let row = try Row.fetchOne(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='native_closure' AND project_id=? AND json_extract(data,'$.session_id')=? COLLATE BINARY AND json_extract(data,'$.old_authorization_generation')=? COLLATE BINARY LIMIT 1",arguments:[pid,sid,generation])
        return try row.map { try GRDBRecordEnvelopeAdapter.decode($0,expectedType:"native_closure").object }
    }

    func inbox(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        guard let sid = c.sessionID else { throw CoreError("FORBIDDEN","This connection has no bound recipient.") }
        let pids: [String]
        if p["project_id"] != nil { pids = [try scope(db,p,c)] } else { pids = c.projectIDs.filter { c.role != "assistant" || (c.assistantGrants[$0]?["read"] == true && c.assistantGrants[$0]?["receive_messages"] == true) } }
        var deliveries: [JSON] = []
        for pid in pids { try assistantPermission(c,pid,"receive_messages"); for var d in try records(db,type:"delivery",project:pid) where d["recipient_session_id"] as? String == sid {
            guard try deliveryCurrent(db,d) else { continue }
            var message = try scoped(db,d["message_id"] as! String,pid,type:"message")
            let subject = try subject(db,message:message);message["subject"] = subject;d["subject"] = subject
            d["message"] = message; deliveries.append(d)
        } }
        return ["deliveries":deliveries,"messages":deliveries.compactMap { $0["message"] as? JSON }]
    }
    func history(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        let pid = try scope(db,p,c)
        let keys = ["task_id","triage_id","epic_id","conversation_id"].filter { p[$0] != nil }
        guard keys.count == 1 else { throw CoreError("INVALID_INPUT","Select exactly one task, group or conversation.") }
        let key = keys[0],id = try text(p,key); let type = key == "task_id" ? "task" : (key == "conversation_id" ? "conversation" : "group")
        let r = try scoped(db,id,pid,type:type)
        if type == "conversation",!c.isOwner { try assistantPermission(c,pid,"receive_messages"); guard let sid = c.sessionID,strings(r,"participants").contains(sid),(r["participant_authorization_generations"] as? [String:String])?[sid] == (try callerSessionGeneration(db,c,project:pid)) else { throw CoreError("FORBIDDEN","Only conversation participants can read these messages.") } }
        let cursorScope = pid+":"+key+":"+id+":"+(try authorizationScope(db,c))+":"+(try callerSessionGeneration(db,c,project:pid)); let after = try cursorSequence(db,p,caller:c,scope:cursorScope)
        let limit = min(max(int(p,"limit",default:200),1),200)
        let fetched = try Row.fetchAll(db,sql:"SELECT seq,id,actor,kind,occurred_at,data FROM events WHERE project_id=? AND entity_id=? AND seq>? ORDER BY seq LIMIT ?",arguments:[pid,id,after,limit+1])
        let rows = Array(fetched.prefix(limit))
        let events: [JSON] = rows.map { ["subject":["id":r["id"]!,"key":r["key"] ?? NSNull(),"title":r["title"] ?? r["name"] ?? ""],"id":$0["id"] as String,"actor":$0["actor"] as String,"kind":$0["kind"] as String,"occurred_at":$0["occurred_at"] as String,"data":jsonObject($0["data"])] }
        var seenMessageIDs = Set<SnapshotRecordIdentity>()
        let messageIDs = events.flatMap {entry -> [String] in let data = entry["data"] as? JSON ?? [:]; return [data["message_id"] as? String,data["reply_id"] as? String].compactMap {$0}}.filter {seenMessageIDs.insert(SnapshotRecordIdentity($0)).inserted}
        // Hydrate only IDs named by this authorized event page, never every project message.
        let identifiers = String(decoding:try JSONSerialization.data(withJSONObject:Array(messageIDs)),as:UTF8.self)
        let messages = chronologicalMessages(try Row.fetchAll(db,sql:"SELECT data FROM records WHERE type='message' AND project_id=? AND id IN (SELECT value FROM json_each(?)) AND json_extract(data,?)=? ORDER BY rowid",arguments:[pid,identifiers,"$."+key,id]).map {jsonObject($0["data"])})
        return ["events":events,"messages":try noteRevisionProjection(db,messages:messages,project:pid),"has_more":fetched.count > limit,"next_cursor":try cursor(db,caller:c,scope:cursorScope,sequence:rows.last.map { $0["seq"] as Int } ?? after)]
    }
}
