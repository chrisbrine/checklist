import Foundation

/// Only rendered fields participate in row equality. Opaque row identity keeps
/// its original bytes; changes to hidden task history cannot invalidate a label.
struct TaskRowPresentation: Equatable {
    let identity: RecordIdentity
    let selected: Bool
    let title: String
    let key: String
    let kind: String
    let projectName: String?
    let human: Bool
    let closed: Bool
    let statusReason: TicketStatusReasonPresentation?
    let statusName: String
    let waiting: String
    let draft: Bool
    var showsStatus: Bool { closed || draft }
    let statusCategory: String
    let age: String
    /// Match the visible facts without asking AX to flatten the styled label tree.
    var accessibilityLabel: String {
        [title, statusReason.map {"Reason: " + $0.text}, key, projectName, kind.capitalized,
         human ? "You" : nil, waiting.isEmpty ? nil : waiting,
         showsStatus ? statusName : nil, draft ? "Draft" : nil, age]
            .compactMap {$0}.filter {!$0.isEmpty}.joined(separator: ", ")
    }
    init(task: Record, selected: Bool, projectName: String?, age: String) {
        identity = RecordIdentity(task.id);self.selected = selected
        title = task.string("title");key = task.string("key");kind = task.string("kind",fallback:"Work")
        self.projectName = projectName
        human = task.string("planned_assignee") == "human" || task.object("planned_assignee")["kind"] as? String == "human"
        statusReason = TicketStatusReasonPresentation(task:task)
        closed = TicketVisibility.isClosed(task);statusName = TicketVisibility.statusLabel(task);waiting = TicketVisibility.waitingLabel(task)
        draft = task.string("readiness") == "draft"
        statusCategory = task.string("status_category");self.age = age
    }
}
