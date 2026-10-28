import Foundation
import GRDB

/// CL-118: owner-selected Changes-requested decisions become ordinary Draft tickets through
/// exact `media_rework_link` records; review-record closure counts rework separately; explicit
/// successor rounds carry a decision only for an identical complete basis. Internal seam only.
/// A rework ticket is ordinary work: its status never writes a media decision, a round or a
/// code-review gate, and media decisions never satisfy that ticket's own guards.
extension CommandRouter {
    private struct MediaReworkEntry {
        let item: JSON
        let decision: JSON
        let member: JSON
        let title: String
    }

    /// Links are mutable-family records keyed by the exact decision they answer.
    func mediaReworkLinks(_ db: Database,round: JSON) throws -> [JSON] {
        let rows = try Row.fetchAll(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='media_rework_link' AND project_id=CAST(? AS TEXT)"
            + " AND json_extract(data,'$.round_id')=CAST(? AS TEXT) COLLATE BINARY ORDER BY id COLLATE BINARY",
            arguments:[Data((try StoredRecord(round, family: "media").string("project_id")).utf8),
                       Data((try StoredRecord(round, family: "media").string("id")).utf8)])
        return try rows.map { try GRDBRecordEnvelopeAdapter.decode($0,expectedType:"media_rework_link").object }
    }

    /// Live projection beside the immutable record: a Closed round can show open rework.
    func mediaReworkSummary(_ db: Database,round: JSON) throws -> JSON {
        let pid = try StoredRecord(round, family: "media").string("project_id")
        var open = 0,done = 0,unavailable = 0
        let links = try mediaReworkLinks(db,round:round).map { link -> JSON in
            var row = link
            if let task = try? scoped(db,(try StoredRecord(link, family: "media").string("task_id")),pid,type:"task"),
               let statusID = task["status_id"] as? String,let status = try? scoped(db,statusID,pid,type:"status") {
                let category = status["category"] as? String ?? ""
                row["task_key"] = task["key"];row["task_title"] = task["title"];row["task_status_category"] = category
                row["task_open"] = !["done","canceled"].contains(category) && !bool(task,"archived") && !bool(task,"trashed")
                if bool(row,"task_open") { open += 1 } else { done += 1 }
            } else { row["task_open"] = false;row["task_status_category"] = "unavailable";unavailable += 1 }
            return row
        }
        return ["links":links,"counts":["linked":links.count,"open":open,"closed":done,"unavailable":unavailable]]
    }

    private func mediaReworkTitle(_ title: String) -> String {
        var result = "Rework: "
        for character in title where result.utf8.count + String(character).utf8.count <= 2000 { result.append(character) }
        return result
    }

    /// Validates the exact selected current applicable Changes-requested decision heads.
    /// Accepted, Pending, Needs-look, Excluded and Stale items refuse the whole selection.
    private func mediaReworkSelection(_ db: Database,_ p: JSON,round: JSON,manifest: JSON,project pid: String,exact: Bool) throws -> [MediaReworkEntry] {
        guard let selected = p["items"] as? [JSON],!selected.isEmpty,selected.count <= 200 else { throw CoreError("INVALID_INPUT","Select 1 to 200 Changes-requested items.") }
        var seen = Set<String>(),entries: [MediaReworkEntry] = []
        for entry in selected {
            let allowed: Set<String> = exact ? ["item_id","expected_revision","decision_id"] : ["item_id"]
            guard Set(entry.keys) == allowed else { throw CoreError("INVALID_INPUT",exact ? "Rework needs the exact item revision and decision." : "Preview names exact item IDs.") }
            let item = try scoped(db,try text(entry,"item_id"),pid,type:"media_item")
            guard seen.insert(try StoredRecord(item, family: "media").string("id")).inserted else { throw CoreError("INVALID_INPUT","Select distinct items.") }
            if exact { try mediaRevision(entry,item) }
            guard EnvelopeStorageIdentity.equal(item["round_id"] as? String,round["id"] as? String),
                  let member = (try StoredRecord(manifest, family: "media").objects("items")).first(where:{EnvelopeStorageIdentity.equal($0["item_id"] as? String,item["id"] as? String)}),
                  let head = item["last_decision_id"] as? String else { throw CoreError("MEDIA_REWORK_INELIGIBLE","Only a current Changes requested owner decision can create rework.") }
            let decision = try scoped(db,head,pid,type:"media_owner_decision")
            guard decision["review_basis_signature"] as? String == member["review_basis_signature"] as? String,
                  decision["disposition"] as? String == "changes_requested" else { throw CoreError("MEDIA_REWORK_INELIGIBLE","Only a current Changes requested owner decision can create rework.") }
            if exact,entry["decision_id"] as? String != head { throw CoreError("MEDIA_BASIS_CHANGED","The selected decision is no longer the item's current owner decision.") }
            let target = try scoped(db,(try StoredRecord(member, family: "media").string("target_id")),pid,type:"media_item_target")
            entries.append(.init(item:item,decision:decision,member:member,title:mediaReworkTitle(target["title"] as? String ?? "Media item")))
        }
        return entries
    }

