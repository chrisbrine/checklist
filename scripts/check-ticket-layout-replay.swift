// Isolated macOS layout replay; no Checklist service or persistent app preferences.
// Compile from the repository root:
// xcrun swiftc -swift-version 5 -parse-as-library Sources/ChecklistApp/Models/{Record,TicketListProjection,TicketListRows}.swift Sources/ChecklistApp/Support/{RecordOrdering,Design}.swift Sources/ChecklistApp/Views/{InlineTriageRow,TaskWorkspaceView}.swift scripts/check-ticket-layout-replay.swift -o /tmp/checklist-ticket-layout-check
// Run /tmp/checklist-ticket-layout-check (idle live snapshots) or add --animated-width / --scroll-stress.
import SwiftUI
import AppKit
import Foundation
import Darwin

@MainActor final class ChecklistStore: ObservableObject {
    @Published var data: [String: Any] = [:]
    @Published var page: Page = .tasks
    @Published var projectID: String? = "synthetic-project"
    @Published var search = ""
    @Published var statusFilter = "all"
    @Published var tagFilter = "all"
    @Published var viewGroupBy = "status"
    @Published var viewOrderBy = "manual"
    @Published var detail: Detail?
    @Published var connected = true
    @Published var loading = false
    @Published var busy = false
    @Published var error: String?
    @Published var showCapture = false
    @Published var sidebarVisible = true
    func records(_ key: String) -> [Record] { (data[key] as? [[String: Any]] ?? []).map(Record.init) }
    var tasks: [Record] { records("tasks") }
    var groups: [Record] { records("groups") }
    var projects: [Record] { records("projects").isEmpty ? [Record(values: ["id":"synthetic-project","name":"Synthetic replay"])] : records("projects") }
    var currentProject: Record? { projects.first }
    var outstandingRequests: [Record] { [] }
    func projectName(_ id: String) -> String { "Synthetic replay" }
    func task(_ id: String) -> Record? { tasks.first { $0.id == id } }
    func statuses(_ project: String) -> [Record] { [Record(values:["id":"review","name":"Review","category":"review"])] }
    func tags(_ project: String) -> [Record] { [] }
    func open(_ detail: Detail) { self.detail = detail }
    func saveTaskView(groupBy: String? = nil, orderBy: String? = nil) {}
    func useProjectTaskView() {}
    func run(_ method: String, _ params: [String: Any], success: String? = nil, completion: (([String: Any]) -> Void)? = nil) {}
    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] { [:] }
}
struct CreateTriageSheet: View {
    let onCreated: (String) -> Void
    var body: some View { EmptyView() }
}
struct ReplayRoot: View {
    @EnvironmentObject var store: ChecklistStore
    var body: some View {
        HStack(spacing: 0) {
            if store.sidebarVisible {
                Color.clear.frame(width: 224).transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            GeometryReader { _ in
                ZStack(alignment: .trailing) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 48)
                        TaskWorkspaceView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.frame(minWidth: 900, minHeight: 650)
    }
}

func validateRowIdentity() {
    let task = Record(values:["id":"ticket", "epic_id":"epic", "status_category":"review"])
    func section(_ id: String, members: [Record]) -> InlineTriageSection {
        InlineTriageSection(triage:Record(values:["id":id,"purpose":"Purpose","task_ids":members.map(\.id)]),allMembers:members,visibleMembers:members,matchesGroupSearch:false)
    }
    let a = section("a",members:[task]), b = section("b",members:[task])
    let rows = TicketListRows.make(triages:[a,b],expandedIDs:["a","b"],ordinaryGroups:[])
    precondition(Set(rows.map(\.id)).count == rows.count,"A ticket in multiple Triages requires distinct displayed row identities")
    precondition(rows.contains { $0.id == .triageMember(triageID:"a",taskID:"ticket") } && rows.contains { $0.id == .triageMember(triageID:"b",taskID:"ticket") })
    let collapsed = TicketListRows.make(triages:[a,b],expandedIDs:["b"],ordinaryGroups:[])
    precondition(!collapsed.contains { $0.id == .triageMember(triageID:"a",taskID:"ticket") } && collapsed.contains { $0.id == .triageMember(triageID:"b",taskID:"ticket") })
    let named = TicketListRows.make(triages:[],expandedIDs:[],ordinaryGroups:[("A",[]),("A/separator",[])])
    precondition(Set(named.map(\.id)).count == named.count,"Display labels cannot collide with separator identities")
    let moved = TicketListRows.make(triages:[section("a",members:[])],expandedIDs:["a"],ordinaryGroups:[("In progress",[task])])
    precondition(!moved.contains { $0.id == .triageMember(triageID:"a",taskID:"ticket") } && moved.contains { $0.id == .ticket("ticket") })
    precondition(task.string("epic_id") == "epic","A row move cannot change a ticket's primary Epic")
    let snapshot = syntheticSnapshot(0)
    let projection = TicketListProjection.make(tasks:(snapshot["tasks"] as? [[String:Any]] ?? []).map(Record.init),groups:(snapshot["groups"] as? [[String:Any]] ?? []).map(Record.init),messages:[],projectID:exactFixture?["project_id"] as? String ?? "synthetic-project",archived:false,statusFilter:"all",tagFilter:"all",search:"",includeTriages:true,projectNames:[:])
    let memberIDs = Set(projection.triages.flatMap { $0.visibleMembers.map(\.id) })
    precondition(!projection.ordinaryTickets.contains { memberIDs.contains($0.id) },"Displayed members must not also appear as ordinary tickets")
    print("GREEN: flat row identity, expansion, membership departure, Epic and duplicate-suppression checks")
}

var exactFixture: [String: Any]?
func syntheticSnapshot(_ phase: Int) -> [String: Any] {
    if let fixture = exactFixture {
        var snapshot = fixture["snapshot"] as! [String: Any]
        var tasks = snapshot["tasks"] as! [[String: Any]]
        var groups = snapshot["groups"] as! [[String: Any]]
        let removed = phase % 4 == 1 || phase % 4 == 2
        for i in tasks.indices where tasks[i]["id"] as? String == fixture["task_id"] as? String {
            let category = removed ? (phase % 4 == 1 ? "queued" : "active") : "review"
            tasks[i]["status_category"] = category;tasks[i]["status_id"] = category;tasks[i]["status_name"] = category == "review" ? "Review" : category == "queued" ? "Queued" : "In progress"
            tasks[i]["updated_at"] = "2026-10-17T21:45:\(String(format:"%02d",phase%60))Z"
        }
        for i in groups.indices where groups[i]["id"] as? String == fixture["group_id"] as? String {
            if removed { groups[i]["task_ids"] = (groups[i]["task_ids"] as? [String] ?? []).filter { $0 != fixture["task_id"] as? String } }
        }
        snapshot["tasks"] = tasks;snapshot["groups"] = groups
        snapshot["attempts"] = [["id":"replay-attempt", "task_id":fixture["task_id"] as? String ?? "", "phase":"implementation", "state":removed ? "active" : "released", "checkpoint":["progress":"Idle source snapshot \(phase)"], "revision":phase+1]]
        snapshot["task_sessions"] = [["task_id":fixture["task_id"] as? String ?? "", "session_id":"replay-session", "state":removed ? "current" : "prior", "last_checkpoint_at":"2026-10-17T21:45:00Z"]]
        return snapshot
    }
    var tasks: [[String: Any]] = []
    for i in 0..<23 {
        let removed = i == 0 && (phase % 4 == 1 || phase % 4 == 2)
        let category = i < 8 && !removed ? "review" : (removed && phase % 4 == 2 ? "active" : "queued")
        tasks.append(["id":"task-\(i)","project_id":"synthetic-project","key":"SYN-\(i)","title":"Synthetic production ticket \(i): long stable wrapped title for live Triage membership deletion and ordinary status regrouping", "kind":"work","readiness":"ready","status_id":category,"status_name":category == "review" ? "Review" : category == "active" ? "In progress" : "Queued", "status_category":category,"revision":phase+1,"order":i,"created_at":"2026-10-17T10:00:00Z","updated_at":i == 0 ? "2026-10-17T12:00:\(String(format:"%02d",phase%60))Z" : "2026-10-17T11:00:00Z"])
    }
    let ids = (0..<8).filter { !($0 == 0 && (phase % 4 == 1 || phase % 4 == 2)) }.map { "task-\($0)" }
    let group: [String: Any] = ["id":"synthetic-triage","project_id":"synthetic-project","kind":"triage","name":"Review: eight synthetic foundation tasks","phase":"review","purpose":"Independent review of exact synthetic submitted targets. Complete passing cases separately; rework only failed cases. This disposable replay reproduces a live eight-to-seven member deletion across a nested lazy-list viewport boundary.","task_ids":ids,"revision":phase+1]
    return ["tasks":tasks,"groups":[group],"messages":[],"attempts":[["id":"replay-attempt","task_id":"task-0","state":phase%4 == 2 ? "active":"released","phase":"implementation","checkpoint":["progress":"Idle source snapshot \(phase)"],"revision":phase+1]],"task_sessions":[["task_id":"task-0","session_id":"replay-session","state":phase%4 == 2 ? "current":"prior"]]]
}

final class Heartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func beat() { lock.lock(); value = Date(); lock.unlock() }
    func age() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return -value.timeIntervalSinceNow }
}

