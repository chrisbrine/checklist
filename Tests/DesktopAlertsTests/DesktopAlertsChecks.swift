import Foundation
#if canImport(ChecklistApp)
import XCTest
@testable import ChecklistApp
#endif

@MainActor final class FakeDesktopAlertSink: DesktopAlertSink {
    var status = DesktopAlertAuthorization.allowed
    var authorizations = 0
    var permissionRequests = 0
    var sent: [DesktopAlert] = []
    var removed: [String] = []
    var failSend = false
    var pauseNextAuthorization = false
    var pendingAuthorization: CheckedContinuation<DesktopAlertAuthorization,Never>?
    var pauseWaiter: CheckedContinuation<Void,Never>?
    func authorization() async -> DesktopAlertAuthorization {
        authorizations += 1
        if pauseNextAuthorization {
            pauseNextAuthorization = false
            return await withCheckedContinuation { continuation in pendingAuthorization = continuation; pauseWaiter?.resume(); pauseWaiter = nil }
        }
        return status
    }
    func waitUntilPaused() async { if pendingAuthorization == nil { await withCheckedContinuation { pauseWaiter = $0 } } }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { permissionRequests += 1; return true }
    func send(_ alert: DesktopAlert) async throws {
        if failSend { throw NSError(domain:"Synthetic desktop sink",code:1,userInfo:[NSLocalizedDescriptionKey:"Synthetic rejection"]) }
        sent.append(alert)
    }
    func remove(_ identifiers: [String]) { removed += identifiers }
}

