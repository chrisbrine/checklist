import Foundation

struct TicketListFilters: Codable, Equatable {
    var tagIDs: [String] = []
    var tagMode = "any"
    var plannedAssignee = "all"
    var actualAssignee = "all"
    var epicID = "all"
    var triageID = "all"
    var isActive: Bool { !tagIDs.isEmpty || plannedAssignee != "all" || actualAssignee != "all" || epicID != "all" || triageID != "all" }
    var parameters: [String: Any] { ["tag_ids":tagIDs, "tag_mode":tagMode, "planned_assignee":plannedAssignee, "actual_assignee":actualAssignee, "epic_id":epicID, "triage_id":triageID] }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tagIDs.map(RecordIdentity.init) == rhs.tagIDs.map(RecordIdentity.init) && lhs.tagMode == rhs.tagMode &&
        RecordIdentity(lhs.plannedAssignee) == RecordIdentity(rhs.plannedAssignee) && RecordIdentity(lhs.actualAssignee) == RecordIdentity(rhs.actualAssignee) &&
        RecordIdentity(lhs.epicID) == RecordIdentity(rhs.epicID) && RecordIdentity(lhs.triageID) == RecordIdentity(rhs.triageID)
    }
}

struct PersonalTicketView: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var search: String
    var status: String
    var legacyTag: String
    var filters: TicketListFilters
    var groupBy: String
    var orderBy: String
    var surface: String? = nil
}

/// Preferences belong to this owner/window, never a project setting. A view
/// stores sort choices only; the project's manual row positions stay untouched.
struct PersonalTicketViews {
    static let limit = 10
    let preferences: UserDefaults
    let projectID: String
    private var key: String { "personalTicketViews:" + projectID }
    func load() -> [PersonalTicketView] {
        guard let data = preferences.data(forKey:key), let values = try? JSONDecoder().decode([PersonalTicketView].self,from:data) else { return [] }
        return Array(values.prefix(Self.limit))
    }
    @discardableResult func save(_ view: PersonalTicketView) -> Bool {
        var views = load()
        if let index = views.firstIndex(where: { $0.id == view.id }) { views[index] = view }
        else { guard views.count < Self.limit else { return false }; views.append(view) }
        guard let data = try? JSONEncoder().encode(views) else { return false }
        preferences.set(data,forKey:key); return true
    }
    func remove(_ id: String) { if let data = try? JSONEncoder().encode(load().filter { $0.id != id }) { preferences.set(data,forKey:key) } }
}
