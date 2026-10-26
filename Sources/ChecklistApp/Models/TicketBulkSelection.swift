import SwiftUI

/// Selection retains the revision the owner selected, so a live update becomes a
/// visible conflict rather than silently granting permission to overwrite it.
@MainActor final class TicketBulkSelection: ObservableObject {
    @Published var selecting = false
    @Published private(set) var tickets: [Record] = []
    private var anchor: ScopedRecordIdentity?
    var count: Int { tickets.count }
    var project: String? {
        guard let first = tickets.first, tickets.allSatisfy({ RecordIdentity($0.string("project_id")) == RecordIdentity(first.string("project_id")) }) else { return nil }
        return first.string("project_id")
    }
    func contains(_ ticket: Record) -> Bool { tickets.contains { identity($0) == identity(ticket) } }
    func clear() { tickets = []; anchor = nil; selecting = false }
    @discardableResult func activate(_ ticket: Record, order: [Record], command: Bool, shift: Bool) -> Bool {
        guard selecting || command || shift else { return false }
        selecting = true
        let key = identity(ticket)
        if shift, let anchor, let start = order.firstIndex(where: { identity($0) == anchor }), let end = order.firstIndex(where: { identity($0) == key }) {
            for row in order[min(start, end)...max(start, end)] where !contains(row) { tickets.append(row) }
        } else {
            if let index = tickets.firstIndex(where: { identity($0) == key }) { tickets.remove(at: index) }
            else { tickets.append(ticket) }
            anchor = key
        }
        return true
    }
    private func identity(_ row: Record) -> ScopedRecordIdentity { .init(projectID: row.string("project_id"), id: row.id) }
    static func renderedTickets(_ rows: [TicketListRow]) -> [Record] {
        var seen = Set<ScopedRecordIdentity>()
        return rows.compactMap { row in
            let ticket: Record
            switch row.content { case .ticket(let value), .triageMember(let value): ticket = value; default: return nil }
            return seen.insert(.init(projectID: ticket.string("project_id"), id: ticket.id)).inserted ? ticket : nil
        }
    }
}

struct TicketBulkRowInteraction: Sendable {
    var selected: @MainActor @Sendable (Record) -> Bool = { _ in false }
    var activate: @MainActor @Sendable (Record, Bool, Bool) -> Bool = { _, _, _ in false }
}
private struct TicketBulkRowInteractionKey: EnvironmentKey { static let defaultValue = TicketBulkRowInteraction() }
extension EnvironmentValues {
    var ticketBulkRowInteraction: TicketBulkRowInteraction {
        get { self[TicketBulkRowInteractionKey.self] }
        set { self[TicketBulkRowInteractionKey.self] = newValue }
    }
}

/// Strictly binds a preview to the requested rows before exposing Apply.
struct TicketBulkPreview {
    let rows: [Record]
    let affectedCount: Int
    var blocked: [Record] { rows.filter { !$0.bool("eligible") } }
    var eligibleIDs: Set<RecordIdentity> { Set(rows.filter { $0.bool("eligible") }.map { RecordIdentity($0.string("task_id")) }) }
    init(_ reply: [String: Any], tickets: [Record]) throws {
        guard let values = reply["rows"] as? [[String: Any]], values.count == tickets.count,
              let count = reply["affected_count"] as? NSNumber, CFGetTypeID(count) != CFBooleanGetTypeID(), count.intValue >= 0, count.doubleValue == Double(count.intValue) else { throw TicketPageError.invalid("bulk_preview") }
        let expected = Set(tickets.map { RecordIdentity($0.id) })
        var seen = Set<RecordIdentity>()
        for value in values {
            guard let id = value["task_id"] as? String, expected.contains(RecordIdentity(id)), seen.insert(RecordIdentity(id)).inserted,
                  value["eligible"] is Bool else { throw TicketPageError.invalid("bulk_preview.rows") }
        }
        let records = values.map(Record.init)
        guard count.intValue <= records.filter({ $0.bool("eligible") }).count else { throw TicketPageError.invalid("bulk_preview.count") }
        rows = records; affectedCount = count.intValue
    }
    func eligibleTickets(from tickets: [Record]) -> [Record] { tickets.filter { eligibleIDs.contains(RecordIdentity($0.id)) } }
}

struct TicketBulkReceipt {
    let commandID: String
    let project: String
    let summary: String
    let tickets: [Record]
    init?(reply: [String: Any], project: String, summary: String, selected: [Record]) {
        guard let commandID = reply["command_id"] as? String, !commandID.isEmpty,
              let preview = try? TicketBulkPreview(reply, tickets: selected) else { return nil }
        var updated: [Record] = []
        for row in preview.rows where row.bool("eligible") {
            guard let before = selected.first(where: { RecordIdentity($0.id) == RecordIdentity(row.string("task_id")) }),
                  let revision = row.values["after_revision"] as? NSNumber else { return nil }
            var values = before.values; values["revision"] = revision
            updated.append(Record(values: values))
        }
        self.commandID = commandID; self.project = project; self.summary = summary; tickets = updated
    }
}

enum TicketBulkWorkers {
    static func eligible(_ sessions: [Record], project: String, providers: Set<String>) -> [Record] {
        sessions.filter { row in
            row.string("role") == "worker" && row.string("access_mode") != "observer_messenger" &&
            !["ended", "revoked", "disconnected"].contains(row.string("state")) && providers.contains(row.string("provider")) &&
            (RecordIdentity(row.string("project_id")) == RecordIdentity(project) || row.strings("project_ids").contains { RecordIdentity($0) == RecordIdentity(project) })
        }
    }
}
