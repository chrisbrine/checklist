import Foundation

enum TicketWorkspaceSurface: Equatable {
    case overview, tickets, archived

    init?(_ page: Page) {
        switch page {
        // The Overview groups by need (CL-53) from its own small pages, not the ticket list.
        case .tasks: self = .tickets
        case .archived: self = .archived
        default: return nil
        }
    }
}

struct TicketWorkspaceQuery: Equatable {
    let surface: TicketWorkspaceSurface
    let projectID: String?
    let rawSearch: String
    let statusFilter: String
    let tagFilter: String

    static func == (left: Self, right: Self) -> Bool {
        left.surface == right.surface &&
        left.projectID.map(RecordIdentity.init) == right.projectID.map(RecordIdentity.init) &&
        left.rawSearch == right.rawSearch &&
        RecordIdentity(left.statusFilter) == RecordIdentity(right.statusFilter) &&
        RecordIdentity(left.tagFilter) == RecordIdentity(right.tagFilter)
    }

    var hasFilters: Bool {
        statusFilter != "all" || tagFilter != "all" || !rawSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct TicketWorkspaceOrdering: Equatable {
    enum Grouping: Equatable { case status, epic, none }
    enum Order: Equatable { case manual, priority, updated }
    let grouping: Grouping
    let order: Order

    init(groupBy: String, orderBy: String) {
        grouping = groupBy == "none" ? .none : groupBy == "epic" ? .epic : .status
        order = orderBy == "updated_desc" ? .updated : orderBy == "priority" ? .priority : .manual
    }
}

struct TicketWorkspaceExpansion: Equatable {
    struct Override {
        let id: String
        let expanded: Bool
    }
    private let expandedValues: [String]
    private let overrideValues: [Override]

    // Preserve byte-distinct IDs before constructing the unordered identity key.
    init(expandedIDValues: [String], overrideValues: [Override] = []) {
        self.expandedValues = expandedIDValues
        self.overrideValues = overrideValues
    }
    init(expandedIDs: RecordIdentitySet, filteredOverrides: [RecordIdentity: Bool]) {
        expandedValues = expandedIDs.values
        overrideValues = []
        exactOverrides = filteredOverrides
    }
    private var exactOverrides: [RecordIdentity: Bool] = [:]

    // Compatibility for legacy consumers only. The new view hook uses the exact
    // producer above. A String Set/Dictionary may
    // already have collapsed aliases; that producer remains a composition gate.
    init(expandedIDs: Set<String> = [], filteredOverrides: [String: Bool] = [:]) {
        self.init(expandedIDValues: Array(expandedIDs), overrideValues: filteredOverrides.map { Override(id: $0.key, expanded: $0.value) })
    }
    private var expandedKeys: Set<RecordIdentity> {
        Set(expandedValues.map(RecordIdentity.init))
    }
    private var overrideKeys: [RecordIdentity: Bool] {
        var result = exactOverrides
        for entry in overrideValues { result[RecordIdentity(entry.id)] = entry.expanded }
        return result
    }
    static func == (left: Self, right: Self) -> Bool {
        left.expandedKeys == right.expandedKeys && left.overrideKeys == right.overrideKeys
    }
    func expanded(_ section: InlineTriageSection, filtered: Bool) -> Bool {
        let id = RecordIdentity(section.id)
        if !filtered { return expandedKeys.contains(id) }
        return overrideKeys[id] ?? (!section.visibleMembers.isEmpty || section.matchesGroupSearch || expandedKeys.contains(id))
    }
}

struct TicketWorkspaceRequest: Equatable {
    let snapshotEpoch: UInt64
    let query: TicketWorkspaceQuery
    let ordering: TicketWorkspaceOrdering
    let expansion: TicketWorkspaceExpansion
}

struct PreparedTicketWorkspace {
    let list: TicketListProjection
    let visibleTicketIDs: RecordIdentitySet
    let ordinaryGroups: [(String, [Record])]
    let overviewRequests: [Record]
    let rows: [TicketListRow]
    let hasTasks: Bool
    let hasProjects: Bool
}

/// One current prepared value. Mutation belongs at the install/input boundary;
/// reading `prepared` never computes a projection or changes view state.
struct TicketWorkspacePreparation {
    struct Rebuilt: Equatable {
        let base: Bool
        let ordering: Bool
        let rows: Bool
        static let none = Rebuilt(base: false, ordering: false, rows: false)
    }

    private struct Current {
        let request: TicketWorkspaceRequest
        let value: PreparedTicketWorkspace
        let epicNames: [RecordIdentity: String]
    }
    private var current: Current?
    var prepared: PreparedTicketWorkspace? { current?.value }

    mutating func reset() { current = nil }

    @discardableResult
    mutating func prepare(snapshot: SnapshotRecordIndex, request: TicketWorkspaceRequest) -> Rebuilt {
        guard current?.request != request else { return .none }
        let old = current
        let rebuildBase = old == nil || old?.request.snapshotEpoch != request.snapshotEpoch || old?.request.query != request.query
        let rebuildOrdering = rebuildBase || old?.request.ordering != request.ordering

        let list: TicketListProjection
        let visibleIDs: RecordIdentitySet
        let requests: [Record]
        let epicNames: [RecordIdentity: String]
        let hasTasks: Bool
        let hasProjects: Bool
        if rebuildBase {
            let tasks = snapshot.records(in: "tasks")
            let projects = snapshot.records(in: "projects")
            let groups = snapshot.records(in: "groups")
            var projectLabels: [RecordIdentity: String] = [:]
            for project in projects where projectLabels[RecordIdentity(project.id)] == nil { projectLabels[RecordIdentity(project.id)] = project.string("name") }
            var epics: [RecordIdentity: String] = [:]
            for group in groups where epics[RecordIdentity(group.id)] == nil { epics[RecordIdentity(group.id)] = ProductionGroups.label(group) }
            let query = request.query
            list = TicketListProjection.make(tasks: tasks, groups: groups, messages: snapshot.records(in: "messages"), projectID: query.projectID, archived: query.surface == .archived, statusFilter: query.statusFilter, tagFilter: query.tagFilter, search: query.rawSearch, includeTriages: query.surface != .overview, projectLabels: projectLabels)
            visibleIDs = RecordIdentitySet(tasks.filter { task in TicketVisibility.includes(task, showingClosed: query.surface == .archived) && (query.projectID.map { RecordIdentity(task.string("project_id")) == RecordIdentity($0) } ?? true) }.map(\.id))
            requests = Self.overviewRequests(snapshot: snapshot, query: query)
            epicNames = epics
            hasTasks = !tasks.isEmpty
            hasProjects = !projects.isEmpty
        } else if let old {
            list = old.value.list
            visibleIDs = old.value.visibleTicketIDs
            requests = old.value.overviewRequests
            epicNames = old.epicNames
            hasTasks = old.value.hasTasks
            hasProjects = old.value.hasProjects
        } else {
            preconditionFailure("A first preparation must build its base.")
        }

        let ordered = rebuildOrdering ? Self.orderedGroups(list.ordinaryTickets, ordering: request.ordering, epicNames: epicNames) : old!.value.ordinaryGroups
        let expanded = RecordIdentitySet(list.triages.filter { request.expansion.expanded($0, filtered: request.query.hasFilters) }.map(\.id))
        let rows = TicketListRows.make(triages: list.triages, expandedRecordIDs: expanded, ordinaryGroups: ordered, requests: requests, showClearFilters: request.query.hasFilters && list.visibleTicketCount == 0)
        current = Current(request: request, value: PreparedTicketWorkspace(list: list, visibleTicketIDs: visibleIDs, ordinaryGroups: ordered, overviewRequests: requests, rows: rows, hasTasks: hasTasks, hasProjects: hasProjects), epicNames: epicNames)
        return Rebuilt(base: rebuildBase, ordering: rebuildOrdering, rows: true)
    }

    private static func overviewRequests(snapshot: SnapshotRecordIndex, query: TicketWorkspaceQuery) -> [Record] {
        guard query.surface == .overview else { return [] }
        return snapshot.records(in: "requests").filter { request in
            let inProject = query.projectID.map { RecordIdentity(request.string("project_id")) == RecordIdentity($0) } ?? true
            guard !["answered", "canceled", "superseded", "resolved"].contains(Canceled.normalized(request.string("state"))), inProject else { return false }
            let task = snapshot.record(in: "tasks", id: request.string("task_id"), projectID: request.string("project_id"))
            let project = snapshot.record(in: "projects", id: request.string("project_id"))
            return query.rawSearch.isEmpty || [request.string("title"), task?.string("key") ?? "", project?.string("name") ?? "Project"].joined(separator: " ").localizedCaseInsensitiveContains(query.rawSearch)
        }
    }

    private static func orderedGroups(_ tickets: [Record], ordering: TicketWorkspaceOrdering, epicNames: [RecordIdentity: String]) -> [(String, [Record])] {
        func ordered(_ rows: [Record]) -> [Record] {
            if ordering.order == .updated { return RecordOrdering.newestFirst(rows, timestamp: "updated_at") }
            let priority = ["urgent": 0, "high": 1, "normal": 2, "low": 3, "none": 4]
            return rows.sorted {
                if ordering.order == .priority, priority[$0.string("priority")] != priority[$1.string("priority")] { return (priority[$0.string("priority")] ?? 4) < (priority[$1.string("priority")] ?? 4) }
                if $0.integer("order") != $1.integer("order") { return $0.integer("order") < $1.integer("order") }
                return $0.string("created_at") == $1.string("created_at") ? $0.id < $1.id : $0.string("created_at") < $1.string("created_at")
            }
        }
        if ordering.grouping == .none { return [("Tickets", ordered(tickets))] }
        if ordering.grouping == .epic {
            return Dictionary(grouping: tickets) { epicNames[RecordIdentity($0.string("epic_id"))] ?? "No Epic" }.map { ($0.key, ordered($0.value)) }.sorted { $0.0 < $1.0 }
        }
        let order = ["active", "in_progress", "working", "review", "ready", "queued", "blocked", "parked", "draft", "done", "completed", "canceled"]
        let grouped = Dictionary(grouping: tickets, by: TicketVisibility.groupLabel)
        return grouped.map { ($0.key, ordered($0.value)) }.sorted {
            let left = order.firstIndex(of: $0.1.first.map(TicketVisibility.category) ?? "") ?? 99
            let right = order.firstIndex(of: $1.1.first.map(TicketVisibility.category) ?? "") ?? 99
            return left == right ? $0.0 < $1.0 : left < right
        }
    }
}
