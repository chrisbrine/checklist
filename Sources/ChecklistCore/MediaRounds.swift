import ChecklistContracts
import Foundation
import CryptoKit
import GRDB

extension CommandRouter {
    /// Internal domain seam; CL-116 exposes only its explicit native-owner allowlist.
    /// Capture/holds are composed internally; public activation still needs the complete
    /// owner UI/rendering/query/rework slice and its native qualification.
    func executeMediaCommand(method: String,params p: JSON,caller c: Caller,nativeOwnerProjection: Bool = false) throws -> JSON {
        do {
            return try executeValidatedMediaCommand(method:method,params:p,caller:c,nativeOwnerProjection:nativeOwnerProjection)
        } catch let error as MediaSchemaError {
            // Portable schema helpers have no transport error codes. Translate at
            // the command boundary, including resource and canonical preparation.
            throw CoreError("INVALID_INPUT","Invalid media input: " + error.description)
        }
    }
    private static let mediaCommandFields: [String:Set<String>] = [
        "media_item_page":["round_id","list","filter","limit","cursor"],
        "media_item_counts":["round_id","list","filter","limit","cursor"],
        "media_approved_examples":["round_id","item_id","examples","expanded","cursor"],
        "media_example_read_lease":["round_id","target_id","decision_id","reference_id","seconds"],
        "media_example_read_release":["lease_id"],
        "media_material_reference_adopt":["round_id","expected_revision","observed_context_token",
            "manifest_id","manifest_digest","item_id","expected_item_revision","reference_target_id",
            "reference_decision_id","reference_slot_id","slot_id"],
        "media_bulk_prepare":["round_id","expected_revision","observed_context_token",
            "manifest_id","manifest_digest","items","disposition","winner_id","none_fit",
            "note","no_follow_up_reason","supersedes_operation_id"],
        "media_bulk_get":["operation_id"],
        "media_bulk_apply":["operation_id","chunk_id"],
        "media_intake_preview":["round_id","sources","text","tsv","mapping"],
        "media_intake_get":["intake_id"],
        "media_intake_revise":["intake_id","expected_revision","mapping","resolutions"],
        "media_intake_confirm":["intake_id","expected_revision","plan_id","plan_digest"],
        "media_intake_capture":["intake_id","expected_revision","plan_id","row_ids"],
        "media_type_retire":["type_id","expected_revision"],
        "media_round_cancel":["round_id","expected_revision","reason"],
        "media_round_archive":["round_id","expected_revision"],
        "media_type_create":["title","schema","rubric"], "media_type_get":["type_id"],
        "media_type_revise":["type_id","expected_revision","schema","rubric","title"],
        "media_type_adopt":["type_id","expected_revision","type_revision_id","observed_type_token"],
        "media_round_create":["type_id","title"], "media_round_get":["round_id"],
        "media_item_create":["round_id","title","metadata","candidates"],
        "media_item_update":["item_id","expected_revision","title","metadata","candidates"],
        "media_round_publish":["round_id","expected_revision","observed_context_token","items"],
        "media_context_approve":["kind","body","type_id","round_id","item_ids","supersedes_id","expected_project_revision"],
        "media_context_reconcile":["round_id","expected_revision","observed_context_token","action","reason","attention_ids"],
        "media_suggest":["round_id","expected_revision","observed_context_token","manifest_id","manifest_digest","items","disposition","winner_id","none_fit","note","no_follow_up_reason"],
        "media_decide":["round_id","expected_revision","observed_context_token","manifest_id","manifest_digest","items","disposition","winner_id","none_fit","note","no_follow_up_reason"],
        "media_adopt_suggestion":["round_id","expected_revision","observed_context_token","manifest_id","manifest_digest","items","suggestion_id"],
        "media_round_finish":["round_id","expected_revision","observed_context_token","manifest_id","manifest_digest"],
        "media_rework_preview":["round_id","epic_id","items"],
        "media_rework_create":["round_id","expected_revision","observed_context_token","manifest_id","manifest_digest","epic_id","items","preview_digest"],
        "media_round_successor":["source_round_id","expected_revision","observed_context_token","manifest_id","manifest_digest","title","items"]
        ]

