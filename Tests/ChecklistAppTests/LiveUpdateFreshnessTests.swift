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
        var failNext = false, ignoreNext = false, holdList = false, holdContext = false
        var failMethod = "task_list"
        var held: [(String, CheckedContinuation<[String:Any],Error>, [String:Any])] = []
        var wait: CheckedContinuation<[String:Any],Error>?
        var cursors: [String?] = []
        var replayChanges = false
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
            ["schema_version":1,"event_cursor":"c0","tickets_page":["query_key":"query","content_cursor":"content","tasks":[task(project:project)],"ordinary_ids":["a"],"triages":[],"projects":[["id":"p"]],"statuses":[],"tags":[],"epics":[],"scoped_count":1,"matched_count":1,"has_more":false,"next_cursor":NSNull(),"previous_cursor":NSNull(),"outstanding_request_count":0,"human_task_count":0,"overview_requests":[],"overview_request_count":0,"service":service]]
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
            if method == "task_get" { return task(params["task_id"] as? String ?? "a") }
            if failNext, method == failMethod {failNext = false;throw ChecklistError("FIXTURE_FAILURE","Expected mock failure")}
            let reply: [String:Any]
            if method == "task_context" { reply = context(params["task_id"] as! String) }
            else {
                let ignored = ignoreNext; ignoreNext = false
                if method == "workspace_page" { reply = workspace(params,invalid:ignored) }
                else { XCTAssertEqual(method,"task_list");reply = list(ignored ? "foreign" : "p") }
            }
            if (method == "task_list" || method == "workspace_page") && holdList || method == "task_context" && holdContext {
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
        if page == .tasks {return store.preparedTicketWorkspace?.list.ordinaryTickets.first?.string("status_name")}
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
            // No new subscription response arrives: recovery is independent of changes_wait.
            let start = ProcessInfo.processInfo.systemUptime
            let before = f.calls.count
            await store.applyChangeCoverage(f.changes())
            XCTAssertEqual(cursor(store),"c0")
            try await until({self.shownStatus(store,page:page) == "Review"},seconds:2)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            XCTAssertLessThan(elapsed,2)
            XCTAssertEqual(f.calls.count - before,2,"Recovery coalesces reads and carries successful Overview groups")
            print("FIX7 watchdog surface=\(page.rawValue) installed_ms=\(Int(elapsed * 1000))")
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
