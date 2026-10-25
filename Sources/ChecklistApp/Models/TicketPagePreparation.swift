import Foundation

/// A single visible page, not a query cache or a replacement snapshot. Store owns
/// publication and event coverage; local tokens only fence stale async read results.
struct TicketPagePreparation {
    struct Request: Equatable {
        let query: TicketPageQuery
        let cursor: String?
        fileprivate let token: UUID
        fileprivate let expectedQueryKey: RecordIdentity?
    }

    private(set) var page: TicketPage?
    private(set) var query: TicketPageQuery?
    private(set) var loading = false
    private(set) var error: String?
    // Display-only overlays belong to this accepted page, never a reusable cache.
    private var statusTasks: [RecordIdentity: Record] = [:]
    private var statusTriages: [RecordIdentity: Record] = [:]
    var displayedTasks: [Record] { page?.tasks.map { statusTasks[RecordIdentity($0.id)] ?? $0 } ?? [] }
    private var displayedTriages: [Record] { page?.triages.map { statusTriages[RecordIdentity($0.id)] ?? $0 } ?? [] }
    private var activeRequest: Request?
    private var installedToken = UUID()
    private var preparation: (token: UUID, expansion: TicketWorkspaceExpansion, value: PreparedTicketWorkspace)?

    mutating func begin(query: TicketPageQuery, cursor: String? = nil) -> Request {
        let expectedKey = cursor != nil && self.query == query ? page.map { RecordIdentity($0.queryKey) } : nil
        if self.query != query {
            page = nil
            statusTasks = [:]; statusTriages = [:]
            preparation = nil
        }
        self.query = query
        let request = Request(query: query, cursor: cursor, token: UUID(), expectedQueryKey: expectedKey)
        activeRequest = request
        loading = true
        error = nil
        return request
    }

    @discardableResult
    mutating func receive(_ page: TicketPage, for request: Request) -> Bool {
        guard activeRequest == request, query == request.query else { return false }
        if let expected = request.expectedQueryKey, expected != RecordIdentity(page.queryKey) {
            fail(request)
            return false
        }
        if let project = request.query.projectID {
            guard page.tasks.allSatisfy({ RecordIdentity($0.string("project_id")) == RecordIdentity(project) }),
                  page.triages.allSatisfy({ RecordIdentity($0.string("project_id")) == RecordIdentity(project) }),
                  page.overviewRequests.allSatisfy({ RecordIdentity($0.string("project_id")) == RecordIdentity(project) }) else {
                fail(request)
                return false
            }
        }
        guard request.query.surface == "overview" || (page.overviewRequests.isEmpty && page.overviewRequestCount == 0) else {
            fail(request)
            return false
        }
        self.page = page
        statusTasks = [:]; statusTriages = [:]
        installedToken = request.token
        preparation = nil
        activeRequest = nil
        loading = false
        error = nil
        return true
    }

    mutating func fail(_ request: Request) {
        guard activeRequest == request else { return }
        activeRequest = nil
        loading = false
        error = "Could not load the ticket page. Refresh the list."
    }

    /// Retire only this read, preserving the accepted page and its preparation.
    mutating func cancel(_ request: Request) {
        guard activeRequest == request else { return }
        activeRequest = nil
        loading = false
        error = nil
    }

    /// Keep the current request fence when its reply establishes a new service version.
    mutating func discardContent() { page = nil; statusTasks = [:]; statusTriages = [:]; preparation = nil; installedToken = UUID() }

    mutating func invalidate() {
        activeRequest = nil
        page = nil
        statusTasks = [:]; statusTriages = [:]
        query = nil
        preparation = nil
        installedToken = UUID()
        loading = false
        error = nil
    }