    private func executeValidatedMediaCommand(method: String,params p: JSON,caller c: Caller,nativeOwnerProjection: Bool) throws -> JSON {
        let reads = CommandMethods.mediaInternalReads
        guard let fields = Self.mediaCommandFields[method],Set(p.keys).isSubset(of:fields.union(["command_id",
            "project_id"])) else { throw CoreError("INVALID_INPUT","Unknown internal media command or fields.") }
        guard let data = try? JSONSerialization.data(withJSONObject:p),data.count <= 2_000_000 else { throw CoreError("INVALID_INPUT","Media command exceeds its input bound.") }
        let lease = try storageAdmission.acquire();defer {lease.finish()}
        if method == "media_example_read_lease" || method == "media_example_read_release" {return try mediaExampleLease(method:method,p:p,c:c)}
        if method == "media_rework_preview" {return try dbQueue.read { db in try self.mediaReworkPreview(db,p,c,project:self.mediaAccess(db,p,c)) }}
        if reads.contains(method) {
            return try dbQueue.read { db in
                let pid = try self.mediaAccess(db,p,c)
                if method == "media_item_page" || method == "media_item_counts" {return try self.mediaListQuery(db,method:method,p:p,c:c,project:pid)}
                if method == "media_approved_examples" {return try self.mediaExampleQuery(db,p:p,c:c,project:pid)}
                if method == "media_bulk_get" { return try self.mediaBulkView(db,operation:self.scoped(db,try text(p,"operation_id"),pid,type:"media_bulk_operation")) }
                if method == "media_intake_get" { return try self.mediaIntakeView(db,intake:self.scoped(db,try text(p,"intake_id"),pid,type:"media_intake")) }
                if method == "media_type_get" {
                    let type = try self.scoped(db,try text(p,"type_id"),pid,type:"media_review_type")
                    return try self.mediaTypeView(db,type:type,caller:c)
                }
                return try self.mediaRoundView(db,round:self.scoped(db,try text(p,"round_id"),pid,type:"media_round"),caller:c)
            }
        }
        let command = try text(p,"command_id",max:100)
        guard UUID(uuidString:command) != nil else { throw CoreError("INVALID_INPUT","command_id must be a UUID.") }
        let digest = hash(Data((method + (try jsonString(p))).utf8))
        // Rework capture writes ordinary tickets, which the media-only preparation cannot hold.
        if method == "media_rework_create" {return try mediaReworkCreateCommand(params:p,caller:c,command:command,digest:digest)}
        var resources = try prepareMediaResources(method:method,params:p,caller:c)
        resources.nativeOwnerProjection = nativeOwnerProjection
        let prepared = try prepareMediaCommand(method:method,params:p,caller:c,resources:resources)
        defer { try? prepared?.observer.close() }
        return try ArchiveStorageGate.withExclusive(root:root) { _ in
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
                    guard let prepared,EnvelopeStorageIdentity.equal(prepared.project,pid) else { throw CoreError("MEDIA_CONTEXT_CHANGED","The media command changed during preparation. Retry with current context.") }
                    try prepared.commit(db,router:self,caller:c)
                    result = prepared.result
                    try self.event(db,caller:c,project:pid,entity:result["id"] as? String,kind:method)
                    try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[c.principal,command,digest,prepared.encodedResult])
                    return .commit
                };return result
            }
        }
    }

    func mediaTypeToken(_ db: Database,type: JSON,caller: Caller) throws -> String {
        let state: JSON = ["domain":"media-type-observation-v1","type":type,"sources":try mediaContextSources(db,
            project:(try StoredRecord(type, family: "media").string("project_id"))).map {(try StoredRecord($0,
             family: "media").requiredValue("id"))},"principal":caller.principal,"scope":try authorizationScope(db,
            caller),"generation":try callerSessionGeneration(db,caller,project:(try StoredRecord(type,
             family: "media").string("project_id"))),"incarnation":incarnation]
        return "mt1." + Data(HMAC<SHA256>.authenticationCode(for:try MediaCanonical.bytes(state),using:cursorKey)).base64EncodedString()
    }
    func mediaTypeView(_ db: Database,type: JSON,caller: Caller) throws -> JSON {
        var r = type;r["observed_type_token"] = try mediaTypeToken(db,type:type,caller:caller)
        r["draft_revision"] = try scoped(db,(try StoredRecord(type, family: "media").string("draft_revision_id")),
            (try StoredRecord(type, family: "media").string("project_id")),type:"media_review_type_revision")
        return r
    }
    /// CL-307: one pass over a manifest's members keyed by item ID. The first entry per key
    /// wins, as `first(where:)` did, so per-item member lookups stay linear in the round size.
    func mediaManifestMembers<Key: Hashable>(_ entries: [JSON],key: (String) -> Key) -> [Key:JSON] {
        var members: [Key:JSON] = [:]
        for entry in entries {
            if let id = entry["item_id"] as? String,members[key(id)] == nil {members[key(id)] = entry}
        }
        return members
    }
    func mediaItems(_ db: Database,round: JSON) throws -> [JSON] {
        // Filter in SQL before decoding; one round, never a whole-project item scan (no item ceiling, CL-307).
        let rows = try Row.fetchAll(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='media_item' AND project_id=CAST(? AS TEXT)"
            + " AND json_extract(data,'$.round_id')=CAST(? AS TEXT) COLLATE BINARY ORDER BY id COLLATE BINARY",
            arguments:[Data(((try StoredRecord(round, family: "media").string("project_id"))).utf8),
            Data(((try StoredRecord(round, family: "media").string("id"))).utf8)])
        return try rows.map { try GRDBRecordEnvelopeAdapter.decode($0,expectedType:"media_item").object }
    }
    func mediaTypeRevision(_ db: Database,type: JSON,input: JSON,caller: Caller) throws -> JSON {
        guard input["schema"] == nil || input["schema"] is JSON else { throw CoreError("INVALID_INPUT","A schema must be an object.") }
        let project = try StoredRecord(type, family: "media_review_type").string("project_id")
        let previous = (type["draft_revision_id"] as? String).flatMap {
            try? scoped(db,$0,project,type:"media_review_type_revision")
        }
        let name = try input["title"] as? String ?? (try StoredRecord(type, family: "media").string("title"))
        var definition: JSON = try input["schema"] as? JSON ?? previous?["schema"] as? JSON ?? ["schema_version":1,"id":(try StoredRecord(type, family: "media").requiredValue("id")),"name":name]
        if input["title"] != nil {definition["name"] = name}
        let schema = try MediaReviewSchema.parse(definition)
        guard schema.id.rawValue == type["id"] as? String else { throw CoreError("INVALID_INPUT","A type revision must keep its stable type ID.") }
        let rubric = input["rubric"] != nil ? try text(input,"rubric",max:16000,required:false) : previous?["rubric"] as? String ?? ""
        let revision = try mediaRecord(["type_id":(try StoredRecord(type, family: "media").requiredValue("id")),
            "schema":definition,"rubric":rubric,"definition_signature":try MediaCanonical.signature(["schema":definition,
            "rubric":rubric])],project:(try StoredRecord(type, family: "media").string("project_id")),
            caller:caller,references:[try mediaRef("media_review_type",type)] + (previous.map {[try mediaRef("media_review_type_revision",
            $0)]} ?? []))
        try mediaWrite(db,revision,type:"media_review_type_revision");return revision
    }
    func mediaRoundParts(_ db: Database,_ round: JSON) throws -> (JSON,JSON) {
        let pid = (try StoredRecord(round, family: "media").string("project_id"))
        return (try scoped(db,(try StoredRecord(round, family: "media").string("type_revision_id")),
            pid,type:"media_review_type_revision"),try scoped(db,(try StoredRecord(round, family: "media").string("context_id")),
            pid,type:"media_review_context"))
    }
    /// Direct item input accepts inline text or retained candidates. Managed candidates
    /// enter only through frozen intake; arbitrary paths/digests/IDs cannot bypass capture.
    func mediaCandidates(_ db: Database,input: Any?,item: JSON,schema: MediaReviewSchema,caller: Caller) throws -> [JSON] {
        guard let raw = input as? [JSON] ?? (input == nil ? [] : nil),raw.count <= schema.maxCandidates else { throw CoreError("INVALID_INPUT","Use at most the declared number of candidates.") }
        var result: [JSON] = [],seen = Set<String>()
        for value in raw {
            guard Set(value.keys).isSubset(of:["candidate_id","slots"]) else { throw CoreError("INVALID_INPUT","Unknown candidate fields; file capture is not composed yet.") }
            if let id = value["candidate_id"] as? String {
                guard value.count == 1,seen.insert(id).inserted else { throw CoreError("INVALID_INPUT","Retain a distinct exact candidate ID without replacing its content.") }
                let old = try scoped(db,id,(try StoredRecord(item, family: "media").string("project_id")),type:"media_candidate")
                guard old["item_id"] as? String == item["id"] as? String else { throw CoreError("FORBIDDEN","A candidate belongs to its own item.") };result.append(old);continue
            }
            guard let slots = value["slots"] as? [JSON],!slots.isEmpty,slots.count <= 8 else { throw CoreError("INVALID_INPUT","A text candidate needs bounded captured slots.") }
            var content: [JSON] = [],slotIDs = Set<MediaReviewID>()
            for slot in slots {
                guard Set(slot.keys) == Set(["slot_id","text"]) else { throw CoreError("MEDIA_CAPTURE_REQUIRED","Only exact inline text is supported before managed capture is composed.") }
                let id = try MediaReviewID(text(slot,"slot_id",max:256))
                guard slotIDs.insert(id).inserted,schema.slots.contains(where:{$0.id == id && $0.kind == .text}) else { throw CoreError("INVALID_INPUT","The candidate needs distinct compatible text slots.") }
                guard let captured = slot["text"] as? String,captured.utf8.count <= 256 * 1024 else {
                    throw CoreError("INVALID_INPUT","Captured text must be an exact UTF-8 string of at most 256 KiB.")
                }
                content.append(["slot_id":id.rawValue,"text":captured,"sha256":hash(Data(captured.utf8)),"encoding":"utf-8-exact-v1"])
            }
            try content.sort { Data(((try StoredRecord($0, family: "media").string("slot_id"))).utf8).lexicographicallyPrecedes(Data(((try StoredRecord($1,
                 family: "media").string("slot_id"))).utf8)) }
            let candidate = mediaRecord(["item_id":(try StoredRecord(item, family: "media").requiredValue("id")),
                "slots":content,"content_signature":try MediaCanonical.signature(content)],
                project:(try StoredRecord(item, family: "media").string("project_id")),caller:caller,
                references:[try mediaRef("media_item",item)])
            try mediaWrite(db,candidate,type:"media_candidate");result.append(candidate);seen.insert((try StoredRecord(candidate, family: "media").string("id")))
        };return try result.sorted { ((try StoredRecord($0, family: "media").string("id"))) < ((try StoredRecord($1, family: "media").string("id"))) }
    }
    func mediaTargetShape(_ db: Database,item: JSON,title: String,metadata: JSON,candidates: [JSON],typeRevision: JSON,context: JSON,tolerateHistorical: Bool = false,materialReferences: [JSON] = []) throws -> JSON {
        let schema = try MediaReviewSchema.parse((try StoredRecord(typeRevision, family: "media").object("schema")))
        guard (try jsonString(metadata)).utf8.count <= 32768 else { throw CoreError("INVALID_INPUT","Item metadata exceeds 32 KiB.") }
        var used = Set<MediaReviewID>(),material: JSON = [:],present = Set<MediaReviewID>()
        var valid = true
        for (key,value) in metadata {
            let id = try MediaReviewID(key)
            do { _ = try schema.validateValue(value,fieldID:id) }
            catch { if !tolerateHistorical { throw error };valid = false }
            if let field = schema.fields.first(where:{$0.id == id}) { used.insert(id);if field.material { material[key] = value } }
            else { material[key] = value }
        }
        var ready = valid && !candidates.isEmpty && candidates.count <= schema.maxCandidates
        let requiredSlots = Set(schema.slots.filter {$0.required}.map(\.id))
        for c in candidates {
            let slots = (try StoredRecord(c, family: "media").objects("slots"));var candidateSlots = Set<MediaReviewID>()
            for slot in slots {
                let id = try MediaReviewID((try StoredRecord(slot, family: "media").string("slot_id")))
                if schema.slots.contains(where:{$0.id == id && ($0.kind == .text ? slot["text"] is String : slot["media_kind"] as? String == $0.kind.rawValue && slot["attachment_id"] is String)}) { present.insert(id);candidateSlots.insert(id) }
                else { if !tolerateHistorical { throw CoreError("INVALID_INPUT","A candidate slot is incompatible with this type revision.") };ready = false }
            }
            if !requiredSlots.isSubset(of:candidateSlots) { ready = false }
            if let primary = schema.layout.primarySlotID,!candidateSlots.contains(primary) { ready = false }
        }
        for field in schema.fields where field.required { if !used.contains(field.id) { ready = false } }
        for reference in materialReferences {
            let id = try MediaReviewID((try StoredRecord(reference, family: "media").string("slot_id")))
            if let slot = schema.slots.first(where:{$0.id == id && $0.material}),slot.kind.rawValue == reference["kind"] as? String {present.insert(id)}
            else if tolerateHistorical {ready = false}
            else {throw CoreError("INVALID_INPUT","An adopted material slot is incompatible with this type revision.")}
        }
        let definition = try schema.materialDefinition(usedFieldIDs:used,presentSlotIDs:present)
        let materialSignature = hash(definition)
        // Candidate identity and complete captured content enter the comparison set. A nonmaterial
        // field/label/order is excluded; title is a label, never an instruction.
        var content: JSON = try ["candidate_set":candidates.map {["id":(try StoredRecord($0,
             family: "media").requiredValue("id")),"signature":(try StoredRecord($0, family: "media").requiredValue("content_signature"))]},
            "material_metadata":material]
        if !materialReferences.isEmpty {content["material_references"] = materialReferences}
        let contentBytes = try MediaCanonical.bytes(content),contextSignature = try mediaEffectiveContext(db,context:context,itemID:(try StoredRecord(item, family: "media").string("id")))
        let basis: JSON = ["content_signature":hash(contentBytes),"material_definition_signature":materialSignature,"context_signature":contextSignature,"rubric":typeRevision["rubric"] ?? "","selection_rule":"single-explicit-winner-v1","material_valid":ready]
        return try ["material_references":materialReferences,"item_id":(try StoredRecord(item,
             family: "media").requiredValue("id")),"title":title,"metadata":metadata,"candidate_ids":candidates.map {(try StoredRecord($0,
             family: "media").requiredValue("id"))},"type_revision_id":(try StoredRecord(typeRevision,
             family: "media").requiredValue("id")),"context_id":(try StoredRecord(context, family: "media").requiredValue("id")),
            "content_signature":hash(contentBytes),"content_basis_base64":contentBytes.base64EncodedString(),
            "material_definition_signature":materialSignature,"material_definition_base64":definition.base64EncodedString(),
            "context_signature":contextSignature,"review_basis_signature":try MediaCanonical.signature(basis),
            "review_basis_base64":try MediaCanonical.bytes(basis).base64EncodedString(),"publication_ready":ready]
    }
    func mediaTarget(_ db: Database,item: JSON,shape: JSON,caller: Caller,previous: JSON? = nil) throws -> JSON {
        let pid = (try StoredRecord(item, family: "media").string("project_id"))
        var refs: [JSON] = [try mediaRef("media_item",item),["type":"media_review_type_revision",
            "id":(try StoredRecord(shape, family: "media").requiredValue("type_revision_id")),
            "revision":1],["type":"media_review_context","id":(try StoredRecord(shape, family: "media").requiredValue("context_id")),
            "revision":1]]
        refs += strings(shape,"candidate_ids").map {["type":"media_candidate","id":$0,"revision":1]}
        if let previous { refs.append(try mediaRef("media_item_target",previous)) }
        if let owner = shape["attachment_owner_id"] as? String { refs.append(["type":"storage_job","id":owner]) }
        refs += strings(shape,"attachment_reference_ids").map { ["type":"storage_hold","id":$0] }
        for reference in shape["material_references"] as? [JSON] ?? [] {
            refs += [["type":"media_item_target","id":(try StoredRecord(reference, family: "media").requiredValue("target_id")),
                "revision":1],["type":"media_owner_decision","id":(try StoredRecord(reference,
                 family: "media").requiredValue("decision_id")),"revision":1]]
        }
        let target = mediaRecord(shape,project:pid,caller:caller,references:refs);try mediaWrite(db,target,type:"media_item_target");return target
    }
    func mediaShapeForTarget(_ db: Database,item: JSON,target: JSON,typeRevision: JSON,context: JSON) throws -> JSON {
        let candidates = try strings(target,"candidate_ids").map {try scoped(db,$0,(try StoredRecord(item, family: "media").string("project_id")),type:"media_candidate")}
        var shape = try mediaTargetShape(db,item:item,title:(try StoredRecord(target, family: "media").string("title")),
            metadata:(try StoredRecord(target, family: "media").object("metadata")),candidates:candidates,
            typeRevision:typeRevision,context:context,tolerateHistorical:true,materialReferences:target["material_references"] as? [JSON] ?? [])
        for key in ["attachment_owner_id","attachment_reference_ids"] { shape[key] = target[key] }
        return shape
    }
    /// Historical schema/shape incompatibility remains optional; mandatory stored-field corruption aborts the command.
    func mediaCompatibleShapeForTarget(_ db: Database,item: JSON,target: JSON,typeRevision: JSON,context: JSON) throws -> JSON? {
        do {
            return try mediaShapeForTarget(db,item:item,target:target,typeRevision:typeRevision,context:context)
        } catch let error as CoreError where error.code == "CANONICAL_RECORD_INVALID" {
            throw error
        } catch {
            return nil
        }
    }
    func mediaRoundView(_ db: Database,round: JSON,caller: Caller) throws -> JSON {
        var result = round;let (type,context) = try mediaRoundParts(db,round)
        result["observed_context_token"] = try mediaToken(db,round:round,caller:caller);result["context"] = context
        let manifest = try (round["manifest_id"] as? String).map {try scoped(db,$0,(try StoredRecord(round, family: "media").string("project_id")),type:"media_round_manifest")}
        result["manifest"] = manifest ?? [:]
        let members = mediaManifestMembers(manifest?["items"] as? [JSON] ?? []) {$0}
        result["items"] = try mediaItems(db,round:round).map { item -> JSON in
            var row = item
            let draft = try scoped(db,(try StoredRecord(item, family: "media").string("draft_target_id")),(try StoredRecord(round, family: "media").string("project_id")),type:"media_item_target")
            row["draft_target"] = draft;row["publication_preview"] = try mediaShapeForTarget(db,item:item,target:draft,typeRevision:type,context:context)
            row["disposition"] = "pending"
            if let id = item["id"] as? String,let entry = members[id] {
                row["published_target"] = try scoped(db,(try StoredRecord(entry, family: "media").string("target_id")),
                    (try StoredRecord(round, family: "media").string("project_id")),type:"media_item_target")
                if let id = item["last_decision_id"] as? String {
                    let decision = try scoped(db,id,(try StoredRecord(round, family: "media").string("project_id")),type:"media_owner_decision")
                    let applies = decision["review_basis_signature"] as? String == entry["review_basis_signature"] as? String
                    row["decision"] = decision;row["decision_applicable"] = applies;row["disposition"] = applies ? (try StoredRecord(decision, family: "media").requiredValue("disposition")) : "stale"
                } else if item["stale_predecessor_decision_id"] is String { row["disposition"] = "stale" }
            };return row
        }
        result["rework"] = try mediaReworkSummary(db,round:round)
        result["attention"] = try strings(round,"attention_ids").map {try scoped(db,$0,(try StoredRecord(round, family: "media").string("project_id")),type:"media_context_attention")}
        return result
    }
    func mediaManifest(_ db: Database,round: inout JSON,targets: [(JSON,JSON)],typeRevision: JSON,context: JSON,caller: Caller) throws -> JSON {
        let members: [JSON] = try targets.map {item,target in ["item_id":(try StoredRecord(item,
             family: "media").requiredValue("id")),"target_id":(try StoredRecord(target, family: "media").requiredValue("id")),
            "target_revision":(try StoredRecord(target, family: "media").requiredValue("revision")),
            "review_basis_signature":(try StoredRecord(target, family: "media").requiredValue("review_basis_signature"))]}.sorted {((try StoredRecord($0,
             family: "media").string("item_id"))) < ((try StoredRecord($1, family: "media").string("item_id")))}
        let basis: JSON = ["round_id":(try StoredRecord(round, family: "media").requiredValue("id")),
            "type_revision_id":(try StoredRecord(typeRevision, family: "media").requiredValue("id")),
            "context_id":(try StoredRecord(context, family: "media").requiredValue("id")),"items":members]
        var refs = try [try mediaRef("media_round",round),try mediaRef("media_review_type_revision",
            typeRevision),try mediaRef("media_review_context",context)] + targets.flatMap {[try mediaRef("media_item",
            $0.0),try mediaRef("media_item_target",$0.1)]}
        if let old = round["manifest_id"] as? String { refs.append(["type":"media_round_manifest","id":old,"revision":1]) }
        let manifest = mediaRecord(["round_id":(try StoredRecord(round, family: "media").requiredValue("id")),
            "type_revision_id":(try StoredRecord(typeRevision, family: "media").requiredValue("id")),
            "context_id":(try StoredRecord(context, family: "media").requiredValue("id")),"items":members,
            "digest":try MediaCanonical.signature(basis),"canonical_basis_base64":try MediaCanonical.bytes(basis).base64EncodedString()],
            project:(try StoredRecord(round, family: "media").string("project_id")),caller:caller,
            references:refs)
        try mediaWrite(db,manifest,type:"media_round_manifest");round["manifest_id"] = manifest["id"]
        round["record_references"] = (round["record_references"] as? [JSON] ?? []) + [try mediaRef("media_round_manifest",manifest)];return manifest
    }
    func mediaCommand(_ db: Database,method: String,p: JSON,c: Caller,project pid: String,resources: PreparedMediaResources = .init()) throws -> JSON {
        if method.hasPrefix("media_intake_") { return try mediaIntakeCommand(db,method:method,p:p,c:c,project:pid,resources:resources) }
        if method.hasPrefix("media_bulk_") { return try mediaBulkCommand(db,method:method,p:p,c:c,project:pid) }
        switch method {
        case "media_material_reference_adopt": return try mediaMaterialReferenceAdopt(db,p:p,c:c,project:pid)
        case "media_type_retire":
            try owner(c)
            var type = try scoped(db,try text(p,"type_id"),pid,type:"media_review_type");try mediaRevision(p,type)
            let live = try records(db,type:"media_round",project:pid).contains { EnvelopeStorageIdentity.equal($0["type_id"] as? String,type["id"] as? String) && ["draft","open"].contains($0["state"] as? String ?? "") }
            guard !live else {throw CoreError("MEDIA_ROUNDS_REMAIN","Finish/archive or explicitly cancel every Draft and Open round before retiring this type.")}
            type["enabled"] = false;type["state"] = "retired";type = revised(type);try mediaWrite(db,type,type:"media_review_type");return type
        case "media_round_cancel", "media_round_archive":
            try owner(c)
            var round = try scoped(db,try text(p,"round_id"),pid,type:"media_round");try mediaRevision(p,round)
            if method == "media_round_cancel" {
                guard ["draft","open"].contains(round["state"] as? String ?? "") else {throw CoreError("MEDIA_ROUND_CLOSED","Only a Draft or Open round can be canceled.")}
                round["cancellation_reason"] = try text(p,"reason",max:4000);round["state"] = "canceled"
            } else {
                guard ["closed","canceled"].contains(round["state"] as? String ?? "") else {throw CoreError("MEDIA_ROUNDS_REMAIN","Finish or explicitly cancel this round before archiving.")}
                round["state"] = "archived"
            }
            round = revised(round);try mediaWrite(db,round,type:"media_round");return round
        case "media_type_create":
            let title = try text(p,"title",max:256)
            var type = mediaRecord(["title":title,"state":"draft","enabled":false],project:pid,caller:c)
            // The server owns stable type IDs, including for an optional supplied definition.
            var input = p
            if var schema = p["schema"] as? JSON { schema["id"] = type["id"];input["schema"] = schema }
            let rev = try mediaTypeRevision(db,type:type,input:input,caller:c)
            type["draft_revision_id"] = rev["id"];type["record_references"] = [try mediaRef("media_review_type_revision",rev)]
            try mediaWrite(db,type,type:"media_review_type");return try mediaTypeView(db,type:type,caller:c)
        case "media_type_revise":
            var type = try scoped(db,try text(p,"type_id"),pid,type:"media_review_type");try mediaRevision(p,type)
            if p["title"] != nil { _ = try text(p,"title",max:256) }
            let rev = try mediaTypeRevision(db,type:type,input:p,caller:c)
            type["draft_revision_id"] = rev["id"];type["record_references"] = (type["record_references"] as? [JSON] ?? []) + [try mediaRef("media_review_type_revision",rev)]
            type = revised(type);try mediaWrite(db,type,type:"media_review_type");return try mediaTypeView(db,type:type,caller:c)
        case "media_type_adopt":
            return try mediaAdoptType(db,p,c,project:pid)
        case "media_round_create":
            let type = try scoped(db,try text(p,"type_id"),pid,type:"media_review_type")
            guard type["state"] as? String != "retired" else {throw CoreError("MEDIA_TYPE_RETIRED","Restore a review type before adding a round.")}
            let typeRevision = try scoped(db,type["adopted_revision_id"] as? String ?? (try StoredRecord(type, family: "media").string("draft_revision_id")),pid,type:"media_review_type_revision")
            var round = mediaRecord(["type_id":(try StoredRecord(type, family: "media").requiredValue("id")),
                "title":try text(p,"title",max:2000),"state":"draft","type_revision_id":(try StoredRecord(typeRevision,
                 family: "media").requiredValue("id")),"attention_ids":[String]()],project:pid,
                caller:c,references:[try mediaRef("media_review_type",type),try mediaRef("media_review_type_revision",
                typeRevision)])
            let sources = try mediaCurrentSources(db,project:pid,type:(try StoredRecord(type, family: "media").string("id")),round:(try StoredRecord(round, family: "media").string("id")))
            let context = try mediaSnapshot(db,round:round,typeRevision:typeRevision,sources:sources,caller:c)
            round["context_id"] = context["id"];round["record_references"] = ((try StoredRecord(round, family: "media").objects("record_references"))) + [try mediaRef("media_review_context",context)]
            try mediaWrite(db,round,type:"media_round");return try resources.nativeOwnerProjection ? mediaOwnerHeader(db,round,c) : mediaRoundView(db,round:round,caller:c)
        case "media_item_create","media_item_update":
            return try mediaEditItem(db,p,c,project:pid,method:method)
        case "media_context_approve":
            try owner(c)
            if p["kind"] as? String == "project" {
                let project = try record(db,pid,type:"project")
                try mediaRevision(["expected_revision":p["expected_project_revision"] ?? NSNull()],project)
                return try mediaApproveProjectContext(db,project:project,caller:c)
            };return try mediaApproveInstruction(db,p,c,project:pid)
        case "media_round_publish":
            return try mediaPublishRound(db,p,c,project:pid,resources:resources)
        case "media_context_reconcile": return try mediaReconcile(db,p,c,project:pid)
        case "media_decide","media_suggest","media_adopt_suggestion": return try mediaDecision(db,p,c,project:pid,method:method)
        case "media_round_finish":
            return try mediaFinishRound(db,p,c,project:pid)
        case "media_round_successor":
            return try mediaSuccessorRound(db,p,c,project:pid)
        default: throw CoreError("UNSUPPORTED_METHOD","Internal media command is unavailable.")
        }
    }
    private func mediaAdoptType(_ db: Database,_ p: JSON,_ c: Caller,project pid: String) throws -> JSON {
        try owner(c)
        var type = try scoped(db,try text(p,"type_id"),pid,type:"media_review_type");try mediaRevision(p,type)
        guard type["state"] as? String != "retired" else {throw CoreError("MEDIA_TYPE_RETIRED","A retired type is historical.")}
        guard p["observed_type_token"] as? String == (try mediaTypeToken(db,type:type,
            caller:c)),p["type_revision_id"] as? String == type["draft_revision_id"] as? String else { throw CoreError("MEDIA_CONTEXT_CHANGED",
            "Inspect the exact proposed type and approved project context before adoption.") }
        let revision = try scoped(db,(try StoredRecord(type, family: "media").string("draft_revision_id")),pid,type:"media_review_type_revision")
        if !bool(type,"enabled"),try records(db,type:"media_review_type",project:pid).filter({bool($0,
            "enabled")}).count >= 8 { throw CoreError("CAPACITY_EXCEEDED","A project supports eight enabled media types.") }
        let adoption: JSON = ["type_revision_id":(try StoredRecord(revision, family: "media").requiredValue("id")),"owner":c.principal,"origin":"human_ui","adopted_at":now()]
        type["adopted_revision_id"] = revision["id"];type["title"] = ((try StoredRecord(revision,
             family: "media").object("schema")))["name"];type["adoptions"] = (type["adoptions"] as? [JSON] ?? []) + [adoption];
            type["state"] = "adopted";type["enabled"] = true
        type = revised(type);try mediaWrite(db,type,type:"media_review_type")
        for round in try records(db,type:"media_round",project:pid) where round["type_id"] as? String == type["id"] as? String {
            let (old,context) = try mediaRoundParts(db,round)
            // An adoption can supersede pending type attention even when its effective
            // material returns to the pinned basis. Retain both changes for reconciliation.
            let pendingTypeChange = try strings(round,"attention_ids").contains {
                try scoped(db,$0,pid,type:"media_context_attention")["proposed_type_revision_id"] is String
            }
            guard old["id"] as? String != revision["id"] as? String || pendingTypeChange else { continue }
            var relevant = try old["rubric"] as? String != revision["rubric"] as? String || !((try StoredRecord(type,
                 family: "media").objects("adoptions"))).contains {$0["type_revision_id"] as? String == old["id"] as? String}
            // CL-307: read the manifest once per round, not once per item.
            let members = try (round["manifest_id"] as? String).map {
                mediaManifestMembers(try scoped(db,$0,pid,type:"media_round_manifest")["items"] as? [JSON] ?? []) {$0}
            }
            for item in try mediaItems(db,round:round) {
                var targetIDs = [(try StoredRecord(item, family: "media").string("draft_target_id"))]
                if let id = item["id"] as? String,let member = members?[id] { targetIDs.append((try StoredRecord(member,
                     family: "media").string("target_id"))) }
                for targetID in Set(targetIDs) {
                let target = try scoped(db,targetID,pid,type:"media_item_target")
                let oldShape = try mediaCompatibleShapeForTarget(db,item:item,target:target,typeRevision:old,context:context)
                let newShape = try mediaCompatibleShapeForTarget(db,item:item,target:target,typeRevision:revision,context:context)
                if oldShape == nil || newShape == nil || oldShape?["review_basis_signature"] as? String != newShape?["review_basis_signature"] as? String { relevant = true }
                }
            }
            // Required constraints affect even empty Draft rounds; optional unused additions do not.
            let oldSchema = try MediaReviewSchema.parse((try StoredRecord(old, family: "media").object("schema"))),
                newSchema = try MediaReviewSchema.parse((try StoredRecord(revision, family: "media").object("schema")))
            if try oldSchema.materialDefinition(usedFieldIDs:[],presentSlotIDs:[]) != newSchema.materialDefinition(usedFieldIDs:[],presentSlotIDs:[]) { relevant = true }
            if relevant || pendingTypeChange { try mediaAttention(db,round:round,source:revision,caller:c,proposedType:revision) }
        };return try mediaTypeView(db,type:type,caller:c)
    }

    private func mediaEditItem(_ db: Database,_ p: JSON,_ c: Caller,project pid: String,method: String) throws -> JSON {
        var item: JSON
        let round: JSON
        var previous: JSON?
        if method == "media_item_create" {
            round = try scoped(db,try text(p,"round_id"),pid,type:"media_round")
            item = mediaRecord(["round_id":(try StoredRecord(round, family: "media").requiredValue("id")),
                "state":"draft","title":try text(p,"title",max:2000)],project:pid,caller:c,
                references:[try mediaRef("media_round",round)])
        } else {
            item = try scoped(db,try text(p,"item_id"),pid,type:"media_item");try mediaRevision(p,item)
            round = try scoped(db,(try StoredRecord(item, family: "media").string("round_id")),pid,type:"media_round")
            previous = try scoped(db,(try StoredRecord(item, family: "media").string("draft_target_id")),pid,type:"media_item_target")
            if p["title"] != nil { item["title"] = try text(p,"title",max:2000) };item = revised(item)
        }
        guard ["draft","open"].contains(round["state"] as? String ?? "") else { throw CoreError("MEDIA_ROUND_CLOSED","Closed round content is immutable.") }
        let (type,context) = try mediaRoundParts(db,round),schema = try MediaReviewSchema.parse((try StoredRecord(type, family: "media").object("schema")))
        if p["metadata"] != nil && !(p["metadata"] is JSON) { throw CoreError("INVALID_INPUT","Metadata must be an object.") }
        let metadata = p["metadata"] as? JSON ?? previous?["metadata"] as? JSON ?? [:]
        let candidates: [JSON]
        if p["candidates"] != nil { candidates = try mediaCandidates(db,input:p["candidates"],item:item,schema:schema,caller:c) }
        else { candidates = try strings(previous ?? [:],"candidate_ids").map {try scoped(db,$0,pid,type:"media_candidate")} }
        var shape = try mediaTargetShape(db,item:item,title:(try StoredRecord(item, family: "media").string("title")),
            metadata:metadata,candidates:candidates,typeRevision:type,context:context,materialReferences:previous?["material_references"] as? [JSON] ?? [])
        for key in ["attachment_owner_id","attachment_reference_ids"] { shape[key] = previous?[key] }
        let target = try mediaTarget(db,item:item,shape:shape,caller:c,previous:previous)
        item["draft_target_id"] = target["id"];item["record_references"] = ((try StoredRecord(item, family: "media").objects("record_references"))) + [try mediaRef("media_item_target",target)]
        try mediaWrite(db,item,type:"media_item");var result = item;result["draft_target"] = target;return result
    }

    private func mediaPublishRound(_ db: Database,_ p: JSON,_ c: Caller,project pid: String,resources: PreparedMediaResources) throws -> JSON {
        try owner(c)
        var round = try scoped(db,try text(p,"round_id"),pid,type:"media_round")
        try mediaObserve(db,p,round:round,caller:c)
        guard ["draft","open"].contains(round["state"] as? String ?? "") else { throw CoreError("MEDIA_ROUND_CLOSED","A closed manifest cannot be replaced.") }
        let typeHead = try scoped(db,(try StoredRecord(round, family: "media").string("type_id")),pid,type:"media_review_type")
        guard (typeHead["adoptions"] as? [JSON] ?? []).contains(where:{$0["type_revision_id"] as? String == round["type_revision_id"] as? String}) else { throw CoreError("MEDIA_TYPE_NOT_ADOPTED",
            "The owner must adopt a type before publication.") }
        let (type,context) = try mediaRoundParts(db,round)
        let hasApprovedProjectHistory = try mediaContextSources(db,project:pid).contains {$0["kind"] as? String == "project_approval"}
        let project = try record(db,pid,type:"project")
        let globalPins = (project["pinned_decisions"] as? [JSON] ?? []).filter {$0["origin"] as? String == "human_ui" && strings($0,"task_kinds").isEmpty && strings($0,"tag_ids").isEmpty}
        guard hasApprovedProjectHistory || (project["brief"] as? String ?? "").isEmpty && globalPins.isEmpty else { throw CoreError("MEDIA_PROJECT_CONTEXT_REQUIRED",
            "Explicitly adopt the observed project context before the first publication; historical text cannot mint approval.") }
        guard let selected = p["items"] as? [JSON],!selected.isEmpty,
            Set(selected.compactMap {$0["item_id"] as? String}).count == selected.count else { throw CoreError("INVALID_INPUT",
            "Select one or more distinct exact Draft targets.") }
        var targets: [(JSON,JSON)] = []
        // Validate the entire selection before writing any new target or manifest.
        for entry in selected {
            guard Set(entry.keys) == Set(["item_id","expected_revision","target_id","review_basis_signature"]) else { throw CoreError("INVALID_INPUT",
                "Publication needs exact item revision, Draft target and prospective basis.") }
            let item = try scoped(db,try text(entry,"item_id"),pid,type:"media_item");try mediaRevision(entry,item)
            guard item["round_id"] as? String == round["id"] as? String,item["draft_target_id"] as? String == entry["target_id"] as? String else { throw CoreError("REVISION_CONFLICT",
                "The selected Draft target changed.") }
            let old = try scoped(db,(try StoredRecord(item, family: "media").string("draft_target_id")),pid,type:"media_item_target")
            let shape = try mediaShapeForTarget(db,item:item,target:old,typeRevision:type,context:context)
            guard bool(shape,"publication_ready"),shape["review_basis_signature"] as? String == entry["review_basis_signature"] as? String else { throw CoreError("MEDIA_BASIS_CHANGED",
                "The exact complete target must match the publication preview.") }
            targets.append((item,shape))
        }
        for i in targets.indices {
            var item = targets[i].0
            let old = try scoped(db,(try StoredRecord(item, family: "media").string("draft_target_id")),pid,type:"media_item_target")
            let shape = try mediaPublishOwnership(db,shape:targets[i].1,caller:c,resources:resources)
            let target = try mediaTarget(db,item:item,shape:shape,caller:c,previous:old)
            item["draft_target_id"] = target["id"];item["record_references"] = ((try StoredRecord(item, family: "media").objects("record_references"))) + [try mediaRef("media_item_target",target)]
            item = revised(item);try mediaWrite(db,item,type:"media_item");targets[i] = (item,target)
        }
        _ = try mediaManifest(db,round:&round,targets:targets,typeRevision:type,context:context,caller:c)
        round["state"] = "open";round = revised(round);try mediaWrite(db,round,type:"media_round");
            return try resources.nativeOwnerProjection ? mediaOwnerHeader(db,round,c) : mediaRoundView(db,
            round:round,caller:c)
    }

    private func mediaFinishRound(_ db: Database,_ p: JSON,_ c: Caller,project pid: String) throws -> JSON {
        try owner(c);var round = try scoped(db,try text(p,"round_id"),pid,type:"media_round")
        try mediaObserve(db,p,round:round,caller:c);let manifest = try mediaObservedManifest(db,p,round:round)
        // CL-118: exact current dispositions; rework links and no-follow-up counted separately.
        let (closure,links) = try mediaClosure(db,round:round,manifest:manifest,caller:c)
        round["closure"] = closure
        round["record_references"] = (try StoredRecord(round, family: "media").objects("record_references")) + (try links.map {try mediaRef("media_rework_link",$0)})
        round["state"] = "closed";round = revised(round);try mediaWrite(db,round,type:"media_round");return round
    }

    func mediaObservedManifest(_ db: Database,_ p: JSON,round: JSON) throws -> JSON {
        guard round["state"] as? String == "open",let id = round["manifest_id"] as? String,id == p["manifest_id"] as? String else { throw CoreError("MEDIA_MANIFEST_CHANGED","Inspect the current open manifest.") }
        let m = try scoped(db,id,(try StoredRecord(round, family: "media").string("project_id")),type:"media_round_manifest")
        guard m["digest"] as? String == p["manifest_digest"] as? String else { throw CoreError("MEDIA_MANIFEST_CHANGED","The observed manifest digest changed.") };return m
    }
    func mediaReconcile(_ db: Database,_ p: JSON,_ c: Caller,project pid: String) throws -> JSON {
        try owner(c);var round = try scoped(db,try text(p,"round_id"),pid,type:"media_round")
        try mediaObserve(db,p,round:round,caller:c,allowAttention:true)
        let attentionIDs = strings(round,"attention_ids"),action = try text(p,"action",max:32),reason = try text(p,"reason",max:4000)
        guard !attentionIDs.isEmpty,strings(p,"attention_ids") == attentionIDs,["keep","migrate"].contains(action) else { throw CoreError("MEDIA_CONTEXT_CHANGED","Reconcile the exact pending attention set with keep or migrate and a reason.") }
        let previousManifest = round["manifest_id"] as? String
        let (priorType,priorContext) = try mediaRoundParts(db,round)
        var type = priorType,sources = try strings(priorContext,"source_ids").map {try scoped(db,$0,pid,type:"media_review_context")}
        let attention = try attentionIDs.map {try scoped(db,$0,pid,type:"media_context_attention")}
        if action == "migrate" {
            if attention.contains(where:{$0["proposed_type_revision_id"] is String}) {
                let head = try scoped(db,(try StoredRecord(round, family: "media").string("type_id")),pid,type:"media_review_type")
                type = try scoped(db,(try StoredRecord(head, family: "media").string("adopted_revision_id")),pid,type:"media_review_type_revision")
            }
            for a in attention {
                if a["proposed_type_revision_id"] is String { continue }
                let source = try scoped(db,(try StoredRecord(a, family: "media").string("source_id")),pid,type:"media_review_context")
                sources.removeAll { old in source["kind"] as? String == "project_approval" ? old["kind"] as? String == "project_approval" : old["instruction_id"] as? String == source["instruction_id"] as? String }
                if mediaScopeMatches(source,type:(try StoredRecord(round, family: "media").string("type_id")),round:(try StoredRecord(round, family: "media").string("id"))) { sources.append(source) }
            }
        }
        try sources.sort {((try StoredRecord($0, family: "media").string("id"))) < ((try StoredRecord($1, family: "media").string("id")))}
        let context = try mediaSnapshot(db,round:round,typeRevision:type,sources:sources,caller:c,previous:priorContext)
        var targets: [(JSON,JSON)] = [],affected: [String] = []
        if let id = round["manifest_id"] as? String {
            let manifest = try scoped(db,id,pid,type:"media_round_manifest")
            for member in (try StoredRecord(manifest, family: "media").objects("items")) {
                var item = try scoped(db,(try StoredRecord(member, family: "media").string("item_id")),pid,type:"media_item")
                let old = try scoped(db,(try StoredRecord(member, family: "media").string("target_id")),pid,type:"media_item_target")
                // Invalid values/removal of a used slot refuses migration atomically. Keep or
                // prepare a compatible successor is explicit; no history is coerced or dropped.
                let shape = try mediaShapeForTarget(db,item:item,target:old,typeRevision:type,context:context)
                let target = try mediaTarget(db,item:item,shape:shape,caller:c,previous:old)
                if target["review_basis_signature"] as? String != old["review_basis_signature"] as? String { affected.append((try StoredRecord(item, family: "media").string("id"))) }
                if item["draft_target_id"] as? String == old["id"] as? String { item["draft_target_id"] = target["id"] }
                item["record_references"] = ((try StoredRecord(item, family: "media").objects("record_references"))) + [try mediaRef("media_item_target",target)];item = revised(item)
                try mediaWrite(db,item,type:"media_item");targets.append((item,target))
            }
            _ = try mediaManifest(db,round:&round,targets:targets,typeRevision:type,context:context,caller:c)
        }
        var manifestRefs: [JSON] = []
        for id in [previousManifest,round["manifest_id"] as? String].compactMap({$0}) { manifestRefs.append(["type":"media_round_manifest","id":id,"revision":1]) }
        let receipt = try mediaRecord(["round_id":(try StoredRecord(round, family: "media").requiredValue("id")),
            "previous_manifest_id":previousManifest ?? "","manifest_id":round["manifest_id"] ?? "",
            "action":action,"reason":reason,"attention_ids":attentionIDs,"previous_context_id":(try StoredRecord(priorContext,
             family: "media").requiredValue("id")),"context_id":(try StoredRecord(context, family: "media").requiredValue("id")),
            "type_revision_id":(try StoredRecord(type, family: "media").requiredValue("id")),
            "affected_item_ids":affected],project:pid,caller:c,references:manifestRefs + affected.map {["type":"media_item",
            "id":$0]} + [try mediaRef("media_round",round),try mediaRef("media_review_context",
            priorContext),try mediaRef("media_review_context",context),try mediaRef("media_review_type_revision",
            type)] + attention.map {try mediaRef("media_context_attention",$0)})
        try mediaWrite(db,receipt,type:"media_context_reconciliation")
        for var a in attention { a["state"] = "reconciled";a["reconciliation_id"] = receipt["id"];
            a["record_references"] = ((try StoredRecord(a, family: "media").objects("record_references"))) + [try mediaRef("media_context_reconciliation",
            receipt)];try mediaWrite(db,revised(a),type:"media_context_attention") }
        round["context_id"] = context["id"];round["type_revision_id"] = type["id"];round["attention_ids"] = [String]()
        round["record_references"] = ((try StoredRecord(round, family: "media").objects("record_references"))) + [try mediaRef("media_review_context",
            context),try mediaRef("media_review_type_revision",type),try mediaRef("media_context_reconciliation",
            receipt)]
        round = revised(round);try mediaWrite(db,round,type:"media_round");var result = try mediaRoundView(db,round:round,caller:c);result["reconciliation"] = receipt;return result
    }
}
