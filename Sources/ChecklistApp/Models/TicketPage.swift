import Foundation

/// One owner Tickets read. Human search keeps its existing text comparison;
/// opaque scope IDs retain their exact bytes. Nothing here supplies write authority.
struct TicketPageQuery: Equatable {
    let surface: String
    let projectID: String?
    let text: String
    let statusFilter: String
    let tagFilter: String
    let groupBy: String
    let orderBy: String
    var filters = TicketListFilters()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.surface == rhs.surface &&
        lhs.projectID.map(RecordIdentity.init) == rhs.projectID.map(RecordIdentity.init) &&
        lhs.text == rhs.text &&
        RecordIdentity(lhs.statusFilter) == RecordIdentity(rhs.statusFilter) &&
        RecordIdentity(lhs.tagFilter) == RecordIdentity(rhs.tagFilter) &&
        lhs.groupBy == rhs.groupBy && lhs.orderBy == rhs.orderBy && lhs.filters == rhs.filters
    }

    func parameters(cursor: String? = nil) -> [String: Any] {
        var view: [String: Any] = [
            "surface": surface, "status_filter": statusFilter,
            "tag_filter": tagFilter, "group_by": groupBy, "order_by": orderBy
        ]
        view.merge(filters.parameters) { _, new in new }
        var result: [String: Any] = ["view": view, "text": text, "limit": 200]
        if let projectID { result["project_id"] = projectID }
        if let cursor { result["cursor"] = cursor }
        return result
    }

    var hasFilters: Bool {
        filters.isActive || statusFilter != "all" || tagFilter != "all" ||
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum TicketPageError: Error, Equatable, LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let field): return "The ticket page is incomplete or invalid (\(field)). Refresh the list."
        }
    }
}

/// A bounded read result, kept apart from the full snapshot/index. Missing page
/// entries are not deleted records, and triage summaries are never membership receipts.
struct TicketPage {
    let queryKey: String
    let contentCursor: String
    let tasks: [Record]
    let ordinaryIDs: [String]
    let triages: [Record]
    let projects: [Record]
    let statuses: [Record]
    let tags: [Record]
    let epics: [Record]
    let filterTriages: [Record]
    let scopedCount: Int
    let matchedCount: Int
    let hasMore: Bool
    let nextCursor: String?
    let previousCursor: String?
    let outstandingRequestCount: Int
    let humanTaskCount: Int
    let overviewRequests: [Record]
    let overviewRequestCount: Int
    let service: Record
    private let tasksByID: [RecordIdentity: Record]

