import SwiftUI

struct NeedsYouView: View {
    @EnvironmentObject var store: ChecklistStore
    @State private var selected = 0
    @State private var showSnoozed = false
    var requests: [Record] {selected == 0 ? store.workspaceRows : []}
    var yourTasks: [Record] {selected == 1 ? store.workspaceRows : []}
    var body: some View {
        let _ = NativeRenderMetrics.body(.needsYou)
        VStack(alignment: .leading, spacing: Spacing.section) {
            Text("Needs You").checklistFont(.pageTitle)
            Picker("View", selection: $selected) { Text("Requests · \(requests.count)").tag(0); Text("Your tickets · \(yourTasks.count)").tag(1) }.pickerStyle(.segmented).tint(.checklistAccent).checklistActionScroll()
            if selected == 0 {
                Toggle("Show snoozed requests", isOn: $showSnoozed).toggleStyle(.checkbox).checklistFont(.micro)
                WorkspacePagingControls()
                if requests.isEmpty { WorkspaceListState(symbol: "checkmark.bubble", emptyTitle: "You're all caught up", emptyDetail: "Agent questions, file requests and approvals will appear here.") }
                else {
                    ScrollView {
                        LazyVStack(spacing: Spacing.small) {
                            ForEach(requests) { request in
                                Button { store.open(.request(request.id)) } label: {
                                    AccessibleHStack(alignment: .top, spacing: Spacing.control) {
                                        Image(systemName: "bubble.left.and.bubble.right").checklistFont(.subheading).foregroundStyle(.orange).padding(.top, Spacing.tight)
                                        VStack(alignment: .leading, spacing: Spacing.small) {
                                            Text(request.string("title")).checklistFont(.bodyStrong).frame(maxWidth: .infinity, alignment: .leading)
                                            AccessibleHStack(spacing: Spacing.small) {
                                                Text(store.projectName(request.string("project_id")))
                                                Text(RequestRowPresentation.ticketLabel(request,task:store.task(request.string("task_id"))))
                                                    .foregroundStyle(request.bool("blocking") ? .orange : Color.checklistSecondaryText)
                                                Spacer(minLength:0)
                                                RequestAgeLabel(request:request)
                                            }.checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                                            AccessibleHStack(spacing: Spacing.compact) {
                                                ForEach(RequestRowPresentation.capabilities(request)) { capability in
                                                    Label(capability.rawValue,systemImage:capability.symbol)
                                                        .checklistFont(.micro).padding(.horizontal,Spacing.small).padding(.vertical,Spacing.tight)
                                                        .background(.primary.opacity(0.05),in:Capsule())
                                                }
                                            }
                                            Text("Requested by \(requesterLabel(request))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                                        }
                                        Image(systemName: "chevron.right").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                                    }.checklistCard(padding: Spacing.group)
                                }.buttonStyle(.checklistRow)
                            }
                        }
                    }
                }
            } else {
                WorkspacePagingControls()
                if yourTasks.isEmpty { WorkspaceListState(symbol: "person.crop.circle.badge.checkmark", emptyTitle: "No tickets assigned to you", emptyDetail: "Tickets assigned to you stay separate from questions agents need answered.") }
                else { ScrollView { LazyVStack { ForEach(yourTasks) { TaskRow(task: $0) } } } }
            }
        }.padding(Spacing.page)
        .focusedSceneValue(\.checklistTicketOrder, selected == 1 ? yourTasks.map(\.id) : [])
        .onAppear {store.configureWorkspace(surface:selected == 0 ? "requests" : "human_tasks",archived:showSnoozed)}
        .onChange(of:selected) {_,value in store.configureWorkspace(surface:value == 0 ? "requests" : "human_tasks",archived:showSnoozed)}
        .onChange(of:showSnoozed) {_,value in store.configureWorkspace(archived:value)}
    }
    func requesterLabel(_ request: Record) -> String {
        let explicit = request.string("requester_label")
        if !explicit.isEmpty && UUID(uuidString: explicit) == nil { return explicit }
        let id = request.string("requester_session_id")
        if id == "human" { return "You" }
        if let session = store.sessions.first(where: { $0.id == id }) {
            let label = session.string("native_conversation_title", fallback: session.string("label"))
            if !label.isEmpty && UUID(uuidString: label) == nil { return label }
        }
        return id.isEmpty ? "Agent" : "Agent · " + String(id.prefix(8))
    }

}

private struct RequestAgeLabel: View {
    let request: Record
    var body: some View {
        // A UI timeline keeps visible ages useful without polling the service or running work.
        TimelineView(.periodic(from:.now,by:60)) { context in
            Text(RequestRowPresentation.age(request,now:context.date))
                .help(request.string("created_at").isEmpty ? "Creation time was not recorded" : "Created \(relativeTime(request.string("created_at")))")
        }
    }
}
