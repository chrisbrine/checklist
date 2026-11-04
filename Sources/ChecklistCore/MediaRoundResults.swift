import Foundation
import GRDB

extension CommandRouter {
    /// A live ticket summary, never a stored copy of mutable ticket authority.
    func mediaRoundTask(_ db: Database,round: JSON) throws -> JSON? {
        guard let id = round["task_id"] as? String else { return nil }
        let pid = try StoredRecord(round,family:"media_round").string("project_id")
        let task = try scoped(db,id,pid,type:"task")
        let status = try (task["status_id"] as? String).map {try scoped(db,$0,pid,type:"status")}
        return ["id":id,"key":task["key"] ?? "","title":task["title"] ?? "",
                "status_name":status?["name"] ?? ""]
    }

    /// Both creation and relinking validate exact same-project identities. A different
    /// destination starts a fresh send baseline; old messages/references remain history.
    func mediaSetTask(_ db: Database,round: inout JSON,input: JSON,project: String) throws {
        guard let raw = input["task_id"] else { return }
        var id: String?
        if !(raw is NSNull) {
            id = try text(input,"task_id")
            let task = try scoped(db,id!,project,type:"task")
            guard !bool(task,"purged") else {throw CoreError("TICKET_PURGED","A purged ticket cannot receive a new media link.")}
            round["record_references"] = (round["record_references"] as? [JSON] ?? []) + [try mediaRef("task",task)]
        }
        if !EnvelopeStorageIdentity.equal(id,round["task_id"] as? String) { round["last_result_sent"] = nil }
        round["task_id"] = id
    }

    func mediaLinkTask(_ db: Database,_ p: JSON,_ c: Caller,project: String,resources: PreparedMediaResources) throws -> JSON {
        if !resources.workerChannel { try owner(c) }
        var round = try scoped(db,try text(p,"round_id"),project,type:"media_round")
        try mediaRevision(p,round)
        guard ["draft","open"].contains(round["state"] as? String ?? "") else {
            throw CoreError("MEDIA_ROUND_CLOSED","A closed or archived round cannot change its ticket.")
        }
        guard p["task_id"] != nil else { throw CoreError("INVALID_INPUT","Name a ticket or explicitly clear task_id with null.") }
        try mediaSetTask(db,round:&round,input:p,project:project)
        round["task_linked_by"] = resources.workerChannel ? mediaAgentActor(c)
            : ["actor":c.principal,"actor_kind":"owner","origin":"human_ui","at":now()]
        round = revised(round);try mediaWrite(db,round,type:"media_round")
        if resources.workerChannel { return try mediaWorkerRound(db,round:round,p:[:],c:c) }
        return try resources.nativeOwnerProjection ? mediaOwnerHeader(db,round,c) : mediaRoundView(db,round:round,caller:c)
    }

    /// Uses the ordinary ticket note writer inside the command's one transaction, so
    /// current recipients, message, outbox, send baseline and retry journal agree.
    func mediaSendResult(_ db: Database,_ p: JSON,_ c: Caller,project: String) throws -> JSON {
        try owner(c)
        var round = try scoped(db,try text(p,"round_id"),project,type:"media_round")
        try mediaRevision(p,round)
        guard let taskID = round["task_id"] as? String else {
            throw CoreError("MEDIA_ROUND_NO_TASK","Link the ticket that owns this round before sending its result.")
        }
        let task = try scoped(db,taskID,project,type:"task")
        guard !bool(task,"purged") else {throw CoreError("TICKET_PURGED","A purged ticket cannot receive a new media result note.")}
        let manifest = try (round["manifest_id"] as? String).map {try scoped(db,$0,project,type:"media_round_manifest")}
        let members = mediaManifestMembers(manifest?["items"] as? [JSON] ?? []) {Data($0.utf8)}
        var current: [(JSON,JSON)] = []
        for item in try mediaItems(db,round:round) {
            guard let id = item["id"] as? String,let member = members[Data(id.utf8)],
                  let head = item["last_decision_id"] as? String else { continue }
            let decision = try scoped(db,head,project,type:"media_owner_decision")
            guard decision["disposition"] as? String != "withdrawn",
                  decision["review_basis_signature"] as? String == member["review_basis_signature"] as? String else { continue }
            let target = try scoped(db,try StoredRecord(member,family:"media_round_manifest").string("target_id"),project,type:"media_item_target")
            current.append((target,decision))
        }
        guard !current.isEmpty else { throw CoreError("MEDIA_ROUND_NO_DECISIONS","Decide at least one current published item before sending.") }
        let last = round["last_result_sent"] as? JSON
        var previous: [Data:JSON] = [:]
        for id in strings(last ?? [:],"decision_ids") {
            let decision = try scoped(db,id,project,type:"media_owner_decision")
            previous[Data(try StoredRecord(decision,family:"media_owner_decision").string("item_id").utf8)] = decision
        }
        let changed = current.filter { _,decision in
            guard let id = decision["item_id"] as? String,let old = previous[Data(id.utf8)] else { return true }
            return ["disposition","note","winner_id","selection_outcome","review_basis_signature","no_follow_up_reason"].contains {
                (old[$0] as? String ?? "") != (decision[$0] as? String ?? "")
            } || bool(old,"none_fit") != bool(decision,"none_fit")
        }
        guard !changed.isEmpty else { throw CoreError("MEDIA_ROUND_NOTHING_NEW","No item decision or note changed since the last send.") }
        let labels = ["accepted":"Accepted","changes_requested":"Changes requested","needs_look":"Needs look","excluded":"Excluded"]
        let lines = changed.map { target,decision in
            "\(target["title"] as? String ?? "Media item"): \(labels[decision["disposition"] as? String ?? ""] ?? "Needs look") — \(decision["note"] as? String ?? "")"
        }
        let body = "Media review: \(round["title"] as? String ?? "")\nRound: \(round["id"] as? String ?? "")\n\n" + lines.joined(separator:"\n")
        let message = try messageWrite(db,["project_id":project,"task_id":taskID,"body":body],c,"message_send",literalBody:true)
        let messageID = try StoredRecord(message,family:"message").string("id")
        let sentAt = try StoredRecord(message,family:"message").string("created_at")
        round["last_result_sent"] = ["message_id":messageID,"at":sentAt,"decision_ids":current.map {$0.1["id"]!}]
        round["record_references"] = (round["record_references"] as? [JSON] ?? []) + [try mediaRef("message",message)] + (try current.map {try mediaRef("media_owner_decision",$0.1)})
        round = revised(round);try mediaWrite(db,round,type:"media_round")
        let recipients = try (message["deliveries"] as? [JSON] ?? []).map { delivery -> JSON in
            let id = try StoredRecord(delivery,family:"delivery").string("recipient_session_id")
            let session = try scoped(db,id,project,type:"session")
            return ["session_id":id,"display":session["label"] as? String ?? sessionThreadLabel(session)]
        }
        return ["message_id":messageID,"recipients":recipients,"item_count":changed.count,"changed_only":last != nil,"sent_at":sentAt]
    }
}
