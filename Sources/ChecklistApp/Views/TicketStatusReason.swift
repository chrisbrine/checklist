import SwiftUI

struct TicketStatusReasonPresentation: Equatable {
    let text: String
    let actor: String
    let at: String
    init?(task: Record) {
        let reason = task.object("status_reason")
        guard let text = reason["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.text = text
        actor = reason["actor_display"] as? String ?? "Agent"
        at = reason["at"] as? String ?? ""
    }
}

/// Shared by Tickets, Needs You, inline Triages and the group detail rows.
struct TicketStatusReasonLine: View {
    let reason: TicketStatusReasonPresentation?
    init(task: Record) { reason = TicketStatusReasonPresentation(task:task) }
    init(reason: TicketStatusReasonPresentation?) { self.reason = reason }
    var body: some View {
        if let reason {
            Text(reason.text).checklistFont(.caption).foregroundStyle(Color.checklistSecondaryText)
                .lineLimit(1).truncationMode(.tail).help(reason.text)
                .accessibilityLabel("Reason: " + reason.text)
        }
    }
}

struct TicketStatusReasonDetail: View {
    let reason: TicketStatusReasonPresentation?
    init(task: Record) { reason = TicketStatusReasonPresentation(task:task) }
    var body: some View {
        if let reason {
            VStack(alignment:.leading,spacing:Spacing.hairline) {
                Text(reason.text).checklistFont(.callout).textSelection(.enabled)
                Text(reason.actor + (reason.at.isEmpty ? "" : " · " + relativeTime(reason.at)))
                    .checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
}
