import SwiftUI

/// Selection starts immediately. An NSMenu waits for its tracking/dismissal
/// sequence before dispatching an item, outside the content navigation clock.
struct ProjectPicker: View {
    @EnvironmentObject var store: ChecklistStore
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: Spacing.small) {
                if let project = store.currentProject { ProjectIcon(project: project, size: 18) }
                else { Image(systemName: "folder") }
                Text(store.currentProject?.string("name") ?? "All projects")
                Image(systemName: "chevron.down").checklistFont(.micro)
            }
        }.buttonStyle(.automatic).accessibilityIdentifier("projectPicker")
            .help("Switch project")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                ProjectPickerChoices(dismiss: { presented = false }).environmentObject(store)
            }
    }
}

struct ProjectPickerChoices: View {
    @EnvironmentObject var store: ChecklistStore
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.small) {
                    Button("All projects") { select(nil) }.accessibilityIdentifier("projectChoice-all")
                    ForEach(store.activeProjects) { project in
                        Button { select(project.id) } label: {
                            HStack(spacing: Spacing.small) {
                                ProjectIcon(project: project, size: 18)
                                Text(project.string("name"))
                                Spacer()
                                if store.projectID.map(RecordIdentity.init) == RecordIdentity(project.id) {
                                    Image(systemName: "checkmark").accessibilityLabel("Selected project")
                                }
                            }
                        }.accessibilityIdentifier("projectChoice-\(project.id)")
                    }
                }
            }.frame(maxHeight: 280)
            Divider()
            Button("New Project…") { dismiss(); store.showNewProject = true }
            if let id = store.projectID {
                Button("Project Settings…") {
                    // Commit picker dismissal and receipt content together;
                    // native popover animation must not hold the settings frame.
                    var transaction = Transaction(animation:nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {dismiss();store.open(.project(id))}
                }
            }
        }.buttonStyle(.checklistRow).padding(Spacing.control).frame(width: 260)
    }

    private func select(_ project: String?) {
        // Begin navigation in the button action, before presentation teardown.
        store.select(.tasks, project: project)
        dismiss()
    }
}
