import XCTest
import ChecklistIPC
@testable import ChecklistApp

/// Transport templates only: no database, native connection, app or test slot.
@MainActor final class LiveUpdateFreshnessTests: XCTestCase {
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-freshness-" + UUID().uuidString)
        let preferences: UserDefaults
        let page: Page
        init(_ preferences:UserDefaults, page:Page = .tasks) {self.preferences = preferences;self.page = page}
        var status = "In progress", version = "v1"
        var calls: [String] = []
        var pageReads: [String] = []
        var failNext = false, ignoreNext = false, holdList = false, holdContext = false
        var failMethod = "task_list"
        var held: [(String, CheckedContinuation<[String:Any],Error>, [String:Any])] = []
        var wait: CheckedContinuation<[String:Any],Error>?
        var cursors: [String?] = []
        var replayChanges = false
        var contextVersion: String?
        var holdSurface = "needs_review"
        var inTriage = false
        var service: [String:Any] { ["store_incarnation":"fixture", "read_version":version] }
        func task(_ id:String = "a", project:String = "p") -> [String:Any] {
            ["id":id,"project_id":project,"title":"Fixture", "revision":version == "v1" ? 1 : 2,"status_name":status,"status_category":status == "Review" ? "review" : "active","status_id":status]
        }
        func context(_ id:String) -> [String:Any] {
            let collections = Dictionary(uniqueKeysWithValues:["messages","attachments","attempts","requests","events","sessions","groups","statuses","tags"].map {($0, [[String:Any]]())})
            return ["ui_version":1,"context_cursor":"context-\(id)-\(version)","task":task(id),"project":["id":"p"],"service":service,"collections":collections,
                    "counts":["messages":0,"attachments":0,"attempts":0,"requests":0],"full_record_loaded":false,"next_history_cursor":NSNull(),"previous_history_cursor":NSNull(),"has_more_messages":false]
        }
        func list(_ project:String = "p") -> [String:Any] {
            let triages: [[String:Any]] = inTriage ? [["id":"triage","project_id":project,"revision":1,"name":"Fixture triage","purpose":"Status timing","kind":"triage","phase":"implementation","archived":false,"active_attention":false,"status_state":"uniform","status_id":status,"status_name":status,"status_category":status == "Review" ? "review" : "active","member_count":2,"matching_count":1,"page_member_ids":["a"],"members_complete":false]] : []
            return ["schema_version":1,"event_cursor":"c0","tickets_page":["query_key":"query","content_cursor":"content","tasks":[task(project:project)],"ordinary_ids":inTriage ? [] : ["a"],"triages":triages,"projects":[["id":"p"]],"statuses":[],"tags":[],"epics":[],"scoped_count":1,"matched_count":1,"has_more":false,"next_cursor":NSNull(),"previous_cursor":NSNull(),"outstanding_request_count":0,"human_task_count":0,"overview_requests":[],"overview_request_count":0,"service":service]]
        }
        func workspace(_ params:[String:Any], invalid:Bool = false) -> [String:Any] {
            let surface = params["surface"] as! String
            if surface == "overview" {
                let surfaces = ChecklistStore.overviewGroups.map(\.surface) + ["human_tasks","recent_reviews","completed_since"]
                return ["groups":Dictionary(uniqueKeysWithValues:surfaces.map { name in
                    var p = params;p["surface"] = name
                    return (name,workspace(p,invalid:invalid && name == "needs_review"))
                }),"service":service,"event_cursor":"c0"]
            }
            return ["workspace_version":1,"surface":surface,"record_id":invalid ? "invalid" : "","rows":[task()],"total":1,"needs_you_count":0,"has_more":false,"next_cursor":NSNull(),"previous_cursor":NSNull(),"projects":[["id":"p"]],"service":service,"content_cursor":"c0"]
        }
        func transport(_ method:String,_ params:[String:Any]) async throws -> [String:Any] {
            if method == "changes_wait" {
                cursors.append(params["cursor"] as? String)
                if replayChanges, params["cursor"] as? String != "c1" {return changes()}
                return try await withCheckedThrowingContinuation { wait = $0 }
            }
            calls.append(method)
            if method == "workspace_page" {pageReads.append(params["surface"] as? String ?? "")}
            if method == "task_get" { return task(params["task_id"] as? String ?? "a") }
            if failNext, method == failMethod {failNext = false;throw ChecklistError("FIXTURE_FAILURE","Expected mock failure")}
            let reply: [String:Any]
            if method == "task_context" {
                let saved = version;version = contextVersion ?? version
                reply = context(params["task_id"] as! String);version = saved
            }
            else {
                let ignored = ignoreNext; ignoreNext = false
                if method == "workspace_page" { reply = workspace(params,invalid:ignored) }
                else { XCTAssertEqual(method,"task_list");reply = list(ignored ? "foreign" : "p") }
            }
            if holdList && (method == "task_list" || method == "workspace_page" && (page != .overview || ["overview",holdSurface].contains(params["surface"] as? String ?? ""))) || method == "task_context" && holdContext {
                return try await withCheckedThrowingContinuation { held.append((method,$0,reply)) }
            }
            return reply
        }
        func changes() -> [String:Any] { ["changed":true,"event_cursor":"c1","coverage":["schema_version":2,"complete":true,"reset":false,"changes":[["project_id":"p","families":["tasks","work","groups"],"task_ids":["a"],"all_tasks":false]]]] }
        func commit() { status = "Review";version = "v2" }
        func release(_ method:String) { guard let i = held.firstIndex(where: {$0.0 == method}) else {return};let row = held.remove(at:i);row.1.resume(returning:row.2) }
        func store() -> ChecklistStore {
            preferences.set(page.rawValue,forKey:"lastPage");preferences.set("p",forKey:"lastProject")
            let store = ChecklistStore(draftJournal:LocalDraftJournal(directory:root),preferences:preferences,restorePendingCommand:false,
                desktopAlerts:DesktopAlertCoordinator(sink:FreshnessAlertSink()),requestTransport:{ [self] in try await transport($0,$1) },navigationMemory:DetailItemNavigationMemory())
            if inTriage {store.updateTicketWorkspaceExpansion(.init(expandedIDValues:["triage"]))}
            store.liveWaitPause = 5_000_000;store.liveRetryPause = 100_000_000
            return store
        }
        func cleanup() {
            wait?.resume(throwing:CancellationError());wait = nil
            for row in held {row.1.resume(throwing:CancellationError())};held = []
            if FileManager.default.fileExists(atPath:root.path) { try? FileManager.default.removeItem(at:root) }
        }
    }
    private func until(_ predicate:()->Bool, seconds:Double = 1, file:StaticString = #filePath,line:UInt = #line) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end { if predicate() {return};try await Task.sleep(nanoseconds:5_000_000) }
        XCTFail("Mock live update did not settle",file:file,line:line);throw CancellationError()
    }
    private func cursor(_ store:ChecklistStore) -> String? { Mirror(reflecting:store).children.first {$0.label == "eventCursor"}?.value as? String }
    private func shownStatus(_ store:ChecklistStore, page:Page) -> String? {
        if page == .tasks {
            return store.preparedTicketWorkspace?.rows.compactMap { row -> Record? in
                switch row.content {case .ticket(let task),.triageMember(let task):return task;default:return nil}
            }.first?.string("status_name")
        }
        if page == .overview {return store.overviewObservations["needs_review"]?.rows.first?.string("status_name")}
        return store.workspaceRows.first?.string("status_name")
    }
    func testFailedReadRetriesWithoutAdvancingCursor() async throws {
        for (page,selected) in [(Page.tasks,false),(.overview,false),(.epics,false),(.tasks,true)] {
            let f = Fixture(isolatedDefaults("LiveFreshness").preferences,page:page),store = f.store(),live = Task {await store.startLiveUpdates()}
            defer {live.cancel();store.stopWindowReads();f.cleanup()}
            try await until {f.wait != nil}
            if selected {store.open(.task("a"));try await until {store.selectedTicketCurrent("a")}}
            f.commit();f.failMethod = selected ? "task_context" : page == .tasks ? "task_list" : "workspace_page"
            f.failNext = true;f.holdList = !selected;f.holdContext = selected
            f.replayChanges = true;f.wait?.resume(returning:f.changes());f.wait = nil
            try await until {selected ? store.selectedTicketError != nil : page == .tasks ? store.ticketPageError != nil : page == .overview ? store.overviewObservations["needs_review"]?.error != nil : store.workspaceError != nil}
            XCTAssertEqual(cursor(store),"c0","Failure must not cover the interval")
            try await until {f.held.contains {$0.0 == f.failMethod}}
            XCTAssertEqual(cursor(store),"c0")
            f.holdList = false;f.holdContext = false;f.release(f.failMethod)
            try await until {self.shownStatus(store,page:page) == "Review" && self.cursor(store) == "c1"}
            if selected {XCTAssertEqual(store.selectedTask("a")?.string("status_name"),"Review")}
        }
    }
    func testUninstalledReplyIsRecoveredByWatchdogWithinTwoSeconds() async throws {
        for page in [Page.tasks,.overview,.epics] {
            let f = Fixture(isolatedDefaults("LiveFreshness").preferences,page:page),store = f.store(),live = Task {await store.startLiveUpdates()}
            defer {live.cancel();store.stopWindowReads();f.cleanup()}
            try await until {f.wait != nil};f.commit();f.ignoreNext = true
            // Thirty idle minutes and the watchdog deadline are virtual time.
            // No new subscription response arrives; no wall-clock budget assertion.
            var now: TimeInterval = 1802.7
            store.liveNow = {now}
            let before = f.calls.count
            await store.applyChangeCoverage(f.changes())
            XCTAssertEqual(cursor(store),"c0")
            now += 1.5
            await store.checkLiveFreshness(selected:false)
            XCTAssertEqual(shownStatus(store,page:page),"Review")
            XCTAssertEqual(f.calls.count - before,page == .overview ? 11 : 2,"Recovery carries successful Overview groups")
        }
    }
    func testSelectedDetailInstallsBeforeHeldListAndDoesNotRestart() async throws {
        let f = Fixture(isolatedDefaults("LiveFreshness").preferences),store = f.store(),live = Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads();f.cleanup()}
        try await until {f.wait != nil};store.open(.task("a"));try await until {store.selectedTicketCurrent("a")}
        f.calls = [];f.commit();f.holdList = true
        let apply = Task {await store.applyChangeCoverage(f.changes())};defer {apply.cancel()}
        try await until {f.held.contains {$0.0 == "task_list"}}
        try await until {store.selectedTask("a")?.string("status_name") == "Review"}
        XCTAssertEqual(f.calls.filter {$0 == "task_context"}.count,1)
        f.holdList = false;f.release("task_list");await apply.value
        XCTAssertEqual(cursor(store),"c1");XCTAssertEqual(f.calls.filter {$0 == "task_context"}.count,1)
    }
    func testParallelSnapshotsDoNotDiscardStatusBehindNoteTraffic() async throws {
        for page in [Page.overview,.tasks] {
            let f = Fixture(isolatedDefaults("LiveSnapshotRace").preferences,page:page)
            f.inTriage = page == .tasks
            let store = f.store(),live = Task {await store.startLiveUpdates()}
            defer {live.cancel();store.stopWindowReads();f.cleanup()}
            try await until {f.wait != nil}
            store.open(.task("a"));try await until {store.selectedTicketCurrent("a")}
            f.commit();f.contextVersion = "v3";f.holdList = true;f.calls = [];f.pageReads = []
            // Both reads begin after the status commit. An unrelated note commits
            // between their pinned snapshots: detail v3, slow list v2.
            let apply = Task {await store.applyChangeCoverage(f.changes())}
            defer {apply.cancel()}
            try await until {f.held.count == 1 && store.selectedTask("a")?.string("status_name") == "Review"}
            f.holdList = false;f.release(page == .tasks ? "task_list" : "workspace_page")
            let accepted = await apply.value
            XCTAssertTrue(accepted,"Concurrent post-change snapshots must cover the status interval")
            XCTAssertEqual(shownStatus(store,page:page),"Review","The first slow reply must install, without a second service round trip")
            XCTAssertEqual(f.calls.filter {$0 == "task_context"}.count,1,"A different note snapshot must not restart selected status")
            XCTAssertEqual(page == .tasks ? f.calls.filter {$0 == "task_list"}.count : f.pageReads.filter {["overview","needs_review"].contains($0)}.count,1)
        }
    }

    func testIdleWatchdogReplacesHeldReadWithoutWaitingForItsReply() async throws {
        for (page,selected) in [(Page.overview,false),(.tasks,false),(.overview,true)] {
            let f = Fixture(isolatedDefaults("IdleWatchdog").preferences,page:page)
            f.inTriage = page == .tasks
            let store = f.store(),live = Task {await store.startLiveUpdates()}
            defer {live.cancel();store.stopWindowReads();f.cleanup()}
            try await until {f.wait != nil}
            store.open(.task("a"));try await until {store.selectedTicketCurrent("a")}
            var now: TimeInterval = 1802.7;store.liveNow = {now}
            f.commit();f.holdList = !selected;f.holdContext = selected
            let apply = Task {await store.applyChangeCoverage(f.changes())};defer {apply.cancel()}
            try await until {f.held.count == 1}
            // The stalled transport deliberately ignores cancellation. Recovery
            // must install while its original reply is still withheld.
            now += 1.5;f.holdList = false;f.holdContext = false
            await store.checkLiveFreshness(selected:selected)
            XCTAssertEqual(f.held.count,1)
            if page == .overview, !selected {
                XCTAssertEqual(f.pageReads.filter { $0 == "overview" }.count,1,"An independent-lane watchdog must not issue a combined read")
                XCTAssertEqual(f.pageReads.filter { $0 == "needs_review" }.count,2,"Only the held group needs replacement")
                for surface in Set(f.pageReads).subtracting(["overview","needs_review"]) {
                    XCTAssertEqual(f.pageReads.filter { $0 == surface }.count,1,"Accepted sibling groups carry into recovery")
                }
            }
            if selected {XCTAssertEqual(store.selectedTask("a")?.string("status_name"),"Review")}
            else {XCTAssertEqual(shownStatus(store,page:page),"Review")}
            f.release(selected ? "task_context" : page == .tasks ? "task_list" : "workspace_page")
            _ = await apply.value
            XCTAssertEqual(shownStatus(store,page:page),"Review")
            XCTAssertEqual(store.selectedTask("a")?.string("status_name"),"Review")
        }
    }

    func testLiveOverviewPublishesStatusWhileQuietGroupIsHeld() async throws {
        let f = Fixture(isolatedDefaults("LiveOverviewLanes").preferences,page:.overview)
        let store = f.store(),live = Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads();f.cleanup()}
        try await until {f.wait != nil}
        f.commit();f.holdList = true;f.holdSurface = "needs_quiet"
        let apply = Task {await store.applyChangeCoverage(f.changes())};defer {apply.cancel()}
        try await until {f.held.count == 1}
        XCTAssertEqual(shownStatus(store,page:.overview),"Review","Status is independent of a slow quiet/digest page")
        f.holdList = false;f.release("workspace_page")
        let accepted = await apply.value;XCTAssertTrue(accepted)
    }

    func testNewCoverageStillFencesHeldReplyFromEarlierStatus() async throws {
        for page in [Page.tasks,.overview] {
            let f = Fixture(isolatedDefaults("LiveCoverageFence").preferences,page:page)
            f.inTriage = page == .tasks
            let store = f.store(),live = Task {await store.startLiveUpdates()}
            defer {live.cancel();store.stopWindowReads();f.cleanup()}
            try await until {f.wait != nil}
            store.open(.task("a"));try await until {store.selectedTicketCurrent("a")}
            f.commit();f.holdList = true
            let old = Task {await store.applyChangeCoverage(f.changes())};defer {old.cancel()}
            try await until {f.held.count == 1}
            f.status = "Queued";f.version = "v3";f.holdList = false
            var newer = f.changes();newer["event_cursor"] = "c2"
            let accepted = await store.applyChangeCoverage(newer);XCTAssertTrue(accepted)
            f.release(page == .tasks ? "task_list" : "workspace_page")
            _ = await old.value
            XCTAssertEqual(shownStatus(store,page:page),"Queued")
            XCTAssertEqual(store.selectedTask("a")?.string("status_name"),"Queued")
            XCTAssertEqual(cursor(store),"c2","The earlier interval cannot cover a later commit")
        }
    }

    func testDelayedOlderReplyAndSelectionSwitchRemainFenced() async throws {
        let f = Fixture(isolatedDefaults("LiveFreshness").preferences),store = f.store(),live = Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads();f.cleanup()}
        try await until {f.wait != nil};store.open(.task("a"));try await until {store.selectedTicketCurrent("a")}
        f.holdList = true;store.retryTicketPage();try await until {f.held.contains {$0.0 == "task_list"}}
        f.holdContext = true;store.retrySelectedTicket();try await until {f.held.contains {$0.0 == "task_context"}}
        f.holdContext = false;f.commit()
        let apply = Task {await store.applyChangeCoverage(f.changes())};defer {apply.cancel()}
        try await until {store.selectedTask("a")?.string("status_name") == "Review"}
        store.open(.task("b"));try await until {store.selectedTicketCurrent("b")}
        f.release("task_context");f.release("task_list") // Delayed v1 replies arrive after v2 detail.
        await Task.yield()
        XCTAssertEqual(store.selectedTask("b")?.string("status_name"),"Review")
        XCTAssertNil(store.preparedTicketWorkspace,"The obsolete page cannot reinstall v1")
        f.holdList = false;f.release("task_list");await apply.value
        XCTAssertNil(store.selectedTask("a"));XCTAssertEqual(store.selectedTask("b")?.string("status_name"),"Review")
    }
}
@MainActor private final class FreshnessAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization {.denied}
    func requestAuthorizationFromOwnerAction() async throws -> Bool {false}
    func send(_ alert:DesktopAlert) async throws {XCTFail("No native alerts in mock tests")}
    func remove(_ identifiers:[String]) {}
}
