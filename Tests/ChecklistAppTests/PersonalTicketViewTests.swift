import XCTest
@testable import ChecklistApp

final class PersonalTicketViewTests: XCTestCase {
    func testPersonalViewsAreBoundedProjectScopedAndUpdateInPlace() throws {
        let prefs = isolatedDefaults("CL16").preferences
        let first = PersonalTicketViews(preferences:prefs,projectID:"first"), other = PersonalTicketViews(preferences:prefs,projectID:"other")
        var view = PersonalTicketView(name:"Art",search:"shader",status:"ready",legacyTag:"all",filters:TicketListFilters(tagIDs:["art"],tagMode:"all",plannedAssignee:"agent",actualAssignee:"unassigned",epicID:"none",triageID:"all"),groupBy:"epic",orderBy:"priority")
        XCTAssertTrue(first.save(view)); XCTAssertTrue(other.load().isEmpty)
        view.name = "Ready art"; XCTAssertTrue(first.save(view)); XCTAssertEqual(first.load().count,1); XCTAssertEqual(first.load().first?.name,"Ready art")
        XCTAssertEqual(first.load().first?.filters,view.filters)
        for index in 1..<10 { var extra = view; extra.id = UUID().uuidString; extra.name = "View \(index)"; XCTAssertTrue(first.save(extra)) }
        var overflow = view; overflow.id = UUID().uuidString; XCTAssertFalse(first.save(overflow)); XCTAssertEqual(first.load().count,10)
        first.remove(view.id); XCTAssertEqual(first.load().count,9); XCTAssertTrue(first.save(overflow))
    }
    @MainActor func testProjectDefaultPersonalPrecedenceAndResetNeverWriteProjectSettings() {
        let prefs = isolatedDefaults("CL16").preferences
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/CL16-preferences-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        prefs.set(Page.needsYou.rawValue,forKey:"lastPage")
        let store = ChecklistStore(draftJournal:LocalDraftJournal(directory:root),preferences:prefs,restorePendingCommand:false,desktopAlerts:DesktopAlertCoordinator(sink:PersonalViewAlertSink()), requestTransport: { _,_ in XCTFail("Preferences must not send service commands"); return [:] })
        store.projectID = "p"
        store.data = ["projects":[["id":"p","name":"Project","default_view":["group_by":"epic","order_by":"priority"]]]]
        store.loadTaskView()
        XCTAssertEqual(store.viewGroupBy,"epic"); XCTAssertEqual(store.viewOrderBy,"priority")
        store.page = .archived
        store.search = "shader"; store.statusFilter = "ready"; store.listFilters = TicketListFilters(tagIDs:["art"],tagMode:"none")
        store.saveTaskView(groupBy:"none",orderBy:"manual"); store.savePersonalTicketView(name:"My view")
        let view = store.personalViews.first!
        store.useProjectTaskView()
        XCTAssertEqual(store.viewGroupBy,"epic"); XCTAssertEqual(store.viewOrderBy,"priority"); XCTAssertFalse(store.listHasFilters)
        XCTAssertEqual(store.personalViews.count,1); XCTAssertNil(store.selectedPersonalViewID)
        store.page = .tasks
        store.applyPersonalTicketView(view)
        XCTAssertEqual(store.page,.archived)
        XCTAssertEqual(store.viewGroupBy,"none"); XCTAssertEqual(store.viewOrderBy,"manual"); XCTAssertEqual(store.search,"shader")
        XCTAssertEqual(store.listFilters.tagIDs,["art"])
        store.resetTicketFilters(); XCTAssertFalse(store.listHasFilters); XCTAssertEqual(store.viewGroupBy,"none")
        XCTAssertEqual(store.project("p")?.object("default_view")["order_by"] as? String,"priority")
    }
    func testAllFiltersParticipateInReadIdentityAndParameters() {
        let plain = TicketPageQuery(surface:"tickets",projectID:"p",text:"",statusFilter:"all",tagFilter:"all",groupBy:"status",orderBy:"manual")
        var filtered = plain; filtered.filters = TicketListFilters(tagIDs:["bug"],tagMode:"none",plannedAssignee:"agent",actualAssignee:"unassigned",epicID:"none",triageID:"triage")
        XCTAssertNotEqual(plain,filtered); XCTAssertTrue(filtered.hasFilters)
        let view = filtered.parameters()["view"] as! [String:Any]
        XCTAssertEqual(view["tag_ids"] as? [String],["bug"]); XCTAssertEqual(view["tag_mode"] as? String,"none")
        XCTAssertEqual(view["actual_assignee"] as? String,"unassigned"); XCTAssertEqual(view["triage_id"] as? String,"triage")
        var identity = filtered; identity.filters.triageID = "é"; filtered.filters.triageID = "e\u{301}"
        XCTAssertNotEqual(identity,filtered)
    }
}

@MainActor private final class PersonalViewAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert:DesktopAlert) async throws { }
    func remove(_ ids:[String]) { }
}
