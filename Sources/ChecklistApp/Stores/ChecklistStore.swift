import Foundation
import SwiftUI
import Combine
import ChecklistIPC

struct PendingCommandPersistence {
    let read: (String)->String?
    let save: (String,String)throws->Void
    let remove: (String)->Void
    static var keychain: Self {Self(read:HumanClaims.read,save:{try HumanClaims.save($0,attempt:$1)},remove:HumanClaims.remove)}
}

@MainActor
final class ChecklistStore: ObservableObject {
    @Published var data: [String: Any] = [:] {
        didSet {
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
    private var selectedTicketDisplay: SelectedTicketDisplay? { get {selectedObservation.display} set {selectedObservation.display = newValue} }
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
    @Published var error: String? { didSet { DiagnosticsRecorder.shared.record(error) } }
    @Published var busy = false
    @Published var hasPendingMutation = false
    var pendingCommandID: String? { pendingMutation?.params["command_id"] as? String }
    private var pendingMutation: (method: String, params: [String: Any], success: String?, completion: (([String: Any]) -> Void)?, failure: ((Error) -> Void)?)?
    @Published var notice: String? { didSet { if !informing { noticeIsWarning = false } } }
    private var informing = false
    /// True when the current notice reports an ignored action rather than a success.
    @Published private(set) var noticeIsWarning = false
    /// CL-58: why a write cannot run now, in plain words; nil when it can.
    var writeBlockReason: String? {
        if !connected { return DisabledReasons.offline }
        if hasPendingMutation { return DisabledReasons.uncheckedChange }
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
    @Published var page: Page = .overview { didSet { prepareTicketWorkspace() } }
    @Published var projectID: String? = nil { didSet { prepareTicketWorkspace() } }
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
    private var restoringPreferences = true
    private var refreshing = false
    private var eventCursor: String?
    private let desktopAlerts: DesktopAlertCoordinator
    let navigationMemory: DetailItemNavigationMemory
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
    var workspaceRows: [Record] {workspaceObservation.page?.rows ?? []}
    var workspaceTotal: Int {workspaceObservation.page?.total ?? 0}
    var workspaceLoading: Bool {workspaceObservation.loading}
    /// A page for the current workspace query has arrived; before that an empty list is not yet known to be empty.
    var workspacePageLoaded: Bool {workspaceObservation.page != nil}
    var workspaceError: String? {workspaceObservation.error}
    var workspaceNext: String? {workspaceObservation.page?.next}
    var workspacePrevious: String? {workspaceObservation.page?.previous}
    var otherDetailLoading: Bool {otherDetailObservation.loading}
    var otherDetailError: String? {otherDetailObservation.error}
    var selectedOther: Record? {otherDetailObservation.page?.rows.first}
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

    init(draftJournal: LocalDraftJournal = LocalDraftJournal(), preferences: UserDefaults = .standard, restorePendingCommand: Bool = true, desktopAlerts: DesktopAlertCoordinator = .shared, requestTransport: ((String,[String:Any]) async throws -> [String:Any])? = nil, navigationMemory: DetailItemNavigationMemory = .shared, pendingCommandKey:String = "pending-command", pendingCommandPersistence:PendingCommandPersistence = .keychain) {
        self.draftJournal = draftJournal; self.preferences = preferences; self.desktopAlerts = desktopAlerts;self.requestTransport = requestTransport;self.navigationMemory = navigationMemory;self.pendingCommandKey=pendingCommandKey;self.pendingCommandPersistence=pendingCommandPersistence
        if restorePendingCommand, let saved = pendingCommandPersistence.read(pendingCommandKey), let bytes = saved.data(using: .utf8), let record = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any], let method = record["method"] as? String, let params = record["params"] as? [String: Any] { pendingMutation = (method, params, "Last change checked", nil, nil); hasPendingMutation = true }
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
    var requests: [Record] { if startedLiveUpdates {return (selectedOther.map { $0.string("record_type")=="request" ? [$0] : [] } ?? []) + workspaceRows.filter {$0.string("record_type")=="request" && RecordIdentity($0.id) != selectedOther.map {RecordIdentity($0.id)}}};return records("requests") }
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
    func loadFullSelectedRecord(_ id: String) {
        selectedRecordsError = nil;selectedRecordsLoading = true
        let readID = UUID();selectedRecordsReadID = readID
        let contextID = selectedTicketReadID
        guard let displayed = selectedTicketDisplay,RecordIdentity(displayed.task.id) == RecordIdentity(id) else {selectedRecordsLoading = false;return}
        selectedWorkRead?.cancel()
        selectedWorkRead=Task {
            do {
                let response = try await request("task_context",["task_id":id,"detail_level":"ui_records","selected_context_cursor":displayed.contextCursor])
                guard !Task.isCancelled,selectedRecordsReadID == readID,selectedTicketReadID == contextID,isSelectedTicket(id),let current = selectedTicketDisplay,
                      RecordIdentity(current.task.id)==RecordIdentity(id),
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
                scheduleSelectedEligibility(for:detail)
            } catch {
                guard selectedRecordsReadID == readID,selectedTicketReadID == contextID,isSelectedTicket(id) else {return}
                selectedRecordsLoading = false;selectedRecordsError = "Could not load work/review records for this observed ticket context. Refresh the selected ticket before retrying; your draft is preserved."
            }
        }
    }
    private func scheduleSelectedTicket(for selection: Detail?, cursor: String? = nil) {
        selectedTicketRead?.cancel(); selectedTicketReadID = UUID();selectedRecordsReadID = UUID()
        recordHistoryRead?.cancel();recordHistoryObservation.cancel(clear:true)
        selectedWorkRead?.cancel()
        if fullSelectedRecordID != nil {selectedRecordsLoading = true}
        guard case .task(let id) = selection else {selectedTicketDisplay = nil;fullSelectedRecordID = nil;selectedRecordCollections = [:];selectedRecordsLoading = false;selectedRecordsError = nil;selectedTicketLoading = false;return}
        if selectedTicketDisplay.map({RecordIdentity($0.task.id) != RecordIdentity(id)}) ?? true {selectedTicketDisplay = nil;fullSelectedRecordID = nil;selectedRecordCollections = [:];selectedRecordsLoading = false;selectedRecordsError = nil}
        guard startedLiveUpdates else {return}
        let readID = selectedTicketReadID
        selectedTicketLoading = true;selectedTicketError = nil;selectedTicketMissing = false
        selectedTicketRead = Task { [weak self] in
            guard let self else {return}
            do {
                var p: [String:Any] = ["task_id":id,"detail_level":"ui"]
                if let cursor {p["history_cursor"] = cursor}
                let response: [String:Any]
                do {response = try await self.request("task_context",p)}
                catch let error as ChecklistError where cursor != nil && error.code == "CURSOR_RESET" {
                    guard !Task.isCancelled,self.selectedTicketReadID == readID,self.isSelectedTicket(id) else {return}
                    // One fresh-head read after the conversation changed. This
                    // never retries a mutation or revives an obsolete selection.
                    response = try await self.request("task_context",["task_id":id,"detail_level":"ui"])
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
                self.selectedTicketDisplay = value;self.selectedTicketLoading = false;self.connected = true
                if changedStore {self.scheduleTicketPage(force:true)}
                if self.fullSelectedRecordLoaded(id) {self.loadFullSelectedRecord(id)}
                self.scheduleSelectedEligibility(for:self.detail)
            } catch {
                guard !Task.isCancelled,self.selectedTicketReadID == readID else {return}
                self.selectedTicketLoading = false;self.selectedTicketError = "Could not load the selected ticket. Your draft is preserved."
                // A removed ticket (for example from an old desktop alert) shows the unavailable state (CL-59).
                self.selectedTicketMissing = (error as? ChecklistError)?.code == "NOT_FOUND"
            }
        }
    }

    private func invalidateSelectedTicketFreshness() {
        guard case .task = detail else {return}
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
        guard force || ticketPages.query != query || (ticketPages.page == nil && !ticketPages.loading) else { return }
        ticketPageRead?.cancel()
        ticketPageRead = Task { [weak self] in await self?.readTicketPage(query: query, cursor: cursor) }
    }
    private func readTicketPage(query: TicketPageQuery, cursor: String?) async {
        let observed = ticketPages.begin(query: query, cursor: cursor)
        let readID = UUID(); ticketPageReadID = readID
        pagedTicketWorkspace = ticketPages.prepared(expansion: ticketExpansion)
        do {
            let result = try await request("task_list", query.parameters(cursor: cursor))
            guard !Task.isCancelled, ticketPageReadID == readID, usesTicketPages, ticketPageQuery == query else { return }
            let page = try TicketPage(response: result)
            let oldIncarnation = storeIncarnation
            let changedStore = !oldIncarnation.isEmpty && oldIncarnation != page.service.string("store_incarnation")
            if changedStore {
                fullSnapshotAvailable = false;fullSnapshotDirty = true
                invalidateSelectedTicketFreshness()
                invalidateSelectedEligibility()
            }
            guard ticketPages.receive(page, for: observed) else { return }
            ticketCatalog.install(page)
            scopedReadGeneration = UUID()
            pagedTicketWorkspace = ticketPages.prepared(expansion: ticketExpansion)
            if !connected {connected = true}
            if eventCursor == nil {eventCursor = result["event_cursor"] as? String ?? page.contentCursor}
            if changedStore {scheduleSelectedTicket(for:detail)}
        } catch {
            guard !Task.isCancelled, ticketPageReadID == readID else { return }
            ticketPages.fail(observed)
        }
    }
    func readRecordHistory(_ task:Record,family:String,cursor:String? = nil) {
        guard let display=selectedTicketDisplay,RecordIdentity(display.task.id)==RecordIdentity(task.id),selectedTicketCurrent(task.id) else{return}
        recordHistoryRead?.cancel()
        let query=WorkspacePageQuery(surface:"record_history",project:task.string("project_id"),record:task.id)
        let generation=recordHistoryObservation.begin(query),contextID=selectedTicketReadID
        recordHistoryRead=Task {[weak self] in
            guard let self else{return}
            do {
                var p:[String:Any] = ["task_id":task.id,"detail_level":"ui_history","selected_context_cursor":display.contextCursor,"records_family":family]
                p["cursor"]=cursor
                let response=try await self.request("task_context",p)
                guard !Task.isCancelled,self.selectedTicketReadID==contextID,self.isSelectedTicket(task.id) else{return}
                _=try self.recordHistoryObservation.receive(response,query:query,generation:generation)
            } catch {if !Task.isCancelled {self.recordHistoryObservation.fail(generation)}}
        }
    }
    private var workspaceQuery: WorkspacePageQuery {
        WorkspacePageQuery(surface:page == .needsYou ? needsSurface : page == .epics ? "epics" : "activity",project:projectID,text:search,archived:workspaceArchived)
    }
    func configureWorkspace(surface:String? = nil,archived:Bool? = nil) {
        if let surface {needsSurface=surface};if let archived {workspaceArchived=archived}
        scheduleWorkspacePage(force:true)
    }
    func moveWorkspacePage(_ cursor:String) {scheduleWorkspacePage(cursor:cursor,force:true)}

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
    func beginOverviewVisit() {
        guard !overviewVisitActive else { return }
        overviewVisitActive = true
        overviewDigestSince = preferences.object(forKey: "overviewLastVisit") as? Date ?? Date().addingTimeInterval(-86400)
        preferences.set(Date(), forKey: "overviewLastVisit")
        scheduleOverviewNeeds(only: "completed_since", force: true)
    }
    func endOverviewVisit() { overviewVisitActive = false }
    static func overviewTitle(_ surface: String) -> String {
        surface == "completed_since" ? "Completed since your last visit" : surface == "recent_reviews" ? "Latest review results" : overviewGroups.first { $0.surface == surface }?.title ?? "Overview"
    }
    func clearOverviewDigest() {
        overviewDigestSince = Date(); preferences.set(Date(), forKey: "overviewLastVisit")
        scheduleOverviewNeeds(only: "completed_since", force: true)
    }
    private static let digestFormatter = ISO8601DateFormatter()
    /// One loader reads the groups in turn. Each read blocks a transport thread until the service answers, so
    /// ten parallel reads per window could starve the shared threads that the live updates also use.
    private var overviewRead: Task<Void,Never>?
    /// The one group shown in full with paging; nil shows every group's first rows.
    @Published var overviewFocus: String? { didSet { if overviewFocus != oldValue { scheduleOverviewNeeds(force: true) } } }
    func overviewQuery(_ surface: String) -> WorkspacePageQuery {
        var query = WorkspacePageQuery(surface: surface, project: projectID)
        query.limit = surface == "human_tasks" ? 1 : overviewFocus == surface ? 50 : surface == "recent_reviews" ? 60 : surface == "completed_since" ? 20 : 5
        if surface == "completed_since" { query.since = Self.digestFormatter.string(from: overviewDigestSince ?? Date().addingTimeInterval(-86400)) }
        return query
    }
    func scheduleOverviewNeeds(cursor: String? = nil, only: String? = nil, force: Bool = false) {
        guard startedLiveUpdates, !restoringPreferences, page == .overview else { return }
        if only == nil && overviewFocus == nil {
            // Every group's first page comes from one "overview" command (one service pass, not ten).
            let due = shownOverviewSurfaces.contains { surface in
                let query = overviewQuery(surface), observation = overviewObservations[surface]!
                return force || observation.query != query || observation.page == nil && !observation.loading
            }
            guard due else { return }
            overviewRead?.cancel(); overviewPending = []
            overviewRead = Task { [weak self] in await self?.readOverviewGroups() }
            return
        }
        let due = shownOverviewSurfaces.filter { surface in
            let query = overviewQuery(surface), observation = overviewObservations[surface]!
            return (only == nil || only == surface) && (force || observation.query != query || observation.page == nil && !observation.loading)
        }
        guard !due.isEmpty else { return }
        // A narrower request ("only") still finishes every group the stopped loader had not read yet.
        let pending = overviewPending.subtracting(due)
        overviewRead?.cancel()
        overviewPending = Set(due).union(pending)
        let order = shownOverviewSurfaces.filter { overviewPending.contains($0) }
        overviewRead = Task { [weak self] in
            for surface in order {
                guard let self, !Task.isCancelled else { return }
                await self.readOverviewNeed(surface, cursor: surface == only ? cursor : nil)
                self.overviewPending.remove(surface)
            }
        }
    }
    private var overviewPending: Set<String> = []
    private var shownOverviewSurfaces: [String] {
        overviewObservations.keys.sorted().filter { overviewFocus == nil || overviewFocus == $0 || $0 == "human_tasks" }
    }
    func moveOverviewPage(_ surface: String, cursor: String) { scheduleOverviewNeeds(cursor: cursor, only: surface, force: true) }
    private func readOverviewNeeds() async {
        overviewRead?.cancel(); overviewPending = []
        if overviewFocus == nil { await readOverviewGroups(); return }
        for surface in shownOverviewSurfaces { await readOverviewNeed(surface, cursor: nil) }
    }
    private func readOverviewGroups() async {
        let surfaces = shownOverviewSurfaces
        var started: [String: (query: WorkspacePageQuery, generation: UUID)] = [:]
        for surface in surfaces { let query = overviewQuery(surface); started[surface] = (query, overviewObservations[surface]!.begin(query)) }
        var params: [String: Any] = ["surface": "overview", "since": overviewQuery("completed_since").since]
        params["project_id"] = projectID
        do {
            let response = try await request("workspace_page", params)
            guard !Task.isCancelled, page == .overview else { return }
            let groups = response["groups"] as? [String: [String: Any]] ?? [:]
            var stale = false
            for surface in surfaces {
                guard let (query, generation) = started[surface], let observation = overviewObservations[surface] else { continue }
                guard overviewQuery(surface) == query else { observation.cancel(); stale = true; continue }
                guard let group = groups[surface] else { observation.fail(generation); continue }
                do { if try observation.receive(group, query: query, generation: generation), let installed = observation.page { ticketCatalog.install(workspace: installed) } }
                catch { observation.fail(generation) }
            }
            if let requests = overviewObservations["requests"]?.page, let owned = overviewObservations["human_tasks"]?.page,
               ticketCatalog.needsCount != requests.total + owned.total { ticketCatalog.needsCount = requests.total + owned.total }
            connected = true
            if eventCursor == nil { eventCursor = response["event_cursor"] as? String ?? (response["content_cursor"] as? String) }
            // The window's scope changed while the read ran: read again instead of leaving groups loading.
            if stale { scheduleOverviewNeeds(force: true) }
        } catch {
            guard !Task.isCancelled else { return }
            for (surface, value) in started { overviewObservations[surface]?.fail(value.generation) }
        }
    }
    private func readOverviewNeed(_ surface: String, cursor: String?) async {
        let query = overviewQuery(surface), observation = overviewObservations[surface]!, generation = observation.begin(query)
        do {
            let response = try await request("workspace_page", query.parameters(cursor: cursor))
            guard !Task.isCancelled, page == .overview else { return }
            // The window's scope changed while this read ran: read the group again instead of leaving it loading.
            guard overviewQuery(surface) == query else { observation.cancel(); scheduleOverviewNeeds(only: surface, force: true); return }
            if try observation.receive(response, query: query, generation: generation), let installed = observation.page {
                ticketCatalog.install(workspace: installed)
                if let requests = overviewObservations["requests"]?.page, let owned = overviewObservations["human_tasks"]?.page,
                   ticketCatalog.needsCount != requests.total + owned.total { ticketCatalog.needsCount = requests.total + owned.total }
                connected = true
                if eventCursor == nil { eventCursor = response["event_cursor"] as? String ?? installed.contentCursor }
            }
        } catch { if !Task.isCancelled { observation.fail(generation) } }
    }
    func retryWorkspacePage() {scheduleWorkspacePage(force:true)}
    private func scheduleWorkspacePage(cursor:String? = nil,force:Bool=false) {
        guard startedLiveUpdates,!restoringPreferences,!usesTicketPages else{return}
        if page == .overview {scheduleOverviewNeeds(force:force);return}
        guard force || workspaceObservation.query != workspaceQuery || workspaceObservation.page == nil && !workspaceObservation.loading else{return}
        workspaceRead?.cancel()
        workspaceRead=Task {[weak self] in await self?.readWorkspacePage(cursor:cursor)}
    }
    private func readWorkspacePage(cursor:String?) async {
        let query=workspaceQuery,id=workspaceObservation.begin(workspaceQuery)
        do {
            let response=try await request("workspace_page",query.parameters(cursor:cursor))
            guard !Task.isCancelled,!usesTicketPages,workspaceQuery==query else{return}
            if try workspaceObservation.receive(response,query:query,generation:id) {
                connected=true;if eventCursor == nil {eventCursor=response["event_cursor"] as? String ?? workspaceObservation.page?.contentCursor}
            }
        } catch {if !Task.isCancelled {workspaceObservation.fail(id)}}
    }
    private func scheduleOtherDetail(for detail:Detail?) {
        let taskQuery=groupTasksObservation.query,candidateQuery=groupCandidatesObservation.query
        otherDetailRead?.cancel();otherDetailObservation.cancel(clear:true)
        groupTasksRead?.cancel();groupTasksObservation.cancel(clear:true)
        groupCandidatesRead?.cancel();groupCandidatesObservation.cancel(clear:true)
        guard startedLiveUpdates,let detail else{return}
        let id:String
        switch detail {case .request(let value),.group(let value),.project(let value):id=value;case .task:return}
        let query=WorkspacePageQuery(surface:"record",project:nil,record:id)
        let generation=otherDetailObservation.begin(query)
        otherDetailRead=Task {[weak self] in
            guard let self else{return}
            do {
                let response=try await self.request("workspace_page",query.parameters())
                guard !Task.isCancelled,self.detail==detail else{return}
                if try self.otherDetailObservation.receive(response,query:query,generation:generation),let group=self.selectedOther,group.string("record_type")=="group" {
                    if let taskQuery,RecordIdentity(taskQuery.record)==RecordIdentity(group.id) {self.loadGroupTasks(group,closed:taskQuery.archived)}
                    if let candidateQuery,RecordIdentity(candidateQuery.record)==RecordIdentity(group.id) {self.loadGroupCandidates(group,closed:candidateQuery.archived)}
                }
            } catch {if !Task.isCancelled {self.otherDetailObservation.fail(generation)}}
        }
    }
    func retryOtherDetail() {scheduleOtherDetail(for:detail)}
    func loadGroupTasks(_ group:Record,closed:Bool,cursor:String? = nil) {
        groupTasksRead?.cancel()
        let query=WorkspacePageQuery(surface:group.string("kind")=="triage" ? "triage_tasks" : "epic_tasks",project:group.string("project_id"),record:group.id,archived:closed)
        let generation=groupTasksObservation.begin(query)
        groupTasksRead=Task {[weak self] in
            guard let self else{return}
            do {let value=try await self.request("workspace_page",query.parameters(cursor:cursor));guard !Task.isCancelled,self.detail == .group(group.id) else{return};_=try self.groupTasksObservation.receive(value,query:query,generation:generation)}
            catch {if !Task.isCancelled {self.groupTasksObservation.fail(generation)}}
        }
    }
    func loadGroupCandidates(_ group:Record,closed:Bool,cursor:String? = nil) {
        groupCandidatesRead?.cancel()
        let query=WorkspacePageQuery(surface:group.string("kind")=="triage" ? "triage_candidates" : "epic_candidates",project:group.string("project_id"),record:group.id,archived:closed)
        let generation=groupCandidatesObservation.begin(query)
        groupCandidatesRead=Task {[weak self] in
            guard let self else{return}
            do {let value=try await self.request("workspace_page",query.parameters(cursor:cursor));guard !Task.isCancelled,self.detail == .group(group.id) else{return};_=try self.groupCandidatesObservation.receive(value,query:query,generation:generation)}
            catch {if !Task.isCancelled {self.groupCandidatesObservation.fail(generation)}}
        }
    }

    /// Compatibility path for existing full-index consumers. This is explicit
    /// loading, not a claim that selected-detail/history paging has been completed.
    func ensureFullSnapshot() async {
        guard fullSnapshotDirty || !fullSnapshotAvailable else { return }
        await refreshFullSnapshot(quiet: true)
    }

    // Synchronous batches only: no queued task, timer or separate query cache.
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
        restoringPreferences = true
        self.page = page; projectID = project
        loadTaskView()
        restoringPreferences = false
        preferences.set(page.rawValue, forKey: "lastPage")
        preferences.set(project, forKey: "lastProject")
        prepareTicketWorkspace()
        if !usesTicketPages { scheduleWorkspacePage(force:true) }
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
        
        if let prior = self.detail, prior != detail { detailBackStack.append(prior) }
        if self.detail == nil {
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.2)) { self.detail = detail }
        } else {
            replaceDetail(detail)
        }
    }
    func closeDetail() { withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.2)) { detail = nil; detailBackStack = [] } }
    func goBack() { if let prior = detailBackStack.popLast() { replaceDetail(prior) } else { closeDetail() } }
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
        return draftSaveError("capture",projectID)==nil ? id : nil
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
        guard connected || params["command_id"] == nil else { throw ChecklistError("SERVICE_UNAVAILABLE", "Reconnect and refresh before sending changes. Your local draft is preserved.") }
        try Task.checkCancellation()
        let family: NativeRenderMetrics.Family = method == "workspace_page" && params["surface"] as? String == "record" ? .selectedOther : .classify(method,detail:params["detail_level"] as? String)
        let metric=NativeRenderMetrics.startRequest(family)
        var succeeded=false
        defer {NativeRenderMetrics.finishRequest(metric,succeeded:succeeded)}
        let reply: [String:Any]
        if let requestTransport {reply=try await requestTransport(method,params)}
        else {reply=try await NativeServiceTransport.call(method,params)}
        try Task.checkCancellation()
        if let failure = reply["error"] as? [String: Any] {
            throw ChecklistError(failure["code"] as? String ?? "SERVICE_ERROR", (failure["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "The Checklist service could not complete this request (\(failure["code"] as? String ?? "no error code")).")
        }
        succeeded=true
        if var result = reply["data"] as? [String: Any] {
            if let cursor = reply["event_cursor"] { result["event_cursor"] = cursor }
            return result
        }
        if let result = reply["result"] as? [String: Any] { return result }
        return reply
    }

    func refresh(quiet: Bool = false) async {
        archivePreviewEpoch = UUID()
        defer { connectionAttempted = true }
        if usesTicketPages {
            ticketPageRead?.cancel()
            await readTicketPage(query: ticketPageQuery, cursor: nil)
            if case .task(let id) = detail {
                scheduleSelectedTicket(for:detail)
            } else if detail != nil {scheduleOtherDetail(for:detail)}
        } else {
            if page == .overview { await readOverviewNeeds() } else { await readWorkspacePage(cursor:nil) }
            if case .task = detail {scheduleSelectedTicket(for:detail)} else {scheduleOtherDetail(for:detail)}
        }
    }

    private func refreshFullSnapshot(quiet: Bool = false) async {
        // A waiter may observe a newer event while a snapshot is in flight.
        // Coalesce it into another fetch; only a successfully installed snapshot
        // advances the applied cursor.
        refreshRequested = true
        invalidateSelectedEligibility()
        guard !refreshing else { return }
        refreshing = true
        if !quiet { loading = true }
        defer {
            refreshing = false; loading = false
            if connected && !Task.isCancelled { scheduleSelectedEligibility(for: detail) }
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
                eventCursor = snapshot["event_cursor"] as? String ?? snapshot["cursor"] as? String ?? (data["cursor"] as? String) ?? eventCursor
                if let projectID, !projects.contains(where: { $0.id == projectID }) { self.projectID = nil }
                connected = true
            } catch {
                connected = false
                // The offline banner reports the outage once; retries never raise the alert again.
                lastServiceFailure = error.localizedDescription
                connectionAttempted = true
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

    func run(_ method: String, _ params: [String: Any] = [:], success: String? = nil, failure: ((Error) -> Void)? = nil, completion: (([String: Any]) -> Void)? = nil) {
        guard allowWrite() else { return }
        var command = params
        if command["command_id"] == nil { command["command_id"] = UUID().uuidString }
        pendingMutation = (method, command, success, completion, failure)
        do {
            let bytes = try JSONSerialization.data(withJSONObject: ["method": method, "params": command])
            try pendingCommandPersistence.save(String(data: bytes, encoding: .utf8)!,pendingCommandKey)
        } catch { pendingMutation = nil; self.error = "Cannot preserve the command for safe recovery: \(error.localizedDescription)"; return }
        performPendingMutation()
    }

    func retryPendingMutation() {
        guard pendingMutation != nil else { return }
        guard connected, !busy else { inform(connected ? DisabledReasons.saving : DisabledReasons.offline); return }
        error = nil; performPendingMutation()
    }
    private func performPendingMutation() {
        guard let pending = pendingMutation else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let reply = try await request(pending.method, pending.params)
                pendingMutation = nil; hasPendingMutation = false; pendingCommandPersistence.remove(pendingCommandKey)
                if !pending.method.hasPrefix("media_") {await refresh(quiet: true)}
                if pending.method == "message_mentions_prepare" {
                    // Preparation's caller must inspect the refreshed selected
                    // context, rather than mistake a scheduled read for readiness.
                    // Capture this read only: a later selection/invalidating read
                    // still fails the caller's exact destination/context guards.
                    let preparedContextRead = selectedTicketRead
                    await preparedContextRead?.value
                }
                noticeIsWarning = false; notice = pending.success
                busy = false
                pending.completion?(reply)
            } catch {
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
    func applyChangeCoverage(_ changes:[String:Any]) async {
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
        // Task/work events remain confined to the selected project, while an
        // unknown or project-policy/catalog event conservatively reloads catalog.
        let catalogAffected=reset || rows.contains {families($0).contains("all")}
        let visible=rows.filter {inProject($0,projectID)}
        let ticketAffected=catalogAffected || visible.contains {row in let f=families(row);return !f.isDisjoint(with:["all","tasks","groups"]) || !search.isEmpty && f.contains("messages")}
        let workspaceAffected=catalogAffected || visible.contains {row in
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
        if selectedAffected {invalidateSelectedTicketFreshness();invalidateSelectedEligibility()}
        if usesTicketPages && ticketAffected {ticketPageRead?.cancel();await readTicketPage(query:ticketPageQuery,cursor:nil)}
        else if !usesTicketPages && workspaceAffected {
            if page == .overview {await readOverviewNeeds()} else {workspaceRead?.cancel();await readWorkspacePage(cursor:nil)}
        }
        if selectedAffected {scheduleSelectedTicket(for:detail)}
        if otherAffected {scheduleOtherDetail(for:detail)}
        if let cursor=changes["event_cursor"] as? String {eventCursor=cursor}
    }

    func stopWindowReads() {
        ticketPageRead?.cancel();ticketPageReadID=UUID();ticketPages.invalidate()
        workspaceRead?.cancel();workspaceObservation.cancel()
        otherDetailRead?.cancel();otherDetailObservation.cancel()
        groupTasksRead?.cancel();groupTasksObservation.cancel()
        groupCandidatesRead?.cancel();groupCandidatesObservation.cancel()
        overviewRead?.cancel(); overviewPending = []; for observation in overviewObservations.values { observation.cancel() }
        selectedTicketRead?.cancel();selectedTicketReadID=UUID();selectedRecordsReadID=UUID();selectedWorkRead?.cancel()
        recordHistoryRead?.cancel();recordHistoryObservation.cancel();invalidateSelectedEligibility()
        scopedReadGeneration=UUID()
    }

    /// Pauses of the live loop: after each wait, and before a retry after a failure. Tests shorten them.
    var liveWaitPause: UInt64 = 500_000_000
    var liveRetryPause: UInt64 = 3_000_000_000

    func startLiveUpdates() async {
        startedLiveUpdates = true
        await refresh()
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
                if changes["changed"] as? Bool == true {
                    NativeRenderMetrics.changeObserved()
                    await applyChangeCoverage(changes)
                }
                try await Task.sleep(nanoseconds: liveWaitPause)
            } catch {
                connected = false
                lastServiceFailure = error.localizedDescription
                fullSnapshotDirty = true
                if (error as? ChecklistError)?.code == "CURSOR_RESET" {
                    // The old coverage interval no longer exists. Only this
                    // explicit reset allows the successful reload to establish a
                    // new interval; ordinary reads never skip unseen events.
                    eventCursor=nil
                    invalidateSelectedTicketFreshness()
                    workspaceRead?.cancel();workspaceObservation.cancel(clear:true)
                    otherDetailRead?.cancel();otherDetailObservation.cancel(clear:true)
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
                await refresh(quiet: true)
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
