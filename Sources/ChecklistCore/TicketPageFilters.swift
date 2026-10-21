import Foundation
import GRDB

extension CommandRouter {
    func validateTicketFacets(_ view: JSON) throws {
        for field in ["planned_assignee", "actual_assignee", "epic_id", "triage_id"] where view[field] != nil {
            guard let value = view[field] as? String, !value.isEmpty, value.utf8.count <= 4000 else {
                throw CoreError("INVALID_INPUT", "Choose a supported ticket filter.")
            }
        }
        if let mode = view["tag_mode"] { guard let mode = mode as? String, ["any", "all", "none"].contains(mode) else { throw CoreError("INVALID_INPUT", "Choose any, all or none for tags.") } }
        if let raw = view["tag_ids"] {
            guard let tags = raw as? [String], tags.count <= 100, tags.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4000 }), Set(tags.map(SnapshotRecordIdentity.init)).count == tags.count else {
                throw CoreError("INVALID_INPUT", "Choose at most 100 distinct tags.")
            }
        }
    }

    func ticketFacetArguments(_ view: JSON?) throws -> StatementArguments {
        ["filterTags":try jsonString(view?["tag_ids"] as? [String] ?? []), "tagMode":view?["tag_mode"] as? String ?? "any",
         "planned":view?["planned_assignee"] as? String ?? "all", "actual":view?["actual_assignee"] as? String ?? "all",
         "epic":view?["epic_id"] as? String ?? "all", "triage":view?["triage_id"] as? String ?? "all"]
    }

    /// The surface has already been fenced by project/type. Attempt lookups use
    /// the record primary key; membership scans use the scoped materialization.
    var ticketFacetSQL: String {
        let planned = "COALESCE(json_extract(data,'$.planned_assignee.kind'),json_extract(data,'$.planned_assignee'),json_extract(data,'$.assignee'),'unassigned')"
        let actual = "(SELECT json_extract(a.data,'$.session_id') FROM records a WHERE a.id=json_extract(surface.data,'$.active_attempt_id') AND a.project_id=surface.project_id AND a.type='attempt' AND json_extract(a.data,'$.state')='active')"
        return """
        (json_array_length(:filterTags)=0 OR
          (:tagMode='any' AND EXISTS (SELECT 1 FROM json_each(:filterTags) wanted JOIN json_each(json_extract(data,'$.tag_ids')) held ON held.value=wanted.value COLLATE BINARY)) OR
          (:tagMode='all' AND NOT EXISTS (SELECT 1 FROM json_each(:filterTags) wanted WHERE NOT EXISTS (SELECT 1 FROM json_each(json_extract(data,'$.tag_ids')) held WHERE held.value=wanted.value COLLATE BINARY))) OR
          (:tagMode='none' AND NOT EXISTS (SELECT 1 FROM json_each(:filterTags) wanted JOIN json_each(json_extract(data,'$.tag_ids')) held ON held.value=wanted.value COLLATE BINARY)))
        AND (:planned='all' OR (:planned='unassigned' AND \(planned) IN ('unassigned','none','')) OR \(planned)=:planned COLLATE BINARY OR json_extract(data,'$.planned_assignee.session_id')=:planned COLLATE BINARY)
        AND (:actual='all' OR (:actual='unassigned' AND \(actual) IS NULL) OR \(actual)=:actual COLLATE BINARY OR (:actual='agent' AND \(actual) IS NOT NULL AND \(actual)<>'human'))
        AND (:epic='all' OR (:epic='none' AND COALESCE(json_extract(data,'$.epic_id'),'')='') OR json_extract(data,'$.epic_id')=:epic COLLATE BINARY)
        AND (:triage='all' OR (:triage='none' AND NOT EXISTS (SELECT 1 FROM memberships m WHERE m.tid=surface.id AND m.project_id=surface.project_id)) OR EXISTS (SELECT 1 FROM memberships m WHERE m.tid=surface.id AND m.project_id=surface.project_id AND m.gid=:triage COLLATE BINARY))
        """
    }
}
