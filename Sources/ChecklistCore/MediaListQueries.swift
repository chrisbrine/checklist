import Foundation
import CoreFoundation
import Darwin
import CryptoKit
import GRDB

/// Internal canonical projections. Cursors retain only a bounded ordered reference index,
/// never candidates/originals, a database snapshot, a runtime worker or a second store.
private enum MediaQueryCursor {
    static let prefix = "ml1."
    static let maximumBytes = 1_400_000
    /// Larger reference indexes are not sealed; the cursor keeps their digest instead.
    static let sealedIndexBytes = 900_000
    static func seal(_ value: JSON, binding: Data, key: SymmetricKey) throws -> String {
        let bytes = try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
        guard bytes.count <= 1_000_000 else { throw CoreError("CAPACITY_EXCEEDED","Media reference window exceeds its bound.") }
        return prefix + (try ChaChaPoly.seal(bytes,using:key,authenticating:binding)).combined.base64EncodedString()
    }
    static func open(_ token: String,binding: Data,key: SymmetricKey) throws -> JSON {
        guard token.hasPrefix(prefix),token.utf8.count <= maximumBytes,
              let bytes = Data(base64Encoded:String(token.dropFirst(prefix.count))),
              let box = try? ChaChaPoly.SealedBox(combined:bytes),
              let plain = try? ChaChaPoly.open(box,using:key,authenticating:binding),
              let value = try? JSONSerialization.jsonObject(with:plain) as? JSON,
              let created = value["created"] as? Double,created <= Date().timeIntervalSince1970,
              Date().timeIntervalSince1970 - created < SealedCursor.maximumAge else {
            throw CoreError("CURSOR_RESET","Refresh this authorized media view.")
        };return value
    }
}

