import Foundation

/// CL-126: the app view of a Triage's orchestrator (CL-269 contract). It reads
/// service fields only; grouping never grants work authority or a model launch.
struct TriageOrchestratorDisplay: Equatable {
    enum State: Equatable { case planned, working, idle, needsRecovery, finished }
    let state: State
    /// The conversation name, or "<Provider> · <short thread id>"; nil for a plan.
    let orchestrator: String?
    /// The current orchestrator session; empty when the Triage has none.
    let sessionID: String

    init(_ triage: Record) {
        let orchestration = Record(values: triage.object("orchestration"))
        let orchestrator = Record(values: triage.object("orchestrator"))
        let recorded = orchestration.string("state")
        let session = Self.first(orchestrator.string("session_id"), orchestration.string("session_id"))
        let active = recorded == "active" || (recorded.isEmpty && !orchestrator.string("session_id").isEmpty)
        guard active else {
            self.orchestrator = nil; sessionID = ""
            state = recorded == "finished" && (triage.bool("archived") || Self.memberCount(triage) == 0) ? .finished : .planned
            return
        }
        sessionID = session
        self.orchestrator = Self.conversationLabel(provider: Self.first(orchestrator.string("provider"), orchestration.string("provider")),
            display: Self.first(orchestrator.string("actor_display"), orchestration.string("actor_display")), sessionID: session)
        if triage.string("orchestration_connection") == "recovery_required" { state = .needsRecovery }
        else { state = Self.workingCount(triage) > 0 ? .working : .idle }
    }

    var stateLabel: String {
        switch state {
        case .planned: return "Planned"
        case .working: return "Working"
        case .idle: return "Idle"
        case .needsRecovery: return "Needs recovery"
        case .finished: return "Finished"
        }
    }
    /// One line for the row text and its accessibility label.
    var summary: String { orchestrator.map { "\($0) · \(stateLabel)" } ?? stateLabel }
    /// Plain route state for the Triage detail. A missing reply is never failure.
    var routeState: String {
        switch state {
        case .planned: return "No orchestrator. A Triage note is saved for pickup until an orchestrator starts this Triage."
        case .working: return "Connected. Its tickets have work in progress. Triage notes and ticket notes reach this conversation."
        case .idle: return "Connected. No ticket in this Triage is in progress. Triage notes and ticket notes reach this conversation."
        case .needsRecovery: return "The orchestrator's connection needs recovery. Notes are saved and wait until it reconnects or another conversation takes over this Triage."
        case .finished: return "Orchestration finished. No conversation receives notes for this Triage."
        }
    }

    /// The contract's default name is "<Provider> · <short thread id>".
    static func conversationLabel(provider: String, display: String, sessionID: String) -> String {
        let name = display.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, UUID(uuidString: name) == nil { return name }
        let trimmed = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerName = trimmed.isEmpty ? "Agent" : trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        return sessionID.isEmpty ? providerName : "\(providerName) · \(sessionID.prefix(8))"
    }

    struct StatusCount: Equatable { let label: String; let count: Int }
    private static let categoryOrder = ["draft", "queued", "active", "review", "parked", "done", "canceled"]
    static func categoryLabel(_ category: String) -> String {
        switch category {
        case "draft": return "Draft"
        case "queued": return "Queued"
        case "active": return "In progress"
        case "review": return "Review"
        case "parked": return "Parked"
        case "done", "completed": return "Done"
        case "canceled": return "Canceled"
        default: return "Other status"
        }
    }
    /// Ticket counts by status: the page summary's named counts, else the
    /// full projection's counts by status category.
    static func statusCounts(_ triage: Record) -> [StatusCount] {
        var rows: [(rank: Int, label: String, count: Int)] = []
        let named = triage.records("member_status_counts")
        if !named.isEmpty {
            for row in named where row.integer("count", fallback: 0) > 0 {
                let category = row.string("category")
                let name = row.string("name").trimmingCharacters(in: .whitespacesAndNewlines)
                rows.append((categoryOrder.firstIndex(of: category) ?? categoryOrder.count, name.isEmpty ? categoryLabel(category) : name, row.integer("count", fallback: 0)))
            }
        } else {
            for (category, value) in triage.object("member_counts_by_status") {
                guard let count = (value as? NSNumber)?.intValue, count > 0 else { continue }
                rows.append((categoryOrder.firstIndex(of: category) ?? categoryOrder.count, categoryLabel(category), count))
            }
        }
        return rows.sorted { ($0.rank, $0.label) < ($1.rank, $1.label) }.map { StatusCount(label: $0.label, count: $0.count) }
    }
    static func statusCountsText(_ triage: Record) -> String {
        statusCounts(triage).map { "\($0.count) \($0.label)" }.joined(separator: " · ")
    }

