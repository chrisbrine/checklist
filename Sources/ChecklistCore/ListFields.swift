import Foundation
import GRDB

extension CommandRouter {
    static let taskListFields: Set<String> = ["id","key","revision","project_id","title","brief","body","acceptance","acceptance_revision","kind","readiness","effective_readiness","status_id","status_name","status_category","status","status_reason","priority","order","tag_ids","tags","planned_assignee","assignee","assignment_reason","epic_id","needs_epic","starter_fields","archived","trashed","created_at","updated_at","created_by","origin","active_attention","work_health","active_attempt_id","active_verification_request_id","current_manifest_id","completed_at","disposition","duplicate_of_task_id","prerequisites","prerequisite_ids","required_prerequisite_ids","prerequisite_blockers","prerequisites_satisfied","queue_eligible","pickup_eligible","canonical_task_id","blocked_reason"]
    static let triageListFields: Set<String> = ["id","key","revision","project_id","kind","name","purpose","phase","phase_requires_selection","phase_source","members","task_ids","archived","created_at","updated_at","member_count","status_state","status_id","status_name","status_category","derived_status","active_attention","active_navigation","member_warnings","orchestration","orchestration_connection","membership_history","batches"]
    func listFields(_ db: Database,_ p: JSON,projects: [String],type: String,kind: String? = nil,known: Set<String>) throws -> Set<String> {
        guard let raw = p["fields"] else { return [] }
        guard let fields = raw as? [String],fields.count <= 200 else { throw CoreError("INVALID_INPUT","fields must be an array of at most 200 field names.") }
        guard !fields.isEmpty else { return [] }
        // Stored optional/retained fields are also full-row fields. Inspect keys
        // inside SQL, without hydrating every ticket just to project one page.
        let stored = try String.fetchAll(db,sql:"SELECT DISTINCT j.key FROM records r,json_each(r.data) j WHERE r.type=? AND r.project_id IN (SELECT value FROM json_each(?)) AND (? IS NULL OR json_extract(r.data,'$.kind')=?)",arguments:[type,try jsonString(projects),kind,kind])
        let valid = known.union(stored)
        guard Set(fields).isSubset(of:valid) else { throw CoreError("INVALID_INPUT","Unknown field name. Valid fields: " + valid.sorted().joined(separator:", ") + ".",details:["valid_fields":valid.sorted()]) }
        return Set(fields).union(["id","key","revision"])
    }
    func listProjection(_ rows: [JSON],fields: Set<String>) -> [JSON] {
        fields.isEmpty ? rows : rows.map { row in row.filter {fields.contains($0.key)} }
    }
    func listGroup(_ db: Database,_ p: JSON,key: String,projects: [String],kind: String) throws -> JSON? {
        guard p[key] != nil else { return nil }
        let id = try text(p,key,max:4000)
        // Same scoped lookup/refusal as other group IDs; no foreign projection.
        guard let row = try Row.fetchOne(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE id=CAST(? AS TEXT) AND type='group' AND project_id IN (SELECT value FROM json_each(?))",arguments:[Data(id.utf8),try jsonString(projects)]) else { throw CoreError("NOT_FOUND","This record is not available in this project.") }
        let group = try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"group").object
        guard group["kind"] as? String == kind else { throw CoreError("INVALID_INPUT","\(key) must name a \(kind).") }
        return group
    }
}