extension CommandRouter {
    private func mediaQueryBinding(_ db: Database,_ p: JSON,_ c: Caller,project: String,method: String) throws -> Data {
        var query = p;query.removeValue(forKey:"cursor");query.removeValue(forKey:"command_id")
        let identity: JSON = ["method":method,"query":query,"scope":try authorizationScope(db,c),
            "workspace":c.workspace ?? "","generation":try callerSessionGeneration(db,c,project:project)]
        return SealedCursor.binding(principal:c.principal,scope:try MediaCanonical.signature(identity),incarnation:incarnation)
    }
    func mediaQuerySchema(_ db: Database,_ round: JSON) throws -> MediaReviewSchema {
        let revision = try scoped(db,(try StoredRecord(round, family: "media").string("type_revision_id")),
            (try StoredRecord(round, family: "media").string("project_id")),type:"media_review_type_revision")
        return try MediaReviewSchema.parse((try StoredRecord(revision, family: "media").object("schema")))
    }
    // Field IDs are data, including quotes/Unicode. A hex literal cannot become SQL or JSONPath.
    private func mediaWindowOffset(_ window: JSON, count: Int) throws -> Int {
        guard let offset = window["offset"] as? Int, (0...count).contains(offset) else {
            throw CoreError("CURSOR_RESET", "Refresh this media view.")
        }
        return offset
    }
    private func mediaSQLBytes(_ value: String) -> String { "X'" + Data(value.utf8).map {String(format:"%02x",$0)}.joined() + "'" }
    private func mediaFieldSQL(_ id: MediaReviewID,alias: String = "t") -> String {
        "(SELECT value FROM json_each(\(alias).data,'$.metadata') WHERE CAST(key AS BLOB)=\(mediaSQLBytes(id.rawValue)))"
    }
    private func mediaFieldProjectionSQL(_ id: MediaReviewID,schema: MediaReviewSchema) -> String {
        let value = mediaFieldSQL(id)
        guard schema.fields.first(where: {$0.id == id})!.kind == .boolean else {return value}
        // json_each exposes Booleans as SQL integers. Restore their JSON subtype
        // only for declared Boolean projections; numbers and missing nulls stay distinct.
        return "json(CASE \(value) WHEN 0 THEN 'false' WHEN 1 THEN 'true' ELSE 'null' END)"
    }
    private func mediaValueOrderSQL(_ id: MediaReviewID,schema: MediaReviewSchema,choice: Bool) -> String {
        let value = mediaFieldSQL(id),field = schema.fields.first {$0.id == id}!
        if choice && field.kind == .choice {
            return "CASE CAST(\(value) AS BLOB) " + field.choices.enumerated().map {"WHEN \(mediaSQLBytes($0.element.rawValue)) THEN \($0.offset)"}.joined(separator:" ") + " ELSE 2147483647 END"
        }
        return [.shortText,.longText,.choice].contains(field.kind) ? "CAST(\(value) AS BLOB)" : value
    }
    private func mediaListOrderSQL(_ list: MediaListConfiguration,schema: MediaReviewSchema) -> String {
        var order: [String] = []
        for field in list.groupBy {order += ["\(mediaFieldSQL(field)) IS NULL",mediaValueOrderSQL(field,schema:schema,choice:true)]}
        for sort in list.sort {
            let value: String
            switch sort.key {
            case .field(let field): order.append("\(mediaFieldSQL(field)) IS NULL");value = mediaValueOrderSQL(field,schema:schema,choice:sort.order == .declaredChoiceOrder)
            case .title: value = "CAST(json_extract(t.data,'$.title') AS BLOB)"
            case .order: value = "COALESCE(json_extract(i.data,'$.order'),0)"
            }
            order.append(value + (sort.order == .descending ? " DESC" : " ASC"))
        }
        // Ordering only; identity predicates retain the storage columns' own collation.
        return (order + ["CAST(i.id AS BLOB)"]).joined(separator:",")
    }
    private var mediaDispositionSQL: String {
        "CASE WHEN d.id IS NULL AND i.member_item_id IS NOT NULL AND json_extract(i.data,'$.stale_predecessor_decision_id') IS NOT NULL THEN 'stale' WHEN d.id IS NULL OR i.member_item_id IS NULL THEN 'pending' WHEN json_extract(d.data,'$.review_basis_signature') IS NOT i.member_basis THEN 'stale' ELSE json_extract(d.data,'$.disposition') END"
    }
    func mediaListIndex(_ db: Database,_ p: JSON,round: JSON,list: MediaListConfiguration,schema: MediaReviewSchema) throws -> [JSON] {
        let (sql,args) = try mediaListIndexStatement(p,round:round,list:list,schema:schema)
        let rows = try Row.fetchAll(db,sql:sql,arguments:args)
        return rows.map {["id":$0["id"] as String,"revision":$0["revision"] as Int,"target_id":$0["target_id"] as String,
            "order":$0["item_order"] as Int,"decision_id":($0["decision_id"] as String?) ?? "","disposition":$0["disposition"] as String]}
    }
    /// CL-307: the round manifest is expanded once (`member`). Published items are read by
    /// primary key from its members, and the other round items once with one NOT IN probe, so
    /// work grows with the round's items. The former per-item `json_each` over the whole
    /// manifest reparsed it for every item. CROSS JOIN fixes the loop order: without table
    /// statistics SQLite could otherwise rescan a whole arm per row. The rows (duplicates
    /// included) and their values are those of the former LEFT JOIN.
    func mediaListIndexStatement(_ p: JSON,round: JSON,list: MediaListConfiguration,schema: MediaReviewSchema) throws -> (String,StatementArguments) {
        let filter = p["filter"] as? JSON ?? [:]
        guard p["filter"] == nil || p["filter"] is JSON,Set(filter.keys).isSubset(of:["dispositions","metadata","hidden_item_ids","has_agent_suggestion","agent_suggestion_excludes","has_note","note_item_ids"]) else {throw CoreError("INVALID_INPUT","Unsupported media filter.")}
        let dispositions = try MediaConfigurationValue.ids(filter["dispositions"],max:6,"filter.dispositions").map(\.rawValue)
        guard Set(dispositions).isSubset(of:["pending","accepted","needs_look","changes_requested","excluded","stale"]) else {throw CoreError("INVALID_INPUT","Unknown disposition.")}
        let hidden = try MediaConfigurationValue.ids(filter["hidden_item_ids"],max:Int.max,"filter.hidden_item_ids").map(\.rawValue)
        guard filter["metadata"] == nil || filter["metadata"] is JSON else {throw CoreError("INVALID_INPUT","Metadata filter must be an object.")}
        let metadata = filter["metadata"] as? JSON ?? [:]
        guard metadata.count <= 3 else {throw CoreError("INVALID_INPUT","Filter at most three metadata fields.")}
        var predicates: [String] = []
        var args: StatementArguments = ["project":(try StoredRecord(round, family: "media").string("project_id")),
            "round":(try StoredRecord(round, family: "media").string("id")),"manifest":round["manifest_id"] as? String ?? ""]
        for (index,entry) in metadata.sorted(by: {Data($0.key.utf8).lexicographicallyPrecedes(Data($1.key.utf8))}).enumerated() {
            let field = try MediaReviewID(entry.key);_ = try schema.validateValue(entry.value,fieldID:field)
            let name = "filter\(index)",value = mediaFieldSQL(field)
            if let text = entry.value as? String {predicates.append("CAST(\(value) AS BLOB)=\(mediaSQLBytes(text))")}
            else {predicates.append("\(value)=json_extract(:\(name),'$[0]')");args += StatementArguments([name:try jsonString([entry.value])])}
        }
        if !hidden.isEmpty {predicates.append("i.id NOT IN (SELECT value FROM json_each(:hidden))");args += ["hidden":try jsonString(hidden)]}
        if !dispositions.isEmpty {predicates.append("(\(mediaDispositionSQL)) IN (SELECT value FROM json_each(:dispositions))");args += ["dispositions":try jsonString(dispositions)]}
        let suggestions = try mediaSuggestionPredicates(filter,arguments:&args)
        predicates += suggestions.predicates
        let sql = """
        WITH \(suggestions.table)member AS MATERIALIZED (
          SELECT CAST(json_extract(entry.value,'$.item_id') AS TEXT) item_id,json_extract(entry.value,'$.target_id') target_id,
            json_extract(entry.value,'$.review_basis_signature') basis
          FROM records m,json_each(m.data,'$.items') entry
          WHERE m.id=:manifest AND m.project_id=:project AND m.type='media_round_manifest'),
        listed AS (
          SELECT i.id,i.revision,i.project_id,i.data,member.item_id member_item_id,member.target_id member_target_id,member.basis member_basis
          FROM member CROSS JOIN records i ON i.id=member.item_id
          WHERE i.type='media_item' AND i.project_id=:project AND json_extract(i.data,'$.round_id')=:round
          UNION ALL
          SELECT i.id,i.revision,i.project_id,i.data,NULL,NULL,NULL FROM records i
          WHERE i.type='media_item' AND i.project_id=:project AND json_extract(i.data,'$.round_id')=:round
            AND i.id NOT IN (SELECT item_id FROM member WHERE item_id IS NOT NULL))
        SELECT i.id,i.revision,t.id target_id,COALESCE(json_extract(i.data,'$.order'),0) item_order,
          d.id decision_id,\(mediaDispositionSQL) disposition
        FROM listed i CROSS JOIN records t ON t.id=COALESCE(i.member_target_id,json_extract(i.data,'$.draft_target_id')) AND t.project_id=i.project_id AND t.type='media_item_target'
        LEFT JOIN records d ON d.id=json_extract(i.data,'$.last_decision_id') AND d.project_id=i.project_id AND d.type='media_owner_decision'
        \(predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator:" AND ")) ORDER BY \(mediaListOrderSQL(list,schema:schema))
        """
        return (sql,args)
    }
    func mediaListQuery(_ db: Database,method: String,p: JSON,c: Caller,project: String) throws -> JSON {
        let round = try scoped(db,try text(p,"round_id"),project,type:"media_round")
        let schema = try mediaQuerySchema(db,round)
        guard p["list"] == nil || p["list"] is JSON else {throw CoreError("INVALID_INPUT","List must be an object.")}
        let list = try MediaListConfiguration.parse(p["list"] as? JSON ?? [:],schema:schema)
        let limit = try MediaConfigurationValue.integer(p["limit"] ?? 100,min:1,max:100,"limit")
        let binding = try mediaQueryBinding(db,p,c,project:project,method:method)
        var window: JSON,index: [JSON]
        if let token = p["cursor"] {
            guard let token = token as? String else {throw CoreError("CURSOR_RESET","Refresh this media view.")}
            window = try MediaQueryCursor.open(token,binding:binding,key:cursorKey)
            if let digest = window["index_digest"] as? String {
                // CL-307: a round too large to seal its reference index pages by recomputing
                // the index; any change since the first page asks for a refresh.
                index = try mediaListIndex(db,p,round:round,list:list,schema:schema)
                guard try MediaCanonical.signature(index) == digest else {throw CoreError("CURSOR_RESET","This media view changed. Refresh it.")}
            } else {index = try StoredRecord(window, family: "media").objects("index")}
        } else {
            index = try mediaListIndex(db,p,round:round,list:list,schema:schema)
            window = ["created":Date().timeIntervalSince1970,"offset":0,"index":index]
        }
        let offset = try mediaWindowOffset(window, count:index.count)
        var counts: [String:Int] = [:];for entry in index {counts[(try StoredRecord(entry, family: "media").string("disposition")),default:0] += 1}
        var result: JSON = ["round_id":(try StoredRecord(round, family: "media").requiredValue("id")),"total":index.count,"counts":counts,"snapshot":true,"requires_current_observation":true]
        if method == "media_item_counts" {return result}
        let columns = list.visibleColumns.map {id in "\(sqlQuote(id.rawValue)),\(mediaFieldProjectionSQL(id,schema:schema))"}.joined(separator:",")
        let groupValues = list.groupBy.map {mediaFieldProjectionSQL($0,schema:schema)}
        let groupKeys = list.groupBy.map {id -> String in
            let field = schema.fields.first {$0.id == id}!
            return [.shortText,.longText,.choice].contains(field.kind) ? "CAST(\(mediaFieldSQL(id)) AS BLOB)" : mediaFieldSQL(id)
        }
        let groups = groupValues.indices.map {level in
            "COUNT(*) OVER (PARTITION BY \(groupKeys.prefix(level+1).joined(separator:","))) g\(level)"
        }
        // CL-307: CROSS JOIN keeps the parsed reference index as the outer loop (parsed once);
        // without statistics SQLite could otherwise scan json_each(:index) once per target row.
        let sql = """
        WITH selected AS MATERIALIZED (SELECT CAST(key AS INTEGER) position,json_extract(value,'$.target_id') target_id FROM json_each(:index))
        SELECT selected.position,json_extract(t.data,'$.title') title,json_object(\(columns)) metadata,
          json_array(\(groupValues.joined(separator:","))) group_values \(groups.isEmpty ? "" : "," + groups.joined(separator:","))
        FROM selected CROSS JOIN records t ON t.id=selected.target_id AND t.project_id=:project AND t.type='media_item_target'
        ORDER BY selected.position LIMIT :limit OFFSET :offset
        """
        let rows = try Row.fetchAll(db,sql:sql,arguments:["index":try jsonString(index),"project":project,"limit":limit,"offset":offset])
        result["rows"] = rows.map { row -> JSON in
            var value = index[row["position"] as Int];value["title"] = row["title"] as String? ?? "";value["metadata"] = jsonObject(row["metadata"] as String)
            let values = (try? JSONSerialization.jsonObject(with:Data((row["group_values"] as String).utf8))) as? [Any] ?? []
            value["group_path"] = list.groupBy.enumerated().map {level,id -> JSON in ["field_id":id.rawValue,"value":values[level],"item_count":row["g\(level)"] as Int]}
            return value
        }
        if c.isOwner {result["rows"] = try mediaRowsWithSuggestions(db,rows:result["rows"] as? [JSON] ?? [],round:round,project:project)}
        let next = offset + rows.count
        result["has_more"] = next < index.count
        if next < index.count {
            window["offset"] = next
            if window["index"] != nil,try JSONSerialization.data(withJSONObject:index).count > MediaQueryCursor.sealedIndexBytes {
                window.removeValue(forKey:"index");window["index_digest"] = try MediaCanonical.signature(index)
            }
            result["next_cursor"] = try MediaQueryCursor.seal(window,binding:binding,key:cursorKey)
        }
        else {result["next_cursor"] = NSNull()}
        return result
    }
    /// CL-350: the unfiltered disposition index of one round, for the owner's Close readiness.
    func mediaRoundDispositionIndex(_ db: Database,round: JSON) throws -> [JSON] {
        let schema = try mediaQuerySchema(db,round)
        return try mediaListIndex(db,[:],round:round,list:try MediaListConfiguration.parse([:],schema:schema),schema:schema)
    }
    private func sqlQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of:"'",with:"''") + "'" }
}