    init(response: [String: Any]) throws {
        try Self.keys(response, required: ["schema_version", "tickets_page"],
            optional: ["event_cursor", "_checklist"], path: "response")
        // Transport observations are allowed alongside, never instead of, the
        // required domain response. They do not establish page/content authority.
        if let cursor = response["event_cursor"] {
            _ = try Self.string(cursor, path: "response.event_cursor", nonempty: true)
        }
        if let observations = response["_checklist"], !(observations is [String: Any]) {
            throw TicketPageError.invalid("response._checklist")
        }
        guard try Self.integer(response["schema_version"], path: "schema_version") == 1,
              let value = response["tickets_page"] as? [String: Any] else {
            throw TicketPageError.invalid("schema_version/tickets_page")
        }
        try Self.keys(value, required: ["query_key", "content_cursor", "tasks", "ordinary_ids", "triages",
            "scoped_count", "matched_count", "has_more", "next_cursor", "previous_cursor", "projects",
            "statuses", "tags", "epics", "outstanding_request_count", "human_task_count",
            "overview_requests", "overview_request_count", "service"], optional: ["filter_triages"], path: "tickets_page")
        queryKey = try Self.string(value["query_key"], path: "query_key", nonempty: true)
        contentCursor = try Self.string(value["content_cursor"], path: "content_cursor", nonempty: true)
        tasks = try Self.records(value["tasks"], path: "tasks", projectScoped: true)
        guard tasks.count <= 200 else { throw TicketPageError.invalid("tasks.limit") }
        var taskIndex: [RecordIdentity: Record] = [:]
        for task in tasks { taskIndex[RecordIdentity(task.id)] = task }
        tasksByID = taskIndex
        ordinaryIDs = try Self.ids(value["ordinary_ids"], path: "ordinary_ids")
        triages = try Self.records(value["triages"], path: "triages", projectScoped: true).map { row in
            var summary = row.values
            // Mixed summaries have no uniform status ID. Keep an empty display
            // identity, never fabricate an actionable status/membership receipt.
            if summary["status_id"] is NSNull { summary["status_id"] = "" }
            return Record(values: summary)
        }
        projects = try Self.records(value["projects"], path: "projects")
        statuses = try Self.records(value["statuses"], path: "statuses", projectScoped: true)
        tags = try Self.records(value["tags"], path: "tags", projectScoped: true)
        epics = try Self.records(value["epics"], path: "epics", projectScoped: true)
        filterTriages = try Self.records(value["filter_triages"] ?? [[String:Any]](), path: "filter_triages", projectScoped: true)
        scopedCount = try Self.integer(value["scoped_count"], path: "scoped_count")
        matchedCount = try Self.integer(value["matched_count"], path: "matched_count")
        hasMore = try Self.boolean(value["has_more"], path: "has_more")
        nextCursor = try Self.cursor(value["next_cursor"], path: "next_cursor")
        previousCursor = try Self.cursor(value["previous_cursor"], path: "previous_cursor")
        outstandingRequestCount = try Self.integer(value["outstanding_request_count"], path: "outstanding_request_count")
        humanTaskCount = try Self.integer(value["human_task_count"], path: "human_task_count")
        overviewRequests = try Self.records(value["overview_requests"], path: "overview_requests", projectScoped: true)
        overviewRequestCount = try Self.integer(value["overview_request_count"], path: "overview_request_count")
        guard let serviceValue = value["service"] as? [String: Any] else {
            throw TicketPageError.invalid("service")
        }
        _ = try Self.string(serviceValue["store_incarnation"], path: "service.store_incarnation", nonempty: true)
        service = Record(values: serviceValue)
        guard matchedCount <= scopedCount, tasks.count <= matchedCount,
              overviewRequests.count <= 3, overviewRequests.count <= overviewRequestCount,
              hasMore == (nextCursor != nil) else { throw TicketPageError.invalid("counts/cursors") }

        var ordinaryKeys: Set<RecordIdentity> = []
        for id in ordinaryIDs {
            let key = RecordIdentity(id)
            guard taskIndex[key] != nil else { throw TicketPageError.invalid("ordinary_ids.reference") }
            ordinaryKeys.insert(key)
        }
        var represented = ordinaryKeys
        var grouped: Set<RecordIdentity> = []
        for triage in triages {
            let summary = triage.values
            try Self.keys(summary, required: ["id", "project_id", "revision", "name", "purpose", "kind", "phase",
                "archived", "active_attention", "status_state", "status_id", "status_name", "status_category",
                "member_count", "matching_count", "page_member_ids", "members_complete"], optional:["key", "orchestration"], path: "triages.summary")
            for field in ["name", "purpose", "phase", "status_state", "status_id", "status_name", "status_category"] {
                _ = try Self.string(summary[field], path: "triages.\(field)")
            }
            guard try Self.string(summary["kind"], path: "triages.kind") == "triage",
                  try Self.integer(summary["revision"], path: "triages.revision") > 0,
                  try Self.boolean(summary["members_complete"], path: "triages.members_complete") == false else {
                throw TicketPageError.invalid("triages.summary")
            }
            _ = try Self.boolean(summary["archived"], path: "triages.archived")
            _ = try Self.boolean(summary["active_attention"], path: "triages.active_attention")
            if let raw = summary["orchestration"] {
                guard let orchestration = raw as? [String: Any] else { throw TicketPageError.invalid("triages.orchestration") }
                try Self.keys(orchestration, required: ["state", "actor_display", "session_id"], path: "triages.orchestration")
                for field in ["state", "actor_display", "session_id"] {
                    _ = try Self.string(orchestration[field], path: "triages.orchestration.\(field)")
                }
            }
            let memberCount = try Self.integer(summary["member_count"], path: "triages.member_count")
            let matchingCount = try Self.integer(summary["matching_count"], path: "triages.matching_count")
            let ids = try Self.ids(summary["page_member_ids"], path: "triages.page_member_ids")
            // The bounded unit stream may contain a name/purpose-matching header
            // without member rows on this page, including matching_count == 0.
            guard ids.count <= matchingCount, matchingCount <= memberCount else {
                throw TicketPageError.invalid("triages.counts")
            }
            for id in ids {
                let key = RecordIdentity(id)
                guard let task = taskIndex[key],
                      RecordIdentity(task.string("project_id")) == RecordIdentity(triage.string("project_id")),
                      !ordinaryKeys.contains(key) else { throw TicketPageError.invalid("triages.page_member_ids.reference") }
                represented.insert(key)
                grouped.insert(key)
            }
        }
        guard represented == Set(taskIndex.keys), ordinaryKeys.isDisjoint(with: grouped) else {
            throw TicketPageError.invalid("tasks.representation")
        }
    }

