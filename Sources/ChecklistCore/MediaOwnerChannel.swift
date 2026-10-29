import ChecklistContracts
import Foundation
import GRDB

/// First native owner slice. Deliberately absent from worker/assistant catalogs.
/// Keep dispatch outside the ordinary writer: capture and hashing prepare first.
extension CommandRouter {
    static let mediaOwnerReads = CommandMethods.mediaOwnerReads
    static let mediaOwnerPoolReads = mediaOwnerReads.subtracting(["media_original_read","media_example_read_lease","media_example_read_release"])
    static let mediaOwnerMethods = mediaOwnerReads.union([
        "media_type_create", "media_type_revise", "media_type_adopt", "media_type_retire", "media_round_create", "media_round_cancel", "media_round_archive", "media_item_create", "media_item_update", "media_round_publish", "media_intake_preview", "media_intake_revise", "media_intake_confirm", "media_intake_capture", "media_context_approve", "media_context_reconcile", "media_decide", "media_example_read_lease", "media_example_read_release", "media_original_read",
        // CL-300: owner screens for CL-118 rework Drafts, round closure and successor rounds.
        "media_rework_create", "media_round_finish", "media_round_successor"
    ])
    func executeMediaOwnerChannel(method: String, params p: JSON, caller c: Caller) throws -> JSON {
        try owner(c)
        guard Self.mediaOwnerMethods.contains(method) else { throw CoreError("UNSUPPORTED_METHOD", "This media capability is not available in the native owner slice.") }
        let projections: [String: Set<String>] = [
            "media_navigation": [], "media_round_page": ["type_id", "state", "offset"],
            "media_round_header": ["round_id"], "media_publication_preview": ["round_id"],
            "media_item_get": ["round_id", "item_id"], "media_original_read": ["round_id", "item_id", "target_id", "reference_id", "representation", "seconds"]
        ]
        if let fields = projections[method] {
            guard Set(p.keys).isSubset(of: fields.union(["project_id"])) else { throw CoreError("INVALID_INPUT", "Unknown media read fields.") }
            let admission = try storageAdmission.acquire(); defer { admission.finish() }
            if method == "media_original_read" { return try mediaOwnerOriginal(p, c) }
            return try readForPreparation { db in
                let project = try self.mediaAccess(db, p, c)
                if method == "media_navigation" {
                    let values = try self.mediaOwnerRecords(db, project: project, family: "media_review_type", predicate: "", arguments: [], limit: 101)
                    guard values.count <= 100 else { throw CoreError("CAPACITY_EXCEEDED", "At most 100 retained type records can be displayed.") }
                    return ["types": values, "enabled": values.filter { bool($0, "enabled") }]
                }
                if method == "media_round_page" {
                    let type = try self.scoped(db, text(p,"type_id"), project, type:"media_review_type")
                    let state = p["state"] as? String ?? "draft"
                    guard ["draft", "open", "closed", "archived", "canceled"].contains(state) else { throw CoreError("INVALID_INPUT", "Choose a round state.") }
                    let offset = try MediaConfigurationValue.integer(p["offset"] ?? 0, max:Int.max, "offset")
                    let values = try self.mediaOwnerRecords(db,project:project,family:"media_round",
                        predicate:" AND json_extract(data,'$.type_id')=? AND json_extract(data,'$.state')=?",
                        arguments:[(try StoredRecord(type, family: "media").string("id")),state],
                        limit:101,offset:offset)
                    return ["rows": Array(values.prefix(100)), "has_more": values.count > 100, "offset":offset]
                }
                let round = try self.scoped(db,text(p,"round_id"),project,type:"media_round")
                if method == "media_round_header" { return try self.mediaOwnerHeader(db,round,c) }
                if method == "media_publication_preview" {
                    let (type,context) = try self.mediaRoundParts(db,round)
                    let items = try self.mediaItems(db,round:round).map { item -> JSON in
                        let target = try self.scoped(db,(try StoredRecord(item, family: "media").string("draft_target_id")),project,type:"media_item_target")
                        let shape = try self.mediaShapeForTarget(db,item:item,target:target,typeRevision:type,context:context)
                        return ["item_id":(try StoredRecord(item, family: "media").requiredValue("id")),
                            "expected_revision":(try StoredRecord(item, family: "media").requiredValue("revision")),
                            "target_id":(try StoredRecord(target, family: "media").requiredValue("id")),
                            "review_basis_signature":(try StoredRecord(shape, family: "media").requiredValue("review_basis_signature")),
                            "publication_ready":(try StoredRecord(shape, family: "media").requiredValue("publication_ready")),
                            "title":(try StoredRecord(target, family: "media").requiredValue("title"))]
                    }
                    return ["round":try self.mediaOwnerHeader(db,round,c),"items":items]
                }
                return try self.mediaOwnerItem(db,round:round,itemID:text(p,"item_id"),caller:c)
            }
        }
        return try executeMediaCommand(method:method,params:p,caller:c,nativeOwnerProjection:true)
    }
    private func mediaOwnerRecords(_ db: Database,project: String,family: String,predicate: String,arguments: StatementArguments,limit: Int,offset: Int = 0) throws -> [JSON] {
        var args: StatementArguments = [project,family]; args += arguments; args += [limit,offset]
        return try Row.fetchAll(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE project_id=? AND type=?" + predicate + " ORDER BY rowid LIMIT ? OFFSET ?",arguments:args).map {try GRDBRecordEnvelopeAdapter.decode($0).object}
    }
    func mediaOwnerHeader(_ db: Database,_ round: JSON,_ caller: Caller) throws -> JSON {
        var result = round
        let (type,context) = try mediaRoundParts(db,round)
        result["type_revision"] = type; result["context"] = context
        result["observed_context_token"] = try mediaToken(db,round:round,caller:caller)
        result["attention"] = try strings(round,"attention_ids").map {try scoped(db,$0,(try StoredRecord(round, family: "media").string("project_id")),type:"media_context_attention")}
        result["context_sources"] = try strings(context,"source_ids").map {try scoped(db,$0,(try StoredRecord(round, family: "media").string("project_id")),type:"media_review_context")}
        result["attention_sources"] = try ((try StoredRecord(result, family: "media").objects("attention"))).map {attention in
            try scoped(db,(try StoredRecord(attention, family: "media").string("source_id")),
                (try StoredRecord(round, family: "media").string("project_id")),type:attention["proposed_type_revision_id"] is String ? "media_review_type_revision" : "media_review_context")
        }
        result["manifest"] = try (round["manifest_id"] as? String).map {try scoped(db,$0,(try StoredRecord(round, family: "media").string("project_id")),type:"media_round_manifest")} ?? [:]
        result["intakes"] = try mediaOwnerRecords(db,project:(try StoredRecord(round, family: "media").string("project_id")),
            family:"media_intake",predicate:" AND json_extract(data,'$.round_id')=?",arguments:[(try StoredRecord(round,
             family: "media").string("id"))],limit:100).map { ["id":(try StoredRecord($0, family: "media").requiredValue("id")),
            "state":(try StoredRecord($0, family: "media").requiredValue("state"))] }
        result["rework"] = try mediaReworkSummary(db,round:round)
        return result
    }
    func mediaOwnerItem(_ db: Database,round: JSON,itemID: String,caller: Caller) throws -> JSON {
        let project = (try StoredRecord(round, family: "media").string("project_id"))
        var item = try scoped(db,itemID,project,type:"media_item")
        guard EnvelopeStorageIdentity.equal(item["round_id"] as? String,round["id"] as? String) else {throw CoreError("NOT_FOUND","This item is unavailable in this round.")}
        let manifest = try (round["manifest_id"] as? String).map {try scoped(db,$0,project,type:"media_round_manifest")}
        let member = (manifest?["items"] as? [JSON] ?? []).first {EnvelopeStorageIdentity.equal($0["item_id"] as? String,itemID)}
        let target = try scoped(db,member?["target_id"] as? String ?? (try StoredRecord(item, family: "media").string("draft_target_id")),project,type:"media_item_target")
        item["published"] = member != nil
        item["target"] = target
        item["candidates"] = try strings(target,"candidate_ids").map {try scoped(db,$0,project,type:"media_candidate")}
        item["suggestions"] = try mediaItemSuggestions(db,project:project,itemID:itemID,target:target)
        item["disposition"] = "pending"
        if let id = item["last_decision_id"] as? String {
            let decision = try scoped(db,id,project,type:"media_owner_decision")
            item["decision"] = decision
            item["disposition"] = decision["review_basis_signature"] as? String == target["review_basis_signature"] as? String ? (try StoredRecord(decision,
                 family: "media").requiredValue("disposition")) : "stale"
        } else if member != nil,item["stale_predecessor_decision_id"] is String {
            // CL-118 successor with a changed basis: same Stale as the round view and item page.
            item["disposition"] = "stale"
        }
        item["originals"] = try strings(target,"attachment_reference_ids").map { id -> JSON in
            let owner = try mediaOwnerValue(db,id:(try StoredRecord(target, family: "media").string("attachment_owner_id")),project:project)
            do {
                let (reference,attachment) = try mediaAttachmentReference(db,project:project,id:id,owner:owner,caller:caller)
                let identity = (attachment["path"] as? String).flatMap {try? self.managedIdentity($0)}
                let available = attachment["availability"] as? String == "available" && identity?.size == Int64(int(attachment,"size"))
                var original: JSON = ["reference_id":(try StoredRecord(reference, family: "media").requiredValue("id")),
                    "attachment_id":(try StoredRecord(attachment, family: "media").requiredValue("id")),
                    "sha256":(try StoredRecord(attachment, family: "media").requiredValue("sha256")),
                    "availability":available ? "available" : "unavailable","size":(try StoredRecord(attachment,
                     family: "media").requiredValue("size")),"name":attachment["name"] ?? "Original"]
                if !available {original["unavailable_reason"] = identity == nil ? "missing" : "changed"}
                return original
            } catch {return ["reference_id":id,"availability":"unavailable","unavailable_reason":mediaOriginalUnavailableReason(db,project:project,referenceID:id)]}
        }
        return item
    }
    private func mediaOwnerOriginal(_ p: JSON,_ c: Caller) throws -> JSON {
        let selected = try dbQueue.read { db -> (String,MediaAttachmentOwner,String) in
            let project = try self.mediaAccess(db,p,c)
            let round = try self.scoped(db,text(p,"round_id"),project,type:"media_round")
            let item = try self.mediaOwnerItem(db,round:round,itemID:text(p,"item_id"),caller:c)
            let target = (try StoredRecord(item, family: "media").object("target"))
            let reference = try text(p,"reference_id")
            guard EnvelopeStorageIdentity.equal(target["id"] as? String,p["target_id"] as? String),strings(target,"attachment_reference_ids").contains(reference) else {throw CoreError("MEDIA_BASIS_CHANGED","Refresh the selected original.")}
            return (project,try self.mediaOwnerValue(db,id:(try StoredRecord(target, family: "media").string("attachment_owner_id")),project:project),reference)
        }
        let representation = p["representation"] as? String ?? "bytes"
        guard ["bytes","lease"].contains(representation) else { throw CoreError("INVALID_INPUT","Choose bytes or lease.") }
        if representation == "lease" {
            // Playback consumers copy and hash the exact original themselves. Each request
            // (load or Open original) is a fresh, short, caller-bound reader lease.
            let seconds = try MediaConfigurationValue.integer(p["seconds"] ?? MediaPlaybackBudget.leaseSeconds,min:1,max:300,"seconds")
            let lease = try acquireMediaAttachmentReadLease(project:selected.0,referenceID:selected.2,owner:selected.1,caller:c,seconds:seconds)
            let a = lease.attachment
            return ["lease_id":lease.id,"expires_at":lease.expiresAt.timeIntervalSince1970,"reference_id":selected.2,"verified_original":false,
                "attachment":["id":a["id"] ?? NSNull(),"path":a["path"] ?? NSNull(),"size":a["size"] ?? NSNull(),"sha256":a["sha256"] ?? NSNull(),"name":a["name"] ?? "Original"]]
        }
        guard p["seconds"] == nil else { throw CoreError("INVALID_INPUT","seconds applies only to a lease.") }
        let bytes = try readMediaAttachment(project:selected.0,referenceID:selected.2,owner:selected.1,caller:c,maximum:8 * 1024 * 1024)
        return ["base64":bytes.base64EncodedString(),"reference_id":selected.2,"verified_original":true]
    }
    /// Honest, non-authorizing reason for an unavailable typed original reference.
    private func mediaOriginalUnavailableReason(_ db: Database,project: String,referenceID: String) -> String {
        guard let hold = try? scoped(db,referenceID,project,type:"storage_hold"),hold["state"] as? String == "active",
              let aid = hold["attachment_id"] as? String,let attachment = try? scoped(db,aid,project,type:"attachment") else {return "reference_unavailable"}
        switch attachment["availability"] as? String {
        case "original_cleaned": return "cleaned"
        case "available": return "changed"
        default: return "missing"
        }
    }
}
