import SwiftUI

struct EpicDetailView: View {
    @EnvironmentObject var store: ChecklistStore
    let epic: Record
    @State private var editing = false
    @State private var name = ""
    @State private var brief = ""
    @State private var showClosedTickets = false
    @State private var selectedTicket = ""
    @State private var moveCandidate: Record?
    var projectID: String { epic.string("project_id") }
    var tickets: [Record] {store.groupTaskRows}
    var visibleTickets: [Record] {tickets}
    var available: [Record] {store.groupCandidateRows}
    var completed: Int {epic.integer("done_count")}
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.page) {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Label("Epic", systemImage: "folder").checklistFont(.micro).foregroundStyle(Color.checklistAccentText)
                    Text(ProductionGroups.label(epic)).checklistFont(.pageTitle)
                    Text(store.projectName(projectID)).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    ProgressView(value: Double(completed), total: Double(max(epic.integer("ticket_count"),1))).tint(.checklistAccentText)
                    Text("\(completed) of \(epic.integer("ticket_count")) tickets done · \(tickets.filter { $0.string("status_category") == "parked" }.count) parked").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                }
                if editing {
                    DetailSection(title: "Epic brief") {
                        TextField("Epic name", text: $name).textFieldStyle(.roundedBorder).onChange(of: name) { _, _ in preserveDraft() }
                        TextEditor(text: $brief).checklistFont(.body).frame(minHeight: 110).padding(Spacing.compact).overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(.quaternary)).onChange(of: brief) { _, _ in preserveDraft() }
                        AccessibleHStack { Button("Cancel") { editing = false; store.windowPreferences.removeObject(forKey: draftKey) }; Spacer(); Button("Save brief") { store.run("epic_edit", ["project_id": projectID, "group_id": epic.id, "expected_revision": epic.integer("revision"), "name": name, "brief": brief, "purpose": brief], success: "Epic brief saved", completion: { _ in editing = false; store.windowPreferences.removeObject(forKey: draftKey) }) }.buttonStyle(.checklistProminent).checklistDisabled([(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Enter a name first."), (!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)]) }
                        Text("Draft saved on this Mac until applied").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    }
                } else {
                    DetailSection(title: "Brief & intended outcome") {
                        let context = epic.string("brief", fallback: epic.string("purpose"))
                        Text(context.isEmpty ? "Describe what this Epic is responsible for and the outcome its tickets support." : context).checklistFont(.callout).foregroundStyle(context.isEmpty ? Color.checklistSecondaryText : .primary).textSelection(.enabled)
                        Button("Edit brief…") { beginEdit() }.checklistFont(.micro)
                    }
                }
                Divider()
                AccessibleHStack {
                    Text("Contained tickets").checklistFont(.bodyStrong)
                    Spacer()
                    Button { store.captureEpicID = epic.id; store.showCapture = true } label: { Label("Ticket", systemImage: "plus") }.buttonStyle(.checklistBordered).checklistDisabled([(!store.connected, DisabledReasons.offline)])
                }
                Picker("Contained ticket visibility", selection: $showClosedTickets) {
                    Text("Incomplete").tag(false)
                    Text("Done / Archived").tag(true)
                }.pickerStyle(.segmented).tint(.checklistAccent).accessibilityIdentifier("epicTicketVisibility")
                GroupTaskPagingControls(group:epic,closed:showClosedTickets)
                if visibleTickets.isEmpty && !store.groupTaskLoading && store.groupTaskError == nil { Text(showClosedTickets ? "No completed, canceled or archived tickets in this Epic." : "No incomplete tickets in this Epic. Use Done / Archived to inspect closed work.").checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText) }
                ForEach(ProductionGroups.taskKinds, id: \.self) { kind in
                    let kindTickets = RecordOrdering.newestFirst(visibleTickets.filter { $0.string("kind", fallback: "work") == kind }, timestamp: "updated_at")
                    if !kindTickets.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            SectionCaption(title: ProductionGroups.kindLabel(kind), count: kindTickets.count)
                            ForEach(kindTickets) { task in EpicTicketRow(task: task, epic: epic) }
                        }
                    }
                }
                Divider()
                DetailSection(title: "Move an existing ticket into this Epic") {
                    GroupCandidatePagingControls(group:epic,closed:showClosedTickets)
                    Picker("Ticket", selection: $selectedTicket) { Text("Choose ticket").tag(""); ForEach(available) { task in Text("\(task.string("key")) · \(task.string("title"))").tag(task.id) } }.labelsHidden()
                    if let task = available.first(where: { $0.id == selectedTicket }) {
                        let previous = store.groups.first { $0.id == task.string("epic_id") }
                        Text(previous == nil ? "This ticket currently has no Epic." : "Currently in \(ProductionGroups.label(previous!)). Moving changes its Epic; its Triage memberships stay as they are.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    }
                    Button("Move ticket here") {
                        guard let task = available.first(where: { $0.id == selectedTicket }) else { return }
                        if task.string("epic_id").isEmpty { add(task) } else { moveCandidate = task }
                    }.checklistDisabled([(selectedTicket.isEmpty, "Choose a ticket first."), (!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
                }
            }.padding(Spacing.page)
        }.onAppear {store.loadGroupTasks(epic,closed:showClosedTickets);store.loadGroupCandidates(epic,closed:showClosedTickets)}.onChange(of:showClosedTickets) {_,value in selectedTicket="";store.loadGroupTasks(epic,closed:value);store.loadGroupCandidates(epic,closed:value)}.confirmationDialog("Move this ticket to this Epic?", isPresented: Binding(get: { moveCandidate != nil }, set: { if !$0 { moveCandidate = nil } }), titleVisibility: .visible) {
            Button("Move to \(ProductionGroups.label(epic))") { if let task = moveCandidate { add(task) }; moveCandidate = nil }
            Button("Cancel", role: .cancel) { moveCandidate = nil }
        } message: { Text("The ticket will leave its previous Epic and become part of this Epic. Its Triages and work history stay intact.") }
    }
    var draftKey: String { "epicBriefDraft-" + epic.id }
    func beginEdit() {
        let saved = store.windowPreferences.dictionary(forKey: draftKey) as? [String: String]
        name = saved?["name"] ?? epic.string("name")
        brief = saved?["brief"] ?? epic.string("brief", fallback: epic.string("purpose"))
        editing = true
    }
    func preserveDraft() { if editing { store.windowPreferences.set(["name": name, "brief": brief], forKey: draftKey) } }
    func add(_ task: Record) {
        var params: [String: Any] = ["project_id": projectID, "group_id": epic.id, "task_id": task.id, "action": task.string("epic_id").isEmpty ? "add" : "move", "expected_revision": epic.integer("revision"), "expected_task_revision": task.integer("revision")]
        if !task.string("epic_id").isEmpty {
            params["from_epic_id"] = task.string("epic_id")
            if let previous = store.groups.first(where: { $0.id == task.string("epic_id") }) { params["from_epic_revision"] = previous.integer("revision") }
        }
        store.run("group_membership", params, success: "Ticket moved into this Epic", completion: { _ in selectedTicket = "" })
    }
}

private struct EpicTicketRow: View {
    @EnvironmentObject var store: ChecklistStore
    let task: Record
    let epic: Record
    @State private var confirmation: PendingConfirmation?
    var body: some View { confirmableBody.checklistConfirmation($confirmation) }
    @ViewBuilder var confirmableBody: some View {
        Button { store.open(.task(task.id)) } label: {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(task.string("title")).checklistFont(.bodyEmphasis).frame(maxWidth: .infinity, alignment: .leading)
                AccessibleHStack { Text(task.string("key")).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText); Spacer(); TicketStatusPills(task: task); if task.bool("archived") { Image(systemName: "archivebox").foregroundStyle(Color.checklistSecondaryText) } }
                TicketStatusReasonLine(task:task)
            }.checklistCard(padding: Card.padding)
        }.buttonStyle(.checklistRow).contextMenu {
            Button("Open ticket") { store.open(.task(task.id)) }
            Button("Remove from this Epic…") { confirmation = Confirmations.removeFromEpic(task.string("key")) { store.run("group_membership", ["project_id": epic.string("project_id"), "group_id": epic.id, "task_id": task.id, "action": "remove", "expected_revision": epic.integer("revision"), "expected_task_revision": task.integer("revision")], success: "Ticket removed from this Epic; Triages unchanged") } }.checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
        }
    }
}

