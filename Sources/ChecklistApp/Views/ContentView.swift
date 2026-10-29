import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("sidebarWidth") private var sidebarWidth = 224.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var searchFocused = false
    @FocusState private var isSearchFocused: Bool
    @State private var draggedSidebarWidth: Double?
    @StateObject private var settingsPresentation = SettingsModalPresentation()
    @StateObject private var detailInteraction:DetailOverlayInteraction
    init(frameAutosaveName:String = "ChecklistWorkspace") {
        _detailInteraction=StateObject(wrappedValue:DetailOverlayInteraction(frameAutosaveName:frameAutosaveName))
    }

    var body: some View {
        let _ = NativeRenderMetrics.body(.content)
        HStack(spacing: Spacing.none) {
            if sidebarVisible {
                SidebarView().frame(width: boundedSidebarWidth(draggedSidebarWidth ?? sidebarWidth)).transition(.move(edge: .leading).combined(with: .opacity))
                sidebarResizeHandle
            }
            GeometryReader { geometry in
                ZStack(alignment: .trailing) {
                    VStack(spacing: Spacing.none) {
                        if store.projectID != nil && [.tasks, .epics, .media, .archived].contains(store.page) { ProjectWorkspaceTabs() }
                        mainContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let detail = store.detail {
                        DetailOverlay(detail: detail)
                            .accessibilitySortPriority(1)
                            .frame(width: min(560, geometry.size.width - 20))
                            .background(DetailOverlayInteractionRegion(interaction: detailInteraction, region: .overlay))
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.large))
                            .overlay(RoundedRectangle(cornerRadius: Radius.large).stroke(.separator.opacity(0.6), lineWidth: 1))
                            .shadow(color: .black.opacity(0.12), radius: 18, x: -5, y: 3)
                            .padding(.vertical, Spacing.row).padding(.trailing, Spacing.row)
                            .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                            .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
                            .accessibilityIdentifier("detailOverlay")
                    }
                }
            }
        }
        .background(DetailOverlayInteractionRegion(interaction: detailInteraction, region: .content, presented: store.detail != nil, isPresented: { store.detail != nil }, currentItem: { store.detail?.persistenceKey }, dismiss: { store.closeDetail() }))
        .environment(\.detailOverlayInteraction, detailInteraction)
        .environment(\.openChecklistSettings, { settingsPresentation.present() })
        .focusedSceneValue(\.checklistSettings, SettingsModalActions(present: { settingsPresentation.present() }, isPresented: settingsPresentation.isPresented))
        .background(SettingsModalAnchor(presentation: settingsPresentation, content: { AnyView(AppSettingsView().environmentObject(store).defaultAppStorage(store.windowPreferences)) }))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { toggleSidebar() } label: { Image(systemName: "sidebar.left") }.buttonStyle(.automatic)
                    .help("Toggle sidebar (⌃⌘S)").accessibilityLabel("Toggle sidebar")
            }
            ToolbarItem(placement: .navigation) {
                ProjectPicker()
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: Spacing.small) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.checklistSecondaryText)
                    TextField("Search tickets, notes or keys…", text: $store.search).textFieldStyle(.plain).focused($isSearchFocused)
                    if !store.search.isEmpty { Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.checklistSecondaryText) }.buttonStyle(.checklistIcon).accessibilityLabel("Clear search").help("Clear search") }
                }.padding(.horizontal, Spacing.control).padding(.vertical, Spacing.small).frame(minWidth: 210, idealWidth: 330, maxWidth: 430).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.medium))
                    .accessibilityIdentifier("globalSearch")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.showCapture = true } label: { Label("Ticket", systemImage: "plus") }
                    .buttonStyle(.checklistProminent).help("New ticket (⌘N)")
            }
        }
        .navigationTitle("Checklist")
        .checklistHiddenWindowTitle()
        .sheet(isPresented: $store.showCapture) { CaptureTaskView().environmentObject(store) }
        .sheet(isPresented: $store.showNewProject) { NewProjectView().environmentObject(store) }
        .alert("Checklist", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            if store.hasPendingMutation { Button("Check the last change") { store.retryPendingMutation() } }
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .safeAreaInset(edge: .top) {
            if store.showsOfflineBanner { OfflineBanner() }
            else if store.showsWriteAdmissionBanner, let admission = store.writeAdmission { WriteAdmissionBanner(state: admission) }
        }
        .safeAreaInset(edge: .bottom) {
            if store.hasPendingMutation && !store.pendingMutationQueued { HStack { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange); VStack(alignment: .leading, spacing: Spacing.hairline) { Text("The last change may already be saved. Check it before you make another change."); if let commandID = store.pendingCommandID { TechnicalDetails([("Command", commandID)]) } }.checklistFont(.callout); Spacer(); Button("Check the last change") { store.retryPendingMutation() }.checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)]) }.padding(Spacing.row).background(.bar) }
        }
        .overlay(alignment: .bottomLeading) {
            if let notice = store.notice {
                HStack { Image(systemName: store.noticeIsWarning ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(store.noticeIsWarning ? Color.orange : Color.primary); Text(notice); Button { store.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.checklistIcon).accessibilityLabel("Dismiss notice").help("Dismiss notice") }
                    .checklistFont(.callout).padding(Spacing.control).background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.medium)).shadow(radius: 6).padding(Spacing.section)
            }
        }
        .task { await store.startLiveUpdates() }
        .task(id: store.projectID) { await store.mediaReview.connect(store:store) }
        .onChange(of: store.archivePreviewEpoch) { _, _ in Task { await store.mediaReview.refresh() } }
        .onAppear {
            QuickCaptureController.shared.openMainWindow = { [openWindow] in openWindow(id: "main") }
            DockBadge.apply(count: store.needsCount)
            DesktopAlertWindows.shared.activate(store)
        }
        .task { await DockBadge.requestPermissionIfNeeded() }
        .onChange(of: controlActiveState) { _, state in if state == .key { DesktopAlertWindows.shared.activate(store) } }
        .onChange(of: store.needsCount) { _, count in DockBadge.apply(count: count) }
        .onDisappear {store.stopWindowReads();DesktopAlertWindows.shared.remove(store)}
        .onReceive(NotificationCenter.default.publisher(for: .toggleChecklistSidebar)) { note in if let target=note.object as? ChecklistStore,target === store {toggleSidebar()} }
        .onChange(of: sidebarVisible) { _, visible in if !visible { draggedSidebarWidth = nil } }
        .onExitCommand {
            if settingsPresentation.isPresented { settingsPresentation.dismiss() }
            else if store.detail != nil && !detailInteraction.leaveEditorBeforeDismiss() { store.closeDetail() }
        }
        .background {
            Button("Search") { isSearchFocused = true }.keyboardShortcut("f").hidden()
        }
        .modifier(SettingsModalBackground(isPresented: settingsPresentation.isPresented))
        .environment(\.checklistStorageUpgradeStatus, store.storageUpgradeStatus)
    }

    @ViewBuilder var mainContent: some View {
        switch store.page {
        case .overview: OverviewView()
        case .tasks, .archived: VStack(spacing: Spacing.none) { ArchivedProjectNotice(); TaskWorkspaceView() }
        case .needsYou: NeedsYouView()
        case .epics: VStack(spacing: Spacing.none) { ArchivedProjectNotice(); EpicWorkspaceView() }
        case .media: MediaReviewWorkspace(model:store.mediaReview)
        case .activity: ActivityView()
        }
    }
    var sidebarResizeHandle: some View {
        Rectangle().fill(.clear).frame(width: 6).contentShape(Rectangle())
            .overlay { Rectangle().fill(.separator).frame(width: 1) }
            .gesture(DragGesture(minimumDistance: 2).onChanged { drag in
                draggedSidebarWidth = boundedSidebarWidth(sidebarWidth + Double(drag.translation.width))
            }.onEnded { drag in
                sidebarWidth = boundedSidebarWidth(sidebarWidth + Double(drag.translation.width))
                draggedSidebarWidth = nil
            })
            .focusable()
            .onKeyPress(.leftArrow) { sidebarWidth = boundedSidebarWidth(sidebarWidth - 10); return .handled }
            .onKeyPress(.rightArrow) { sidebarWidth = boundedSidebarWidth(sidebarWidth + 10); return .handled }
            .help("Drag to resize sidebar, or focus here and use Left and Right Arrow")
            .accessibilityElement().accessibilityLabel("Sidebar width").accessibilityValue("\(Int(boundedSidebarWidth(draggedSidebarWidth ?? sidebarWidth))) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: sidebarWidth = boundedSidebarWidth(sidebarWidth + 10)
                case .decrement: sidebarWidth = boundedSidebarWidth(sidebarWidth - 10)
                @unknown default: break
                }
            }
    }
    func boundedSidebarWidth(_ width: Double) -> Double { width.isFinite ? min(340, max(180, width)) : 224 }
    func toggleSidebar() { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { sidebarVisible.toggle() } }
}

