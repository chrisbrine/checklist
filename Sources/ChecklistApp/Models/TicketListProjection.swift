import Foundation

struct InlineTriageSection: Identifiable {
    let triage: Record
    let allMembers: [Record]
    let visibleMembers: [Record]
    let matchesGroupSearch: Bool
    var id: String { triage.id }
    var totalCount: Int { triage.values["members_complete"] as? Bool == false ? triage.integer("member_count", fallback: 0) : RecordIdentitySet(triage.strings("task_ids")).count }
}

/// Builds one ticket list without duplicating records or losing group membership under filters.
struct TicketListProjection {
    let ordinaryTickets: [Record]
    let triages: [InlineTriageSection]
    let visibleTicketCount: Int
    let scopedTicketCount: Int

    static func make(tasks: [Record], groups: [Record], messages: [Record], projectID: String?, archived: Bool, statusFilter: String, tagFilter: String, search: String, includeTriages: Bool, projectNames: [String: String]) -> TicketListProjection {
        // Compatibility for existing callers. New snapshot consumers supply exact
        // labels before a String-keyed dictionary could collapse their IDs.
        let labels = Dictionary(uniqueKeysWithValues: projectNames.map { (RecordIdentity($0.key), $0.value) })
        return make(tasks: tasks, groups: groups, messages: messages, projectID: projectID, archived: archived, statusFilter: statusFilter, tagFilter: tagFilter, search: search, includeTriages: includeTriages, projectLabels: labels)
    }

    static func make(tasks: [Record], groups: [Record], messages: [Record], projectID: String?, archived: Bool, statusFilter: String, tagFilter: String, search: String, includeTriages: Bool, projectLabels: [RecordIdentity: String]) -> TicketListProjection {
        func key(_ record: Record) -> ScopedRecordIdentity { ScopedRecordIdentity(projectID: record.string("project_id"), id: record.id) }
        func inProject(_ record: Record) -> Bool { projectID.map { RecordIdentity(record.string("project_id")) == RecordIdentity($0) } ?? true }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasFacets = statusFilter != "all" || tagFilter != "all"
        let notesByTask = query.isEmpty ? [:] : Dictionary(grouping: messages, by: { ScopedRecordIdentity(projectID: $0.string("project_id"), id: $0.string("task_id")) })
        let activeTriageMembers = Set(groups.filter { $0.string("kind") == "triage" && !$0.bool("archived") && $0.bool("active_attention") }.flatMap { group in group.strings("task_ids").map { ScopedRecordIdentity(projectID: group.string("project_id"), id: $0) } })
        // The legacy archived parameter selects the explicit Done / Archived surface.
        let scope = tasks.filter { TicketVisibility.includes($0, showingClosed: archived) && inProject($0) }
        let facets = scope.filter { task in
            let statusMatches = TicketVisibility.matchesStatus(task, filter: statusFilter, activeTriageMember: activeTriageMembers.contains(key(task)))
            return statusMatches && (tagFilter == "all" || task.strings("tag_ids").contains { RecordIdentity($0) == RecordIdentity(tagFilter) })
        }
        func matches(_ task: Record) -> Bool {
            query.isEmpty || ([task.string("title"), task.string("key"), task.string("brief"), projectLabels[RecordIdentity(task.string("project_id"))] ?? ""] + (notesByTask[key(task)] ?? []).map { $0.string("body") }).joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
        let scopeIDs = Set(scope.map(key))
        func groupHasScopedMember(_ group: Record, in ids: Set<ScopedRecordIdentity>) -> Bool {
            group.strings("task_ids").contains { ids.contains(ScopedRecordIdentity(projectID: group.string("project_id"), id: $0)) }
        }
        let selectedTriages = includeTriages ? groups.filter { $0.string("kind") == "triage" && !$0.strings("task_ids").isEmpty && groupHasScopedMember($0, in: scopeIDs) && (archived || !$0.bool("archived")) && inProject($0) } : []
        let membershipIDs = Set(selectedTriages.flatMap { group in group.strings("task_ids").map { ScopedRecordIdentity(projectID: group.string("project_id"), id: $0) } })
        let sections: [InlineTriageSection] = selectedTriages.compactMap { triage in
            let ids = Set(triage.strings("task_ids").map { ScopedRecordIdentity(projectID: triage.string("project_id"), id: $0) })
            let groupMatches = !query.isEmpty && [triage.string("key"), triage.string("name"), triage.string("purpose"), projectLabels[RecordIdentity(triage.string("project_id"))] ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(query)
            let all = tasks.filter { ids.contains(key($0)) }
            let visible = facets.filter { ids.contains(key($0)) && (groupMatches || matches($0)) }
            if archived && !scope.contains(where: { ids.contains(key($0)) }) { return nil }
            if visible.isEmpty && !groupMatches && (hasFacets || !query.isEmpty) { return nil }
            return InlineTriageSection(triage: triage, allMembers: all, visibleMembers: RecordOrdering.newestFirst(visible, timestamp: "updated_at"), matchesGroupSearch: groupMatches)
        }.sorted { left, right in
            let order = left.triage.string("name").localizedStandardCompare(right.triage.string("name"))
            return order == .orderedSame ? left.id < right.id : order == .orderedAscending
        }
        let ordinary = facets.filter { !membershipIDs.contains(key($0)) && matches($0) }
        let visibleIDs = Set(ordinary.map(key) + sections.flatMap { $0.visibleMembers.map(key) })
        return TicketListProjection(ordinaryTickets: ordinary, triages: sections, visibleTicketCount: visibleIDs.count, scopedTicketCount: Set(scope.map(key)).count)
    }
}
