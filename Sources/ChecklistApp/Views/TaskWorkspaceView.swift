import SwiftUI
import AppKit

/// Keep the controls mounted across projects. Only the native ticket list needs
/// a new identity to retire the preceding project's rows and accessibility tree.
struct TaskWorkspaceView: View {
    @EnvironmentObject var store: ChecklistStore
    var body: some View {
        ProjectTicketContent()
    }
}

private struct ProjectTicketContent: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.checklistTextScale) private var textScale
    @State private var expandedTriages = RecordIdentitySet()
    @State private var filteredExpansion: [RecordIdentity: Bool] = [:]
    @State private var showCreateTriage = false
    @State private var pastTriages: [Record]?
    @State private var pastTriagesLoading = false
    @State private var pastTriagesError: String?
    @State private var pastTriagesProject: String?
    @State private var pastTriagesReadID = UUID()
    @StateObject private var stability = TicketListStability()
    @StateObject private var bulkSelection = TicketBulkSelection()
    @State private var bulkDraft: TicketBulkDraft?
    @State private var bulkReceipt: TicketBulkReceipt?
    var hasFilters: Bool { store.listHasFilters }
    var explicitClosedFilter: Bool { TicketVisibility.isClosedFilter(store.statusFilter, statuses: store.ticketStatuses) }
    var body: some View {
        let _ = NativeRenderMetrics.body(.tickets)
        Group {
            if let prepared = store.preparedTicketWorkspace {
                preparedContent(prepared)
            } else if store.showsOfflineBanner {
                EmptyState(symbol: "bolt.horizontal.circle", title: "Checklist is offline", detail: "Tickets load when Checklist reconnects. Your drafts stay on this Mac.").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure = store.ticketPageError {
                VStack(spacing: Spacing.control) { Text(failure).checklistFont(.callout); Button("Retry ticket page") { store.retryTicketPage() } }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading tickets…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.sheet(isPresented: $showCreateTriage) { CreateTriageSheet(onCreated: { id in expandedTriages.insert(id); persistExpansion() }).environmentObject(store) }
            .sheet(item: $bulkDraft) { draft in
                TicketBulkEditSheet(draft: draft) { receipt in bulkReceipt = receipt; bulkSelection.clear() }.environmentObject(store)
            }
            .onAppear {
                expandedTriages = RecordIdentitySet(store.windowPreferences.stringArray(forKey: "expandedTriages") ?? [])
                store.updateTicketWorkspaceExpansion(expansionState)
                showExplicitClosedFilter()
            }
            .onChange(of: store.search) { _, _ in filteredExpansion = [:]; store.updateTicketWorkspaceExpansion(expansionState); stability.reset() }
            .onChange(of: RecordIdentity(store.statusFilter)) { _, _ in filteredExpansion = [:]; store.updateTicketWorkspaceExpansion(expansionState); stability.reset(); showExplicitClosedFilter() }
            .onChange(of: explicitClosedFilter) { _, _ in showExplicitClosedFilter() }
            .onChange(of: RecordIdentity(store.tagFilter)) { _, _ in filteredExpansion = [:]; store.updateTicketWorkspaceExpansion(expansionState); stability.reset() }
            .onChange(of: store.listFilters) { _, _ in filteredExpansion = [:]; store.updateTicketWorkspaceExpansion(expansionState); stability.reset() }
            .onChange(of: store.projectID.map(RecordIdentity.init)) { _, _ in
                bulkSelection.clear(); bulkReceipt = nil; bulkDraft = nil; showCreateTriage = false
                filteredExpansion = [:]; store.updateTicketWorkspaceExpansion(expansionState)
                stability.reset();pastTriagesReadID = UUID();pastTriages = nil;pastTriagesLoading = false;pastTriagesError = nil;pastTriagesProject = nil
            }
            .onChange(of: store.page) { _, _ in stability.reset(); bulkSelection.clear() }
            .onChange(of: store.storeIncarnation) { _, _ in
                bulkSelection.clear(); bulkReceipt = nil; bulkDraft = nil
                pastTriagesReadID = UUID();pastTriages = nil;pastTriagesLoading = false;pastTriagesError = nil;pastTriagesProject = nil
            }
    }
    func preparedContent(_ prepared: PreparedTicketWorkspace) -> some View {
        let list = prepared.list
        let visibleTicketIDs = prepared.visibleTicketIDs
        let freshRows = prepared.rows
        let overviewRequests = prepared.overviewRequests
        let firstRowText = freshRows.lazy.compactMap { row -> String? in
                switch row.content {
                case .triage(let section): return ProductionGroups.label(section.triage)
                case .ticket(let task), .triageMember(let task): return task.string("title")
                default: return nil
                }
            }.first
        let frameText = [store.currentProject?.string("name") ?? store.page.title,
            "Showing \(store.ticketPageShownCount) of \(store.ticketPageMatchedCount) matching tickets"] + (firstRowText.map {[$0]} ?? [])
        return VStack(alignment: .leading, spacing: Spacing.none) {
            header(list).checklistActionScroll()
            surfaceControls
            filterControls.checklistActionScroll()
            bulkControls.checklistActionScroll()
            TicketListFilterControls().checklistActionScroll()
            if let failure = store.ticketPageError {
                HStack { Text(failure).checklistFont(.micro); Button("Retry") { store.retryTicketPage() } }.padding(.horizontal, Spacing.page).padding(.bottom, Spacing.small).checklistActionScroll()
            }
            HStack {
                if store.ticketPageLoading { ProgressView().controlSize(.small) }
                Text("Showing \(store.ticketPageShownCount) of \(store.ticketPageMatchedCount) matching tickets").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                Spacer()
                Button("Previous page") { if let cursor = store.ticketPagePreviousCursor { stability.reset(); store.moveTicketPage(cursor) } }.checklistDisabled([(store.ticketPageLoading, "The page is still loading."), (store.ticketPagePreviousCursor == nil, "This is the first page.")])
                Button("Next page") { if let cursor = store.ticketPageNextCursor { stability.reset(); store.moveTicketPage(cursor) } }.checklistDisabled([(store.ticketPageLoading, "The page is still loading."), (store.ticketPageNextCursor == nil, "This is the last page.")])
            }.padding(.horizontal, Spacing.page).padding(.bottom, Spacing.row).checklistActionScroll()
            if stability.pending(freshRows) {
                HStack { Text("List updates are waiting while you interact.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText); Spacer(); Button("Apply updates") { stability.apply(freshRows) }.buttonStyle(.link) }.padding(.horizontal, Spacing.page).padding(.bottom, Spacing.small).checklistActionScroll()
            }
            if !store.connected {
                Label("Showing saved state. Drafts stay on this Mac until the service reconnects.", systemImage: "wifi.slash").checklistFont(.callout).foregroundStyle(.orange).padding(.horizontal, Spacing.page).padding(.bottom, Spacing.row)
            }
            if store.loading && !prepared.hasTasks { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if stability.rows(freshRows, visibleRecordIDs: visibleTicketIDs).isEmpty && list.triages.isEmpty && overviewRequests.isEmpty {
                VStack(spacing: Spacing.none) {
                    EmptyState(symbol: "checklist", title: !prepared.hasProjects ? "A clear place for your work" : hasFilters ? "No tickets match these filters" : "Nothing here yet", detail: !prepared.hasProjects ? "Create a project, then capture a ticket. Your existing checklists stay where they are." : "Add a ticket or adjust the filters to see more work.")
                    if hasFilters { Button("Reset") { clearFilters() }.padding(.bottom, Spacing.empty) }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.compact) {
                        ForEach(stability.rows(freshRows, visibleRecordIDs: visibleTicketIDs)) { row in
                            ticketListRow(row)
                        }
                    }.padding(.horizontal, Spacing.page).padding(.bottom, Spacing.spacious)
                }.id(store.projectID.map(RecordIdentity.init))
                    .onHover { stability.pointer($0, rows: freshRows) }
                    .onKeyPress(phases: [.down, .repeat]) { _ in stability.keyboard(rows: freshRows); return .ignored }
            }
        }
            // Only the subtree containing the heading, counts and ticket rows
            // may finish these clocks; project tabs can paint independently.
            .screenContentFrame(store.screenTiming, .tickets, ready: store.page == .tasks, accessibilityContent:ScreenAccessibilityContent(text:frameText))
            .screenContentFrame(store.screenTiming, .projectSwitch, ready: store.page == .tasks, accessibilityContent:ScreenAccessibilityContent(text:frameText))
            .focusedSceneValue(\.checklistTicketOrder, TicketKeyboardNavigation.order(stability.rows(freshRows, visibleRecordIDs: visibleTicketIDs)))
            .environment(\.ticketBulkRowInteraction, TicketBulkRowInteraction(selected: { bulkSelection.contains($0) }, activate: { ticket, command, shift in
                bulkSelection.activate(ticket, order: TicketBulkSelection.renderedTickets(stability.rows(freshRows, visibleRecordIDs: visibleTicketIDs)), command: command, shift: shift)
            }))
            .onKeyPress(.escape, phases: .down) { _ in
                guard store.detail == nil, bulkSelection.selecting else { return .ignored }
                bulkSelection.clear(); return .handled
            }
    }
    var bulkControls: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.control) {
                Button { if bulkSelection.selecting { bulkSelection.clear() } else { bulkSelection.selecting = true } } label: {
                    TicketHeaderActionLabel(title: bulkSelection.selecting ? "Finish selecting" : "Select tickets", symbol: bulkSelection.selecting ? "checkmark.circle" : "checklist")
                }.buttonStyle(.checklistPlain)
                    .help(bulkSelection.selecting ? "Finish selecting tickets and clear the selection" : "Select tickets for a bulk change")
                    .accessibilityLabel(bulkSelection.selecting ? "Finish selecting" : "Select tickets")
                    .accessibilityValue(bulkSelection.selecting ? "Selection mode on, \(bulkSelection.count) selected" : "Selection mode off")
                    .accessibilityIdentifier("ticketSelection")
                if bulkSelection.selecting {
                    Text("\(bulkSelection.count) selected").checklistFont(.bodyStrong)
                    if bulkSelection.count > 0 {
                        Menu("Status") { bulkAction("Change status…", kind: "status") }
                        Menu("Tags") { bulkAction("Add or remove tags…", kind: "tags") }
                        Menu("Assignee") { bulkAction("Change planned assignee…", kind: "assignee") }
                        Menu("Epic") { bulkAction("Move to Epic…", kind: "epic") }
                        Menu("Triage") { bulkAction("Add or remove from Triage…", kind: "triage") }
                        Menu("Archive") { bulkAction("Archive or unarchive…", kind: "archive") }
                    }
                }
            }
            if bulkSelection.selecting {
                Text(bulkSelection.count > 200 ? "Choose at most 200 tickets for one bulk change." : (bulkSelection.count > 0 && bulkSelection.project == nil ? "Choose tickets from one project to make a bulk change." : "Command-click to select tickets. Shift-click selects a range. Selection keeps the version you selected.")).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }
            if let bulkReceipt {
                HStack {
                    Text(bulkReceipt.summary).checklistFont(.callout)
                    Button("Undo…") { bulkDraft = TicketBulkDraft(kind: "undo", tickets: bulkReceipt.tickets, undo: bulkReceipt) }.checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
                    Button("Dismiss") { self.bulkReceipt = nil }.buttonStyle(.link)
                }
            }
        }.padding(.horizontal, Spacing.page).padding(.bottom, Spacing.control)
    }
    func bulkAction(_ title: String, kind: String) -> some View {
        Button(title) { bulkDraft = TicketBulkDraft(kind: kind, tickets: bulkSelection.tickets) }
            .checklistDisabled([(bulkSelection.project == nil, "Choose tickets from one project."), (bulkSelection.count > 200, "Choose at most 200 tickets."), (!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
    }
    func header(_ list: TicketListProjection) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if store.page != .tasks || store.projectID == nil { Text(store.page == .archived ? "Done / Archived" : store.page.title).checklistFont(.pageTitle) }
            Text(hasFilters ? "\(list.visibleTicketCount) of \(list.scopedTicketCount) tickets" : "\(list.visibleTicketCount) tickets").checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText)
            Spacer()
            if store.page == .tasks {
                Button { showCreateTriage = true } label: { TicketHeaderActionLabel(title: "New Triage", symbol: "plus") }.buttonStyle(.checklistPlain).help("Create a Triage to handle related tickets together").accessibilityLabel("New Triage").accessibilityIdentifier("newTriage").checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
                Menu {
                    if let project = store.projectID {
                        Button(pastTriages == nil ? "Load empty or archived Triages" : "Refresh empty or archived Triages") {loadPastTriages(project)}
                    } else {
                        Menu("Load a project's past Triages") {ForEach(store.projects) {project in Button(project.string("name")) {loadPastTriages(project.id)}}}
                    }
                    if pastTriagesLoading {Text("Loading past Triages…")}
                    if let failure = pastTriagesError {Text(failure)}
                    if let loaded = pastTriages {
                        if let project = pastTriagesProject {Text(store.projectName(project))}
                        if loaded.isEmpty {Text("No empty or archived Triages in this loaded project")}
                        ForEach(loaded) {triage in Button(ProductionGroups.label(triage) + (triage.bool("archived") ? " · archived" : " · empty")) {store.open(.group(triage.id))}}
                    } else if !pastTriagesLoading {Text("Past Triages have not been loaded")}
                } label: { DecorativeIconLabel(title: "Past Triages", systemImage: "tray.2") }.menuStyle(.button).buttonStyle(.checklistPlain).menuIndicator(.hidden).fixedSize().checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
            }
            if store.currentProject != nil {
                Menu {
                    Button("Project Settings…") { if let id = store.projectID { store.open(.project(id)) } }
                    Button(store.page == .archived ? "Incomplete tickets" : "Done / Archived") { showClosed(store.page != .archived) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.button).buttonStyle(.checklistIcon).menuIndicator(.hidden).frame(width: 22).accessibilityLabel("Project actions").help("Project actions")
            }
        }.padding(.horizontal, Spacing.page).padding(.top, store.page == .tasks && store.projectID != nil ? Spacing.section : Spacing.page).padding(.bottom, Spacing.group)
    }
    func loadPastTriages(_ project: String) {
        let readID = UUID(),viewProject = store.projectID.map(RecordIdentity.init),incarnation = store.storeIncarnation
        pastTriagesReadID = readID;pastTriagesLoading = true;pastTriagesError = nil
        Task {
            defer {if pastTriagesReadID == readID {pastTriagesLoading = false}}
            do {
                let result = try await store.request("triage_list",["project_id":project])
                guard pastTriagesReadID == readID,store.projectID.map(RecordIdentity.init) == viewProject,store.storeIncarnation == incarnation else {return}
                guard let rows = result["groups"] as? [[String:Any]],rows.allSatisfy({RecordIdentity($0["project_id"] as? String ?? "") == RecordIdentity(project)}) else {throw TicketPageError.invalid("past_triages")}
                pastTriages = rows.map(Record.init).filter {$0.string("kind") == "triage" && ($0.bool("archived") || ($0.strings("task_ids").isEmpty && $0.records("members").isEmpty))}
                pastTriagesProject = project
            } catch {
                guard pastTriagesReadID == readID else {return}
                pastTriagesError = "Could not load past Triages. No empty-state conclusion was made."
            }
        }
    }
    var surfaceControls: some View {
        HStack(spacing: Spacing.small) {
            visibilityChip("Incomplete", closed: false)
            visibilityChip("Done / Archived", closed: true)
        }.padding(.horizontal, Spacing.page).padding(.bottom, Spacing.control)
            .accessibilityIdentifier("ticketVisibility").checklistActionScroll()
    }
    func visibilityChip(_ label: String, closed: Bool) -> some View {
        let selected = (store.page == .archived) == closed
        return Button { showClosed(closed) } label: {
            Text(label).checklistFont(.calloutEmphasis).padding(.horizontal, Spacing.control).padding(.vertical, Spacing.small)
        }.buttonStyle(ChecklistChipButtonStyle(selected: selected)).accessibilityAddTraits(selected ? .isSelected : [])
    }

    func showClosed(_ closed: Bool) {
        store.withTicketViewUpdate {
            store.statusFilter = "all"
            store.page = closed ? .archived : .tasks
        }
        stability.reset()
    }
    func showExplicitClosedFilter() {
        let resolved = TicketVisibility.reconciledPage(store.page, filter: store.statusFilter, statuses: store.ticketStatuses)
        if resolved != store.page { store.page = resolved }
    }
    var filterControls: some View {
        // Above 115% text the chips and menus can exceed one row in the minimum window; put the menus on a second row.
        Group {
            if textScale > 1.15 {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    HStack(spacing: Spacing.small) { filterChips }
                    HStack(spacing: Spacing.small) { filterMenus }
                }
            } else {
                HStack(spacing: Spacing.small) { filterChips; Spacer(); filterMenus }
            }
        }.padding(.horizontal, Spacing.page).padding(.bottom, Spacing.section)
    }
    @ViewBuilder var filterChips: some View {
        if store.page == .archived {
            filter("All closed", value: "all"); filter("Done", value: "done"); filter("Canceled", value: "canceled"); filter("Archived", value: "archived")
        } else {
            filter("All", value: "all"); filter("Active", value: "active"); filter("Review", value: "review"); filter("Ready", value: "ready"); filter("Drafts", value: "draft")
        }
    }
    @ViewBuilder var filterMenus: some View {
            Menu {
                Picker("Group by", selection: Binding(get: { store.viewGroupBy }, set: { store.saveTaskView(groupBy: $0) })) {
                    Text("Status").tag("status"); Text("Epic").tag("epic"); Text("None").tag("none")
                }
                Picker("Order", selection: Binding(get: { store.viewOrderBy }, set: { store.saveTaskView(orderBy: $0) })) {
                    Text("Manual").tag("manual"); Text("Priority").tag("priority"); Text("Recently updated").tag("updated_desc")
                }
                Button("Use project defaults") { store.useProjectTaskView() }
            } label: { DecorativeIconLabel(title: "View", systemImage: "list.bullet") }.menuStyle(.button).buttonStyle(.checklistPlain).menuIndicator(.hidden).fixedSize()
            Menu {
                Button("All statuses") { store.statusFilter = "all" }
                Button("All Parked types") { store.statusFilter = "parked" }
                Button("Blocked") { store.statusFilter = "blocked" }
                Button("Done") { store.statusFilter = "done" }
                Button("Canceled") { store.statusFilter = "canceled" }
                if let project = store.projectID { Divider(); ForEach(store.statuses(project)) { status in Button(status.string("name")) { store.statusFilter = status.id } } }
            } label: { DecorativeIconLabel(title: "Status", systemImage: "line.3.horizontal.decrease") }.menuStyle(.button).buttonStyle(.checklistPlain).menuIndicator(.hidden).fixedSize()

    }
    @ViewBuilder func ticketListRow(_ row: TicketListRow) -> some View {
        switch row.content {
        case .requestHeading(let count): SectionCaption(title: store.overviewRequestTotal > count ? "Needs your answer · showing \(count) of \(store.overviewRequestTotal)" : "Needs your answer", count: count)
        case .request(let request):
            Button { store.open(.request(request.id)) } label: { HStack(spacing: Spacing.row) { Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.orange); Text(request.string("title")).checklistFont(.bodyEmphasis); Spacer(); Image(systemName: "chevron.right").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }.padding(Spacing.control).background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.medium)) }.buttonStyle(.checklistRow)
        case .triage(let section): InlineTriageRow(section: section, expanded: expansion(section), filtered: hasFilters)
        // Align purpose text with the Triage title after its disclosure control.
        case .triagePurpose(let text): Text(text).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText).padding(.leading, 33).padding(.trailing, Spacing.control).padding(.top, Spacing.small).textSelection(.enabled).triageMemberRule()
        // Align the empty message with the nested member content.
        case .triageEmpty(let text): Text(text).checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText).padding(.leading, 34).padding(.vertical, Spacing.group).triageMemberRule()
        case .triageMember(let task): InlineTriageMemberRow(task: task)
        case .heading(let title, let count): SectionCaption(title: title, count: count)
        case .ticket(let task): TaskRow(task: task)
        case .separator(let isTriage): Divider().padding(.vertical, isTriage ? Spacing.compact : Spacing.row)
        case .clearFilters: Button("Clear filters to show all tickets") { clearFilters() }.padding(.vertical, Spacing.row)
        }
    }
    var expansionState: TicketWorkspaceExpansion {
        TicketWorkspaceExpansion(expandedIDs: expandedTriages, filteredOverrides: filteredExpansion)
    }
    func expansion(_ section: InlineTriageSection) -> Binding<Bool> {
        Binding(get: { hasFilters ? filteredExpansion[RecordIdentity(section.id)] ?? (!section.visibleMembers.isEmpty || section.matchesGroupSearch || expandedTriages.contains(section.id)) : expandedTriages.contains(section.id) }, set: { value in
            stability.reset()
            if hasFilters { filteredExpansion[RecordIdentity(section.id)] = value; store.updateTicketWorkspaceExpansion(expansionState) }
            else { if value { expandedTriages.insert(section.id) } else { expandedTriages.remove(section.id) }; persistExpansion() }
        })
    }
    func persistExpansion() { store.windowPreferences.set(expandedTriages.values, forKey: "expandedTriages"); store.updateTicketWorkspaceExpansion(expansionState) }
    func clearFilters() { store.resetTicketFilters() }
    func filter(_ label: String, value: String) -> some View {
        Button { store.statusFilter = value } label: { Text(label).checklistFont(.calloutEmphasis).padding(.horizontal, Spacing.control).padding(.vertical, Spacing.small) }.buttonStyle(ChecklistChipButtonStyle(selected: store.statusFilter == value)).accessibilityAddTraits(store.statusFilter == value ? .isSelected : [])
    }
}