extension CommandRouter {
    /// Explicitly adopted material is immutable historical context, so a later source
    /// reversal does not rewrite it. Its managed originals must still be available.
    /// Walk only declared target references, with bounded metadata work and no blob reads.
    /// Historical absence remains optional; malformed required relationships fail before this lookup.
    private func mediaHistoricalRecord(_ db: Database,_ id: String,_ project: String,type: String) -> JSON? {
        try? scoped(db,id,project,type:type)
    }
    private func mediaMaterialOriginalsAvailable(_ db: Database,target: JSON,project: String,typeID: String,caller: Caller) throws -> Bool {
        var pending = target["material_references"] as? [JSON] ?? [],seen = Set<Data>()
        while let reference = pending.popLast() {
            guard let id = reference["target_id"] as? String else {return false}
            if !seen.insert(Data(id.utf8)).inserted {continue}
            guard seen.count <= 64,let source = try? scoped(db,id,project,type:"media_item_target"),bool(source,"publication_ready"),
                  let revision = mediaHistoricalRecord(db,(try StoredRecord(source, family: "media").string("type_revision_id")),project,type:"media_review_type_revision"),
                  EnvelopeStorageIdentity.equal(revision["type_id"] as? String,typeID),
                  let encoded = source["review_basis_base64"] as? String,let basis = Data(base64Encoded:encoded),
                  hash(basis) == source["review_basis_signature"] as? String else {return false}
            let ids = strings(source,"attachment_reference_ids")
            guard ids.count <= 64 else {return false}
            if !ids.isEmpty {
                guard let ownerID = source["attachment_owner_id"] as? String,
                      let owner = try? mediaOwnerValue(db,id:ownerID,project:project),owner.kind == .target else {return false}
                for id in ids {
                    guard let (_,attachment) = try? mediaAttachmentReference(db,project:project,id:id,owner:owner,caller:caller),
                          let path = attachment["path"] as? String,let relative = try? managedRelative(path,family:"objects"),
                          (try? StorageObjectFiles(root:root).openRegular(relative,{fd in
                              var info = stat();return fstat(fd,&info) == 0 && info.st_size == int(attachment,"size")
                          })) == true else {return false}
                }
            }
            let parents = source["material_references"] as? [JSON] ?? []
            guard parents.count <= 8,pending.count + parents.count <= 512 else {return false}
            pending += parents
        }
        return true
    }
    /// Exact accepted target resolver shared by Show, material adoption and original leases.
    /// No raw digest lookup; every dependency is scoped before content is returned.
    private func mediaApprovedExample(_ db: Database,targetID: String,decisionID: String? = nil,project: String,typeID: String,caller: Caller) throws -> JSON? {
        guard let target = try? scoped(db,targetID,project,type:"media_item_target"),
              let item = mediaHistoricalRecord(db,(try StoredRecord(target, family: "media").string("item_id")),project,type:"media_item"),
              let round = mediaHistoricalRecord(db,(try StoredRecord(item, family: "media").string("round_id")),project,type:"media_round"),
              EnvelopeStorageIdentity.equal(round["type_id"] as? String,typeID),strings(round,"attention_ids").isEmpty,
              let head = item["last_decision_id"] as? String,decisionID == nil || EnvelopeStorageIdentity.equal(head,decisionID),
              let decision = try? scoped(db,head,project,type:"media_owner_decision"),
              decision["origin"] as? String == "human_ui",decision["author_session_id"] as? String == "human",
              decision["disposition"] as? String == "accepted",EnvelopeStorageIdentity.equal(decision["target_id"] as? String,targetID),
              let winner = decision["winner_id"] as? String,strings(target,"candidate_ids").contains(where:{EnvelopeStorageIdentity.equal($0,winner)}),
              bool(target,"publication_ready"),let basis = target["review_basis_signature"] as? String,
              decision["review_basis_signature"] as? String == basis,
              let encoded = target["review_basis_base64"] as? String,let bytes = Data(base64Encoded:encoded),hash(bytes) == basis,
              let manifestID = decision["manifest_id"] as? String,
              let manifest = try? scoped(db,manifestID,project,type:"media_round_manifest"),
              manifest["digest"] as? String == decision["manifest_digest"] as? String,
              (manifest["items"] as? [JSON] ?? []).contains(where:{EnvelopeStorageIdentity.equal($0["target_id"] as? String,targetID) && $0["review_basis_signature"] as? String == basis}),
              let currentManifestID = round["manifest_id"] as? String,
              let current = try? scoped(db,currentManifestID,project,type:"media_round_manifest"),
              (current["items"] as? [JSON] ?? []).contains(where:{EnvelopeStorageIdentity.equal($0["item_id"] as? String,item["id"] as? String) && $0["review_basis_signature"] as? String == basis}) else {return nil}
        let (type,context) = try mediaRoundParts(db,round)
        guard let shape = try mediaCompatibleShapeForTarget(db,item:item,target:target,typeRevision:type,context:context),
              bool(shape,"publication_ready"),shape["review_basis_signature"] as? String == basis else {return nil}
        guard try mediaMaterialOriginalsAvailable(db,target:target,project:project,typeID:typeID,caller:caller) else {return nil}
        let candidate = try scoped(db,winner,project,type:"media_candidate")
        var references: [JSON] = []
        let managedSlots = try strings(target,"candidate_ids").flatMap { id in
            (try scoped(db,id,project,type:"media_candidate")["slots"] as? [JSON] ?? []).filter {$0["attachment_id"] is String}
        }
        if !managedSlots.isEmpty {
            guard let ownerID = target["attachment_owner_id"] as? String,
                  let owner = try? mediaOwnerValue(db,id:ownerID,project:project),owner.kind == .target else {return nil}
            var attachments: [Data:(JSON,JSON)] = [:]
            for id in strings(target,"attachment_reference_ids") {
                guard let pair = try? mediaAttachmentReference(db,project:project,id:id,owner:owner,caller:caller),
                      let path = pair.1["path"] as? String,let relative = try? managedRelative(path,family:"objects"),
                      (try? StorageObjectFiles(root:root).openRegular(relative, { fd -> Bool in
                          var info = stat();return fstat(fd,&info) == 0 && info.st_size == int(pair.1,"size")
                      })) == true else {return nil}
                attachments[Data(((try StoredRecord(pair.1, family: "media").string("id"))).utf8)] = pair
            }
            for slot in managedSlots {
                guard let pair = attachments[Data(((try StoredRecord(slot, family: "media").string("attachment_id"))).utf8)],pair.1["sha256"] as? String == slot["sha256"] as? String else {return nil}
            }
            for slot in candidate["slots"] as? [JSON] ?? [] where slot["attachment_id"] is String {
                let pair = attachments[Data(((try StoredRecord(slot, family: "media").string("attachment_id"))).utf8)]!
                references.append(["reference_id":(try StoredRecord(pair.0, family: "media").requiredValue("id")),
                    "attachment_id":(try StoredRecord(pair.1, family: "media").requiredValue("id")),
                    "slot_id":(try StoredRecord(slot, family: "media").requiredValue("slot_id")),
                    "sha256":(try StoredRecord(pair.1, family: "media").requiredValue("sha256")),
                    "size":(try StoredRecord(pair.1, family: "media").requiredValue("size"))])
            }
        }
        return ["target_id":targetID,"item_id":(try StoredRecord(item, family: "media").requiredValue("id")),
            "round_id":(try StoredRecord(round, family: "media").requiredValue("id")),"type_id":typeID,
            "decision_id":head,
            "title":(try StoredRecord(target, family: "media").requiredValue("title")),"metadata":(try StoredRecord(target,
                 family: "media").requiredValue("metadata")),"winner_id":winner,"slots":(try StoredRecord(candidate,
                 family: "media").requiredValue("slots")),
            "review_basis_signature":basis,"historical_context_label":"Historical owner-accepted example — no current approval",
            "context_id":(try StoredRecord(target, family: "media").requiredValue("context_id")),
                "type_revision_id":(try StoredRecord(target, family: "media").requiredValue("type_revision_id")),
                "display_only":true,"grants_current_approval":false,
            "original_references":references,"decision_created_at":(try StoredRecord(decision,
                 family: "media").requiredValue("created_at")),"decision_origin":(try StoredRecord(decision,
                 family: "media").requiredValue("origin")),"decision_author_session_id":(try StoredRecord(decision,
                 family: "media").requiredValue("author_session_id")),"round_title":(try StoredRecord(round,
                 family: "media").requiredValue("title")),"source_name":candidate["source_name"] ?? "Captured text"]
    }
    func mediaExampleQuery(_ db: Database,p: JSON,c: Caller,project: String) throws -> JSON {
        let round = try scoped(db,try text(p,"round_id"),project,type:"media_round"),schema = try mediaQuerySchema(db,round)
        let item = try scoped(db,try text(p,"item_id"),project,type:"media_item")
        guard EnvelopeStorageIdentity.equal(item["round_id"] as? String,round["id"] as? String) else {throw CoreError("NOT_FOUND","This item is unavailable in this round.")}
        guard p["examples"] == nil || p["examples"] is JSON else {throw CoreError("INVALID_INPUT","Examples must be an object.")}
        let options = try MediaHistoricalExamples.parse(p["examples"] as? JSON ?? ["enabled":false],schema:schema)
        if let expanded = p["expanded"] {
            guard let n = expanded as? NSNumber,CFGetTypeID(n) == CFBooleanGetTypeID() else {throw CoreError("INVALID_INPUT","expanded must be Boolean.")}
        }
        guard let request = options.request(expanded:bool(p,"expanded"),projectID:try MediaReviewID(project),typeID:schema.id) else {
            return ["collapsed":true,"examples":[JSON](),"has_more":false,"next_cursor":NSNull()]
        }
        let binding = try mediaQueryBinding(db,p,c,project:project,method:"media_approved_examples")
        var window: JSON
        if let cursor = p["cursor"] {
            guard let cursor = cursor as? String else {throw CoreError("CURSOR_RESET","Refresh these examples.")}
            window = try MediaQueryCursor.open(cursor,binding:binding,key:cursorKey)
        } else {
            var predicates = ["i.type='media_item'","i.project_id=:project","r.type='media_round'","r.project_id=i.project_id","json_extract(r.data,'$.type_id')=:type","r.id<>:round","d.type='media_owner_decision'","d.project_id=i.project_id","json_extract(d.data,'$.disposition')='accepted'","json_extract(d.data,'$.origin')='human_ui'","t.type='media_item_target'","t.project_id=i.project_id"]
            var args: StatementArguments = ["project":project,"type":schema.id.rawValue,"round":(try StoredRecord(round, family: "media").string("id"))]
            switch request.selection {
            case .explicitTargets(let targets):
                predicates.append("t.id IN (SELECT value FROM json_each(:targets))");args += ["targets":try jsonString(targets.map(\.rawValue))]
            case .matching(let fields):
                let manifest = try (round["manifest_id"] as? String).map {try scoped(db,$0,project,type:"media_round_manifest")}
                let member = (manifest?["items"] as? [JSON] ?? []).first {EnvelopeStorageIdentity.equal($0["item_id"] as? String,item["id"] as? String)}
                let source = try scoped(db,member?["target_id"] as? String ?? (try StoredRecord(item, family: "media").string("draft_target_id")),project,type:"media_item_target")
                let metadata = (try StoredRecord(source, family: "media").object("metadata"))
                for id in fields {
                    guard let entry = metadata.first(where:{Data($0.key.utf8) == id.bytes}) else {return ["collapsed":false,"examples":[JSON](),"has_more":false,"next_cursor":NSNull()]}
                    let value = mediaFieldSQL(id)
                    if let text = entry.value as? String {predicates.append("CAST(\(value) AS BLOB)=\(mediaSQLBytes(text))")}
                    else {predicates.append("\(value)=json_extract(\(sqlQuote(try jsonString([entry.value]))),'$[0]')")}
                }
            }
            let rows = try Row.fetchAll(db,sql:"""
            SELECT t.id,d.id decision_id FROM records i
            JOIN records r ON r.id=json_extract(i.data,'$.round_id')
            JOIN records d ON d.id=json_extract(i.data,'$.last_decision_id')
            JOIN records t ON t.id=json_extract(d.data,'$.target_id')
            WHERE \(predicates.joined(separator:" AND ")) ORDER BY CAST(t.id AS BLOB) LIMIT 65
            """,arguments:args)
            window = ["created":Date().timeIntervalSince1970,"offset":0,"capped":rows.count > 64,
                "index":rows.prefix(64).map {["target_id":$0["id"] as String,"decision_id":$0["decision_id"] as String]}]
        }
        let index = try StoredRecord(window, family: "media").objects("index")
        let offset = try mediaWindowOffset(window, count:index.count)
        let end = min(index.count,offset + request.pageSize)
        var examples: [JSON] = []
        for ref in index[offset..<end] {
            if let value = try mediaApprovedExample(db,targetID:(try StoredRecord(ref, family: "media").string("target_id")),
                decisionID:ref["decision_id"] as? String,project:project,typeID:schema.id.rawValue,
                caller:c) {examples.append(value)}
        }
        var result: JSON = ["collapsed":false,"examples":examples,"has_more":end < index.count,
            "capped":(try StoredRecord(window, family: "media").requiredValue("capped")),"candidate_cap":64,
            "display_only":true,"grants_current_approval":false]
        if end < index.count {window["offset"] = end;result["next_cursor"] = try MediaQueryCursor.seal(window,binding:binding,key:cursorKey)}
        else {result["next_cursor"] = NSNull()}
        return result
    }
    /// Metadata Show never opens a file or creates a lease. Only this exact selected
    /// winner reference can issue a short current-caller lease under the deletion gate.
    func mediaExampleLease(method: String,p: JSON,c: Caller) throws -> JSON {
        if method == "media_example_read_release" {
            return try ArchiveStorageGate.withExclusive(root:root) {permit in
                try dbQueue.write {db in
                    let project = try self.mediaAccess(db,p,c)
                    try self.releaseMediaReadHold(db,permit:permit,project:project,id:text(p,"lease_id"),caller:c)
                    return ["released":true]
                }
            }
        }
        // Basis/candidate decoding and hashing precede the writer. The short transaction
        // fences the exact accepted head, round observation and typed owner/reference again.
        let prepared = try dbQueue.read {db -> (String,JSON,JSON,String,String) in
            let project = try self.mediaAccess(db,p,c)
            let round = try self.scoped(db,text(p,"round_id"),project,type:"media_round")
            guard let example = try self.mediaApprovedExample(db,targetID:text(p,"target_id"),
                decisionID:text(p,"decision_id"),project:project,typeID:(try StoredRecord(round,
                 family: "media").string("type_id")),caller:c),
                  !EnvelopeStorageIdentity.equal(example["round_id"] as? String,round["id"] as? String),
                  let selected = ((try StoredRecord(example, family: "media").objects("original_references"))).first(where:{EnvelopeStorageIdentity.equal($0["reference_id"] as? String,
                      p["reference_id"] as? String)}) else {throw CoreError("NOT_FOUND","This approved example reference is unavailable.")}
            let source = try self.scoped(db,(try StoredRecord(example, family: "media").string("round_id")),project,type:"media_round")
            return (project,example,selected,try self.mediaToken(db,round:source,caller:c),try self.callerSessionGeneration(db,c,project:project))
        }
        let seconds = try MediaConfigurationValue.integer(p["seconds"] ?? 300,min:1,max:300,"seconds")
        return try ArchiveStorageGate.withExclusive(root:root) {permit in
            try dbQueue.write {db in
                let (project,example,selected,token,generation) = prepared
                _ = try self.mediaAccess(db,p,c)
                let item = try self.scoped(db,(try StoredRecord(example, family: "media").string("item_id")),project,type:"media_item")
                let source = try self.scoped(db,(try StoredRecord(example, family: "media").string("round_id")),project,type:"media_round")
                guard EnvelopeStorageIdentity.equal(item["last_decision_id"] as? String,example["decision_id"] as? String),
                      token == (try self.mediaToken(db,round:source,caller:c)),generation == (try self.callerSessionGeneration(db,c,project:project)) else {throw CoreError("NOT_FOUND","This approved example reference is unavailable.")}
                let target = try self.scoped(db,(try StoredRecord(example, family: "media").string("target_id")),project,type:"media_item_target")
                let owner = try self.mediaOwnerValue(db,id:(try StoredRecord(target, family: "media").string("attachment_owner_id")),project:project)
                let (_,attachment) = try self.mediaAttachmentReference(db,project:project,id:(try StoredRecord(selected, family: "media").string("reference_id")),owner:owner,caller:c)
                let path = (try StoredRecord(attachment, family: "media").string("path"))
                let relative = try self.managedRelative(path,family:"objects")
                guard try StorageObjectFiles(root:self.root).openRegular(relative,{fd in
                          var info = stat();return fstat(fd,&info) == 0 && info.st_size == int(attachment,"size")
                      }) else {throw CoreError("NOT_FOUND","This approved example reference is unavailable.")}
                let id = uuid(),expiry = Date().addingTimeInterval(Double(seconds))
                try self.save(db,["id":id,"project_id":project,"kind":"reader","attachment_id":(try StoredRecord(attachment,
                     family: "media").requiredValue("id")),"owner_reference_id":(try StoredRecord(selected,
                     family: "media").requiredValue("reference_id")),
                    "state":"active","expires_at":expiry.timeIntervalSince1970,"author":c.principal,"incarnation":self.incarnation,
                    "session_generation":generation,"revision":1,"created_at":now()],type:"storage_hold")
                return ["lease_id":id,"expires_at":expiry.timeIntervalSince1970,"attachment":self.ownerManagedPathProjection(attachment,
                    caller:c),"target_id":(try StoredRecord(example, family: "media").requiredValue("target_id")),
                    "decision_id":(try StoredRecord(example, family: "media").requiredValue("decision_id"))]
            }
        }
    }
    func mediaMaterialReferenceAdopt(_ db: Database,p: JSON,c: Caller,project: String) throws -> JSON {
        try owner(c)
        var round = try scoped(db,try text(p,"round_id"),project,type:"media_round")
        try mediaObserve(db,p,round:round,caller:c);_ = try mediaObservedManifest(db,p,round:round)
        var item = try scoped(db,try text(p,"item_id"),project,type:"media_item")
        try mediaRevision(["expected_revision":p["expected_item_revision"] ?? NSNull()],item)
        guard EnvelopeStorageIdentity.equal(item["round_id"] as? String,round["id"] as? String),
              let example = try mediaApprovedExample(db,targetID:text(p,"reference_target_id"),
                  decisionID:text(p,"reference_decision_id"),project:project,typeID:(try StoredRecord(round,
                   family: "media").string("type_id")),caller:c),
              !EnvelopeStorageIdentity.equal(example["round_id"] as? String,round["id"] as? String) else {throw CoreError("NOT_FOUND","This approved material reference is unavailable.")}
        let (type,context) = try mediaRoundParts(db,round),schema = try MediaReviewSchema.parse((try StoredRecord(type, family: "media").object("schema")))
        let slotID = try text(p,"slot_id"),sourceSlot = try text(p,"reference_slot_id")
        guard let destination = schema.slots.first(where:{Data($0.id.rawValue.utf8) == Data(slotID.utf8) && $0.material}),
              let slot = ((try StoredRecord(example, family: "media").objects("slots"))).first(where:{EnvelopeStorageIdentity.equal($0["slot_id"] as? String,sourceSlot)}),
              (slot["text"] is String ? MediaSlotKind.text : MediaSlotKind(rawValue:slot["media_kind"] as? String ?? "")) == destination.kind else {throw CoreError("INVALID_INPUT","Adopt an exact compatible material slot.")}
        let manifest = try scoped(db,(try StoredRecord(round, family: "media").string("manifest_id")),project,type:"media_round_manifest")
        guard let member = ((try StoredRecord(manifest, family: "media").objects("items"))).first(where:{EnvelopeStorageIdentity.equal($0["item_id"] as? String,
            item["id"] as? String)}) else {throw CoreError("MEDIA_MANIFEST_CHANGED","Adopt material into a published item.")}
        let old = try scoped(db,(try StoredRecord(member, family: "media").string("target_id")),project,type:"media_item_target")
        // Do not discard unpublished successor work during an owner material edit.
        guard EnvelopeStorageIdentity.equal(item["draft_target_id"] as? String,old["id"] as? String) else {throw CoreError("MEDIA_MANIFEST_CHANGED","Publish or reconcile the existing Draft successor first.")}
        var references = old["material_references"] as? [JSON] ?? []
        references.removeAll {EnvelopeStorageIdentity.equal($0["slot_id"] as? String,slotID)}
        references.append(["project_id":project,"type_id":(try StoredRecord(round, family: "media").requiredValue("type_id")),
            "target_id":(try StoredRecord(example, family: "media").requiredValue("target_id")),
            "decision_id":(try StoredRecord(example, family: "media").requiredValue("decision_id")),
            "candidate_id":(try StoredRecord(example, family: "media").requiredValue("winner_id")),
                "source_slot_id":sourceSlot,"slot_id":slotID,"kind":destination.kind.rawValue,
                "sha256":(try StoredRecord(slot, family: "media").requiredValue("sha256"))])
        try references.sort {Data(((try StoredRecord($0, family: "media").string("slot_id"))).utf8).lexicographicallyPrecedes(Data(((try StoredRecord($1, family: "media").string("slot_id"))).utf8))}
        let candidates = try strings(old,"candidate_ids").map {try scoped(db,$0,project,type:"media_candidate")}
        var shape = try mediaTargetShape(db,item:item,title:(try StoredRecord(old, family: "media").string("title")),
            metadata:(try StoredRecord(old, family: "media").object("metadata")),candidates:candidates,
            typeRevision:type,context:context,materialReferences:references)
        for key in ["attachment_owner_id","attachment_reference_ids"] {shape[key] = old[key]}
        let target = try mediaTarget(db,item:item,shape:shape,caller:c,previous:old)
        item["draft_target_id"] = target["id"];item["record_references"] = ((try StoredRecord(item, family: "media").objects("record_references"))) + [try mediaRef("media_item_target",target)]
        item = revised(item);try mediaWrite(db,item,type:"media_item")
        let members = try ((try StoredRecord(manifest, family: "media").objects("items"))).map { entry -> (JSON,JSON) in
            if EnvelopeStorageIdentity.equal(entry["item_id"] as? String,item["id"] as? String) {return (item,target)}
            return (try scoped(db,(try StoredRecord(entry, family: "media").string("item_id")),
                project,type:"media_item"),try scoped(db,(try StoredRecord(entry, family: "media").string("target_id")),
                project,type:"media_item_target"))
        }
        let next = try mediaManifest(db,round:&round,targets:members,typeRevision:type,context:context,caller:c)
        round = revised(round);try mediaWrite(db,round,type:"media_round")
        return ["item_id":(try StoredRecord(item, family: "media").requiredValue("id")),"target_id":(try StoredRecord(target,
             family: "media").requiredValue("id")),"manifest_id":(try StoredRecord(next, family: "media").requiredValue("id")),
            "material_reference":references.first(where:{$0["slot_id"] as? String == slotID})!,
            "decision_stale":old["review_basis_signature"] as? String != target["review_basis_signature"] as? String]
    }
}