#if !canImport(ChecklistApp)
@main
#endif
@MainActor struct DesktopAlertsChecks {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool,_ message: String) throws {
        checks += 1
        if !value() { throw NSError(domain:"DesktopAlertsChecks",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    }
    nonisolated static func project(_ id: String = "p",_ mode: String = "inherit") -> [String:Any] { ["id":id,"name":id,"alert_override":mode,"archived":false] }
    nonisolated static func request(_ id: String = "r",_ pid: String = "p") -> [String:Any] { ["id":id,"project_id":pid,"state":"pending","title":"Choose the result","revision":1] }
    nonisolated static func snapshot(projects: [[String:Any]] = [project()],requests: [[String:Any]] = [],tasks: [[String:Any]] = [],messages: [[String:Any]] = []) -> [String:Any] { ["projects":projects,"requests":requests,"tasks":tasks,"messages":messages] }
    nonisolated static func message(_ id: String,_ state: String,_ pid: String = "p") -> [String:Any] { ["id":"m-"+id,"project_id":pid,"deliveries":[["id":id,"state":state,"push_state":"unavailable"]]] }
    nonisolated static func encoded(_ value: [String:Any]) throws -> Data { try JSONSerialization.data(withJSONObject:value,options:.sortedKeys) }

    static func main() async throws {
        // A clean installation remains off; neither construction nor observations ask permission.
        let inactive = FakeDesktopAlertSink(), disabled = DesktopAlertCoordinator(sink:inactive,preferences:{ DesktopAlertPreferences() })
        await disabled.observe(snapshot:snapshot())
        let pending = snapshot(requests:[request()])
        await disabled.observe(snapshot:pending)
        try expect(inactive.sent.isEmpty,"Default-off routing emitted an OS alert")
        try expect(inactive.authorizations == 0 && inactive.permissionRequests == 0,"Default-off observer contacted permission setup")

        var prefs = DesktopAlertPreferences(enabled:true,defaultMode:"all")
        let sink = FakeDesktopAlertSink(), coordinator = DesktopAlertCoordinator(sink:sink,preferences:{ prefs })
        await coordinator.observe(snapshot:snapshot(requests:[request("old")]))
        try expect(sink.sent.isEmpty,"Startup replayed old Needs You items")
        let new = snapshot(requests:[request("old"),request("new")])
        let before = try encoded(new)
        await coordinator.observe(snapshot:new); await coordinator.observe(snapshot:new)
        try expect(sink.sent.map(\.id) == ["request:new"],"New item must alert once across repeated publishes")
        let after = try encoded(new)
        try expect(after == before,"Alert routing changed actual inbox data")
        try expect(sink.permissionRequests == 0,"A normal snapshot asked OS permission")

        await coordinator.observe(snapshot:snapshot(projects:[project("p","quiet")],requests:[request("old"),request("new"),request("quiet")]))
        try expect(sink.sent.count == 1,"Quiet project produced a new alert")
        try expect(sink.removed.contains("request:new"),"Quiet did not remove an alert already sent by this app session")
        await coordinator.observe(snapshot:snapshot(requests:[request("old"),request("new"),request("quiet")]))
        try expect(sink.sent.count == 1,"Unmuting replayed a quiet-period item")

        let failures = [message("failed","unavailable"),message("normal-pickup","queued")]
        await coordinator.observe(snapshot:snapshot(requests:[request("old"),request("new"),request("quiet")],messages:failures))
        try expect(sink.sent.last?.id == "delivery:failed","Inherited all mode omitted a true failure or alerted normal pickup")
        try expect(!sink.sent.contains { $0.id == "delivery:normal-pickup" },"Unqualified native push was treated as a failed pickup")
        await coordinator.observe(snapshot:snapshot(projects:[project("p","needs_you"),project("q","inherit")],requests:[request("other","q")],messages:[message("failed2","held_for_approval")]))
        try expect(!sink.sent.contains { $0.id == "delivery:failed2" },"Needs You override inherited unrelated failure alerts")
        try expect(sink.sent.contains { $0.id == "request:other" },"One project's override suppressed another project's alert")

        prefs.enabled = false
        await coordinator.preferencesChanged()
        try expect(sink.removed.contains("request:other"),"Local opt-out did not remove session alerts")
        prefs.enabled = true
        await coordinator.preferencesChanged()
        try expect(sink.sent.filter { $0.id == "request:other" }.count == 1,"Opt-in replayed existing items")

        let deniedSink = FakeDesktopAlertSink(); deniedSink.status = .denied
        let denied = DesktopAlertCoordinator(sink:deniedSink,preferences:{ DesktopAlertPreferences(enabled:true,defaultMode:"all") })
        await denied.observe(snapshot:snapshot()); await denied.observe(snapshot:pending)
        try expect(deniedSink.sent.isEmpty && deniedSink.permissionRequests == 0,"Denied permission was bypassed or automatically requested")
        deniedSink.status = .allowed; await denied.observe(snapshot:pending)
        try expect(deniedSink.sent.isEmpty,"New permission replayed a historical inbox")
        await denied.observe(snapshot:snapshot(requests:[request(),request("after-permission")]))
        try expect(deniedSink.sent.map(\.id) == ["request:after-permission"],"Allowed permission failed to route a new item")

        let failedSink = FakeDesktopAlertSink(); failedSink.failSend = true
        let failed = DesktopAlertCoordinator(sink:failedSink,preferences:{ DesktopAlertPreferences(enabled:true,defaultMode:"all") })
        await failed.observe(snapshot:snapshot()); await failed.observe(snapshot:pending)
        try expect(failed.lastFailure?.contains("Synthetic rejection") == true,"OS failure was not honestly visible")
        try expect(failedSink.permissionRequests == 0,"A delivery error triggered permission setup")
        let permission = try await failed.requestAuthorizationFromOwnerAction()
        try expect(permission && failedSink.permissionRequests == 1,"Only the explicit owner action may ask permission")

        var snoozed = request(); snoozed["owner_snoozed"] = true
        var answered = request("answered"); answered["state"] = "answered"
        let task: [String:Any] = ["id":"human","project_id":"p","title":"Record a result","planned_assignee":"human","status_category":"queued"]
        var planner = DesktopAlertPlanner()
        _ = planner.plan(snapshot:snapshot(),preferences:prefs,authorized:true)
        let planned = planner.plan(snapshot:snapshot(requests:[snoozed,answered],tasks:[task]),preferences:prefs,authorized:true)
        try expect(planned.send.map(\.id) == ["task:human"],"Actionable human work or snoozed/resolved requests were classified incorrectly")
        let many = (0..<30).map { request("many-\($0)") }
        let bounded = planner.plan(snapshot:snapshot(requests:many),preferences:prefs,authorized:true)
        try expect(bounded.send.count == 5,"One snapshot flooded desktop alerts")
        try expect(planner.plan(snapshot:snapshot(requests:many),preferences:prefs,authorized:true).send.isEmpty,"Bounded suppression replayed a backlog")

        // A newer opt-out wins even if OS authorization for an older publication is still in flight.
        var racePrefs = DesktopAlertPreferences(enabled:true,defaultMode:"all")
        let racingSink = FakeDesktopAlertSink(), racing = DesktopAlertCoordinator(sink:racingSink,preferences:{ racePrefs })
        await racing.observe(snapshot:snapshot())
        racingSink.pauseNextAuthorization = true
        let inFlight = Task { await racing.observe(snapshot:pending) }
        await racingSink.waitUntilPaused()
        racePrefs.enabled = false; await racing.preferencesChanged()
        racingSink.pendingAuthorization?.resume(returning:.allowed); racingSink.pendingAuthorization = nil
        await inFlight.value
        try expect(racingSink.sent.isEmpty,"An in-flight old snapshot sent after local opt-out")

        // CL-59: a click opens the alert's ticket or request; a click before any window waits for one.
        var targets = DesktopAlertPlanner()
        _ = targets.plan(snapshot:snapshot(),preferences:DesktopAlertPreferences(enabled:true,defaultMode:"all"),authorized:true)
        var failedDelivery = message("d-target","unavailable"); failedDelivery["task_id"] = "t-delivery"
        let routed = targets.plan(snapshot:snapshot(requests:[request("r-target")],tasks:[task],messages:[failedDelivery]),preferences:DesktopAlertPreferences(enabled:true,defaultMode:"all"),authorized:true)
        try expect(Set(routed.send.map(\.target)) == ["request:r-target","task:human","task:t-delivery"],"An alert does not name the item its click opens")
        try expect(DesktopAlertTarget(target:"request:r1",identifier:"x") == .request("r1"),"A request target did not parse")
        try expect(DesktopAlertTarget(target:"",identifier:"task:t1") == .task("t1"),"An older alert without a target did not fall back to its identifier")
        try expect(DesktopAlertTarget(target:"",identifier:"delivery:d1") == nil,"A delivery alert without a ticket opened something")
        let clicks = DesktopAlertClicks()
        clicks.received(target:"task:t9",identifier:"task:t9")
        try expect(clicks.pending == .task("t9"),"A click before any window was lost")
        var opened: [DesktopAlertTarget] = []
        clicks.setHandler { opened.append($0); return true }
        try expect(opened == [.task("t9")] && clicks.pending == nil,"The waiting click did not open when a window became available")
        clicks.received(target:"request:r9",identifier:"request:r9")
        try expect(opened.last == .request("r9"),"A click did not open its request")
        let closed = DesktopAlertClicks(); closed.setHandler { _ in false }
        closed.received(target:"task:t10",identifier:"task:t10")
        try expect(closed.pending == .task("t10"),"A click that no window could open was dropped")
        var reopened: [DesktopAlertTarget] = []
        let later = DesktopAlertClicks(); later.setHandler { _ in false }
        later.received(target:"task:t11",identifier:"task:t11")
        later.setHandler { reopened.append($0); return true }; later.received(target:"request:r11",identifier:"request:r11")
        try expect(reopened == [.task("t11"),.request("r11")],"A replaced handler did not open the waiting click first")
        let flushed = DesktopAlertClicks(); var available = false; var flushedTargets: [DesktopAlertTarget] = []
        flushed.setHandler { target in
            guard available else { return false }
            flushedTargets.append(target); return true
        }
        flushed.received(target:"task:t12",identifier:"task:t12"); available = true; flushed.flush()
        try expect(flushedTargets == [.task("t12")] && flushed.pending == nil,"A window that became available did not open the waiting click")

        print("Desktop alert checks passed: \(checks). Fake sink only; no system notification or OS permission request, and no preference write.")
    }
}

#if canImport(ChecklistApp)
@MainActor final class DesktopAlertsTests: XCTestCase {
    func testStandaloneChecks() async throws {
        try await DesktopAlertsChecks.main()
    }
}
#endif
