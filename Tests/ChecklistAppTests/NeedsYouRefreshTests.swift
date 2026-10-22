import XCTest
import SwiftUI
import AppKit
import Observation
@testable import ChecklistApp

@MainActor final class NeedsYouRefreshTests: XCTestCase {
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("needs-refresh-" + UUID().uuidString)
        let preferences: UserDefaults
        var rows: [[String:Any]] = [Fixture.request("a"), Fixture.request("b"), Fixture.request("c")]
        var selected: [[String:Any]] = [Fixture.request("b")]
        var calls: [[String:Any]] = []
        var holdSurface: String?
        var failSurface: String?
        var held: CheckedContinuation<[String:Any],Error>?
        var heldReply: [String:Any] = [:]
        var waitStarted = false
        var pageSize: Int?
        init(_ preferences: UserDefaults) {
            self.preferences = preferences
            preferences.set(Page.needsYou.rawValue, forKey:"lastPage")
        }
        static func request(_ id: String, title: String? = nil) -> [String:Any] {
            ["id":id,"project_id":"p","record_type":"request","title":title ?? "Request \(id)",
             "state":"pending","revision":1,"form_revision":1,"questions":[["id":"q","prompt":"Your answer","type":"text"]]]
        }
        func response(_ params: [String:Any]) -> [String:Any] {
            let surface = params["surface"] as! String
            let all = surface == "record" ? selected : rows
            let offset = Int(params["cursor"] as? String ?? "") ?? 0
            let limit = surface == "record" ? all.count : pageSize ?? all.count
            let values = Array(all.dropFirst(offset).prefix(limit))
            let next = offset + values.count < all.count ? String(offset + values.count) : nil
            return ["workspace_version":1,"surface":surface,"record_id":params["record_id"] ?? "",
                    "rows":values,"total":all.count,"needs_you_count":rows.count,"has_more":next != nil,"next_cursor":next as Any? ?? NSNull(),"previous_cursor":offset > 0 ? String(max(0,offset - limit)) : NSNull(),
                    "projects":[["id":"p","name":"Synthetic project"]],"service":["store_incarnation":"synthetic"],"content_cursor":"content"]
        }
        func transport(_ method: String, _ params: [String:Any]) async throws -> [String:Any] {
            if method == "changes_wait" {
                waitStarted = true
                try await Task.sleep(nanoseconds:30_000_000_000)
                throw CancellationError()
            }
            guard method == "workspace_page" else { throw NSError(domain:"UnexpectedNeedsYouRead",code:1) }
            calls.append(params)
            let surface = params["surface"] as? String
            if failSurface == surface { failSurface = nil; throw NSError(domain:"SyntheticOffline",code:1) }
            if holdSurface == surface {
                holdSurface = nil; heldReply = response(params)
                return try await withCheckedThrowingContinuation { held = $0 }
            }
            return response(params)
        }
        func release() { let saved = held; held = nil; saved?.resume(returning:heldReply) }
        func store() -> ChecklistStore {
            ChecklistStore(draftJournal:LocalDraftJournal(directory:root),preferences:preferences,restorePendingCommand:false,
                           desktopAlerts:DesktopAlertCoordinator(sink:RefreshAlertSink()),
                           requestTransport:{ [self] in try await transport($0,$1) },navigationMemory:DetailItemNavigationMemory())
        }
        func clean() { release(); try? FileManager.default.removeItem(at:root) }
    }
    private func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        XCTFail("Bounded Needs You fixture did not settle",file:file,line:line)
        throw CancellationError()
    }
    private func coverage() -> [String:Any] {
        ["event_cursor":"next","coverage":["schema_version":2,"complete":true,"reset":false,
          "changes":[["project_id":"p","families":["requests"],"all_tasks":true]]]]
    }
    func testBackgroundRefreshKeepsRowsThenReconcilesChangedAddedAndRemovedIdentities() async throws {
        let f = Fixture(isolatedDefaults("NeedsRefreshDiff").preferences); defer { f.clean() }
        let store = f.store(); await store.refresh()
        let original = store.workspaceRows.map(\.workspaceIdentity)
        f.rows = [Fixture.request("a"), Fixture.request("b",title:"Changed"), Fixture.request("d")]
        f.holdSurface = "requests"
        let refresh = Task { await store.refresh(quiet:true) }
        try await until { f.held != nil }
        XCTAssertEqual(store.workspaceRows.map(\.workspaceIdentity),original)
        XCTAssertTrue(store.workspaceLoading); XCTAssertFalse(store.workspaceShowsLoading)
        XCTAssertTrue(store.workspacePageLoaded)
        f.release(); await refresh.value
        XCTAssertEqual(store.workspaceRows.map(\.id),["a","b","d"])
        XCTAssertEqual(store.workspaceRows[1].string("title"),"Changed")
        XCTAssertEqual(store.workspaceRows[1].workspaceIdentity,original[1])
        XCTAssertNil(store.workspaceError)
    }
    func testIdenticalRefreshDoesNotPublishRowsAndOpaqueIDsStayDistinct() throws {
        let f = Fixture(isolatedDefaults("NeedsRefreshIdentity").preferences); defer { f.clean() }
        let observation = WorkspacePageObservation(), query = WorkspacePageQuery(surface:"requests",project:nil)
        f.rows = [Fixture.request("é"),Fixture.request("e\u{301}")]
        let response = f.response(query.parameters())
        XCTAssertTrue(try observation.receive(response,query:query,generation:observation.begin(query)))
        let unchanged = expectation(description:"Identical rows are not published")
        unchanged.isInverted = true
        withObservationTracking({ _ = observation.rows },onChange:{ unchanged.fulfill() })
        XCTAssertTrue(try observation.receive(response,query:query,generation:observation.begin(query)))
        wait(for:[unchanged],timeout:0.01)
        XCTAssertNotEqual(observation.rows[0].workspaceIdentity,observation.rows[1].workspaceIdentity)
    }
    func testFailureKeepsLastGoodRowsAndFirstLoadStillHasLoadingAndEmptyStates() async throws {
        let f = Fixture(isolatedDefaults("NeedsRefreshFailure").preferences); defer { f.clean() }
        let store = f.store()
        f.holdSurface = "requests"
        let first = Task { await store.refresh() }
        try await until { f.held != nil }
        XCTAssertTrue(store.workspaceShowsLoading); XCTAssertFalse(store.workspacePageLoaded)
        f.release(); await first.value
        let ids = store.workspaceRows.map(\.id)
        f.failSurface = "requests"; await store.refresh(quiet:true)
        XCTAssertEqual(store.workspaceRows.map(\.id),ids)
        XCTAssertTrue(store.workspacePageLoaded); XCTAssertFalse(store.workspaceShowsLoading)
        XCTAssertNotNil(store.workspaceError)
        f.rows = []; await store.refresh()
        XCTAssertTrue(store.workspaceRows.isEmpty); XCTAssertTrue(store.workspacePageLoaded)
        XCTAssertFalse(store.workspaceShowsLoading); XCTAssertNil(store.workspaceError)
    }
    func testOpenRequestDraftAndNavigationSurviveLiveRefreshFailureAndRemoval() async throws {
        let f = Fixture(isolatedDefaults("NeedsRefreshRequest").preferences); defer { f.clean() }
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { f.waitStarted }
        store.open(.request("b"))
        try await until { store.requestDetail("b") != nil && !store.otherDetailLoading }
        var draft = AnswerDraft(revision:1); draft.values["q"] = "Unsent exact answer é"; draft.explanation = "Keep typing"
        store.saveAnswer("b",draft:draft)
        let generation = store.navigationMemory.navigationGeneration
        f.rows.removeAll { $0["id"] as? String == "b" }
        f.holdSurface = "record"
        await store.applyChangeCoverage(coverage())
        try await until { f.held != nil }
        XCTAssertTrue(store.otherDetailLoading); XCTAssertNotNil(store.requestDetail("b"))
        XCTAssertTrue(store.requestNoLongerListed("b")); XCTAssertEqual(store.detail,.request("b"))
        f.release(); try await until { !store.otherDetailLoading }
        f.failSurface = "record"; store.retryOtherDetail()
        try await until { store.otherDetailError != nil }
        XCTAssertNotNil(store.requestDetail("b")); XCTAssertEqual(store.answerDrafts["b"]?.values,draft.values)
        f.selected = []; store.retryOtherDetail()
        try await until { !store.otherDetailLoading && store.otherDetailMissing }
        XCTAssertEqual(store.requestDetail("b")?.id,"b","Keep the form and draft mounted with a removal notice")
        XCTAssertEqual(store.detail,.request("b")); XCTAssertEqual(store.navigationMemory.navigationGeneration,generation)
        XCTAssertEqual(store.needsCount,2,"A retained removed request cannot inflate the live count")
        XCTAssertEqual(store.answerDrafts["b"]?.explanation,draft.explanation)
        XCTAssertEqual(try LocalDraftJournal(directory:f.root).recover(StoredAnswerDraft.self,kind:"answer").values["b"]?.draft.values,draft.values)
        store.open(.request("a"))
        XCTAssertNil(store.requestDetail("b"),"The retained record never leaks to another selection")
    }
    func testSelectedSurfaceAndSnoozedFilterAreKeptDuringBackgroundRefresh() async throws {
        let f = Fixture(isolatedDefaults("NeedsRefreshFilters").preferences); defer { f.clean() }
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { f.waitStarted }
        store.configureWorkspace(surface:"human_tasks",archived:true)
        try await until { f.calls.last?["surface"] as? String == "human_tasks" && !store.workspaceLoading }
        for _ in 0..<3 { await store.refresh(quiet:true) }
        XCTAssertEqual(f.calls.suffix(3).compactMap { $0["surface"] as? String },["human_tasks","human_tasks","human_tasks"])
        XCTAssertTrue(f.calls.suffix(3).allSatisfy { $0["include_archived"] as? Bool == true })
        store.configureWorkspace(surface:"requests")
        try await until { f.calls.last?["surface"] as? String == "requests" && !store.workspaceLoading }
        XCTAssertEqual(f.calls.last?["include_archived"] as? Bool,true)
    }
    func testRefreshReseeksCurrentPageWithoutPublishingIntermediatePages() async throws {
        let f = Fixture(isolatedDefaults("NeedsRefreshPaging").preferences); defer { f.clean() }
        f.pageSize = 2; f.rows = ["a","b","c","d","e","f"].map { Fixture.request($0) }
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { f.waitStarted }
        store.moveWorkspacePage(try XCTUnwrap(store.workspaceNext))
        try await until { !store.workspaceLoading && store.workspaceRows.first?.id == "c" }
        let unchanged = expectation(description:"Intermediate first page is never displayed")
        unchanged.isInverted = true
        withObservationTracking({ _ = store.workspaceRows },onChange:{ unchanged.fulfill() })
        f.rows.append(Fixture.request("g"))
        let before = f.calls.count
        await store.refresh(quiet:true)
        XCTAssertEqual(store.workspaceRows.map(\.id),["c","d"])
        XCTAssertEqual(store.workspaceTotal,7)
        XCTAssertEqual(f.calls.count - before,2,"Re-seek with fresh event-bound cursors")
        XCTAssertNil(f.calls[before]["cursor"])
        XCTAssertEqual(f.calls.last?["cursor"] as? String,"2")
        await fulfillment(of:[unchanged],timeout:0.01)
    }
    func testFailedNewTabRetryStartsAtItsFirstPage() async throws {
        let f = Fixture(isolatedDefaults("NeedsRefreshNewQuery").preferences); defer { f.clean() }
        f.pageSize = 2; f.rows = ["a","b","c","d"].map { Fixture.request($0) }
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { f.waitStarted }
        store.moveWorkspacePage(try XCTUnwrap(store.workspaceNext))
        try await until { !store.workspaceLoading && store.workspaceRows.first?.id == "c" }
        f.failSurface = "human_tasks"
        store.configureWorkspace(surface:"human_tasks")
        try await until { store.workspaceError != nil && !store.workspaceLoading }
        XCTAssertFalse(store.workspacePageLoaded)
        store.retryWorkspacePage()
        try await until { store.workspacePageLoaded && !store.workspaceLoading }
        XCTAssertEqual(store.workspaceRows.map(\.id),["a","b"],"A failed new query cannot inherit the previous tab's page index")
    }
    private func descendants<T: NSView>(_ view: NSView, of: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0,of:T.self) }
    }
    func testMountedNeedsYouListKeepsScrollWhenRowsChange() async throws {
        let f = Fixture(isolatedDefaults("NeedsRefreshListScroll").preferences); defer { f.clean() }
        f.rows = (0..<40).map { Fixture.request("row-\($0)") }
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { f.waitStarted }
        let host = NSHostingView(rootView: NeedsYouView().environmentObject(store))
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:700,height:500),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await until { host.layoutSubtreeIfNeeded(); return !store.workspaceLoading && !self.descendants(host,of:NSScrollView.self).isEmpty }
        let scroll = try XCTUnwrap(descendants(host,of:NSScrollView.self).first)
        scroll.contentView.scroll(to:NSPoint(x:0,y:400)); scroll.reflectScrolledClipView(scroll.contentView)
        // Allow the user-scroll binding to reach SwiftUI before changing the page.
        try await Task.sleep(nanoseconds:30_000_000)
        let offset = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(offset,0)
        f.rows[39] = Fixture.request("row-39",title:"Changed request")
        f.rows.remove(at:38); f.rows.append(Fixture.request("new"))
        f.holdSurface = "requests"
        let refresh = Task { await store.refresh(quiet:true) }
        try await until { f.held != nil }
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(scroll.window === window)
        XCTAssertEqual(scroll.contentView.bounds.origin.y,offset,accuracy:1)
        f.release(); await refresh.value
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(scroll.window === window)
        XCTAssertEqual(scroll.contentView.bounds.origin.y,offset,accuracy:1)
        XCTAssertEqual(store.workspaceRows.last?.id,"new")
    }
    func testMountedRequestEditorFocusDraftAndScrollSurviveThreeBackgroundRefreshes() async throws {
        let f = Fixture(isolatedDefaults("NeedsRefreshNative").preferences); defer { f.clean() }
        let store = f.store(), live = Task { await store.startLiveUpdates() }
        defer { live.cancel(); store.stopWindowReads() }
        try await until { f.waitStarted }
        store.open(.request("b")); try await until { store.requestDetail("b") != nil && !store.otherDetailLoading }
        let host = NSHostingView(rootView: DetailOverlay(detail:.request("b")).environmentObject(store).environment(\.detailNavigationMemory,store.navigationMemory))
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:700,height:400),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await until { host.layoutSubtreeIfNeeded(); return !self.descendants(host,of:NSTextView.self).filter(\.isEditable).isEmpty }
        // Let initial panel focus run before simulating the owner's subsequent typing.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        let editor = try XCTUnwrap(descendants(host,of:NSTextView.self).first { $0.isEditable })
        editor.insertText("Typed draft stays",replacementRange:NSRange(location:0,length:0))
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location:5,length:0))
        let scroll = try XCTUnwrap(descendants(host,of:NSScrollView.self).first { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height })
        scroll.contentView.scroll(to:NSPoint(x:0,y:40))
        let offset = scroll.contentView.bounds.origin
        XCTAssertGreaterThan(offset.y,0)
        for i in 0..<3 {
            f.rows[0] = Fixture.request("a",title:"Background update \(i)")
            f.holdSurface = "record"
            await store.refresh(quiet:true)
            try await until { f.held != nil }
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(editor.window === window,"The editor stays mounted during a record read")
            XCTAssertTrue(window.firstResponder === editor,"Actual responder: \(String(describing:window.firstResponder))")
            XCTAssertEqual(editor.string,"Typed draft stays")
            f.release(); try await until { !store.otherDetailLoading }
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(window.firstResponder === editor,"Actual responder: \(String(describing:window.firstResponder))")
            XCTAssertEqual(editor.selectedRange(),NSRange(location:5,length:0))
            XCTAssertEqual(scroll.contentView.bounds.origin,offset)
        }
        f.failSurface = "record"; store.retryOtherDetail()
        try await until { store.otherDetailError != nil }
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(editor.window === window)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(store.answerDrafts["b"]?.explanation,"Typed draft stays")
    }
}

@MainActor private final class RefreshAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("Unexpected notification") }
    func remove(_ identifiers: [String]) {}
}
