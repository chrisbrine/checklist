import XCTest
import SwiftUI
import AppKit
@testable import ChecklistApp

/// Synthetic hosted content and a suspended transport; no installed app or store.
@MainActor final class CachedProjectSwitchFrameTests: XCTestCase {
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-switch-" + UUID().uuidString)
        let preferences: UserDefaults
        init(_ preferences: UserDefaults) {self.preferences=preferences}
        var hold = false
        var pending: [CheckedContinuation<[String:Any],Error>] = []
        var calls = 0
        let service: [String:Any] = ["store_incarnation":"synthetic-store","read_version":"v1"]
        var projects: [[String:Any]] { ["p","q"].map {["id":$0,"name":"Project \($0)","revision":1]} }
        func transport(_ method: String, _ params: [String:Any]) async throws -> [String:Any] {
            if method == "changes_wait" {try await Task.sleep(nanoseconds:30_000_000_000);throw CancellationError()}
            calls += 1
            if hold {return try await withCheckedThrowingContinuation {pending.append($0)}}
            if method == "service_info" {return service}
            if method == "workspace_page" {
                return ["workspace_version":1,"surface":params["surface"] as! String,"record_id":"","rows":[],"total":0,"needs_you_count":0,"has_more":false,"next_cursor":NSNull(),"previous_cursor":NSNull(),"projects":projects,"service":service,"content_cursor":"cursor"]
            }
            guard method == "task_list" else {XCTFail("Unexpected fake read \(method)");return [:]}
            let project = params["project_id"] as? String ?? "p"
            let tasks = (0..<82).map { ["id":"\(project)-\($0)","project_id":project,"title":"\(project) cached ticket \($0)","key":"\(project)-\($0)","revision":1,"status_category":"queued","status_name":"Queued"] as [String:Any] }
            return ["schema_version":1,"tickets_page":["query_key":project,"content_cursor":"cursor","tasks":tasks,"ordinary_ids":tasks.map {$0["id"]!},"triages":[],"scoped_count":82,"matched_count":82,"has_more":false,"next_cursor":NSNull(),"previous_cursor":NSNull(),"projects":projects,"statuses":[],"tags":[],"epics":[],"outstanding_request_count":0,"human_task_count":0,"overview_requests":[],"overview_request_count":0,"service":service]]
        }
        func store() -> ChecklistStore {
            preferences.set(Page.tasks.rawValue,forKey:"lastPage");preferences.set("p",forKey:"lastProject")
            return ChecklistStore(draftJournal:LocalDraftJournal(directory:root),preferences:preferences,restorePendingCommand:false,
                desktopAlerts:DesktopAlertCoordinator(sink:ProjectSwitchAlertSink()),requestTransport:{[self] in try await transport($0,$1)})
        }
        func cleanup() {for read in pending {read.resume(throwing:CancellationError())};pending=[];try? FileManager.default.removeItem(at:root)}
    }
    private struct Host: View {
        @ObservedObject var store: ChecklistStore
        let tabsOnly: Bool
        var body: some View {
            VStack(spacing:0) {
                ProjectWorkspaceTabs()
                if !tabsOnly {TaskWorkspaceView()}
            }.environmentObject(store).defaultAppStorage(store.windowPreferences).frame(width:1100,height:850)
        }
    }
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {if condition() {return};try await Task.sleep(nanoseconds:5_000_000)}
        XCTFail("Synthetic project switch did not settle");throw CancellationError()
    }
    func testCachedProjectSwitchDisplaysHeadingAndRowsBeforeBackgroundReply() async throws {try await check(tabsOnly:false)}
    func testProjectTabsCannotFinishContentClock() async throws {try await check(tabsOnly:true)}
    func testRetainedContentFrameCannotConsumeNextNavigation() async throws {
        _ = NSApplication.shared
        let timing = ScreenTiming()
        // Build once, before the next project is selected. Deliberately retain
        // this exact root value instead of rebuilding destination content.
        let frozen = Text("Previous project content").frame(width:400,height:200)
            .screenContentFrame(timing, .projectSwitch, ready:true)
        let host = NSHostingView(rootView:frozen)
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:400,height:200),styleMask:[],backing:.buffered,defer:false)
        window.title="Synthetic retained content frame (offscreen)";window.isReleasedWhenClosed=false;window.contentView=host;window.orderFront(nil)
        defer {NativeRenderMetrics.cancel();window.contentView=nil;window.close()}
        func draw() {
            host.layoutSubtreeIfNeeded();host.displayIfNeeded();window.displayIfNeeded()
            func probes(_ view:NSView) {for child in view.subviews {probes(child)};if String(describing:type(of:view)).contains("FrameView") {view.display()}}
            probes(host)
        }
        draw()
        NativeRenderMetrics.begin(sample:254)
        timing.begin(.projectSwitch);timing.cached(.projectSwitch,true)
        // Let tracked probe invalidations run, without changing the frozen root.
        for _ in 0..<3 {await Task.yield();draw()}
        let snapshot=try XCTUnwrap(NativeRenderMetrics.finish())
        XCTAssertNil(snapshot.screens["project_switch"],"A retained old-content frame must not report a later navigation")
        XCTAssertNotNil(timing.navigation(.projectSwitch))
    }
    private func check(tabsOnly: Bool) async throws {
        _ = NSApplication.shared
        let restoreAX = AXProbe.enableEnhancedUserInterface();defer {restoreAX()}
        let f=Fixture(isolatedDefaults("CachedProjectSwitchFrame").preferences),store=f.store(),live=Task {await store.startLiveUpdates()}
        let host=NSHostingView(rootView:Host(store:store,tabsOnly:tabsOnly))
        let window=NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:1100,height:850),styleMask:[],backing:.buffered,defer:false)
        window.title="Synthetic cached project switch (offscreen)";window.isReleasedWhenClosed=false;window.contentView=host;window.orderFront(nil)
        defer {NativeRenderMetrics.cancel();live.cancel();store.stopWindowReads();f.cleanup();window.contentView=nil;window.close()}
        func draw() {
            host.layoutSubtreeIfNeeded();host.displayIfNeeded();window.displayIfNeeded()
            func probes(_ view:NSView) {for child in view.subviews {probes(child)};if String(describing:type(of:view)).contains("FrameView") {view.display()}}
            probes(host)
        }
        try await until {store.preparedTicketWorkspace != nil && !store.ticketPageLoading}
        draw()
        store.select(.tasks,project:"q");try await until {store.preparedTicketWorkspace?.visibleTicketIDs.contains("q-0") == true && !store.ticketPageLoading};draw()
        store.select(.tasks,project:"p");try await until {store.preparedTicketWorkspace?.visibleTicketIDs.contains("p-0") == true && !store.ticketPageLoading};draw()
        // Drain the preceding clock's async teardown before starting the measured switch.
        await Task.yield();draw()
        f.hold=true
        let calls=f.calls
        NativeRenderMetrics.begin(sample:254)
        store.select(.tasks,project:"q")
        XCTAssertEqual(f.calls,calls)
        XCTAssertEqual(store.currentProject?.string("name"),"Project q")
        XCTAssertEqual(store.preparedTicketWorkspace?.list.visibleTicketCount,82)
        XCTAssertEqual(store.preparedTicketWorkspace?.visibleTicketIDs.count,82)
        XCTAssertEqual(store.screenTiming.navigation(.projectSwitch)?.cached,true)
        // Both model restoration and native content must precede this suspended read.
        try await until {!f.pending.isEmpty}
        draw()
        if !tabsOnly {
            let text=AXProbe.text(host)
            XCTAssertTrue(text.contains("Project q"),"The first cached frame lacks its project heading: \(text)")
            XCTAssertTrue(text.contains("Showing 82 of 82 matching tickets"),"The first cached frame lacks its counts")
            XCTAssertTrue(text.contains("q cached ticket 0"),"The first cached frame lacks its rows")
        }
        let snapshot=try XCTUnwrap(NativeRenderMetrics.finish())
        if tabsOnly {XCTAssertNil(snapshot.screens["project_switch"],"Tabs are not the destination content frame");XCTAssertNil(snapshot.screens["tickets"])}
        else {XCTAssertEqual(snapshot.screens["project_switch"]?.cached,true);XCTAssertEqual(snapshot.screens["tickets"]?.cached,true)}
        XCTAssertFalse(f.pending.isEmpty,"The background read must remain suspended through the content frame")
    }
}
@MainActor private final class ProjectSwitchAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization {.denied}
    func requestAuthorizationFromOwnerAction() async throws -> Bool {false}
    func send(_ alert:DesktopAlert) async throws {XCTFail("No alerts in a rendering fixture")}
    func remove(_ identifiers:[String]) {}
}