    private func mediaReworkPreviewDigest(round: JSON,manifest: JSON,epicID: String,entries: [MediaReworkEntry]) throws -> String {
        try MediaCanonical.signature(["domain":"media-rework-preview-v1","round_id":try StoredRecord(round, family: "media").requiredValue("id"),
            "manifest_id":try StoredRecord(manifest, family: "media").requiredValue("id"),"manifest_digest":try StoredRecord(manifest, family: "media").requiredValue("digest"),
            "epic_id":epicID,"items":entries.map { e -> JSON in
                ["item_id":e.item["id"] ?? NSNull(),"item_revision":e.item["revision"] ?? NSNull(),"decision_id":e.decision["id"] ?? NSNull(),
                 "target_id":e.member["target_id"] ?? NSNull(),"review_basis_signature":e.member["review_basis_signature"] ?? NSNull(),"title":e.title] }])
    }

    private func mediaReworkEpic(_ db: Database,_ p: JSON,project pid: String) throws -> String {
        let epic = try scoped(db,try text(p,"epic_id",max:4000),pid,type:"group")
        guard epic["kind"] as? String == "epic",!bool(epic,"archived") else { throw CoreError("INVALID_INPUT","Choose a current Epic in this project.") }
        return try StoredRecord(epic, family: "group").string("id")
    }

    /// Read-only owner preview: what would be created and which exact links are reused.
    func mediaReworkPreview(_ db: Database,_ p: JSON,_ c: Caller,project pid: String) throws -> JSON {
        try owner(c)
        let round = try scoped(db,try text(p,"round_id"),pid,type:"media_round")
        guard round["state"] as? String == "open",let manifestID = round["manifest_id"] as? String else { throw CoreError("MEDIA_ROUND_CLOSED","Rework is created from an Open review record.") }
        let manifest = try scoped(db,manifestID,pid,type:"media_round_manifest")
        let epicID = try mediaReworkEpic(db,p,project:pid)
        let entries = try mediaReworkSelection(db,p,round:round,manifest:manifest,project:pid,exact:false)
        let links = try mediaReworkLinks(db,round:round)
        let rows = entries.map { e -> JSON in
            var row: JSON = ["item_id":e.item["id"]!,"expected_revision":e.item["revision"]!,"decision_id":e.decision["id"]!,
                "target_id":e.member["target_id"]!,"review_basis_signature":e.member["review_basis_signature"]!,"title":e.title,
                "note":e.decision["note"] ?? NSNull()]
            if let link = links.first(where:{$0["decision_id"] as? String == e.decision["id"] as? String}) {
                row["action"] = "reuse";row["link_id"] = link["id"];row["task_id"] = link["task_id"]
            } else { row["action"] = "create" }
            return row
        }
        return ["round_id":round["id"]!,"expected_revision":round["revision"]!,"observed_context_token":try mediaToken(db,round:round,caller:c),
            "manifest_id":manifest["id"]!,"manifest_digest":manifest["digest"]!,"epic_id":epicID,"items":rows,
            "preview_digest":try mediaReworkPreviewDigest(round:round,manifest:manifest,epicID:epicID,entries:entries),
            "readiness":"draft","assignment":NSNull()]
    }

