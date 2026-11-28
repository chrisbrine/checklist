/// The closed list of canonical record families routine maintenance may retire.
/// Use the same selection at preparation and apply. A delivery is the original
/// pickup, acknowledgment and history record, including after its generation
/// closes. An attachment-import job is the original replay, repair or terminal
/// intent fence. Neither family has an age-based retirement condition.
enum RoutineCanonicalRecordRetirement: String {
    case cleanupPreview = "cleanup_preview"

    var selectionSQL: String {
        switch self {
        case .cleanupPreview:
            return """
                SELECT p.rowid FROM records p
                LEFT JOIN records t ON t.type='task' AND t.id=CASE WHEN json_valid(p.data) THEN json_extract(p.data,'$.task_id') END
                WHERE p.type='\(rawValue)' AND CASE WHEN json_valid(p.data) THEN
                  (t.id IS NULL OR json_extract(p.data,'$.task_revision') <> CASE WHEN json_valid(t.data) THEN json_extract(t.data,'$.revision') END
                   OR COALESCE(json_extract(p.data,'$.created_at'),'9999') < ?)
                ELSE 0 END
                """
        }
    }
}
