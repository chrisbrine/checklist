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
    let statusName: String
    let waiting: String
    let draft: Bool
    var showsStatus: Bool { closed || draft }
    let statusCategory: String
    let age: String
    init(task: Record, selected: Bool, projectName: String?, age: String) {
        identity = RecordIdentity(task.id);self.selected = selected
        title = task.string("title");key = task.string("key");kind = task.string("kind",fallback:"Work")
        self.projectName = projectName
        human = task.string("planned_assignee") == "human" || task.object("planned_assignee")["kind"] as? String == "human"
        closed = TicketVisibility.isClosed(task);statusName = TicketVisibility.statusLabel(task);waiting = TicketVisibility.waitingLabel(task)
        draft = task.string("readiness") == "draft"
        statusCategory = task.string("status_category");self.age = age
    }
}
