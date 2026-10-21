import SwiftUI

/// CL-130 text for an archived project, shared by the ticket list notice and Project settings.
enum ProjectArchiveText {
    static let archivedNotice = "This project is archived. Its tickets, notes, files and history stay readable, but nobody can change them or start work until you restore the project."
    static let archiveHelp = "Archive a finished or paused project. It leaves the sidebar and the Overview; its tickets, notes, files, history and workspace folder stay unchanged. Archive needs no active work and no open owner requests."
}

/// A notice above the ticket and Epic lists of an archived project, with the restore action.
struct ArchivedProjectNotice: View {
    @EnvironmentObject var store: ChecklistStore
    var body: some View {
        if let id = store.projectID, let project = store.archivedProjects.first(where: { RecordIdentity($0.id) == RecordIdentity(id) }) {
            AccessibleHStack(spacing: Spacing.small) {
                Image(systemName: "archivebox").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(ProjectArchiveText.archivedNotice).checklistFont(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.small)
                Button("Restore project") { store.setProjectArchived(project, archived: false) }
                    .buttonStyle(.checklistBordered)
                    .checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
            }
            .padding(.horizontal, Spacing.page).padding(.vertical, Spacing.control)
            .background(Color.orange.opacity(0.12))
            .accessibilityElement(children: .contain).accessibilityIdentifier("archivedProjectNotice")
        }
    }
}
