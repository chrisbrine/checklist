import Foundation

/// Opt-in measurement of actual native View bodies and App request boundaries.
/// The fixed vocabulary never records record IDs, drafts, queries or payloads.
/// Nothing is published back to SwiftUI, and the hot path never serializes/logs.
enum NativeRenderMetrics {
    enum Body: String, CaseIterable, Codable, Sendable {
        case content, sidebar, tickets, ticketRow, ticketLabel, detailOverlay
        case taskDetail, noteComposer, messageRow, needsYou, epics, activity
    }
    enum Family: String, CaseIterable, Codable, Sendable {
        case ticketPage, workspacePage, selectedTicket, selectedWork, selectedOther
        case eligibility, eventHistory, changes, snapshot, other
        static func classify(_ method: String, detail: String?) -> Self {
            switch method {
            case "task_list": return .ticketPage
            case "workspace_page": return .workspacePage
            case "task_context": return ["ui_records", "ui_history"].contains(detail ?? "") ? .selectedWork : .selectedTicket
            case "selected_context": return .selectedOther
            case "task_get": return .eligibility
            case "history_list", "event_list": return .eventHistory
            case "changes_wait": return .changes
            case "snapshot": return .snapshot
            default: return .other
            }
        }
    }
    struct Request: Sendable { fileprivate let epoch: UInt64; fileprivate let family: Family; fileprivate let start: UInt64 }
    struct RequestCount: Codable, Equatable {
        var started = 0
        var succeeded = 0
        var failed = 0
        var elapsedNanoseconds: UInt64 = 0
    }
    struct Snapshot: Codable {
        let schemaVersion: Int
        let sample: Int
        let epoch: UInt64
        let durationNanoseconds: UInt64
        let observedChanges: Int
        let bodies: [String:Int]
        let firstBodyNanoseconds: [String:UInt64]
        let firstAppearanceNanoseconds: [String:UInt64]
        let requests: [String:RequestCount]
        let truncated: Bool
        let expired: Bool
        let limit: Int
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var enabled = false
        var epoch: UInt64 = 0
        var sample = 0
        var start: UInt64 = 0
        var deadline: UInt64 = 0
        var expired = false
        var bodies: [Body:Int] = [:]
        var firstBody: [Body:UInt64] = [:]
        var firstAppearance: [Body:UInt64] = [:]
        var requests: [Family:RequestCount] = [:]
        var events = 0
        var observedChanges = 0
        var truncated = false
        let limit = 100_000
        func consume() -> Bool {
            guard DispatchTime.now().uptimeNanoseconds <= deadline else {expired = true;return false}
            guard events < limit else {truncated = true;return false}
            events += 1;return true
        }
    }
    private static let state = State()
    /// Only an explicit measurement host arms a finite sample. The ordinary App
    /// has no caller of this API, no environment backend and no recording sink.
    static func begin(sample: Int) {
        state.lock.lock();defer {state.lock.unlock()}
        state.epoch &+= 1;state.sample = sample;state.start = DispatchTime.now().uptimeNanoseconds
        state.deadline = state.start + 30_000_000_000;state.expired = false
        state.bodies = [:];state.firstBody = [:];state.firstAppearance = [:];state.requests = [:];state.events = 0;state.observedChanges = 0;state.truncated = false;state.enabled = true
    }
    static func body(_ body: Body) {
        state.lock.lock();defer {state.lock.unlock()}
        guard state.enabled,state.consume() else {return}
        state.bodies[body,default:0] += 1
        if state.firstBody[body] == nil {state.firstBody[body] = DispatchTime.now().uptimeNanoseconds-state.start}
    }
    /// Native SwiftUI mount timing, not a claim about a physical display frame.
    static func appeared(_ body: Body) {
        state.lock.lock();defer {state.lock.unlock()}
        guard state.enabled,state.consume(),state.firstAppearance[body] == nil else {return}
        state.firstAppearance[body] = DispatchTime.now().uptimeNanoseconds-state.start
    }
    /// The actual Store event loop calls this only after consuming a changed
    /// response. A zero-refresh sample requires this positive observation proof.
    static func changeObserved() {
        state.lock.lock();defer {state.lock.unlock()}
        guard state.enabled,state.consume() else {return}
        state.observedChanges += 1
    }
    static func startRequest(_ family: Family) -> Request? {
        state.lock.lock();defer {state.lock.unlock()}
        guard state.enabled,state.consume() else {return nil}
        var count = state.requests[family] ?? .init();count.started += 1;state.requests[family] = count
        return .init(epoch:state.epoch,family:family,start:DispatchTime.now().uptimeNanoseconds)
    }
    static func finishRequest(_ request: Request?, succeeded: Bool) {
        guard let request else {return}
        state.lock.lock();defer {state.lock.unlock()}
        guard state.enabled,state.epoch == request.epoch,state.consume() else {return}
        var count = state.requests[request.family] ?? .init()
        if succeeded {count.succeeded += 1} else {count.failed += 1}
        count.elapsedNanoseconds &+= DispatchTime.now().uptimeNanoseconds - request.start
        state.requests[request.family] = count
    }
    /// Called after the native sample settles. Serialization and file ownership
    /// belong to the isolated host, outside body/request decision paths.
    static func finish() -> Snapshot? {
        state.lock.lock();defer {state.lock.unlock()}
        guard state.enabled else {return nil}
        state.enabled = false
        return .init(schemaVersion:1,sample:state.sample,epoch:state.epoch,
                     durationNanoseconds:DispatchTime.now().uptimeNanoseconds-state.start,observedChanges:state.observedChanges,
                     bodies:Dictionary(uniqueKeysWithValues:Body.allCases.map {($0.rawValue,state.bodies[$0] ?? 0)}),
                     firstBodyNanoseconds:Dictionary(uniqueKeysWithValues:state.firstBody.map {($0.key.rawValue,$0.value)}),
                     firstAppearanceNanoseconds:Dictionary(uniqueKeysWithValues:state.firstAppearance.map {($0.key.rawValue,$0.value)}),
                     requests:Dictionary(uniqueKeysWithValues:Family.allCases.map {($0.rawValue,state.requests[$0] ?? .init())}),
                     truncated:state.truncated,expired:state.expired || DispatchTime.now().uptimeNanoseconds > state.deadline,limit:state.limit)
    }
    static func cancel() {
        state.lock.lock();defer {state.lock.unlock()}
        state.enabled = false;state.epoch &+= 1
        state.bodies = [:];state.firstBody = [:];state.firstAppearance = [:];state.requests = [:]
    }
}
