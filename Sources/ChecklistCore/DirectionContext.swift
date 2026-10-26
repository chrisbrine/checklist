import ChecklistDomain
import Foundation
import GRDB

extension CommandRouter {
    func validateHumanGateDirection(_ db: Database, request: JSON, params: JSON, caller: Caller) throws {
        try owner(caller)
        let task = try scoped(db,(try StoredRecord(request, family: "request").string("task_id")),(try StoredRecord(request, family: "request").string("project_id")),type:"task")
        guard params["direction_cursor"] is String else { throw CoreError("DIRECTION_CURSOR_REQUIRED","Refresh this approval's ticket context before recording a gate verdict. Your answer draft remains saved.") }
        guard let expected = params["expected_task_revision"] as? NSNumber,CFGetTypeID(expected) != CFBooleanGetTypeID(),expected.doubleValue.rounded() == expected.doubleValue else { throw CoreError("REVISION_REQUIRED","Include the observed ticket revision separately from this request's form revision.") }
        guard expected.intValue == int(task,"revision") else { throw CoreError("REVISION_CONFLICT","This approval's ticket changed. Inspect its current context before recording a verdict.",details:["current_revision":int(task,"revision")]) }
        try validateDirectionCursor(db,params:params,task:task,caller:caller)
    }

    func relevantHandlerRecipients(_ db: Database, task: JSON) throws -> [JSON] {
        let pid = (try StoredRecord(task, family: "task").string("project_id")), tid = (try StoredRecord(task, family: "task").string("id"))
        let root = (task["active_attempt_id"] as? String).flatMap {try? scoped(db,$0,pid,type:"attempt")}
        let attempts: [JSON]
        if let root,root["state"] as? String == "active" {
            // The live accepted tree is task-scoped before any canonical row is
            // decoded. Historical attempts in this project are not context work.
            let sql="WITH RECURSIVE tree(id) AS (SELECT id FROM records WHERE type='attempt' AND project_id=CAST(? AS TEXT) AND id=CAST(? AS TEXT) AND json_extract(data,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY AND json_extract(data,'$.state')='active' UNION SELECT a.id FROM records a JOIN tree ON json_extract(a.data,'$.parent_attempt_id')=tree.id WHERE a.type='attempt' AND a.project_id=CAST(? AS TEXT) AND json_extract(a.data,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY AND json_extract(a.data,'$.state')='active') SELECT "+Self.canonicalColumns(alias:"r")+" FROM records r JOIN tree ON r.id=tree.id LIMIT 34"
            let rows=try Row.fetchAll(db,sql:sql,arguments:[Data(pid.utf8),Data(((try StoredRecord(root, family: "attempt").string("id"))).utf8),Data(tid.utf8),Data(pid.utf8),Data(tid.utf8)])
            guard rows.count<=33 else {throw CoreError("CAPACITY_EXCEEDED","The live task delegation tree exceeds its declared capacity.")}
            attempts=try rows.map {try GRDBRecordEnvelopeAdapter.decode($0,expectedType:"attempt").object}
        } else { attempts = [] }
        var result: [String:JSON] = [:]
        for attempt in attempts {
            guard let sid = attempt["session_id"] as? String,sid != "human",let session = try? scoped(db,sid,pid,type:"session"),session["role"] as? String == "worker",canReceive(session,project:pid),attempt["session_authorization_generation"] as? String == sessionGeneration(session) else { continue }
            // Child authority comes from an accepted attempt, never an unclaimed context attachment.
            if attempt["id"] as? String != task["active_attempt_id"] as? String,attempt["parent_attempt_id"] == nil { continue }
            result[sid] = ["session_id":sid,"attempt_id":attempt["id"]!,"recipient_role":attempt["parent_attempt_id"] == nil ? "handler" : "registered_child","display_name":session["label"] ?? "Worker"]
        }
        let project = try record(db,pid,type:"project"), policy = project["policy"] as? JSON ?? [:]
        if let sid = policy["coordinator_session_id"] as? String,result[sid] == nil,let session = try? scoped(db,sid,pid,type:"session"),session["role"] as? String == "worker",canReceive(session,project:pid) {
            result[sid] = ["session_id":sid,"recipient_role":"coordinator","display_name":session["label"] ?? "Coordinator"]
        }
        return result.values.sorted { ($0["session_id"] as? String ?? "") < ($1["session_id"] as? String ?? "") }
    }

