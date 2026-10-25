import Foundation

/// Only the currently selected ticket. This value never replaces the full index
/// and never claims that its bounded history is a complete review record.
struct SelectedTicketDisplay {
    var task: Record
    let project: Record
    let service: Record
    let collections: [String: Any]
    let counts: [String: Any]
    let contextCursor: String
    let nextHistoryCursor: String?
    let previousHistoryCursor: String?

    init(response: [String: Any]) throws {
        guard let version = response["ui_version"] as? NSNumber, String(cString:version.objCType) != "c", version.doubleValue == 1,
              let context = response["context_cursor"] as? String,!context.isEmpty,
              let task = response["task"] as? [String:Any], let tid = task["id"] as? String, !tid.isEmpty,
              let pid = task["project_id"] as? String, !pid.isEmpty,
              let project = response["project"] as? [String:Any],
              let projectID = project["id"] as? String, RecordIdentity(projectID) == RecordIdentity(pid),
              let service = response["service"] as? [String:Any], let incarnation = service["store_incarnation"] as? String, !incarnation.isEmpty,
              let collections = response["collections"] as? [String:Any], let counts = response["counts"] as? [String:Any],
              response["full_record_loaded"] as? Bool == false else { throw TicketPageError.invalid("selected_ticket") }
        for key in ["messages","attachments","attempts","requests","events","sessions","groups","statuses","tags"] {
            guard let rows = collections[key] as? [[String:Any]], rows.allSatisfy({($0["id"] as? String)?.isEmpty == false}) else {
                throw TicketPageError.invalid("selected_ticket."+key)
            }
            for row in rows where key != "sessions" {
                guard let scoped = row["project_id"] as? String, RecordIdentity(scoped) == RecordIdentity(pid) else {throw TicketPageError.invalid("selected_ticket.scope")}
                if ["messages","attachments","attempts","requests"].contains(key) {
                    guard let selected = row["task_id"] as? String, RecordIdentity(selected) == RecordIdentity(tid) else {throw TicketPageError.invalid("selected_ticket.task")}
                }
            }
        }
        for key in ["messages","attachments","attempts","requests"] {
            guard let number = counts[key] as? NSNumber,String(cString:number.objCType) != "c",number.doubleValue >= 0,number.doubleValue.rounded(.towardZero) == number.doubleValue,
                  number.intValue >= (collections[key] as? [[String:Any]] ?? []).count else {throw TicketPageError.invalid("selected_ticket.counts")}
        }
        self.task = Record(values:task);self.project = Record(values:project);self.service = Record(values:service)
        self.collections = collections;self.counts = counts;self.contextCursor = context
        func cursor(_ key: String) throws -> String? {
            if response[key] is NSNull {return nil}
            guard let token = response[key] as? String,!token.isEmpty else {throw TicketPageError.invalid(key)}
            return token
        }
        nextHistoryCursor = try cursor("next_history_cursor");previousHistoryCursor = try cursor("previous_history_cursor")
        guard response["has_more_messages"] as? Bool == (nextHistoryCursor != nil) else {throw TicketPageError.invalid("selected_ticket.history")}
    }
    func records(_ key: String) -> [Record] { (collections[key] as? [[String:Any]] ?? []).map(Record.init) }
}
