import XCTest
import SwiftUI
import ChecklistIPC
@testable import ChecklistApp

/// Bounded page replies derived from a real-size inert corpus. No router, store,
/// native app window, subscription mutations or live files are used.
@MainActor final class ScreenTimingTests: XCTestCase {
    private enum Surface: String {case overview, tickets, epics, ticketDetail = "ticket_detail", projectSwitch = "project_switch", cleanup}
    @MainActor private final class Fixture {
        let preferences: UserDefaults
        init(_ preferences: UserDefaults) {self.preferences = preferences}
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let surfaces = ChecklistStore.overviewGroups.map(\.surface) + ["human_tasks", "recent_reviews", "completed_since"]
        let events = (0..<20_707).map { ["id":"event-\($0)", "project_id":"p", "created_at":"2026-10-24T10:00:00Z"] }
        let tasks = (0..<542).map { ["id":"task-\($0)", "project_id":"p", "key":"T-\($0)", "title":"Synthetic ticket \($0)", "status_id":"queued", "status_category":"queued", "revision":1, "epic_id":"epic-0"] as [String:Any] }
        var version = "v1", delay: UInt64 = 0
        var timeoutOverview = false
        var holdQuiet = false
        var quietRead: CheckedContinuation<Void,Never>?
        var calls: [String] = []
        var removedBytes = 42, holdReceipts = false
        var heldReceipts: [(CheckedContinuation<[String:Any],Error>,[String:Any])] = []
        func releaseReceipts(throwing error: Error? = nil) {
            let held = heldReceipts;heldReceipts = []
            for (continuation,reply) in held {if let error {continuation.resume(throwing:error)} else {continuation.resume(returning:reply)}}
        }
        var projects: [[String:Any]] { (0..<5).map { ["id":$0 == 0 ? "p" : "q\($0)", "name":"Synthetic project \($0)", "revision":1, "brief":String(repeating:"Context. ",count:100)] } }
        var service: [String:Any] { ["store_incarnation":"fixture-store", "read_version":version] }
        func workspace(_ params: [String:Any]) -> [String:Any] {
            let surface = params["surface"] as! String
            if surface == "overview" {
                var groups: [String:[String:Any]] = [:]
                for surface in surfaces {var p = params;p["surface"] = surface;var group = workspace(p);group.removeValue(forKey:"service");group.removeValue(forKey:"projects");groups[surface] = group}
                return ["groups":groups,"projects":projects,"service":service,"needs_you_count":0,"content_cursor":"cursor","event_cursor":"cursor"]
            }
            let project = params["project_id"] as? String ?? "p"
            let rows: [[String:Any]]
            if surface == "record" {rows = [projects[0].merging(["id":params["record_id"] as! String,"project_id":"p","record_type":"project"]) {_,n in n}]}
            else if surface == "epics" {rows = (0..<8).map { ["id":"epic-\($0)","project_id":project,"name":"Synthetic Epic \($0)","kind":"epic","ticket_count":67,"done_count":10] }}
            else if ["human_tasks","requests","recent_reviews"].contains(surface) {rows = []}
            else {rows = Array(tasks.prefix(surface == "completed_since" ? 1 : 5)).map {$0.merging(["project_id":project,"title":version == "v1" ? "Original synthetic row" : "Updated synthetic row"]) {_,n in n}}}
            return ["workspace_version":1,"surface":surface,"record_id":params["record_id"] as? String ?? "","rows":rows,"total":rows.count,"needs_you_count":0,"has_more":false,"next_cursor":NSNull(),"previous_cursor":NSNull(),"projects":projects,"service":service,"content_cursor":"cursor"]
        }
        func tickets(_ params:[String:Any]) -> [String:Any] {
            let pid = params["project_id"] as? String ?? "p"
            let rows = Array(tasks.prefix(200)).map {$0.merging(["project_id":pid]) {_,n in n}}
            let triages: [[String:Any]] = (0..<120).map { i in ["id":"triage-\(i)","project_id":pid,"revision":1,"name":"Triage \(i)","purpose":"Synthetic","kind":"triage","phase":"implementation","archived":false,"active_attention":false,"status_state":"uniform","status_id":"queued","status_name":"Queued","status_category":"queued","member_count":2,"matching_count":2,"page_member_ids": i < 100 ? ["task-\(i*2)","task-\(i*2+1)"] : [],"members_complete":false] }
            return ["schema_version":1,"tickets_page":["query_key":"query","content_cursor":"cursor","tasks":rows,"ordinary_ids":[],"triages":triages,"scoped_count":542,"matched_count":542,"has_more":true,"next_cursor":"next","previous_cursor":NSNull(),"projects":projects,"statuses":[["id":"queued","project_id":pid,"name":"Queued","category":"queued","sort_order":0]],"tags":[],"epics":[],"outstanding_request_count":0,"human_task_count":0,"overview_requests":[],"overview_request_count":0,"service":service]]
        }
        func transport(_ method: String,_ params:[String:Any]) async throws -> [String:Any] {
            if method == "changes_wait" {try await Task.sleep(nanoseconds:30_000_000_000);throw CancellationError()}
            calls.append(method + ":" + (params["surface"] as? String ?? ""))
            if holdQuiet, method == "workspace_page", params["surface"] as? String == "needs_quiet" {
                await withCheckedContinuation {quietRead = $0}
            }
            if delay > 0 {try await Task.sleep(nanoseconds:delay)}
            switch method {
            case "workspace_page":
                if timeoutOverview, params["surface"] as? String == "overview" {throw CommandReply.unknown(commandID:nil,reason:"reply_timeout")}
                return workspace(params)
            case "task_list": return tickets(params)
            case "task_context":
                let id = params["task_id"] as! String
                return ["ui_version":1,"context_cursor":"context","task":tasks.first {$0["id"] as? String == id}!,"project":projects[0],"service":service,"collections":["messages":(0..<50).map {["id":"message-\($0)","project_id":"p","task_id":id,"body":"Synthetic note \($0). " + String(repeating:"Bounded conversation content. ",count:8),"created_at":"2026-10-24T10:00:00Z"]},"attachments":[],"attempts":[],"requests":[],"events":Array(events.suffix(10)),"sessions":[],"groups":[],"statuses":[],"tags":[]],"counts":["messages":300,"attachments":0,"attempts":0,"requests":0],"full_record_loaded":false,"next_history_cursor":"older-notes","previous_history_cursor":NSNull(),"has_more_messages":true]
            case "task_get": return tasks[0].merging(["completion_eligibility":["eligible":false,"task_revision":1,"manifest_id":NSNull(),"blockers":[]]]) {_,n in n}
            case "service_info": return service
            case "media_navigation": return ["types":[]]
            case "cleanup_job_list": return ["cleanup_jobs":[]]
            case "ticket_cleanup_receipts":
                let reply: [String:Any] = ["receipts":(0..<50).map {["id":"receipt-\($0)","created_at":"2026-10-24T10:00:00Z","summary":["removed_bytes":removedBytes,"retained_count":542],"bytes_state":"complete"]}]
                if holdReceipts {return try await withCheckedThrowingContinuation {heldReceipts.append(($0,reply))}}
                return reply
            default: XCTFail("Unexpected fake request \(method)");return [:]
            }
        }
        func store() -> ChecklistStore {
            preferences.set(Page.overview.rawValue,forKey:"lastPage")
            preferences.set((0..<120).map {"triage-\($0)"},forKey:"expandedTriages")
            return ChecklistStore(draftJournal:LocalDraftJournal(directory:root),preferences:preferences,restorePendingCommand:false,desktopAlerts:DesktopAlertCoordinator(sink:TimingAlertSink()),requestTransport:{[self] in try await transport($0,$1)},navigationMemory:DetailItemNavigationMemory())
        }
    }
    private struct Host: View {
        @ObservedObject var store: ChecklistStore
        var body: some View {
            Group {
                if let detail = store.detail {DetailOverlay(detail:detail)}
                else {switch store.page {case .overview: OverviewView();case .tasks: VStack(spacing:0) {ProjectWorkspaceTabs();TaskWorkspaceView()};case .epics: EpicWorkspaceView();default: Text("Other")}}
            }.environmentObject(store).defaultAppStorage(store.windowPreferences).frame(width:1100,height:850)
        }
    }
    private func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {if predicate() {return};try await Task.sleep(nanoseconds:5_000_000)}
        XCTFail("Template did not settle");throw CancellationError()
    }
    private func ready(_ store: ChecklistStore) -> Bool {
        if store.page == .overview {return store.overviewObservations.values.allSatisfy {$0.page != nil}}
        if store.page == .tasks {return store.preparedTicketWorkspace != nil}
        return store.workspacePageLoaded
    }
    private func measure(_ surface: Surface, cached: Bool = true, action: (ChecklistStore)->Void) async throws {
        _ = NSApplication.shared
        let f = Fixture(isolatedDefaults("ScreenTiming").preferences), store = f.store(), live = Task {await store.startLiveUpdates()}
        let host = NSHostingView(rootView:Host(store:store))
        // A synthetic XCTest host outside the desktop, never an installed app window.
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:1100,height:850),styleMask:[],backing:.buffered,defer:false)
        window.title = "Synthetic Checklist screen measurement host (offscreen)"
        window.isReleasedWhenClosed = false;window.contentView = host;window.orderFront(nil)
        defer {NativeRenderMetrics.cancel();live.cancel();store.stopWindowReads();window.contentView = nil;window.close();try? FileManager.default.removeItem(at:f.root)}
        func draw() {
            host.layoutSubtreeIfNeeded();host.displayIfNeeded();window.displayIfNeeded()
            // AppKit may occlude a native child of an offscreen TextEditor /
            // ScrollView even after hosting layout. Flush the real probe views
            // after content layout; no bitmap readback or synthetic receipt.
            func displayProbes(_ view:NSView) {
                for child in view.subviews {displayProbes(child)}
                if String(describing:type(of:view)).contains("FrameView") {view.display()}
            }
            displayProbes(host)
        }
        try await until {ready(store) && !store.sidebarLoading}
        store.select(.tasks,project:"p");try await until {store.preparedTicketWorkspace != nil && !store.ticketPageLoading}
        draw();try await Task.sleep(nanoseconds:30_000_000)
        store.select(.epics,project:"p");try await until {store.workspacePageLoaded && !store.workspaceLoading}
        store.open(.task("task-0"));try await until {store.selectedTicketCurrent("task-0")}
        store.closeDetail()
        store.open(.project("p"));try await until {!store.otherDetailLoading};draw()
        try await until {store.ticketCleanupReceipts.receipts.count == 50}
        store.closeDetail()
        // Warm the exact Overview query including the digest timestamp.
        store.select(.overview);try await until {ready(store) && !store.sidebarLoading};draw()
        store.select(.epics,project:"p");try await until {!store.workspaceLoading};draw()
        try await Task.sleep(nanoseconds:50_000_000)
        if surface == .projectSwitch {store.select(.epics,project:"q1");try await until {!store.workspaceLoading};draw();try await Task.sleep(nanoseconds:20_000_000)}
        if !cached {f.version = "cold-version";_ = try await store.request("service_info")}
        f.delay = cached ? 450_000_000 : 50_000_000
        NativeRenderMetrics.begin(sample:31)
        var load = [Double](repeating:0,count:3);getloadavg(&load,3)
        let start = ProcessInfo.processInfo.systemUptime
        action(store)
        if surface == .ticketDetail {XCTAssertNotNil(store.selectedTask("task-0"),"The detail timing case must start with its cached display installed")}
        while ProcessInfo.processInfo.systemUptime-start < (cached ? 0.8 : 1.5) {
            draw();try await Task.sleep(nanoseconds:2_000_000)
        }
        let snapshot = try XCTUnwrap(NativeRenderMetrics.finish())
        // Decode the optional new measurements so these exact tests compile
        // against r30j too; its missing native-frame/log hooks must fail here.
        let object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(snapshot)) as! [String:Any]
        let screens = object["screens"] as? [String:[String:Any]] ?? [:]
        if screens[surface.rawValue] == nil {
            func probes(_ view:NSView) -> [String] {
                let own = String(describing:type(of:view)).contains("FrameView") ? ["\(type(of:view)) surface=\(view.identifier?.rawValue ?? "") needsDisplay=\(view.needsDisplay) frame=\(view.frame) visible=\(view.visibleRect) hidden=\(view.isHidden) window=\(view.window != nil) state=\(Mirror(reflecting:view).children.filter {$0.label == "navigation" || $0.label == "completion"}.map {"\($0.label ?? "")=\($0.value)"})"] : []
                return own + view.subviews.flatMap(probes)
            }
            let clock = Mirror(reflecting:store).children.first {$0.label == "screenTiming"}.map {Mirror(reflecting:$0.value).children.map {"\($0.label ?? "")=\($0.value)"}}
            print("P9 CLOCK detail=\(String(describing:store.detail)) clock=\(String(describing:clock)) expired=\(snapshot.expired) truncated=\(snapshot.truncated)")
            print("P9 missing frame surface=\(surface.rawValue) cached_detail_present=\(store.selectedTask("task-0") != nil) bodies=\(snapshot.bodies) probes=\(probes(host))")
        }
        let result = try XCTUnwrap(screens[surface.rawValue],"No native content frame for \(surface.rawValue)")
        let milliseconds = try XCTUnwrap(result["milliseconds"] as? Double)
        print("P9-r5 native surface=\(surface.rawValue) cached=\(result["cached"]!) duration_ms=\(milliseconds) corpus=542/120/20707 load=\(load)")
        XCTAssertEqual(result["cached"] as? Bool,cached,"The reported cache identity must match the tested path")
        XCTAssertLessThan(milliseconds,cached ? 300 : 1_000)
        if surface == .ticketDetail {XCTAssertLessThan(snapshot.bodies["messageRow"] ?? 0,50,"First frame must not eagerly construct the whole offscreen conversation")}
    }
    /// CL-260 item 2: a cached settings open installs its retained receipts at
    /// navigation, completes its native display pass with them, and only then
    /// replaces them from the background receipt read. No wall-clock budget.
    func testCachedCleanupOpenDisplaysRetainedReceiptsBeforeBackgroundRead() async throws {
        _ = NSApplication.shared
        let f = Fixture(isolatedDefaults("CachedCleanupOpen").preferences), store = f.store(), live = Task {await store.startLiveUpdates()}
        let host = NSHostingView(rootView:Host(store:store))
        // A synthetic XCTest host outside the desktop, never an installed app window.
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:1100,height:850),styleMask:[],backing:.buffered,defer:false)
        window.title = "Synthetic Checklist cached cleanup host (offscreen)"
        window.isReleasedWhenClosed = false;window.contentView = host;window.orderFront(nil)
        defer {f.releaseReceipts(throwing:CancellationError());live.cancel();store.stopWindowReads();window.contentView = nil;window.close();try? FileManager.default.removeItem(at:f.root)}
        func draw() {
            host.layoutSubtreeIfNeeded();host.displayIfNeeded();window.displayIfNeeded()
            func displayProbes(_ view:NSView) {for child in view.subviews {displayProbes(child)};if String(describing:type(of:view)).contains("FrameView") {view.display()}}
            displayProbes(host)
        }
        func settle(_ message: String,_ predicate: () -> Bool) async throws {
            for _ in 0..<400 {draw();if predicate() {return};try await Task.sleep(nanoseconds:5_000_000)}
            XCTFail(message);throw CancellationError()
        }
        let receipts = store.ticketCleanupReceipts
        func bytes() -> [Int] {receipts.receipts.map {$0.object("summary")["removed_bytes"] as? Int ?? -1}}
        func receiptReads() -> Int {f.calls.filter {$0.hasPrefix("ticket_cleanup_receipts")}.count}
        try await until {ready(store) && !store.sidebarLoading}
        store.open(.project("p"));try await until {!store.otherDetailLoading}
        try await settle("First settings visit did not load receipts") {receipts.loaded && receipts.scope == store.cleanupReceiptScope("p") && receipts.receipts.count == 50}
        // Another project's settings take over the window's receipt observation.
        store.closeDetail();store.open(.project("q1"));try await until {!store.otherDetailLoading}
        try await settle("Other settings visit did not load receipts") {receipts.loaded && receipts.scope == store.cleanupReceiptScope("q1")}
        let readsOpen = receiptReads()
        store.closeDetail();draw();try await Task.sleep(nanoseconds:20_000_000);draw()
        XCTAssertEqual(receiptReads(),readsOpen,"Closing settings must not issue a generation-scoped receipt read")
        XCTAssertEqual(receipts.scope,store.cleanupReceiptScope("q1").components(separatedBy:":").prefix(3).joined(separator:":") + ":v1","Closing settings must not replace the retained receipt scope")
        f.holdReceipts = true;f.removedBytes = 99
        let readsBefore = receiptReads()
        store.open(.project("p"))
        // Synchronously, before any view task, display pass or read reply.
        XCTAssertEqual(store.screenTiming.navigation(.cleanup)?.cached,true,"The tested path must be the cached settings open")
        XCTAssertEqual(receipts.scope,store.cleanupReceiptScope("p"),"Navigation must install the retained receipts of the restored scope")
        XCTAssertTrue(receipts.loaded)
        XCTAssertEqual(bytes(),Array(repeating:42,count:50),"Cached facts are the facts shown today")
        try await settle("The cached open must refresh its receipts in the background") {receiptReads() > readsBefore && !f.heldReceipts.isEmpty}
        try await settle("The native display pass must complete with the cached receipts while the read is pending") {store.screenTiming.navigation(.cleanup) == nil}
        XCTAssertFalse(f.heldReceipts.isEmpty,"The display pass completed before the background read returned")
        XCTAssertEqual(bytes(),Array(repeating:42,count:50))
        f.releaseReceipts()
        try await settle("The background reply must replace changed receipt facts") {bytes() == Array(repeating:99,count:50)}
        XCTAssertTrue(receipts.error.isEmpty)
    }
    func testAutomaticOverviewRefreshRetainsValidRowsAndCountsUntilEachReply() async throws {
        let f = Fixture(isolatedDefaults("RetainedOverview").preferences),store = f.store()
        let live = Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads();f.quietRead?.resume();f.quietRead = nil;try? FileManager.default.removeItem(at:f.root)}
        try await until {ready(store) && !store.sidebarLoading}
        let rows = store.overviewObservations.mapValues {$0.rows.map(\.id)}
        let totals = store.overviewObservations.mapValues {$0.page?.total}
        f.version = "v2";f.delay = 50_000_000;f.timeoutOverview = true;f.holdQuiet = true
        let refresh = Task {await store.applyChangeCoverage(["event_cursor":"v2-cursor","coverage":["schema_version":2,"complete":true,"reset":false,"changes":[["project_id":"p","families":["tasks"],"task_ids":["task-0"],"all_tasks":false]]]])}
        defer {refresh.cancel()}
        try await Task.sleep(nanoseconds:5_000_000)
        XCTAssertEqual(store.overviewObservations.mapValues {$0.rows.map(\.id)},rows)
        XCTAssertEqual(store.overviewObservations.mapValues {$0.page?.total},totals)
        XCTAssertEqual(SourceState.of(Array(store.overviewObservations.values),offline:false),.loaded,"Valid retained pages must not select a loader")
        // Complete live coverage publishes status groups first. Hold a later
        // quiet reply explicitly rather than assuming sequential group order.
        try await until {f.quietRead != nil && store.overviewObservations["completed_since"]?.loading == false}
        XCTAssertEqual(store.overviewObservations["completed_since"]?.rows.first?.string("title"),"Updated synthetic row")
        XCTAssertEqual(store.overviewObservations["needs_quiet"]?.rows.first?.string("title"),"Original synthetic row","A later pending group keeps its own retained rows")
        XCTAssertTrue(store.overviewObservations.values.contains {$0.loading})
        XCTAssertEqual(store.overviewObservations.mapValues {$0.page?.total},totals)
        f.holdQuiet = false;let quiet = f.quietRead;f.quietRead = nil;quiet?.resume()
        let accepted = await refresh.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(f.calls.filter {$0 == "workspace_page:overview"}.count,1)
        XCTAssertTrue(store.overviewObservations.values.allSatisfy {!$0.loading && $0.error == nil && $0.page != nil})
    }
    func testSettingsDisplayAndReceiptScopeRetireOnKnownGrantVersion() async throws {
        let f = Fixture(isolatedDefaults("SettingsVersionFence").preferences),store = f.store()
        let live = Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads();try? FileManager.default.removeItem(at:f.root)}
        try await until {ready(store) && !store.sidebarLoading}
        store.open(.project("p"));try await until {!store.otherDetailLoading}
        let scope = "p:" + store.storeIncarnation + ":" + store.archivePreviewEpoch.uuidString
        await store.ticketCleanupReceipts.load(scope:scope) {try await f.transport("ticket_cleanup_receipts",["project_id":"p"])}
        store.closeDetail();store.open(.project("p"))
        XCTAssertNotNil(store.selectedOther,"Settings restore before their background read")
        let oldEpoch = store.archivePreviewEpoch
        f.version = "new-grant-and-data-version"
        _ = try await store.request("service_info")
        XCTAssertNotEqual(store.archivePreviewEpoch,oldEpoch,"Receipt reuse must retire with known data/grant identity")
        store.closeDetail();f.delay = 50_000_000;store.open(.project("p"))
        XCTAssertNil(store.selectedOther,"Old-grant settings cannot be restored")
    }
    func testDisplayComparisonPreservesExactStringBytesAndJSONTypes() throws {
        let f = Fixture(isolatedDefaults("DisplayComparison").preferences)
        let query = WorkspacePageQuery(surface:"needs_pickup",project:nil)
        let observation = WorkspacePageObservation()
        var response = f.workspace(["surface":"needs_pickup"])
        var row: [String:Any] = ["id":"row","project_id":"p","title":"é","flag":true,"nested":["text":"é"]]
        response["rows"] = [row]
        XCTAssertTrue(try observation.receive(response,query:query,generation:observation.begin(query)))
        row["title"] = "e\u{301}";row["flag"] = 1;row["nested"] = ["text":"e\u{301}"]
        response["rows"] = [row]
        XCTAssertTrue(try observation.receive(response,query:query,generation:observation.begin(query)))
        XCTAssertEqual(Array(observation.rows[0].string("title").utf8),Array("e\u{301}".utf8))
        XCTAssertNotEqual(CFGetTypeID(observation.rows[0].values["flag"] as! NSNumber),CFBooleanGetTypeID())
        XCTAssertEqual(Array((observation.rows[0].object("nested")["text"] as! String).utf8),Array("e\u{301}".utf8))
    }
    func testScreenTimingUsesOnlyPublicFixedFields() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Sources/ChecklistApp/Support/ScreenTiming.swift")
        guard FileManager.default.fileExists(atPath:path.path) else {XCTFail("ScreenTiming log is absent");return}
        let source = try String(contentsOf:path,encoding:.utf8)
        XCTAssertTrue(source.contains("Logger(subsystem: \"org.checklist.app\", category: \"ScreenTiming\")"))
        let line = try XCTUnwrap(source.split(separator:"\n").first {$0.contains("Self.logger.notice(")})
        XCTAssertEqual(line.components(separatedBy:"privacy: .public").count-1,3)
        XCTAssertTrue(line.contains("surface="));XCTAssertTrue(line.contains("cache="));XCTAssertTrue(line.contains("duration_ms="))
    }
    func testCachedOverviewNativeFrame() async throws {try await measure(.overview) {$0.select(.overview)}}
    func testCachedTicketsWithTriagesNativeFrame() async throws {try await measure(.tickets) {$0.select(.tasks,project:"p")}}
    func testCachedEpicsNativeFrame() async throws {try await measure(.epics) {$0.select(.epics,project:"p")}}
    func testCachedTicketDetailNativeFrame() async throws {try await measure(.ticketDetail) {$0.open(.task("task-0"))}}
    func testCachedProjectSwitchNativeFrame() async throws {try await measure(.projectSwitch) {$0.select(.tasks,project:"p")}}
    func testColdCleanupNativeFrame() async throws {try await measure(.cleanup,cached:false) {$0.open(.project("p"))}}
    func testCachedCleanupNativeFrame() async throws {try await measure(.cleanup) {$0.open(.project("p"))}}
}
@MainActor private final class TimingAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization {.denied}
    func requestAuthorizationFromOwnerAction() async throws -> Bool {false}
    func send(_ alert:DesktopAlert) async throws {XCTFail("No alerts in read fixture")}
    func remove(_ identifiers:[String]) {}
}
