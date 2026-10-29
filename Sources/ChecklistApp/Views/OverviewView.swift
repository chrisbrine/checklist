import SwiftUI
import ChecklistIPC

/// CL-53, CL-66, CL-67: Overview answers "what needs me today". It shows who works now, groups tickets
/// by what needs the owner (each group with its count and Show all), the latest review results and
/// a digest of tickets completed since the last visit. It reads existing records only.
struct OverviewView: View {
    @EnvironmentObject var store: ChecklistStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.page) {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text("Overview").checklistFont(.pageTitle)
                    Text(store.projectID.map { store.projectName($0) } ?? "All projects").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                }
                if let focus = store.overviewFocus {
                    Button { store.overviewFocus = nil } label: { Label("Overview", systemImage: "chevron.left") }.buttonStyle(.link)
                    if focus == "recent_reviews" { LatestReviewResults(focused: true) }
                    else { OverviewGroupSection(surface: focus, title: ChecklistStore.overviewTitle(focus), focused: true) }
                } else {
                    WorkingNowStrip()
                    ForEach(ChecklistStore.overviewGroups, id: \.surface) { group in
                        OverviewGroupSection(surface: group.surface, title: group.title, focused: false)
                    }
                    LatestReviewResults()
                    CompletionDigest()
                }
            }.padding(Spacing.page).frame(maxWidth: .infinity, alignment: .leading)
        }
        .screenContentFrame(store.screenTiming, .overview, ready: store.page == .overview && store.screenContentReady)
        .screenContentFrame(store.screenTiming, .projectSwitch, ready: store.page == .overview && store.screenContentReady)
        .onAppear { store.beginOverviewVisit() }
        .onDisappear { store.endOverviewVisit() }
    }
}

