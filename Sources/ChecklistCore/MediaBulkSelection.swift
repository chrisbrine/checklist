import Foundation
import GRDB

/// CL-318/CL-349 owner reads for bulk decisions. A selection names exact item revisions,
/// targets and bases; it accepts nothing, and `media_bulk_prepare` still validates every entry.
extension CommandRouter {
    private static let mediaSuggestedTable = """
    suggested AS MATERIALIZED (
      SELECT CAST(json_extract(s.data,'$.item_id') AS TEXT) item_id,json_extract(s.data,'$.review_basis_signature') basis,
        json_extract(s.data,'$.disposition') disposition,json_extract(s.data,'$.note') note
      FROM records s WHERE s.type='media_suggestion' AND s.project_id=:project AND json_extract(s.data,'$.round_id')=:round),

    """
    /// The filters "has agent suggestion" and "has note". A suggestion counts only on the
    /// item's current published basis, so an earlier target's advice never selects an item.
    /// `note_item_ids` names items with a note that is still local to the owner's window.
    func mediaSuggestionPredicates(_ filter: JSON,arguments args: inout StatementArguments) throws -> (table: String,predicates: [String]) {
        func flag(_ key: String) throws -> Bool? {
            guard let raw = filter[key] else {return nil}
            guard let number = raw as? NSNumber,CFGetTypeID(number) == CFBooleanGetTypeID() else {throw CoreError("INVALID_INPUT","\(key) must be Boolean.")}
            return number.boolValue
        }
        let hasSuggestion = try flag("has_agent_suggestion"),hasNote = try flag("has_note")
        let excludes = try MediaConfigurationValue.ids(filter["agent_suggestion_excludes"],max:4,"filter.agent_suggestion_excludes").map(\.rawValue)
        guard Set(excludes).isSubset(of:["accepted","needs_look","changes_requested","excluded"]) else {throw CoreError("INVALID_INPUT","Unknown disposition.")}
        let noteItems = try MediaConfigurationValue.ids(filter["note_item_ids"],max:Int.max,"filter.note_item_ids").map(\.rawValue)
        guard hasNote != nil || noteItems.isEmpty else {throw CoreError("INVALID_INPUT","note_item_ids applies only to has_note.")}
        guard hasSuggestion != nil || hasNote != nil || !excludes.isEmpty else {return ("",[])}
        let current = "(i.id,COALESCE(i.member_basis,''))"
        var predicates: [String] = []
        if let hasSuggestion {predicates.append("\(current) \(hasSuggestion ? "" : "NOT ")IN (SELECT item_id,basis FROM suggested)")}
        if !excludes.isEmpty {
            predicates.append("\(current) NOT IN (SELECT item_id,basis FROM suggested WHERE disposition IN (SELECT value FROM json_each(:suggestion_excludes)))")
            args += ["suggestion_excludes":try jsonString(excludes)]
        }
        if let hasNote {
            let noted = "(COALESCE(json_extract(d.data,'$.note'),'')<>'' OR \(current) IN (SELECT item_id,basis FROM suggested WHERE COALESCE(note,'')<>'') OR i.id IN (SELECT value FROM json_each(:note_items)))"
            predicates.append(hasNote ? noted : "NOT " + noted)
            args += ["note_items":try jsonString(noteItems)]
        }
        return (Self.mediaSuggestedTable,predicates)
    }
    /// The dispositions of each item's current suggestions, read once for the round.
    private func mediaCurrentSuggestionChoices(_ db: Database,round: JSON,project: String) throws -> [String:[(target: String,disposition: String)]] {
        var choices: [String:[(target: String,disposition: String)]] = [:]
        let rows = try Row.fetchAll(db,sql:"""
        SELECT CAST(json_extract(data,'$.item_id') AS TEXT) item_id,CAST(json_extract(data,'$.target_id') AS TEXT) target_id,json_extract(data,'$.disposition') disposition
        FROM records WHERE type='media_suggestion' AND project_id=? AND json_extract(data,'$.round_id')=? ORDER BY rowid
        """,arguments:[project,try StoredRecord(round,family:"media").string("id")])
        for row in rows {choices[row["item_id"] as String,default:[]].append((row["target_id"] as String,row["disposition"] as String))}
        return choices
    }
    /// Owner list rows name their current agent suggestions as display-only advice.
    func mediaRowsWithSuggestions(_ db: Database,rows: [JSON],round: JSON,project: String) throws -> [JSON] {
        guard !rows.isEmpty else {return rows}
        let choices = try mediaCurrentSuggestionChoices(db,round:round,project:project)
        guard !choices.isEmpty else {return rows}
        return rows.map { row in
            var value = row
            let target = row["target_id"] as? String,id = row["id"] as? String ?? ""
            let current = (choices[id] ?? []).filter {$0.target == target}.map(\.disposition)
            if !current.isEmpty {value["agent_suggestions"] = current}
            return value
        }
    }
    /// One snapshot of exact entries for the current list filter, or for explicit item IDs,
    /// with no page limit (CL-307), and the round observation from the same snapshot.
    /// Unpublished Draft items have no decision basis, so they are counted and left out.
    func mediaBulkSelection(_ db: Database,_ p: JSON,round: JSON,caller c: Caller,project: String) throws -> JSON {
        let stored = StoredRecord(round,family:"media")
        guard p["list"] == nil || p["list"] is JSON else {throw CoreError("INVALID_INPUT","List must be an object.")}
        let schema = try mediaQuerySchema(db,round)
        let list = try MediaListConfiguration.parse(p["list"] as? JSON ?? [:],schema:schema)
        var index = try mediaListIndex(db,p,round:round,list:list,schema:schema)
        if let raw = p["item_ids"] {
            guard let ids = raw as? [String] else {throw CoreError("INVALID_INPUT","item_ids must be a list of item IDs.")}
            let wanted = Set(ids.map {Data($0.utf8)})
            index = index.filter {wanted.contains(Data(($0["id"] as? String ?? "").utf8))}
        }
        var result: JSON = ["round_id":try stored.requiredValue("id"),"expected_revision":try stored.requiredValue("revision"),
            "observed_context_token":try mediaToken(db,round:round,caller:c),"state":try stored.requiredValue("state"),
            "context_attention":!strings(round,"attention_ids").isEmpty,"entries":[JSON](),"unpublished":0]
        guard let manifestID = round["manifest_id"] as? String else {
            result["unpublished"] = index.count;return result
        }
        let manifest = try scoped(db,manifestID,project,type:"media_round_manifest")
        result["manifest_id"] = manifestID;result["manifest_digest"] = try StoredRecord(manifest,family:"media").requiredValue("digest")
        let members = mediaManifestMembers(try StoredRecord(manifest,family:"media").objects("items")) {$0}
        var seen = Set<String>(),unpublished = 0,published: [JSON] = []
        for entry in index {
            guard let id = entry["id"] as? String,seen.insert(id).inserted else {continue}
            if members[id] == nil {unpublished += 1} else {published.append(entry)}
        }
        // One read of the listed targets; candidate IDs decide which items need a chosen take.
        var candidates: [String:[String]] = [:]
        for row in try Row.fetchAll(db,sql:"""
        WITH selected AS MATERIALIZED (SELECT json_extract(value,'$.target_id') target_id FROM json_each(:index))
        SELECT t.id,json_extract(t.data,'$.candidate_ids') candidate_ids
        FROM selected CROSS JOIN records t ON t.id=selected.target_id AND t.project_id=:project AND t.type='media_item_target'
        """,arguments:["index":try jsonString(published),"project":project]) {
            let ids = (try? JSONSerialization.jsonObject(with:Data((row["candidate_ids"] as String).utf8))) as? [String]
            candidates[row["id"] as String] = ids ?? []
        }
        let suggestions = try mediaCurrentSuggestionChoices(db,round:round,project:project)
        result["entries"] = try published.map { entry -> JSON in
            let id = try StoredRecord(entry,family:"media").string("id"),target = try StoredRecord(entry,family:"media").string("target_id")
            var value: JSON = ["item_id":id,"expected_revision":try StoredRecord(entry,family:"media").requiredValue("revision"),"target_id":target,
                "review_basis_signature":try StoredRecord(members[id]!,family:"media").requiredValue("review_basis_signature"),
                "candidate_ids":candidates[target] ?? [],"disposition":try StoredRecord(entry,family:"media").requiredValue("disposition")]
            let advice = (suggestions[id] ?? []).filter {$0.target == target}.map(\.disposition)
            if !advice.isEmpty {value["agent_suggestions"] = advice}
            return value
        }
        result["unpublished"] = unpublished
        return result
    }
}