struct TaskRow: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.detailOverlayInteraction) private var detailInteraction
    @FocusState private var rowFocused: Bool
    @Environment(\.isEnabled) private var rowEnabled
    @Environment(\.ticketBulkRowInteraction) private var bulkInteraction
    @State private var openingControlID = UUID()
    let task: Record
    var selected: Bool { store.detail == .task(task.id) || bulkInteraction.selected(task) }
    @State private var confirmation: PendingConfirmation?
    var body: some View { confirmableBody.checklistConfirmation($confirmation) }
    @ViewBuilder var confirmableBody: some View {
        let _ = NativeRenderMetrics.body(.ticketRow)
        Button(action: activateTask) {
            TaskRowLabel(presentation: TaskRowPresentation(task:task,selected:selected,
                projectName:store.projectID == nil ? store.projectName(task.string("project_id")) : nil,
                age:relativeTime(task.string("updated_at")))).equatable()
        }.buttonStyle(ChecklistRowButtonStyle(focused: rowFocused)).onAppear {NativeRenderMetrics.appeared(.ticketRow)}.focusable().focused($rowFocused)
            // The row style draws the focus ring from rowFocused; the system ring would draw a second one.
            .focusEffectDisabled()
            .onKeyPress(.space, phases: .down) { press in
                guard rowEnabled, press.modifiers.isEmpty else { return .ignored }
                activateTask()
                return .handled
            }
            .background(DetailOverlayOpeningControl(instanceID: openingControlID, itemIdentity: task.id, keyboardFocused: rowFocused, restoreFocus: { rowFocused = false; DispatchQueue.main.async { rowFocused = true } }))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("taskRow-\(task.string("key"))")
            .contextMenu {
                Button("Open", action: openTask)
                Button(task.bool("archived") ? "Unarchive" : "Archive…") { let archive = { store.run("task_archive", ["project_id": task.string("project_id"), "task_id": task.id, "expected_revision": task.integer("revision"), "action": task.bool("archived") ? "unarchive" : "archive", "cleanup": false]) }; if task.bool("archived") { archive() } else { confirmation = Confirmations.archiveTicket(perform: archive) } }.checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
                Button("Copy ticket key") { clipboard(task.string("key")) }
            }
    }
    // The opened detail takes keyboard focus; restoreFocus returns it to this row on close.
    private func activateTask() {
        let modifiers = NSEvent.modifierFlags
        if bulkInteraction.activate(task, modifiers.contains(.command), modifiers.contains(.shift)) { return }
        openTask()
    }
    private func openTask() {
        detailInteraction?.openingControlActivated(instanceID: openingControlID, itemIdentity: task.id)
        store.open(.task(task.id))
    }
}