struct GroupTaskPagingControls: View {
    @EnvironmentObject var store: ChecklistStore
    let group:Record
    let closed:Bool
    var body:some View {
        VStack(alignment:.leading) {
            if store.groupTaskLoading {ProgressView("Loading tickets…")}
            if let error=store.groupTaskError {Text(error).checklistFont(.micro).foregroundStyle(.orange);Button("Retry tickets") {store.loadGroupTasks(group,closed:closed)}}
            AccessibleHStack {Text("\(store.groupTaskRows.count) shown · \(store.groupTaskTotal) matching").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText);Spacer();if let c=store.groupTaskPrevious {Button("Previous") {store.loadGroupTasks(group,closed:closed,cursor:c)}};if let c=store.groupTaskNext {Button("Next") {store.loadGroupTasks(group,closed:closed,cursor:c)}}}.checklistDisabled([(store.groupTaskLoading, "The page is still loading.")])
        }
    }
}
struct GroupCandidatePagingControls:View {
    @EnvironmentObject var store:ChecklistStore
    let group:Record
    let closed:Bool
    var state: CandidateListState {
        CandidateListState(loaded: store.groupCandidatesLoaded, loading: store.groupCandidateLoading, error: store.groupCandidateError,
                           offline: store.showsOfflineBanner, count: store.groupCandidateRows.count)
    }
    var body:some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            switch state {
            case .offline: Text("Ticket choices load when Checklist reconnects.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            case .loading: ProgressView("Loading ticket choices…").controlSize(.small)
            case .failed(let error): Text(error).checklistFont(.micro).foregroundStyle(.orange); Button("Retry choices") {store.loadGroupCandidates(group,closed:closed)}
            case .empty: Text(group.string("kind") == "epic" ? "No other ticket in this project can move into this Epic." : "No other ticket in this project can be added to this Triage.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            case .choices: EmptyView()
            }
            if store.groupCandidatePrevious != nil || store.groupCandidateNext != nil {
                AccessibleHStack {if let c=store.groupCandidatePrevious {Button("Previous choices") {store.loadGroupCandidates(group,closed:closed,cursor:c)}};if let c=store.groupCandidateNext {Button("More choices") {store.loadGroupCandidates(group,closed:closed,cursor:c)}}}
                    .checklistDisabled([(store.groupCandidateLoading, "The choices are still loading.")])
            }
        }
    }
}
