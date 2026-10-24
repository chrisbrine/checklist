import SwiftUI

/// The current Epic stays visible even when it is outside the bounded choice page.
struct TicketEpicSection: View {
    @EnvironmentObject var store: ChecklistStore
    let task: Record
    @State private var selection = ""
    @State private var choices: [Record] = []
    @State private var next: String?
    @State private var previous: String?
    @State private var loading = false
    @State private var failure: String?
    @State private var read = UUID()
    var current: Record? { store.detailRecords("groups",task:task).first {$0.id == task.string("epic_id") && $0.string("kind") == "epic"} }
    var body: some View {
        DetailSection(title: "Epic · required") {
            if let current {
                Button {store.open(.group(current.id))} label: {Label(ProductionGroups.label(current),systemImage:"folder")}.buttonStyle(.link)
            } else if task.string("epic_id").isEmpty {
                Text("This older ticket needs a primary Epic before its details can be saved.").checklistFont(.callout).foregroundStyle(.orange)
            } else {Text("The current Epic is unavailable. Refresh this ticket before moving it.").checklistFont(.micro).foregroundStyle(.orange)}
            Picker("Primary Epic",selection:$selection) {
                Text("Choose an Epic").tag("")
                if let current,!choices.contains(where: {$0.id == current.id}) {Text(ProductionGroups.label(current)).tag(current.id)}
                ForEach(choices) {Text(ProductionGroups.label($0)).tag($0.id)}
            }.checklistDisabled([(loading,"Epics are still loading.")])
            AccessibleHStack {
                if loading {ProgressView().controlSize(.small)}
                if let previous {Button("Previous Epics") {Task {await load(cursor:previous)}}}
                if let next {Button("More Epics") {Task {await load(cursor:next)}}}
                Spacer()
                Button(task.string("epic_id").isEmpty ? "Set Epic" : "Move to Epic") {save()}
                    .checklistDisabled([(selection.isEmpty,"Choose an Epic first."),(selection == task.string("epic_id"),"This is already the primary Epic."),(loading,"Epics are still loading."),(!store.connected,DisabledReasons.offline),(store.busy,DisabledReasons.saving),(!store.selectedTicketCurrent(task.id),DisabledReasons.ticketLoading),(!task.string("epic_id").isEmpty && current == nil,"Refresh the current Epic before moving this ticket.")])
            }.checklistFont(.micro)
            if let failure {Text(failure).checklistFont(.micro).foregroundStyle(.orange);Button("Retry Epics") {Task {await load()}}}
        }.task(id:task.id) {selection=task.string("epic_id");await load()}
            .onDisappear {read=UUID()}
    }
    func load(cursor:String? = nil) async {
        let token=UUID(),project=task.string("project_id"),incarnation=store.storeIncarnation;read=token;loading=true;failure=nil
        do {
            let query=WorkspacePageQuery(surface:"epics",project:project)
            let page=try WorkspacePage(await store.request("workspace_page",query.parameters(cursor:cursor)),query:query)
            guard !Task.isCancelled,read==token,store.storeIncarnation==incarnation else {return}
            choices=page.rows;next=page.next;previous=page.previous;loading=false
        } catch {if read==token {loading=false;failure="Could not load Epic choices. The current Epic is kept."}}
    }
    func save() {
        guard let target=choices.first(where: {$0.id == selection}) else {return}
        let project=task.string("project_id")
        if task.string("epic_id").isEmpty {
            store.run("task_edit",["project_id":project,"task_id":task.id,"expected_revision":task.integer("revision"),"patch":["epic_id":target.id]],success:"Primary Epic set")
        } else if let current {
            store.run("group_membership",["project_id":project,"group_id":target.id,"expected_revision":target.integer("revision"),"task_id":task.id,"expected_task_revision":task.integer("revision"),"action":"move","from_epic_id":current.id,"from_epic_revision":current.integer("revision")],success:"Ticket moved to Epic")
        }
    }
}