    /// Ordinary ticket capture and exact links commit together under the writer. No media
    /// decision, round, sibling item, assignee, readiness, Triage or model state changes.
    func mediaReworkCreate(_ db: Database,_ p: JSON,_ c: Caller,project pid: String) throws -> JSON {
        try owner(c)
        let round = try scoped(db,try text(p,"round_id"),pid,type:"media_round")
        guard round["state"] as? String == "open" else { throw CoreError("MEDIA_ROUND_CLOSED","Rework is created from an Open review record.") }
        try mediaObserve(db,p,round:round,caller:c)
        let manifest = try mediaObservedManifest(db,p,round:round)
        let epicID = try mediaReworkEpic(db,p,project:pid)
        let entries = try mediaReworkSelection(db,p,round:round,manifest:manifest,project:pid,exact:true)
        guard p["preview_digest"] as? String == (try mediaReworkPreviewDigest(round:round,manifest:manifest,epicID:epicID,entries:entries)) else {
            throw CoreError("MEDIA_REWORK_PREVIEW_CHANGED","Preview the exact rework tickets again before creating them.")
        }
        let existing = try mediaReworkLinks(db,round:round)
        var links: [JSON] = [],created: [String] = [],reused: [String] = []
        for e in entries {
            let decisionID = try StoredRecord(e.decision, family: "media").string("id")
            if let link = existing.first(where:{EnvelopeStorageIdentity.equal($0["decision_id"] as? String,decisionID)}) {
                links.append(link);reused.append(try StoredRecord(link, family: "media").string("id"));continue
            }
            var brief = "Changes requested in media review round \u{201C}\(round["title"] as? String ?? "")\u{201D} for \u{201C}\(e.title.dropFirst(8))\u{201D}."
            if let note = e.decision["note"] as? String { brief += "\n\nOwner note: " + note }
            brief += "\n\nLinked to exact owner decision \(decisionID). This ticket's status never changes the media decision or the review record."
            let task = try taskCreate(db,["project_id":pid,"title":e.title,"brief":brief,"epic_id":epicID,"kind":"work"],c)
            let taskID = try StoredRecord(task, family: "task").string("id")
            let link = mediaRecord(["round_id":round["id"]!,"item_id":e.item["id"]!,"decision_id":decisionID,
                "target_id":e.member["target_id"]!,"review_basis_signature":e.member["review_basis_signature"]!,
                "manifest_id":manifest["id"]!,"task_id":taskID,"task_key":task["key"] ?? NSNull(),"epic_id":epicID,"state":"linked"],
                project:pid,caller:c,references:[try mediaRef("media_round",round),try mediaRef("media_item",e.item),
                ["type":"media_owner_decision","id":decisionID,"revision":e.decision["revision"]!],
                ["type":"media_item_target","id":e.member["target_id"]!,"revision":1],
                ["type":"media_round_manifest","id":manifest["id"]!,"revision":manifest["revision"]!],
                ["type":"task","id":taskID]])
            try mediaWrite(db,link,type:"media_rework_link")
            links.append(link);created.append(taskID)
        }
        // Writer-side check: every dependency of each new link resolves in this project at
        // its exact recorded revision (the referenced records keep their own validated chains).
        for link in links where !reused.contains((link["id"] as? String) ?? "") {
            for reference in try StoredRecord(link, family: "media").objects("record_references") {
                let target = try scoped(db,try StoredRecord(reference, family: "media").string("id"),pid,type:try StoredRecord(reference, family: "media").string("type"))
                if let revision = reference["revision"] as? Int,target["revision"] as? Int != revision {
                    throw CoreError("MEDIA_CAPTURE_INCOMPLETE","A required same-project media record or exact revision is unavailable.")
                }
            }
        }
        return ["id":round["id"]!,"links":links,"created_task_ids":created,"reused_link_ids":reused]
    }