    func queueDirectionDeliveries(_ db: Database, message: JSON, recipients: [JSON]) throws -> [JSON] {
        let pid = (try StoredRecord(message, family: "message").string("project_id")), mid = (try StoredRecord(message, family: "message").string("id"))
        var deliveries = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='delivery' AND project_id=? AND json_extract(data,'$.message_id')=? COLLATE BINARY ORDER BY rowid",arguments:[pid,mid]).map {try GRDBRecordEnvelopeAdapter.decode($0).object}
        for recipient in recipients {
            let sid = (try StoredRecord(recipient, family: "recipient").string("session_id")), session = try scoped(db,sid,pid,type:"session"), generation = sessionGeneration(session)
            if deliveries.contains(where: {$0["recipient_session_id"] as? String == sid && $0["recipient_authorization_generation"] as? String == generation}) { continue }
            var delivery: JSON = ["id":uuid(),"project_id":pid,"message_id":mid,"recipient_session_id":sid,"recipient_authorization_generation":generation,"recipient_role":recipient["recipient_role"] ?? "recipient","recipient_display":recipient["display_name"] ?? session["label"] ?? "Worker","state":"queued","push_state":"unavailable","push_reason":"Native push is unqualified; available on recipient MCP pickup.","revision":1,"created_at":now()]
            if let aid = recipient["attempt_id"] { delivery["recipient_attempt_id"] = aid }
            try save(db,delivery,type:"delivery"); deliveries.append(delivery)
        }
        return deliveries
    }