    private static func first(_ values: String...) -> String { values.first { !$0.isEmpty } ?? "" }
    private static func memberCount(_ triage: Record) -> Int {
        triage.values["member_count"] != nil ? triage.integer("member_count", fallback: 0) : triage.strings("task_ids").count
    }
    private static func workingCount(_ triage: Record) -> Int {
        if let working = triage.values["member_working_count"] as? NSNumber { return working.intValue }
        if let named = triage.values["member_status_counts"] as? [[String: Any]] {
            return named.filter { $0["category"] as? String == "active" }.reduce(0) { $0 + (($1["count"] as? NSNumber)?.intValue ?? 0) }
        }
        return (triage.object("member_counts_by_status")["active"] as? NSNumber)?.intValue ?? 0
    }
}

/// CL-126/CL-248: who receives an ordinary ticket note. Both is the default
/// and the service default, so it is never sent as a parameter.
enum NoteAudience: String, CaseIterable, Identifiable {
    case all, holder, orchestrator
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "Both"
        case .holder: return "Holder only"
        case .orchestrator: return "Orchestrator only"
        }
    }
    static let alwaysBothReason = "Owner directions always go to both the holder and the orchestrator, as do request answers, review verdicts, takeover, handoff and work-health notices."
    static let taggedNoteReason = "A note that tags a conversation uses its tag route; this choice applies to untagged notes."
    /// Owner directions and mention plans cannot be narrowed: the service refuses
    /// `audience` with `mention_target` (CL-248), so a tagged note omits it.
    func effective(ownerDirection: Bool, mentionPlan: Bool = false) -> NoteAudience { ownerDirection || mentionPlan ? .all : self }
    var parameter: String? { self == .all ? nil : rawValue }
    func unavailableReason(hasOrchestrator: Bool) -> String? {
        self == .orchestrator && !hasOrchestrator ? "This ticket's Triage has no orchestrator. Choose Both or Holder only." : nil
    }
    /// The composer destination for the selected audience.
    func destination(holder: String, orchestrator: String?) -> String {
        guard let orchestrator else { return holder }
        switch self {
        case .all: return "\(holder) and \(orchestrator)"
        case .holder: return holder
        case .orchestrator: return orchestrator
        }
    }
}

/// The audience choice and the orchestrator a ticket draft was written for.
/// Kept in the window preferences, so they survive switching, close and reopen
/// and a service reconnect exactly as the note draft itself does.
struct TicketNoteRouting {
    let preferences: UserDefaults
    private func audienceKey(_ taskID: String) -> String { "noteAudience-" + taskID }
    private func orchestratorKey(_ taskID: String) -> String { "noteOrchestrator-" + taskID }
    func audience(_ taskID: String) -> NoteAudience { NoteAudience(rawValue: preferences.string(forKey: audienceKey(taskID)) ?? "") ?? .all }
    func setAudience(_ audience: NoteAudience, for taskID: String) {
        if audience == .all { preferences.removeObject(forKey: audienceKey(taskID)) } else { preferences.set(audience.rawValue, forKey: audienceKey(taskID)) }
    }
    /// Bind (or confirm) the destination orchestrator for the current draft.
    func bind(_ taskID: String, orchestrator: String) { preferences.set(orchestrator, forKey: orchestratorKey(taskID)) }
    func clearDestination(_ taskID: String) { preferences.removeObject(forKey: orchestratorKey(taskID)) }
    /// A draft written for one orchestrator is never silently sent to another.
    func orchestratorChanged(_ taskID: String, current: String, hasDraft: Bool) -> Bool {
        guard hasDraft, let expected = preferences.string(forKey: orchestratorKey(taskID)) else { return false }
        return !expected.utf8.elementsEqual(current.utf8)
    }
}

