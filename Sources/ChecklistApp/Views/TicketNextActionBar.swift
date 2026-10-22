import SwiftUI

/// CL-52: one bar directly under the ticket's status line with the next permitted action.
struct NextActionBar<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Next").checklistFont(.microEmphasis).foregroundStyle(Color.checklistSecondaryText)
            content()
        }
        .padding(Spacing.control).frame(maxWidth: .infinity, alignment: .leading).checklistCard()
        .accessibilityElement(children: .contain).accessibilityLabel("Next action")
    }
}

/// The ticket's next-action bar. With the work records loaded it shows every next action; before they
/// load it shows what the selected ticket read already allows and offers to load the rest.
struct TicketNextActionBar: View {
    @EnvironmentObject var store: ChecklistStore
    let task: Record
    @State private var recoveryAttempt: Record?
    var activeAttempt: Record? { store.detailRecords("attempts", task: task).first { $0.id == task.string("active_attempt_id") && $0.string("state") == "active" } }
    var lead: TicketNextAction? {
        let attempt = activeAttempt
        let session = attempt.flatMap { active in store.detailRecords("sessions", task: task).first { $0.id == active.string("session_id") } }
        return TicketNextAction.lead(task: task, requests: store.detailRecords("requests", task: task), activeAttempt: attempt, session: session)
    }
    var body: some View {
        if store.fullSelectedRecordLoaded(task.id) {
            ReviewDetailView(task: task, part: .nextAction).checklistDisabled([(!store.selectedRecordsCurrent, "Work and review records are still loading.")])
        } else {
            NextActionBar {
                if let lead {
                    NextActionLead(task: task, step: lead) { recoveryAttempt = $0 }
                } else {
                    if let attempt = activeAttempt {
                        Text(attempt.string("phase") == "review" ? "A reviewer is working on this ticket." : "An implementer is working on this ticket.").checklistFont(.captionStrong)
                    }
                    Button("Show start, review and completion actions") { store.loadFullSelectedRecord(task.id) }
                        .buttonStyle(.checklistBordered)
                        .checklistDisabled([(!store.connected, DisabledReasons.offline), (store.selectedRecordsLoading, "The work records are loading.")])
                    Text("These actions need this ticket's current work and review records.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                }
            }
            .sheet(item: $recoveryAttempt) { attempt in TaskRecoverySheet(task: task, attempt: attempt).environmentObject(store) }
        }
    }
}

/// The first next actions, the same with or without the work records: completed, answer the blocking
/// request, recover stopped work, or make the Draft ready.
struct NextActionLead: View {
    @EnvironmentObject var store: ChecklistStore
    let task: Record
    let step: TicketNextAction
    let recover: (Record) -> Void
    var body: some View {
        switch step {
        case .completed:
            Label("Completed", systemImage: "checkmark.circle").checklistFont(.captionStrong)
            Text("The submitted work and its review history stay available below.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
        case .answer(let id):
            let title = store.detailRecords("requests", task: task).first { $0.id == id }?.string("title") ?? ""
            Button(title.isEmpty ? "Answer the blocking request" : "Answer: \(title)") { store.open(.request(id)) }.buttonStyle(.checklistProminent)
            Text("This request blocks the ticket. Work continues after your answer.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
        case .recover(let id):
            let attempt = store.detailRecords("attempts", task: task).first { $0.id == id }
            Label("The session that works on this ticket has ended or is unknown.", systemImage: "exclamationmark.triangle").checklistFont(.captionStrong).foregroundStyle(.orange)
            Button("Recover stopped work…") { if let attempt { recover(attempt) } }.buttonStyle(.checklistProminent)
                .checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving), (attempt == nil, "The work records are still loading.")])
            Text("Recover only after checking that the work stopped. A timeout does not prove it.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
        case .makeReady:
            Button("Make ready") {
                store.run("task_edit", ["project_id": task.string("project_id"), "task_id": task.id, "readiness": "ready", "expected_revision": task.integer("revision")], success: "Ticket is Ready")
            }.buttonStyle(.checklistProminent)
                .checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving), (!store.selectedTicketCurrent(task.id), DisabledReasons.ticketLoading)])
            Text("This ticket is a Draft. Make it Ready when its brief and expected outcome are useful.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
        }
    }
}
