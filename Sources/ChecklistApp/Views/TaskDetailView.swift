import SwiftUI
import AppKit
import ChecklistIPC

struct TaskDetailView: View {
    @EnvironmentObject var store: ChecklistStore
    let task: Record
    @Environment(\.checklistTextScale) private var textScale
    @State private var editing = false
    @State private var ticketUndo: TicketUndo?
    @State private var reasonStatus: Record?
    @State private var assignmentTarget: String?
    @State private var showingAssignmentReason = false
    @State private var title = ""
    @State private var brief = ""
    @State private var editBaseRevision = 0
    @State private var movedFromStatus = ""
    @State private var attachmentMode = "managed_copy"
    @StateObject private var archiveConfirmation = ArchiveConfirmationState()
    @State private var archiveRetry = UUID()
    @State private var handoffProvider: HandoffProvider?
    @State private var showWorkerAssignment = false
    @State private var eventHistory = SelectedEventHistory()
    @State private var mentionComposer = MentionComposerState()
    var project: String { task.string("project_id") }
    var messages: [Record] { RecordOrdering.newestFirst(store.detailRecords("messages",task:task).filter { $0.string("task_id") == task.id }, chronologicalInput: true) }
    var recipientChanged: Bool { store.noteDestinations[task.id] != task.string("active_attempt_id") || store.noteDraftNeedsReconciliation(task.id) }
    var destinationLabel: String {
        guard let expected = store.noteDestinations[task.id] else { return (store.noteDrafts[task.id] ?? "").isEmpty ? "Next pickup / current handlers" : "Choose current recipient" }
        if expected.isEmpty { return "Next pickup" }
        if let attempt = store.detailRecords("attempts",task:task).first(where: { $0.id == expected }) { return attempt.string("actor_display", fallback: attempt.string("session_id", fallback: "Current handler")) }
        return "Previous handler"
    }
    @State private var pendingAttachments:[CaptureAttachment]=[]
    @State private var statusConfirmation: PendingConfirmation?
    @State private var recordHistoryFamily = "attachment"
    var files: [Record] { store.detailRecords("attachments",task:task).filter { $0.string("task_id") == task.id && !$0.bool("unlinked") } }
    var body: some View {
        let _ = NativeRenderMetrics.body(.taskDetail)
        if task.bool("purged") {
            VStack(alignment:.leading,spacing:Spacing.group) {
                Text("Purged ticket").checklistFont(.sheetTitle)
                Text(task.string("key")).checklistFont(.bodyStrong)
                Text("This ticket was permanently removed. Its reference and history positions remain. Shared records, managed file bytes, backups and exports may remain.").checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText)
            }.padding(Spacing.page).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        } else {
        VStack(spacing: Spacing.none) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.page) {
                    header
                    TicketNextActionBar(task: task)
                    TicketRetirementControls(task:task,files:files,undo:$ticketUndo)
                    if store.selectedTicketLoading {ProgressView("Refreshing selected ticket…").controlSize(.small)}
                    if let failure = store.selectedTicketError {Text(failure).checklistFont(.micro).foregroundStyle(.orange);Button("Refresh selected ticket") {store.retrySelectedTicket()}}
                    if editing {
                        VStack(alignment: .leading, spacing: Spacing.small) {
                            TextField("Ticket title", text: $title).checklistFont(.subheading).textFieldStyle(.roundedBorder)
                            TextEditor(text: $brief).checklistFont(.body).frame(minHeight: 110).padding(Spacing.compact).overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(.quaternary))
                            if editNeedsReconciliation {
                                Text("This ticket changed after you started editing. Current title: \(task.string("title"))").checklistFont(.micro).foregroundStyle(.orange).textSelection(.enabled)
                                DisclosureGroup("Read current brief before keeping these edits") { Text(task.string("brief")).checklistFont(.micro).textSelection(.enabled) }
                                Button("Use the current ticket; keep my edits") { editBaseRevision = task.integer("revision"); persistEdit(hasChanges: true, reconcile: true) }.buttonStyle(.link)
                            }
                            DraftSaveStatusView(kind: "edit", draftID: task.id)
                            AccessibleHStack {
                                Button("Keep draft") { editing = false; persistEdit(hasChanges: true) }
                                Spacer()
                                Button("Save changes") { saveEdit() }.buttonStyle(.checklistProminent)
                                    .checklistDisabled([(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Enter a title first."), (task.string("epic_id").isEmpty, "Choose a primary Epic below before saving."), (editNeedsReconciliation, "The ticket changed after you started editing. Choose how to keep your edits first."), (!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving), (!store.selectedTicketCurrent(task.id), DisabledReasons.ticketLoading)])
                            }
                        }
                    } else {
                        DetailSection(title: "Brief") {
                            Text(task.string("brief").isEmpty ? "Add a brief and expected outcome so the next handler has useful context." : task.string("brief"))
                                .checklistFont(.body).foregroundStyle(task.string("brief").isEmpty ? Color.checklistSecondaryText : .primary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    StarterFieldsSection(task: task)
                    TicketEpicSection(task:task)
                    let handlingTriages = store.detailRecords("groups",task:task).filter { $0.string("kind") == "triage" && ($0.bool("selected_task_member") || $0.strings("task_ids").contains(task.id)) }
                    if !handlingTriages.isEmpty {
                        DetailSection(title: "Triages") { ForEach(handlingTriages) { triage in Button { store.open(.group(triage.id)) } label: { Label(ProductionGroups.label(triage), systemImage: "tray.2") }.buttonStyle(.link) } }
                    }
                    if store.fullSelectedRecordLoaded(task.id) {
                        if let failure = store.selectedRecordsError {Text(failure).checklistFont(.micro).foregroundStyle(.orange);Button("Refresh work & review records") {store.loadFullSelectedRecord(task.id)};Button("Refresh selected ticket") {store.retrySelectedTicket()}}
                        RelatedTicketsView(task: task).checklistDisabled([(!store.selectedRecordsCurrent, "Work and review records are still loading.")])
                        ReviewDetailView(task: task).checklistDisabled([(!store.selectedRecordsCurrent, "Work and review records are still loading.")])
                        HumanWorkActions(task: task).checklistDisabled([(!store.selectedRecordsCurrent, "Work and review records are still loading.")])
                    } else {
                        DetailSection(title:"Work, related tickets & review") {
                            Text("The selected ticket is loaded. Its complete review and work records have a separate loading boundary.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                            if let failure = store.selectedRecordsError {Text(failure).checklistFont(.micro).foregroundStyle(.orange);Button("Refresh selected ticket") {store.retrySelectedTicket()}}
                            Button("Load current work & review records") {store.loadFullSelectedRecord(task.id)}.checklistDisabled([(!store.connected, DisabledReasons.offline), (store.loading, "Checklist is still loading."), (store.selectedRecordsLoading, "Work and review records are still loading."), (!store.selectedTicketCurrent(task.id), DisabledReasons.ticketLoading)])
                        }
                    }
                    ArchiveCleanupSection(task:task)
                    recordHistorySection
                    if !files.isEmpty {
                        DetailSection(title: "Files & evidence · \(files.count) of \(store.selectedRecordCount("attachments",task:task))") { ForEach(files) { file in AttachmentRow(file: file) } }
                    }
                    if !task.strings("tag_ids").isEmpty {
                        DetailSection(title: "Tags") {
                            AccessibleHStack { ForEach(store.tags(project).filter { task.strings("tag_ids").contains($0.id) }) { tag in Text(tag.string("name")).checklistFont(.micro).padding(.horizontal, Spacing.small).padding(.vertical, Spacing.tight).background(Color.named(tag.string("color")).opacity(0.1), in: Capsule()) } }
                        }
                    }
                    let requests = store.detailRecords("requests",task:task).filter { !["answered","canceled","superseded","resolved"].contains(Canceled.normalized($0.string("state"))) }.filter { $0.string("task_id") == task.id }
                    if !requests.isEmpty {
                        DetailSection(title: "Waiting for you") {
                            ForEach(requests) { request in Button { store.open(.request(request.id)) } label: { Label(request.string("title"), systemImage: "bubble.left.and.bubble.right").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.checklistBordered) }
                        }
                    }
                    if store.fullSelectedRecordLoaded(task.id) {TaskSessionsView(task: task).checklistDisabled([(!store.selectedRecordsCurrent, "Work and review records are still loading."), (!store.selectedTicketCurrent(task.id), DisabledReasons.ticketLoading)])}
                    Divider()
                    DetailSection(title: "Conversation · \(messages.count) shown of \(store.selectedMessageCount) · newest first") {
                        AccessibleHStack {
                            Button("Newer messages") {if let cursor = store.selectedMessagePreviousCursor {store.moveSelectedMessages(cursor)}}.checklistDisabled([(store.selectedTicketLoading, "The ticket is still loading."), (store.selectedMessagePreviousCursor == nil, "There are no newer messages.")])
                            Button("Older messages") {if let cursor = store.selectedMessageNextCursor {store.moveSelectedMessages(cursor)}}.checklistDisabled([(store.selectedTicketLoading, "The ticket is still loading."), (store.selectedMessageNextCursor == nil, "There are no older messages.")])
                        }
                        if messages.isEmpty { Text("Notes and agent messages build the context for this ticket.").checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText) }
                        ForEach(messages) { message in MessageRow(message: message, task: task) }
                    }
                    let currentHistory = eventHistory.records(in:store.storeIncarnation)
                    let history = currentHistory ?? store.detailRecords("events",task:task)
                    DisclosureGroup(currentHistory == nil ? "Recent ticket history · \(history.count) events" : "Ticket history · \(history.count) events on this page") {
                        VStack(alignment:.leading,spacing: Spacing.small) {
                            if let failure = eventHistory.error {Text(failure).foregroundStyle(.orange)}
                            Button(currentHistory == nil ? "Read earlier ticket history" : "Later events") {readEventHistory()}
                                .checklistDisabled([(eventHistory.loading, "History is still loading."), ((currentHistory != nil && !eventHistory.hasMore), "There is no earlier history."), (!store.selectedTicketCurrent(task.id), DisabledReasons.ticketLoading)])
                            Button("Restart ticket history") {readEventHistory(fresh:true)}.checklistDisabled([(eventHistory.loading, "History is still loading."), (!store.selectedTicketCurrent(task.id), DisabledReasons.ticketLoading)])
                            ForEach(history) {event in
                                VStack(alignment:.leading,spacing: Spacing.hairline) {
                                    Text(event.string("type",fallback:event.string("kind"))).checklistFont(.microEmphasis)
                                    Text(relativeTime(event.string("occurred_at",fallback:event.string("created_at")))).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                                    if let reason = event.object("data")["reason"] as? String, !reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { Text(reason).checklistFont(.callout).textSelection(.enabled) }
                                }.frame(maxWidth:.infinity,alignment:.leading)
                            }
                        }.padding(.top,Spacing.small)
                    }.checklistFont(.micro)
                    if TextScale.usesInlineComposer(at: textScale) { Divider(); composer }
                }.padding(Spacing.page)
            }
            if !TextScale.usesInlineComposer(at: textScale) { Divider(); composer }
        }.onAppear {restoreEdit();eventHistory.observe(store:store.storeIncarnation)}
            .onChange(of:store.storeIncarnation) {_,incarnation in ticketUndo = nil;eventHistory.observe(store:incarnation)}
            .onDisappear {eventHistory.cancel()}
            .onAppear {observeMentionDraft()}
            .onChange(of: store.storeIncarnation) { _, _ in observeMentionDraft() }
            .onChange(of: task.id) { _, _ in ticketUndo = nil;mentionComposer.cancel(); observeMentionDraft() }
            .onChange(of: Array((store.noteDrafts[task.id] ?? "").utf8)) { _, _ in observeMentionDraft() }
            .onDisappear {mentionComposer.cancel()}
            .onChange(of: title) { _, _ in if editing { persistEdit(hasChanges: true) } }
            .onChange(of: brief) { _, _ in if editing { persistEdit(hasChanges: true) } }
            .onChange(of: task.string("status_id")) { _, _ in movedFromStatus = task.string("status_name") }
            .sheet(item:$reasonStatus) { status in TicketReasonSheet(task:task,status:status,onTransition:{result in ticketUndo = TicketUndo.transition(result,previous:task)}).environmentObject(store) }
            .sheet(isPresented:$showingAssignmentReason) {TicketReasonSheet(task:task,assignment:assignmentTarget).environmentObject(store)}
            .sheet(item: $handoffProvider) { provider in TaskHandoffSheet(task: task, provider: provider).id(TaskHandoffModel.Scope(task: task, provider: provider)).environmentObject(store) }
            .sheet(isPresented: $showWorkerAssignment) { TaskAssignmentSheet(task: task).environmentObject(store) }
            .task(id: ArchiveConfirmationState.LoadKey(scope: archiveScope, presented: archiveConfirmation.presented, retry: archiveRetry)) {
                guard archiveConfirmation.presented else { return }
                let scope = archiveScope
                await archiveConfirmation.load(scope) {
                    try await store.request("attachment_cleanup_preview", ["project_id": project, "task_id": task.id])
                }
            }
            .onChange(of: archiveConfirmation.presented) { _, presented in if !presented { archiveConfirmation.invalidate() } }
            .onChange(of: task.id) { _, _ in archiveConfirmation.cancel() }
            .onDisappear { archiveConfirmation.cancel() }
            .sheet(isPresented: $archiveConfirmation.presented) {
                ArchiveTicketSheet(preview: archiveConfirmation.preview(for: archiveScope),
                                   failure: archiveConfirmation.failure(for: archiveScope),
                                   blockedReason: store.writeBlockReason ?? (!archiveScope.selection.readable ? DisabledReasons.ticketLoading : nil),
                                   refresh: { archiveRetry = UUID() }) { clean, preview in
                    archiveConfirmation.presented = false
                    archive(clean: clean, preview: preview)
                }
            }
            .checklistConfirmation($statusConfirmation)
        }
    }
    func readEventHistory(fresh: Bool = false) {
        let read = eventHistory.begin(store:store.storeIncarnation,fresh:fresh)
        Task {
            do {
                var p: [String:Any] = ["project_id":project,"task_id":task.id,"limit":50]
                if let cursor = read.cursor {p["cursor"] = cursor}
                let result = try await store.request("history_list",p)
                guard store.selectedTicketCurrent(task.id) else {eventHistory.fail(read,resetCursor:false);return}
                try eventHistory.receive(result,for:read,currentStore:store.storeIncarnation)
            } catch {eventHistory.fail(read,resetCursor:(error as? ChecklistError)?.code == "CURSOR_RESET")}
        }
    }
    var header: some View {
        VStack(alignment: .leading, spacing: Spacing.control) {
            AccessibleHStack(alignment: .top) {
                Text(task.string("title")).checklistFont(.pageTitle).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button(store.taskEditDrafts[task.id]?.hasChanges == true ? "Resume edit draft…" : "Edit ticket…") { beginEdit() }
                    Menu("Assign") {
                        Button("Unassigned") { assign("unassigned") }
                        Button("Me") { assign("human") }
                        Button("Choose worker…") { showWorkerAssignment = true }.checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving), (!store.selectedTicketCurrent(task.id), DisabledReasons.ticketLoading)])
                    }
                    Menu("Status") {
                        ForEach(store.statuses(project).filter { !["active", "review", "done"].contains($0.string("category")) }) { status in
                            Button(Canceled.matches(status.string("category")) ? status.string("name") + "…" : status.string("name")) {
                                let change = { store.run("task_transition", ["project_id": project, "task_id": task.id, "status_id": status.id, "expected_revision": task.integer("revision")]) }
                                if Canceled.matches(status.string("category")) || ["done","completed","canceled"].contains(task.string("status_category")) { reasonStatus = status } else { change() }
                            }
                                .checklistDisabled([(!task.string("active_attempt_id").isEmpty, "Work on this ticket is active."), (!task.string("active_verification_request_id").isEmpty, "An owner check is active on this ticket."), (!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving), (!store.selectedTicketCurrent(task.id), DisabledReasons.ticketLoading)])
                        }
                        Divider()
                        Text("Work, review and completion use the ticket’s guarded actions.")
                    }
                    Menu("Tags") { ForEach(store.tags(project)) { tag in Button { var ids = task.strings("tag_ids"); if ids.contains(tag.id) { ids.removeAll { $0 == tag.id } } else { ids.append(tag.id) }; store.run("task_edit", ["project_id": project, "task_id": task.id, "expected_revision": task.integer("revision"), "tag_ids": ids]) } label: { if task.strings("tag_ids").contains(tag.id) { Label(tag.string("name"), systemImage: "checkmark") } else { Text(tag.string("name")) } } } }
                    Divider()
                    Button("Copy ticket key") { clipboard(task.string("key")) }
                    if task.bool("archived") { Button("Unarchive") { archive(clean: false) } } else { Button("Archive…") { prepareArchive() } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.button).buttonStyle(.checklistIcon).menuIndicator(.hidden).frame(width: 25).accessibilityLabel("Ticket actions").help("Ticket actions").checklistDisabled([(!store.selectedTicketCurrent(task.id), DisabledReasons.ticketLoading), (store.busy, DisabledReasons.saving), (!store.connected, DisabledReasons.offline)])
            }
            AccessibleHStack {
                TicketStatusPills(task: task)
                Text(handler).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                Spacer()
            }
            TicketStatusReasonDetail(task:task)
            if !movedFromStatus.isEmpty { Label("Moved to \(movedFromStatus). This ticket stays open.", systemImage: "arrow.turn.down.right").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
            if noLongerMatchesView { Text("No longer matches this view. This ticket stays open by its identity.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
            if task.bool("archived") { Label("Archived elsewhere · this ticket stays open", systemImage: "archivebox").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
            if task.bool("trashed") { Label("Trashed elsewhere · this ticket stays open", systemImage: "trash").checklistFont(.micro).foregroundStyle(.orange) }
            if store.detailRecords("groups",task:task).contains(where: { $0.string("kind") == "triage" && ($0.bool("selected_task_member") || $0.strings("task_ids").contains(task.id)) }) {
                Text("Changing this ticket's status takes it out of every Triage.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }
            AccessibleHStack(spacing: Spacing.small) {
                ForEach(HandoffProvider.workProviders()) { provider in
                    Button("Use in \(provider.name)") { handoffProvider = provider }
                }
            }.buttonStyle(.checklistBordered).controlSize(.small).checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving), (!store.selectedTicketCurrent(task.id), DisabledReasons.ticketLoading)])
            if !task.string("blocked_reason").isEmpty { Label(task.string("blocked_reason"), systemImage: "exclamationmark.circle").checklistFont(.callout).foregroundStyle(.orange) }
        }
    }
    var handler: String {
        if let attempt = store.detailRecords("attempts",task:task).first(where: { $0.id == task.string("active_attempt_id") }) {
            if attempt.string("session_id") == "human" { return "You are handling this" }
            if let session = store.detailRecords("sessions",task:task).first(where: { $0.id == attempt.string("session_id") }) {
                let label = session.string("native_conversation_title", fallback: session.string("label"))
                if !label.isEmpty && UUID(uuidString: label) == nil { return label }
                return session.string("provider", fallback: "Agent").capitalized + " · Current handler"
            }
            return "Current handler · details below"
        }
        let assignee = task.string("planned_assignee")
        if assignee == "human" || task.object("planned_assignee")["kind"] as? String == "human" { return "Assigned to you" }
        if let sessionID = task.object("planned_assignee")["session_id"] as? String, let session = store.workSessions.first(where: { $0.id == sessionID }) { return session.string("native_conversation_title", fallback: session.string("label", fallback: sessionID)) }
        return "Unassigned"
    }
    var recordHistorySection:some View {
        DisclosureGroup("Work, review & file history") {
            VStack(alignment:.leading,spacing: Spacing.row) {
                Text("One page is retained. Current action gates are checked separately above.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                Picker("History",selection:$recordHistoryFamily) {
                    Text("Files").tag("attachment");Text("Work attempts").tag("attempt");Text("Targets").tag("manifest");Text("Gate requests").tag("review_request");Text("Verdicts").tag("review");Text("Findings").tag("finding");Text("Finding responses").tag("finding_resolution");Text("Human requests").tag("request");Text("Source executions").tag("source_execution");Text("Ticket connections").tag("task_session");Text("Aliases").tag("task_alias")
                }.onChange(of:recordHistoryFamily) {_,value in store.readRecordHistory(task,family:value)}
                AccessibleHStack {Button("Read history") {store.readRecordHistory(task,family:recordHistoryFamily)};if let c=store.recordHistoryPrevious {Button("Newer") {store.readRecordHistory(task,family:recordHistoryFamily,cursor:c)}};if let c=store.recordHistoryNext {Button("Older") {store.readRecordHistory(task,family:recordHistoryFamily,cursor:c)}}}.checklistDisabled([(store.recordHistoryLoading, "History is still loading."), (!store.selectedTicketCurrent(task.id), DisabledReasons.ticketLoading)])
                if store.recordHistoryLoading {ProgressView("Loading history page…")}
                if let notice=store.recordHistoryNotice {Text(notice).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)}
                if let error=store.recordHistoryError {Text(error).checklistFont(.micro).foregroundStyle(.orange);Button("Refresh selected ticket") {store.retrySelectedTicket()}}
                Text("\(store.recordHistoryRows.count) shown · \(store.recordHistoryTotal) records").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                ForEach(store.recordHistoryRows) {record in
                    if record.string("record_type")=="attachment" {AttachmentRow(file:record)}
                    else {VStack(alignment:.leading,spacing:Spacing.tight) {Text(record.string("title",fallback:GlossaryText.humanize(record.string("record_type")).capitalized)+" · "+relativeTime(record.string("updated_at",fallback:record.string("created_at")))).checklistFont(.micro); TechnicalDetails([("Record", record.id)], raw: [("Record", record.values)])}}
                }
            }.padding(.top,Spacing.small)
        }
    }
    var composer: some View {
        NativeRenderMetrics.body(.noteComposer)
        return VStack(alignment: .leading, spacing: Spacing.small) {
            AttachmentCaptureSection(pending:$pendingAttachments,destination:Binding(get:{CaptureAttachmentDestination(storeIncarnation:store.storeIncarnation,projectID:project,taskID:task.id)},set:{_ in}),disabled:store.busy || !store.selectedTicketCurrent(task.id))
            if pendingAttachments.contains(where:{$0.destination == CaptureAttachmentDestination(storeIncarnation:store.storeIncarnation,projectID:project,taskID:task.id)}) {
                Button("Attach selected files") {
                    let destination=CaptureAttachmentDestination(storeIncarnation:store.storeIncarnation,projectID:project,taskID:task.id)
                    CaptureAttachmentUpload.send(pendingAttachments.filter {$0.destination==destination},projectID:project,taskID:task.id,store:store,accepted:{id in pendingAttachments.removeAll {$0.id==id}},completion:{})
                }.checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving), (!store.selectedTicketCurrent(task.id), DisabledReasons.ticketLoading)])
            }
            AccessibleHStack(spacing: Spacing.compact) {
                Text("\(store.projectName(project)) · \(task.string("key"))").lineLimit(1)
                Image(systemName: "arrow.right")
                Text(destinationLabel)
                Spacer()
            }.checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            if recipientChanged && !(store.noteDrafts[task.id] ?? "").isEmpty {
                AccessibleHStack { Text("The handler changed. Confirm the current destination before sending.").checklistFont(.micro).foregroundStyle(.orange); Spacer(); Button("Update recipients") { store.refreshNoteDestination(task.id) }.checklistFont(.micro) }
            }
            TextEditor(text: Binding(get: { store.noteDrafts[task.id] ?? "" }, set: { store.saveNote(task.id, text: $0); observeMentionDraft() }))
                .checklistFont(.callout).frame(height: 55).padding(Spacing.compact).background(.background, in: RoundedRectangle(cornerRadius: Radius.small)).overlay(RoundedRectangle(cornerRadius: Radius.small).stroke(.quaternary)).accessibilityLabel("Add a note")
            if let panel = mentionComposer.panel {
                ScrollView {
                    MentionComposerPanel(panel: panel, select: { panelID, span, target in
                        observeMentionDraft()
                        if mentionComposer.select(panelID: panelID, span: span, target: target) {
                            store.notice = "Target selected. Send note when each target is ready."
                        }
                    }, clear: {
                        mentionComposer.clearSelections()
                        store.notice = "Selections cleared. Send note to read current targets."
                    })
                }.frame(maxHeight: 190)
                    .checklistDisabled([(store.busy, DisabledReasons.saving), (store.hasPendingMutation, DisabledReasons.uncheckedChange), (!store.connected, DisabledReasons.offline), (!store.selectedTicketCurrent(task.id), DisabledReasons.ticketLoading), (recipientChanged, "The recipients changed. Check them first.")])
            }
            AccessibleHStack {
                Menu {
                    Button("Add managed copy…") { attach(mode: "managed_copy") }
                    Button("Reference a file…") { attach(mode: "reference") }
                } label: { Image(systemName: "paperclip") }.menuStyle(.button).buttonStyle(.checklistPlain).menuIndicator(.hidden).frame(width: 24).help("Add files").accessibilityLabel("Add files")
                Spacer()
                Button("Send note") { prepareNoteWithMentions()
                }.buttonStyle(.checklistProminent).keyboardShortcut(.return, modifiers: .command).help("Send note (⌘Return)").checklistDisabled([((store.noteDrafts[task.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Write a note first."), (store.busy, DisabledReasons.saving), (!store.connected, DisabledReasons.offline), (!store.selectedTicketCurrent(task.id), DisabledReasons.ticketLoading), (recipientChanged, "The recipients changed. Check them first."), (store.hasPendingMutation, DisabledReasons.uncheckedChange)])
            }
            if !(store.noteDrafts[task.id] ?? "").isEmpty { DraftSaveStatusView(kind: "note", draftID: task.id) }
        }.padding(Spacing.group).background(.bar)
    }
    var mentionContext: MentionDraftResolution.Context {
        .init(storeIncarnation: .init(store.storeIncarnation), projectID: .init(project), taskID: .init(task.id), replyID: nil)
    }
    func observeMentionDraft() {
        mentionComposer.observe(context: mentionContext, body: store.noteDrafts[task.id] ?? "")
    }
    func mentionDestinationCurrent(_ submission: MentionComposerState.Submission) -> Bool {
        guard store.selectedTicketCurrent(task.id), !store.noteDraftNeedsReconciliation(task.id),
              let current = store.selectedTask(task.id) else { return false }
        return MentionDraftResolution.ExactText(current.string("project_id")) == submission.snapshot.context.projectID
            && MentionDraftResolution.ExactText(current.string("active_attempt_id")) == submission.expectedAttempt
            && MentionDraftResolution.ExactText(store.noteDestinations[task.id] ?? "") == submission.expectedAttempt
    }
    func prepareNoteWithMentions() {
        guard store.allowWrite() else { return }
        guard store.connected, !store.busy, !store.hasPendingMutation,
              store.selectedTicketCurrent(task.id), !recipientChanged else { return }
        observeMentionDraft()
        guard let submission = mentionComposer.begin(expectedAttempt: store.noteDestinations[task.id] ?? "") else { return }
        store.run("message_mentions_prepare", submission.parameters) { result in
            guard mentionDestinationCurrent(submission) else {
                mentionComposer.cancel(); store.notice = "The destination changed. Review it before sending."
                return
            }
            do {
                guard let outcome = try mentionComposer.receive(result, for: submission, context: mentionContext,
                                                               body: store.noteDrafts[task.id] ?? "") else { return }
                switch outcome {
                case .needsSelection:
                    store.notice = "Choose ambiguous targets or correct unknown tags, then Send note."
                case .send(let target):
                    // Finish the prepare run's completion/defer before using the
                    // same durable run path for the actual note command.
                    Task { @MainActor in
                        guard store.connected, !store.busy, !store.hasPendingMutation,
                              mentionDestinationCurrent(submission),
                              mentionComposer.consumeSend(submission, context: mentionContext,
                                  body: store.noteDrafts[task.id] ?? "", expectedAttempt: store.noteDestinations[task.id] ?? "") else { return }
                        let body = submission.snapshot.body.string
                        var params: [String: Any] = ["project_id": project, "task_id": task.id, "body": body,
                            "expects_reply": true, "expected_attempt_id": submission.expectedAttempt.string]
                        if let target { params["mention_target"] = target }
                        store.run("message_send", params, success: task.string("active_attempt_id").isEmpty ? "Note saved for pickup" : "Note saved; see delivery receipts") { _ in
                            if MentionDraftResolution.ExactText(store.noteDrafts[task.id] ?? "") == submission.snapshot.body { store.saveNote(task.id, text: "") }
                            else { store.notice = "Note sent; newer local draft text was retained." }
                            observeMentionDraft()
                        }
                    }
                }
            } catch { store.error = PlainError.text(error) }
        }
    }
    var editNeedsReconciliation: Bool {
        guard let draft = store.taskEditDrafts[task.id] else { return false }
        return draft.baseRevision != task.integer("revision") || !draft.scope.matches(store: store.storeIncarnation, project: project, entity: task.id)
    }
    var noLongerMatchesView: Bool {
        guard [.tasks, .archived].contains(store.page) else { return false }
        // A missing page row or note outside this bounded conversation is unknown,
        // not proof that the selected ticket stopped matching the list.
        if store.hasSelectedTicketDisplay(task.id) {return false}
        let projection = TicketListProjection.make(tasks: [task], groups: [], messages: store.detailRecords("messages",task:task), projectID: store.projectID, archived: store.page == .archived, statusFilter: store.statusFilter, tagFilter: store.tagFilter, search: store.search, includeTriages: false, projectNames: [project: store.projectName(project)])
        return projection.visibleTicketCount == 0
    }
    func restoreEdit() {
        guard let draft = store.taskEditDrafts[task.id], draft.hasChanges || draft.editing else { return }
        title = draft.title; brief = draft.brief; editBaseRevision = draft.baseRevision; editing = draft.editing
    }
    func beginEdit() {
        let resuming = store.taskEditDrafts[task.id]?.hasChanges == true
        if let draft = store.taskEditDrafts[task.id], resuming { title = draft.title; brief = draft.brief; editBaseRevision = draft.baseRevision }
        else { title = task.string("title"); brief = task.string("brief"); editBaseRevision = task.integer("revision") }
        editing = true; persistEdit(hasChanges: resuming, reconcile: !resuming)
    }
    func persistEdit(hasChanges: Bool, reconcile: Bool = false) {
        let scope = reconcile ? store.draftScope(project: project, entity: task.id) : store.taskEditDrafts[task.id]?.scope ?? store.draftScope(project: project, entity: task.id)
        store.saveTaskEdit(task.id, draft: TaskEditDraft(title: title, brief: brief, baseRevision: editBaseRevision, editing: editing, hasChanges: hasChanges, scope: scope))
    }
    func saveEdit() {
        let submittedTitle = title, submittedBrief = brief
        store.run("task_edit", ["project_id": project, "task_id": task.id, "expected_revision": editBaseRevision, "patch": ["title": submittedTitle, "brief": submittedBrief]], success: "Ticket updated") { result in
            editBaseRevision = (result["revision"] as? NSNumber)?.intValue ?? editBaseRevision
            let changedAgain = title != submittedTitle || brief != submittedBrief
            editing = changedAgain; persistEdit(hasChanges: changedAgain, reconcile: true)
        }
    }
    func assign(_ value: String) { assignmentTarget = value;showingAssignmentReason = true }
    func attach(mode: String) {
        let urls = chooseFiles(directories: false)
        Task { for url in urls { do { _ = try await store.request("attachment_add", ["command_id": UUID().uuidString, "project_id": project, "task_id": task.id, "path": url.path, "mode": mode]); await store.refresh(quiet: true) } catch { store.error = PlainError.text(error); return } } }
    }
    var archiveScope: ArchiveConfirmationState.Scope {
        .init(task: task, store: store.storeIncarnation,
              settingsRevision: store.project(project)?.integer("settings_revision") ?? 0,
              epoch: store.archivePreviewEpoch,
              readable: store.connected && store.selectedTicketCurrent(task.id) && !task.bool("archived") && !task.bool("trashed"))
    }
    func prepareArchive() {
        archiveRetry = UUID()
        archiveConfirmation.present()
    }
    func archive(clean: Bool, preview: [String: Any] = [:]) {
        var params: [String: Any] = ["project_id": project, "task_id": task.id, "expected_revision": task.integer("revision"), "action": task.bool("archived") ? "unarchive" : "archive", "cleanup": clean]
        if let previewID = preview["cleanup_preview_id"] { params["cleanup_preview_id"] = previewID }
        store.run("task_archive", params, success: task.bool("archived") ? (files.contains { $0.string("availability") == "original_cleaned" } ? "Ticket restored; previously cleaned originals remain unavailable" : "Ticket restored") : clean ? "Ticket archived; cleanup queued; Undo is available until original bytes are removed" : "Ticket archived; files retained") {result in ticketUndo = TicketUndo.archive(result,action:params["action"] as? String ?? "");if params["action"] as? String == "unarchive" {store.notice = (result["cleaned_original_count"] as? Int ?? 0) > 0 ? "Ticket visible again; cleaned original files are not restored" : "Ticket visible again"} }
    }
}

struct DraftSaveStatusView: View {
    @EnvironmentObject var store: ChecklistStore
    let kind: String
    let draftID: String
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if let failure = store.draftSaveError(kind, draftID) {
                Text("Not saved · \(failure). Your text remains in this app; copy it before quitting.").foregroundStyle(.orange).textSelection(.enabled)
                Button("Retry draft save") { store.retryDraftSave(kind, draftID) }.buttonStyle(.link)
            } else { Text("Saved on this Mac, not sent").foregroundStyle(Color.checklistSecondaryText) }
            if let recovery = store.draftRecoveryError { Text(recovery).foregroundStyle(.orange).textSelection(.enabled) }
        }.checklistFont(.micro)
    }
}