    /// Patch known rows only. Complete current membership coverage can also
    /// derive a header; a partial page's visible members alone cannot do that.
    mutating func applyCommittedStatuses(_ updates: [(task: Record, triages: [Record])]) {
        guard page != nil else { return }
        func key(_ row: Record) -> ScopedRecordIdentity {ScopedRecordIdentity(projectID:row.string("project_id"),id:row.id)}
        let before = displayedTasks
        var changed = false
        for update in updates {
            guard let source = before.first(where: { key($0) == key(update.task) }),
                  update.task.integer("revision") > source.integer("revision") else { continue }
            let fields = update.task.values.filter { ["id","project_id","revision","status_id","status_name","status_category","archived","trashed"].contains($0.key) }
            statusTasks[RecordIdentity(source.id)] = Record(values:source.values.merging(fields) {_,new in new})
            changed = true
        }
        for summary in displayedTriages {
            let members = updates.compactMap { update -> (task: Record, membership: Record)? in
                guard RecordIdentity(update.task.string("project_id")) == RecordIdentity(summary.string("project_id")),
                      let membership = update.triages.first(where: {RecordIdentity($0.id) == RecordIdentity(summary.id)}) else {return nil}
                return (update.task,membership)
            }
            guard let first = members.first,
                  first.membership.integer("revision") >= summary.integer("revision"),
                  first.membership.integer("member_count") == summary.integer("member_count"),
                  members.count == first.membership.integer("member_count"),
                  Set(members.map {RecordIdentity($0.task.id)}).count == members.count,
                  members.allSatisfy({$0.membership.integer("revision") == first.membership.integer("revision") && $0.membership.integer("member_count") == members.count}),
                  Set(summary.strings("page_member_ids").map(RecordIdentity.init)).isSubset(of:Set(members.map {RecordIdentity($0.task.id)})) else {continue}
            let known = before.filter { row in members.contains {key($0.task) == key(row)} }
            guard known.contains(where: {row in members.contains {key($0.task) == key(row) && $0.task.integer("revision") > row.integer("revision")}}),
                  known.allSatisfy({row in members.contains {key($0.task) == key(row) && $0.task.integer("revision") >= row.integer("revision")}}) else {continue}
            let uniform = Set(members.map {RecordIdentity($0.task.string("status_id"))}).count == 1
            let fields: [String:Any] = ["revision":first.membership.integer("revision"),"status_state":uniform ? "uniform" : "mixed",
                "status_id":uniform ? first.task.string("status_id") : "", "status_name":uniform ? first.task.string("status_name") : "Mixed",
                "status_category":uniform ? first.task.string("status_category") : "mixed"]
            statusTriages[RecordIdentity(summary.id)] = Record(values:summary.values.merging(fields) {_,new in new})
            changed = true
        }
        if changed {preparation = nil;installedToken = UUID()}
        // Counts, membership, cursors and the accepted service page stay provisional
        // until receive replaces them. An overlay never inserts an unseen ticket.
    }

    /// Call at the page/expansion install boundary; publish its returned plain
    /// value. This never reads or changes Store.data or the full-index preparation.
    mutating func prepared(expansion: TicketWorkspaceExpansion) -> PreparedTicketWorkspace? {
        guard let page, let query else { return nil }
        if let preparation, preparation.token == installedToken, preparation.expansion == expansion {
            return preparation.value
        }
        let tasks = Dictionary(uniqueKeysWithValues: displayedTasks.map {(RecordIdentity($0.id),$0)})
        let sections = displayedTriages.map { summary in
            // This is explicitly NOT complete membership. The composing view must
            // honor members_complete:false and fetch/revalidate before group writes.
            InlineTriageSection(triage: summary, allMembers: [],
                visibleMembers: summary.strings("page_member_ids").compactMap {tasks[RecordIdentity($0)]}, matchesGroupSearch: false)
        }
        let ordinary = page.ordinaryIDs.compactMap {tasks[RecordIdentity($0)]}
        let list = TicketListProjection(ordinaryTickets: ordinary, triages: sections,
            visibleTicketCount: page.matchedCount, scopedTicketCount: page.scopedCount)
        guard let groups = Self.groups(ordinary, query: query, epics: page.epics, provisional: !statusTasks.isEmpty) else {
            error = "The ticket page order is invalid. Refresh the list."
            return nil
        }
        let expanded = RecordIdentitySet(sections.filter { expansion.expanded($0, filtered: query.hasFilters) }.map(\.id))
        let rows = TicketListRows.make(triages: sections, expandedRecordIDs: expanded, ordinaryGroups: groups,
            requests: page.overviewRequests,
            showClearFilters: query.hasFilters && page.matchedCount == 0)
        let value = PreparedTicketWorkspace(list: list, visibleTicketIDs: RecordIdentitySet(page.tasks.map(\.id)),
            ordinaryGroups: groups, overviewRequests: page.overviewRequests, rows: rows,
            hasTasks: page.scopedCount > 0, hasProjects: !page.projects.isEmpty)
        preparation = (installedToken, expansion, value)
        return value
    }

    private static func groups(_ tasks: [Record], query: TicketPageQuery, epics: [Record], provisional: Bool) -> [(String, [Record])]? {
        if query.groupBy == "none" { return tasks.isEmpty ? [] : [("Tickets", tasks)] }
        var epicLabels: [RecordIdentity: String] = [:]
        for epic in epics { epicLabels[RecordIdentity(epic.id)] = ProductionGroups.label(epic) }
        var result: [(String, [Record])] = []
        var seen: Set<String> = []
        for task in tasks {
            let label = query.groupBy == "epic" ? epicLabels[RecordIdentity(task.string("epic_id"))] ?? "No Epic" : TicketVisibility.groupLabel(task)
            if result.last?.0 == label { result[result.count - 1].1.append(task) }
            else {
                // Repeated nonadjacent headings would either duplicate SwiftUI IDs
                // or silently reorder server IDs. The emitter guarantees contiguity.
                if !seen.insert(label).inserted {
                    guard provisional, let index = result.firstIndex(where: {$0.0 == label}) else {return nil}
                    result[index].1.append(task)
                    continue
                }
                result.append((label, [task]))
            }
        }
        // Service order is authoritative for this display read. No local sorting,
        // corpus search/filter or merging of previously loaded pages occurs here.
        return result
    }
}