private struct TaskRowLabel: View, Equatable {
    let presentation: TaskRowPresentation
    var body: some View {
        let _ = NativeRenderMetrics.body(.ticketLabel)
        HStack(alignment: .top, spacing: Spacing.control) {
            Image(systemName: presentation.kind == "bug" ? "ladybug" : "circle").checklistFont(.body).foregroundStyle(presentation.selected ? Color.checklistAccentText : Color.checklistSecondaryText).padding(.top, Spacing.tight)
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(presentation.title).checklistFont(.bodyStrong).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                TicketStatusReasonLine(reason:presentation.statusReason)
                HStack(spacing: Spacing.compact) {
                    Text(presentation.key)
                    if let project = presentation.projectName { Text("·");Text(project) }
                    Text("·");Text(presentation.kind.capitalized)
                    if presentation.human {Text("· You")}
                    if !presentation.waiting.isEmpty {Text("· " + presentation.waiting).foregroundStyle(.orange)}
                }.checklistFont(.caption).foregroundStyle(Color.checklistSecondaryText).lineLimit(1)
            }
            if presentation.showsStatus { TicketStatusPills(name: presentation.statusName, category: presentation.statusCategory, draft: presentation.draft) }
            Text(presentation.age).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText).padding(.top, Spacing.tight)
        }.padding(.horizontal, Spacing.control).padding(.vertical, Spacing.control).background(presentation.selected ? Color.checklistAccent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: Radius.medium)).contentShape(Rectangle())
            .accessibilityElement(children: .ignore).accessibilityLabel(presentation.accessibilityLabel)
    }
}

/// Quiet header actions share the existing plain-button interaction feedback.
struct TicketHeaderActionLabel: View {
    let title: String
    let symbol: String
    @Environment(\.colorSchemeContrast) private var contrast

    static func textColor(increasedContrast: Bool) -> Color {
        // The stronger high-contrast pressed fill needs primary text to retain 4.5:1.
        increasedContrast ? .primary : .checklistSecondaryText
    }

    var body: some View {
        Label(title, systemImage: symbol).checklistFont(.callout)
            .foregroundStyle(Self.textColor(increasedContrast: contrast == .increased))
            .padding(.horizontal, Spacing.small).padding(.vertical, Spacing.tight)
            .frame(minHeight: HitTarget.icon)
    }
}
