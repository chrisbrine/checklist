import SwiftUI

/// CL-58: a page-based list says whether it is offline, still loading, failed or really empty.
/// The page error itself shows in WorkspacePagingControls with its Refresh button.
struct WorkspaceListState: View {
    @EnvironmentObject var store: ChecklistStore
    let symbol: String
    let emptyTitle: String
    let emptyDetail: String
    var body: some View {
        if store.workspaceError != nil {
            EmptyView()
        } else if !store.workspacePageLoaded && store.showsOfflineBanner {
            EmptyState(symbol: "bolt.horizontal.circle", title: "Checklist is offline", detail: "This list loads when Checklist reconnects. Your drafts stay on this Mac.")
        } else if !store.workspacePageLoaded {
            ProgressView("Loading…").frame(maxWidth: .infinity).padding(.vertical, Spacing.group)
        } else {
            EmptyState(symbol: symbol, title: emptyTitle, detail: emptyDetail)
        }
    }
}

/// CL-58: the ticket choices of an Epic or Triage picker are offline, loading, failed, empty or present.
enum CandidateListState: Equatable {
    case offline, loading, failed(String), empty, choices
    init(loaded: Bool, loading: Bool, error: String?, offline: Bool, count: Int) {
        if loading { self = .loading }
        else if let error { self = offline ? .offline : .failed(error) }
        else if !loaded { self = offline ? .offline : .loading }
        else { self = count == 0 ? .empty : .choices }
    }
}

/// CL-58: an overlay whose record is missing says why instead of showing a blank panel.
struct DetailUnavailable: View {
    @EnvironmentObject var store: ChecklistStore
    let symbol: String
    let title: String
    var body: some View {
        if store.showsOfflineBanner {
            EmptyState(symbol: "bolt.horizontal.circle", title: "Checklist is offline", detail: "This detail loads when Checklist reconnects. Your drafts stay on this Mac.")
        } else if store.loading {
            ProgressView("Loading…").padding(Spacing.group)
        } else {
            VStack(spacing: Spacing.control) {
                EmptyState(symbol: symbol, title: title, detail: "It may be archived, removed or not loaded yet. Refresh to check its current state.")
                Button("Refresh") { Task { await store.refresh() } }
            }
        }
    }
}
