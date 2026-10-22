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
    private var activeRequest: Request?
    private var installedToken = UUID()
    private var preparation: (token: UUID, expansion: TicketWorkspaceExpansion, value: PreparedTicketWorkspace)?

    mutating func begin(query: TicketPageQuery, cursor: String? = nil) -> Request {
        let expectedKey = cursor != nil && self.query == query ? page.map { RecordIdentity($0.queryKey) } : nil
        if self.query != query {
            page = nil
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

    mutating func invalidate() {
        activeRequest = nil
        page = nil
        query = nil
        preparation = nil
        installedToken = UUID()
        loading = false
        error = nil
    }

    /// Call at the page/expansion install boundary; publish its returned plain
    /// value. This never reads or changes Store.data or the full-index preparation.
    mutating func prepared(expansion: TicketWorkspaceExpansion) -> PreparedTicketWorkspace? {
        guard let page, let query else { return nil }
        if let preparation, preparation.token == installedToken, preparation.expansion == expansion {
            return preparation.value
        }
        let sections = page.triages.map { summary in
            // This is explicitly NOT complete membership. The composing view must
            // honor members_complete:false and fetch/revalidate before group writes.
            InlineTriageSection(triage: summary, allMembers: [],
                visibleMembers: summary.strings("page_member_ids").compactMap(page.task), matchesGroupSearch: false)
        }
        let ordinary = page.ordinaryIDs.compactMap(page.task)
        let list = TicketListProjection(ordinaryTickets: ordinary, triages: sections,
            visibleTicketCount: page.matchedCount, scopedTicketCount: page.scopedCount)
        guard let groups = Self.groups(ordinary, query: query, epics: page.epics) else {
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

    private static func groups(_ tasks: [Record], query: TicketPageQuery, epics: [Record]) -> [(String, [Record])]? {
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
                guard seen.insert(label).inserted else { return nil }
                result.append((label, [task]))
            }
        }
        // Service order is authoritative for this display read. No local sorting,
        // corpus search/filter or merging of previously loaded pages occurs here.
        return result
    }
}
