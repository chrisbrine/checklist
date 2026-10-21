import Foundation
import Combine
import UserNotifications

enum DesktopAlertKind: String { case needsYou, deliveryFailure }
struct DesktopAlert: Equatable {
    let id: String
    let projectID: String
    let kind: DesktopAlertKind
    let signature: String
    let title: String
    let body: String
    /// The item a click opens: "request:<id>" or "task:<id>"; empty when the alert has no item (CL-59).
    var target = ""
}
struct DesktopAlertPreferences {
    static let enabledKey = "desktopAlertsEnabled"
    static let defaultModeKey = "desktopAlertDefaultMode"
    var enabled = false
    var defaultMode = "needs_you"
    static func current() -> Self {
        Self(enabled:UserDefaults.standard.bool(forKey:enabledKey),defaultMode:UserDefaults.standard.string(forKey:defaultModeKey) ?? "needs_you")
    }
}
struct DesktopAlertPlan {
    var send: [DesktopAlert] = []
    var remove: [String] = []
}

/// Uses already-fetched state only. Startup, opt-in and unmuting never replay an old inbox.
struct DesktopAlertPlanner {
    private var previous: [String:DesktopAlert] = [:]
    private var delivered: Set<String> = []
    private var initialized = false

    mutating func plan(snapshot: [String:Any], preferences: DesktopAlertPreferences, authorized: Bool) -> DesktopAlertPlan {
        let projects = (snapshot["projects"] as? [[String:Any]] ?? []).reduce(into:[String:[String:Any]]()) { result, project in if let id = project["id"] as? String { result[id] = project } }
        let tasks = (snapshot["tasks"] as? [[String:Any]] ?? []).reduce(into:[String:[String:Any]]()) { result, task in if let id = task["id"] as? String { result[id] = task } }
        var candidates: [String:DesktopAlert] = [:]
        func add(_ id: String,_ project: String,_ kind: DesktopAlertKind,_ signature: String,_ title: String,_ body: String,target: String) {
            guard let definition = projects[project], definition["archived"] as? Bool != true else { return }
            candidates[id] = DesktopAlert(id:id,projectID:project,kind:kind,signature:signature,title:title,body:body,target:target)
        }
        for request in snapshot["requests"] as? [[String:Any]] ?? [] {
            guard request["state"] as? String == "pending",request["owner_snoozed"] as? Bool != true,let id = request["id"] as? String,let pid = request["project_id"] as? String else { continue }
            if let tid = request["task_id"] as? String,let task = tasks[tid],task["archived"] as? Bool == true || task["trashed"] as? Bool == true { continue }
            let revision = (request["revision"] as? NSNumber)?.stringValue ?? "1"
            add("request:"+id,pid,.needsYou,revision,"Checklist · Needs You",request["title"] as? String ?? "A request needs your answer.",target:"request:"+id)
        }
        for (id,task) in tasks {
            let assignment = task["planned_assignee"] as? String ?? (task["planned_assignee"] as? [String:Any])?["kind"] as? String ?? ""
            guard assignment == "human",task["archived"] as? Bool != true,task["trashed"] as? Bool != true,!["done","completed","canceled"].contains(Canceled.normalized(task["status_category"] as? String ?? "")),let pid = task["project_id"] as? String else { continue }
            add("task:"+id,pid,.needsYou,"human_assignment","Checklist · Assigned to you",task["title"] as? String ?? "A ticket is assigned to you.",target:"task:"+id)
        }
        for message in snapshot["messages"] as? [[String:Any]] ?? [] {
            guard let pid = message["project_id"] as? String else { continue }
            for delivery in message["deliveries"] as? [[String:Any]] ?? [] {
                let state = delivery["state"] as? String ?? ""
                guard let id = delivery["id"] as? String,["unavailable","failed","delivery_uncertain","held_for_approval"].contains(state) else { continue }
                add("delivery:"+id,pid,.deliveryFailure,state,"Checklist · Delivery needs attention","A message could not be delivered or needs approval. Open Checklist for its actual receipt.",target:(message["task_id"] as? String).map { "task:"+$0 } ?? "")
            }
        }
        func eligible(_ alert: DesktopAlert) -> Bool {
            guard preferences.enabled,authorized else { return false }
            let override = projects[alert.projectID]?["alert_override"] as? String ?? "inherit"
            let mode = override == "inherit" ? preferences.defaultMode : override
            return mode == "all" || (mode == "needs_you" && alert.kind == .needsYou)
        }
        let eligibleIDs = Set(candidates.values.filter(eligible).map(\.id))
        let remove = delivered.subtracting(eligibleIDs).sorted()
        delivered.subtract(remove)
        let fresh = initialized ? candidates.values.filter { eligible($0) && previous[$0.id]?.signature != $0.signature }.sorted { $0.id < $1.id } : []
        previous = candidates; initialized = true
        // Bound one publication without replaying an accumulating backlog on the next refresh.
        return DesktopAlertPlan(send:Array(fresh.prefix(5)),remove:remove)
    }
    mutating func didSend(_ id: String) { delivered.insert(id) }
}

