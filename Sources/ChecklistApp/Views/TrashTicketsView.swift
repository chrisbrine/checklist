import SwiftUI

struct TrashTicketsView: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) private var dismiss
    @State private var page: TicketPage?
    @State private var loading = false
    @State private var failure: String?
    @State private var readID = UUID()
    @State private var preview: TicketPurgePreview?
    @State private var confirmPurge = false
    var query: TicketPageQuery {TicketPageQuery(surface:"trash",projectID:store.projectID,text:"",statusFilter:"all",tagFilter:"all",groupBy:"none",orderBy:"updated_desc")}
    var body: some View {
        VStack(alignment:.leading,spacing:Spacing.group) {
            HStack {Text("Trash").checklistFont(.sheetTitle);Spacer();Button("Close") {dismiss()}}
            Text("Trashed tickets keep their notes and connections. Restore returns them to their earlier status and archive visibility.").checklistFont(.callout).foregroundStyle(.secondary)
            if loading {ProgressView("Loading Trash…")}
            if let failure {Text(failure).foregroundStyle(.orange)}
            HStack {Button("Refresh") {load()};if let cursor = page?.previousCursor {Button("Previous page") {load(cursor)}};if let cursor = page?.nextCursor {Button("Next page") {load(cursor)}}}.checklistDisabled([(loading,"Trash is still loading.")])
            if let page {
                Text("\(page.matchedCount) tickets in Trash").checklistFont(.micro)
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:Spacing.group) {
                        ForEach(page.tasks) {ticket in
                            VStack(alignment:.leading,spacing:Spacing.small) {
                                Button(ticket.string("key") + " · " + ticket.string("title")) {store.open(.task(ticket.id));dismiss()}.buttonStyle(.link)
                                HStack {
                                    Button("Restore") {store.run("task_archive",["project_id":ticket.string("project_id"),"task_id":ticket.id,"expected_revision":ticket.integer("revision"),"action":"restore"],success:"Ticket restored") {_ in load()}}
                                    Button("Delete permanently…") {purgePreview(ticket)}
                                }.checklistDisabled([(store.busy,DisabledReasons.saving),(!store.connected,DisabledReasons.offline)])
                            }
                            Divider()
                        }
                    }
                }
            }

        }.padding(Spacing.page).frame(minHeight:440).checklistSheet(width:620).onAppear {load()}
            .onDisappear {readID = UUID()}
            .onChange(of:store.projectID) {_,_ in page = nil;load()}
            .onChange(of:store.storeIncarnation) {_,_ in page = nil;preview = nil;confirmPurge = false;load()}
            .sheet(item:$preview) {value in
                VStack(alignment:.leading,spacing:Spacing.group) {
                    Text("Delete ticket permanently").checklistFont(.sheetTitle)
                    Text(value.ticket.string("key") + " · " + value.ticket.string("title")).checklistFont(.bodyStrong)
                    Text("Removes the ticket's private content and \(value.removed) exclusively owned records, including notes, work attempts, requests, review and file records. Clears content from \(value.events) history entries while keeping their place.").checklistFont(.callout)
                    Text("Keeps a minimal Purged ticket reference, incoming connections, other tickets and \(value.shared) shared records. This cannot be undone.").checklistFont(.callout)
                    Text("All managed file bytes remain in this version. The preview includes \(value.managed) managed attachments with \(ByteCountFormatter.string(fromByteCount:value.originalBytes,countStyle:.file)) of original file sizes. External originals and workspace files are never deleted. This does not securely erase file contents.").checklistFont(.callout)
                    Text("Checklist knows of \(value.backups) earlier backup generations. Backups and exports made before this purge may contain this ticket. Checklist does not change them; delete those copies yourself if needed.").checklistFont(.callout)
                    if !value.creationTimes.isEmpty {Text("Recorded backup creation times: " + value.creationTimes.joined(separator:", ")).checklistFont(.micro)}
                    if !value.observedTimes.isEmpty {Text("Recorded backup observation times: " + value.observedTimes.joined(separator:", ")).checklistFont(.micro)}
                    HStack {Button("Keep ticket") {preview = nil};Spacer();Button("Delete permanently…",role:.destructive) {confirmPurge = true}.checklistDisabled([(store.busy,DisabledReasons.saving),(!store.connected,DisabledReasons.offline),(store.storeIncarnation != value.incarnation,"The store changed. Read a new preview.")])}
                }.padding(Spacing.page).checklistSheet(width:600)
                    .confirmationDialog("Delete this ticket permanently?",isPresented:$confirmPurge,titleVisibility:.visible) {
                        Button("Delete permanently",role:.destructive) {purge(value)}
                        Button("Cancel",role:.cancel) {}
                    } message: {Text("The ticket's private records will be removed. Managed file bytes, shared records, backups and exports remain. This cannot be undone.")}
            }
    }
    func load(_ cursor: String? = nil) {
        let requestID = UUID(),scope = store.storeIncarnation,requestedQuery = query
        readID = requestID;loading = true;failure = nil
        Task {
            do {
                let reply = try await store.request("task_list",requestedQuery.parameters(cursor:cursor))
                guard readID == requestID,scope == store.storeIncarnation,requestedQuery == query else {return}
                page = try TicketPage(response:reply);loading = false
            } catch {guard readID == requestID else {return};failure = PlainError.text(error);loading = false}
        }
    }
    func purgePreview(_ ticket: Record) {
        let incarnation = store.storeIncarnation
        store.run("task_purge_preview",["project_id":ticket.string("project_id"),"task_id":ticket.id,"expected_revision":ticket.integer("revision")]) {reply in
            guard incarnation == store.storeIncarnation else {return}
            do {preview = try TicketPurgePreview(reply:reply,ticket:ticket,incarnation:incarnation)} catch {store.error = PlainError.text(error)}
        }
    }
    func purge(_ value: TicketPurgePreview) {
        guard value.incarnation == store.storeIncarnation else {store.error = "The store changed. Read a new preview.";return}
        store.run("task_purge",value.parameters,success:"Ticket permanently removed; managed file bytes, shared records, backups and exports retained") {_ in preview = nil;load()}
    }
}