    func task(_ id: String) -> Record? { tasksByID[RecordIdentity(id)] }

    private static func keys(_ object: [String: Any], required: Set<String>, optional: Set<String> = [], path: String) throws {
        let actual = Set(object.keys)
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else {
            throw TicketPageError.invalid(path + ".fields")
        }
    }
    private static func string(_ raw: Any?, path: String, nonempty: Bool = false) throws -> String {
        guard let result = raw as? String, !nonempty || !result.isEmpty else { throw TicketPageError.invalid(path) }
        return result
    }
    private static func integer(_ raw: Any?, path: String) throws -> Int {
        // JSONSerialization represents booleans with ObjC type `c`; do not accept
        // true/false as counts. Reject fractional, negative and overflowing numbers.
        guard let number = raw as? NSNumber, String(cString: number.objCType) != "c",
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue < Double(Int.max), number.doubleValue.rounded(.towardZero) == number.doubleValue else {
            throw TicketPageError.invalid(path)
        }
        return number.intValue
    }
    private static func boolean(_ raw: Any?, path: String) throws -> Bool {
        guard let number = raw as? NSNumber, String(cString: number.objCType) == "c" else {
            throw TicketPageError.invalid(path)
        }
        return number.boolValue
    }
    private static func cursor(_ raw: Any?, path: String) throws -> String? {
        if raw is NSNull { return nil }
        return try string(raw, path: path, nonempty: true)
    }
    private static func ids(_ raw: Any?, path: String) throws -> [String] {
        guard let ids = raw as? [String], ids.allSatisfy({ !$0.isEmpty }),
              Set(ids.map(RecordIdentity.init)).count == ids.count else { throw TicketPageError.invalid(path) }
        return ids
    }
    private static func records(_ raw: Any?, path: String, projectScoped: Bool = false) throws -> [Record] {
        guard let values = raw as? [[String: Any]] else { throw TicketPageError.invalid(path) }
        var seen: Set<RecordIdentity> = []
        return try values.map { value in
            let id = try string(value["id"], path: path + ".id", nonempty: true)
            guard seen.insert(RecordIdentity(id)).inserted else { throw TicketPageError.invalid(path + ".duplicate_id") }
            if projectScoped { _ = try string(value["project_id"], path: path + ".project_id", nonempty: true) }
            return Record(values: value)
        }
    }
}