/// A Triage note draft, bound to its Triage, store and orchestrator.
struct TriageNoteDraft: Equatable {
    var body: String
    var storeIncarnation: String
    var projectID: String
    var orchestratorSessionID: String
}

struct TriageNoteDrafts {
    let preferences: UserDefaults
    static func key(_ triageID: String) -> String { "triageNoteDraft-" + triageID }
    func draft(_ triageID: String) -> TriageNoteDraft? {
        guard let value = preferences.dictionary(forKey: Self.key(triageID)) as? [String: String], let body = value["body"], !body.isEmpty else { return nil }
        return TriageNoteDraft(body: body, storeIncarnation: value["store"] ?? "", projectID: value["project"] ?? "", orchestratorSessionID: value["orchestrator"] ?? "")
    }
    /// Text changes keep the destination the draft was started for.
    func save(_ triageID: String, body: String, storeIncarnation: String, projectID: String, orchestrator: String) {
        guard !body.isEmpty else { clear(triageID); return }
        let bound = draft(triageID)
        write(triageID, TriageNoteDraft(body: body, storeIncarnation: bound?.storeIncarnation ?? storeIncarnation,
            projectID: bound?.projectID ?? projectID, orchestratorSessionID: bound?.orchestratorSessionID ?? orchestrator))
    }
    func confirm(_ triageID: String, storeIncarnation: String, projectID: String, orchestrator: String) {
        guard var current = draft(triageID) else { return }
        current.storeIncarnation = storeIncarnation; current.projectID = projectID; current.orchestratorSessionID = orchestrator
        write(triageID, current)
    }
    func needsConfirmation(_ triageID: String, storeIncarnation: String, projectID: String, orchestrator: String) -> Bool {
        guard let current = draft(triageID) else { return false }
        return !current.orchestratorSessionID.utf8.elementsEqual(orchestrator.utf8) || !current.storeIncarnation.utf8.elementsEqual(storeIncarnation.utf8)
            || !current.projectID.utf8.elementsEqual(projectID.utf8)
    }
    func clear(_ triageID: String) { preferences.removeObject(forKey: Self.key(triageID)) }
    private func write(_ triageID: String, _ draft: TriageNoteDraft) {
        preferences.set(["body": draft.body, "store": draft.storeIncarnation, "project": draft.projectID, "orchestrator": draft.orchestratorSessionID], forKey: Self.key(triageID))
    }
}

/// One combined, paged list of Triage notes and member ticket notes, oldest
/// first. Each source pages with its own history cursor; a message shows only
/// when no unread page of another source can hold an older one.
@MainActor final class TriageMessageFeed: ObservableObject {
    struct Source: Equatable { let field: String; let id: String; let ticketKey: String }
    typealias Request = (String, [String: Any]) async throws -> [String: Any]
    static let pageSize = 50
    static let maximumSources = 100
    @Published private(set) var messages: [Record] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var hasMore = false
    private(set) var sources: [Source] = []
    private var buffers: [String: [Record]] = [:]
    private var cursors: [String: String] = [:]
    private var more: [String: Bool] = [:]
    private var frontiers: [String: String] = [:]
    private var projectID = ""
    private var generation = UUID()

