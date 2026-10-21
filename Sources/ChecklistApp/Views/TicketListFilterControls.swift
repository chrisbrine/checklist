import SwiftUI

/// Personal list controls never mutate project settings or ticket assignment.
struct TicketListFilterControls: View {
    @EnvironmentObject var store: ChecklistStore
    @State private var viewName = ""
    @State private var savingView = false
    @State private var workers: [Record] = []
    @State private var workerCursor: String?
    @State private var workerError: String?
    @State private var loadingWorkers = false
    @State private var workerReadID = UUID()
    var scope: String { store.projectID.map { store.projectName($0) } ?? "All projects" }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.control) {
                Menu {
                    Picker("Match tags", selection: filter(\.tagMode)) { Text("Any selected tag").tag("any"); Text("All selected tags").tag("all"); Text("None of the selected tags").tag("none") }
                    ForEach(store.ticketTags) { tag in
                        Toggle(label(tag), isOn: Binding(get: { store.listFilters.tagIDs.contains { RecordIdentity($0) == RecordIdentity(tag.id) } }, set: { selected in
                            var value = store.listFilters
                            value.tagIDs.removeAll { RecordIdentity($0) == RecordIdentity(tag.id) }
                            if selected { value.tagIDs.append(tag.id) }
                            store.tagFilter = "all"; store.listFilters = value
                        }))
                    }
                } label: { Label("Tags", systemImage:"tag") }
                assigneeMenu("Planned assignee", key: \.plannedAssignee)
                assigneeMenu("Current handler", key: \.actualAssignee)
                Menu {
                    Picker("Epic", selection: filter(\.epicID)) { Text("All Epics").tag("all"); Text("No Epic").tag("none"); ForEach(store.ticketFilterEpics) { Text(label($0)).tag($0.id) } }
                } label: { Text("Epic") }
                Menu {
                    Picker("Triage", selection: filter(\.triageID)) { Text("All Triages").tag("all"); Text("No Triage").tag("none"); ForEach(store.ticketFilterTriages) { Text(label($0)).tag($0.id) } }
                } label: { Text("Triage") }
                Menu {
                    ForEach(store.personalViews) { view in Button(view.name) { store.applyPersonalTicketView(view) } }
                    Divider()
                    Button("Save current view…") { viewName = ""; savingView = true }
                    if let id = store.selectedPersonalViewID, let selected = store.personalViews.first(where: { $0.id == id }) {
                        Button("Update \(selected.name)") { store.savePersonalTicketView(name:selected.name, updating:id) }
                        Button("Remove \(selected.name)") { store.removePersonalTicketView(id) }
                    }
                    Button("Use project defaults") { store.useProjectTaskView() }
                } label: { Text("Saved views") }
            }.menuStyle(.borderlessButton).fixedSize(horizontal:false, vertical:true)
            HStack(alignment:.top) {
                Text(summary).checklistFont(.micro).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                if store.listHasFilters { Button("Reset") { store.resetTicketFilters() }.buttonStyle(.link) }
            }
            if let workerError { Text(workerError).checklistFont(.micro).foregroundStyle(.secondary) }
        }.padding(.horizontal, Spacing.page).padding(.bottom, Spacing.control)
            .sheet(isPresented:$savingView) {
                VStack(alignment:.leading, spacing:Spacing.control) {
                    Text("Save personal view").checklistFont(.sheetTitle)
                    Text("Save these filters, grouping and order for \(scope). Keep up to 10 views.").checklistFont(.callout)
                    TextField("View name",text:$viewName).onSubmit { save() }
                    HStack { Button("Cancel") { savingView = false }.keyboardShortcut(.cancelAction); Spacer(); Button("Save view") { save() }.keyboardShortcut(.defaultAction) }
                }.padding(Spacing.page).frame(width:400)
            }
            .task(id:store.projectID) { workerReadID = UUID(); loadingWorkers = false; workers = []; workerCursor = nil; workerError = nil; await loadWorkers() }
    }
    func save() { store.savePersonalTicketView(name:viewName); if !viewName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && viewName.count <= 80 && store.personalViews.contains(where: { $0.name == viewName.trimmingCharacters(in:.whitespacesAndNewlines) }) { savingView = false } }
    func filter(_ key: WritableKeyPath<TicketListFilters,String>) -> Binding<String> { Binding(get: { store.listFilters[keyPath:key] }, set: { value in var filters = store.listFilters; filters[keyPath:key] = value; store.listFilters = filters }) }
    func assigneeMenu(_ title: String, key: WritableKeyPath<TicketListFilters,String>) -> some View {
        Menu {
            Picker(title, selection:filter(key)) {
                Text("Anyone").tag("all"); Text("Unassigned").tag("unassigned"); Text("Any worker").tag("agent"); Text("You").tag("human")
                ForEach(workers) { Text(workerLabel($0)).tag($0.id) }
            }
            if workerCursor != nil { Button("More workers…") { Task { await loadWorkers(cursor:workerCursor) } } }
            if workerError != nil { Button("Retry workers") { Task { await loadWorkers() } } }
        } label: { Text(title) }
    }
    func loadWorkers(cursor:String? = nil) async {
        guard !loadingWorkers else { return }
        let readID = UUID(); workerReadID = readID; loadingWorkers = true
        defer { if workerReadID == readID { loadingWorkers = false } }
        let query = WorkspacePageQuery(surface:"worker_sessions",project:store.projectID,limit:100)
        do {
            let response = try await store.request("workspace_page",query.parameters(cursor:cursor))
            try Task.checkCancellation()
            guard workerReadID == readID, store.projectID.map(RecordIdentity.init) == query.project.map(RecordIdentity.init) else { return }
            let page = try WorkspacePage(response,query:query)
            let rows = page.rows.filter { $0.string("role") == "worker" }
            if cursor == nil { workers = rows } else { for row in rows where !workers.contains(where: { RecordIdentity($0.id) == RecordIdentity(row.id) }) { workers.append(row) } }
            workerCursor = page.next; workerError = nil
        } catch {
            guard workerReadID == readID, !Task.isCancelled else { return }
            workerError = PlainError.text(error)
        }
    }
    func workerLabel(_ row:Record) -> String {
        let provider = row.string("provider",fallback:"Worker").capitalized
        let title = row.string("native_conversation_title",fallback:row.string("label"))
        return title.isEmpty ? provider : provider + " · " + title
    }
    func label(_ row:Record) -> String { let name = ["triage","epic"].contains(row.string("kind")) || !row.string("key").isEmpty ? ProductionGroups.label(row) : row.string("name",fallback:"Unnamed"); return store.projectID == nil ? name + " · " + store.projectName(row.string("project_id")) : name }
    func selectedName(_ id:String, rows:[Record], none:String) -> String {
        if id == "none" || id == "unassigned" { return none }; if id == "agent" { return "Any worker" }; if id == "human" { return "You" }
        if let row = rows.first(where: { RecordIdentity($0.id) == RecordIdentity(id) }) { return row.string("role") == "worker" ? workerLabel(row) : label(row) }
        return "Unavailable selection"
    }
    var summary: String {
        var parts = [scope]
        if store.statusFilter != "all" { parts.append("Status: " + (store.ticketStatuses.first { RecordIdentity($0.id) == RecordIdentity(store.statusFilter) }?.string("name") ?? GlossaryText.title(store.statusFilter))) }
        let filters = store.listFilters
        if !filters.tagIDs.isEmpty {
            let labels = filters.tagIDs.map { id in
                guard let tag = store.ticketTags.first(where: { RecordIdentity($0.id) == RecordIdentity(id) }) else { return "Unavailable tag" }
                return label(tag) + (tag.bool("retired") ? " (retired)" : "")
            }
            parts.append("Tags, \(filters.tagMode): " + labels.joined(separator:", "))
        } else if store.tagFilter != "all" { parts.append("Tag: " + selectedName(store.tagFilter,rows:store.ticketTags,none:"No tag")) }
        for (title,id,rows,none) in [("Planned assignee",filters.plannedAssignee,workers,"Unassigned"),("Current handler",filters.actualAssignee,workers,"Unassigned"),("Epic",filters.epicID,store.ticketFilterEpics,"No Epic"),("Triage",filters.triageID,store.ticketFilterTriages,"No Triage")] where id != "all" { parts.append(title + ": " + selectedName(id,rows:rows,none:none)) }
        if !store.search.isEmpty { parts.append("Search: “\(store.search)”") }
        return parts.joined(separator:" · ")
    }
}