/// One need group: its exact count, its first rows and Show all; focused, it pages through every row.
struct OverviewGroupSection: View {
    @EnvironmentObject var store: ChecklistStore
    let surface: String
    let title: String
    let focused: Bool
    var observation: WorkspacePageObservation? { store.overviewObservations[surface] }
    var body: some View {
        let page = observation?.page
        VStack(alignment: .leading, spacing: Spacing.small) {
            AccessibleHStack {
                SectionCaption(title: title, count: page?.total ?? 0)
                Spacer()
                if !focused, let page, page.total > 0 {
                    Button(page.total > page.rows.count ? "Show all \(page.total)" : "Show all") {
                        if surface == "requests" { store.select(.needsYou, project: store.projectID) } else { store.overviewFocus = surface }
                    }.buttonStyle(.link).checklistFont(.micro).accessibilityLabel("Show all \(title)")
                }
            }
            if observation?.error != nil, page != nil {
                // A refresh failed over earlier rows (finding 310a34a7): say so instead of showing them as current.
                StaleNotice(upgrade: store.storageUpgradeStatus) { store.scheduleOverviewNeeds(only: surface, force: true) }
            }
            if let placeholder = Self.placeholder(observation, offline: store.showsOfflineBanner, upgrade: store.storageUpgradeStatus) {
                switch placeholder {
                case .failure(let error):
                    Text(error).checklistFont(.micro).foregroundStyle(.orange)
                    Button("Retry") { store.scheduleOverviewNeeds(only: surface, force: true) }.checklistFont(.micro)
                case .text(let text): Text(text).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                case .loading: ProgressView().controlSize(.small)
                }
            } else if let page, page.rows.isEmpty {
                Text(OverviewText.empty(surface)).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            } else if let page {
                ForEach(page.rows) { row in
                    if surface == "requests" { OverviewRequestRow(request: row) }
                    else {
                        VStack(alignment: .leading, spacing: Spacing.none) {
                            TaskRow(task: row)
                            if let work = OverviewText.work(row) {
                                Text(work.text).checklistFont(.micro).foregroundStyle(work.needsRecovery ? Color.orange : Color.checklistSecondaryText).padding(.leading, Spacing.control)
                            }
                        }
                    }
                }
                if focused && (page.previous != nil || page.next != nil) {
                    AccessibleHStack {
                        if let cursor = page.previous { Button("Previous") { store.moveOverviewPage(surface, cursor: cursor) } }
                        Spacer()
                        if let cursor = page.next { Button("Next") { store.moveOverviewPage(surface, cursor: cursor) } }
                    }.checklistDisabled([(observation?.loading == true, "The page is still loading.")])
                }
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
    /// CL-338: what the group shows while it has no page. A known store upgrade replaces both the
    /// reconnect text and the load error; a real outage keeps the reconnect text. Nil: the page shows.
    static func placeholder(_ observation: WorkspacePageObservation?, offline: Bool, upgrade: StorageUpgradeStatus?) -> SourcePlaceholder? {
        guard observation?.page == nil else { return nil }
        if let upgrade { return .text(OverviewUpgradeText.waiting("This group loads", upgrade)) }
        if let error = observation?.error { return .failure(error) }
        return offline ? .text("This group loads when Checklist reconnects.") : .loading
    }
}

/// CL-66: who works on which ticket now, from ticket attempts. Ended or unknown sessions show as
/// recovery needed, not as working. There is no worker catalog.
struct WorkingNowStrip: View {
    @EnvironmentObject var store: ChecklistStore
    var rows: [Record] {
        ["needs_active", "needs_quiet", "needs_recovery"].flatMap { store.overviewObservations[$0]?.page?.rows ?? [] }.filter { !$0.object("active_work").isEmpty }
    }
    static let sources = ["needs_active", "needs_quiet", "needs_recovery"]
    /// Rows not shown in the strip, per source group; each link opens its own group.
    func more(_ surface: String) -> Int {
        let page = store.overviewObservations[surface]?.page
        return max(0, (page?.total ?? 0) - (page?.rows.count ?? 0))
    }
    var state: SourceState { SourceState.of(Self.sources.map { store.overviewObservations[$0] }, offline: store.showsOfflineBanner, upgrade: store.storageUpgradeStatus) }
    /// The note above the strip's entries when not every source is current.
    static func partialNotice(_ state: SourceState) -> String? {
        switch state {
        case .stale: return "Could not refresh; showing the last loaded results."
        case .failed: return "Could not load all of who is working; some entries may be missing."
        case .loading: return "Still loading some of who is working."
        case .offline: return "Some entries load when Checklist reconnects."
        case .upgrading(let upgrade): return OverviewUpgradeText.partial(upgrade)
        case .loaded: return nil
        }
    }
    /// What the strip shows when it has no entries (CL-338: a known upgrade names its stage and estimate).
    static func placeholder(_ state: SourceState) -> SourcePlaceholder {
        switch state {
        case .loading: return .loading
        case .failed, .stale: return .failure("Could not load who is working now.")
        case .offline: return .text("Working now loads when Checklist reconnects.")
        case .upgrading(let upgrade): return .text(OverviewUpgradeText.waiting("Working now loads", upgrade))
        case .loaded: return .text("No agent is working on a ticket now.")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            SectionCaption(title: "Working now", count: rows.count)
            if rows.isEmpty {
                SourcePlaceholderView(placeholder: Self.placeholder(state)) { store.scheduleOverviewNeeds(force: true) }
            } else {
                // Entries can come from some sources while another failed, loads or waits (review finding 310a34a7).
                if let text = Self.partialNotice(state) {
                    if state == .stale || state == .failed { SourceFailure(text: text) { store.scheduleOverviewNeeds(force: true) } }
                    else { Text(text).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.small) {
                        ForEach(rows) { row in
                            let work = OverviewText.work(row)
                            Button { store.open(.task(row.id)) } label: {
                                VStack(alignment: .leading, spacing: Spacing.tight) {
                                    Text(row.string("key")).checklistFont(.captionStrong)
                                    Text(work?.text ?? "").checklistFont(.micro).foregroundStyle(work?.needsRecovery == true ? Color.orange : Color.checklistSecondaryText).lineLimit(2)
                                }.padding(Spacing.small).frame(width: 190, alignment: .leading)
                            }.buttonStyle(.checklistPlain).checklistCard()
                                .accessibilityLabel("\(row.string("key")), \(work?.text ?? "")").help(row.string("title"))
                        }
                        ForEach([("needs_active", "active"), ("needs_quiet", "stale"), ("needs_recovery", "in Recovery or blocked")], id: \.0) { surface, label in
                            if more(surface) > 0 { Button("\(more(surface)) more \(label)") { store.overviewFocus = surface }.buttonStyle(.link).checklistFont(.micro) }
                        }
                    }
                }
            }
        }
    }
}

/// CL-67: each project's latest review verdicts with time and reviewer.
struct LatestReviewResults: View {
    @EnvironmentObject var store: ChecklistStore
    /// Focused, the list pages through every project's latest verdicts (finding 1234fd5f).
    var focused = false
    var body: some View {
        let observation = store.overviewObservations["recent_reviews"], page = observation?.page
        let rows = page?.rows ?? []
        let state = SourceState.of([observation], offline: store.showsOfflineBanner, upgrade: store.storageUpgradeStatus)
        VStack(alignment: .leading, spacing: Spacing.small) {
            AccessibleHStack {
                SectionCaption(title: "Latest review results", count: rows.count)
                Spacer()
                // A page holds the latest three verdicts of each project; more projects continue on the next page.
                if !focused, page?.next != nil {
                    Button("Show more projects") { store.overviewFocus = "recent_reviews" }.buttonStyle(.link).checklistFont(.micro)
                }
            }
            if rows.isEmpty {
                SourcePlaceholderView(placeholder: Self.placeholder(state)) { store.scheduleOverviewNeeds(only: focused ? "recent_reviews" : nil, force: true) }
            } else if state == .stale || state.upgrade != nil {
                StaleNotice(upgrade: state.upgrade) { store.scheduleOverviewNeeds(only: focused ? "recent_reviews" : nil, force: true) }
            }
            ForEach(OverviewText.byProject(rows), id: \.0) { project, verdicts in
                if store.projectID == nil { Text(store.projectName(project)).checklistFont(.microEmphasis).foregroundStyle(Color.checklistSecondaryText) }
                ForEach(verdicts.prefix(3)) { review in
                    Button { store.open(.task(review.string("task_id"))) } label: {
                        HStack(spacing: Spacing.small) {
                            StatusPill(name: OverviewText.verdict(review.string("verdict")), category: review.string("verdict") == "pass" ? "done" : "blocked")
                            Text("\(review.string("task_key")) · \(review.string("task_title"))").checklistFont(.callout).lineLimit(1)
                            Spacer()
                            Text("\(review.string("reviewer", fallback: "Reviewer")) · \(relativeTime(review.string("created_at")))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText).lineLimit(1)
                        }.padding(.vertical, Spacing.tight).contentShape(Rectangle())
                    }.buttonStyle(.checklistPlain).checklistDisabled([(review.string("task_id").isEmpty, "This verdict has no ticket.")])
                }
            }
            if focused, let page, page.previous != nil || page.next != nil {
                AccessibleHStack {
                    if let cursor = page.previous { Button("Previous projects") { store.moveOverviewPage("recent_reviews", cursor: cursor) } }
                    Spacer()
                    if let cursor = page.next { Button("More projects") { store.moveOverviewPage("recent_reviews", cursor: cursor) } }
                }.checklistDisabled([(observation?.loading == true, "The page is still loading.")])
            }
        }
    }
    /// What the section shows when it has no verdicts (CL-338: a known upgrade names its stage and estimate).
    static func placeholder(_ state: SourceState) -> SourcePlaceholder {
        switch state {
        case .loading: return .loading
        case .failed, .stale: return .failure("Could not load the latest review results.")
        case .offline: return .text("Review results load when Checklist reconnects.")
        case .upgrading(let upgrade): return .text(OverviewUpgradeText.waiting("Review results load", upgrade))
        case .loaded: return .text("No review results yet.")
        }
    }
}

/// CL-67: tickets completed since the owner's previous Overview visit, one line each. It stays in the app.
struct CompletionDigest: View {
    @EnvironmentObject var store: ChecklistStore
    var body: some View {
        let page = store.overviewObservations["completed_since"]?.page
        let since = store.overviewDigestSince.map { relativeTime(ISO8601DateFormatter().string(from: $0)) } ?? ""
        VStack(alignment: .leading, spacing: Spacing.small) {
            AccessibleHStack {
                SectionCaption(title: "Completed since your last visit", count: page?.total ?? 0)
                Spacer()
                if let page, page.total > page.rows.count {
                    Button("Show all \(page.total)") { store.overviewFocus = "completed_since" }.buttonStyle(.link).checklistFont(.micro)
                } else if (page?.total ?? 0) > 0 {
                    // Clear only once every completion is on screen, so it never hides unseen lines.
                    Button("Clear") { store.clearOverviewDigest() }.buttonStyle(.link).checklistFont(.micro)
                }
            }
            if page == nil {
                SourcePlaceholderView(placeholder: Self.placeholder(SourceState.of([store.overviewObservations["completed_since"]], offline: store.showsOfflineBanner, upgrade: store.storageUpgradeStatus))) {
                    store.scheduleOverviewNeeds(only: "completed_since", force: true)
                }
            } else if store.overviewObservations["completed_since"]?.error != nil {
                StaleNotice(upgrade: store.storageUpgradeStatus) { store.scheduleOverviewNeeds(only: "completed_since", force: true) }
            }
            if let page, page.rows.isEmpty, store.overviewObservations["completed_since"]?.error == nil {
                Text(since.isEmpty ? "Nothing completed since your last visit." : "Nothing completed since your last visit (\(since)).").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }
            ForEach(page?.rows ?? []) { task in
                Button { store.open(.task(task.id)) } label: {
                    HStack(spacing: Spacing.small) {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green).accessibilityHidden(true)
                        Text("\(task.string("key")) · \(task.string("title"))").checklistFont(.callout).lineLimit(1)
                        Spacer()
                        Text(relativeTime(task.string("completed_at"))).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    }.padding(.vertical, Spacing.tight).contentShape(Rectangle())
                }.buttonStyle(.checklistPlain)
            }
        }
    }
    /// What the digest shows while it has no page (CL-338: a known upgrade names its stage and estimate).
    static func placeholder(_ state: SourceState) -> SourcePlaceholder {
        switch state {
        case .loading, .loaded: return .loading
        case .failed, .stale: return .failure("Could not load the completed tickets.")
        case .offline: return .text("The digest loads when Checklist reconnects.")
        case .upgrading(let upgrade): return .text(OverviewUpgradeText.waiting("The digest loads", upgrade))
        }
    }
}

struct OverviewRequestRow: View {
    @EnvironmentObject var store: ChecklistStore
    let request: Record
    var body: some View {
        Button { store.open(.request(request.id)) } label: {
            HStack(spacing: Spacing.row) {
                Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.orange).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(request.string("title")).checklistFont(.bodyEmphasis).lineLimit(2)
                    Text([store.projectID == nil ? store.projectName(request.string("project_id")) : "", request.string("task_key"), request.bool("blocking") ? "Blocks work" : ""]
                        .filter { !$0.isEmpty }.joined(separator: " · ")).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                }
                Spacer()
                Text(relativeTime(request.string("created_at"))).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }.padding(.vertical, Spacing.small).contentShape(Rectangle())
        }.buttonStyle(.checklistPlain)
    }
}

/// Plain Overview text from service rows (tested in OverviewTests).
enum OverviewText {
    static func empty(_ surface: String) -> String {
        switch surface {
        case "requests": return "No request waits for your answer."
        case "needs_review": return "No ticket waits for review."
        case "needs_pickup": return "No Ready ticket waits for pickup."
        case "needs_active": return "No ticket is being worked on."
        case "needs_recovery": return "No ticket is blocked or needs recovery."
        case "needs_quiet": return "Every active ticket has a recent checkpoint."
        default: return "No ticket was completed today."
        }
    }
    static func verdict(_ value: String) -> String { ["pass": "Passed", "reject": "Changes needed", "blocked": "Blocked"][value] ?? GlossaryText.title(value) }
    /// Who works, and how recent the work is; ended, revoked or unknown sessions need recovery.
    static func work(_ row: Record) -> (text: String, needsRecovery: Bool)? {
        let work = Record(values: row.object("active_work"))
        guard !work.values.isEmpty else { return nil }
        let state = work.string("session_state")
        let agent = state == "owner" ? "You" : work.string("session_label").isEmpty ? (work.string("provider").isEmpty ? "Agent" : work.string("provider").capitalized) : work.string("session_label")
        let role = work.string("phase") == "review" ? "review" : "implementation"
        if ["ended", "revoked", "unknown"].contains(state) {
            return ("\(agent) · session \(state == "unknown" ? "unknown" : state) · recovery needed", true)
        }
        if !work.string("waiting_for_resource").isEmpty { return ("\(agent) · \(role) · waiting for \(work.string("waiting_for_resource"))", false) }
        let checkpoint = work.string("last_checkpoint")
        return ("\(agent) · \(role) · checkpoint \(checkpoint.isEmpty ? "not recorded" : relativeTime(checkpoint))", false)
    }
    static func byProject(_ rows: [Record]) -> [(String, [Record])] {
        var order: [String] = [], groups: [String: [Record]] = [:]
        for row in rows {
            let project = row.string("project_id")
            if groups[project] == nil { order.append(project) }
            groups[project, default: []].append(row)
        }
        return order.map { ($0, groups[$0]!) }
    }
}

/// CL-66, CL-67: whether a section's source pages are loading, failed, offline or loaded (truly empty when no rows).
enum SourceState: Equatable {
    /// `stale`: a refresh failed while earlier rows are still shown (review finding 310a34a7).
    case loading, failed, offline, stale, loaded
    /// CL-338: a known store upgrade keeps a source from loading or refreshing; it replaces offline,
    /// failed, loading and stale so the section names the upgrade stage and estimate.
    case upgrading(StorageUpgradeStatus)
    var upgrade: StorageUpgradeStatus? { if case .upgrading(let upgrade) = self { return upgrade }; return nil }
    @MainActor static func of(_ observations: [WorkspacePageObservation?], offline: Bool, upgrade: StorageUpgradeStatus? = nil) -> SourceState {
        if let upgrade, observations.contains(where: { $0?.page == nil || $0?.error != nil }) { return .upgrading(upgrade) }
        if observations.contains(where: { $0?.error != nil && $0?.page == nil }) { return offline ? .offline : .failed }
        if observations.contains(where: { $0?.page == nil }) { return offline ? .offline : .loading }
        if observations.contains(where: { $0?.error != nil }) { return .stale }
        return .loaded
    }
}

/// Shown above rows that a failed refresh could not update. During a known store upgrade it names
/// the upgrade instead of offering Retry (CL-338).
struct StaleNotice: View {
    var upgrade: StorageUpgradeStatus? = nil
    let retry: () -> Void
    var body: some View {
        if let upgrade { Text(OverviewUpgradeText.stale(upgrade)).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
        else { SourceFailure(text: "Could not refresh; showing the last loaded results.", retry: retry) }
    }
}

/// What a section shows in place of rows it cannot show yet.
enum SourcePlaceholder: Equatable {
    case loading
    case failure(String)
    case text(String)
}

struct SourcePlaceholderView: View {
    let placeholder: SourcePlaceholder
    let retry: () -> Void
    var body: some View {
        switch placeholder {
        case .loading: ProgressView().controlSize(.small)
        case .failure(let text): SourceFailure(text: text, retry: retry)
        case .text(let text): Text(text).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
        }
    }
}

/// CL-338: Overview text while a known store upgrade keeps its sources from loading. Like the sidebar
/// footer it names the stage and estimate, never the reconnect or load-error text of a real outage.
enum OverviewUpgradeText {
    static func waiting(_ subject: String, _ upgrade: StorageUpgradeStatus) -> String { "\(subject) after the upgrade. " + upgrade.summary }
    static func partial(_ upgrade: StorageUpgradeStatus) -> String { "Some entries load after the upgrade. " + upgrade.summary }
    static func stale(_ upgrade: StorageUpgradeStatus) -> String { "Showing the last loaded results. They refresh after the upgrade. " + upgrade.summary }
}

struct SourceFailure: View {
    let text: String
    let retry: () -> Void
    var body: some View {
        AccessibleHStack {
            Text(text).checklistFont(.micro).foregroundStyle(.orange)
            Button("Retry", action: retry).checklistFont(.micro)
        }
    }
}
