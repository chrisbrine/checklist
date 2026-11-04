import Foundation
import GRDB

extension CommandRouter {
    /// A live ticket summary, never a stored copy of mutable ticket authority.
    func mediaRoundTask(_ db: Database,round: JSON) throws -> JSON? {
        guard let id = round["task_id"] as? String else { return nil }
        let pid = try StoredRecord(round,family:"media ticket link").string("project_id")
        let task = try scoped(db,id,pid,type:"task")
        let status = try (task["status_id"] as? String).map {try scoped(db,$0,pid,type:"status")}
        return ["id":id,"key":task["key"] ?? "","title":task["title"] ?? "",
                "status_name":status?["name"] ?? ""]
    }

    /// Both creation and relinking validate exact same-project identities. A different
    /// destination makes only the affected items new; old messages remain history.
    func mediaSetTask(_ db: Database,round: inout JSON,input: JSON,project: String) throws {
        guard let raw = input["task_id"] else { return }
        var id: String?
        if !(raw is NSNull) {
            id = try text(input,"task_id")
            let task = try scoped(db,id!,project,type:"task")
            guard !bool(task,"purged") else {throw CoreError("TICKET_PURGED","A purged ticket cannot receive a new media link.")}
            round["record_references"] = (round["record_references"] as? [JSON] ?? []) + [try mediaRef("task",task)]
        }
        if var receipt = round["last_result_sent"] as? JSON,receipt["sends"] == nil,let previous = round["task_id"] as? String {
            receipt["sends"] = [["task_id":previous,"decision_ids":strings(receipt,"decision_ids")]]
            round["last_result_sent"] = receipt
        }
        // Send baselines belong to each item and its destination, so changing a
        // fallback never resets unrelated explicitly linked items.
        round["task_id"] = id
    }

    func mediaLinkTask(_ db: Database,_ p: JSON,_ c: Caller,project: String,resources: PreparedMediaResources,itemLink: Bool = false) throws -> JSON {
        if !resources.workerChannel { try owner(c) }
        var round = try scoped(db,try text(p,"round_id"),project,type:"media_round")
        var linked = itemLink ? try scoped(db,text(p,"item_id"),project,type:"media_item") : round
        if itemLink,!EnvelopeStorageIdentity.equal(linked["round_id"] as? String,round["id"] as? String) {
            throw CoreError("NOT_FOUND","This item is unavailable in this round.")
        }
        try mediaRevision(p,linked)
        guard ["draft","open"].contains(round["state"] as? String ?? "") else {
            throw CoreError("MEDIA_ROUND_CLOSED","A closed or archived round cannot change its ticket.")
        }
        guard p["task_id"] != nil else { throw CoreError("INVALID_INPUT","Name a ticket or explicitly clear task_id with null.") }
        try mediaSetTask(db,round:&linked,input:p,project:project)
        linked["task_linked_by"] = resources.workerChannel ? mediaAgentActor(c)
            : ["actor":c.principal,"actor_kind":"owner","origin":"human_ui","at":now()]
        linked = revised(linked)
        try mediaWrite(db,linked,type:itemLink ? "media_item" : "media_round")
        if itemLink {
            // Retire old round observations and page cursors along with the item revision.
            round = revised(round);try mediaWrite(db,round,type:"media_round")
            if resources.nativeOwnerProjection {return try mediaOwnerItem(db,round:round,itemID:text(p,"item_id"),caller:c)}
            var result: JSON = [:]
            for key in ["id","round_id","revision","task_id","task_linked_by"] {result[key] = linked[key]}
            result["task"] = try mediaRoundTask(db,round:linked) ?? NSNull()
            return result
        }
        if resources.workerChannel { return try mediaWorkerRound(db,round:linked,p:[:],c:c) }
        return try resources.nativeOwnerProjection ? mediaOwnerHeader(db,linked,c) : mediaRoundView(db,round:linked,caller:c)
    }

