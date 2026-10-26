import Foundation
import CoreFoundation
import CryptoKit
import GRDB

/// Versioned length-prefixed UTF-8; display JSON is never a signature. Finite IEEE-754
/// numbers use POSIX %.17g, with negative zero encoded as zero. Exact text is retained.
enum MediaCanonical {
    static func bytes(_ value: Any) throws -> Data {
        var result = Data()
        func atom(_ s: String) { let b = Data(s.utf8);result.append(contentsOf:String(b.count).utf8);result.append(58);result.append(b) }
        func encode(_ value: Any) throws {
            if value is NSNull { atom("null") }
            else if let s = value as? String { atom("text");atom(s) }
            else if let n = value as? NSNumber {
                if CFGetTypeID(n) == CFBooleanGetTypeID() { atom("bool");atom(n.boolValue ? "1" : "0") }
                else {
                    guard n.doubleValue.isFinite else { throw CoreError("INVALID_INPUT","Media numbers must be finite.") }
                    atom("number");atom(n.doubleValue == 0 ? "0" : String(format:"%.17g",locale:Locale(identifier:"en_US_POSIX"),n.doubleValue))
                }
            } else if let a = value as? [Any] { atom("array");atom(String(a.count));for v in a { try encode(v) } }
            else if let o = value as? JSON {
                atom("object");atom(String(o.count))
                for key in o.keys.sorted(by:{Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8))}) { atom(key);try encode(o[key]!) }
            } else { throw CoreError("INVALID_INPUT","Unsupported canonical media value.") }
        }
        atom("checklist.media.canonical.v1");try encode(value);return result
    }
    static func signature(_ value: Any) throws -> String { hash(try bytes(value)) }
}