    @discardableResult
    func deliverSavedNotesToHandler(_ db: Database, task: JSON, caller: Caller) throws -> Bool {
        guard try !scopedTaskRows(db,type:"attempt",task:task,predicate:"json_extract(data,'$.state')='active' AND json_extract(data,'$.principal')=?",arguments:[caller.principal],limit:1).isEmpty else {return false}
        let recipients=try relevantHandlerRecipients(db,task:task)
        let pairs: [JSON]=try recipients.map {recipient in
            let sid=(try StoredRecord(recipient, family: "recipient").string("session_id")),session=try scoped(db,sid,(try StoredRecord(task, family: "task").string("project_id")),type:"session")
            return ["session":sid,"generation":sessionGeneration(session)]
        }
        guard !pairs.isEmpty else {return false}
        // Existing current-generation receipts are not decoded or revisited.
        // Each authenticated pickup processes at most50 missing notes; further
        // work is advertised, never hidden in a polling loop or huge allocation.
        let sql="SELECT "+Self.canonicalColumns(alias:"m")+" FROM records m WHERE m.type='message' AND m.project_id=CAST(? AS TEXT) AND json_extract(m.data,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY AND json_extract(m.data,'$.origin')='human_ui' AND (COALESCE(json_extract(m.data,'$.requires_action'),0)=0 OR \(Self.unretractedDirectionSQL("m"))) AND (NOT EXISTS (SELECT 1 FROM records d WHERE d.type='delivery' AND d.project_id=m.project_id AND json_extract(d.data,'$.message_id')=m.id) OR (json_extract(m.data,'$.requires_action')=1 AND COALESCE(json_extract(m.data,'$.addressed'),0)=0 AND EXISTS (SELECT 1 FROM json_each(?) target WHERE NOT EXISTS (SELECT 1 FROM records d WHERE d.type='delivery' AND d.project_id=m.project_id AND json_extract(d.data,'$.message_id')=m.id AND json_extract(d.data,'$.recipient_session_id')=json_extract(target.value,'$.session') COLLATE BINARY AND json_extract(d.data,'$.recipient_authorization_generation')=json_extract(target.value,'$.generation') COLLATE BINARY)))) ORDER BY m.rowid LIMIT 51"
        let rows=try Row.fetchAll(db,sql:sql,arguments:[Data(((try StoredRecord(task, family: "task").string("project_id"))).utf8),Data(((try StoredRecord(task,
            family: "task").string("id"))).utf8),try jsonString(pairs)])
        for row in rows.prefix(50) {
            let message=try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"message").object
            let deliverySQL = "SELECT " + Self.canonicalRecordColumns +
                " FROM records WHERE type='delivery' AND project_id=CAST(? AS TEXT)" +
                " AND json_extract(data,'$.message_id')=CAST(? AS TEXT) COLLATE BINARY ORDER BY rowid"
            let projectID = try StoredRecord(task, family: "task").string("project_id")
            let messageID = try StoredRecord(message, family: "message").string("id")
            let existing = try Row.fetchAll(db, sql: deliverySQL, arguments: [Data(projectID.utf8), Data(messageID.utf8)])
                .map {try GRDBRecordEnvelopeAdapter.decode($0,expectedType:"delivery").object}
            if bool(message,"requires_action") || message["human_request_id"] != nil {
                if existing.isEmpty || (bool(message,"requires_action") && !bool(message,"addressed")) {_=try queueDirectionDeliveries(db,message:message,recipients:recipients)}
            } else if message["ordinary_routing"] as? String != "tagged_reply",existing.isEmpty {_=try queueOrdinaryDeliveries(db,message:message,recipients:ordinaryHandlerRecipients(db,task:task))}
        }
        return rows.count>50
    }

    func validateDirectionDisposition(_ db: Database, delivery: JSON, params: JSON, caller: Caller) throws -> JSON {
        guard caller.role == "worker",let reference = params["response_ref"] as? JSON,let kind = reference["kind"] as? String,["message","checkpoint","manifest"].contains(kind),let id = reference["id"] as? String else { throw CoreError("DIRECTION_EVIDENCE_REQUIRED","Addressing a direction requires an actual message, checkpoint or manifest reference.") }
        let pid = (try StoredRecord(delivery, family: "delivery").string("project_id")), message = try scoped(db,(try StoredRecord(delivery,
            family: "delivery").string("message_id")),pid,type:"message")
        guard message["origin"] as? String == "human_ui",bool(message,"requires_action"),let tid = message["task_id"] as? String else { throw CoreError("INVALID_INPUT","Only a trusted requires-action ticket direction can be addressed.") }
        let task = try scoped(db,tid,pid,type:"task")
        guard let aid = task["active_attempt_id"] as? String,let attempt = try? scoped(db,aid,pid,type:"attempt"),attempt["state"] as? String == "active",attempt["principal"] as? String == caller.principal,attempt["session_id"] as? String == caller.sessionID else { throw CoreError("FORBIDDEN","Only the current handling attempt can dispose of a ticket direction. Other recipients may acknowledge their own copy.") }
        let response = try scoped(db,id,pid,type:kind)
        guard response["task_id"] as? String == tid else { throw CoreError("DIRECTION_EVIDENCE_REQUIRED","The referenced response belongs to another ticket.") }
        let author = kind == "message" ? response["author"] as? String : (kind == "manifest" ? response["author_principal"] as? String : response["principal"] as? String)
        let session = kind == "message" ? response["author_session_id"] as? String : (kind == "manifest" ? response["author_session_id"] as? String : response["session_id"] as? String)
        guard author == caller.principal,session == caller.sessionID else { throw CoreError("DIRECTION_EVIDENCE_REQUIRED","The referenced response was not recorded by this current handler.") }
        let mid = (try StoredRecord(message, family: "message").string("id"))
        let explicitlyBound = kind == "message" ? response["reply_to"] as? String == mid : strings(kind == "manifest" ? (response["evidence"] as? JSON ?? [:]) : response,"direction_ids").contains(mid)
        let responsePosition = try Int.fetchOne(db,sql:"SELECT rowid FROM records WHERE id=?",arguments:[id]) ?? 0
        let directionPosition = try Int.fetchOne(db,sql:"SELECT rowid FROM records WHERE id=?",arguments:[mid]) ?? 0
        guard explicitlyBound,responsePosition > directionPosition else { throw CoreError("DIRECTION_EVIDENCE_REQUIRED","Use a later response explicitly bound to this direction; arbitrary text and unrelated evidence cannot mark it addressed.") }
        let disposition: JSON = ["id":uuid(),"project_id":pid,"task_id":tid,"message_id":mid,"delivery_id":delivery["id"]!,"attempt_id":aid,"response_ref":["kind":kind,"id":id],"actor":caller.principal,"session_id":caller.sessionID!,"state":"addressed","revision":1,"created_at":now()]
        try save(db,disposition,type:"direction_disposition")
        return disposition
    }

    func directionWaive(_ db: Database,_ params: JSON,_ caller: Caller) throws -> JSON {
        let pid = try scope(db,params,caller,write:true); try requireAgentEditAuthority(db,project:try record(db,pid,type:"project"),caller:caller)
        var message = try scoped(db,try text(params,"message_id"),pid,type:"message"); try revision(params,message)
        guard message["origin"] as? String == "human_ui",bool(message,"requires_action") else { throw CoreError("INVALID_INPUT","Select a trusted owner direction.") }
        let storedMessage = StoredRecord(message, family: "message")
        let taskID = try storedMessage.requiredValue("task_id")
        let messageID = try storedMessage.requiredValue("id")
        let disposition: JSON = [
            "id":uuid(), "project_id":pid, "task_id":taskID, "message_id":messageID, "actor":caller.principal,
            "origin":caller.isOwner ? "human_ui" : "agent", "waiver_kind":caller.isOwner ? "owner_waiver" : "agent_waiver",
            "session_id":caller.sessionID ?? "human", "state":"waived", "reason":try text(params,"reason",max:4000),
            "revision":1, "created_at":now()
        ]
        try save(db,disposition,type:"direction_disposition")
        message["addressed"] = true
        message["disposition_id"] = disposition["id"]
        message["disposition_state"] = "waived"
        try save(db,revised(message),type:"message")
        try event(db,caller:caller,project:pid,entity:message["task_id"] as? String,kind:"direction_waived",
            data:["message_id":messageID,"disposition_id":disposition["id"]!])
        return disposition
    }

    func prepareProjectContextChange(_ db: Database, old: JSON, updated: JSON, caller: Caller) throws -> JSON {
        var result = updated
        guard updated["brief"] == nil || updated["brief"] is String else { throw CoreError("INVALID_INPUT","Project brief must be text.") }
        let oldBrief = old["brief"] as? String ?? "", newBrief = updated["brief"] as? String ?? ""
        guard newBrief.utf8.count <= 65536 else { throw CoreError("INVALID_INPUT","Project brief exceeds its text limit.") }
        let oldPins = old["pinned_decisions"] ?? [], rawPins = updated["pinned_decisions"] ?? []
        let pinsChanged = try jsonString(oldPins) != jsonString(rawPins)
        guard newBrief != oldBrief || pinsChanged else { return result }
        try requireAgentEditAuthority(db,project:old,caller:caller)
        let pid = (try StoredRecord(old, family: "project").string("id"))
        let previous: JSON = ["id":uuid(),"project_id":pid,"project_revision":int(old,"revision"),"brief":oldBrief,"pinned_decisions":oldPins,"brief_revision":int(old,"brief_revision"),"decisions_revision":int(old,"decisions_revision"),"previous_context_revision_id":old["previous_context_revision_id"] ?? NSNull(),"origin":"retained_project_context","revision":1,"created_at":now()]
        try save(db,previous,type:"project_context_revision")
        result["previous_context_revision_id"] = previous["id"]
        result["context_revision"] = int(old,"context_revision",default:1)+1
        if newBrief != oldBrief { result["brief_revision"] = int(old,"brief_revision")+1 }
        if pinsChanged {
            guard let entries = rawPins as? [Any],entries.count <= 25 else { throw CoreError("INVALID_INPUT","Use at most 25 short pinned decisions.") }
            let prior = old["pinned_decisions"] as? [JSON] ?? []
            var normalized: [JSON] = [], seen: Set<String> = []
            for entry in entries {
                let input = (entry as? String).map {["body":$0] as JSON} ?? entry as? JSON ?? [:]
                guard Set(input.keys).isSubset(of:["id","body","title","task_kinds","tag_ids","revision","origin","approved_by","approved_at"]),input["task_kinds"] == nil || input["task_kinds"] is [String],input["tag_ids"] == nil || input["tag_ids"] is [String],strings(input,"task_kinds").allSatisfy({TicketKind.wireValues.contains($0)}) else { throw CoreError("INVALID_INPUT","Pinned decisions contain unsupported fields or task kinds.") }
                let id = input["id"] as? String ?? uuid(); guard !seen.contains(id) else { throw CoreError("INVALID_INPUT","Pinned decision IDs must be distinct.") }; seen.insert(id)
                let oldPin = prior.first {$0["id"] as? String == id}
                if input["id"] != nil,oldPin == nil { throw CoreError("INVALID_INPUT","New decisions receive server-generated IDs; existing IDs must belong to this project.") }
                let body = try text(input,"body",max:4000)
                var pin: JSON = ["id":id,"body":body,"task_kinds":strings(input,"task_kinds"),"tag_ids":strings(input,"tag_ids")]
                for tag in strings(input,"tag_ids") { _ = try scoped(db,tag,pid,type:"tag") }
                if input["title"] != nil { pin["title"] = try text(input,"title",max:200) }
                let compareKeys: Set<String> = ["id","body","title","task_kinds","tag_ids"]
                let changed = try oldPin.map {try jsonString($0.filter {compareKeys.contains($0.key)}) != jsonString(pin)} ?? true
                pin["revision"] = (oldPin.map {int($0,"revision")} ?? 0)+(changed ? 1 : 0)
                pin["origin"] = changed ? (caller.isOwner ? "human_ui" : "agent") : oldPin?["origin"] ?? "human_ui"; pin["approved_by"] = changed ? caller.principal : oldPin?["approved_by"] ?? caller.principal; pin["approved_at"] = changed ? now() : oldPin?["approved_at"] ?? now()
                normalized.append(pin)
            }
            result["pinned_decisions"] = normalized; result["decisions_revision"] = int(old,"decisions_revision")+1
        }
        result["context_approved_by"] = caller.principal
        return result
    }

    func propagateProjectContextChange(_ db: Database, old: JSON, updated: JSON, caller: Caller) throws {
        guard int(old,"brief_revision") != int(updated,"brief_revision") || int(old,"decisions_revision") != int(updated,"decisions_revision") else { return }
        let pid = (try StoredRecord(updated, family: "project").string("id"))
        try mediaProjectContextChanged(db,old:old,updated:updated,caller:caller)
        for task in try records(db,type:"task",project:pid) where !bool(task,"archived") && !bool(task,"trashed") {
            let category = try taskProjection(db,task)["status_category"] as? String ?? ""
            if ["done","canceled"].contains(category) { continue }
            let prior = try jsonString(applicableDecisions(old,task:task)), current = try jsonString(applicableDecisions(updated,task:task))
            guard (old["brief"] as? String ?? "") != (updated["brief"] as? String ?? "") || prior != current else { continue }
            // An agent's context change is an ordinary agent note; only the owner channel creates a requires-action direction.
            guard caller.isOwner else {
                _ = try messageWrite(db,["project_id":pid,"task_id":task["id"]!,"body":"Ticket metadata: \(try agentReference(db,task)). An agent changed the project brief or pinned decisions. Read the current project context before continuing."],caller,"message_send")
                continue
            }
            let message: JSON = ["id":uuid(),"project_id":pid,"task_id":task["id"]!,"body":"Ticket metadata: \(try agentReference(db,task)). The approved project context changed. Read the current project brief and applicable pinned decisions before continuing.","kind":"project_context_changed","origin":"human_ui","author":caller.principal,"author_display":author(db,caller),"author_session_id":"human","original_requester_session_id":"human","requires_action":true,"addressed":false,"source_revisions":["project_revision":int(updated,"revision"),"brief_revision":int(updated,"brief_revision"),"decisions_revision":int(updated,"decisions_revision")],"previous_context_revision_id":updated["previous_context_revision_id"] ?? NSNull(),"revision":1,"created_at":now()]
            try save(db,message,type:"message"); _ = try queueDirectionDeliveries(db,message:message,recipients:relevantHandlerRecipients(db,task:task))
            try event(db,caller:caller,project:pid,entity:task["id"] as? String,kind:"message_saved",data:["message_id":message["id"]!,"origin":"human_ui","reason":"project_context_changed"])
        }
    }
}
