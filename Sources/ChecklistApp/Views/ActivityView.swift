import SwiftUI

struct ActivityView: View {
    @EnvironmentObject var store: ChecklistStore
    var body: some View {
        let _ = NativeRenderMetrics.body(.activity)
        VStack(alignment: .leading, spacing: Spacing.section) {
            Text("Activity").checklistFont(.pageTitle)
            WorkspacePagingControls()
            if store.workspaceRows.isEmpty { WorkspaceListState(symbol: "clock.arrow.circlepath", emptyTitle: "No activity yet", emptyDetail: "Changes to tickets, notes, requests and reviews in this view appear here.") }
            // The five-point event dot is decorative artwork, independent of text scale.
            ScrollView { LazyVStack(alignment: .leading, spacing: Spacing.none) { ForEach(store.workspaceRows) { event in AccessibleHStack(alignment: .top, spacing: Spacing.control) { Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(Color.checklistAccentText).padding(.top, Spacing.compact).accessibilityHidden(true); VStack(alignment: .leading, spacing: Spacing.compact) { Text(GlossaryText.humanize(event.string("type", fallback: event.string("kind", fallback: "Change")))).checklistFont(.bodyEmphasis); Text("\(store.projectName(event.string("project_id"))) · \(relativeTime(event.string("occurred_at", fallback: event.string("created_at"))))").checklistFont(.micro).foregroundStyle(.secondary) }; Spacer() }.padding(.vertical, Spacing.control); Divider() } } }
        }.padding(Spacing.page)
    }
}

struct WorkspacePagingControls: View {
    @EnvironmentObject var store: ChecklistStore
    var body: some View {
        VStack(alignment:.leading,spacing: Spacing.compact) {
            if store.workspaceLoading {ProgressView("Loading page…")}
            if let error=store.workspaceError {Text(error).checklistFont(.micro).foregroundStyle(.orange);Button("Refresh page") {store.retryWorkspacePage()}}
            AccessibleHStack {Text("\(store.workspaceRows.count) shown · \(store.workspaceTotal) matching").checklistFont(.micro).foregroundStyle(.secondary);Spacer();if let token=store.workspacePrevious {Button("Previous") {store.moveWorkspacePage(token)}};if let token=store.workspaceNext {Button("Next") {store.moveWorkspacePage(token)}}}.checklistDisabled([(store.workspaceLoading, "The page is still loading.")])
        }
    }
}
