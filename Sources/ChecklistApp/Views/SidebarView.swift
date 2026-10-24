import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.openChecklistSettings) private var openSettings
    @State private var confirmation: PendingConfirmation?
    @State private var showArchivedProjects = false
    @State private var mediaLoading = false
    var body: some View {
        let _ = NativeRenderMetrics.body(.sidebar)
        VStack(spacing: Spacing.none) {
            AccessibleHStack(spacing: Spacing.small) {
                Image(systemName: "checklist").checklistFont(.title).foregroundStyle(Color.checklistAccentText)
                // Keep the app name on one line inside the user-sized sidebar at 200% text.
                Text("Checklist").checklistFont(.title).lineLimit(1).minimumScaleFactor(0.5)
                Spacer()
            }.padding(.horizontal, Spacing.section).padding(.top, Spacing.page).padding(.bottom, Spacing.section)
            List {
                navigation(.overview)
                navigation(.needsYou, count: store.needsCount)
                Section {
                    ForEach(store.activeProjects) { project in
                        Button { store.select(.tasks, project: project.id) } label: {
                            HStack(spacing: Spacing.row) {
                                ProjectIcon(project: project, size: 20)
                                Text(project.string("name")).lineLimit(1)
                                Spacer(minLength: 0)
                            }.checklistFont(.body).padding(.vertical, Spacing.compact).padding(.horizontal, Spacing.tight)
                        }.buttonStyle(.checklistRow)
                            .accessibilityAddTraits(store.projectID == project.id && [.tasks, .epics, .archived].contains(store.page) ? .isSelected : [])
                            .help(project.string("name"))
                            .listRowBackground(store.projectID == project.id && [.tasks, .epics, .archived].contains(store.page) ? Color.checklistAccent.opacity(0.13) : Color.clear)
                            .contextMenu {
                                Button("Settings…") { store.open(.project(project.id)) }
                                Button("Epics") { store.select(.epics, project: project.id) }
                                Button("Done / Archived") { store.select(.archived, project: project.id) }
                                Divider()
                                Button("Archive Project…") { confirmation = Confirmations.archiveProject(project.string("name")) { store.setProjectArchived(project, archived: true) } }
                            }
                    }
                    Button { store.showNewProject = true } label: { Label("Add Project…", systemImage: "plus").checklistFont(.body).foregroundStyle(Color.checklistSecondaryText).padding(.vertical, Spacing.tight).padding(.horizontal, Spacing.tight).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.checklistRow)
                    if !store.archivedProjects.isEmpty {
                        DisclosureGroup(isExpanded: $showArchivedProjects) {
                            ForEach(store.archivedProjects) { project in archivedProjectRow(project) }
                        } label: {
                            Text("Archived projects (\(store.archivedProjects.count))").checklistFont(.body).foregroundStyle(Color.checklistSecondaryText)
                        }.accessibilityIdentifier("archivedProjects")
                    }
                } header: { Text("Projects").checklistFont(.captionEmphasis).foregroundStyle(Color.checklistSecondaryText) }
                Section {
                    navigation(.activity)
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            VStack(spacing: Spacing.control) {
                Divider()
                HStack(spacing: Spacing.small) {
                    Circle().fill(store.connected ? Color.checklistAccentText : .orange).frame(width: 7, height: 7)
                    Text(store.connected ? "Service connected" : "Service disconnected").checklistFont(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    HStack(spacing: Spacing.small) {
                        if store.sidebarLoading || (store.page == .media && mediaLoading) { ProgressView().controlSize(.mini).frame(width: 28, height: 28) }
                        else { Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.checklistIcon).foregroundStyle(Color.checklistSecondaryText).help("Refresh service").accessibilityLabel("Refresh service") }
                        Button(action: openSettings) { Image(systemName: "gearshape").frame(width: 28, height: 28) }.buttonStyle(.checklistIcon).foregroundStyle(Color.checklistSecondaryText).help("Checklist Settings").accessibilityLabel("Checklist Settings").accessibilityIdentifier("openChecklistSettings")
                    }.fixedSize()
                }.accessibilityIdentifier("sidebarServiceFooter")
            }.padding(.horizontal, Spacing.section).padding(.bottom, Spacing.group)
        }.background(.bar).checklistFont(.body).checklistConfirmation($confirmation)
            .onReceive(store.mediaReview.$loading) { mediaLoading = $0 }
    }
    /// An archived project stays readable; Restore brings it back to the active list with the same identity.
    func archivedProjectRow(_ project: Record) -> some View {
        AccessibleHStack(spacing: Spacing.row) {
            Button { store.select(.tasks, project: project.id) } label: {
                HStack(spacing: Spacing.row) {
                    ProjectIcon(project: project, size: 20).opacity(0.6)
                    Text(project.string("name")).lineLimit(1).foregroundStyle(Color.checklistSecondaryText)
                    Spacer(minLength: 0)
                }.checklistFont(.body).padding(.vertical, Spacing.compact).padding(.horizontal, Spacing.tight)
            }.buttonStyle(.checklistRow).help("Show the tickets of \(project.string("name"))")
            Button("Restore") { store.setProjectArchived(project, archived: false) }
                .buttonStyle(.checklistBordered).controlSize(.small)
                .checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
                .accessibilityLabel("Restore \(project.string("name"))")
        }
        .listRowBackground(store.projectID == project.id && [.tasks, .epics, .archived].contains(store.page) ? Color.checklistAccent.opacity(0.13) : Color.clear)
        .contextMenu {
            Button("Show Tickets") { store.select(.tasks, project: project.id) }
            Button("Restore Project") { store.setProjectArchived(project, archived: false) }
        }
    }
    func navigation(_ page: Page, count: Int = 0) -> some View {
        Button { store.select(page) } label: {
            HStack(spacing: Spacing.row) {
                Image(systemName: page.symbol).frame(width: 20)
                Text(page.title)
                Spacer(minLength: 0)
                if count > 0 { Text("\(count)").checklistFont(.captionStrong).foregroundStyle(.white).padding(.horizontal, Spacing.compact).padding(.vertical, Spacing.tight).background(Color.orange, in: Capsule()) }
            }.checklistFont(.body).padding(.vertical, Spacing.compact).padding(.horizontal, Spacing.tight)
        }.buttonStyle(.checklistRow).accessibilityAddTraits(store.page == page && store.projectID == nil ? .isSelected : []).listRowBackground(store.page == page && store.projectID == nil ? Color.checklistAccent.opacity(0.13) : Color.clear)
    }
}