    /// Direct writer path: ordinary ticket capture cannot run in the media-only preparation
    /// workspace. Selection is bounded to 200 small records; no media bytes are read.
    func mediaReworkCreateCommand(params p: JSON,caller c: Caller,command: String,digest: String) throws -> JSON {
        try ArchiveStorageGate.withExclusive(root:root) { _ in
            try dbQueue.writeWithoutTransaction { db in
                var result: JSON = [:]
                try self.withValidatedDomainTransaction(db) {
                    let pid = try self.mediaAccess(db,p,c,write:true)
                    try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:c)
                    if let row = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[c.principal,command]) {
                        guard row["digest"] as String == digest else { throw CoreError("IDEMPOTENCY_CONFLICT","This command ID has a different intent.") }
                        result = jsonObject(row["result"])
                        if Self.isPrunedResult(result) { throw Self.expiredCommandError(command) }
                        result["replayed"] = true;return .commit
                    }
                    result = try self.mediaReworkCreate(db,p,c,project:pid)
                    try self.event(db,caller:c,project:pid,entity:result["id"] as? String,kind:"media_rework_create")
                    try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[c.principal,command,digest,try jsonString(result)])
                    return .commit
                };return result
            }
        }
    }

    /// Closure: every published item needs a current explicit final disposition; Changes
    /// requested needs an exact link for its CURRENT decision or an owner no-follow-up reason.
    func mediaClosure(_ db: Database,round: JSON,manifest: JSON,caller: Caller) throws -> (JSON,[JSON]) {
        let rows = try StoredRecord(mediaRoundView(db,round:round,caller:caller), family: "media_round_view").objects("items")
        let members = Set(try (try StoredRecord(manifest, family: "media_round_manifest").objects("items")).map { try StoredRecord($0, family: "media").string("item_id") })
        let links = try mediaReworkLinks(db,round:round),pid = try StoredRecord(round, family: "media").string("project_id")
        var counts = ["accepted":0,"excluded":0,"changes_requested":0,"rework_linked":0,"no_follow_up":0],used: [JSON] = []
        for row in rows where members.contains(try StoredRecord(row, family: "media").string("id")) {
            let disposition = try StoredRecord(row, family: "media").string("disposition")
            guard ["accepted","excluded","changes_requested"].contains(disposition) else { throw CoreError("MEDIA_UNRESOLVED","Every published item needs a current explicit final disposition.") }
            counts[disposition, default:0] += 1
            guard disposition == "changes_requested" else { continue }
            let decision = row["decision"] as? JSON ?? [:]
            if let link = links.first(where:{EnvelopeStorageIdentity.equal($0["decision_id"] as? String,decision["id"] as? String)}),
               (try? scoped(db,(try StoredRecord(link, family: "media").string("task_id")),pid,type:"task")) != nil {
                counts["rework_linked", default:0] += 1;used.append(link)
            } else if let reason = decision["no_follow_up_reason"] as? String,!reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                counts["no_follow_up", default:0] += 1
            } else { throw CoreError("MEDIA_UNRESOLVED","Rework needs a link or explicit owner no-follow-up reason.") }
        }
        let closure: JSON = ["manifest_id":manifest["id"]!,"manifest_digest":manifest["digest"]!,"closed_at":now(),
            "counts":counts,"rework_link_ids":used.map { $0["id"]! }]
        return (closure,used)
    }

    /// Explicit owner successor of an Open/Closed review record. Only included items are
    /// copied as Draft targets of exact retained candidates. A carry names the source item's
    /// current applicable decision; it applies only to an identical complete basis.
    func mediaSuccessorRound(_ db: Database,_ p: JSON,_ c: Caller,project pid: String) throws -> JSON {
        try owner(c)
        let source = try scoped(db,try text(p,"source_round_id"),pid,type:"media_round")
        var observed = p;observed["round_id"] = source["id"]
        try mediaObserve(db,observed,round:source,caller:c)
        guard ["open","closed"].contains(source["state"] as? String ?? ""),let manifestID = source["manifest_id"] as? String,
              manifestID == p["manifest_id"] as? String else { throw CoreError("MEDIA_MANIFEST_CHANGED","Inspect the current published review record.") }
        let manifest = try scoped(db,manifestID,pid,type:"media_round_manifest")
        guard manifest["digest"] as? String == p["manifest_digest"] as? String else { throw CoreError("MEDIA_MANIFEST_CHANGED","The observed manifest digest changed.") }
        guard let selected = p["items"] as? [JSON],!selected.isEmpty else { throw CoreError("INVALID_INPUT","Include one or more exact items.") }
        var plan: [(item: JSON,target: JSON,carry: JSON?)] = [],seen = Set<String>()
        // Validate the whole explicit inclusion before writing any successor record.
        for entry in selected {
            guard Set(entry.keys).isSubset(of:["item_id","carry_decision_id"]),entry["item_id"] is String else { throw CoreError("INVALID_INPUT","Include exact item IDs and optional carry_decision_id.") }
            let item = try scoped(db,try text(entry,"item_id"),pid,type:"media_item")
            guard seen.insert(try StoredRecord(item, family: "media").string("id")).inserted else { throw CoreError("INVALID_INPUT","Include distinct items.") }
            guard EnvelopeStorageIdentity.equal(item["round_id"] as? String,source["id"] as? String),
                  let member = (try StoredRecord(manifest, family: "media").objects("items")).first(where:{EnvelopeStorageIdentity.equal($0["item_id"] as? String,item["id"] as? String)}) else {
                throw CoreError("MEDIA_BASIS_CHANGED","Only published items of the source record can be included.")
            }
            let target = try scoped(db,(try StoredRecord(member, family: "media").string("target_id")),pid,type:"media_item_target")
            var carry: JSON?
            if let raw = entry["carry_decision_id"] {
                guard let id = raw as? String,EnvelopeStorageIdentity.equal(item["last_decision_id"] as? String,id) else { throw CoreError("MEDIA_BASIS_CHANGED","A carry names the item's exact current owner decision.") }
                let decision = try scoped(db,id,pid,type:"media_owner_decision")
                guard decision["review_basis_signature"] as? String == member["review_basis_signature"] as? String else { throw CoreError("MEDIA_BASIS_CHANGED","A stale source decision cannot be carried.") }
                carry = decision
            }
            plan.append((item,target,carry))
        }
        let type = try scoped(db,(try StoredRecord(source, family: "media").string("type_id")),pid,type:"media_review_type")
        guard type["state"] as? String != "retired" else { throw CoreError("MEDIA_TYPE_RETIRED","Restore a review type before adding a round.") }
        let typeRevision = try scoped(db,type["adopted_revision_id"] as? String ?? (try StoredRecord(type, family: "media").string("draft_revision_id")),pid,type:"media_review_type_revision")
        var round = mediaRecord(["type_id":type["id"]!,"title":try text(p,"title",max:2000),"state":"draft",
            "type_revision_id":typeRevision["id"]!,"attention_ids":[String](),"predecessor_round_id":source["id"]!,
            "predecessor_manifest_id":manifest["id"]!],project:pid,caller:c,
            references:[try mediaRef("media_review_type",type),try mediaRef("media_review_type_revision",typeRevision),
                        try mediaRef("media_round",source),try mediaRef("media_round_manifest",manifest)])
        let sources = try mediaCurrentSources(db,project:pid,type:(try StoredRecord(type, family: "media").string("id")),round:(try StoredRecord(round, family: "media").string("id")))
        let context = try mediaSnapshot(db,round:round,typeRevision:typeRevision,sources:sources,caller:c)
        round["context_id"] = context["id"];round["record_references"] = (try StoredRecord(round, family: "media").objects("record_references")) + [try mediaRef("media_review_context",context)]
        try mediaWrite(db,round,type:"media_round")
        var outcomes: [JSON] = []
        for (old,sourceTarget,carry) in plan {
            var item = mediaRecord(["round_id":round["id"]!,"state":"draft","title":sourceTarget["title"] ?? "",
                "predecessor_item_id":old["id"]!,"predecessor_target_id":sourceTarget["id"]!],project:pid,caller:c,
                references:[try mediaRef("media_round",round),try mediaRef("media_item",old)])
            let candidates = try strings(sourceTarget,"candidate_ids").map { try scoped(db,$0,pid,type:"media_candidate") }
            var shape = try mediaTargetShape(db,item:item,title:(try StoredRecord(sourceTarget, family: "media").string("title")),
                metadata:(try StoredRecord(sourceTarget, family: "media").object("metadata")),candidates:candidates,
                typeRevision:typeRevision,context:context,tolerateHistorical:true,materialReferences:sourceTarget["material_references"] as? [JSON] ?? [])
            for key in ["attachment_owner_id","attachment_reference_ids"] { shape[key] = sourceTarget[key] }
            let target = try mediaTarget(db,item:item,shape:shape,caller:c,previous:sourceTarget)
            item["draft_target_id"] = target["id"];item["record_references"] = (try StoredRecord(item, family: "media").objects("record_references")) + [try mediaRef("media_item_target",target)]
            var outcome: JSON = ["source_item_id":old["id"]!,"item_id":item["id"]!,"target_id":target["id"]!,"carried":false]
            if let carry {
                if carry["review_basis_signature"] as? String == target["review_basis_signature"] as? String {
                    var fields: JSON = ["round_id":round["id"]!,"item_id":item["id"]!,"target_id":target["id"]!,
                        "type_revision_id":target["type_revision_id"]!,"context_id":context["id"]!,
                        "carried_from_decision_id":carry["id"]!,"carried_from_round_id":source["id"]!,"carried_from_manifest_id":manifest["id"]!,
                        "carry":"explicit_owner_inclusion","item_revision":item["revision"]!]
                    for key in ["context_signature","content_signature","material_definition_signature","candidate_ids","review_basis_signature","review_basis_base64"] { fields[key] = target[key] }
                    for key in ["disposition","winner_id","none_fit","not_selected_candidate_ids","selection_outcome","note","no_follow_up_reason"] where carry[key] != nil { fields[key] = carry[key] }
                    var refs = [try mediaRef("media_round",round),try mediaRef("media_item",item),try mediaRef("media_item_target",target),
                        try mediaRef("media_review_context",context),try mediaRef("media_review_type_revision",typeRevision),
                        try mediaRef("media_owner_decision",carry),try mediaRef("media_round",source),try mediaRef("media_round_manifest",manifest)]
                    refs += strings(target,"candidate_ids").map { ["type":"media_candidate","id":$0,"revision":1] }
                    let decision = mediaRecord(fields,project:pid,caller:c,references:refs)
                    try mediaWrite(db,decision,type:"media_owner_decision")
                    item["last_decision_id"] = decision["id"];item["record_references"] = (try StoredRecord(item, family: "media").objects("record_references")) + [try mediaRef("media_owner_decision",decision)]
                    outcome["carried"] = true;outcome["decision_id"] = decision["id"]
                } else {
                    // Changed material/context: the predecessor stays history and the item is Stale.
                    item["stale_predecessor_decision_id"] = carry["id"]
                    item["record_references"] = (try StoredRecord(item, family: "media").objects("record_references")) + [try mediaRef("media_owner_decision",carry)]
                    outcome["reason"] = "basis_changed"
                }
            }
            try mediaWrite(db,item,type:"media_item");outcomes.append(outcome)
        }
        var result = try mediaRoundView(db,round:round,caller:c);result["successor"] = ["source_round_id":source["id"]!,"items":outcomes];return result
    }
}
