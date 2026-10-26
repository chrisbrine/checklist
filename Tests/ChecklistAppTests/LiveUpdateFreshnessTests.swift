import XCTest
import SwiftUI
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
        var revision = 1
        var title = "Fixture"
        var calls: [String] = []
        var pageReads: [String] = []
        var failNext = false, ignoreNext = false, holdList = false, holdContext = false
        var failMethod = "task_list"
        var held: [(String, CheckedContinuation<[String:Any],Error>, [String:Any])] = []
        var wait: CheckedContinuation<[String:Any],Error>?
        var extraWaits: [CheckedContinuation<[String:Any],Error>] = []
        var queuedChanges: [[String:Any]] = []
        var cursors: [String?] = []
        var replayChanges = false
        var contextVersion: String?
        var holdSurface = "needs_review"
        var heldSurfaces: Set<String> = []
        var inTriage = false
        var statusCoverage = false
        var service: [String:Any] { ["store_incarnation":"fixture", "read_version":version] }
        func task(_ id:String = "a", project:String = "p") -> [String:Any] {
            ["id":id,"project_id":project,"title":title, "revision":revision,"status_name":status,"status_category":status == "Review" ? "review" : "active","status_id":status]
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
                if !queuedChanges.isEmpty {return queuedChanges.removeFirst()}
                if let wait {extraWaits.append(wait);self.wait = nil}
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
            if method == "workspace_page" && heldSurfaces.contains(params["surface"] as? String ?? "") || holdList && (method == "task_list" || method == "workspace_page" && (page != .overview || (holdSurface == "all" || ["overview",holdSurface].contains(params["surface"] as? String ?? "")))) || method == "task_context" && holdContext {
                return try await withCheckedThrowingContinuation { held.append((method,$0,reply)) }
            }
            return reply
        }
        func changes() -> [String:Any] {
            var result: [String:Any] = ["changed":true,"event_cursor":"c1","coverage":["schema_version":2,"complete":true,"reset":false,"changes":[["project_id":"p","families":["tasks","work","groups"],"task_ids":["a"],"all_tasks":false]]]]
            if statusCoverage {
                var coverage = result["coverage"] as! [String:Any]
                coverage["store_incarnation"] = "fixture"
                coverage["status_updates"] = [["task":task(),"surfaces":status == "Review" ? ["needs_review"] : ["needs_pickup"]]]
                result["coverage"] = coverage
            }
            return result
        }
        func commit() { status = "Review";version = "v2";revision = 2;title = "Updated fixture" }
        func release(_ method:String) { guard let i = held.firstIndex(where: {$0.0 == method}) else {return};let row = held.remove(at:i);row.1.resume(returning: fixtureReply(row.2)) }
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
            for wait in extraWaits {wait.resume(throwing:CancellationError())};extraWaits = []
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

    func testTicketsCommittedStatusOverlaysOrdinaryAndTriageMemberBeforeHeldReads() async throws {
        for grouped in [false,true] {
            let f = Fixture(isolatedDefaults("TicketsCommittedStatus").preferences)
            f.inTriage = grouped
            let store = f.store(), live = Task {await store.startLiveUpdates()}
            defer {live.cancel();store.stopWindowReads();f.cleanup()}
            try await until {f.wait != nil}
            store.open(.task("a"));try await until {store.selectedTicketCurrent("a")}
            var now: TimeInterval = 1802.7;store.liveNow = {now}
            f.commit();f.statusCoverage = true;f.holdList = true;f.holdContext = true
            let apply = Task {await store.applyChangeCoverage(f.changes())};defer {apply.cancel()}
            try await until {f.held.count == 2}
            XCTAssertEqual(shownStatus(store,page:.tasks),"Review")
            XCTAssertEqual(store.selectedTask("a")?.string("status_name"),"Review")
            XCTAssertEqual(cursor(store),"c0")
            XCTAssertFalse(store.selectedTicketCurrent("a"))
            XCTAssertEqual(store.preparedTicketWorkspace?.list.triages.count,grouped ? 1 : 0)
            now += 0.25
            f.holdList = false;f.holdContext = false
            while !f.held.isEmpty {f.release(f.held[0].0)}
            let accepted = await apply.value;XCTAssertTrue(accepted)
            XCTAssertEqual(store.preparedTicketWorkspace?.rows.compactMap {row -> Record? in
                switch row.content {case .ticket(let t),.triageMember(let t):return t;default:return nil}
            }.first?.string("title"),"Updated fixture")
            XCTAssertTrue(store.selectedTicketCurrent("a"));XCTAssertEqual(cursor(store),"c1")
        }
    }

    func testNewerTicketsPageDoesNotSuppressCoverageForOlderSelectedDetail() async throws {
        for grouped in [false,true] {
            let f = Fixture(isolatedDefaults("TicketsStatusAfterPage").preferences)
            f.inTriage = grouped
            let store = f.store(), live = Task {await store.startLiveUpdates()}
            defer {live.cancel();store.stopWindowReads();f.cleanup()}
            try await until {f.wait != nil}
            store.open(.task("a"));try await until {store.selectedTicketCurrent("a")}
            f.holdContext = true
            f.commit()
            store.retryTicketPage()
            try await until {self.shownStatus(store,page:.tasks) == "Review"}
            XCTAssertEqual(store.selectedTask("a")?.string("status_name"),"In progress")
            f.statusCoverage = true;f.holdList = true;f.holdContext = true
            let apply = Task {await store.applyChangeCoverage(f.changes())};defer {apply.cancel()}
            try await until {f.held.contains {$0.0 == "task_list"} && f.held.contains {$0.0 == "task_context"}}
            XCTAssertEqual(shownStatus(store,page:.tasks),"Review")
            XCTAssertEqual(store.selectedTask("a")?.string("status_name"),"Review",
                           "A list at the coverage revision must not suppress the same committed status for an older detail")
            XCTAssertFalse(store.selectedTicketCurrent("a"))
            XCTAssertEqual(cursor(store),"c0")
            f.holdList = false;f.holdContext = false
            while !f.held.isEmpty {f.release(f.held[0].0)}
            let accepted = await apply.value;XCTAssertTrue(accepted)
            XCTAssertTrue(store.selectedTicketCurrent("a"));XCTAssertEqual(cursor(store),"c1")
        }
    }

    func testTicketsCommittedStatusReadAheadFencesEarlierPageWithoutAcknowledgingIt() async throws {
        let f = Fixture(isolatedDefaults("TicketsStatusReadAhead").preferences)
        f.inTriage = true
        let store = f.store(), live = Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads();f.cleanup()}
        try await until {f.wait != nil}
        var now: TimeInterval = 1802.7;store.liveNow = {now}
        f.holdList = true;f.statusCoverage = true
        let first = f.wait;f.wait = nil;first?.resume(returning: fixtureReply(f.changes()))
        try await until {f.held.count == 1}
        now += 0.25;f.commit();f.statusCoverage = true
        var changed = f.changes();changed["event_cursor"] = "c2"
        if let wait = f.wait {f.wait = nil;wait.resume(returning: fixtureReply(changed))} else {f.queuedChanges.append(changed)}
        try await until {self.shownStatus(store,page:.tasks) == "Review"}
        XCTAssertEqual(cursor(store),"c0");XCTAssertEqual(f.held.count,1)
        // Read-ahead observes but does not consume the primary subscription's
        // replay from its last applied cursor.
        f.queuedChanges.append(changed)
        f.holdList = false;f.release("task_list")
        try await until {self.cursor(store) == "c2"}
        XCTAssertEqual(shownStatus(store,page:.tasks),"Review")
    }

    func testTicketsTriageHeaderRequiresCompleteRevisionMatchedCoverage() async throws {
        for variant in ["complete","partial","wrong_group_revision","new_group_revision","mixed"] {
            let f = Fixture(isolatedDefaults("TriageStatusCoverage").preferences)
            f.inTriage = true
            let store = f.store(), live = Task {await store.startLiveUpdates()}
            defer {live.cancel();store.stopWindowReads();f.cleanup()}
            try await until {f.wait != nil}
            store.liveNow = {1802.7}
            f.commit();f.statusCoverage = true;f.holdList = true
            var changes = f.changes(), coverage = changes["coverage"] as! [String:Any]
            let membership: [String:Any] = ["id":"triage","revision":variant == "wrong_group_revision" ? 0 : variant == "new_group_revision" ? 2 : 1,"member_count":2]
            var b = f.task("b")
            if variant == "mixed" {b["status_id"] = "Queued";b["status_name"] = "Queued";b["status_category"] = "queued"}
            var updates = [["task":f.task(),"surfaces":["needs_review"],"triages":[membership]]] as [[String:Any]]
            if variant != "partial" {updates.append(["task":b,"surfaces":[],"triages":[membership]])}
            coverage["status_updates"] = updates;changes["coverage"] = coverage
            let apply = Task {await store.applyChangeCoverage(changes)};defer {apply.cancel()}
            try await until {f.held.count == 1}
            XCTAssertEqual(shownStatus(store,page:.tasks),"Review")
            let summary = store.preparedTicketWorkspace?.list.triages.first
            XCTAssertEqual(summary?.triage.string("status_name"),["complete","new_group_revision"].contains(variant) ? "Review" : variant == "mixed" ? "Mixed" : "In progress")
            XCTAssertEqual(summary?.visibleMembers.map(\.id),["a"],"Unloaded members never become page rows")
            XCTAssertEqual(summary?.triage.bool("members_complete"),false)
            XCTAssertEqual(cursor(store),"c0")
            f.holdList = false;f.release("task_list");_ = await apply.value
        }
    }

    func testTicketsStatusOverlayKeepsStoreProjectAndRevisionFences() async throws {
        for variant in ["store","project","older","equal"] {
            let f = Fixture(isolatedDefaults("TicketsStatusFences").preferences)
            f.revision = 3;f.inTriage = true
            let store = f.store(), live = Task {await store.startLiveUpdates()}
            defer {live.cancel();store.stopWindowReads();f.cleanup()}
            try await until {f.wait != nil}
            store.liveNow = {1802.7}
            f.statusCoverage = true;f.holdList = true
            f.status = "Review";f.version = "v2";f.revision = variant == "older" ? 2 : variant == "equal" ? 3 : 4
            var changes = f.changes(), coverage = changes["coverage"] as! [String:Any]
            if variant == "store" {coverage["store_incarnation"] = "foreign"}
            if variant == "project" {coverage["status_updates"] = [["task":f.task(project:"foreign"),"surfaces":[]]]}
            changes["coverage"] = coverage
            let apply = Task {await store.applyChangeCoverage(changes)};defer {apply.cancel()}
            try await until {f.held.count == 1}
            XCTAssertEqual(shownStatus(store,page:.tasks),"In progress")
            f.holdList = false;f.release("task_list");_ = await apply.value
        }
    }

    func testTicketsNoteCoverageRetainsMountedFiltersWhilePageWaits() async throws {
        _ = NSApplication.shared
        let f = Fixture(isolatedDefaults("TicketsFilterMount").preferences)
        let store = f.store(), live = Task {await store.startLiveUpdates()}
        let host = NSHostingView(rootView:TaskWorkspaceView().environmentObject(store).frame(width:1100,height:850))
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:1100,height:850),styleMask:[],backing:.buffered,defer:false)
        window.title = "Synthetic Tickets coverage host (offscreen)";window.isReleasedWhenClosed = false
        window.contentView = host;window.orderFront(nil)
        defer {live.cancel();store.stopWindowReads();window.contentView = nil;window.close();f.cleanup()}
        func draw() {host.layoutSubtreeIfNeeded();host.displayIfNeeded();window.displayIfNeeded()}
        try await until {draw();return f.wait != nil && f.pageReads.contains("worker_sessions")}
        let lists = f.calls.filter {$0 == "task_list"}.count
        store.search = "Fixture";try await until {f.calls.filter {$0 == "task_list"}.count > lists && !store.ticketPageLoading}
        draw();let reads = f.pageReads.filter {$0 == "worker_sessions"}.count
        store.liveNow = {1802.7};f.holdList = true
        var changes = f.changes();changes["coverage"] = ["schema_version":2,"complete":true,"reset":false,
            "changes":[["project_id":"p","families":["messages"],"task_ids":["b"],"all_tasks":false]]]
        let apply = Task {await store.applyChangeCoverage(changes)};defer {apply.cancel()}
        try await until {f.held.contains {$0.0 == "task_list"}}
        draw();XCTAssertNotNil(store.preparedTicketWorkspace,"Complete coverage must keep the mounted content and controls")
        try await Task.sleep(nanoseconds:20_000_000);draw()
        f.holdList = false;while !f.held.isEmpty {f.release(f.held[0].0)};_ = await apply.value
        draw();try await Task.sleep(nanoseconds:20_000_000);draw()
        XCTAssertEqual(f.pageReads.filter {$0 == "worker_sessions"}.count,reads,"A note refresh must not remount the controls' worker-session read")
    }

    func testLiveStatusCoverageArrivesWhileEarlierPagesStayHeld() async throws {
        let f = Fixture(isolatedDefaults("StatusReadAhead").preferences,page:.overview)
        let store = f.store(),live = Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads();f.cleanup()}
        try await until {f.wait != nil}
        store.open(.task("a"));try await until {store.selectedTicketCurrent("a")}
        var now: TimeInterval = 1802.7;store.liveNow = {now}
        f.statusCoverage = true;f.holdList = true;f.holdSurface = "all";f.holdContext = true
        // A work update starts a slow full read, before the status commits.
        var earlier = f.changes(),coverage = earlier["coverage"] as! [String:Any]
        coverage["changes"] = [["project_id":"p","families":["work"],"task_ids":["a"],"all_tasks":false]]
        earlier["coverage"] = coverage
        let firstWait = f.wait;f.wait = nil;firstWait?.resume(returning: fixtureReply(earlier))
        try await until {f.held.count >= 4}
        now += 0.25;f.commit()
        var statusChange = f.changes();statusChange["event_cursor"] = "c2"
        if let wait = f.wait {f.wait = nil;wait.resume(returning: fixtureReply(statusChange))}
        else {f.queuedChanges.append(statusChange)}
        try await until {store.selectedTask("a")?.string("status_name") == "Review" && self.shownStatus(store,page:.overview) == "Review" && f.held.count == 5}
        XCTAssertEqual(f.held.count,5,"Read-ahead replaces the canceled context without releasing any held reply")
        XCTAssertEqual(cursor(store),"c0","Read-ahead is not acknowledgment of either unfinished interval")
        XCTAssertFalse(store.selectedTicketCurrent("a"))
        XCTAssertEqual(f.pageReads.filter {$0 == "overview"}.count,1)
    }

    func testReadAheadReplacesCanceledSelectedContextBeforeWatchdog() async throws {
        let f = Fixture(isolatedDefaults("ReadAheadSelectedRecovery").preferences,page:.overview)
        let store = f.store(),live = Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads();f.cleanup()}
        try await until {f.wait != nil}
        store.open(.task("a"));try await until {store.selectedTicketCurrent("a")}
        f.statusCoverage = true;f.holdList = true;f.holdSurface = "all";f.holdContext = true
        var earlier = f.changes(),coverage = earlier["coverage"] as! [String:Any]
        coverage["changes"] = [["project_id":"p","families":["work"],"task_ids":["a"],"all_tasks":false]]
        earlier["coverage"] = coverage
        let wait = f.wait;f.wait = nil;wait?.resume(returning: fixtureReply(earlier))
        try await until {f.held.count >= 4}
        f.commit();f.holdContext = false
        var newer = f.changes();newer["event_cursor"] = "c2"
        if let wait = f.wait {f.wait = nil;wait.resume(returning: fixtureReply(newer))} else {f.queuedChanges.append(newer)}
        try await until {store.selectedTicketCurrent("a") && store.selectedTask("a")?.string("status_name") == "Review"}
        XCTAssertEqual(f.held.count,4,"The old context and all three old pages remain held")
        XCTAssertEqual(cursor(store),"c0","Fresh selected context alone does not acknowledge page coverage")
        XCTAssertEqual(f.calls.filter {$0 == "task_context"}.count,3,"Initial context, canceled context, immediate replacement")
        f.release("task_context")
        await Task.yield()
        XCTAssertEqual(store.selectedTask("a")?.string("status_name"),"Review")
    }

    func testCommittedStatusDisplaysBeforeHeldPagesAndContextAfterIdle() async throws {
        let f = Fixture(isolatedDefaults("CoverageStatusIdle").preferences,page:.overview)
        let store = f.store(), live = Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads();f.cleanup()}
        try await until {f.wait != nil}
        store.open(.task("a"));try await until {store.selectedTicketCurrent("a")}
        var now: TimeInterval = 1802.7;store.liveNow = {now}
        f.commit();f.statusCoverage = true;f.holdList = true;f.holdSurface = "all";f.holdContext = true
        let apply = Task {await store.applyChangeCoverage(f.changes())};defer {apply.cancel()}
        try await until {f.held.count >= 4}
        // No elapsed-time assertion: coverage must publish synchronously before
        // any deliberately stalled transport or watchdog clock can complete.
        XCTAssertEqual(shownStatus(store,page:.overview),"Review")
        XCTAssertEqual(store.selectedTask("a")?.string("status_name"),"Review")
        XCTAssertFalse(store.overviewObservations["needs_active"]!.rows.contains {$0.id == "a"})
        XCTAssertEqual(store.selectedTask("a")?.string("title"),"Fixture","Only status fields are patched")
        XCTAssertEqual(cursor(store),"c0","The status patch does not cover unfinished page reads")
        now += 0.25
        XCTAssertEqual(f.pageReads.filter {$0 == "overview"}.count,1)
        f.holdList = false;f.holdContext = false
        while !f.held.isEmpty {f.release(f.held[0].0)}
        let accepted = await apply.value;XCTAssertTrue(accepted)
        XCTAssertEqual(cursor(store),"c1")
        XCTAssertEqual(store.selectedTask("a")?.string("title"),"Updated fixture","Full context replaces the status patch")
    }

    func testCoverageStatusCannotReplaceNewerDisplayedTicket() async throws {
        let f = Fixture(isolatedDefaults("CoverageStatusRevision").preferences,page:.overview)
        f.version = "v3";f.status = "Queued";f.revision = 3
        let store = f.store(),live = Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads();f.cleanup()}
        try await until {f.wait != nil}
        store.open(.task("a"));try await until {store.selectedTicketCurrent("a")}
        f.statusCoverage = true;f.version = "v2";f.status = "Review";f.revision = 2
        f.holdList = true;f.holdSurface = "all";f.holdContext = true
        let apply = Task {await store.applyChangeCoverage(f.changes())};defer {apply.cancel()}
        try await until {f.held.count >= 4}
        XCTAssertEqual(store.selectedTask("a")?.string("status_name"),"Queued")
        XCTAssertEqual(shownStatus(store,page:.overview),"Queued")
        f.holdList = false;f.holdContext = false;f.version = "v3";f.status = "Queued";f.revision = 3
        // Stale in-flight replies must be rejected, then the ordinary retry can
        // obtain a complete newer page/context.
        while !f.held.isEmpty {f.release(f.held[0].0)}
        _ = await apply.value
        XCTAssertEqual(store.selectedTask("a")?.string("status_name"),"Queued")
        XCTAssertEqual(shownStatus(store,page:.overview),"Queued")
    }

    func testNewCommittedStatusFencesEarlierHeldStatusReplies() async throws {
        let f = Fixture(isolatedDefaults("CoverageStatusSupersession").preferences,page:.overview)
        let store = f.store(),live = Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads();f.cleanup()}
        try await until {f.wait != nil}
        store.open(.task("a"));try await until {store.selectedTicketCurrent("a")}
        var now: TimeInterval = 1802.7;store.liveNow = {now}
        f.commit();f.statusCoverage = true;f.holdList = true;f.holdSurface = "all";f.holdContext = true
        let old = Task {await store.applyChangeCoverage(f.changes())};defer {old.cancel()}
        try await until {f.held.count >= 4}
        XCTAssertEqual(shownStatus(store,page:.overview),"Review")
        XCTAssertFalse(store.selectedTicketCurrent("a"),"A status patch is not a complete current context")
        now += 0.25;f.revision = 3;f.version = "v3";f.status = "Queued"
        f.holdList = false;f.holdContext = false
        var newer = f.changes();newer["event_cursor"] = "c2"
        let accepted = await store.applyChangeCoverage(newer);XCTAssertTrue(accepted)
        XCTAssertEqual(store.selectedTask("a")?.string("status_name"),"Queued")
        XCTAssertEqual(shownStatus(store,page:.overview),"Queued")
        while !f.held.isEmpty {f.release(f.held[0].0)}
        _ = await old.value
        XCTAssertEqual(store.selectedTask("a")?.string("status_name"),"Queued")
        XCTAssertEqual(shownStatus(store,page:.overview),"Queued")
        XCTAssertEqual(cursor(store),"c2")
        XCTAssertEqual(f.pageReads.filter {$0 == "overview"}.count,1)
    }

    func testMessageOnlyCoverageDoesNotFanOutOverviewReads() async throws {
        let f = Fixture(isolatedDefaults("OverviewNoteCoverage").preferences,page:.overview)
        let store = f.store(),live = Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads();f.cleanup()}
        try await until {f.wait != nil}
        let before = f.pageReads
        var changes = f.changes()
        changes["coverage"] = ["schema_version":2,"complete":true,"reset":false,
            "changes":[["project_id":"p","families":["messages"],"task_ids":["b"],"all_tasks":false]]]
        let accepted = await store.applyChangeCoverage(changes)
        XCTAssertTrue(accepted)
        XCTAssertEqual(f.pageReads,before,"Note writers cannot enqueue all ten Overview groups")
        XCTAssertEqual(cursor(store),"c1")
    }

    func testCoverageStatusRejectsWrongIncarnationAndProject() async throws {
        for foreignStore in [true,false] {
            let f = Fixture(isolatedDefaults("CoverageStatusScope").preferences,page:.overview)
            let store = f.store(),live = Task {await store.startLiveUpdates()}
            defer {live.cancel();store.stopWindowReads();f.cleanup()}
            try await until {f.wait != nil}
            store.open(.task("a"));try await until {store.selectedTicketCurrent("a")}
            f.commit();f.statusCoverage = true;f.holdList = true;f.holdSurface = "all";f.holdContext = true
            var changes = f.changes(),coverage = changes["coverage"] as! [String:Any]
            if foreignStore {coverage["store_incarnation"] = "other-store"}
            else {coverage["status_updates"] = [["task":f.task(project:"other-project"),"surfaces":["needs_review"]]]}
            changes["coverage"] = coverage
            let apply = Task {await store.applyChangeCoverage(changes)};defer {apply.cancel()}
            try await until {f.held.count >= 4}
            XCTAssertEqual(shownStatus(store,page:.overview),"In progress")
            XCTAssertEqual(store.selectedTask("a")?.string("status_name"),"In progress")
            f.holdList = false;f.holdContext = false
            while !f.held.isEmpty {f.release(f.held[0].0)}
            _ = await apply.value
        }
    }
    func testFailedReadRetriesWithoutAdvancingCursor() async throws {
        for (page,selected) in [(Page.tasks,false),(.overview,false),(.epics,false),(.tasks,true)] {
            let f = Fixture(isolatedDefaults("LiveFreshness").preferences,page:page),store = f.store(),live = Task {await store.startLiveUpdates()}
            defer {live.cancel();store.stopWindowReads();f.cleanup()}
            try await until {f.wait != nil}
            if selected {store.open(.task("a"));try await until {store.selectedTicketCurrent("a")}}
            f.commit();f.failMethod = selected ? "task_context" : page == .tasks ? "task_list" : "workspace_page"
            f.failNext = true;f.holdList = !selected;f.holdContext = selected
            f.replayChanges = true;f.wait?.resume(returning: fixtureReply(f.changes()));f.wait = nil
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
        f.holdList = false;f.release("task_list");_ = await apply.value
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

    func testCommittedDoneDestinationStartsBeforeHeldUnrelatedStatusPages() async throws {
        let f = Fixture(isolatedDefaults("LiveDoneDestination").preferences,page:.overview)
        let store = f.store(),live = Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads();f.cleanup()}
        try await until {f.wait != nil}
        f.commit();f.status = "Done";f.statusCoverage = true
        f.heldSurfaces = ["needs_review","needs_pickup","needs_active"]
        f.pageReads = []
        var changes = f.changes(),coverage = changes["coverage"] as! [String:Any]
        coverage["status_updates"] = [["task":f.task(),"surfaces":["needs_done_today"]]]
        changes["coverage"] = coverage
        let apply = Task {await store.applyChangeCoverage(changes)};defer {apply.cancel()}
        try await until {f.held.count == 3}
        XCTAssertEqual(f.pageReads.first,"needs_done_today")
        XCTAssertEqual(store.overviewObservations["needs_done_today"]?.rows.first?.string("status_name"),"Done")
        f.heldSurfaces = []
        while !f.held.isEmpty {f.release("workspace_page")}
        let accepted = await apply.value;XCTAssertTrue(accepted)
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

    func testFirstDetailReplacesEpochRetiredByAnotherTicketsSearchChange() async throws {
        let f = Fixture(isolatedDefaults("FirstDetailSearchCoverage").preferences)
        let store = f.store(), live = Task {await store.startLiveUpdates()}
        defer {live.cancel();store.stopWindowReads();f.cleanup()}
        try await until {f.wait != nil}
        store.search = "Fixture"
        try await until {!store.ticketPageLoading}
        f.holdContext = true;store.open(.task("a"))
        try await until {f.held.contains {$0.0 == "task_context"}}
        XCTAssertNil(store.selectedTask("a"),"This is the first visit, with no cached detail")
        f.version = "v2"
        let changes: [String:Any] = ["changed":true,"event_cursor":"c1","coverage":["schema_version":2,"complete":true,"reset":false,"changes":[["project_id":"p","families":["messages"],"task_ids":["b"],"all_tasks":false]]]]
        let accepted = await store.applyChangeCoverage(changes)
        XCTAssertTrue(accepted)
        // The old v1 reply is obsolete even though the selected task was not
        // touched. A fresh v2 read must replace it without a watchdog or another event.
        f.holdContext = false;f.release("task_context")
        try await until {store.selectedTicketCurrent("a")}
        XCTAssertEqual(store.selectedTask("a")?.string("title"),"Fixture")
        XCTAssertEqual(f.calls.filter {$0 == "task_context"}.count,2)
        XCTAssertNil(store.selectedTicketError)
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
        f.holdList = false;f.release("task_list");_ = await apply.value
        XCTAssertNil(store.selectedTask("a"));XCTAssertEqual(store.selectedTask("b")?.string("status_name"),"Review")
    }
}
@MainActor private final class FreshnessAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization {.denied}
    func requestAuthorizationFromOwnerAction() async throws -> Bool {false}
    func send(_ alert:DesktopAlert) async throws {XCTFail("No native alerts in mock tests")}
    func remove(_ identifiers:[String]) {}
}