    /// Uses the ordinary ticket note writer inside the command's one transaction, so
    /// current recipients, message, outbox, send baseline and retry journal agree.
    func mediaSendResult(_ db: Database,_ p: JSON,_ c: Caller,project: String) throws -> JSON {
        try owner(c)
        var round = try scoped(db,try text(p,"round_id"),project,type:"media_round")
        try mediaRevision(p,round)
        guard ["draft","open"].contains(round["state"] as? String ?? "") else {
            throw CoreError("MEDIA_ROUND_CLOSED","A closed or archived round cannot send results.")
        }
        let items = try mediaItems(db,round:round)
        let manifest = try (round["manifest_id"] as? String).map {try scoped(db,$0,project,type:"media_round_manifest")}
        let members = mediaManifestMembers(manifest?["items"] as? [JSON] ?? []) {Data($0.utf8)}
        var current: [(item: JSON,target: JSON,decision: JSON)] = []
        var withdrawn: [(item: JSON,target: JSON,decision: JSON)] = []
        for item in items {
            guard let id = item["id"] as? String,let member = members[Data(id.utf8)],
                  let head = item["last_decision_id"] as? String else { continue }
            let decision = try scoped(db,head,project,type:"media_owner_decision")
            let isWithdrawn = decision["disposition"] as? String == "withdrawn"
            guard isWithdrawn || decision["review_basis_signature"] as? String == member["review_basis_signature"] as? String else { continue }
            let target = try scoped(db,try StoredRecord(member,family:"media_round_manifest").string("target_id"),project,type:"media_item_target")
            if isWithdrawn {withdrawn.append((item,target,decision))}
            else {current.append((item,target,decision))}
        }
        let last = round["last_result_sent"] as? JSON
        // Legacy CL-427 receipts apply to the round destination they were sent to.
        let oldSends = last?["sends"] as? [JSON] ?? (last.map {receipt -> [JSON] in
            guard let taskID = round["task_id"] as? String else {return []}
            var legacy = receipt;legacy["task_id"] = taskID;return [legacy]
        } ?? [])
        var previous: [Data:(String,JSON)] = [:]
        for send in oldSends {
            guard let taskID = send["task_id"] as? String else {continue}
            for id in strings(send,"decision_ids") {
                let decision = try scoped(db,id,project,type:"media_owner_decision")
                previous[Data(try StoredRecord(decision,family:"media_owner_decision").string("item_id").utf8)] = (taskID,decision)
            }
        }
        var grouped: [String:[(JSON,JSON)]] = [:]
        for (item,target,decision) in current + withdrawn {
            let old = previous[Data(try StoredRecord(item,family:"media_item").string("id").utf8)]
            if decision["disposition"] as? String == "withdrawn" {
                // Retract at the sent destination, even after links move or clear.
                // The new destination never received this decision.
                if let old {grouped[old.0,default:[]].append((target,decision))}
                continue
            }
            guard let taskID = item["task_id"] as? String ?? round["task_id"] as? String else {continue}
            let changed = old == nil || !EnvelopeStorageIdentity.equal(old?.0,taskID) ||
                ["disposition","note","winner_id","selection_outcome","review_basis_signature","no_follow_up_reason"].contains {
                    (old?.1[$0] as? String ?? "") != (decision[$0] as? String ?? "")
                } || bool(old?.1 ?? [:],"none_fit") != bool(decision,"none_fit")
            if changed {grouped[taskID,default:[]].append((target,decision))}
        }
        guard !grouped.isEmpty || items.contains(where:{($0["task_id"] as? String ?? round["task_id"] as? String) != nil}) else {
            // A retained send still permits a withdrawal-only retry after clearing links.
            if last != nil {throw CoreError("MEDIA_ROUND_NOTHING_NEW","No item decision, destination or note changed since the last send.")}
            throw CoreError("MEDIA_ROUND_NO_TASK","No item names a ticket, directly or through its round.")
        }
        if current.isEmpty,grouped.isEmpty,last == nil {
            throw CoreError("MEDIA_ROUND_NO_DECISIONS","Decide at least one current published item before sending.")
        }
        guard !grouped.isEmpty else { throw CoreError("MEDIA_ROUND_NOTHING_NEW","No item decision, destination or note changed since the last send.") }
        let labels = ["accepted":"Accepted","changes_requested":"Changes requested","needs_look":"Needs look","excluded":"Excluded"]
        var sends: [JSON] = [],references: [JSON] = []
        var sentAt = ""
        for taskID in grouped.keys.sorted() {
            let task = try scoped(db,taskID,project,type:"task")
            guard !bool(task,"purged") else {throw CoreError("TICKET_PURGED","A purged ticket cannot receive a new media result note.")}
            let changed = grouped[taskID]!
            let lines = changed.map { target,decision in
                if decision["disposition"] as? String == "withdrawn" {
                    return "\(target["title"] as? String ?? "Media item"): Pending — decision withdrawn"
                }
                return "\(target["title"] as? String ?? "Media item"): \(labels[decision["disposition"] as? String ?? ""] ?? "Needs look") — \(decision["note"] as? String ?? "")"
            }
            let body = "Media review: \(round["title"] as? String ?? "")\nRound: \(round["id"] as? String ?? "")\n\n" + lines.joined(separator:"\n")
            let message = try messageWrite(db,["project_id":project,"task_id":taskID,"body":body],c,"message_send",literalBody:true)
            let recipients = try (message["deliveries"] as? [JSON] ?? []).map { delivery -> JSON in
                let id = try StoredRecord(delivery,family:"delivery").string("recipient_session_id")
                let session = try scoped(db,id,project,type:"session")
                return ["session_id":id,"display":session["label"] as? String ?? sessionThreadLabel(session)]
            }
            sends.append(["task_id":taskID,"task_key":task["key"] ?? "","message_id":try StoredRecord(message,family:"message").string("id"),
                "recipients":recipients,"delivery_state":message["delivery_status"] ?? "saved_for_pickup","item_count":changed.count])
            sentAt = try StoredRecord(message,family:"message").string("created_at")
            references.append(try mediaRef("message",message))
        }
        // Keep all currently routed decisions, including unchanged siblings, and
        // the last actually sent choice of an unlinked item. A sibling's send
        // must not erase the destination which still needs a later withdrawal.
        let routed = current.filter {($0.item["task_id"] as? String ?? round["task_id"] as? String) != nil}
        var baselineRows: [(taskID: String,decision: JSON)] = routed.map {row in
            (row.item["task_id"] as? String ?? round["task_id"] as! String,row.decision)
        }
        for row in current where (row.item["task_id"] as? String ?? round["task_id"] as? String) == nil {
            if let old = previous[Data(try StoredRecord(row.item,family:"media_item").string("id").utf8)] {baselineRows.append(old)}
        }
        var baseline: [String:[String]] = [:]
        for row in baselineRows {
            baseline[row.taskID,default:[]].append(try StoredRecord(row.decision,family:"media_owner_decision").string("id"))
        }
        let previousDestinations = Set(previous.values.map {$0.0})
        var receipt: JSON = ["at":sentAt,"decision_ids":baselineRows.map {$0.decision["id"]!},"sends":try baseline.keys.sorted().map {taskID -> JSON in
            ["task_id":taskID,"task_key":try scoped(db,taskID,project,type:"task")["key"] ?? "","decision_ids":baseline[taskID]!]
        }]
        var result: JSON = ["sends":sends,"unsent_item_count":items.filter {($0["task_id"] as? String ?? round["task_id"] as? String) == nil}.count,
            "changed_only":Set(grouped.keys).isSubset(of:previousDestinations),"sent_at":sentAt]
        if items.allSatisfy({$0["task_id"] == nil}),sends.count == 1 {
            for key in ["message_id","recipients","delivery_state","item_count"] {result[key] = sends[0][key]}
            receipt["message_id"] = sends[0]["message_id"]
        }
        round["last_result_sent"] = receipt
        round["record_references"] = (round["record_references"] as? [JSON] ?? []) + references + (try baselineRows.map {try mediaRef("media_owner_decision",$0.decision)})
        round = revised(round);try mediaWrite(db,round,type:"media_round")
        return result
    }
}
