import SwiftUI

struct TaskAssignmentSheet: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) private var dismiss
    let task: Record
    @State private var selectedSessionID = ""
    @State private var reason = ""
    @State private var availableSessions: [Record] = []
    @State private var eligibleProviders = Set<String>()
    @State private var policyRevision = 0
    @State private var expectedRevision = 0
    @State private var loading = true
    @State private var nextWorkers:String?
    @State private var previousWorkers:String?
    @State private var failure = ""
    @State private var loadedDraft = false
    var project: String { task.string("project_id") }
    var currentTask: Record { store.selectedTask(task.id) ?? store.task(task.id) ?? task }
    var projectPolicyRevision: Int { store.project(project)?.integer("policy_revision", fallback: 0) ?? 0 }
    var draftKey: String { "workerAssignmentDraft:" + project + ":" + task.id }
    var eligibleSessions: [Record] {
        TicketBulkWorkers.eligible(availableSessions, project: project, providers: eligibleProviders)
    }
    var selectedSession: Record? { eligibleSessions.first { $0.id == selectedSessionID } }
    var contextChanged: Bool { expectedRevision != currentTask.integer("revision") || policyRevision != projectPolicyRevision }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            Text("Assign an existing worker").checklistFont(.sheetTitle)
            Text("\(store.projectName(project)) · \(task.string("key")) · \(task.string("title"))").checklistFont(.bodyStrong).lineLimit(3)
            Text("Choose an actual enrolled session allowed by this ticket's current implementation policy. Assignment plans who handles the ticket; it does not launch an agent or acquire a claim.").checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText)
            if loading { ProgressView("Checking current worker eligibility…") }
            if !failure.isEmpty {
                Text(failure).checklistFont(.micro).foregroundStyle(.orange)
                Button("Retry eligibility check") { Task { await loadPolicy() } }
            }
            Picker("Worker", selection: $selectedSessionID) {
                Text("Choose an actual worker").tag("")
                if !selectedSessionID.isEmpty && selectedSession == nil { Text("Previous selection is unavailable · \(String(selectedSessionID.prefix(8)))").tag(selectedSessionID) }
                ForEach(eligibleSessions) { session in Text("\(session.string("provider").capitalized) · \(session.string("native_conversation_title", fallback: session.string("label", fallback: String(session.id.prefix(8))))) · \(String(session.id.prefix(8)))").tag(session.id) }
            }.checklistDisabled([(loading, "Still loading."), (!failure.isEmpty, "Loading failed. Read the message above.")])
            AccessibleHStack {if let cursor=previousWorkers {Button("Previous workers") {Task {await loadPolicy(cursor:cursor)}}};if let cursor=nextWorkers {Button("More workers") {Task {await loadPolicy(cursor:cursor)}}}}.checklistFont(.micro).checklistDisabled([(loading, "Still loading.")])
            if !loading && failure.isEmpty && eligibleSessions.isEmpty { Text("No currently enrolled worker is eligible for this ticket. Connect a supported provider session through its normal Checklist integration.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
            if let session = selectedSession { Text("Provider: \(session.string("provider").capitalized)").checklistFont(.micro); TechnicalDetails([("Session", session.id), ("Policy revision", "\(policyRevision)")]) }
            TextField("Why should this worker handle this ticket?", text: $reason, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
            if contextChanged && !loading {
                Label("This ticket or its policy changed. Review its current state before assigning. Your draft is retained.", systemImage: "exclamationmark.circle").checklistFont(.micro).foregroundStyle(.orange)
                Button("Review current assignment and eligibility") { expectedRevision = currentTask.integer("revision"); Task { await loadPolicy() } }
                Text("Current assignment: \(currentAssignment)").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }
            Text("Draft saved on this Mac. Your reason is recorded with the actual assignment.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            AccessibleHStack {
                Button("Close; keep draft") { saveDraft(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Assign worker") { assign() }.buttonStyle(.checklistProminent).checklistDisabled([(loading, "Still loading."), (!failure.isEmpty, "Loading failed. Read the message above."), (contextChanged, "The ticket changed. Close and reopen this sheet."), (selectedSession == nil, "Choose a worker first."), (reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Write a reason first."), (store.busy, DisabledReasons.saving), (!store.connected, DisabledReasons.offline)])
            }
        }.padding(Spacing.page).checklistSheet(width: 570)
            .onAppear { restoreDraft() }
            .task(id: task.id + ":" + String(projectPolicyRevision)) { await loadPolicy() }
            .onChange(of: selectedSessionID) { _ in saveDraft() }
            .onChange(of: reason) { _ in saveDraft() }
            .onChange(of: expectedRevision) { _ in saveDraft() }
    }
    var currentAssignment: String {
        let assignment = currentTask.object("planned_assignee")
        if let sid = assignment["session_id"] as? String { return availableSessions.first { $0.id == sid }?.string("label", fallback: sid) ?? sid }
        return currentTask.string("planned_assignee", fallback: "Unassigned").capitalized
    }
    func restoreDraft() {
        guard !loadedDraft else { return }
        let draft = store.windowPreferences.dictionary(forKey: draftKey) as? [String: String] ?? [:]
        selectedSessionID = draft["session_id"] ?? currentTask.object("planned_assignee")["session_id"] as? String ?? ""
        reason = draft["reason"] ?? ""
        expectedRevision = draft["expected_revision"].flatMap(Int.init) ?? currentTask.integer("revision")
        loadedDraft = true
    }
    func saveDraft() {
        guard loadedDraft else { return }
        store.windowPreferences.set(["session_id": selectedSessionID, "reason": reason, "expected_revision": String(expectedRevision)], forKey: draftKey)
    }
    func loadPolicy(cursor:String? = nil) async {
        loading = true; failure = ""
        defer { loading = false }
        do {
            let response = try await store.request("policy_get", ["project_id": project, "task_id": task.id])
            let query=WorkspacePageQuery(surface:"worker_sessions",project:project)
            let reply=try await store.request("workspace_page",query.parameters(cursor:cursor))
            let workers=try WorkspacePage(reply,query:query)
            availableSessions=workers.rows;nextWorkers=workers.next;previousWorkers=workers.previous
            let policy = Record(values: response["policy"] as? [String: Any] ?? [:])
            let role = Record(values: policy.object("roles")["implementer"] as? [String: Any] ?? [:])
            eligibleProviders = Set(role.strings("providers")).intersection(policy.strings("allowed_providers"))
            policyRevision = (response["revision"] as? NSNumber)?.intValue ?? 0
        } catch { failure = PlainError.text(error); eligibleProviders = [] }
    }
    func assign() {
        guard let session = selectedSession, !contextChanged else { return }
        store.run("task_edit", ["project_id": project, "task_id": task.id, "expected_revision": expectedRevision, "planned_assignee": ["kind": "agent", "session_id": session.id, "provider": session.string("provider")], "assignment_reason": reason.trimmingCharacters(in: .whitespacesAndNewlines)], success: "Existing worker assigned with your recorded reason") { _ in
            store.windowPreferences.removeObject(forKey: draftKey); dismiss()
        }
    }
}