enum DesktopAlertAuthorization: String { case allowed, denied, notRequested }
@MainActor protocol DesktopAlertSink: AnyObject {
    func authorization() async -> DesktopAlertAuthorization
    func requestAuthorizationFromOwnerAction() async throws -> Bool
    func send(_ alert: DesktopAlert) async throws
    func remove(_ identifiers: [String])
}

@MainActor final class SystemDesktopAlertSink: NSObject, DesktopAlertSink, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    override init() { center = UNUserNotificationCenter.current(); super.init(); center.delegate = self }
    func authorization() async -> DesktopAlertAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized,.provisional: return .allowed
        case .denied: return .denied
        default: return .notRequested
        }
    }
    // This method is called only by the explicit owner button, never startup or a snapshot.
    func requestAuthorizationFromOwnerAction() async throws -> Bool { try await center.requestAuthorization(options:[.alert]) }
    func send(_ alert: DesktopAlert) async throws {
        let content = UNMutableNotificationContent(); content.title = alert.title; content.body = alert.body
        content.userInfo = ["project_id":alert.projectID,"checklist_alert_id":alert.id,"checklist_target":alert.target]
        try await center.add(UNNotificationRequest(identifier:alert.id,content:content,trigger:nil))
    }
    func remove(_ identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers:identifiers); center.removeDeliveredNotifications(withIdentifiers:identifiers) }
    /// CL-59: a click opens the alert's ticket or request in the most recently active window.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,didReceive response: UNNotificationResponse,withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        let target = request.content.userInfo["checklist_target"] as? String ?? "", identifier = request.identifier
        Task { @MainActor in DesktopAlertClicks.shared.received(target: target, identifier: identifier) }
        completionHandler()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,willPresent notification: UNNotification,withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner,.list]) }
}

@MainActor final class DesktopAlertCoordinator: ObservableObject {
    static let shared = DesktopAlertCoordinator(sink:SystemDesktopAlertSink())
    @Published private(set) var lastFailure: String?
    private var planner = DesktopAlertPlanner()
    private let sink: DesktopAlertSink
    private let preferences: () -> DesktopAlertPreferences
    private var lastSnapshot: [String:Any]?
    private var observationGeneration = 0
    init(sink: DesktopAlertSink,preferences: @escaping () -> DesktopAlertPreferences = { .current() }) { self.sink = sink; self.preferences = preferences }
    func observe(snapshot: [String:Any]) async {
        lastSnapshot = snapshot; observationGeneration += 1
        let generation = observationGeneration
        let prefs = preferences(), authorized = prefs.enabled ? await sink.authorization() == .allowed : false
        guard generation == observationGeneration else { return }
        let plan = planner.plan(snapshot:snapshot,preferences:prefs,authorized:authorized)
        if !plan.remove.isEmpty { sink.remove(plan.remove) }
        for alert in plan.send {
            guard generation == observationGeneration,preferences().enabled else { return }
            do {
                try await sink.send(alert)
                guard generation == observationGeneration else { sink.remove([alert.id]); return }
                planner.didSend(alert.id)
            }
            catch { lastFailure = "A desktop alert could not be shown. The item and its actual delivery state remain in Checklist. \(error.localizedDescription)" }
        }
    }
    func preferencesChanged() async { if let lastSnapshot { await observe(snapshot:lastSnapshot) } }
    func authorization() async -> DesktopAlertAuthorization { await sink.authorization() }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { try await sink.requestAuthorizationFromOwnerAction() }
}

/// CL-59: what a desktop alert click opens. Older alerts without a stored target use their identifier.
enum DesktopAlertTarget: Equatable {
    case request(String), task(String)
    init?(target: String, identifier: String) {
        let value = target.isEmpty ? identifier : target
        if value.hasPrefix("request:"), value.count > 8 { self = .request(String(value.dropFirst(8))) }
        else if value.hasPrefix("task:"), value.count > 5 { self = .task(String(value.dropFirst(5))) }
        else { return nil }
    }
}

/// Holds a click until a window can open it, for example when the click launched the app.
@MainActor final class DesktopAlertClicks {
    static let shared = DesktopAlertClicks()
    private(set) var pending: DesktopAlertTarget?
    private var handler: ((DesktopAlertTarget) -> Bool)?
    /// The handler returns false when no window can open the item yet.
    func setHandler(_ handler: @escaping (DesktopAlertTarget) -> Bool) {
        self.handler = handler
        if let pending, handler(pending) { self.pending = nil }
    }
    /// Opens a waiting click when a window can take it again (for example after the last window closed).
    func flush() { if let pending, handler?(pending) == true { self.pending = nil } }
    func received(target: String, identifier: String) {
        guard let target = DesktopAlertTarget(target: target, identifier: identifier) else { return }
        route(target)
    }
    /// Opens the item now, or keeps it until a window can open it (CL-65 quick capture uses this too).
    func route(_ target: DesktopAlertTarget) { if handler?(target) != true { pending = target } }
}