struct MessageRow: View {
    @EnvironmentObject var store: ChecklistStore
    let message: Record
    let task: Record
    var savedResponseRequest: Record? {
        func sameID(_ left: String, _ right: String) -> Bool { left.utf8.elementsEqual(right.utf8) }
        let requestID = message.string("human_request_id"), responseID = message.string("human_response_id")
        let projectID = task.string("project_id")
        guard message.string("origin") == "human_ui", !requestID.isEmpty, !responseID.isEmpty,
              !task.id.isEmpty, !projectID.isEmpty,
              sameID(message.string("project_id"), projectID), sameID(message.string("task_id"), task.id) else { return nil }
        // Match the destination's existing ID lookup, refusing ambiguity before
        // checking the exact byte identity and ticket scope.
        let matches = store.detailRecords("requests",task:task).filter { $0.id == requestID }
        guard matches.count == 1, let request = matches.first, sameID(request.id, requestID),
              sameID(request.string("project_id"), projectID), sameID(request.string("task_id"), task.id),
              ["answered", "resolved", "canceled", "superseded"].contains(Canceled.normalized(request.string("state"))) else { return nil }
        let responses = request.records("responses").filter { $0.id == responseID }
        guard responses.count == 1, let response = responses.first, sameID(response.id, responseID),
              response.string("origin") == "human_ui" else { return nil }
        return request
    }
    var body: some View {
        let _ = NativeRenderMetrics.body(.messageRow)
        VStack(alignment: .leading, spacing: Spacing.small) {
            AccessibleHStack {
                Image(systemName: ["human", "human_ui"].contains(message.string("origin")) ? "person.crop.circle.fill" : "bubble.left.fill").foregroundStyle(["human", "human_ui"].contains(message.string("origin")) ? Color.checklistAccentText : Color.checklistSecondaryText)
                Text(message.string("author_display", fallback: ["human", "human_ui"].contains(message.string("origin")) ? "You" : "Agent")).checklistFont(.captionStrong)
                Spacer()
                Text(relativeTime(message.string("created_at"))).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }
            Text(message.string("body")).checklistFont(.callout).textSelection(.enabled)
            NoteCorrectionActions(message:message,task:task)
            if savedResponseRequest != nil {
                Button("View saved response") {
                    if let request = savedResponseRequest { store.open(.request(request.id)) }
                }.buttonStyle(.link).checklistFont(.micro)
            }
            if message.bool("requires_action"),message.string("note_revision_state") != "retracted" { Label("Requires action", systemImage: "flag.fill").checklistFont(.micro).foregroundStyle(.orange) }
            ForEach(message.records("deliveries")) { delivery in
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    AccessibleHStack(spacing: Spacing.tight) {
                        Text("\(recipientLabel(delivery)): \(receiptLabel(delivery.string("state")))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                        if let reaction = reactionLabel(delivery.string("reaction")) {
                            Text(reaction.symbol).checklistFont(.caption).help(reaction.meaning).accessibilityLabel("Agent reaction: \(reaction.meaning)")
                        }
                    }
                    if ["queued", "pending", "saved", "saved_for_pickup"].contains(delivery.string("state")), delivery.string("push_state") == "unavailable" {
                        Text("Saved for the agent’s next Checklist check.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    } else if !delivery.string("reason", fallback: delivery.string("push_reason")).isEmpty && !delivery.string("reason", fallback: delivery.string("push_reason")).contains("Native push is unqualified") {
                        Text(delivery.string("reason", fallback: delivery.string("push_reason"))).checklistFont(.micro).foregroundStyle(.orange)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).checklistCard(padding: Card.padding)
    }
    func recipientLabel(_ delivery: Record) -> String {
        let sessionID = delivery.string("recipient_session_id")
        if let session = store.detailRecords("sessions",task:task).first(where: { $0.id == sessionID }) {
            let label = session.string("native_conversation_title", fallback: session.string("label"))
            if !label.isEmpty && UUID(uuidString: label) == nil { return label }
        }
        let label = delivery.string("recipient_label")
        if !label.isEmpty && UUID(uuidString: label) == nil { return label }
        return sessionID.isEmpty ? "Agent" : "Agent · " + String(sessionID.prefix(8))
    }
    /// The recipient's own marker for the note; only the fixed service set is shown.
    func reactionLabel(_ value: String) -> (symbol: String, meaning: String)? {
        switch value {
        case "thumbs_up": return ("👍", "Seen. No reply needed.")
        case "thumbs_down": return ("👎", "No.")
        case "done": return ("✅", "Done.")
        case "looking": return ("👀", "Looking into it.")
        case "question": return ("❓", "Has a question.")
        default: return nil
        }
    }
    func receiptLabel(_ state: String) -> String { DeliveryLabels.receipt(state) }
}

struct AttachmentRow: View {
    @EnvironmentObject var store: ChecklistStore
    let file: Record
    var targetManifestID: String? = nil
    @State private var showingPreview = false
    @State private var openExternally = false
    var resources: [Record] {
        guard let task = store.task(file.string("task_id")) else { return [file] }
        return store.detailRecords("attachments", task: task)
    }
    var presentedFile: Record {
        guard let targetManifestID, !targetManifestID.isEmpty else { return file }
        var value = file.values; value["target_manifest_id"] = targetManifestID
        return Record(values: value)
    }
    var body: some View {
        AccessibleHStack(spacing: Spacing.row) {
            AttachmentThumbnail(file: file).frame(width: 75, height: 50)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(file.string("name")).checklistFont(.calloutEmphasis).lineLimit(2)
                Text("\(GlossaryText.humanize(file.string("mode", fallback: "Managed copy"))) · \(ByteCountFormatter.string(fromByteCount: Int64(file.integer("size", fallback: 0)), countStyle: .file)) · \(availabilityLabel)").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }
            Spacer()
            Button("Preview") { openExternally = false; showingPreview = true }.checklistFont(.micro)
            Button("Open in…") { openExternally = true; showingPreview = true }.checklistFont(.micro)
        }.checklistCard(padding: Spacing.small)
            .sheet(isPresented: $showingPreview) { FilePreviewSheet(attachment: presentedFile, resources: resources, openExternally: openExternally) }
    }
    var availabilityLabel: String {
        switch file.string("availability") {
        case "available": return "Available"
        case "original_cleaned", "cleaned": return file.string("preview_path").isEmpty ? "Original cleaned" : "Original cleaned · preview retained"
        default: return "Original unavailable"
        }
    }
}