/// A backup pause is a reachable service state. The caller's original command
/// remains pending until the service reports its applied result.
struct WriteAdmissionBanner: View {
    let state: WriteAdmissionState
    var body: some View {
        AccessibleHStack(alignment: .top, spacing: Spacing.control) {
            Image(systemName: "lock.clock").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(state.title).checklistFont(.bodyStrong)
                Text(state.message).checklistFont(.callout).fixedSize(horizontal: false, vertical: true)
                if let estimate = state.estimateText { Text(estimate).checklistFont(.callout) }
            }
            Spacer(minLength: Spacing.small)
        }
        .padding(Spacing.row).background(.bar).overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain).accessibilityIdentifier("writeAdmissionBanner")
    }
}

/// CL-60: one banner for the whole outage, with the recovery step; reconnection removes it.
private struct OfflineBanner: View {
    @EnvironmentObject var store: ChecklistStore
    var body: some View {
        AccessibleHStack(alignment: .top, spacing: Spacing.control) {
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(store.connectionBannerTitle).checklistFont(.bodyStrong)
                Text(store.connectionBannerMessage).checklistFont(.callout).fixedSize(horizontal: false, vertical: true)
                TechnicalDetails([("Last error", store.lastServiceFailure ?? "")])
            }
            Spacer(minLength: Spacing.small)
            Button("Retry now") { Task { await store.refresh() } }.buttonStyle(.checklistBordered).checklistDisabled([(store.loading, "Checklist is still loading.")])
        }
        .padding(Spacing.row).background(.bar).overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain).accessibilityIdentifier("offlineBanner")
    }
}
