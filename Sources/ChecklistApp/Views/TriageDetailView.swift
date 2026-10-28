import SwiftUI

struct TriageDetailView: View {
    @EnvironmentObject var store: ChecklistStore
    let triage: Record
    @StateObject private var batchHistory = TriageBatchHistory()
    @State private var editingPurpose = false
    @State private var name = ""
    @State private var purpose = ""
    @State private var selectedTicket = ""
    @StateObject private var messageFeed = TriageMessageFeed()
    @State private var confirmation: PendingConfirmation?
    var projectID: String { triage.string("project_id") }
    var members:[Record] {store.groupTaskRows}
    var available:[Record] {store.groupCandidateRows}
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.page) {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("Edit Triage").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    Text(ProductionGroups.label(triage)).checklistFont(.title)
                    Text("\(store.projectName(projectID)) · \(orchestrator.summary) · \(members.count) current tickets").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    let counts = TriageOrchestratorDisplay.statusCountsText(stateRecord)
                    if !counts.isEmpty { Text(counts).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
                    Text("A ticket stays in this Triage through status changes. It leaves when it is Done or canceled, when another orchestrator handles it, or when it is removed.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    Text("Active includes only tickets whose own status is In progress. Triage orchestration does not change ticket status.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    if triage.bool("archived") { Text("Archived Triage · tickets and dispatched batches are preserved").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
                }
                DetailSection(title:"Orchestrator") {
                    // CL-126: the orchestrator conversation and its route state; a plan has none.
                    Text(orchestrator.orchestrator ?? "No orchestrator").checklistFont(.callout).accessibilityLabel("Orchestrator: \(orchestrator.orchestrator ?? "none")")
                    Text(orchestrator.stateLabel).checklistFont(.captionStrong).accessibilityLabel("State: \(orchestrator.stateLabel)")
                    Text(orchestrator.routeState).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText).fixedSize(horizontal: false, vertical: true)
                    let orchestration = Record(values:triage.object("orchestration"))
                    if orchestrator.orchestrator != nil, !orchestration.string("progress").isEmpty { Text(orchestration.string("progress")).checklistFont(.micro).textSelection(.enabled) }
                    if orchestrator.state == .needsRecovery { Text("Its ending does not complete, review or release these tickets.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
                    if !orchestrator.sessionID.isEmpty { TechnicalDetails([("Orchestrator session", orchestrator.sessionID)]) }
                }
                if editingPurpose {
                    DetailSection(title: "Triage brief") {
                        TextField("Name", text: $name).textFieldStyle(.roundedBorder).onChange(of: name) { _, _ in preserveDraft() }
                        TextEditor(text: $purpose).checklistFont(.body).frame(minHeight: 90).padding(Spacing.compact).overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(.quaternary)).onChange(of: purpose) { _, _ in preserveDraft() }
                        AccessibleHStack { Button("Cancel") { editingPurpose = false; store.windowPreferences.removeObject(forKey: draftKey) }; Spacer(); Button("Save Triage brief") { store.run("triage_edit", ["project_id": projectID, "group_id": triage.id, "expected_revision": triage.integer("revision"), "name": name, "purpose": purpose], success: "Triage brief saved", completion: { _ in editingPurpose = false; store.windowPreferences.removeObject(forKey: draftKey) }) }.checklistDisabled([(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Enter a name first."), (!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)]) }
                    }
                } else {
                    DetailSection(title: "Triage purpose") {
                        if triage.string("purpose").isEmpty { Text("Describe the fix or review pass these tickets should share.").checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText).textSelection(.enabled) }
                        else { RichTextView(text: triage.string("purpose"), capability: .triagePurpose) }
                        Button("Edit Triage brief…") { beginEdit() }.checklistFont(.micro)
                    }
                }
                Divider()
                TriageMessagesSection(feed: messageFeed, reload: { Task { await loadMessages() } }, loadMore: { Task { await messageFeed.loadMore { method, params in try await store.request(method, params) } } })
                TriageNoteComposer(triage: triage, display: orchestrator, sent: { Task { await loadMessages() } })
                Divider()
                DetailSection(title: "Current members") {
                    GroupTaskPagingControls(group:triage,closed:false)
                    if members.isEmpty && !store.groupTaskLoading && store.groupTaskError == nil {
                        Text("This Triage is empty. Add more work for another pass, or leave it as a record of this Triage.").checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText)
                    }
                    ForEach(members) { task in TriageMemberRow(task: task, triage: triage) }
                }
                Divider()
                DetailSection(title: "Add a ticket to this Triage") {
                    GroupCandidatePagingControls(group:triage,closed:false)
                    Picker("Ticket", selection: $selectedTicket) { Text("Choose ticket from this project").tag(""); ForEach(available) { task in Text("\(task.string("key")) · \(task.string("title"))").tag(task.id) } }.labelsHidden()
                    if let task = available.first(where: { $0.id == selectedTicket }) {
                        let epic = store.groups.first { $0.id == task.string("epic_id") }
                        Text(epic.map { "Stays in Epic: " + ProductionGroups.label($0) } ?? "No Epic. Adding it to this Triage does not change its Epic.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    }
                    Button("Add to this Triage") { store.run("group_membership", ["project_id": projectID, "group_id": triage.id, "task_id": selectedTicket, "action": "add", "expected_revision": triage.integer("revision")], success: "Ticket added to this Triage; Epic unchanged", completion: { _ in selectedTicket = "" }) }.buttonStyle(.checklistBordered).checklistDisabled([(triage.bool("archived"), "This Triage is archived. Restore it first."), (selectedTicket.isEmpty, "Choose a ticket first."), (!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
                    Text("Membership changes apply to the current members. A dispatched batch, claim or review is not rewritten.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                }
                Divider()
                TriageFixedBatchesSection(history: batchHistory) {
                    Task { await loadBatches() }
                }
                Divider()
                Button(triage.bool("archived") ? "Restore Triage" : "Archive Triage…") {
                    let archived = triage.bool("archived")
                    let change = { store.run("triage_edit",["project_id":projectID,"group_id":triage.id,"expected_revision":triage.integer("revision"),"archived":!archived],success:archived ? "Triage restored" : "Triage archived; tickets preserved") }
                    if archived { change() } else { confirmation = Confirmations.archiveTriage(ProductionGroups.label(triage), perform: change) }
                }.checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
            }.padding(Spacing.page)
        }.onAppear { store.loadGroupTasks(triage,closed:false);store.loadGroupCandidates(triage,closed:false) }
        .task(id: triage.integer("revision")) { await loadMessages() }
        .onChange(of: members.map { $0.id + ":" + $0.string("key") }) { _, _ in messageFeed.updateKeys(memberKeys) }
        .task(id: store.archivePreviewEpoch) { await loadBatches() }
        .checklistConfirmation($confirmation)
    }
    private func loadBatches() async {
        await batchHistory.load(projectID: projectID, triageID: triage.id) { method, params in
            try await store.request(method, params)
        }
    }
    /// CL-126 (R42A D2): the row's Triage summary (or the loaded members) supplies the
    /// state and counts, so the detail and the row agree.
    var stateRecord: Record {
        let summary = store.preparedTicketWorkspace?.list.triages.first { $0.triage.id.utf8.elementsEqual(triage.id.utf8) }?.triage
        return TriageOrchestratorDisplay.withMemberState(triage, summary: summary, members: members)
    }
    var orchestrator: TriageOrchestratorDisplay { TriageOrchestratorDisplay(stateRecord) }
    var memberKeys: [(id: String, key: String)] {
        let rows = members
        let ids = triage.strings("task_ids").isEmpty ? rows.map(\.id) : triage.strings("task_ids")
        return ids.map { id in
            let key = rows.first { $0.id == id }?.string("key") ?? ""
            return (id: id, key: key.isEmpty ? store.task(id)?.string("key") ?? "" : key)
        }
    }
    private func loadMessages() async {
        await messageFeed.load(projectID: projectID, triageID: triage.id, members: memberKeys) { method, params in try await store.request(method, params) }
    }
    var draftKey: String { "triageHandlingDraft-" + triage.id }
    func beginEdit() {
        let draft = store.windowPreferences.dictionary(forKey: draftKey) as? [String: String]
        name = draft?["name"] ?? triage.string("name"); purpose = draft?["purpose"] ?? triage.string("purpose"); editingPurpose = true
    }
    func preserveDraft() { if editingPurpose { store.windowPreferences.set(["name": name, "purpose": purpose], forKey: draftKey) } }
}

private struct TriageMemberRow: View {
    @EnvironmentObject var store: ChecklistStore
    let task: Record
    let triage: Record
    @State private var confirmation: PendingConfirmation?
    var body: some View { confirmableBody.checklistConfirmation($confirmation) }
    @ViewBuilder var confirmableBody: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            Button { store.open(.task(task.id)) } label: { VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(task.string("title")).checklistFont(.bodyStrong).frame(maxWidth: .infinity, alignment: .leading)
                AccessibleHStack { Text(task.string("key")).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText); Spacer(); TicketStatusPills(task: task) }
                TicketStatusReasonLine(task:task)
            } }.buttonStyle(.checklistRow)
            if let epic = store.groups.first(where: { $0.id == task.string("epic_id") }) { Button { store.open(.group(epic.id)) } label: { Label("Epic: " + ProductionGroups.label(epic), systemImage: "folder") }.buttonStyle(.link).checklistFont(.micro) }
            else { Text("No Epic").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
            AccessibleHStack { Text("Ticket stays in its Epic").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText); Spacer(); Button("Remove from Triage…") { confirmation = Confirmations.removeFromTriage(task.string("key")) { store.run("group_membership", ["project_id": triage.string("project_id"), "group_id": triage.id, "task_id": task.id, "action": "remove", "expected_revision": triage.integer("revision")], success: "Removed from this Triage; Epic unchanged") } }.checklistFont(.micro).checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)]) }
        }.checklistCard(padding: Card.padding)
    }

}

/// Detail-local history: workspace group summaries intentionally omit fixed batches.
@MainActor final class TriageBatchHistory: ObservableObject {
    @Published private(set) var batches: [Record] = []
    @Published private(set) var loading = true
    @Published private(set) var error: String?
    private var generation = UUID()

    func load(projectID: String, triageID: String,
              request: (String, [String: Any]) async throws -> [String: Any]) async {
        let read = UUID(); generation = read
        batches = []; error = nil; loading = true
        defer { if generation == read { loading = false } }
        do {
            let result = try await request("triage_list", ["project_id": projectID, "triage_id": triageID, "fields": ["project_id", "batches"]])
            guard generation == read, !Task.isCancelled else { return }
            guard let groups = result["groups"] as? [[String: Any]], groups.count == 1,
                  let group = groups.first,
                  RecordIdentity(group["id"] as? String ?? "") == RecordIdentity(triageID),
                  RecordIdentity(group["project_id"] as? String ?? "") == RecordIdentity(projectID),
                  let rows = group["batches"] as? [[String: Any]],
                  rows.allSatisfy({ !($0["id"] as? String ?? "").isEmpty }),
                  Set(rows.compactMap { $0["id"] as? String }).count == rows.count else {
                error = "Fixed batches could not be read. Try again."
                return
            }
            batches = rows.map(Record.init)
        } catch {
            guard generation == read, !Task.isCancelled else { return }
            self.error = "Fixed batches could not be loaded. " + PlainError.text(error)
        }
    }
}

struct TriageFixedBatchesSection: View {
    @ObservedObject var history: TriageBatchHistory
    let retry: () -> Void
    var body: some View {
        DetailSection(title: "Fixed batches") {
            if history.loading {
                Text("Loading fixed batches…").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            } else if let error = history.error {
                Text(error).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                Button("Retry fixed batches", action: retry).checklistFont(.micro)
            } else if history.batches.isEmpty {
                Text("No fixed batches for this Triage.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            } else {
                ForEach(history.batches) { batch in
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text("\(batch.string("phase").capitalized) · \(batch.integer("member_count", fallback: 0)) tickets").checklistFont(.callout)
                        let lifecycle = BatchLifecycleDisplay(batch)
                        Text(lifecycle.date.isEmpty ? lifecycle.label : "\(lifecycle.label) \(relativeTime(lifecycle.date))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                        if !lifecycle.reason.isEmpty { Text(lifecycle.reason).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
                        TechnicalDetails([("Batch", batch.id), ("Triage revision", "\(batch.integer("triage_revision"))"), ("Created at", batch.string("created_at")), ("Lifecycle date", lifecycle.date)])
                    }
                }
                Text("Later membership edits affect future batches. Passing tickets complete independently; the next pass contains only failed or remaining work unless this project's rules hold passing tickets.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }
        }
    }
}
