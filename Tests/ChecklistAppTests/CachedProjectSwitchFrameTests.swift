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
        var pending: [(String, [String:Any], CheckedContinuation<[String:Any],Error>)] = []
        var ticketReads: [String] = []
        var surfaceReads: [String] = []
        var calls = 0
        var realSize = false
        let service: [String:Any] = ["store_incarnation":"synthetic-store","read_version":"v1"]
        var projects: [[String:Any]] { ["p","q"].map {["id":$0,"name":"Project \($0)","revision":1]} }
        func transport(_ method: String, _ params: [String:Any]) async throws -> [String:Any] {
            if method == "changes_wait" {try await Task.sleep(nanoseconds:30_000_000_000);throw CancellationError()}
            calls += 1
            if method == "task_list" { ticketReads.append(params["project_id"] as? String ?? "all") }
            if method == "workspace_page" { surfaceReads.append(params["surface"] as? String ?? "") }
            if hold {return try await withCheckedThrowingContinuation {pending.append((method,params,$0))}}
            if method == "service_info" {return service}
            if method == "workspace_page" {
                let workers: [[String:Any]] = realSize && params["surface"] as? String == "worker_sessions" ? (0..<100).map {["id":"worker-\($0)","role":"worker","provider":"codex","native_conversation_title":"Synthetic worker \($0)"]} : []
                return ["workspace_version":1,"surface":params["surface"] as! String,"record_id":"","rows":workers,"total":workers.count,"needs_you_count":0,"has_more":false,"next_cursor":NSNull(),"previous_cursor":NSNull(),"projects":projects,"service":service,"content_cursor":"cursor"]
            }
            guard method == "task_list" else {XCTFail("Unexpected fake read \(method)");return [:]}
            let project = params["project_id"] as? String ?? "p"
            let large = realSize && project == "p"
            let tasks = (0..<(large ? 200 : 82)).map { ["id":"\(project)-\($0)","project_id":project,"title":"\(project) cached ticket \($0)","key":"\(project)-\($0)","revision":1,"status_category":"queued","status_name":"Queued"] as [String:Any] }
            let triages: [[String:Any]] = large ? (0..<120).map { i in
                ["id":"triage-\(i)","project_id":project,"revision":1,"name":"Synthetic Triage \(i)","purpose":"Real-size template","kind":"triage","phase":"implementation","archived":false,"active_attention":false,"status_state":"uniform","status_id":"queued","status_name":"Queued","status_category":"queued","member_count":2,"matching_count":2,"page_member_ids":i < 100 ? ["p-\(i*2)","p-\(i*2+1)"] : [],"members_complete":false]
            } : []
            return ["schema_version":1,"tickets_page":["query_key":project,"content_cursor":"cursor","tasks":tasks,"ordinary_ids":large ? [] : tasks.map {$0["id"]!},"triages":triages,"scoped_count":large ? 286 : 82,"matched_count":large ? 286 : 82,"has_more":large,"next_cursor":large ? "next" as Any : NSNull(),"previous_cursor":NSNull(),"projects":projects,"statuses":[],"tags":[],"epics":[],"outstanding_request_count":0,"human_task_count":0,"overview_requests":[],"overview_request_count":0,"service":service]]
        }
        func store() -> ChecklistStore {
            preferences.set(Page.tasks.rawValue,forKey:"lastPage");preferences.set("p",forKey:"lastProject")
            return ChecklistStore(draftJournal:LocalDraftJournal(directory:root),preferences:preferences,restorePendingCommand:false,
                desktopAlerts:DesktopAlertCoordinator(sink:ProjectSwitchAlertSink()),requestTransport:{[self] in try await transport($0,$1)})
        }
        func release() async throws {
            hold = false
            let reads = pending; pending = []
            for (method,params,read) in reads {read.resume(returning:try await transport(method,params))}
        }
        func cleanup() {for read in pending {read.2.resume(throwing:CancellationError())};pending=[];try? FileManager.default.removeItem(at:root)}
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
    func testOverviewReturnPrefetchWaitsForColdDestination() async throws {
        let f = Fixture(isolatedDefaults("DeferredDigest").preferences);f.realSize = true
        let store = f.store(), live = Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads();f.cleanup()}
        try await AXProbe.until {store.ticketPageMatchedCount == 286 && !store.ticketPageLoading}
        // Reproduce the departing Overview's visit/disappear boundary, without
        // a database or a wall-clock assertion about the held destination.
        store.beginOverviewVisit();f.hold = true
        store.select(.tasks,project:"q");store.endOverviewVisit()
        try await AXProbe.until {f.ticketReads.contains("q")}
        for _ in 0..<10 {await Task.yield()}
        XCTAssertFalse(f.surfaceReads.contains("completed_since"),"Optional prefetch cannot race the cold destination")
        try await f.release()
        try await AXProbe.until {store.ticketPageMatchedCount == 82 && f.surfaceReads.contains("completed_since")}
    }
    func testColdProjectReadDoesNotInheritPreviousSurfaceWatchdogAge() async throws {
        _ = NSApplication.shared
        let restoreAX = AXProbe.enableEnhancedUserInterface(); defer {restoreAX()}
        let f = Fixture(isolatedDefaults("ColdProjectWatchdog").preferences)
        f.realSize = true
        let store = f.store(), live = Task {await store.startLiveUpdates()}
        let host = NSHostingView(rootView:Host(store:store,tabsOnly:false))
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:1100,height:850),styleMask:[],backing:.buffered,defer:false)
        window.title = "Synthetic cold project read (offscreen)"; window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer {NativeRenderMetrics.cancel();live.cancel();store.stopWindowReads();f.cleanup();window.contentView = nil;window.close()}
        func draw() {host.layoutSubtreeIfNeeded();host.displayIfNeeded();window.displayIfNeeded()}
        try await AXProbe.until {store.ticketPageMatchedCount == 286 && !store.ticketPageLoading}
        draw()
        var now: TimeInterval = 100
        store.liveNow = {now}; f.hold = true
        let coverage = Task {await store.applyChangeCoverage(["changed":true,"event_cursor":"next","coverage":["schema_version":2,"complete":true,"reset":false,"changes":[["project_id":"p","families":["tasks"],"all_tasks":true]]]])}
        defer {coverage.cancel()}
        try await AXProbe.until {f.ticketReads.filter {$0 == "p"}.count >= 2}
        // Virtual time makes the old scope overdue, without a wall-clock budget.
        now += 1.6
        NativeRenderMetrics.begin(sample:254)
        store.select(.tasks,project:"q")
        try await AXProbe.until {f.ticketReads.contains("q")}
        draw()
        XCTAssertNil(NativeRenderMetrics.finish()?.screens["project_switch"],"Loading is not a destination content frame")
        let tick = Task {await store.checkLiveFreshness(selected:false)}
        defer {tick.cancel()}
        for _ in 0..<10 {await Task.yield()}
        XCTAssertEqual(f.ticketReads.filter {$0 == "q"}.count,1,"The preceding screen's stale age must not cancel a fresh project read")
        NativeRenderMetrics.begin(sample:254)
        try await f.release()
        await tick.value
        try await AXProbe.until {store.ticketPageMatchedCount == 82 && !store.ticketPageLoading}
        draw()
        let text = AXProbe.text(host)
        XCTAssertTrue(text.contains("Project q")); XCTAssertTrue(text.contains("Showing 82 of 82 matching tickets")); XCTAssertTrue(text.contains("q cached ticket 0"))
        XCTAssertFalse(text.contains("p cached ticket 0"))
        XCTAssertNotNil(NativeRenderMetrics.finish()?.screens["project_switch"])
    }
    func testRealSizeProjectChoiceInstallsCachedRowsBeforeDismissAndKeepsControls() async throws {
        _ = NSApplication.shared
        let restoreAX = AXProbe.enableEnhancedUserInterface();defer {restoreAX()}
        let f = Fixture(isolatedDefaults("RealSizeProjectChoice").preferences)
        f.realSize = true
        f.preferences.set((0..<120).map {"triage-\($0)"},forKey:"expandedTriages")
        let store = f.store(), live = Task {await store.startLiveUpdates()}
        let host = NSHostingView(rootView:Host(store:store,tabsOnly:false))
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:1100,height:850),styleMask:[],backing:.buffered,defer:false)
        window.title = "Synthetic real-size project picker (offscreen)";window.isReleasedWhenClosed = false;window.contentView = host;window.orderFront(nil)
        var dismissed = false
        let choices = NSHostingView(rootView:ProjectPickerChoices(dismiss: {
            XCTAssertEqual(store.projectID,"q","Selection must begin before the picker dismisses")
            XCTAssertEqual(store.preparedTicketWorkspace?.visibleTicketIDs.count,82)
            dismissed = true
        }).environmentObject(store))
        let choiceWindow = NSWindow(contentRect:NSRect(x:-12000,y:-10000,width:300,height:500),styleMask:[],backing:.buffered,defer:false)
        choiceWindow.title = "Synthetic project choices (offscreen)";choiceWindow.isReleasedWhenClosed = false;choiceWindow.contentView = choices;choiceWindow.orderFront(nil)
        defer {NativeRenderMetrics.cancel();live.cancel();store.stopWindowReads();f.cleanup();window.contentView = nil;window.close();choiceWindow.contentView = nil;choiceWindow.close()}
        func draw() {host.layoutSubtreeIfNeeded();host.displayIfNeeded();window.displayIfNeeded();choices.layoutSubtreeIfNeeded();choices.displayIfNeeded()}
        try await until {store.ticketPageMatchedCount == 286 && !store.ticketPageLoading};draw()
        XCTAssertEqual(store.ticketPageMatchedCount,286)
        XCTAssertEqual(store.ticketPageShownCount,200)
        XCTAssertEqual(store.preparedTicketWorkspace?.list.triages.count,120)
        store.select(.tasks,project:"q");try await until {store.ticketPageMatchedCount == 82 && !store.ticketPageLoading};draw()
        store.select(.tasks,project:"p");try await until {store.ticketPageMatchedCount == 286 && !store.ticketPageLoading};draw()
        await Task.yield();draw()
        let control = try XCTUnwrap(AXProbe.nodes(host).first {AXProbe.attribute($0,"accessibilityIdentifier") as? String == "newTriage"})
        let choice = try XCTUnwrap(AXProbe.nodes(choices).first {AXProbe.attribute($0,"accessibilityIdentifier") as? String == "projectChoice-q"})
        f.hold = true
        let calls = f.calls
        AXProbe.press(choice)
        XCTAssertTrue(dismissed,"A project choice is a direct button action, without NSMenu tracking")
        XCTAssertEqual(f.calls,calls,"Cached selection performs no synchronous service read")
        draw()
        let current = try XCTUnwrap(AXProbe.nodes(host).first {AXProbe.attribute($0,"accessibilityIdentifier") as? String == "newTriage"})
        XCTAssertTrue(control === current,"Project navigation must retain the native controls")
        let text = AXProbe.text(host)
        XCTAssertTrue(text.contains("Showing 82 of 82 matching tickets"))
        XCTAssertTrue(text.contains("q cached ticket 0"))
        XCTAssertFalse(text.contains("p cached ticket 0"),"The retained controls must not retain the preceding ticket tree")
        try await until {!f.pending.isEmpty}
        XCTAssertFalse(f.pending.isEmpty,"Destination content precedes the held background reads")
    }
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
