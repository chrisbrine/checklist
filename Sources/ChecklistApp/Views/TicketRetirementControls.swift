import SwiftUI

struct TicketRetirementControls: View {
    @EnvironmentObject var store: ChecklistStore
    let task: Record
    let files: [Record]
    @Binding var undo: TicketUndo?
    @State private var reasonAction: TicketRetirementAction?
    var body: some View {
        HStack {
            if task.bool("trashed") {
                Button("Restore from Trash") { archiveAction("restore") }
                Text("Notes and connections are retained.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            } else {
                Button("Move to Trash…") { reasonAction = .trash }
                if ["done","completed","canceled"].contains(task.string("status_category")) {
                    Button("Reopen…") { reasonAction = .reopen }
                } else {Button("Cancel ticket…") { reasonAction = .cancel }}
            }
            if let receipt = undo,receipt.available(task:task,files:files) {
                Button("Undo") {store.run(receipt.method,receipt.parameters,success:"Ticket change undone") {_ in undo = nil}}
            }
        }.buttonStyle(.checklistBordered).controlSize(.small)
            .checklistDisabled([(!store.selectedTicketCurrent(task.id),DisabledReasons.ticketLoading),(!store.connected,DisabledReasons.offline),(store.busy,DisabledReasons.saving)])
            .sheet(item: $reasonAction) { action in
                TicketRetirementReasonSheet(action: action, busy: store.busy, connected: store.connected) { reason in
                    perform(action, reason: reason)
                }
            }
    }
    func archiveAction(_ action: String, reason: String = "") {
        store.run("task_archive",["project_id":task.string("project_id"),"task_id":task.id,"expected_revision":task.integer("revision"),"action":action,"reason":reason],success:action == "trash" ? "Ticket moved to Trash" : "Ticket restored") {result in
            undo = TicketUndo.archive(result,action:action);reasonAction = nil
        }
    }
    func perform(_ action: TicketRetirementAction, reason: String) {
        if action == .trash {archiveAction(action.rawValue, reason: reason);return}
        store.run("task_transition",["project_id":task.string("project_id"),"task_id":task.id,"expected_revision":task.integer("revision"),"action":action.rawValue,"reason":reason],success:action == .cancel ? "Ticket canceled" : "Ticket reopened in Queued") {result in
            undo = TicketUndo.transition(result,previous:task);reasonAction = nil
        }
    }
}

/// The sheet item supplies its action before the first render, without separate presentation state.
enum TicketRetirementAction: String, Identifiable, CaseIterable {
    case cancel, trash, reopen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cancel: return "Cancel ticket"
        case .trash: return "Move ticket to Trash"
        case .reopen: return "Reopen ticket"
        }
    }
    var confirmLabel: String {
        switch self {
        case .cancel: return "Cancel ticket"
        case .trash: return "Move to Trash"
        case .reopen: return "Reopen ticket"
        }
    }
    var reasonPrompt: String {
        switch self {
        case .cancel: return "Reason for canceling"
        case .trash: return "Reason for moving to Trash"
        case .reopen: return "Reason for reopening"
        }
    }
    var explanation: String {
        self == .reopen
            ? "The ticket returns to Queued and keeps its notes and connections. Changing status removes it from its Triages."
            : "Notes and connections stay. Active work must be released or recovered after a verified stop first."
    }
}

struct TicketRetirementReasonSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let confirmLabel: String
    let reasonPrompt: String
    let explanation: String
    let busy: Bool
    let connected: Bool
    let perform: (String) -> Void
    @State private var reason = ""

    init(action: TicketRetirementAction, busy: Bool, connected: Bool, perform: @escaping (String) -> Void) {
        title = action.title
        confirmLabel = action.confirmLabel
        reasonPrompt = action.reasonPrompt
        explanation = action.explanation
        self.busy = busy
        self.connected = connected
        self.perform = perform
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            Text(title).checklistFont(.sheetTitle)
            Text(explanation).checklistFont(.callout)
            TextField(reasonPrompt, text: $reason, axis: .vertical).textFieldStyle(.roundedBorder)
            HStack {
                Button("Keep ticket") { dismiss() }
                Spacer()
                Button(confirmLabel) { perform(reason) }
                    .buttonStyle(.checklistProminent)
                    .checklistDisabled([(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Write a reason first."),
                                        (busy, DisabledReasons.saving), (!connected, DisabledReasons.offline)])
            }
        }.padding(Spacing.page).checklistSheet(width: 480)
    }
}

struct TicketReasonSheet: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) private var dismiss
    let task: Record
    var status: Record? = nil
    var assignment: String? = nil
    var onTransition: (([String:Any]) -> Void)? = nil
    @State private var reason = ""
    var body: some View {
        VStack(alignment:.leading,spacing:Spacing.group) {
            Text(assignment == nil ? "Change ticket status" : "Change assignment").checklistFont(.sheetTitle)
            Text("Record why this ticket should change. Active work must be released or recovered after a verified stop first.").checklistFont(.callout)
            TextField("Reason",text:$reason,axis:.vertical).textFieldStyle(.roundedBorder)
            HStack {Button("Cancel") {dismiss()};Spacer();Button("Save change") {save()}.buttonStyle(.checklistProminent).checklistDisabled([(reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,"Write a reason first."),(store.busy,DisabledReasons.saving),(!store.connected,DisabledReasons.offline)])}
        }.padding(Spacing.page).checklistSheet(width:480)
    }
    func save() {
        var params: [String:Any] = ["project_id":task.string("project_id"),"task_id":task.id,"expected_revision":task.integer("revision")]
        if let assignment { params["planned_assignee"] = assignment;params["assignment_reason"] = reason }
        else if let status {params["target_status_id"] = status.id;params["reason"] = reason}
        store.run(assignment == nil ? "task_transition" : "task_edit",params,success:"Ticket changed with your recorded reason") {result in onTransition?(result);dismiss()}
    }
}