    func load(projectID: String, triageID: String, members: [(id: String, key: String)], request: Request) async {
        let read = UUID(); generation = read
        self.projectID = projectID
        sources = [Source(field: "triage_id", id: triageID, ticketKey: "")] + members.prefix(Self.maximumSources).map { Source(field: "task_id", id: $0.id, ticketKey: $0.key) }
        buffers = [:]; cursors = [:]; more = [:]; frontiers = [:]; messages = []; hasMore = false; error = nil
        await fetch(sources, read: read, request: request)
    }
    func loadMore(request: Request) async {
        guard !loading else { return }
        let read = UUID(); generation = read
        await fetch(sources.filter { more[$0.id] == true }, read: read, request: request)
    }
    /// The ticket key an orchestrator copy names, or empty for a Triage note.
    func ticketKey(_ message: Record) -> String {
        sources.first { $0.field == "task_id" && $0.id.utf8.elementsEqual(message.string("task_id").utf8) }?.ticketKey ?? ""
    }
    private func fetch(_ selected: [Source], read: UUID, request: Request) async {
        loading = true; error = nil
        defer { if generation == read { loading = false } }
        do {
            for source in selected {
                var params: [String: Any] = ["project_id": projectID, source.field: source.id, "limit": Self.pageSize]
                if let cursor = cursors[source.id] { params["cursor"] = cursor }
                let result = try await request("history_list", params)
                guard generation == read, !Task.isCancelled else { return }
                let rows = (result["messages"] as? [[String: Any]] ?? []).map(Record.init).filter {
                    source.field == "task_id" ? $0.string("task_id").utf8.elementsEqual(source.id.utf8)
                        : $0.string("task_id").isEmpty && $0.string("triage_id").utf8.elementsEqual(source.id.utf8)
                }
                buffers[source.id, default: []].append(contentsOf: rows)
                cursors[source.id] = result["next_cursor"] as? String
                more[source.id] = result["has_more"] as? Bool ?? false
                let lastEvent = (result["events"] as? [[String: Any]])?.last?["occurred_at"] as? String
                frontiers[source.id] = lastEvent ?? rows.last?.string("created_at") ?? frontiers[source.id] ?? ""
            }
            rebuild()
            await loadReceipts(read: read, request: request)
        } catch {
            guard generation == read, !Task.isCancelled else { return }
            self.error = "Messages could not be loaded. " + PlainError.text(error)
        }
    }
    /// `history_list` returns note bodies without receipts (docs/mcp-contract.md), so each
    /// shown note reads its own receipts with `message_delivery_list` (CL-248 wire format:
    /// `task_id` for a ticket note, `triage_id` for a ticket-free Triage note). A failed read
    /// marks the note `receipt_unavailable`; the row never guesses a state.
    private func loadReceipts(read: UUID, request: Request) async {
        let pending = messages.filter { $0.values["deliveries"] == nil && $0.values["receipt_unavailable"] == nil }
        guard !pending.isEmpty else { return }
        for message in pending {
            let taskID = message.string("task_id")
            var params: [String: Any] = ["project_id": projectID, "message_id": message.id]
            if taskID.isEmpty { params["triage_id"] = message.string("triage_id") } else { params["task_id"] = taskID }
            var values = message.values
            do {
                let result = try await request("message_delivery_list", params)
                values["deliveries"] = result["deliveries"] as? [[String: Any]] ?? []
                if let status = result["delivery_status"] as? String { values["delivery_status"] = status }
            } catch { values["receipt_unavailable"] = true }
            guard generation == read, !Task.isCancelled else { return }
            for key in buffers.keys {
                if let index = buffers[key]?.firstIndex(where: { $0.id.utf8.elementsEqual(message.id.utf8) }) { buffers[key]?[index] = Record(values: values) }
            }
        }
        rebuild()
    }
    private func rebuild() {
        var seen = Set<String>(), merged: [Record] = []
        for source in sources { for message in buffers[source.id] ?? [] where seen.insert(message.id).inserted { merged.append(message) } }
        merged = DeliveryLabels.correlateReplies(merged)
        merged.sort { ($0.string("created_at"), $0.id) < ($1.string("created_at"), $1.id) }
        let pending = sources.filter { more[$0.id] == true }
        hasMore = !pending.isEmpty
        if let frontier = pending.map({ frontiers[$0.id] ?? "" }).min() {
            messages = merged.filter { $0.string("created_at") <= frontier }
        } else {
            messages = merged
        }
    }
}

/// The orchestrator copy label of a ticket note (CL-248 wire format), or a
/// label built from the holder's own delivery when the service sent none.
enum TriageCopyLabel {
    static func text(_ message: Record, ticketKey: String) -> String? {
        let deliveries = message.records("deliveries")
        guard let copy = deliveries.first(where: { $0.string("recipient_role") == "triage_orchestrator" }) else { return nil }
        let label = copy.string("label").trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty { return label }
        guard !ticketKey.isEmpty, let holder = deliveries.first(where: { ["handler", "registered_child"].contains($0.string("recipient_role")) }) else { return nil }
        let display = holder.string("recipient_display").isEmpty ? holder.string("recipient_label") : holder.string("recipient_display")
        let name = TriageOrchestratorDisplay.conversationLabel(provider: holder.string("recipient_provider"), display: display, sessionID: holder.string("recipient_session_id"))
        return "Also sent to \(name), which holds \(ticketKey)."
    }
}