extension CommandRouter {
    func mediaRef(_ family: String, _ value: JSON) throws -> JSON {
        let record = StoredRecord(value, family: family)
        var reference: JSON = ["type":family, "id":try record.requiredValue("id")]
        if MediaRecordRegistry.immutableFamilies.contains(family) {
            reference["revision"] = try record.requiredValue("revision")
        }
        return reference
    }
    func mediaRecord(_ fields: JSON, project: String, caller: Caller, references: [JSON] = []) -> JSON {
        var r = fields;r["id"] = uuid();r["project_id"] = project;r["revision"] = 1;r["record_references"] = references
        r["origin"] = caller.isOwner ? "human_ui" : "agent";r["author"] = caller.principal
        r["author_session_id"] = caller.isOwner ? "human" : caller.sessionID ?? "";r["created_at"] = now();return r
    }
    func mediaWrite(_ db: Database,_ value: JSON,type: String) throws {
        guard MediaRecordRegistry.families.contains(type),value["record_references"] is [JSON] else { throw CoreError("MEDIA_CAPTURE_INCOMPLETE","Register media records and dependencies before writing.") }
        try save(db,value,type:type)
    }
    func mediaRevision(_ p: JSON,_ record: JSON) throws {
        guard let n = p["expected_revision"] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),(try? EnvelopeInteger.positiveExact(n.stringValue)) != nil else { throw CoreError("REVISION_REQUIRED","Read the exact positive integer record revision before editing.") }
        try revision(p,record)
    }
    func mediaAccess(_ db: Database,_ p: JSON,_ c: Caller,write: Bool = false) throws -> String {
        try worker(c);let pid = try scope(db,p,c,write:write)
        if !c.isOwner {
            guard c.role == "worker",c.sessionID != nil else { throw CoreError("FORBIDDEN","Media requires a registered project worker.") }
            _ = try callerSessionGeneration(db,c,project:pid)
        };return pid
    }
    func mediaContextSources(_ db: Database,project: String) throws -> [JSON] {
        try records(db,type:"media_review_context",project:project).filter { ["project_approval","instruction"].contains($0["kind"] as? String ?? "") }
    }
    func mediaScopeMatches(_ source: JSON,type: String,round: String,item: String? = nil) -> Bool {
        if let id = source["type_id"] as? String,!EnvelopeStorageIdentity.equal(id,type) { return false }
        if let id = source["round_id"] as? String,!EnvelopeStorageIdentity.equal(id,round) { return false }
        let items = strings(source,"item_ids")
        return items.isEmpty || item == nil || items.contains { EnvelopeStorageIdentity.equal($0,item) }
    }
    func mediaCurrentSources(_ db: Database,project: String,type: String,round: String) throws -> [JSON] {
        let sources = try mediaContextSources(db,project:project)
        let approved = sources.last { $0["kind"] as? String == "project_approval" }
        var instructions: [String:JSON] = [:]
        for source in sources where source["kind"] as? String == "instruction" {
            let record = StoredRecord(source, family: "media_review_context")
            instructions[try record.string("instruction_id")] = source
        }
        let scopedInstructions = instructions.values.filter { mediaScopeMatches($0,type:type,round:round) }
        let ordered = try scopedInstructions.map { source in
            (try StoredRecord(source, family: "media_review_context").string("id"), source)
        }.sorted { $0.0 < $1.0 }.map { $0.1 }
        return (approved.map {[$0]} ?? []) + ordered
    }
    func mediaSnapshot(_ db: Database,round: JSON,typeRevision: JSON,sources: [JSON],caller: Caller,previous: JSON? = nil) throws -> JSON {
        let roundRecord = StoredRecord(round, family: "media_round")
        let revisionRecord = StoredRecord(typeRevision, family: "media_review_type_revision")
        let sourceRecords = sources.map { StoredRecord($0, family: "media_review_context") }
        var refs = [try mediaRef("media_round",round),try mediaRef("media_review_type_revision",typeRevision)]
        refs += try sources.map {try mediaRef("media_review_context",$0)}
        if let previous { refs.append(try mediaRef("media_review_context",previous)) }
        let fields: JSON = [
            "kind":"snapshot", "round_id":try roundRecord.string("id"),
            "type_id":try roundRecord.string("type_id"), "type_revision_id":try revisionRecord.string("id"),
            "source_ids":try sourceRecords.map { try $0.string("id") },
            "signature":try MediaCanonical.signature(sourceRecords.map { try $0.requiredValue("signature") })
        ]
        let context = mediaRecord(fields,project:try roundRecord.string("project_id"),caller:caller,references:refs)
        try mediaWrite(db,context,type:"media_review_context");return context
    }
    func mediaEffectiveContext(_ db: Database,context: JSON,itemID: String) throws -> String {
        let record = StoredRecord(context, family: "media_review_context")
        let project = try record.string("project_id")
        let type = try record.string("type_id"), round = try record.string("round_id")
        let sources = try strings(context,"source_ids").map { try scoped(db,$0,project,type:"media_review_context") }
        let effective = sources.filter { mediaScopeMatches($0,type:type,round:round,item:itemID) }
        return try MediaCanonical.signature(effective.compactMap {$0["signature"] as? String}.sorted())
    }
    /// Opaque MAC binds observation, caller scope/generation and incarnation; no event sequences.
    func mediaToken(_ db: Database,round: JSON,caller: Caller) throws -> String {
        let record = StoredRecord(round, family: "media_round")
        let project = try record.string("project_id")
        let type = try scoped(db,record.string("type_id"),project,type:"media_review_type")
        let state: JSON = [
            "domain":"media-observed-context-v1", "round_id":try record.requiredValue("id"),
            "revision":try record.requiredValue("revision"), "context_id":try record.requiredValue("context_id"),
            "manifest_id":round["manifest_id"] ?? NSNull(), "attention_ids":strings(round,"attention_ids"),
            "type_revision_id":try record.requiredValue("type_revision_id"),
            "adopted_type_revision_id":type["adopted_revision_id"] ?? NSNull(), "principal":caller.principal,
            "scope":try authorizationScope(db,caller), "workspace":caller.workspace ?? "", "incarnation":incarnation,
            "generation":try callerSessionGeneration(db,caller,project:project)
        ]
        let authentication = HMAC<SHA256>.authenticationCode(for:try MediaCanonical.bytes(state),using:cursorKey)
        return "mc1." + Data(authentication).base64EncodedString()
    }
    func mediaObserve(_ db: Database,_ p: JSON,round: JSON,caller: Caller,allowAttention: Bool = false) throws {
        guard let token = p["observed_context_token"] as? String,token == (try mediaToken(db,round:round,caller:caller)) else { throw CoreError("MEDIA_CONTEXT_CHANGED","Refresh the exact round, context and manifest. No records changed.") }
        guard allowAttention || strings(round,"attention_ids").isEmpty else { throw CoreError("MEDIA_CONTEXT_ATTENTION","The owner must keep or migrate the changed context first. No records changed.") }
        try mediaRevision(p,round)
    }
    func mediaAttention(_ db: Database,round original: JSON,source: JSON,caller: Caller,proposedType: JSON? = nil) throws {
        var round = original
        guard ["draft","open"].contains(round["state"] as? String ?? "") else { return }
        let attention = mediaRecord(["round_id":(try StoredRecord(round, family: "media").requiredValue("id")),
            "source_id":(try StoredRecord(source, family: "media").requiredValue("id")),"state":"pending",
            "proposed_type_revision_id":proposedType?["id"] ?? NSNull()],project:(try StoredRecord(round,
             family: "media").string("project_id")),caller:caller,references:[try mediaRef(proposedType == nil ? "media_review_context" : "media_review_type_revision",
            source),try mediaRef("media_round",round)])
        try mediaWrite(db,attention,type:"media_context_attention")
        round["attention_ids"] = strings(round,"attention_ids") + [(try StoredRecord(attention, family: "media").string("id"))]
        round["record_references"] = (round["record_references"] as? [JSON] ?? []) + [try mediaRef("media_context_attention",attention)]
        try mediaWrite(db,revised(round),type:"media_round")
    }
    /// Hook runs inside the existing project edit transaction. Agent edits are not approvals.
    func mediaProjectContextChanged(_ db: Database,old: JSON,updated: JSON,caller: Caller) throws {
        guard caller.isOwner,!(try records(db,type:"media_review_type",project:((try StoredRecord(updated, family: "media").string("id"))))).isEmpty else { return }
        let briefChanged = old["brief"] as? String != updated["brief"] as? String
        let pinsChanged = try jsonString(old["pinned_decisions"] ?? []) != jsonString(updated["pinned_decisions"] ?? [])
        if briefChanged || pinsChanged {
            let prior = try mediaContextSources(db,project:((try StoredRecord(updated, family: "media").string("id")))).last {$0["kind"] as? String == "project_approval"}?["approved_context"] as? JSON
            let retainedBrief: JSON? = briefChanged ? nil : ["brief":prior?["brief"] ?? "","brief_revision":prior?["brief_revision"] ?? 0]
            _ = try mediaApproveProjectContext(db,project:updated,caller:caller,retainedBrief:retainedBrief)
        }
    }
    @discardableResult func mediaApproveProjectContext(_ db: Database,project: JSON,caller: Caller,retainedBrief: JSON? = nil) throws -> JSON {
        try owner(caller);let pid = (try StoredRecord(project, family: "media").string("id"))
        let pins = (project["pinned_decisions"] as? [JSON] ?? []).filter { $0["origin"] as? String == "human_ui" && strings($0,"task_kinds").isEmpty && strings($0,"tag_ids").isEmpty }
        let payload: JSON = ["brief":retainedBrief?["brief"] ?? project["brief"] ?? "","brief_revision":retainedBrief?["brief_revision"] ?? project["brief_revision"] ?? 0,"pinned_decisions":pins]
        let signature = try MediaCanonical.signature(payload)
        let old = try mediaContextSources(db,project:pid).last {$0["kind"] as? String == "project_approval"}
        if let old,old["signature"] as? String == signature { return old }
        if old == nil,(payload["brief"] as? String ?? "").isEmpty,pins.isEmpty { return ["state":"unchanged","approved_context":payload] }
        let source = mediaRecord(["kind":"project_approval","project_revision":(try StoredRecord(project,
             family: "media").requiredValue("revision")),"approved_context":payload,"signature":signature],
            project:pid,caller:caller,references:[try mediaRef("project",project)])
        try mediaWrite(db,source,type:"media_review_context")
        for round in try records(db,type:"media_round",project:pid) { try mediaAttention(db,round:round,source:source,caller:caller) };return source
    }
    func mediaApproveInstruction(_ db: Database,_ p: JSON,_ c: Caller,project: String) throws -> JSON {
        try owner(c);let kind = try text(p,"kind",max:32)
        guard ["rubric","direction"].contains(kind) else { throw CoreError("INVALID_INPUT","Approve a rubric or requires-action direction.") }
        var f: JSON = ["kind":"instruction","instruction_kind":kind,"body":try text(p,"body",max:16000)]
        var refs: [JSON] = []
        if let tid = p["type_id"] as? String { let t = try scoped(db,tid,project,type:"media_review_type");f["type_id"] = tid;refs.append(try mediaRef("media_review_type",t)) }
        if let rid = p["round_id"] as? String {
            let r = try scoped(db,rid,project,type:"media_round")
            guard f["type_id"] == nil || f["type_id"] as? String == r["type_id"] as? String else { throw CoreError("INVALID_INPUT","Context scopes must agree.") }
            f["round_id"] = rid;f["type_id"] = r["type_id"];refs.append(try mediaRef("media_round",
                r));refs.append(["type":"media_review_type","id":(try StoredRecord(r, family: "media").requiredValue("type_id"))])
        }
        let items = strings(p,"item_ids")
        guard p["item_ids"] == nil || p["item_ids"] is [String],items.count <= 1000,Set(items).count == items.count else { throw CoreError("INVALID_INPUT","Use distinct scoped items.") }
        for id in items {
            let item = try scoped(db,id,project,type:"media_item"),r = try scoped(db,(try StoredRecord(item, family: "media").string("round_id")),project,type:"media_round")
            guard (f["type_id"] == nil || f["type_id"] as? String == r["type_id"] as? String), (f["round_id"] == nil || f["round_id"] as? String == item["round_id"] as? String) else { throw CoreError("INVALID_INPUT","Item and context scopes must agree.") }
            refs.append(try mediaRef("media_item",item))
        };f["item_ids"] = items
        var prior: JSON?
        if let id = p["supersedes_id"] as? String {
            prior = try scoped(db,id,project,type:"media_review_context")
            guard prior?["kind"] as? String == "instruction",!(try mediaContextSources(db,project:project)).contains(where:{$0["supersedes_id"] as? String == id}) else { throw CoreError("REVISION_CONFLICT","Refresh the current instruction.") }
            f["instruction_id"] = prior!["instruction_id"];f["supersedes_id"] = id;refs.append(try mediaRef("media_review_context",prior!))
        } else { f["instruction_id"] = uuid() }
        f["signature"] = try MediaCanonical.signature(f.filter { !["instruction_id","supersedes_id"].contains($0.key) })
        let source = mediaRecord(f,project:project,caller:c,references:refs);try mediaWrite(db,source,type:"media_review_context")
        for r in try records(db,type:"media_round",project:project) {
            let tid = (try StoredRecord(r, family: "media").string("type_id")),rid = (try StoredRecord(r, family: "media").string("id"))
            let matches = try mediaItems(db,round:r).contains { item in
                mediaScopeMatches(source,type:tid,round:rid,item:item["id"] as? String) || prior.map {mediaScopeMatches($0,type:tid,round:rid,item:item["id"] as? String)} == true
            }
            let roundScopeMatches = items.isEmpty && mediaScopeMatches(source,type:tid,round:rid)
                || prior.map { strings($0,"item_ids").isEmpty && mediaScopeMatches($0,type:tid,round:rid) } == true
            if matches || roundScopeMatches { try mediaAttention(db,round:r,source:source,caller:c) }
        };return source
    }
}
