import Foundation
import GRDB

/// CL-350: a worker records one follow-up for a set of Changes requested owner decisions,
/// as exact per-decision `media_rework_link` rows. The rows name one existing ticket or one
/// worker reason the owner sees. Only the owner closes the round; a worker record never
/// appends a decision, moves a decision head or changes the round or the ticket.
/// CL-351: a worker suggestion on an exact Draft target, current only through its publication.
extension CommandRouter {
    struct MediaFollowUpIndex {
        var tickets: [Data:JSON] = [:]
        var reasons: [Data:JSON] = [:]
    }

    func mediaFollowUpIndex(_ links: [JSON]) -> MediaFollowUpIndex {
        var index = MediaFollowUpIndex()
        for link in links {
            guard let id = link["decision_id"] as? String else { continue }
            if link["task_id"] is String { if index.tickets[Data(id.utf8)] == nil { index.tickets[Data(id.utf8)] = link } }
            else if link["follow_up_reason"] is String,index.reasons[Data(id.utf8)] == nil { index.reasons[Data(id.utf8)] = link }
        }
        return index
    }

    /// One rule for Close and for its readiness count. A ticket wins over a worker reason,
    /// and a worker reason wins over the owner's no-follow-up reason.
    func mediaFollowUpResolution(_ db: Database,decision: JSON,index: MediaFollowUpIndex,project: String) -> (kind: String,link: JSON?)? {
        guard let id = decision["id"] as? String else { return nil }
        if let link = index.tickets[Data(id.utf8)],let task = link["task_id"] as? String,
           (try? scoped(db,task,project,type:"task")) != nil { return ("rework_linked",link) }
        if let link = index.reasons[Data(id.utf8)] { return ("worker_reason",link) }
        if let reason = decision["no_follow_up_reason"] as? String,!reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return ("no_follow_up",nil) }
        return nil
    }

    /// Worker and owner read the same safe row. It has no owner or session identity.
    func mediaFollowUpView(_ db: Database,index: MediaFollowUpIndex,decisionID: String,project: String) throws -> JSON? {
        if let link = index.tickets[Data(decisionID.utf8)] {
            return ["kind":"ticket","link_id":link["id"] ?? NSNull(),"task_id":link["task_id"] ?? NSNull(),"task_key":link["task_key"] ?? NSNull(),"origin":link["origin"] ?? NSNull()]
        }
        if let link = index.reasons[Data(decisionID.utf8)] {
            return ["kind":"worker_reason","link_id":link["id"] ?? NSNull(),"reason":link["follow_up_reason"] ?? NSNull(),"origin":link["origin"] ?? NSNull()]
        }
        return nil
    }

    private func mediaFollowUpTaskOpen(_ db: Database,task: JSON,project: String) -> Bool {
        guard !bool(task,"archived"),!bool(task,"trashed"),let statusID = task["status_id"] as? String,
              let status = try? scoped(db,statusID,project,type:"status") else { return false }
        return !["done","canceled"].contains(status["category"] as? String ?? "")
    }

    /// Worker command. Exact current decisions only; the whole selection refuses or commits.
    func mediaFollowUpRecord(_ db: Database,_ p: JSON,_ c: Caller,project pid: String) throws -> JSON {
        guard !c.isOwner else { throw CoreError("FORBIDDEN","A follow-up record keeps actual worker provenance; the owner decides in the native app.") }
        let round = try scoped(db,try text(p,"round_id"),pid,type:"media_round")
        guard round["state"] as? String == "open" else { throw CoreError("MEDIA_ROUND_CLOSED","A follow-up is recorded on an Open review record.") }
        try mediaObserve(db,p,round:round,caller:c)
        let manifest = try mediaObservedManifest(db,p,round:round)
        guard (p["task_id"] == nil) != (p["reason"] == nil) else { throw CoreError("INVALID_INPUT","A follow-up names exactly one of task_id or reason.") }
        var task: JSON?,reason: String?
        if p["task_id"] != nil {
            let selected = try scoped(db,try text(p,"task_id",max:4000),pid,type:"task")
            guard mediaFollowUpTaskOpen(db,task:selected,project:pid) else { throw CoreError("MEDIA_FOLLOW_UP_INELIGIBLE","A follow-up ticket must be open in this project.") }
            task = selected
        } else { reason = try text(p,"reason",max:4000) }
        let entries = try mediaReworkSelection(db,p,round:round,manifest:manifest,project:pid,exact:true)
        let index = mediaFollowUpIndex(try mediaReworkLinks(db,round:round))
        var links: [JSON] = [],created: [String] = [],reused: [String] = [],pending: [JSON] = []
        for e in entries {
            let decisionID = try StoredRecord(e.decision, family: "media").string("id"),key = Data(decisionID.utf8)
            if let existing = index.tickets[key] ?? index.reasons[key] {
                let same = task.map { EnvelopeStorageIdentity.equal(existing["task_id"] as? String,$0["id"] as? String) }
                    ?? (existing["task_id"] == nil && existing["follow_up_reason"] as? String == reason)
                guard same else { throw CoreError("MEDIA_FOLLOW_UP_EXISTS","This decision already has another recorded follow-up. No records changed.") }
                links.append(existing);reused.append(try StoredRecord(existing, family: "media").string("id"));continue
            }
            var fields: JSON = ["round_id":round["id"]!,"item_id":e.item["id"]!,"decision_id":decisionID,
                "target_id":e.member["target_id"]!,"review_basis_signature":e.member["review_basis_signature"]!,"manifest_id":manifest["id"]!]
            var references = [try mediaRef("media_round",round),try mediaRef("media_item",e.item),
                ["type":"media_owner_decision","id":decisionID,"revision":e.decision["revision"]!],
                ["type":"media_item_target","id":e.member["target_id"]!,"revision":1],
                ["type":"media_round_manifest","id":manifest["id"]!,"revision":manifest["revision"]!]] as [JSON]
            if let task {
                fields["task_id"] = task["id"];fields["task_key"] = task["key"] ?? NSNull();fields["state"] = "linked"
                references.append(["type":"task","id":task["id"]!])
            } else {
                fields["follow_up_reason"] = reason;fields["state"] = "worker_reason"
            }
            pending.append(mediaRecord(fields,project:pid,caller:c,references:references))
        }
        for link in pending {
            try mediaWrite(db,link,type:"media_rework_link")
            links.append(link);created.append(try StoredRecord(link, family: "media").string("id"))
        }
        return ["id":round["id"]!,"links":links,"created_link_ids":created,"reused_link_ids":reused]
    }

    /// Grouped owner projection: one ticket row with its decision count, and each worker reason
    /// of a CURRENT decision. A reason for a superseded decision is history and is not listed.
    func mediaFollowUpSummary(_ db: Database,all: [JSON],ticketLinks: [JSON],project: String) throws -> JSON {
        var order: [String] = [],tickets: [String:JSON] = [:],open = 0,closed = 0,unavailable = 0
        for link in ticketLinks {
            guard let id = link["task_id"] as? String else { continue }
            if var row = tickets[id] { row["decision_count"] = int(row,"decision_count") + 1;tickets[id] = row;continue }
            order.append(id)
            tickets[id] = ["task_id":id,"task_key":link["task_key"] ?? NSNull(),"task_title":link["task_title"] ?? NSNull(),"task_open":link["task_open"] ?? false,
                "task_status_category":link["task_status_category"] ?? "unavailable","decision_count":1]
            if link["task_status_category"] as? String == "unavailable" { unavailable += 1 }
            else if bool(link,"task_open") { open += 1 } else { closed += 1 }
        }
        var reasonOrder: [String] = [],reasons: [String:JSON] = [:]
        for link in all {
            guard let reason = link["follow_up_reason"] as? String,let itemID = link["item_id"] as? String,
                  let item = try? scoped(db,itemID,project,type:"media_item"),
                  EnvelopeStorageIdentity.equal(item["last_decision_id"] as? String,link["decision_id"] as? String) else { continue }
            let session = link["author_session_id"] as? String ?? "",key = session + "\u{0}" + reason
            if var row = reasons[key] {
                row["decision_count"] = int(row,"decision_count") + 1;row["item_ids"] = strings(row,"item_ids") + [itemID];reasons[key] = row;continue
            }
            let source = (try? scoped(db,session,project,type:"session")).map(sessionThreadLabel) ?? "Recorded worker"
            reasonOrder.append(key)
            reasons[key] = ["reason":reason,"source_label":source,"origin":link["origin"] ?? NSNull(),"created_at":link["created_at"] ?? NSNull(),"item_ids":[itemID],"decision_count":1]
        }
        return ["tickets":order.compactMap {tickets[$0]},"ticket_counts":["open":open,"closed":closed,"unavailable":unavailable],
            "worker_reasons":reasonOrder.compactMap {reasons[$0]}]
    }

    /// Unfiltered counts for the owner's Close button, with the same rule as closure.
    func mediaCloseReadiness(_ db: Database,round: JSON) throws -> JSON {
        let project = try StoredRecord(round, family: "media").string("project_id")
        let index = mediaFollowUpIndex(try mediaReworkLinks(db,round:round))
        var counts: [String:Int] = ["pending":0,"stale":0,"needs_look":0,"missing_follow_up":0]
        for row in try mediaRoundDispositionIndex(db,round:round) {
            let disposition = try StoredRecord(row, family: "media").string("disposition")
            counts[disposition, default:0] += 1
            guard disposition == "changes_requested",let id = row["decision_id"] as? String else { continue }
            let decision = try scoped(db,id,project,type:"media_owner_decision")
            if mediaFollowUpResolution(db,decision:decision,index:index,project:project) == nil { counts["missing_follow_up", default:0] += 1 }
        }
        return counts
    }

    /// CL-351: the exact Draft members of this selection, in the shape of a manifest's `items`.
    /// A Draft has no manifest, so a supplied manifest observation cannot be current.
    func mediaDraftSuggestionMembers(_ db: Database,_ p: JSON,project: String) throws -> JSON {
        guard p["manifest_id"] == nil,p["manifest_digest"] == nil else { throw CoreError("MEDIA_MANIFEST_CHANGED","A Draft round has no manifest. Inspect the current round.") }
        let items = try (p["items"] as? [JSON] ?? []).map { entry -> JSON in
            let item = try scoped(db,try text(entry,"item_id"),project,type:"media_item")
            let target = try scoped(db,try StoredRecord(item, family: "media").string("draft_target_id"),project,type:"media_item_target")
            return ["item_id":try StoredRecord(item, family: "media").requiredValue("id"),"target_id":try StoredRecord(target, family: "media").requiredValue("id"),
                "review_basis_signature":try StoredRecord(target, family: "media").requiredValue("review_basis_signature")]
        }
        return ["items":items]
    }

    /// A suggestion is current on its exact target and basis, or, when recorded on a Draft
    /// target, on the target published from that exact Draft target with the same basis.
    func mediaSuggestionCurrent(_ suggestion: JSON,target: JSON) -> Bool {
        guard suggestion["review_basis_signature"] as? String == target["review_basis_signature"] as? String else { return false }
        if EnvelopeStorageIdentity.equal(suggestion["target_id"] as? String,target["id"] as? String) { return true }
        return suggestion["target_phase"] as? String == "draft" && target["published_from_target_id"] is String
            && EnvelopeStorageIdentity.equal(suggestion["target_id"] as? String,target["published_from_target_id"] as? String)
    }
}
