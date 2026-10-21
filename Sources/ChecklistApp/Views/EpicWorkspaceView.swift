import SwiftUI

struct EpicWorkspaceView: View {
    @EnvironmentObject var store: ChecklistStore
    @State private var showCreate = false
    @State private var showArchived = false
    var epics: [Record] {store.workspaceRows}
    var body: some View {
        let _ = NativeRenderMetrics.body(.epics)
        VStack(alignment: .leading, spacing: Spacing.section) {
            AccessibleHStack { Text("Epics").checklistFont(.pageTitle); Spacer(); Button { showCreate = true } label: { Label("Epic", systemImage: "plus") }.buttonStyle(.checklistProminent).checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)]) }
            Text("Epics group related production work. Each Epic keeps its own brief and tickets as implementation and review move forward.").checklistFont(.callout).foregroundStyle(.secondary)
            Toggle("Include archived Epics", isOn: $showArchived).toggleStyle(.checkbox).checklistFont(.micro)
            WorkspacePagingControls()
            if epics.isEmpty {
                WorkspaceListState(symbol: "folder.badge.gearshape", emptyTitle: "Organize work in an Epic", emptyDetail: "Create an Epic for an ongoing area of your game or app, then keep its work, bugs, assets and playtests together.")
            } else {
                ScrollView { LazyVStack(spacing: Spacing.control) { ForEach(epics) { epic in EpicOverviewRow(epic: epic) } } }
            }
        }.padding(Spacing.page).onAppear {store.configureWorkspace(archived:showArchived)}.onChange(of:showArchived) {_,value in store.configureWorkspace(archived:value)}.sheet(isPresented: $showCreate) { CreateEpicSheet().environmentObject(store) }
    }
}

private struct EpicOverviewRow: View {
    @EnvironmentObject var store: ChecklistStore
    let epic: Record
    var ticketCount: Int {epic.integer("ticket_count")}
    var completed: Int {epic.integer("done_count")}
    var body: some View {
        Button { store.open(.group(epic.id)) } label: {
            VStack(alignment: .leading, spacing: Spacing.control) {
                AccessibleHStack(alignment: .top, spacing: Spacing.control) {
                    Image(systemName: "folder").checklistFont(.subheading).foregroundStyle(Color.checklistAccentText)
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Text(ProductionGroups.label(epic)).checklistFont(.sectionTitle)
                        Text(store.projectName(epic.string("project_id")) + (epic.bool("archived") ? " · Archived Epic" : " · Epic")).checklistFont(.micro).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").checklistFont(.micro).foregroundStyle(.tertiary)
                }
                let brief = epic.string("brief", fallback: epic.string("purpose"))
                if !brief.isEmpty { Text(brief).checklistFont(.callout).foregroundStyle(.secondary).lineLimit(2) }
                AccessibleHStack { ProgressView(value: Double(completed), total: Double(max(ticketCount, 1))).tint(.checklistAccentText); Text("\(completed) / \(ticketCount) done").checklistFont(.micro).foregroundStyle(.secondary).fixedSize() }
                Text(ticketCount == 0 ? "No tickets yet" : "Tickets by type").checklistFont(.micro).foregroundStyle(.secondary)
            }.padding(Spacing.group).frame(maxWidth: .infinity, alignment: .leading).checklistCard()
        }.buttonStyle(.checklistRow)
    }
}

private struct CreateEpicSheet: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) private var dismiss
    @State private var projectID = ""
    @State private var name = ""
    @State private var brief = ""
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            Text("New Epic").checklistFont(.sheetTitle)
            Text("An Epic is a lasting part of a project, with a brief and related tickets grouped by their type.").checklistFont(.callout).foregroundStyle(.secondary)
            Picker("Project", selection: $projectID) { Text("Choose project").tag(""); ForEach(store.activeProjects) { Text($0.string("name")).tag($0.id) } }
            TextField("Epic name", text: $name).textFieldStyle(.roundedBorder)
            Text("Brief / intended outcome").checklistFont(.bodyStrong)
            TextEditor(text: $brief).checklistFont(.body).frame(height: 110).padding(Spacing.compact).overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(.quaternary))
            AccessibleHStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Create Epic") { store.run("epic_create", ["project_id": projectID, "name": name, "brief": brief, "purpose": brief], success: "Epic created") { epic in if let id = epic["id"] as? String { store.open(.group(id)) }; dismiss() } }.buttonStyle(.checklistProminent).checklistDisabled([(projectID.isEmpty, "Choose a project first."), (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Enter a name first."), (!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)]) }
        }.padding(Spacing.page).checklistSheet(width: 530).onAppear { projectID = store.projectID ?? (store.activeProjects.count == 1 ? store.activeProjects.first?.id ?? "" : "") }
    }
}
