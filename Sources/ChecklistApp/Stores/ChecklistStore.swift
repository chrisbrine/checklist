import Foundation
import SwiftUI
import Combine
import OSLog
import ChecklistIPC

struct PendingCommandPersistence {
    let read: (String)throws->String?
    let save: (String,String)throws->Void
    let remove: (String)->Void
    static var keychain: Self {Self(read:HumanClaims.readRecovery,save:{try HumanClaims.save($0,attempt:$1)},remove:HumanClaims.remove)}
}

@MainActor
final class ChecklistStore: ObservableObject {
    @Published var data: [String: Any] = [:] {
        didSet {
            invalidateContentCache(clearVisible:false); contentVersion = nil
            snapshotRecords = SnapshotRecordIndex(snapshot: data)
            fullSnapshotDirty = false; fullSnapshotAvailable = true
            invalidateSelectedEligibility()
            ticketSnapshotEpoch &+= 1
            prepareTicketWorkspace()
        }
    }
    private var snapshotRecords = SnapshotRecordIndex(snapshot: [:])
    private let ticketObservation = TicketWorkspaceObservation()
    private let ticketCatalog = TicketCatalogObservation()
    private let selectedObservation = SelectedTicketObservation()
    private let draftObservation = DraftObservation()
    private var selectedTicketFromCache = false
    private var selectedTicketDisplay: SelectedTicketDisplay? { get {selectedObservation.display} set {selectedObservation.display = newValue;selectedTicketFromCache = false} }
    private(set) var selectedTicketLoading: Bool { get {selectedObservation.loading} set {selectedObservation.loading = newValue} }
    private(set) var selectedTicketError: String? { get {selectedObservation.error} set {selectedObservation.error = newValue} }
    private var selectedRecordCollections: [String:Any] { get {selectedObservation.collections} set {selectedObservation.collections = newValue} }
    private(set) var selectedRecordsLoading: Bool { get {selectedObservation.recordsLoading} set {selectedObservation.recordsLoading = newValue} }
    private var selectedRecordsReadID = UUID()
    private(set) var selectedRecordsError: String? { get {selectedObservation.recordsError} set {selectedObservation.recordsError = newValue} }
    private var fullSelectedRecordID: RecordIdentity? { get {selectedObservation.fullRecordID} set {selectedObservation.fullRecordID = newValue} }
    private var selectedTicketRead: Task<Void,Never>?
    private var selectedWorkRead:Task<Void,Never>?
    private var selectedTicketReadID = UUID()
    // This selection/lifetime fence survives a record-context rebase. The shared
    // read fetches only; each waiting consumer must still own its installation.
    private var selectedRecordLifetimeID = UUID()
    private var selectedRecordRecovery: (id: UUID, context: String, read: Task<SelectedTicketDisplay,Error>)?
    @Published private(set) var recordHistoryNotice: String?
    private var ticketPages: TicketPagePreparation { get {ticketObservation.pages} set {ticketObservation.pages = newValue} }
    private var pagedTicketWorkspace: PreparedTicketWorkspace? { get {ticketObservation.workspace} set {ticketObservation.workspace = newValue} }
    @Published private(set) var fullSnapshotAvailable = false
    private var fullSnapshotDirty = true
    private var startedLiveUpdates = false
    private var ticketPageRead: Task<Void, Never>?
    private var ticketPageReadID = UUID()
    private var ticketSnapshotEpoch: UInt64 = 0
    private var ticketPreparation: TicketWorkspacePreparation { get {ticketObservation.fullPreparation} set {ticketObservation.fullPreparation = newValue} }
    private var ticketExpansion = TicketWorkspaceExpansion()
    private var ticketUpdateDepth = 0
    private var selectedEligibility: SelectedCompletionEligibility { get {selectedObservation.eligibility} set {selectedObservation.eligibility = newValue} }
    private var selectedEligibilityRead: Task<Void, Never>?
    private var selectionObservation: AnyCancellable?
    private var projectSelectionObservation: AnyCancellable?
    private var refreshRequested = false
    private var scopedReadGeneration = UUID()
    @Published var connected = false
    /// Any observed service change can affect cross-ticket retention holds.
    @Published private(set) var archivePreviewEpoch = UUID()
    @Published private(set) var selectedTicketMissing = false
    /// CL-60: an outage shows one offline banner (after the first connection attempt), never a repeated alert.
    @Published private(set) var connectionAttempted = false
    @Published private(set) var lastServiceFailure: String?
    var showsOfflineBanner: Bool { connectionAttempted && !connected }
    @Published var loading = false
    /// Activity for the visible workspace, not the idle live subscription or
    /// an obsolete reader belonging to a page the owner has already left.
    var sidebarLoading: Bool {
        if loading { return true }
        if usesTicketPages { return ticketPageLoading }
        if page == .overview { return shownOverviewSurfaces.contains { overviewObservations[$0]?.loading == true } }
        return workspaceLoading
    }
    @Published var error: String? { didSet { DiagnosticsRecorder.shared.record(error) } }
    @Published var busy = false
    @Published var hasPendingMutation = false
    var pendingCommandID: String? { pendingMutation?.command.params["command_id"] as? String }
    private var pendingMutation: (command: PendingCommandRecovery, success: String?, completion: (([String: Any]) -> Void)?, failure: ((Error) -> Void)?)?
    private var recoveredCommand: (command: PendingCommandRecovery, marker: String)?
    @Published var notice: String? { didSet { if !informing { noticeIsWarning = false } } }
    private var informing = false
    /// True when the current notice reports an ignored action rather than a success.
    @Published private(set) var noticeIsWarning = false
    /// CL-58: why a write cannot run now, in plain words; nil when it can.
    var writeBlockReason: String? {
        if !connected { return DisabledReasons.offline }
        if hasPendingMutation { return DisabledReasons.uncheckedChange }
        if recoveredCommand != nil { return "Checklist is checking which saved change belongs to this store." }
        if busy { return DisabledReasons.saving }
        return nil
    }
    /// An action the app ignores shows a short notice instead of doing nothing.
    func inform(_ text: String) { informing = true; noticeIsWarning = true; notice = text; informing = false }
    @discardableResult func allowWrite() -> Bool {
        guard let reason = writeBlockReason else { return true }
        inform(reason); return false
    }
    // CL-116: one window-local media presentation; service remains durable authority.
    let mediaReview = MediaReviewModel()
    let screenTiming = ScreenTiming()
    let ticketCleanupReceipts = TicketCleanupReceiptObservation()
    @Published var page: Page = .overview { didSet {
        if page != oldValue {
            // Only the versioned query cache may restore an off-screen page.
            resetOverviewScope(clear:true)
            ticketPageRead?.cancel(); ticketPageReadID = UUID(); ticketPages.invalidate(); pagedTicketWorkspace = nil
            workspaceRead?.cancel(); workspaceObservation.cancel(clear:true)
        }
        prepareTicketWorkspace()
        if page != oldValue, !restoringPreferences, usesTicketPages { scheduleTicketPage(force:true) }
    } }
    @Published var projectID: String? = nil { didSet { if projectID.map(RecordIdentity.init) != oldValue.map(RecordIdentity.init) { resetOverviewScope(clear: true) }; prepareTicketWorkspace() } }
    @Published var detail: Detail? {
        willSet { navigationMemory.prepareNavigation(to: newValue?.persistenceKey) }
        didSet { if let detail, let bytes = try? JSONEncoder().encode(detail) { preferences.set(bytes, forKey: "lastDetail") } else { preferences.removeObject(forKey: "lastDetail") } }
    }
    @Published var detailBackStack: [Detail] = []
    var search: String { get {ticketObservation.search} set {ticketObservation.search = newValue;saveTaskFilters();prepareTicketWorkspace()} }
    var statusFilter: String { get {ticketObservation.statusFilter} set {ticketObservation.statusFilter = newValue;saveTaskFilters();prepareTicketWorkspace()} }
    var tagFilter: String { get {ticketObservation.tagFilter} set {ticketObservation.tagFilter = newValue;saveTaskFilters();prepareTicketWorkspace()} }
    var listFilters: TicketListFilters { get { ticketObservation.filters } set { ticketObservation.filters = newValue; saveTaskFilters(); prepareTicketWorkspace() } }
    var personalViews: [PersonalTicketView] { ticketObservation.personalViews }
    var selectedPersonalViewID: String? { ticketObservation.selectedPersonalViewID }
    var listHasFilters: Bool { listFilters.isActive || statusFilter != "all" || tagFilter != "all" || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var viewGroupBy: String { get {ticketObservation.groupBy} set {ticketObservation.groupBy = newValue;prepareTicketWorkspace()} }
    var viewOrderBy: String { get {ticketObservation.orderBy} set {ticketObservation.orderBy = newValue;prepareTicketWorkspace()} }
    @Published var showCapture = false
    @Published var captureEpicID: String?
    @Published var showNewProject = false
    var noteDrafts: [String:String] { get {draftObservation.notes} set {draftObservation.notes = newValue} }
    var noteDestinations: [String:String] { get {draftObservation.destinations} set {draftObservation.destinations = newValue} }
    var answerDrafts: [String:AnswerDraft] { get {draftObservation.answers} set {draftObservation.answers = newValue} }
    var taskEditDrafts: [String:TaskEditDraft] { get {draftObservation.edits} set {draftObservation.edits = newValue} }
    var captureDrafts: [String:CaptureDraft] { get {draftObservation.captures} set {draftObservation.captures = newValue} }
    var draftSaveFailures: [String:String] { get {draftObservation.failures} set {draftObservation.failures = newValue} }
    var draftRecoveryError: String? { get {draftObservation.recoveryError} set {draftObservation.recoveryError = newValue} }
    private var noteScopes: [String: DraftScope] = [:]
    private var answerScopes: [String: DraftScope] = [:]
    private let draftJournal: LocalDraftJournal
    private let preferences: UserDefaults
    var windowPreferences:UserDefaults {preferences}
    private let pendingCommandKey:String
    private let pendingCommandPersistence:PendingCommandPersistence
    private let pendingCommandServiceIdentity: String
    private var ignoredRecoveryPreferenceKey: String { "ignored-recovery-" + pendingCommandKey }
    private var restoringPreferences = true
    private var refreshing = false
    private var eventCursor: String?
    private static let liveLogger = Logger(subsystem: "org.checklist.app", category: "LiveUpdates")
    // Coverage and installed content have separate clocks. An ignored reply must
    // never make a visible surface fresh merely because the subscription moved.
    private var visibleChange = UUID(), visibleInstalledChange: UUID?
    private var selectedChange = UUID(), selectedInstalledChange: UUID?
    private var visibleStaleSince: TimeInterval?, selectedStaleSince: TimeInterval?
    private var pendingCoverageCursor: String?
    private var pendingCoverageScope: LiveSurfaceScope?
    private var liveSurfaceRead: Task<Bool,Never>?
    private var liveSurfaceScope: LiveSurfaceScope?
    private var liveSurfaceReadID = UUID(), liveSurfaceEpoch = UUID()
    private var freshnessWatchdog: Task<Void,Never>?
    private var visibleRetryAfter: TimeInterval = 0, selectedRetryAfter: TimeInterval = 0
    private var selectedReadEpoch = UUID(), selectedReadTaskID: RecordIdentity?, selectedReadScope: RecordIdentity?
    private var selectedReadInstalledID: UUID?
    private struct LiveSurfaceScope: Equatable {
        let page: Page
        let tickets: TicketPageQuery
        let workspace: WorkspacePageQuery
        let focus: String?
        let digest: Date?
    }
    private var liveScope: LiveSurfaceScope {
        LiveSurfaceScope(page:page,tickets:ticketPageQuery,workspace:workspaceQuery,focus:overviewFocus,digest:overviewDigestSince)
    }
    private func markVisibleStale() {
        visibleChange = UUID()
        if visibleStaleSince == nil { visibleStaleSince = ProcessInfo.processInfo.systemUptime }
    }
    private func markSelectedStale() {
        selectedChange = UUID()
        if selectedStaleSince == nil { selectedStaleSince = ProcessInfo.processInfo.systemUptime }
    }
    private func logLiveRead(_ surface: String, start: TimeInterval, outcome: String) {
        let ms = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
        Self.liveLogger.notice("read surface=\(surface, privacy:.public) duration_ms=\(ms) outcome=\(outcome, privacy:.public)")
    }
    /// Join a read only while its exact visible query still owns it.
    private func readLiveSurface() async -> Bool {
        let scope = liveScope
        if let read = liveSurfaceRead, liveSurfaceScope == scope, liveSurfaceEpoch == contentEpoch {
            return await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
        }
        liveSurfaceRead?.cancel()
        let id = UUID(), change = visibleChange
        liveSurfaceReadID = id; liveSurfaceScope = scope; liveSurfaceEpoch = contentEpoch
        let read = Task { [weak self] in
            guard let self else { return false }
            let installed: Bool
            if self.usesTicketPages { self.ticketPageRead?.cancel(); installed = await self.readTicketPage(query:scope.tickets,cursor:nil) }
            else if self.page == .overview { installed = await self.readOverviewNeeds(force:false,retry:true) }
            else { self.workspaceRead?.cancel(); installed = await self.readWorkspacePage(cursor:nil) }
            guard !Task.isCancelled, self.liveScope == scope else { return false }
            if installed, self.visibleChange == change {
                self.visibleInstalledChange = change; self.visibleStaleSince = nil
            }
            return installed
        }
        liveSurfaceRead = read
        let installed = await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
        if liveSurfaceReadID == id { liveSurfaceRead = nil; liveSurfaceScope = nil }
        return installed
    }
    private func readLiveSelected() async -> Bool {
        guard case .task(let id) = detail else { return true }
        scheduleSelectedTicket(for:detail,coalesce:true)
        let read = selectedTicketRead, readID = selectedTicketReadID
        await withTaskCancellationHandler { await read?.value } onCancel: { read?.cancel() }
        return !Task.isCancelled && isSelectedTicket(id) && selectedReadInstalledID == readID
    }
    private func runFreshnessWatchdog() async {
        // A held list reply must never hold the detail watchdog behind it.
        async let visible: Void = watchFreshness(selected:false)
        async let selected: Void = watchFreshness(selected:true)
        _ = await (visible,selected)
    }
    private func watchFreshness(selected: Bool) async {
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds:100_000_000) } catch { return }
            let now = ProcessInfo.processInfo.systemUptime
            let since = selected ? selectedStaleSince : visibleStaleSince
            let installed = selected ? selectedInstalledChange == selectedChange : visibleInstalledChange == visibleChange
            let retryAfter = selected ? selectedRetryAfter : visibleRetryAfter
            // Leave half a second for a normal-load read before the two-second limit.
            guard !installed, let since, now - since >= 1.5, now >= retryAfter else { continue }
            let surface = selected ? "selected_ticket" : page.rawValue, lag = Int((now - since) * 1000)
            Self.liveLogger.notice("watchdog surface=\(surface, privacy:.public) lag_ms=\(lag)")
            // Even ignored replies retry at the ordinary bounded pace.
            if selected {
                selectedRetryAfter = now + Double(liveRetryPause) / 1_000_000_000
                _ = await readLiveSelected()
            } else {
                visibleRetryAfter = now + Double(liveRetryPause) / 1_000_000_000
                _ = await readLiveSurface()
            }
        }
    }
    private func advanceEventCursor(_ cursor: String?, source: String) {
        guard let cursor else { return }
        eventCursor = cursor
        Self.liveLogger.notice("cursor_advanced source=\(source, privacy:.public)")
    }
    // Window-local last pages. The opaque service version binds store, reader snapshot
    // and caller/grants; event/mutation knowledge retires every retained query at once.
    private var contentVersion: String?
    private var contentEpoch = UUID()
    private var cachedTickets: [(query: TicketPageQuery, value: TicketPagePreparation)] = []
    private var cachedWorkspace: [(query: WorkspacePageQuery, value: WorkspacePage, index: Int)] = []
    private var cachedSelectedTickets: [(scope: RecordIdentity?, value: SelectedTicketDisplay)] = []
    private func invalidateContentCache(clearVisible: Bool = true, retireReads: Bool = true) {
        if retireReads { contentEpoch = UUID() }
        cachedTickets = []; cachedWorkspace = []; cachedSelectedTickets = []
        if clearVisible {
            if startedLiveUpdates { markVisibleStale() }
            if selectedTicketFromCache { selectedTicketDisplay = nil }
            ticketPages.discardContent(); pagedTicketWorkspace = nil
            workspaceObservation.discardContent()
            if selectedOther?.string("record_type") == "project" {otherDetailObservation.discardContent()}
            for observation in overviewObservations.values { observation.discardContent() }
        }
    }
    private func cacheTicketPage(_ query: TicketPageQuery) {
        guard contentVersion != nil else { return }
        cachedTickets.removeAll { $0.query == query }
        cachedTickets.append((query, ticketPages))
        if cachedTickets.count > 12 { cachedTickets.removeFirst() }
    }
    private func cacheWorkspacePage(_ page: WorkspacePage, index: Int = 0) {
        guard contentVersion != nil else { return }
        cachedWorkspace.removeAll { $0.query == page.query }
        cachedWorkspace.append((page.query, page, index))
        if cachedWorkspace.count > 32 { cachedWorkspace.removeFirst() }
    }
    private func restoreWorkspacePage(_ observation: WorkspacePageObservation, query: WorkspacePageQuery) -> Int? {
        guard observation.query != query || observation.page == nil,
              let cached = cachedWorkspace.last(where: { $0.query == query }) else { return nil }
        // Shared metadata is already installed for this version. Replaying each
        // cached group would compare/encode the catalog again and replace newer health.
        observation.restore(cached.value)
        return cached.index
    }
    private func cacheSelectedTicket(_ value: SelectedTicketDisplay, scope: RecordIdentity?) {
        guard let contentVersion, !contentVersion.isEmpty, value.service.string("read_version") == contentVersion else { return }
        cachedSelectedTickets.removeAll { $0.scope == scope && RecordIdentity($0.value.task.id) == RecordIdentity(value.task.id) }
        cachedSelectedTickets.append((scope, value))
        if cachedSelectedTickets.count > 12 { cachedSelectedTickets.removeFirst() }
    }
    var desktopAlertCoordinator: DesktopAlertCoordinator { desktopAlerts }
    private let desktopAlerts: DesktopAlertCoordinator
    let navigationMemory: DetailItemNavigationMemory
    private let qualificationFaults: QualificationFaults
    private let requestTransport: ((String,[String:Any]) async throws -> [String:Any])?
    private let workspaceObservation = WorkspacePageObservation()
    private let otherDetailObservation = WorkspacePageObservation()
    private let recordHistoryObservation = WorkspacePageObservation()
    private var recordHistoryRead:Task<Void,Never>?
    var recordHistoryRows:[Record] {recordHistoryObservation.page?.rows ?? []}
    var recordHistoryTotal:Int {recordHistoryObservation.page?.total ?? 0}
    var recordHistoryNext:String? {recordHistoryObservation.page?.next}
    var recordHistoryPrevious:String? {recordHistoryObservation.page?.previous}
    var recordHistoryLoading:Bool {recordHistoryObservation.loading}
    var recordHistoryError:String? {recordHistoryObservation.error}
    private let groupTasksObservation = WorkspacePageObservation()
    private let groupCandidatesObservation = WorkspacePageObservation()
    private var workspaceRead: Task<Void,Never>?
    private var otherDetailRead: Task<Void,Never>?
    private var groupTasksRead: Task<Void,Never>?
    private var groupCandidatesRead: Task<Void,Never>?
    private var needsSurface = "requests"
    private var workspaceArchived = false
    private var workspacePageIndex = 0
    var workspaceRows: [Record] {workspaceObservation.rows}
    var workspaceTotal: Int {workspaceObservation.page?.total ?? 0}
    var workspaceLoading: Bool {workspaceObservation.loading}
    /// A page for the current workspace query has arrived; before that an empty list is not yet known to be empty.
    var workspacePageLoaded: Bool {workspaceObservation.page != nil}
    var workspaceShowsLoading: Bool {workspaceLoading && !workspacePageLoaded}
    var workspaceError: String? {workspaceObservation.error}
    var workspaceNext: String? {workspaceObservation.page?.next}
    var workspacePrevious: String? {workspaceObservation.page?.previous}
    var otherDetailLoading: Bool {otherDetailObservation.loading}
    var otherDetailError: String? {otherDetailObservation.error}
    var selectedOther: Record? {otherDetailObservation.page?.rows.first ?? otherDetailObservation.retainedRequest}
    var otherDetailMissing: Bool {otherDetailObservation.page?.rows.isEmpty == true && otherDetailObservation.retainedRequest != nil}
    func requestDetail(_ id: String) -> Record? {
        if let request = selectedOther, request.string("record_type") == "request", RecordIdentity(request.id) == RecordIdentity(id) { return request }
        return startedLiveUpdates ? nil : records("requests").first { RecordIdentity($0.id) == RecordIdentity(id) }
    }
    func requestNoLongerListed(_ id: String) -> Bool {
        page == .needsYou && needsSurface == "requests" && workspacePageLoaded &&
            !workspaceRows.contains { RecordIdentity($0.id) == RecordIdentity(id) }
    }
    var groupTaskRows: [Record] {groupTasksObservation.page?.rows ?? []}
    var groupTaskTotal: Int {groupTasksObservation.page?.total ?? 0}
    var groupTaskNext: String? {groupTasksObservation.page?.next}
    var groupTaskPrevious: String? {groupTasksObservation.page?.previous}
    var groupCandidateRows: [Record] {groupCandidatesObservation.page?.rows ?? []}
    var groupCandidateNext: String? {groupCandidatesObservation.page?.next}
    var groupCandidatePrevious: String? {groupCandidatesObservation.page?.previous}
    var groupCandidateLoading: Bool {groupCandidatesObservation.loading}
    var groupCandidateError: String? {groupCandidatesObservation.error}
    var groupCandidatesLoaded: Bool {groupCandidatesObservation.page != nil}
    var groupTaskLoading: Bool {groupTasksObservation.loading}
    var groupTaskError: String? {groupTasksObservation.error}

    init(draftJournal: LocalDraftJournal = LocalDraftJournal(), preferences: UserDefaults = .standard, restorePendingCommand: Bool = true, desktopAlerts: DesktopAlertCoordinator = .shared, requestTransport: ((String,[String:Any]) async throws -> [String:Any])? = nil, navigationMemory: DetailItemNavigationMemory = .shared, pendingCommandKey:String = WorkspaceWindowIdentity.primary.pendingCommandKey, pendingCommandPersistence:PendingCommandPersistence = .keychain, pendingCommandServiceIdentity: String = ChecklistInstance.current.machServiceName, qualificationFaults: QualificationFaults? = nil) {
        self.qualificationFaults = qualificationFaults ?? .shared
        self.draftJournal = draftJournal; self.preferences = preferences; self.desktopAlerts = desktopAlerts;self.requestTransport = requestTransport;self.navigationMemory = navigationMemory;self.pendingCommandKey=pendingCommandKey;self.pendingCommandPersistence=pendingCommandPersistence;self.pendingCommandServiceIdentity=pendingCommandServiceIdentity
        if restorePendingCommand { restoreSavedCommand() }
        if let bytes = preferences.data(forKey: "lastDetail") {
            if let savedDetail = try? JSONDecoder().decode(Detail.self, from: bytes) { detail = savedDetail }
            else { preferences.removeObject(forKey: "lastDetail") }
        }
        noteDrafts = preferences.dictionary(forKey: "noteDrafts") as? [String: String] ?? [:]
        noteDestinations = preferences.dictionary(forKey: "noteDestinations") as? [String: String] ?? [:]
        if let bytes = preferences.data(forKey: "answerDrafts"), let drafts = try? JSONDecoder().decode([String: AnswerDraft].self, from: bytes) { answerDrafts = drafts }
        loadLocalDrafts()
        if preferences.string(forKey: "lastPage") == "triages" { page = .tasks; preferences.set(Page.tasks.rawValue, forKey: "lastPage") } else if let savedPage = preferences.string(forKey: "lastPage"), let page = Page(rawValue: savedPage) { self.page = page } else { preferences.set(Page.overview.rawValue, forKey: "lastPage") }
        projectID = preferences.string(forKey: "lastProject")
        loadTaskView()
        restoringPreferences = false
        navigationMemory.prepareNavigation(to: detail?.persistenceKey)
        prepareTicketWorkspace()
        selectionObservation = $detail.removeDuplicates(by: { left, right in left.map {RecordIdentity($0.persistenceKey)} == right.map {RecordIdentity($0.persistenceKey)} }).sink { [weak self] selection in
            // Published emits before the setter completes. The read starts after
            // the physical item transaction; a generation fences late results.
            self?.scheduleOtherDetail(for:selection)
            self?.scheduleSelectedTicket(for: selection)
            self?.scheduleSelectedEligibility(for: selection)
        }
        projectSelectionObservation = $projectID.removeDuplicates().dropFirst().sink { [weak self] _ in
            guard let self else { return }
            self.cancelSelectedRecordRecovery()
            self.selectedWorkRead?.cancel();self.selectedRecordsReadID = UUID();self.selectedRecordsLoading = false
            self.recordHistoryRead?.cancel();self.recordHistoryObservation.cancel(clear:true)
            self.scheduleSelectedEligibility(for: self.detail)
        }
    }

    func records(_ key: String) -> [Record] { snapshotRecords.records(in: key) }
    var projects: [Record] { (usesTicketPages || page == .overview ? ticketCatalog.projects : workspaceObservation.page?.projects) ?? otherDetailObservation.page?.projects ?? ticketCatalog.projects ?? records("projects") }
    var ticketStatuses: [Record] {ticketCatalog.statuses ?? records("statuses")}
    /// CL-130: an archived project leaves the active sidebar and stays listed under Archived projects.
    var activeProjects: [Record] { projects.filter { !$0.bool("archived") } }
    var archivedProjects: [Record] { projects.filter { $0.bool("archived") } }
    func setProjectArchived(_ project: Record, archived: Bool) {
        run("project_archive", ["project_id": project.id, "expected_revision": project.integer("revision"), "archived": archived],
            success: archived ? "Project archived" : "Project restored") { [weak self] _ in
            guard let self, archived, let selected = self.projectID, RecordIdentity(selected) == RecordIdentity(project.id) else { return }
            self.select(.overview)
        }
    }
    var ticketTags: [Record] {ticketCatalog.tags ?? records("tags")}
    var tasks: [Record] { records("tasks") }
    var workSessions: [Record] { sessions.filter { $0.string("role") == "worker" } }
    var sessions: [Record] { records("sessions") }
    var requests: [Record] { if startedLiveUpdates {return (selectedOther.map { $0.string("record_type")=="request" && !otherDetailMissing ? [$0] : [] } ?? []) + workspaceRows.filter {$0.string("record_type")=="request" && RecordIdentity($0.id) != selectedOther.map {RecordIdentity($0.id)}}};return records("requests") }
    var groups: [Record] { if startedLiveUpdates {return (selectedOther.map {$0.string("record_type")=="group" ? [$0] : []} ?? []) + workspaceRows.filter {$0.string("record_type")=="group" && RecordIdentity($0.id) != selectedOther.map {RecordIdentity($0.id)}}};return records("groups") }
    var currentProject: Record? { projectID.flatMap { project($0) } }
    var outstandingRequests: [Record] { requests.filter { !["answered", "canceled", "superseded", "resolved"].contains(Canceled.normalized($0.string("state"))) } }
    var yourTasks: [Record] { tasks.filter { !$0.bool("archived") && !$0.bool("trashed") && ($0.string("planned_assignee") == "human" || $0.object("planned_assignee")["kind"] as? String == "human" || $0.string("assignee") == "human") && !["done", "completed", "canceled"].contains(Canceled.normalized($0.string("status_category"))) } }
    var needsCount: Int { ticketCatalog.needsCount ?? (outstandingRequests.count + yourTasks.count) }
    var service: Record { (usesTicketPages || page == .overview ? ticketCatalog.service : workspaceObservation.page?.service) ?? selectedTicketDisplay?.service ?? otherDetailObservation.page?.service ?? Record(values: data["service"] as? [String: Any] ?? [:]) }
    var buildLabel: String { BuildIdentity.current }

    func project(_ id: String) -> Record? { if let selectedOther,selectedOther.string("record_type")=="project",RecordIdentity(selectedOther.id)==RecordIdentity(id) {return selectedOther};return selectedTicketDisplay.flatMap {RecordIdentity($0.project.id) == RecordIdentity(id) ? $0.project : nil} ?? projects.first { RecordIdentity($0.id) == RecordIdentity(id) } }
    func rawTask(_ id: String) -> Record? { snapshotRecords.record(in: "tasks", id: id) }
    func task(_ id: String) -> Record? { if let value=selectedOther?.values["selected_task"] as? [String:Any],let tid=value["id"] as? String,RecordIdentity(tid)==RecordIdentity(id) {return Record(values:value)};return rawTask(id).map { selectedEligibility.overlay(on: $0, store: storeIncarnation) } }
    func selectedTask(_ id: String) -> Record? {
        guard let selected = selectedTicketDisplay, RecordIdentity(selected.task.id) == RecordIdentity(id) else {return nil}
        return selectedEligibility.overlay(on:selected.task,store:selected.service.string("store_incarnation"))
    }
    private func isSelectedTicket(_ id: String) -> Bool {
        guard case .task(let current) = detail else {return false}
        return RecordIdentity(current) == RecordIdentity(id)
    }
    func selectedTicketCurrent(_ id: String) -> Bool {isSelectedTicket(id) && !selectedTicketLoading && selectedTicketError == nil && hasSelectedTicketDisplay(id)}
    var selectedRecordsCurrent: Bool {fullSelectedRecordID != nil && !selectedTicketLoading && selectedTicketError == nil && !selectedRecordsLoading && selectedRecordsError == nil}
    func hasSelectedTicketDisplay(_ id: String) -> Bool { selectedTicketDisplay.map {RecordIdentity($0.task.id) == RecordIdentity(id)} ?? false }
    func selectedRecordCount(_ key: String, task: Record) -> Int {
        fullSelectedRecordLoaded(task.id) ? detailRecords(key,task:task).count : (selectedTicketDisplay?.counts[key] as? Int ?? 0)
    }
    private func eligibilityTask(_ id: String) -> Record? { selectedTicketDisplay.flatMap { RecordIdentity($0.task.id) == RecordIdentity(id) ? $0.task : nil } ?? rawTask(id) }
    func detailRecords(_ key: String, task: Record) -> [Record] {
        guard let selected = selectedTicketDisplay, RecordIdentity(selected.task.id) == RecordIdentity(task.id) else {return []}
        return fullSelectedRecordLoaded(task.id) && key != "messages" && key != "events" && key != "groups" && key != "statuses" && key != "tags" ? (selectedRecordCollections[key] as? [[String:Any]] ?? []).map(Record.init) : selected.records(key)
    }
    func fullSelectedRecordLoaded(_ id: String) -> Bool { fullSelectedRecordID == RecordIdentity(id) }
    func selectedReviewData(_ task: Record) -> [String:Any] {fullSelectedRecordLoaded(task.id) ? selectedRecordCollections : [:]}
    func selectedRelatedTask(_ id: String, task: Record) -> Record? {detailRecords("tasks",task:task).first {RecordIdentity($0.id)==RecordIdentity(id)}}
    func assignmentSessions(_ task: Record) -> [Record] {detailRecords("sessions",task:task).filter {$0.string("role")=="worker"}}
    var selectedMessageNextCursor: String? { selectedTicketDisplay?.nextHistoryCursor }
    var selectedMessagePreviousCursor: String? { selectedTicketDisplay?.previousHistoryCursor }
    var selectedMessageCount: Int { (selectedTicketDisplay?.counts["messages"] as? Int) ?? 0 }
    func moveSelectedMessages(_ cursor: String) {
        guard case .task(let id) = detail else {return}
        scheduleSelectedTicket(for:.task(id),cursor:cursor)
    }
    func retrySelectedTicket() {scheduleSelectedTicket(for:detail)}
    private func cancelSelectedRecordRecovery() {
        selectedRecordLifetimeID = UUID()
        selectedRecordRecovery?.read.cancel();selectedRecordRecovery = nil
        recordHistoryNotice = nil
    }
    private func selectedRecordScopeCurrent(_ display: SelectedTicketDisplay, lifetime: UUID, project: String?) -> Bool {
        selectedRecordLifetimeID == lifetime && isSelectedTicket(display.task.id) &&
        project.map(RecordIdentity.init) == projectID.map(RecordIdentity.init) &&
        RecordIdentity(storeIncarnation) == RecordIdentity(display.service.string("store_incarnation"))
    }
    private func refreshSelectedRecordContext(_ displayed: SelectedTicketDisplay, isCurrent: @MainActor () -> Bool) async throws -> SelectedTicketDisplay {
        guard !Task.isCancelled,isCurrent() else {throw CancellationError()}
        if let current = selectedTicketDisplay,current.contextCursor != displayed.contextCursor {return current}
        let recovery: (id: UUID, context: String, read: Task<SelectedTicketDisplay,Error>)
        if let pending = selectedRecordRecovery,pending.context == displayed.contextCursor {recovery = pending}
        else {
            recovery = (UUID(),displayed.contextCursor,Task {
                try self.qualificationFaults.inject(.freshContext)
                let response = try await self.request("task_context",["task_id":displayed.task.id,"detail_level":"ui"])
                try Task.checkCancellation()
                let value = try SelectedTicketDisplay(response:response)
                guard RecordIdentity(value.task.id) == RecordIdentity(displayed.task.id),
                      RecordIdentity(value.project.id) == RecordIdentity(displayed.project.id),
                      RecordIdentity(value.service.string("store_incarnation")) == RecordIdentity(displayed.service.string("store_incarnation")),
                      value.task.integer("revision") >= displayed.task.integer("revision") else {throw TicketPageError.invalid("selected_ticket.identity")}
                return value
            })
            selectedRecordRecovery = recovery
        }
        defer {if selectedRecordRecovery?.id == recovery.id {selectedRecordRecovery = nil}}
        let value = try await recovery.read.value
        guard !Task.isCancelled,isCurrent() else {throw CancellationError()}
        if let current = selectedTicketDisplay,current.contextCursor != displayed.contextCursor {return current}
        // Do not run the ordinary expanded-record reload hook: that would cancel
        // this consumer and grant a fresh retry budget. Old authority is retired.
        fullSelectedRecordID = nil;selectedRecordCollections = [:]
        invalidateSelectedEligibility()
        selectedTicketDisplay = value;cacheSelectedTicket(value, scope:projectID.map(RecordIdentity.init));acceptServiceRead()
        scheduleSelectedEligibility(for:detail)
        return value
    }
    private func selectedRecordResponse(_ displayed: SelectedTicketDisplay, level: String, family: String? = nil, cursor: String? = nil, isCurrent: @MainActor () -> Bool) async throws -> (response: [String:Any], context: String, restarted: Bool) {
        func parameters(_ display: SelectedTicketDisplay, cursor: String?) -> [String:Any] {
            var p: [String:Any] = ["task_id":display.task.id,"detail_level":level,"selected_context_cursor":display.contextCursor]
            p["records_family"] = family;p["cursor"] = cursor
            return p
        }
        do {
            try qualificationFaults.inject(level == "ui_history" ? .history : .records)
            let response = try await request("task_context",parameters(displayed,cursor:cursor), ifCurrent:isCurrent)
            return (response,displayed.contextCursor,false)
        } catch let failure as ChecklistError where failure.code == "CURSOR_RESET" {
            guard !isReadCancellation(failure),isCurrent() else {throw CancellationError()}
            // A delayed reset for the old cursor must not retire authority
            // already accepted by a concurrent consumer on the fresh context.
            if selectedTicketDisplay?.contextCursor == displayed.contextCursor {
                fullSelectedRecordID = nil;selectedRecordCollections = [:]
                invalidateSelectedEligibility()
            }
            let fresh = try await refreshSelectedRecordContext(displayed,isCurrent:isCurrent)
            guard !Task.isCancelled,isCurrent() else {throw CancellationError()}
            // One retry only. History's offset belongs to the rejected context.
            try qualificationFaults.inject(level == "ui_history" ? .history : .records)
            let response = try await request("task_context",parameters(fresh,cursor:nil), ifCurrent:isCurrent)
            return (response,fresh.contextCursor,level == "ui_history")
        }
    }
    private func selectedRecordFailure(_ error: Error, operation: String) -> String {
        if (error as? ChecklistError)?.code == "CURSOR_RESET" {
            return "This ticket's context changed again while loading. Use Refresh selected ticket, then load these records again. Your draft is kept."
        }
        return "Could not load \(operation). \(PlainError.text(error)) Your draft is kept."
    }
    func loadFullSelectedRecord(_ id: String) {
        selectedRecordsError = nil;selectedRecordsLoading = true
        let readID = UUID();selectedRecordsReadID = readID
        let lifetime = selectedRecordLifetimeID,project = projectID
        guard let displayed = selectedTicketDisplay,RecordIdentity(displayed.task.id) == RecordIdentity(id) else {selectedRecordsLoading = false;return}
        selectedWorkRead?.cancel()
        selectedWorkRead=Task {
            @MainActor func current() -> Bool {selectedRecordsReadID == readID && selectedRecordScopeCurrent(displayed,lifetime:lifetime,project:project)}
            do {
                let result = try await selectedRecordResponse(displayed,level:"ui_records",isCurrent:current)
                guard !Task.isCancelled,current(),let current = selectedTicketDisplay,current.contextCursor == result.context else {throw CancellationError()}
                let response = result.response
                guard RecordIdentity(current.task.id)==RecordIdentity(id),
                      response["ui_records_version"] as? Int == 1,
                      response["task_revision"] as? Int == current.task.integer("revision"),
                      let returnedID = response["task_id"] as? String,RecordIdentity(returnedID)==RecordIdentity(id),
                      let project = response["project_id"] as? String,RecordIdentity(project)==RecordIdentity(current.task.string("project_id")),
                      let service = response["service"] as? [String:Any],service["store_incarnation"] as? String == current.service.string("store_incarnation"),
                      let collections = response["collections"] as? [String:Any] else {throw TicketPageError.invalid("selected_records.identity")}
                guard response["complete"] as? Bool == true else {
                    selectedRecordsLoading = false
                    selectedRecordsError = "More than 200 current actionable records require attention. Inspect their bounded history pages; omitted current records cannot establish completion."
                    return
                }
                for key in ["manifests","review_requests","reviews","findings","finding_resolutions","attempts","attachments","requests","source_executions","task_aliases","task_sessions","messages","relations","tasks","sessions"] {
                    guard collections[key] is [[String:Any]] else {throw TicketPageError.invalid("selected_records."+key)}
                }
                selectedRecordCollections = collections;fullSelectedRecordID = RecordIdentity(id);selectedRecordsLoading = false
                acceptServiceRead();scheduleSelectedEligibility(for:detail)
            } catch {
                guard selectedRecordsReadID == readID,selectedRecordLifetimeID == lifetime else {return}
                selectedRecordsLoading = false
                if isReadCancellation(error) || !current() {return}
                selectedRecordsError = selectedRecordFailure(error,operation:"work and review records")
            }
        }
    }
    private func scheduleSelectedTicket(for selection: Detail?, cursor: String? = nil, coalesce: Bool = false) {
        if coalesce, case .task(let id) = selection, selectedTicketLoading, selectedTicketRead != nil,
           selectedReadEpoch == contentEpoch, selectedReadTaskID == RecordIdentity(id), selectedReadScope == projectID.map(RecordIdentity.init) { return }
        cancelSelectedRecordRecovery()
        selectedTicketRead?.cancel(); selectedTicketReadID = UUID();selectedRecordsReadID = UUID()
        recordHistoryRead?.cancel();recordHistoryObservation.cancel(clear:true)
        selectedWorkRead?.cancel()
        if fullSelectedRecordID != nil {selectedRecordsLoading = true}
        guard case .task(let id) = selection else {selectedStaleSince = nil;selectedInstalledChange = selectedChange;selectedTicketDisplay = nil;fullSelectedRecordID = nil;selectedRecordCollections = [:];selectedRecordsLoading = false;selectedRecordsError = nil;selectedTicketLoading = false;return}
        if selectedTicketDisplay.map({RecordIdentity($0.task.id) != RecordIdentity(id)}) ?? true {selectedTicketDisplay = nil;fullSelectedRecordID = nil;selectedRecordCollections = [:];selectedRecordsLoading = false;selectedRecordsError = nil}
        let scope = projectID.map(RecordIdentity.init)
        if selectedTicketDisplay == nil, cursor == nil,
           let cached = cachedSelectedTickets.last(where: { $0.scope == scope && RecordIdentity($0.value.task.id) == RecordIdentity(id) }) {
            selectedTicketDisplay = cached.value; selectedTicketFromCache = true; screenTiming.cached(.ticketDetail, true)
        }
        guard startedLiveUpdates else {return}
        let readID = selectedTicketReadID, recordsReadID = selectedRecordsReadID
        selectedReadEpoch = contentEpoch; selectedReadTaskID = RecordIdentity(id); selectedReadScope = scope
        selectedTicketLoading = true;selectedTicketError = nil;selectedTicketMissing = false
        selectedTicketRead = Task { [weak self] in
            guard let self else {return}
            let start = ProcessInfo.processInfo.systemUptime
            var outcome = "ignored:fenced"
            defer { self.logLiveRead("selected_ticket",start:start,outcome:outcome) }
            do {
                var p: [String:Any] = ["task_id":id,"detail_level":"ui"]
                if let cursor {p["history_cursor"] = cursor}
                let response: [String:Any]
                do {response = try await self.request("task_context",p, ifCurrent: { self.selectedTicketReadID == readID && self.isSelectedTicket(id) && self.projectID.map(RecordIdentity.init) == scope })}
                catch let error as ChecklistError where cursor != nil && error.code == "CURSOR_RESET" {
                    guard !Task.isCancelled,self.selectedTicketReadID == readID,self.isSelectedTicket(id) else {return}
                    // One fresh-head read after the conversation changed. This
                    // never retries a mutation or revives an obsolete selection.
                    response = try await self.request("task_context",["task_id":id,"detail_level":"ui"], ifCurrent: { self.selectedTicketReadID == readID && self.isSelectedTicket(id) && self.projectID.map(RecordIdentity.init) == scope })
                }
                guard !Task.isCancelled,self.selectedTicketReadID == readID,self.isSelectedTicket(id) else {return}
                let value = try SelectedTicketDisplay(response:response)
                guard RecordIdentity(value.task.id) == RecordIdentity(id) else {throw TicketPageError.invalid("selected_ticket.identity")}
                let changedStore = !self.storeIncarnation.isEmpty && self.storeIncarnation != value.service.string("store_incarnation")
                if changedStore {
                    self.fullSnapshotAvailable = false;self.fullSnapshotDirty = true
                    self.ticketPageRead?.cancel();self.ticketPageReadID = UUID();self.ticketPages.invalidate();self.ticketCatalog.clear();self.pagedTicketWorkspace = nil
                    self.fullSelectedRecordID = nil;self.selectedRecordCollections = [:];self.selectedRecordsLoading = false
                    self.invalidateSelectedEligibility()
                }
                self.scopedReadGeneration = UUID()
                self.selectedTicketDisplay = value;self.cacheSelectedTicket(value, scope:scope)
                self.selectedTicketLoading = false;self.acceptServiceRead()
                self.selectedReadInstalledID = readID; outcome = "installed"
                self.selectedInstalledChange = self.selectedChange; self.selectedStaleSince = nil
                if changedStore {self.scheduleTicketPage(force:true)}
                if self.fullSelectedRecordLoaded(id) {self.loadFullSelectedRecord(id)}
                self.scheduleSelectedEligibility(for:self.detail)
            } catch {
                guard self.selectedTicketReadID == readID else {return}
                self.selectedTicketLoading = false
                if self.isReadCancellation(error) {
                    if self.selectedRecordsReadID == recordsReadID {self.selectedRecordsLoading = false}
                    return
                }
                if let failure = error as? ChecklistError, ["NOT_FOUND", "FORBIDDEN", "DENIED"].contains(failure.code) {
                    self.cachedSelectedTickets = []; self.selectedTicketDisplay = nil
                    self.fullSelectedRecordID = nil; self.selectedRecordCollections = [:]; self.selectedRecordsLoading = false
                }
                outcome = "failed:" + ((error as? ChecklistError)?.code ?? "INVALID_RESPONSE")
                self.selectedRetryAfter = ProcessInfo.processInfo.systemUptime + Double(self.liveRetryPause) / 1_000_000_000
                self.selectedTicketError = "Could not load the selected ticket. Your draft is preserved."
                // A removed ticket (for example from an old desktop alert) shows the unavailable state (CL-59).
                self.selectedTicketMissing = (error as? ChecklistError)?.code == "NOT_FOUND"
            }
        }
    }

    private func invalidateSelectedTicketFreshness() {
        cancelSelectedRecordRecovery()
        guard case .task = detail else {return}
        markSelectedStale()
        selectedTicketRead?.cancel();selectedTicketReadID = UUID();selectedRecordsReadID = UUID()
        selectedTicketLoading = true;selectedTicketError = nil;selectedTicketMissing = false
        selectedRecordsLoading = fullSelectedRecordID != nil
    }

    private func invalidateSelectedEligibility() {
        selectedEligibilityRead?.cancel(); selectedEligibilityRead = nil
        selectedEligibility.invalidate()
    }
    private func scheduleSelectedEligibility(for selection: Detail?) {
        invalidateSelectedEligibility()
        guard connected, !refreshing, case .task(let id) = selection, let task = eligibilityTask(id),
              let request = selectedEligibility.begin(task: task, store: storeIncarnation) else { return }
        selectedEligibilityRead = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                let result = try await self.request("task_get", ["project_id": request.project, "task_id": request.task, "include_completion_eligibility": true])
                guard !Task.isCancelled, self.connected else { return }
                self.selectedEligibility.receive(Record(values: result), for: request, currentTask: self.eligibilityTask(request.task), store: self.storeIncarnation)
            } catch {
                guard !Task.isCancelled else { return }
                self.selectedEligibility.fail(request)
            }
        }
    }
    func projectName(_ id: String) -> String { project(id)?.string("name") ?? "Project" }
    func statuses(_ project: String) -> [Record] { (selectedTicketDisplay.flatMap {RecordIdentity($0.project.id) == RecordIdentity(project) ? $0.records("statuses") : nil} ?? selectedOther.flatMap {RecordIdentity($0.string("project_id"))==RecordIdentity(project) && $0.string("record_type")=="project" ? $0.records("detail_statuses") : nil} ?? ticketCatalog.statuses?.filter {RecordIdentity($0.string("project_id")) == RecordIdentity(project)} ?? snapshotRecords.records(in: "statuses", projectID: project)).filter { !$0.bool("retired") }.sorted { $0.integer("sort_order") < $1.integer("sort_order") } }
    func tags(_ project: String) -> [Record] { (selectedTicketDisplay.flatMap {RecordIdentity($0.project.id) == RecordIdentity(project) ? $0.records("tags") : nil} ?? selectedOther.flatMap {RecordIdentity($0.string("project_id"))==RecordIdentity(project) && $0.string("record_type")=="project" ? $0.records("detail_tags") : nil} ?? ticketCatalog.tags?.filter {RecordIdentity($0.string("project_id")) == RecordIdentity(project)} ?? snapshotRecords.records(in: "tags", projectID: project)).filter { !$0.bool("retired") } }
    var preparedTicketWorkspace: PreparedTicketWorkspace? { usesTicketPages ? pagedTicketWorkspace : ticketPreparation.prepared }
    var ticketPageLoading: Bool { ticketPages.loading }
    var ticketPageError: String? { ticketPages.error }
    var ticketPageNextCursor: String? { ticketPages.page?.nextCursor }
    var ticketPagePreviousCursor: String? { ticketPages.page?.previousCursor }
    var ticketPageShownCount: Int { ticketPages.page?.tasks.count ?? 0 }
    var ticketPageMatchedCount: Int { ticketPages.page?.matchedCount ?? 0 }
    var overviewRequestTotal: Int { ticketPages.page?.overviewRequestCount ?? 0 }
    private var usesTicketPages: Bool { startedLiveUpdates && TicketWorkspaceSurface(page) != nil }
    private var ticketPageQuery: TicketPageQuery {
        TicketPageQuery(surface: page == .overview ? "overview" : page == .archived ? "archived" : "tickets", projectID: projectID, text: search, statusFilter: statusFilter, tagFilter: tagFilter, groupBy: viewGroupBy, orderBy: viewOrderBy, filters: listFilters)
    }
    func moveTicketPage(_ cursor: String) { scheduleTicketPage(cursor: cursor, force: true) }
    func retryTicketPage() { scheduleTicketPage(force: true) }

    private func scheduleTicketPage(cursor: String? = nil, force: Bool = false) {
        guard usesTicketPages, !restoringPreferences, ticketUpdateDepth == 0 else { return }
        let query = ticketPageQuery
        let switched = ticketPages.query != query
        if switched {
            ticketPages.invalidate()
            if let cached = cachedTickets.last(where: { $0.query == query }) {
                ticketPages = cached.value
                if let page = ticketPages.page {ticketCatalog.restoreFilters(page)}
            }
            pagedTicketWorkspace = ticketPages.prepared(expansion: ticketExpansion)
        }
        guard force || switched || (ticketPages.page == nil && !ticketPages.loading) else { return }
        ticketPageRead?.cancel()
        ticketPageRead = Task { [weak self] in _ = await self?.readTicketPage(query: query, cursor: cursor) }
    }
    @discardableResult private func readTicketPage(query: TicketPageQuery, cursor: String?) async -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        var outcome = "ignored:fenced"
        defer { logLiveRead(query.surface,start:start,outcome:outcome) }
        let scope = liveScope
        let observed = ticketPages.begin(query: query, cursor: cursor)
        let readID = UUID(); ticketPageReadID = readID
        pagedTicketWorkspace = ticketPages.prepared(expansion: ticketExpansion)
        do {
            let result = try await request("task_list", query.parameters(cursor: cursor), ifCurrent: { self.ticketPageReadID == readID && self.usesTicketPages && self.ticketPageQuery == query })
            guard !Task.isCancelled, ticketPageReadID == readID, usesTicketPages, ticketPageQuery == query else { return false }
            let page = try TicketPage(response: result)
            let oldIncarnation = storeIncarnation
            let changedStore = !oldIncarnation.isEmpty && oldIncarnation != page.service.string("store_incarnation")
            if changedStore {
                fullSnapshotAvailable = false;fullSnapshotDirty = true
                invalidateSelectedTicketFreshness()
                invalidateSelectedEligibility()
            }
            guard ticketPages.receive(page, for: observed) else { outcome = "ignored:installation_rejected"; return false }
            ticketCatalog.install(page)
            cacheTicketPage(query)
            outcome = "installed"
            scopedReadGeneration = UUID()
            pagedTicketWorkspace = ticketPages.prepared(expansion: ticketExpansion)
            guard pagedTicketWorkspace != nil else { outcome = "failed:INVALID_PAGE_ORDER"; return false }
            if scope == liveScope { visibleInstalledChange = visibleChange; visibleStaleSince = nil }
            acceptServiceRead()
            if eventCursor == nil, pendingCoverageScope == nil {advanceEventCursor(result["event_cursor"] as? String ?? page.contentCursor,source:"tickets")}
            if changedStore {scheduleSelectedTicket(for:detail)}
        } catch {
            if isReadCancellation(error) { ticketPages.cancel(observed); return false }
            guard ticketPageReadID == readID else { return false }
            connectionAttempted = true
            ticketPages.fail(observed)
            outcome = "failed:" + ((error as? ChecklistError)?.code ?? "INVALID_RESPONSE")
            visibleRetryAfter = ProcessInfo.processInfo.systemUptime + Double(liveRetryPause) / 1_000_000_000
            return false
        }
        return !Task.isCancelled
    }
    func readRecordHistory(_ task:Record,family:String,cursor:String? = nil) {
        guard let display=selectedTicketDisplay,RecordIdentity(display.task.id)==RecordIdentity(task.id),selectedTicketCurrent(task.id) else{return}
        recordHistoryRead?.cancel();recordHistoryNotice = nil
        let query=WorkspacePageQuery(surface:"record_history",project:task.string("project_id"),text:family,record:task.id)
        let generation=recordHistoryObservation.begin(query),lifetime=selectedRecordLifetimeID,project=projectID
        recordHistoryRead=Task {[weak self] in
            guard let self else{return}
            @MainActor func current() -> Bool {self.recordHistoryObservation.isCurrent(generation) && self.selectedRecordScopeCurrent(display,lifetime:lifetime,project:project)}
            do {
                let result = try await self.selectedRecordResponse(display,level:"ui_history",family:family,cursor:cursor,isCurrent:current)
                guard !Task.isCancelled,current(),self.selectedTicketDisplay?.contextCursor == result.context else {throw CancellationError()}
                guard let service=result.response["service"] as? [String:Any],service["store_incarnation"] as? String == display.service.string("store_incarnation") else {throw TicketPageError.invalid("selected_history.identity")}
                if try self.recordHistoryObservation.receive(result.response,query:query,generation:generation) {
                    if result.restarted {self.recordHistoryNotice = "This ticket changed. History restarted at the latest records."}
                    self.acceptServiceRead()
                }
            } catch {
                if self.isReadCancellation(error) || !current() {self.recordHistoryObservation.cancel(generation)}
                else {self.recordHistoryObservation.fail(generation,message:self.selectedRecordFailure(error,operation:"ticket history"))}
            }
        }
    }
    private var workspaceQuery: WorkspacePageQuery {
        WorkspacePageQuery(surface:page == .needsYou ? needsSurface : page == .epics ? "epics" : "activity",project:projectID,text:search,archived:workspaceArchived)
    }
    func configureWorkspace(surface:String? = nil,archived:Bool? = nil) {
        if let surface {needsSurface=surface};if let archived {workspaceArchived=archived}
        scheduleWorkspacePage(force:true)
    }
    func moveWorkspacePage(_ cursor:String) {
        let index = cursor == workspaceNext ? workspacePageIndex + 1 : max(0,workspacePageIndex - 1)
        scheduleWorkspacePage(cursor:cursor,force:true,pageIndex:index)
    }

    // CL-53: Overview groups by what needs the owner. Each group is one small page with its exact
    // total from existing records; "Show all" pages one group. "human_tasks" only keeps the Needs You count.
    static let overviewGroups: [(surface: String, title: String)] = [("requests", "Owner requests"), ("needs_review", "Ready for review"),
        ("needs_pickup", "Ready for pickup"), ("needs_active", "Active work"), ("needs_recovery", "Recovery or blocked"),
        ("needs_quiet", "Stale checkpoints"), ("needs_done_today", "Done today")]
    let overviewObservations: [String: WorkspacePageObservation] = Dictionary(uniqueKeysWithValues: (overviewGroups.map(\.surface) + ["human_tasks", "recent_reviews", "completed_since"]).map { ($0, WorkspacePageObservation()) })
    /// CL-67: the digest lists tickets completed since the owner's previous Overview visit.
    @Published private(set) var overviewDigestSince: Date?
    /// Each Overview visit shows completions since the previous visit and keeps that start while it is shown;
    /// the next visit starts from this one (CL-67).
    private var overviewVisitActive = false
    private var overviewVisitProject: String?
    private var nextDigestRead: Task<Void,Never>?
    private func prepareOverviewVisit() {
        guard !overviewVisitActive else { return }
        overviewVisitActive = true
        overviewVisitProject = projectID
        overviewDigestSince = preferences.object(forKey: "overviewLastVisit") as? Date ?? Date().addingTimeInterval(-86400)
        preferences.set(Date(), forKey: "overviewLastVisit")
    }
    func beginOverviewVisit() {
        guard !overviewVisitActive else { return }
        prepareOverviewVisit()
        scheduleOverviewNeeds(force: true)
    }
    func endOverviewVisit() {
        guard overviewVisitActive else {return}
        overviewVisitActive = false; resetOverviewScope()
        // The next visit has a new digest query. Prepare that exact scope after
        // leaving, rather than replaying the previous visit's completed rows.
        guard page != .overview, startedLiveUpdates, connected,
              let since = preferences.object(forKey:"overviewLastVisit") as? Date else {return}
        var query = WorkspacePageQuery(surface:"completed_since",project:overviewVisitProject)
        query.limit = 20;query.since = Self.digestFormatter.string(from:since)
        let epoch = contentEpoch
        nextDigestRead?.cancel()
        nextDigestRead = Task { [weak self] in
            guard let self else {return}
            do {
                let response = try await self.request("workspace_page",query.parameters(),ifCurrent:{self.contentEpoch == epoch})
                guard !Task.isCancelled, self.contentEpoch == epoch else {return}
                let page = try WorkspacePage(response,query:query)
                self.cacheWorkspacePage(page)
            } catch { /* Navigation prefetch has no visible failure or retry loop. */ }
        }
    }
    static func overviewTitle(_ surface: String) -> String {
        surface == "completed_since" ? "Completed since your last visit" : surface == "recent_reviews" ? "Latest review results" : overviewGroups.first { $0.surface == surface }?.title ?? "Overview"
    }
    func clearOverviewDigest() {
        overviewDigestSince = Date(); preferences.set(Date(), forKey: "overviewLastVisit")
        scheduleOverviewNeeds(only: "completed_since", force: true)
    }
    private static let digestFormatter = ISO8601DateFormatter()
    /// One owned loader serves scheduling, refresh and live coverage. A timed-out combined read
    /// switches this visit/project to sequential reads; focus and digest changes keep that mode.
    private var overviewRead: Task<Bool,Never>?
    private var overviewReadID = UUID()
    private var overviewSequential = false
    private let overviewDefaultDigestSince = Date().addingTimeInterval(-86400)
    private struct OverviewRead {
        let query: WorkspacePageQuery
        let cursor: String?
        let generation: UUID
    }
    private var overviewPending: [String: OverviewRead] = [:]
    /// The one group shown in full with paging; nil shows every group's first rows.
    @Published var overviewFocus: String? { didSet { if overviewFocus != oldValue { scheduleOverviewNeeds(force: true) } } }
    func overviewQuery(_ surface: String) -> WorkspacePageQuery {
        var query = WorkspacePageQuery(surface: surface, project: projectID)
        query.limit = surface == "human_tasks" ? 1 : overviewFocus == surface ? 50 : surface == "recent_reviews" ? 60 : surface == "completed_since" ? 20 : 5
        if surface == "completed_since" { query.since = Self.digestFormatter.string(from: overviewDigestSince ?? overviewDefaultDigestSince) }
        return query
    }
    func scheduleOverviewNeeds(cursor: String? = nil, only: String? = nil, force: Bool = false) {
        guard startedLiveUpdates, !restoringPreferences, page == .overview else { return }
        _ = startOverviewRead(cursor: cursor, only: only, force: force)
    }
    private var shownOverviewSurfaces: [String] {
        overviewObservations.keys.sorted().filter { overviewFocus == nil || overviewFocus == $0 || $0 == "human_tasks" }
    }
    private func resetOverviewScope(clear: Bool = false) {
        retireOverviewRead(); overviewSequential = false
        if clear { for observation in overviewObservations.values { observation.cancel(clear: true) } }
    }
    private func retireOverviewRead() {
        overviewReadID = UUID(); overviewRead?.cancel(); overviewRead = nil
        for (surface, read) in overviewPending { overviewObservations[surface]?.cancel(read.generation) }
        overviewPending = [:]
    }
    /// Freeze every query and cursor before yielding. Even the combined phase owns its pending
    /// surfaces, so a narrower Retry can finish outstanding groups without reviving completed ones.
    private func startOverviewRead(cursor: String? = nil, only: String? = nil, force: Bool, retry: Bool = false) -> Task<Bool,Never>? {
        guard page == .overview, !Task.isCancelled else { return nil }
        prepareOverviewVisit()
        let surfaces = shownOverviewSurfaces
        for surface in surfaces {
            _ = restoreWorkspacePage(overviewObservations[surface]!, query: overviewQuery(surface))
        }
        let due = surfaces.filter { surface in
            let query = overviewQuery(surface), observation = overviewObservations[surface]!
            return (only == nil || only == surface) && (force || observation.needsRefresh || retry && observation.error != nil || observation.query != query || observation.page == nil && !observation.loading && observation.error == nil)
        }
        guard !due.isEmpty else { return overviewRead }
        let previous = overviewPending
        retireOverviewRead()
        let combined = only == nil && overviewFocus == nil && !overviewSequential && due.count == surfaces.count
        let order = combined ? surfaces : surfaces.filter { due.contains($0) || previous[$0] != nil }
        for surface in order {
            let query = overviewQuery(surface)
            let nextCursor = surface == only ? cursor : previous[surface].flatMap { $0.query == query && !due.contains(surface) ? $0.cursor : nil }
            overviewPending[surface] = OverviewRead(query: query, cursor: nextCursor, generation: overviewObservations[surface]!.begin(query))
        }
        let id = overviewReadID, focus = overviewFocus, reads = overviewPending
        let scope = liveScope
        let task = Task { [weak self] in
            guard let self else { return false }
            defer {
                // An obsolete task may never clear its replacement's pending set or loading state.
                if self.overviewReadID == id {
                    for (surface, read) in self.overviewPending { self.overviewObservations[surface]?.cancel(read.generation) }
                    self.overviewPending = [:]; self.overviewRead = nil
                }
            }
            guard !Task.isCancelled, self.overviewReadCurrent(id, focus: focus, reads: reads) else { return false }
            if combined {
                guard await self.readOverviewGroups(id: id, focus: focus, reads: reads) else { return false }
            }
            var remaining = order
            var allInstalled = true
            var attemptedVersions: [String:String] = [:]
            while true {
                guard self.overviewReadCurrent(id, focus: focus, reads: reads), !Task.isCancelled else { return false }
                if remaining.isEmpty {
                    let version = self.contentVersion ?? ""
                    // A real commit learned midway through fallback invalidates
                    // earlier accepted pages. Only those pages become due again,
                    // once for the newly known version; failures never auto-retry.
                    remaining = order.filter {
                        let observation = self.overviewObservations[$0]!
                        return observation.page == nil && observation.error == nil && attemptedVersions[$0] != version
                    }
                    guard !remaining.isEmpty else { break }
                    for surface in remaining {
                        let previous = reads[surface]!
                        self.overviewPending[surface] = OverviewRead(query:previous.query, cursor:previous.cursor,
                            generation:self.overviewObservations[surface]!.begin(previous.query))
                    }
                }
                let surface = remaining.removeFirst()
                guard let read = self.overviewPending[surface] else { continue }
                if !(await self.readOverviewNeed(surface, read: read, id: id, focus: focus, reads: reads)) {
                    guard !Task.isCancelled, self.overviewReadCurrent(id,focus:focus,reads:reads) else { return false }
                    self.overviewObservations[surface]?.cancel(read.generation)
                    allInstalled = false
                }
                self.overviewPending.removeValue(forKey: surface)
                attemptedVersions[surface] = self.contentVersion ?? ""
            }
            let complete = self.shownOverviewSurfaces.allSatisfy { self.overviewObservations[$0]?.page != nil && self.overviewObservations[$0]?.needsRefresh == false && self.overviewObservations[$0]?.error == nil }
            if allInstalled, complete, !Task.isCancelled, self.liveScope == scope {
                self.visibleInstalledChange = self.visibleChange; self.visibleStaleSince = nil
            }
            return allInstalled && !Task.isCancelled
        }
        overviewRead = task
        return task
    }
    private func overviewReadCurrent(_ id: UUID, focus: String?, reads: [String: OverviewRead]) -> Bool {
        overviewReadID == id && page == .overview && overviewFocus == focus && reads.allSatisfy { overviewQuery($0.key) == $0.value.query }
    }
    func moveOverviewPage(_ surface: String, cursor: String) { scheduleOverviewNeeds(cursor: cursor, only: surface, force: true) }
    @discardableResult private func readOverviewNeeds(force:Bool = true,retry:Bool = false) async -> Bool {
        guard let read = startOverviewRead(force:force,retry:retry) else { return false }
        return await awaitOverviewRead(read, id: overviewReadID)
    }
    private func awaitOverviewRead(_ read: Task<Bool,Never>, id: UUID) async -> Bool {
        return await withTaskCancellationHandler {
            let accepted = await read.value
            return accepted && overviewReadID == id && !Task.isCancelled
        } onCancel: {
            read.cancel()
            Task { @MainActor [weak self] in
                if self?.overviewReadID == id { self?.retireOverviewRead() }
            }
        }
    }
    /// Returns true after either settling the combined result or selecting the bounded fallback.
    private func readOverviewGroups(id: UUID, focus: String?, reads: [String: OverviewRead]) async -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        var outcome = "ignored:fenced"
        defer { logLiveRead("overview",start:start,outcome:outcome) }
        var params: [String: Any] = ["surface": "overview", "since": reads["completed_since"]!.query.since]
        params["project_id"] = reads["completed_since"]!.query.project
        do {
            let response = try await request("workspace_page", params, ifCurrent: { self.overviewReadCurrent(id, focus:focus, reads:reads) })
            guard !Task.isCancelled, overviewReadCurrent(id, focus: focus, reads: reads) else { return false }
            let groups = response["groups"] as? [String: [String: Any]] ?? [:]
            var installed = true
            var installedCatalog = false
            for (surface, read) in reads {
                if var group = groups[surface] {
                    // Combined replies carry shared catalogs/identity once. Legacy self-contained
                    // groups still parse through the same strict single-page validator.
                    for key in ["projects", "service", "needs_you_count", "content_cursor"] where group[key] == nil { group[key] = response[key] }
                    if !installOverviewPage(group, surface: surface, read: read, eventCursor: response["event_cursor"] as? String ?? response["content_cursor"] as? String, installCatalog: !installedCatalog || groups[surface]?["projects"] != nil) { installed = false }
                    else { installedCatalog = true }
                }
                else { overviewObservations[surface]?.fail(read.generation); installed = false }
                overviewPending.removeValue(forKey: surface)
            }
            guard installed else { outcome = "failed:INVALID_RESPONSE"; return false }
            outcome = "installed"
        } catch {
            guard !isReadCancellation(error), overviewReadCurrent(id, focus: focus, reads: reads) else { return false }
            if let timeout = error as? ChecklistError, timeout.code == "OUTCOME_UNKNOWN",
               timeout.details["reason"] as? String == "reply_timeout", timeout.details["command_id"] == nil {
                overviewSequential = true // Keep loading/retained pages; do not publish ten transient errors.
                outcome = "ignored:timeout_fallback"
                return true
            }
            connectionAttempted = true
            for (surface, read) in reads { overviewObservations[surface]?.fail(read.generation) }
            overviewPending = [:]
            outcome = "failed:" + ((error as? ChecklistError)?.code ?? "INVALID_RESPONSE")
            visibleRetryAfter = ProcessInfo.processInfo.systemUptime + Double(liveRetryPause) / 1_000_000_000
            return false
        }
        return !Task.isCancelled
    }
    @discardableResult private func installOverviewPage(_ response: [String: Any], surface: String, read: OverviewRead, eventCursor: String? = nil, installCatalog: Bool = true) -> Bool {
        let observation = overviewObservations[surface]!
        do {
            if try observation.receive(response, query: read.query, generation: read.generation), let installed = observation.page {
                if installCatalog { ticketCatalog.install(workspace: installed) }; cacheWorkspacePage(installed); acceptServiceRead()
                // Incidental pages never advance an established live coverage interval.
                if self.eventCursor == nil, pendingCoverageScope == nil { advanceEventCursor(eventCursor ?? response["event_cursor"] as? String ?? installed.contentCursor,source:"overview") }
                return true
            }
        } catch { observation.fail(read.generation) }
        return false
    }
    private func readOverviewNeed(_ surface: String, read: OverviewRead, id: UUID, focus: String?, reads: [String: OverviewRead]) async -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        var outcome = "ignored:fenced"
        defer { logLiveRead(surface,start:start,outcome:outcome) }
        do {
            let response = try await request("workspace_page", read.query.parameters(cursor: read.cursor), ifCurrent: { self.overviewReadCurrent(id, focus:focus, reads:reads) })
            guard !Task.isCancelled, overviewReadCurrent(id, focus: focus, reads: reads) else { return false }
            guard installOverviewPage(response, surface: surface, read: read) else {
                outcome = overviewObservations[surface]?.error == nil ? "ignored:installation_rejected" : "failed:INVALID_RESPONSE"
                return false
            }
            outcome = "installed"
        } catch {
            guard !isReadCancellation(error), overviewReadCurrent(id, focus: focus, reads: reads) else { return false }
            connectionAttempted = true; overviewObservations[surface]?.fail(read.generation)
            outcome = "failed:" + ((error as? ChecklistError)?.code ?? "INVALID_RESPONSE")
            visibleRetryAfter = ProcessInfo.processInfo.systemUptime + Double(liveRetryPause) / 1_000_000_000
            return false
        }
        return !Task.isCancelled
    }
    func retryWorkspacePage() {scheduleWorkspacePage(force:true)}
    private func scheduleWorkspacePage(cursor:String? = nil,force:Bool=false,pageIndex:Int? = nil) {
        guard startedLiveUpdates,!restoringPreferences,!usesTicketPages else{return}
        if page == .overview {scheduleOverviewNeeds(force:force);return}
        let switched = workspaceObservation.query != workspaceQuery
        if let index = restoreWorkspacePage(workspaceObservation, query: workspaceQuery) { workspacePageIndex = index }
        else if switched { workspaceObservation.cancel(clear:true); workspacePageIndex = 0 }
        guard force || switched || workspaceObservation.page == nil && !workspaceObservation.loading else{return}
        workspaceRead?.cancel()
        workspaceRead=Task {[weak self] in _ = await self?.readWorkspacePage(cursor:cursor,pageIndex:pageIndex)}
    }
    @discardableResult private func readWorkspacePage(cursor:String?,pageIndex:Int? = nil) async -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        var outcome = "ignored:fenced"
        let query=workspaceQuery
        defer { logLiveRead(query.surface,start:start,outcome:outcome) }
        let targetIndex = pageIndex ?? (workspaceObservation.query == query && workspaceObservation.page != nil ? workspacePageIndex : 0)
        let scope = liveScope
        let id=workspaceObservation.begin(query)
        func current() -> Bool { !Task.isCancelled && !usesTicketPages && workspaceQuery == query && workspaceObservation.isCurrent(id) }
        do {
            var response: [String:Any]
            var index = cursor == nil ? 0 : targetIndex
            do { response = try await request("workspace_page",query.parameters(cursor:cursor), ifCurrent:current) }
            catch {
                guard current(), cursor != nil, (error as? ChecklistError)?.code == "CURSOR_RESET" else { throw error }
                index = 0
                response = try await request("workspace_page",query.parameters(), ifCurrent:current)
            }
            // Workspace cursors include event coverage and expire after a change. Re-seek the
            // current page with fresh tokens, keeping all intermediate pages off screen.
            while current(), index < targetIndex {
                let page = try WorkspacePage(response,query:query)
                guard let next = page.next else { break }
                response = try await request("workspace_page",query.parameters(cursor:next), ifCurrent:current)
                index += 1
            }
            guard current() else {return false}
            if try workspaceObservation.receive(response,query:query,generation:id) {
                if let installed = workspaceObservation.page { ticketCatalog.install(workspace:installed); cacheWorkspacePage(installed, index: index) }
                workspacePageIndex = index
                outcome = "installed"
                if scope == liveScope { visibleInstalledChange = visibleChange; visibleStaleSince = nil }
                acceptServiceRead();if eventCursor == nil, pendingCoverageScope == nil {advanceEventCursor(response["event_cursor"] as? String ?? workspaceObservation.page?.contentCursor,source:"workspace")}
            } else { outcome = "ignored:installation_rejected"; return false }
        } catch {
            if isReadCancellation(error) {workspaceObservation.cancel(id);return false}
            connectionAttempted = true;workspaceObservation.fail(id)
            outcome = "failed:" + ((error as? ChecklistError)?.code ?? "INVALID_RESPONSE")
            visibleRetryAfter = ProcessInfo.processInfo.systemUptime + Double(liveRetryPause) / 1_000_000_000
            return false
        }
        return !Task.isCancelled
    }
    private func scheduleOtherDetail(for detail:Detail?) {
        let taskQuery=groupTasksObservation.query,candidateQuery=groupCandidatesObservation.query
        let id:String?
        switch detail {case .request(let value),.group(let value),.project(let value):id=value;default:id=nil}
        let sameRecord=id.map {RecordIdentity($0)==otherDetailObservation.query.map {RecordIdentity($0.record)}} ?? false
        otherDetailRead?.cancel();otherDetailObservation.cancel(clear:!sameRecord)
        groupTasksRead?.cancel();groupTasksObservation.cancel(clear:!sameRecord)
        groupCandidatesRead?.cancel();groupCandidatesObservation.cancel(clear:!sameRecord)
        guard startedLiveUpdates,let detail,let id else{return}
        let query=WorkspacePageQuery(surface:"record",project:nil,record:id)
        if case .project = detail, restoreWorkspacePage(otherDetailObservation,query:query) != nil {
            screenTiming.cached(.cleanup, ticketCleanupReceipts.isCached(scope:cleanupReceiptScope(id)))
        }
        let generation=otherDetailObservation.begin(query)
        otherDetailRead=Task {[weak self] in
            guard let self else{return}
            do {
                let response=try await self.request("workspace_page",query.parameters())
                guard !Task.isCancelled,self.detail==detail else{return}
                if try self.otherDetailObservation.receive(response,query:query,generation:generation) {
                    if case .project = detail, let installed = self.otherDetailObservation.page {self.cacheWorkspacePage(installed)}
                    if let group=self.selectedOther,group.string("record_type")=="group" {
                        if let taskQuery,RecordIdentity(taskQuery.record)==RecordIdentity(group.id) {self.loadGroupTasks(group,closed:taskQuery.archived)}
                        if let candidateQuery,RecordIdentity(candidateQuery.record)==RecordIdentity(group.id) {self.loadGroupCandidates(group,closed:candidateQuery.archived)}
                    }
                }
            } catch {
                if self.isReadCancellation(error) {self.otherDetailObservation.cancel(generation)}
                else {
                    guard self.detail == detail,self.otherDetailObservation.isCurrent(generation) else {return}
                    if ["FORBIDDEN","DENIED","NOT_FOUND"].contains((error as? ChecklistError)?.code ?? "") {
                        self.cachedWorkspace.removeAll {$0.query == query}
                        self.otherDetailObservation.discardContent()
                    }
                    self.otherDetailObservation.fail(generation)
                }
            }
        }
    }
    func cleanupReceiptScope(_ project: String) -> String {
        let version = otherDetailObservation.page?.service.string("read_version") ?? ""
        let identity = version.isEmpty ? otherDetailObservation.readScope.uuidString : version
        return project + ":" + storeIncarnation + ":" + archivePreviewEpoch.uuidString + ":" + identity
    }
    func retryOtherDetail() {scheduleOtherDetail(for:detail)}
    func loadGroupTasks(_ group:Record,closed:Bool,cursor:String? = nil) {
        groupTasksRead?.cancel()
        let query=WorkspacePageQuery(surface:group.string("kind")=="triage" ? "triage_tasks" : "epic_tasks",project:group.string("project_id"),record:group.id,archived:closed)
        let generation=groupTasksObservation.begin(query)
        groupTasksRead=Task {[weak self] in
            guard let self else{return}
            do {let value=try await self.request("workspace_page",query.parameters(cursor:cursor));guard !Task.isCancelled,self.detail == .group(group.id) else{return};_=try self.groupTasksObservation.receive(value,query:query,generation:generation)}
            catch {if self.isReadCancellation(error) {self.groupTasksObservation.cancel(generation)} else {self.groupTasksObservation.fail(generation)}}
        }
    }
    func loadGroupCandidates(_ group:Record,closed:Bool,cursor:String? = nil) {
        groupCandidatesRead?.cancel()
        let query=WorkspacePageQuery(surface:group.string("kind")=="triage" ? "triage_candidates" : "epic_candidates",project:group.string("project_id"),record:group.id,archived:closed)
        let generation=groupCandidatesObservation.begin(query)
        groupCandidatesRead=Task {[weak self] in
            guard let self else{return}
            do {let value=try await self.request("workspace_page",query.parameters(cursor:cursor));guard !Task.isCancelled,self.detail == .group(group.id) else{return};_=try self.groupCandidatesObservation.receive(value,query:query,generation:generation)}
            catch {if self.isReadCancellation(error) {self.groupCandidatesObservation.cancel(generation)} else {self.groupCandidatesObservation.fail(generation)}}
        }
    }

    /// Compatibility path for existing full-index consumers. This is explicit
    /// loading, not a claim that selected-detail/history paging has been completed.
    func ensureFullSnapshot() async {
        guard fullSnapshotDirty || !fullSnapshotAvailable else { return }
        await refreshFullSnapshot(quiet: true)
    }

    // Batch property edits synchronously before preparing the visible query.
    func withTicketViewUpdate(_ changes: () -> Void) {
        ticketUpdateDepth += 1
        defer { ticketUpdateDepth -= 1; prepareTicketWorkspace() }
        changes()
    }
    func updateTicketWorkspaceExpansion(_ expansion: TicketWorkspaceExpansion) {
        guard ticketExpansion != expansion else { return }
        ticketExpansion = expansion
        prepareTicketWorkspace()
    }
    private func prepareTicketWorkspace() {
        guard !restoringPreferences, ticketUpdateDepth == 0 else { return }
        guard let surface = TicketWorkspaceSurface(page) else { ticketPreparation.reset();ticketPageRead?.cancel();ticketPageReadID = UUID();scheduleWorkspacePage();return }
        workspaceRead?.cancel();workspaceObservation.cancel(clear:true)
        if usesTicketPages {
            pagedTicketWorkspace = ticketPages.prepared(expansion: ticketExpansion)
            scheduleTicketPage()
            return
        }
        ticketPageRead?.cancel(); ticketPageReadID = UUID()
        let request = TicketWorkspaceRequest(snapshotEpoch: ticketSnapshotEpoch,
            query: TicketWorkspaceQuery(surface: surface, projectID: projectID, rawSearch: search, statusFilter: statusFilter, tagFilter: tagFilter),
            ordering: TicketWorkspaceOrdering(groupBy: viewGroupBy, orderBy: viewOrderBy), expansion: ticketExpansion)
        ticketPreparation.prepare(snapshot: snapshotRecords, request: request)
    }

    func select(_ page: Page, project: String? = nil) {
        for surface in [ScreenTiming.Surface.overview, .tickets, .epics, .projectSwitch] { screenTiming.cancel(surface) }
        let switchedProject = projectID.map(RecordIdentity.init) != project.map(RecordIdentity.init)
        if switchedProject { screenTiming.begin(.projectSwitch) }
        let surface: ScreenTiming.Surface? = page == .overview ? .overview : page == .tasks ? .tickets : page == .epics ? .epics : nil
        if let surface { screenTiming.begin(surface) }
        restoringPreferences = true
        self.page = page; projectID = project
        loadTaskView()
        restoringPreferences = false
        preferences.set(page.rawValue, forKey: "lastPage")
        preferences.set(project, forKey: "lastProject")
        prepareTicketWorkspace()
        if usesTicketPages { scheduleTicketPage(force:true) }
        else { scheduleWorkspacePage(force:true) }
        let cached = screenContentReady
        if let surface { screenTiming.cached(surface, cached) }
        if switchedProject { screenTiming.cached(.projectSwitch, cached) }
    }
    var screenContentReady: Bool {
        if page == .overview { return shownOverviewSurfaces.allSatisfy { overviewObservations[$0]?.page != nil } }
        if usesTicketPages { return preparedTicketWorkspace != nil }
        return workspacePageLoaded
    }
    func loadTaskView() {
        let restoringBefore = restoringPreferences; restoringPreferences = true
        defer { restoringPreferences = restoringBefore; prepareTicketWorkspace() }
        ticketObservation.personalViews = personalViewStorage.load()
        ticketObservation.selectedPersonalViewID = preferences.string(forKey: "activePersonalView:" + (projectID ?? "overview"))
        let key = "taskView:" + (projectID ?? "overview")
        let personal = preferences.dictionary(forKey: key)
        let defaults = currentProject?.object("default_view") ?? [:]
        viewGroupBy = personal?["group_by"] as? String ?? defaults["group_by"] as? String ?? "status"
        viewOrderBy = personal?["order_by"] as? String ?? defaults["order_by"] as? String ?? "manual"
        let filters = preferences.dictionary(forKey: "taskFilters:" + (projectID ?? "overview"))
        search = filters?["search"] as? String ?? ""
        statusFilter = filters?["status"] as? String ?? "all"
        tagFilter = filters?["tag"] as? String ?? "all"
        if let data = preferences.data(forKey: "extendedTaskFilters:" + (projectID ?? "overview")), let saved = try? JSONDecoder().decode(TicketListFilters.self, from:data) { listFilters = saved } else { listFilters = TicketListFilters() }
    }
    private func saveTaskFilters() {
        guard !restoringPreferences else { return }
        preferences.set(["search": search, "status": statusFilter, "tag": tagFilter], forKey: "taskFilters:" + (projectID ?? "overview"))
        if let data = try? JSONEncoder().encode(listFilters) { preferences.set(data, forKey: "extendedTaskFilters:" + (projectID ?? "overview")) }
    }
    func saveTaskView(groupBy: String? = nil, orderBy: String? = nil) {
        withTicketViewUpdate {
            if let groupBy { viewGroupBy = groupBy }; if let orderBy { viewOrderBy = orderBy }
        }
        preferences.set(["group_by":viewGroupBy,"order_by":viewOrderBy], forKey: "taskView:" + (projectID ?? "overview"))
    }
    func useProjectTaskView() {
        for prefix in ["taskView:", "taskFilters:", "extendedTaskFilters:", "activePersonalView:"] { preferences.removeObject(forKey: prefix + (projectID ?? "overview")) }
        loadTaskView()
    }
    func open(_ detail: Detail) {
        screenTiming.cancel(.ticketDetail);screenTiming.cancel(.cleanup)
        if case .task(let id) = detail {
            screenTiming.begin(.ticketDetail)
            if self.detail == detail,selectedTask(id) != nil {screenTiming.cached(.ticketDetail,true)}
        }
        if case .project(let id) = detail {
            screenTiming.begin(.cleanup)
            if self.detail == detail,selectedOther?.id == id {screenTiming.cached(.cleanup,ticketCleanupReceipts.isCached(scope:cleanupReceiptScope(id)))}
        }
        
        if let prior = self.detail, prior != detail { detailBackStack.append(prior) }
        if self.detail == nil {
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.2)) { self.detail = detail }
        } else {
            replaceDetail(detail)
        }
    }
    func closeDetail() { screenTiming.cancel(.ticketDetail); screenTiming.cancel(.cleanup); withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.2)) { detail = nil; detailBackStack = [] } }
    func goBack() { if let prior = detailBackStack.popLast() { screenTiming.cancel(.ticketDetail);screenTiming.cancel(.cleanup);if case .task = prior {screenTiming.begin(.ticketDetail)};if case .project = prior {screenTiming.begin(.cleanup)};replaceDetail(prior) } else { closeDetail() } }
    private func replaceDetail(_ detail: Detail) {
        // The panel animates when presented or closed. Replacing its item commits
        // one native item tree before another may restore editor state.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { self.detail = detail }
    }
    func saveNote(_ id: String, text: String) {
        if (noteDrafts[id] ?? "").isEmpty && !text.isEmpty { noteDestinations[id] = (selectedTask(id) ?? task(id))?.string("active_attempt_id") ?? "" }
        if text.isEmpty { noteDestinations.removeValue(forKey: id) }
        noteDrafts[id] = text
        if noteScopes[id] == nil { noteScopes[id] = draftScope(project: (selectedTask(id) ?? task(id))?.string("project_id") ?? "", entity: id) }
        persistNote(id)
    }
    func refreshNoteDestination(_ id: String) {
        noteDestinations[id] = (selectedTask(id) ?? task(id))?.string("active_attempt_id") ?? ""
        noteScopes[id] = draftScope(project: (selectedTask(id) ?? task(id))?.string("project_id") ?? "", entity: id)
        persistNote(id)
    }
    func saveAnswer(_ id: String, draft: AnswerDraft, reconcile: Bool = false) {
        answerDrafts[id] = draft
        let requestID = String(id.split(separator: "#", maxSplits: 1).first ?? "")
        if reconcile || answerScopes[id] == nil { answerScopes[id] = draftScope(project: requests.first { $0.id == requestID }?.string("project_id") ?? "", entity: requestID) }
        persistDraft(StoredAnswerDraft(draft: draft, scope: answerScopes[id]!), kind: "answer", key: id)
    }

    var storeIncarnation: String { service.string("store_incarnation") }
    func draftScope(project: String, entity: String) -> DraftScope { DraftScope(storeIncarnation: storeIncarnation, projectID: project, entityID: entity) }
    func noteDraftNeedsReconciliation(_ id: String) -> Bool {
        guard !(noteDrafts[id] ?? "").isEmpty else { return false }
        return noteScopes[id]?.matches(store: storeIncarnation, project: (selectedTask(id) ?? task(id))?.string("project_id") ?? "", entity: id) != true
    }
    func answerDraftNeedsReconciliation(_ id: String, project: String) -> Bool {
        guard answerDrafts[id] != nil else { return false }
        return answerScopes[id]?.matches(store: storeIncarnation, project: project, entity: id) != true
    }
    func saveTaskEdit(_ id: String, draft: TaskEditDraft) { taskEditDrafts[id] = draft; persistDraft(draft, kind: "edit", key: id) }
    func saveCapture(_ draft: CaptureDraft) { captureDrafts[draft.projectID] = draft; persistDraft(draft, kind: "capture", key: draft.projectID) }
    /// Freeze the actual create intent in the durable draft before a service
    /// request exists. A restored sheet replays this UUID, never another create.
    func captureCreateParameters(projectID:String)throws->[String:Any] {
        guard var draft=captureDrafts[projectID],RecordIdentity(draft.projectID)==RecordIdentity(projectID),
              RecordIdentity(draft.storeIncarnation)==RecordIdentity(storeIncarnation),draft.createdTaskID == nil else {throw ChecklistError("CAPTURE_RECONCILIATION_REQUIRED","Inspect the preserved capture destination before creating a ticket.")}
        guard draft.createCommandID != nil || !draft.epicID.isEmpty else {throw ChecklistError("EPIC_REQUIRED","Choose a primary Epic for this ticket.")}
        if draft.createCommandID == nil {draft.createCommandID=UUID().uuidString}
        saveCapture(draft)
        guard draftSaveError("capture",projectID)==nil,let command=draft.createCommandID else {throw ChecklistError("CAPTURE_JOURNAL_REQUIRED","Save the original capture command before sending it.")}
        var params:[String:Any] = ["command_id":command,"project_id":projectID,"title":draft.title,"brief":draft.brief,"kind":draft.kind]
        if !draft.epicID.isEmpty {params["epic_id"]=draft.epicID}
        let starter=StarterFields.parameters(draft.starterFields ?? [:],kind:draft.kind)
        if !starter.isEmpty {params["starter_fields"]=starter}
        return params
    }
    @discardableResult func recordCapturedTask(_ response:[String:Any],projectID:String,commandID:String,store:String)->String? {
        let task=(response["task"] as? [String:Any]) ?? response
        guard RecordIdentity(storeIncarnation)==RecordIdentity(store),let id=task["id"] as? String,!id.isEmpty,
              let pid=task["project_id"] as? String,RecordIdentity(pid)==RecordIdentity(projectID),
              var draft=captureDrafts[projectID],draft.createCommandID.map(RecordIdentity.init)==RecordIdentity(commandID),
              RecordIdentity(draft.storeIncarnation)==RecordIdentity(store) else {return nil}
        draft.createdTaskID=id;saveCapture(draft)
        CaptureEpicDefaults.remember(draft.epicID,project:projectID,preferences:preferences)
        return draftSaveError("capture",projectID)==nil ? id : nil
    }
    /// A saved blank-project draft takes priority over ordinary capture defaults.
    var captureInitialProjectID: String {
        if let blank = captureDrafts[""], !blank.title.isEmpty || !blank.brief.isEmpty { return "" }
        return projectID ?? (activeProjects.count == 1 ? activeProjects.first?.id ?? "" : "")
    }
    func captureTerminationCheck() -> CaptureTerminationCheck {
        let drafts = captureDrafts, journal = draftJournal
        let failed = draftSaveFailures.keys.contains { $0.hasPrefix("capture:") }
        return CaptureTerminationCheck(verify: {
            guard !failed else { throw CocoaError(.fileWriteUnknown) }
            for (key, draft) in drafts { try journal.checkSaved(draft, kind: "capture", key: key) }
        }, isCurrent: { [weak self] in self?.captureDrafts == drafts })
    }

    func draftSaveError(_ kind: String, _ id: String) -> String? { draftSaveFailures[kind + ":" + id] }
    func retryDraftSave(_ kind: String, _ id: String) {
        switch kind {
        case "note": persistNote(id)
        case "answer": if let draft = answerDrafts[id] { saveAnswer(id, draft: draft) }
        case "edit": if let draft = taskEditDrafts[id] { saveTaskEdit(id, draft: draft) }
        case "capture": if let draft = captureDrafts[id] { saveCapture(draft) }
        default: break
        }
    }
    private func persistNote(_ id: String) {
        guard let scope = noteScopes[id] else { return }
        persistDraft(StoredNoteDraft(text: noteDrafts[id] ?? "", destination: noteDestinations[id] ?? "", scope: scope), kind: "note", key: id)
    }
    private func persistDraft<Value: Codable>(_ value: Value, kind: String, key: String) {
        do { try draftJournal.save(value, kind: kind, key: key); draftSaveFailures.removeValue(forKey: kind + ":" + key) }
        catch { draftSaveFailures[kind + ":" + key] = error.localizedDescription }
    }
    private func loadLocalDrafts() {
        do {
            let recoveredNotes = try draftJournal.recover(StoredNoteDraft.self, kind: "note")
            let notes = recoveredNotes.values
            for (id, value) in notes { noteDrafts[id] = value.text; noteDestinations[id] = value.destination; noteScopes[id] = value.scope }
            let recoveredAnswers = try draftJournal.recover(StoredAnswerDraft.self, kind: "answer")
            let answers = recoveredAnswers.values
            for (id, value) in answers { answerDrafts[id] = value.draft; answerScopes[id] = value.scope }
            let recoveredEdits = try draftJournal.recover(TaskEditDraft.self, kind: "edit")
            let recoveredCaptures = try draftJournal.recover(CaptureDraft.self, kind: "capture")
            taskEditDrafts = recoveredEdits.values
            captureDrafts = recoveredCaptures.values
            if !(recoveredNotes.errors + recoveredAnswers.errors + recoveredEdits.errors + recoveredCaptures.errors).isEmpty {
                draftRecoveryError = "Some local drafts could not be loaded. Readable drafts and original journal files were preserved for recovery."
            }
            // Migrate old preferences once, retaining their unknown origin for explicit reconciliation.
            for id in noteDrafts.keys where notes[id] == nil {
                if draftJournal.contains(kind: "note", key: id) { draftSaveFailures["note:" + id] = "The existing journal entry needs recovery; its original file was preserved."; continue }
                noteScopes[id] = DraftScope(storeIncarnation: "", projectID: "", entityID: id); persistNote(id)
            }
            for (id, draft) in answerDrafts where answers[id] == nil {
                if draftJournal.contains(kind: "answer", key: id) { draftSaveFailures["answer:" + id] = "The existing journal entry needs recovery; its original file was preserved."; continue }
                let requestID = String(id.split(separator: "#", maxSplits: 1).first ?? "")
                answerScopes[id] = DraftScope(storeIncarnation: "", projectID: "", entityID: requestID)
                persistDraft(StoredAnswerDraft(draft: draft, scope: answerScopes[id]!), kind: "answer", key: id)
            }
        } catch { draftRecoveryError = "Some local drafts could not be loaded. Their journal files were preserved: \(error.localizedDescription)" }
    }

    func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        try await request(method, params, ifCurrent: { true })
    }
    func request(_ method: String, _ params: [String: Any] = [:], ifCurrent: () -> Bool) async throws -> [String: Any] {
        guard connected || params["command_id"] == nil else { throw ChecklistError("SERVICE_UNAVAILABLE", "Reconnect and refresh before sending changes. Your local draft is preserved.") }
        try Task.checkCancellation()
        let family: NativeRenderMetrics.Family = method == "workspace_page" && params["surface"] as? String == "record" ? .selectedOther : .classify(method,detail:params["detail_level"] as? String)
        let metric=NativeRenderMetrics.startRequest(family)
        var succeeded=false
        defer {NativeRenderMetrics.finishRequest(metric,succeeded:succeeded)}
        let epoch = contentEpoch
        let reply: [String:Any]
        if let requestTransport {reply=try await requestTransport(method,params)}
        else {reply=try await NativeServiceTransport.call(method,params)}
        try Task.checkCancellation()
        guard ifCurrent() else { throw CancellationError() }
        if let failure = reply["error"] as? [String: Any] {
            throw ChecklistError(failure["code"] as? String ?? "SERVICE_ERROR", (failure["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "The Checklist service could not complete this request (\(failure["code"] as? String ?? "no error code")).")
        }
        // Do not compare randomized event cursor encodings as versions. The service's
        // read token is stable only for this exact caller/grant and database snapshot.
        let payload = reply["data"] as? [String:Any] ?? reply["result"] as? [String:Any] ?? reply
        let service = payload["service"] as? [String:Any] ?? (payload["tickets_page"] as? [String:Any])?["service"] as? [String:Any]
        // Only the projections that populate the window's content cache share
        // its epoch. Storage, restore previews and receipt reads own independent
        // lifetimes; navigating or refreshing a list must not cancel those reads.
        let contentRead = ["workspace_page", "task_list", "task_context", "snapshot", "service_info"].contains(method)
        if contentRead { guard epoch == contentEpoch else { throw CancellationError() } }
        let version = (method == "service_info" ? payload : service)?["read_version"] as? String
        if contentRead, let version {
            if let current = contentVersion, current != version {
                archivePreviewEpoch = UUID()
                invalidateContentCache()
                fullSelectedRecordID = nil; selectedRecordCollections = [:]
                invalidateSelectedEligibility()
                if method != "task_context" || params["detail_level"] as? String != "ui" {
                    // A newer list must not let cancellation promote an older selected
                    // display to current. Preserve a fresh UI read discovering its own version.
                    invalidateSelectedTicketFreshness()
                    scheduleSelectedTicket(for:detail)
                }
                let surface = params["surface"] as? String
                // The sequential fallback already owns every due Overview page.
                // Learning a commit from its first page must not enqueue another
                // loader that cancels this one and repeats the same surfaces.
                let pendingOverviewPage = surface.map { overviewPending[$0] != nil } ?? false
                let currentScreenRead = usesTicketPages ? method == "task_list" : method == "workspace_page" && (page == .overview ? surface == "overview" || pendingOverviewPage : surface == workspaceQuery.surface)
                if !currentScreenRead {
                    // A selected/partial read can learn a commit before live coverage.
                    // Rebase all visible pages as well as retiring off-screen caches.
                    Task { [weak self] in
                        guard let self else { return }
                        // List freshness must not cancel a selected-context recovery that
                        // discovered this generation, or replace its shared consumer read.
                        _ = await self.readLiveSurface()
                    }
                }
            }
            contentVersion = version
        } else if contentRead, contentVersion != nil {
            // Writer fallback and legacy/unqualified reads cannot authorize reusable pages.
            archivePreviewEpoch = UUID()
            invalidateContentCache(clearVisible:false); contentVersion = nil
        }
        succeeded=true
        if var result = reply["data"] as? [String: Any] {
            if let cursor = reply["event_cursor"] { result["event_cursor"] = cursor }
            return result
        }
        if let result = reply["result"] as? [String: Any] { return result }
        return reply
    }

    /// Cancellation is a caller/read lifecycle event, never service health evidence.
    private func isReadCancellation(_ error: Error) -> Bool {
        error is CancellationError || Task.isCancelled
    }
    private func acceptServiceRead() {
        connected = true; connectionAttempted = true; lastServiceFailure = nil
        reconcileRecoveredCommand()
    }
    private func recordServiceOutage(_ error: Error) {
        connected = false; connectionAttempted = true; lastServiceFailure = error.localizedDescription
    }

    func refresh(quiet: Bool = false) async {
        archivePreviewEpoch = UUID()
        // Selection is an independent visible surface, even when the list fails.
        if case .task = detail { scheduleSelectedTicket(for:detail,coalesce:true) }
        if usesTicketPages {
            ticketPageRead?.cancel()
            guard await readTicketPage(query:ticketPageQuery,cursor:nil) else { return }
        } else {
            if page == .overview { guard await readOverviewNeeds() else { return } }
            else { guard await readWorkspacePage(cursor:nil) else { return } }
        }
        if case .task = detail {} else if detail != nil { scheduleOtherDetail(for:detail) }
    }

    private func refreshFullSnapshot(quiet: Bool = false) async {
        // A waiter may observe a newer event while a snapshot is in flight.
        // Coalesce it into another fetch; only a successfully installed snapshot
        // advances the applied cursor.
        refreshRequested = true
        invalidateSelectedEligibility()
        guard !refreshing else { return }
        refreshing = true
        var canceledRead = false
        if !quiet { loading = true }
        defer {
            refreshing = false; loading = false
            if connected && !canceledRead && !Task.isCancelled { scheduleSelectedEligibility(for: detail) }
        }
        repeat {
            refreshRequested = false
            do {
                let observedGeneration = scopedReadGeneration
                let snapshot = try await request("snapshot")
                guard !Task.isCancelled else { return }
                // A newer accepted page/selected read can change incarnation while
                // this compatibility snapshot is in flight. Reuse the existing
                // coalescer for a fresh read; never install its old data/cursor.
                guard scopedReadGeneration == observedGeneration else {refreshRequested = true;continue}
                let installed = snapshot["data"] as? [String:Any] ?? snapshot
                let incoming = (installed["service"] as? [String:Any])?["store_incarnation"] as? String ?? ""
                if !storeIncarnation.isEmpty && !incoming.isEmpty && storeIncarnation != incoming {
                    ticketPageRead?.cancel();ticketPageReadID = UUID();ticketPages.invalidate();ticketCatalog.clear();pagedTicketWorkspace = nil
                    selectedTicketRead?.cancel();selectedTicketReadID = UUID();selectedRecordsReadID = UUID()
                    selectedTicketDisplay = nil;fullSelectedRecordID = nil;selectedRecordCollections = [:]
                }
                data = installed
                await desktopAlerts.observe(snapshot: data)
                loadTaskView()
                advanceEventCursor(snapshot["event_cursor"] as? String ?? snapshot["cursor"] as? String ?? (data["cursor"] as? String),source:"snapshot")
                if let projectID, !projects.contains(where: { $0.id == projectID }) { self.projectID = nil }
                acceptServiceRead()
            } catch {
                guard !isReadCancellation(error) else { canceledRead = true; return }
                recordServiceOutage(error)
                return
            }
        } while refreshRequested && !Task.isCancelled
    }

    func runTaskCommand(_ method: String, _ params: [String: Any], taskID: String, success: String? = nil, completion: (([String: Any]) -> Void)? = nil) {
        guard allowWrite() else { return }
        busy = true
        Task {
            do {
                let context = try await request("task_context", ["project_id": params["project_id"] ?? "", "task_id": taskID])
                guard let current = context["task"] as? [String: Any], let cursor = context["direction_cursor"] as? String else { throw NSError(domain: "Checklist", code: 1, userInfo: [NSLocalizedDescriptionKey: "Refresh this ticket's context before continuing. Your draft is preserved."]) }
                if ["work_claim", "task_complete", "work_recover"].contains(method), let expected = params["expected_revision"] as? Int, expected != (current["revision"] as? Int) { throw NSError(domain: "Checklist", code: 1, userInfo: [NSLocalizedDescriptionKey: "This ticket changed. Review its current state before continuing. Your draft is preserved."]) }
                for key in ["target_manifest_id", "current_manifest_id"] {
                    if let expected = params[key] as? String, expected != current["current_manifest_id"] as? String { throw NSError(domain: "Checklist", code: 1, userInfo: [NSLocalizedDescriptionKey: "The review target changed. Your previous draft is preserved."]) }
                }
                var command = params
                if method == "human_request_answer" {
                    if let displayed = params["expected_task_revision"] as? Int, displayed != current["revision"] as? Int {
                        throw NSError(domain: "Checklist", code: 1, userInfo: [NSLocalizedDescriptionKey: "This ticket changed while the answer was being prepared. Review its current target before sending. Your answer draft is preserved."])
                    }
                    command["expected_task_revision"] = current["revision"]
                }
                command["direction_cursor"] = cursor
                busy = false
                run(method, command, success: success, completion: completion)
            } catch { busy = false; self.error = PlainError.text(error) }
        }
    }

    private static let foreignRecoveryNotice = "Checklist ignored a saved change from a different store or installation. It will not be sent to this store."
    private static let unreadableRecoveryNotice = "Checklist ignored a saved change it could not read safely. It will not be sent."

    private func restoreSavedCommand() {
        do {
            guard let saved = try pendingCommandPersistence.read(pendingCommandKey) else {
                preferences.removeObject(forKey: ignoredRecoveryPreferenceKey)
                return
            }
            if preferences.string(forKey: ignoredRecoveryPreferenceKey) == "unreadable" {
                preferences.removeObject(forKey: ignoredRecoveryPreferenceKey)
            }
            let marker = PendingCommandRecovery.marker(saved)
            guard let command = PendingCommandRecovery(saved: saved) else {
                ignoreSavedCommand(marker: marker, message: Self.unreadableRecoveryNotice)
                return
            }
            recoveredCommand = (command, marker)
        } catch {
            // The bytes are inaccessible, so remember this unreadable interval
            // until an absent/readable item or a new saved command is observed.
            ignoreSavedCommand(marker: "unreadable", message: Self.unreadableRecoveryNotice)
        }
    }

    private func reconcileRecoveredCommand() {
        guard !storeIncarnation.isEmpty else { return }
        if let recovered = recoveredCommand {
            recoveredCommand = nil
            guard recovered.command.matches(storeIncarnation: storeIncarnation, serviceIdentity: pendingCommandServiceIdentity) else {
                ignoreSavedCommand(marker: recovered.marker, message: Self.foreignRecoveryNotice)
                return
            }
            pendingMutation = (recovered.command, "Last change checked", nil, nil)
            hasPendingMutation = true
        } else if let pending = pendingMutation,
                  !pending.command.matches(storeIncarnation: storeIncarnation, serviceIdentity: pendingCommandServiceIdentity) {
            ignoreSavedCommand(marker: pending.command.marker, message: Self.foreignRecoveryNotice)
        }
    }

    private func ignoreSavedCommand(marker: String, message: String) {
        recoveredCommand = nil; pendingMutation = nil; hasPendingMutation = false
        guard preferences.string(forKey: ignoredRecoveryPreferenceKey) != marker else { return }
        preferences.set(marker, forKey: ignoredRecoveryPreferenceKey)
        inform(message)
    }

    func run(_ method: String, _ params: [String: Any] = [:], success: String? = nil, failure: ((Error) -> Void)? = nil, completion: (([String: Any]) -> Void)? = nil) {
        guard allowWrite() else { return }
        guard !storeIncarnation.isEmpty else { inform("Refresh Checklist before making a change so it can be recovered safely."); return }
        var command = params
        if command["command_id"] == nil { command["command_id"] = UUID().uuidString }
        let recovery = PendingCommandRecovery(method: method, params: command, storeIncarnation: storeIncarnation, serviceIdentity: pendingCommandServiceIdentity)
        pendingMutation = (recovery, success, completion, failure)
        do {
            try pendingCommandPersistence.save(recovery.encoded(),pendingCommandKey)
            preferences.removeObject(forKey: ignoredRecoveryPreferenceKey)
        } catch { pendingMutation = nil; self.error = "Cannot preserve the command for safe recovery: \(error.localizedDescription)"; return }
        performPendingMutation()
    }

    func retryPendingMutation() {
        guard pendingMutation != nil else { return }
        guard connected, !busy else { inform(connected ? DisabledReasons.saving : DisabledReasons.offline); return }
        error = nil; performPendingMutation(checkIdentity: true)
    }
    /// Apply the committed answer before any refresh can wait or fail. Counts come
    /// from the same transaction as the answer, including any human-gate task change.
    private func applyHumanAnswerReceipt(_ reply: [String:Any], params: [String:Any]) {
        let record = Record(values:reply)
        guard record.id == params["request_id"] as? String,
              record.string("project_id") == params["project_id"] as? String,
              record.string("state") == "answered",
              let response = record.records("responses").last, response.bool("complete"),
              response.string("origin") == "human_ui" else { return }
        if let current = requests.first(where: { RecordIdentity($0.id) == RecordIdentity(record.id) }),
           current.integer("revision") > record.integer("revision") { return }
        // Every workspace page now carries the global count; fence any older reply.
        workspaceRead?.cancel(); workspaceObservation.cancel()
        if page == .overview {
            retireOverviewRead(); for observation in overviewObservations.values { observation.cancel() }
        }
        if detail == .request(record.id) { otherDetailRead?.cancel(); otherDetailObservation.cancel() }
        ticketPageRead?.cancel(); ticketPageReadID = UUID()
        workspaceObservation.applyAnsweredRequest(record)
        overviewObservations["requests"]?.applyAnsweredRequest(record)
        otherDetailObservation.applyAnsweredRequest(record)
        if let count = reply["needs_you_count"] as? Int, count >= 0 { ticketCatalog.needsCount = count }
    }
    private func performPendingMutation(checkIdentity: Bool = false) {
        guard let pending = pendingMutation else { return }
        busy = true
        Task {
            defer { busy = false }
            // A retry checks the actual endpoint again: its store may have been
            // replaced since the page that offered this command was accepted.
            if checkIdentity {
                do {
                    let service = try await request("service_info")
                    guard let incarnation = service["store_incarnation"] as? String, !incarnation.isEmpty else {
                        throw ChecklistError("INVALID_RESPONSE", "Checklist could not identify the store. Reconnect before checking the last change.")
                    }
                    guard pending.command.matches(storeIncarnation: incarnation, serviceIdentity: pendingCommandServiceIdentity) else {
                        ignoreSavedCommand(marker: pending.command.marker, message: Self.foreignRecoveryNotice)
                        return
                    }
                } catch {
                    guard pendingMutation != nil else { return }
                    // A failed identity read says nothing about the original write.
                    hasPendingMutation = true
                    self.error = "Checklist could not check the saved change's store. Reconnect and try Check the last change again."
                    return
                }
            }
            // A concurrent accepted read can fence this command while its
            // identity check is suspended. Never revive or send that old item.
            guard pendingMutation != nil else { return }
            do {
                let reply = try await request(pending.command.method, pending.command.params)
                guard pendingMutation != nil else { return }
                pendingMutation = nil; hasPendingMutation = false; pendingCommandPersistence.remove(pendingCommandKey)
                let answered = pending.command.method == "human_request_answer"
                if answered {
                    applyHumanAnswerReceipt(reply,params:pending.command.params)
                    pending.completion?(reply)
                }
                invalidateContentCache(clearVisible: !answered)
                if !pending.command.method.hasPrefix("media_") {await refresh(quiet: true)}
                if pending.command.method == "message_mentions_prepare" {
                    // Preparation's caller must inspect the refreshed selected
                    // context, rather than mistake a scheduled read for readiness.
                    // Capture this read only: a later selection/invalidating read
                    // still fails the caller's exact destination/context guards.
                    let preparedContextRead = selectedTicketRead
                    await preparedContextRead?.value
                }
                noticeIsWarning = false; notice = pending.success
                busy = false
                if !answered { pending.completion?(reply) }
            } catch {
                guard pendingMutation != nil else { return }
                pending.failure?(error)
                if CommandReply.shouldRetainPending(after: error) {
                    hasPendingMutation = true
                    self.error = "The service may already have saved this change. Use Check the last change before you make another change."
                } else {
                    pendingMutation = nil; hasPendingMutation = false; pendingCommandPersistence.remove(pendingCommandKey)
                    self.error = PlainError.text(error)
                }
            }
        }
    }

    /// Called by the authenticated event subscription. Cursor advancement belongs
    /// to this coverage interval, never an incidental newer list/read response.
    @discardableResult func applyChangeCoverage(_ changes:[String:Any]) async -> Bool {
        if page == .overview { prepareOverviewVisit() }
        let scope = liveScope
        let cursor = changes["event_cursor"] as? String
        let newInterval = pendingCoverageCursor == nil || pendingCoverageCursor != cursor || pendingCoverageScope != scope
        archivePreviewEpoch = UUID()
        fullSnapshotDirty=true
        let coverage=changes["coverage"] as? [String:Any]
        let reset=coverage?["schema_version"] as? Int != 2 || coverage?["complete"] as? Bool != true || coverage?["reset"] as? Bool != false
        let rows=coverage?["changes"] as? [[String:Any]] ?? []
        func inProject(_ row:[String:Any],_ project:String?)->Bool {project.map {RecordIdentity($0)==RecordIdentity(row["project_id"] as? String ?? "")} ?? true}
        func families(_ row:[String:Any])->Set<String> {Set(row["families"] as? [String] ?? ["all"])}
        func touches(_ row:[String:Any],task:String?)->Bool {
            row["all_tasks"] as? Bool != false || task == nil || (row["task_ids"] as? [String] ?? []).contains {RecordIdentity($0)==RecordIdentity(task!)}
        }
        // Catalog metadata is visible in the Sidebar across all owned projects.
        // The owner count also spans all projects: request/task changes can alter
        // the badge even when the selected project's rows are unchanged.
        let catalogAffected=reset || rows.contains {families($0).contains("all")}
        let needsAffected=reset || rows.contains {!families($0).isDisjoint(with:["all","requests","tasks"])}
        let visible=rows.filter {inProject($0,projectID)}
        let ticketAffected=catalogAffected || needsAffected || visible.contains {row in let f=families(row);return !f.isDisjoint(with:["all","tasks","groups"]) || !search.isEmpty && f.contains("messages")}
        let workspaceAffected=catalogAffected || needsAffected || visible.contains {row in
            let f=families(row)
            if page == .activity || page == .overview {return true}
            if page == .epics {return !f.isDisjoint(with:["all","tasks","groups"])}
            return !f.isDisjoint(with:needsSurface == "requests" ? ["all","requests","tasks"] : ["all","tasks"])
        }
        let selectedID: String? = {if case .task(let id)=detail{return id};return nil}()
        let selectedProject=selectedTicketDisplay?.task.string("project_id")
        let selectedAffected=selectedID != nil && (reset || rows.contains {inProject($0,selectedProject) && touches($0,task:selectedID)})
        let otherTask=selectedOther?.object("selected_task")["id"] as? String
        let otherAffected=selectedOther != nil && (reset || rows.contains {inProject($0,selectedOther?.string("project_id")) && (selectedOther?.string("record_type")=="group" ? !families($0).isDisjoint(with:["all","groups","tasks"]) : touches($0,task:otherTask))})
        let affected = usesTicketPages ? ticketAffected : workspaceAffected
        if newInterval {
            pendingCoverageCursor = cursor; pendingCoverageScope = scope
            invalidateContentCache(clearVisible:false,retireReads:affected || selectedAffected)
            // The interval already retired old replies. Its parallel readers may
            // discover the same new version without canceling one another.
            if affected || selectedAffected { contentVersion = nil }
            if affected {
                markVisibleStale()
                if usesTicketPages { ticketPages.discardContent(); pagedTicketWorkspace = nil }
                else if page == .overview { for observation in overviewObservations.values { if reset {observation.discardContent()} else {observation.markNeedsRefresh()} } }
                else { workspaceObservation.discardContent() }
            }
            if selectedAffected { selectedTicketDisplay = nil; invalidateSelectedTicketFreshness(); invalidateSelectedEligibility() }
        }
        let familyNames = Set(rows.flatMap { $0["families"] as? [String] ?? ["all"] }).sorted().joined(separator:",")
        let taskCount = Set(rows.flatMap { $0["task_ids"] as? [String] ?? [] }).count
        if newInterval { Self.liveLogger.notice("changed families=\(familyNames, privacy:.public) task_count=\(taskCount) visible_affected=\(affected)") }
        let refreshSelected = selectedAffected && selectedInstalledChange != selectedChange
        let refreshVisible = affected && visibleInstalledChange != visibleChange
        async let selectedOK = refreshSelected ? readLiveSelected() : true
        async let visibleOK = refreshVisible ? readLiveSurface() : true
        let installed = await (visibleOK,selectedOK)
        guard installed.0, installed.1, !Task.isCancelled, liveScope == scope,
              !affected || visibleInstalledChange == visibleChange,
              !selectedAffected || selectedInstalledChange == selectedChange else {
            // A manual refresh may have superseded this reader and installed a
            // fresh baseline. Do not let the abandoned interval block bootstrap.
            if !installed.0, visibleInstalledChange == visibleChange {
                pendingCoverageCursor = nil; pendingCoverageScope = nil
            }
            return false
        }
        if otherAffected { scheduleOtherDetail(for:detail) }
        advanceEventCursor(cursor,source:"coverage")
        pendingCoverageCursor = nil; pendingCoverageScope = nil
        return true
    }

    func stopWindowReads() {
        for surface in ScreenTiming.Surface.allCases {screenTiming.cancel(surface)}
        nextDigestRead?.cancel();nextDigestRead = nil
        freshnessWatchdog?.cancel(); freshnessWatchdog = nil
        liveSurfaceRead?.cancel(); liveSurfaceRead = nil; liveSurfaceScope = nil
        visibleStaleSince = nil; selectedStaleSince = nil; pendingCoverageCursor = nil; pendingCoverageScope = nil
        invalidateContentCache(clearVisible: false); contentVersion = nil
        cancelSelectedRecordRecovery()
        ticketPageRead?.cancel();ticketPageReadID=UUID();ticketPages.invalidate()
        workspaceRead?.cancel();workspaceObservation.cancel()
        otherDetailRead?.cancel();otherDetailObservation.cancel()
        groupTasksRead?.cancel();groupTasksObservation.cancel()
        groupCandidatesRead?.cancel();groupCandidatesObservation.cancel()
        retireOverviewRead(); for observation in overviewObservations.values { observation.cancel() }
        selectedTicketRead?.cancel();selectedTicketReadID=UUID();selectedRecordsReadID=UUID();selectedWorkRead?.cancel()
        recordHistoryRead?.cancel();recordHistoryObservation.cancel();invalidateSelectedEligibility()
        selectedTicketLoading=false;selectedRecordsLoading=false
        scopedReadGeneration=UUID()
    }

    /// Pauses of the live loop: after each wait, and before a retry after a failure. Tests shorten them.
    var liveWaitPause: UInt64 = 500_000_000
    var liveRetryPause: UInt64 = 3_000_000_000

    /// A replaced store can leave a persisted project ID that no longer exists.
    /// Prove absence with the global catalog; a failed scoped read alone is not enough.
    private func recoverMissingRestoredProject() async -> Bool {
        guard !connected, let selected = projectID else { return false }
        let restoredPage = page, observedGeneration = scopedReadGeneration
        func isCurrent() -> Bool {
            !connected && page == restoredPage && scopedReadGeneration == observedGeneration &&
                projectID.map(RecordIdentity.init) == RecordIdentity(selected)
        }
        do {
            let catalog = try await request("project_list", ["include_archived": true])
            guard !Task.isCancelled, isCurrent(),
                  let projects = catalog["projects"] as? [[String: Any]] else { return false }
            let ids = projects.compactMap { $0["id"] as? String }
            guard ids.count == projects.count, ids.allSatisfy({ !$0.isEmpty }),
                  !ids.contains(where: { RecordIdentity($0) == RecordIdentity(selected) }) else { return false }
            // Media review requires a project. Keep drafts, but reopen the ordinary worklist.
            select(page == .media ? .tasks : page, project: nil)
            return true
        } catch {
            guard !isReadCancellation(error), isCurrent() else { return false }
            recordServiceOutage(error)
            return false // No catalog authority: preserve the saved scope for recovery.
        }
    }

    func startLiveUpdates() async {
        startedLiveUpdates = true
        freshnessWatchdog?.cancel()
        let watchdog = Task { [weak self] in
            guard let self else { return }; await self.runFreshnessWatchdog()
        }
        freshnessWatchdog = watchdog
        defer { watchdog.cancel() }
        await refresh()
        if await recoverMissingRestoredProject() { await refresh() }
        // Event invalidation only: this never polls or launches an agent/model.
        while !Task.isCancelled {
            do {
                var params: [String: Any] = ["timeout_ms": 8000, "include_coverage": true]
                if let eventCursor { params["cursor"] = eventCursor }
                let changes = try await request("changes_wait", params)
                // The service answers again after an outage. Reload the visible data first: a read that
                // installs sets connected, which removes the offline banner and allows writes again,
                // even when no event changed (CL-60).
                if !connected { await refresh(quiet: true) }
                try Task.checkCancellation()
                if changes["changed"] as? Bool == true {
                    NativeRenderMetrics.changeObserved()
                    if !(await applyChangeCoverage(changes)) {
                        try await Task.sleep(nanoseconds:liveRetryPause)
                        // Ask again from the last applied cursor. Newer changes
                        // must still reach the list while a detail keeps failing.
                        continue
                    }
                }
                try await Task.sleep(nanoseconds: liveWaitPause)
            } catch {
                if isReadCancellation(error) {
                    guard !Task.isCancelled else { return }
                    do { try await Task.sleep(nanoseconds: liveWaitPause) } catch { return }
                    continue
                }
                recordServiceOutage(error)
                let failure = error as? ChecklistError
                let reset = failure?.code == "CURSOR_RESET"
                // An interrupted read is not a data change. Keep the owned Overview
                // loader and its accepted pages; its next version still fences a real commit.
                // Definite scope/coverage errors retain the ordinary invalidation path.
                let interruptedRead = failure?.code == "OUTCOME_UNKNOWN" && failure?.details["command_id"] == nil
                let overviewRecovery = page == .overview && interruptedRead ? overviewRead : nil
                let overviewRecoveryID = overviewReadID
                invalidateContentCache(clearVisible: overviewRecovery == nil, retireReads: overviewRecovery == nil)
                if overviewRecovery == nil { contentVersion = nil }
                fullSnapshotDirty = true
                if reset {
                    // The old coverage interval no longer exists. Only this
                    // explicit reset allows the successful reload to establish a
                    // new interval; ordinary reads never skip unseen events.
                    eventCursor=nil
                    invalidateSelectedTicketFreshness()
                    workspaceRead?.cancel();workspaceObservation.cancel()
                    otherDetailRead?.cancel();otherDetailObservation.cancel()
                    groupTasksRead?.cancel();groupTasksObservation.cancel(clear:true)
                    groupCandidatesRead?.cancel();groupCandidatesObservation.cancel(clear:true)
                    recordHistoryRead?.cancel();recordHistoryObservation.cancel(clear:true)
                }
                ticketPages.invalidate();ticketCatalog.clear(); pagedTicketWorkspace = nil
                ticketPageReadID = UUID(); ticketPageRead?.cancel()
                invalidateSelectedEligibility()
                // Service reconnect is a local UI data subscription, never model pickup.
                try? await Task.sleep(nanoseconds: liveRetryPause)
                guard !Task.isCancelled else { return }
                if let overviewRecovery, overviewReadID == overviewRecoveryID {
                    // Also join a loader that finished during the retry pause. Starting
                    // a forced refresh here would repeat its already completed surfaces.
                    _ = await awaitOverviewRead(overviewRecovery, id: overviewRecoveryID)
                } else if reset {
                    // The watchdog may already have installed the reset head during
                    // the retry pause. Join its reads instead of loading twice.
                    let selectedDue = selectedStaleSince != nil
                    async let selected = selectedDue ? readLiveSelected() : true
                    if visibleInstalledChange != visibleChange { _ = await readLiveSurface() }
                    _ = await selected
                    if case .task = detail {} else if detail != nil { scheduleOtherDetail(for:detail) }
                } else {
                    await refresh(quiet:true)
                }
            }
        }
    }
}


extension ChecklistStore {
    private var personalViewStorage: PersonalTicketViews { PersonalTicketViews(preferences: preferences, projectID: projectID ?? "overview") }
    func resetTicketFilters() { withTicketViewUpdate { statusFilter = "all"; tagFilter = "all"; search = ""; listFilters = TicketListFilters() } }
    func savePersonalTicketView(name: String, updating: String? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { inform("Give the view a name of at most 80 characters."); return }
        var view = PersonalTicketView(name:name, search:search, status:statusFilter, legacyTag:tagFilter, filters:listFilters, groupBy:viewGroupBy, orderBy:viewOrderBy, surface:page.rawValue)
        if let updating { view.id = updating }
        guard personalViewStorage.save(view) else { inform("Keep at most 10 saved views for this project. Remove a view first."); return }
        ticketObservation.personalViews = personalViewStorage.load()
        ticketObservation.selectedPersonalViewID = view.id
        preferences.set(view.id, forKey:"activePersonalView:" + (projectID ?? "overview"))
    }
    func applyPersonalTicketView(_ view: PersonalTicketView) {
        withTicketViewUpdate {
            if let surface = view.surface, let savedPage = Page(rawValue:surface), [.tasks, .archived, .overview].contains(savedPage) { page = savedPage }
            search = view.search; statusFilter = view.status; tagFilter = view.legacyTag; listFilters = view.filters; viewGroupBy = view.groupBy; viewOrderBy = view.orderBy
        }
        saveTaskView(); ticketObservation.selectedPersonalViewID = view.id
        preferences.set(view.id, forKey:"activePersonalView:" + (projectID ?? "overview"))
    }
    func removePersonalTicketView(_ id: String) {
        personalViewStorage.remove(id); ticketObservation.personalViews = personalViewStorage.load()
        if selectedPersonalViewID == id { ticketObservation.selectedPersonalViewID = nil; preferences.removeObject(forKey:"activePersonalView:" + (projectID ?? "overview")) }
    }
    var ticketFilterEpics: [Record] { ticketPages.page?.epics ?? [] }
    var ticketFilterTriages: [Record] { ticketPages.page?.filterTriages ?? [] }
}

extension ChecklistStore: CaptureTerminationParticipant {}
