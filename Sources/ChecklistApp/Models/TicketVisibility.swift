import Foundation

/// Presentation only: closed visibility never archives, deletes or changes a ticket.
enum TicketVisibility {
    static let doneCategories: Set<String> = ["done", "completed"]

    static func isClosed(_ task: Record) -> Bool {
        task.bool("archived") || doneCategories.contains(task.string("status_category")) || Canceled.matches(task.string("status_category"))
    }
    static func includes(_ task: Record, showingClosed: Bool) -> Bool {
        !task.bool("trashed") && isClosed(task) == showingClosed
    }
    static func isClosedFilter(_ filter: String, statuses: [Record]) -> Bool {
        doneCategories.contains(filter) || Canceled.matches(filter) || filter == "archived" || statuses.contains { RecordIdentity($0.id) == RecordIdentity(filter) && (doneCategories.contains($0.string("category")) || Canceled.matches($0.string("category"))) }
    }
    static func reconciledPage(_ page: Page, filter: String, statuses: [Record]) -> Page {
        isClosedFilter(filter, statuses: statuses) ? .archived : page
    }
    static func matchesStatus(_ task: Record, filter: String, activeTriageMembers: Set<String>) -> Bool {
        matchesStatus(task, filter: filter, activeTriageMember: activeTriageMembers.contains(task.id))
    }
    static func matchesStatus(_ task: Record, filter: String, activeTriageMember: Bool) -> Bool {
        if RecordIdentity(task.string("status_id")) == RecordIdentity(filter) { return true }
        switch filter {
        case "all": return true
        case "archived": return task.bool("archived")
        case "done": return doneCategories.contains(task.string("status_category"))
        case "canceled": return Canceled.matches(task.string("status_category"))
        case "draft": return task.string("readiness") == "draft" && !isClosed(task)
        case "ready": return task.string("readiness") == "ready" && task.string("status_category") == "queued"
        case "active": return task.string("status_category") == "active" || task.bool("active_attention") || activeTriageMember
        default: return task.string("status_category") == filter
        }
    }
    static func category(_ task: Record) -> String {
        if doneCategories.contains(task.string("status_category")) { return "done" }
        if Canceled.matches(task.string("status_category")) { return "canceled" }
        return task.string("readiness") == "draft" && task.string("status_category") == "queued" ? "draft" : task.string("status_category")
    }
    static func statusLabel(_ task: Record) -> String {
        let category = category(task), name = task.string("status_name")
        let base: String
        if category == "canceled" { base = name.isEmpty || Canceled.matches(name.lowercased()) ? "Canceled" : "Canceled · " + name }
        else if category == "done" { base = name.isEmpty || ["done", "completed"].contains(name.lowercased()) ? "Done" : "Done · " + name }
        else { base = name.isEmpty ? GlossaryText.title(task.string("status_category", fallback: "queued")) : name }
        return task.bool("archived") ? "Archived · " + base : base
    }
    /// A Ready open ticket with open prerequisites names what it waits for; empty otherwise. Group headings stay plain.
    static func waitingLabel(_ task: Record) -> String {
        guard !isClosed(task), task.string("readiness") == "ready" else { return "" }
        let keys = task.records("prerequisite_blockers").map { $0.string("key") }.filter { !$0.isEmpty }
        guard !keys.isEmpty else { return "" }
        return "Waiting for " + keys.prefix(2).joined(separator: ", ") + (keys.count > 2 ? " +\(keys.count - 2)" : "")
    }
    static func groupLabel(_ task: Record) -> String {
        category(task) == "draft" ? (task.bool("archived") ? "Archived · Draft" : "Drafts") : statusLabel(task)
    }
}
