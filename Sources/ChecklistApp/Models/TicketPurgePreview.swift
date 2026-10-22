import Foundation

struct TicketPurgePreview: Identifiable {
    let ticket: Record
    let digest: String
    let removed: Int
    let shared: Int
    let events: Int
    let managed: Int
    let originalBytes: Int64
    let deletionBytes: Int64
    let retainedBytes: Int64
    let backups: Int
    let observedTimes: [String]
    let creationTimes: [String]
    let incarnation: String
    var id: String {ticket.id}
    init(reply: [String:Any],ticket: Record,incarnation: String) throws {
        guard reply["can_purge"] as? Bool == true,let digest = reply["digest"] as? String,!digest.isEmpty,
              let impact = reply["impact"] as? [String:Any],
              RecordIdentity(impact["task_id"] as? String ?? "") == RecordIdentity(ticket.id),
              RecordIdentity(impact["project_id"] as? String ?? "") == RecordIdentity(ticket.string("project_id")),
              (impact["expected_revision"] as? NSNumber)?.intValue == ticket.integer("revision") else {throw TicketPageError.invalid("purge_preview")}
        self.ticket = ticket;self.digest = digest;self.incarnation = incarnation
        removed = (impact["removed_record_count"] as? NSNumber)?.intValue ?? 0
        shared = (impact["shared_record_count"] as? NSNumber)?.intValue ?? 0
        events = (impact["history_events"] as? NSNumber)?.intValue ?? 0
        managed = (impact["managed_attachment_count"] as? NSNumber)?.intValue ?? 0
        originalBytes = (impact["managed_attachment_logical_bytes"] as? NSNumber)?.int64Value ?? 0
        let deletion = impact["byte_deletion"] as? [String:Any] ?? [:]
        deletionBytes = (deletion["pending_bytes"] as? NSNumber)?.int64Value ?? 0
        retainedBytes = (deletion["retained_bytes"] as? NSNumber)?.int64Value ?? 0
        backups = (impact["known_backup_count"] as? NSNumber)?.intValue ?? 0
        observedTimes = impact["known_backup_observed_times"] as? [String] ?? []
        creationTimes = impact["known_backup_creation_times"] as? [String] ?? []
    }
    var parameters: [String:Any] {["project_id":ticket.string("project_id"),"task_id":ticket.id,"expected_revision":ticket.integer("revision"),"preview_digest":digest]}
}
