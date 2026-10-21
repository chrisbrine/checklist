import SwiftUI

struct TicketBulkDraft: Identifiable {
    let id = UUID()
    let kind: String
    let tickets: [Record]
    var undo: TicketBulkReceipt? = nil
}

struct TicketBulkEditSheet: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) private var dismiss
    let draft: TicketBulkDraft
    let completed: (TicketBulkReceipt?) -> Void
    @State private var tickets: [Record] = []
    @State private var status = "queue"
    @State private var tagAction = "add"
    @State private var selectedTags = RecordIdentitySet()
    @State private var assignment = "unassigned"
    @State private var reason = ""
    @State private var groupID = ""
    @State private var triageAction = "add"
    @State private var archiveAction = "archive"
    @State private var options: [Record] = []
    @State private var providers = Set<String>()
    @State private var previous: String?
    @State private var next: String?
    @State private var loading = false
    @State private var checking = false
    @State private var failure: String?
    @State private var preview: TicketBulkPreview?
    @State private var editGeneration = UUID()
    private var project: String { draft.tickets.first?.string("project_id") ?? "" }
    private var isUndo: Bool { draft.undo != nil }
    private var statusRequiresReason: Bool { !isUndo && draft.kind == "status" && ["cancel", "reopen"].contains(status) }
    private var missingStatusReason: Bool { statusRequiresReason && reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var statusReasonTooLong: Bool { statusRequiresReason && reason.utf8.count > 4000 }
    private var validationDisabledReasons: [(Bool, String)] {
        [(missingStatusReason, "Add a short reason to cancel or reopen these tickets."),
         (statusReasonTooLong, "Keep the reason within 4,000 bytes."),
         (!valid, "Choose a change first.")]
    }
    private var workerOptions: [Record] { TicketBulkWorkers.eligible(options, project: project, providers: providers) }
    private var title: String { isUndo ? "Undo ticket changes" : "Change \(draft.tickets.count) tickets" }
    private var summary: String {
        if isUndo { return "Undo: " + (draft.undo?.summary ?? "ticket changes") }
        switch draft.kind {
        case "status": return ["queue": "Queue tickets", "defer": "Defer tickets", "block": "Block tickets", "cancel": "Cancel tickets", "reopen": "Reopen tickets"][status] ?? "Change status"
        case "tags": return tagAction == "add" ? "Add tags" : "Remove tags"
        case "assignee": return "Change planned assignee"
        case "epic": return "Move tickets to Epic"
        case "triage": return triageAction == "add" ? "Add tickets to Triage" : "Remove tickets from Triage"
        default: return archiveAction == "archive" ? "Archive tickets" : "Unarchive tickets"
        }
    }
    private var changes: [String: Any] {
        switch draft.kind {
        case "status":
            var value: [String: Any] = ["kind": "status", "action": status]
            if statusRequiresReason { value["reason"] = reason.trimmingCharacters(in: .whitespacesAndNewlines) }
            return value
        case "tags": return ["kind": "tags", "add": tagAction == "add" ? selectedTags.values : [], "remove": tagAction == "remove" ? selectedTags.values : []]
        case "assignee":
            if let worker = workerOptions.first(where: { RecordIdentity($0.id) == RecordIdentity(assignment) }) {
                return ["kind": "assignee", "planned_assignee": ["kind": "agent", "session_id": worker.id, "provider": worker.string("provider")], "assignment_reason": reason.trimmingCharacters(in: .whitespacesAndNewlines)]
            }
            return ["kind": "assignee", "planned_assignee": assignment]
        case "epic": return ["kind": "epic", "epic_id": groupID.isEmpty ? NSNull() : groupID]
        case "triage": return ["kind": "triage", "triage_id": groupID, "action": triageAction]
        default: return ["kind": "archive", "action": archiveAction]
        }
    }
    private var valid: Bool {
        if isUndo { return !tickets.isEmpty }
        switch draft.kind {
        case "status": return !missingStatusReason && !statusReasonTooLong
        case "tags": return selectedTags.count > 0
        case "assignee": return ["unassigned", "human"].contains(assignment) || (workerOptions.contains { RecordIdentity($0.id) == RecordIdentity(assignment) } && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case "triage": return !groupID.isEmpty
        default: return true
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            Text(title).checklistFont(.sheetTitle)
            Text("\(store.projectName(project)) · \(draft.tickets.count) selected tickets").checklistFont(.bodyStrong)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.group) {
                    if isUndo {
                        Text(draft.undo?.summary ?? "Ticket changes").checklistFont(.bodyStrong)
                        Text("Undo checks the original change against each ticket now. Later edits stay. Work that has advanced or has an active claim is left alone. Notes and history stay, and cleaned files are not restored.").checklistFont(.callout).foregroundStyle(.secondary)
                    } else { editControls }
                    if loading || checking { ProgressView(loading ? "Loading choices…" : "Checking tickets…") }
                    if let failure {
                        Text(failure).checklistFont(.callout).foregroundStyle(.orange)
                        if !isUndo && ["assignee", "epic", "triage"].contains(draft.kind) { Button("Retry choices") { Task { await loadOptions() } } }
                    }
                    if let error = store.error { Text(error).checklistFont(.callout).foregroundStyle(.orange) }
                    if let preview { previewContent(preview) }
                    DisclosureGroup("Selected tickets") {
                        ForEach(draft.tickets) { ticket in Text(ticket.string("key") + " · " + ticket.string("title")).checklistFont(.callout).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 390)
            AccessibleHStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isUndo ? "Check Undo" : "Preview changes") { Task { await check() } }
                    .checklistDisabled(validationDisabledReasons + [(loading || checking, "Wait for the current check."), (store.busy, DisabledReasons.saving), (!store.connected, DisabledReasons.offline)])
                if let preview, preview.blocked.isEmpty, preview.affectedCount > 0 {
                    Button(isUndo ? "Undo \(preview.affectedCount) tickets" : "Apply to \(preview.affectedCount) tickets") { apply(tickets) }.buttonStyle(.checklistProminent)
                        .checklistDisabled(validationDisabledReasons + [(store.busy, DisabledReasons.saving), (!store.connected, DisabledReasons.offline), (checking || loading, "Wait for the current check.")])
                }
            }
        }.padding(Spacing.page).checklistSheet(width: 610)
            .task { tickets = draft.tickets; await loadOptions() }
            .onChange(of: status) { _, _ in invalidatePreview() }
            .onChange(of: tagAction) { _, _ in invalidatePreview() }
            .onChange(of: selectedTags) { _, _ in invalidatePreview() }
            .onChange(of: assignment) { _, _ in invalidatePreview() }
            .onChange(of: reason) { _, _ in invalidatePreview() }
            .onChange(of: groupID) { _, _ in invalidatePreview() }
            .onChange(of: triageAction) { _, _ in invalidatePreview() }
            .onChange(of: archiveAction) { _, _ in invalidatePreview() }
            .onDisappear { invalidatePreview() }
    }
    private func invalidatePreview() { preview = nil; editGeneration = UUID() }
    @ViewBuilder private var editControls: some View {
        switch draft.kind {
        case "status":
            Picker("Status action", selection: $status) {
                Text("Queue").tag("queue"); Text("Defer").tag("defer"); Text("Block").tag("block"); Text("Cancel").tag("cancel"); Text("Reopen").tag("reopen")
            }
            if statusRequiresReason {
                TextField("Short reason for canceling or reopening these tickets", text: $reason, axis: .vertical).textFieldStyle(.roundedBorder)
            }
            Text("Each status action removes that ticket from its current Triages. Work and review still use their normal claim and completion checks.").checklistFont(.callout).foregroundStyle(.secondary)
        case "tags":
            Picker("Tags", selection: $tagAction) { Text("Add").tag("add"); Text("Remove").tag("remove") }.pickerStyle(.segmented)
            ForEach(store.tags(project)) { tag in
                Toggle(tag.string("name"), isOn: Binding(get: { selectedTags.contains(tag.id) }, set: { if $0 { selectedTags.insert(tag.id) } else { selectedTags.remove(tag.id) } }))
            }
            if store.tags(project).isEmpty { Text("This project has no available tags.").checklistFont(.callout).foregroundStyle(.secondary) }
        case "assignee":
            Picker("Planned assignee", selection: $assignment) {
                Text("Unassigned").tag("unassigned"); Text("You · Your tickets").tag("human")
                ForEach(workerOptions) { worker in Text(worker.string("provider").capitalized + " · " + worker.string("native_conversation_title", fallback: worker.string("label", fallback: "Existing worker"))).tag(worker.id) }
            }
            optionPages
            Text("Only actual workers allowed by every selected ticket's policy are listed. Assigning a ticket to you puts it in Your tickets.").checklistFont(.callout).foregroundStyle(.secondary)
            if !["unassigned", "human"].contains(assignment) {
                TextField("Why should this worker handle these tickets?", text: $reason, axis: .vertical).textFieldStyle(.roundedBorder)
                if let worker = workerOptions.first(where: { RecordIdentity($0.id) == RecordIdentity(assignment) }) { TechnicalDetails([("Session", worker.id)]) }
            }
        case "epic", "triage":
            if draft.kind == "triage" { Picker("Triage change", selection: $triageAction) { Text("Add").tag("add"); Text("Remove").tag("remove") }.pickerStyle(.segmented) }
            Picker(draft.kind == "epic" ? "Epic" : "Triage", selection: $groupID) {
                Text(draft.kind == "epic" ? "No Epic" : "Choose Triage").tag("")
                ForEach(options) { group in Text(ProductionGroups.label(group)).tag(group.id) }
            }
            optionPages
            if draft.kind == "triage" { Text("The service checks each ticket against the Triage's phase and current membership.").checklistFont(.callout).foregroundStyle(.secondary) }
        default:
            Picker("Archive change", selection: $archiveAction) { Text("Archive").tag("archive"); Text("Unarchive").tag("unarchive") }.pickerStyle(.segmented)
            Text("Tickets with active work cannot be archived. Unarchive cannot restore files that were already cleaned.").checklistFont(.callout).foregroundStyle(.secondary)
        }
    }
    private var optionPages: some View {
        AccessibleHStack {
            if let previous { Button("Previous choices") { Task { await loadOptions(cursor: previous) } } }
            if let next { Button("More choices") { Task { await loadOptions(cursor: next) } } }
        }.checklistDisabled([(loading, "Wait for the choices to load.")])
    }
    private func previewContent(_ preview: TicketBulkPreview) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("\(preview.affectedCount) tickets would change").checklistFont(.bodyStrong)
            if preview.blocked.isEmpty { Text("All selected tickets passed this check. Apply checks them again together.").checklistFont(.callout).foregroundStyle(.secondary) }
            else {
                Text("Nothing has changed. \(preview.blocked.count) tickets cannot be included:").checklistFont(.callout)
                ForEach(Array(preview.blocked.enumerated()), id: \.offset) { _, row in
                    let ticket = tickets.first { RecordIdentity($0.id) == RecordIdentity(row.string("task_id")) }
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Text((ticket?.string("key") ?? "Ticket") + " · " + (ticket?.string("title") ?? "Unavailable ticket")).checklistFont(.bodyStrong)
                        Text(row.string("reason", fallback: "This ticket changed or is not permitted.")).checklistFont(.callout).foregroundStyle(.orange)
                    }
                }
                if preview.affectedCount > 0 {
                    Button("Apply to the \(preview.affectedCount) eligible tickets") { apply(preview.eligibleTickets(from: tickets)) }
                        .checklistDisabled(validationDisabledReasons + [(store.busy, DisabledReasons.saving), (!store.connected, DisabledReasons.offline), (checking || loading, "Wait for the current check.")])
                    Text("This sends a new change for only the eligible tickets. The blocked tickets stay as they are.").checklistFont(.micro).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func parameters(_ rows: [Record], preview: Bool) -> [String: Any] {
        var value: [String: Any] = ["project_id": project, "tasks": rows.map { ["task_id": $0.id, "expected_revision": $0.integer("revision")] as [String: Any] }, "preview": preview, "command_id": UUID().uuidString]
        if let receipt = draft.undo { value["original_command_id"] = receipt.commandID }
        else { value["changes"] = changes }
        return value
    }
    private func check() async {
        guard valid, store.connected, !store.busy else { return }
        checking = true; failure = nil; preview = nil
        let generation = editGeneration
        defer { checking = false }
        do {
            if isUndo {
                var current: [Record] = []
                for row in draft.tickets {
                    let reply = try await store.request("task_context", ["task_id": row.id, "project_id": project, "detail_level": "ui"])
                    try Task.checkCancellation()
                    let display = try SelectedTicketDisplay(response: reply)
                    guard RecordIdentity(display.task.id) == RecordIdentity(row.id), RecordIdentity(display.project.id) == RecordIdentity(project) else { throw TicketPageError.invalid("undo.scope") }
                    current.append(display.task)
                }
                tickets = current
            }
            let reply = try await store.request(isUndo ? "task_bulk_undo" : "task_bulk_edit", parameters(tickets, preview: true))
            try Task.checkCancellation()
            guard generation == editGeneration else { return }
            preview = try TicketBulkPreview(reply, tickets: tickets)
        } catch is CancellationError { return }
        catch { failure = PlainError.text(error) }
    }
    private func apply(_ rows: [Record]) {
        guard valid, !rows.isEmpty, store.connected, !store.busy else { return }
        preview = nil
        let project = project, summary = summary
        store.run(isUndo ? "task_bulk_undo" : "task_bulk_edit", parameters(rows, preview: false), success: summary) { reply in
            completed(isUndo ? nil : TicketBulkReceipt(reply: reply, project: project, summary: summary, selected: rows))
            dismiss()
        }
    }
    private func loadOptions(cursor: String? = nil) async {
        guard !isUndo, ["assignee", "epic", "triage"].contains(draft.kind) else { return }
        loading = true; failure = nil; preview = nil
        defer { loading = false }
        do {
            if draft.kind == "triage" {
                let reply = try await store.request("triage_list", ["project_id": project])
                try Task.checkCancellation()
                guard let groups = reply["groups"] as? [[String: Any]] else { throw TicketPageError.invalid("bulk.triages") }
                options = groups.map(Record.init).filter { $0.string("kind") == "triage" && !$0.bool("archived") && RecordIdentity($0.string("project_id")) == RecordIdentity(project) }
            } else {
                let query = WorkspacePageQuery(surface: draft.kind == "epic" ? "epics" : "worker_sessions", project: project)
                let reply = try await store.request("workspace_page", query.parameters(cursor: cursor))
                try Task.checkCancellation()
                let page = try WorkspacePage(reply, query: query)
                options = page.rows; previous = page.previous; next = page.next
                if draft.kind == "assignee", cursor == nil {
                    var common: Set<String>?
                    for ticket in draft.tickets {
                        let reply = try await store.request("policy_get", ["project_id": project, "task_id": ticket.id])
                        try Task.checkCancellation()
                        let policy = Record(values: reply["policy"] as? [String: Any] ?? [:])
                        let role = Record(values: policy.object("roles")["implementer"] as? [String: Any] ?? [:])
                        let allowed = Set(role.strings("providers")).intersection(policy.strings("allowed_providers"))
                        common = common.map { $0.intersection(allowed) } ?? allowed
                    }
                    providers = common ?? []
                }
            }
        } catch is CancellationError { return }
        catch { failure = PlainError.text(error); options = []; providers = [] }
    }
}