@main struct Replay {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let fixture = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) { exactFixture = try! JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:fixture))) as? [String: Any] }
        validateRowIdentity()
        if CommandLine.arguments.contains("--projection-only") { return }
        UserDefaults.standard.setVolatileDomain(["expandedTriages":[exactFixture?["group_id"] as? String ?? "synthetic-triage"]], forName: UserDefaults.argumentDomain)
        let store = ChecklistStore(); store.data = syntheticSnapshot(0)
        if let project = exactFixture?["project_id"] as? String { store.projectID = project }
        let host = NSHostingView(rootView: ReplayRoot().environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: -5000,y: 100,width:1240,height:820), styleMask:[.titled,.resizable], backing:.buffered, defer:false)
        window.contentView = host
        window.orderFront(nil)
        let heartbeat = Heartbeat()
        var phase = 0
        var peakHeight: CGFloat = 0
        let limit = 80
        func ticketFrames(_ value: Any, depth: Int = 0) -> [NSRect] {
            guard depth < 50, let element = value as? NSAccessibilityProtocol else { return [] }
            let own = (element.accessibilityIdentifier() ?? "").hasPrefix("taskRow-") ? [element.accessibilityFrame()] : []
            return own + (element.accessibilityChildren() ?? []).flatMap { ticketFrames($0, depth: depth + 1) }
        }
        func scrollViews(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map {[$0]} ?? view.subviews.flatMap(scrollViews) }
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<250 {
                Thread.sleep(forTimeInterval: 0.1)
                if heartbeat.age() > 2.5 {
                    fputs("RED: main run-loop stalled during live nested membership replay\n",stderr)
                    let sampler = Process();sampler.executableURL = URL(fileURLWithPath:"/usr/bin/sample");sampler.arguments = [String(getpid()),"1","1","-file","/tmp/checklist-layout-replay-stall.sample.txt"];try? sampler.run();sampler.waitUntilExit();exit(2)
                }
            }
            fputs("RED: replay exceeded bounded 25-second deadline\n",stderr);exit(3)
        }
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { timer in
            MainActor.assumeIsolated {
            heartbeat.beat()
            phase += 1
            if phase > limit {
                timer.invalidate()
                withTransaction(Transaction(animation: nil)) { store.sidebarVisible = true; store.data = syntheticSnapshot(0) }
                DispatchQueue.main.asyncAfter(deadline: .now()+0.75) {
                    host.layoutSubtreeIfNeeded()
                    if let scroll = scrollViews(host).first { scroll.contentView.scroll(to:.zero); scroll.reflectScrolledClipView(scroll.contentView) }
                    DispatchQueue.main.asyncAfter(deadline: .now()+0.75) {
                        host.layoutSubtreeIfNeeded()
                        if let scroll = scrollViews(host).first {
                            print("SETTLED: fixture phase0, sidebar visible, expanded1, viewport \(scroll.contentSize), document \(scroll.documentView?.frame.size ?? .zero), origin \(scroll.contentView.bounds.origin)")
                        }
                        let frames = ticketFrames(host)
                        print("AX laid-out ticket rows \(frames.count), height range \(frames.map(\.height).min() ?? 0)...\(frames.map(\.height).max() ?? 0)")
                        print("GREEN: \(limit) live membership/status/session/checkpoint snapshots completed with responsive main run-loop, peak document height \(peakHeight), scroll stress \(CommandLine.arguments.contains("--scroll-stress")), width stress \(CommandLine.arguments.contains("--animated-width"))");fflush(stdout);exit(0)
                    }
                }
                return
            }
            let scroll = scrollViews(host).first
            if CommandLine.arguments.contains("--scroll-stress"), let scroll, let document = scroll.documentView {
                let available = max(0,document.frame.height-scroll.contentSize.height)
                let positions: [CGFloat] = [0.247,0.5,0.9,0.1,0]
                let fraction = positions[(phase/4)%positions.count]
                scroll.contentView.scroll(to:NSPoint(x:0,y:available*fraction));scroll.reflectScrolledClipView(scroll.contentView)
            }
            if CommandLine.arguments.contains("--animated-width") && phase % 3 == 0 {
                withAnimation(.easeInOut(duration:0.2)) { store.sidebarVisible.toggle() }
            }
            store.data = syntheticSnapshot(phase)
            store.connected = true
            store.viewGroupBy = "status"
            store.viewOrderBy = "manual"
            host.layoutSubtreeIfNeeded()
            peakHeight = max(peakHeight,scroll?.documentView?.frame.height ?? 0)
            if phase == 1 || phase % 20 == 0 { print("snapshot \(phase), scroll views \(scrollViews(host).count), document \(scroll?.documentView?.frame.size ?? .zero), viewport \(scroll?.contentSize ?? .zero)");fflush(stdout) }
            }
        }
        app.run()
    }
}
