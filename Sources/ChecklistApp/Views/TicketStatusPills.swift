import SwiftUI

/// Readiness never replaces the status, including in an ungrouped ticket row.
struct TicketStatusPills: View {
    let name: String
    let category: String
    let draft: Bool

    init(name: String, category: String, draft: Bool) {
        self.name = name; self.category = category; self.draft = draft
    }
    init(task: Record) {
        self.init(name: TicketVisibility.statusLabel(task), category: task.string("status_category"), draft: task.string("readiness") == "draft")
    }
    var body: some View {
        HStack(spacing: Spacing.compact) {
            StatusPill(name: name, category: category)
            if draft { StatusPill(name: "Draft", category: "draft") }
        }.accessibilityElement(children: .combine)
    }
}
