import Foundation
import GRDB

/// These facts come from one read snapshot. All decisions about current waits,
/// correlated replies and delivery authority still run on the writer.
struct WorkHealthPreparedProgress {
    let target: JSON
    let reading: (at: Date?, clock: String?)
    let token: String
}

struct WorkHealthPreparedPage {
    enum Action {
        case unheld(String)
        case inspect(WorkHealthPreparedProgress)
        case skip
    }
    struct Item {
        let task: JSON
        let action: Action
        let dependencies: WorkHealthPreparationDependencies
    }
    let items: [Item]
    let nextPosition: Int64
    let hasMore: Bool
    let enabled: Bool
}

/// Exact byte identities and semantic project settings for one bounded page.
/// A newly matching Triage is detected from the changed group's current members.
struct WorkHealthPreparationDependencies {
    struct Task: Hashable {
        let project: Data
        let id: Data
    }
    private(set) var ids = Set<Data>()
    var selectedTasks = Set<Task>()
    var attemptTasks = Set<Task>()
    var projectFacts: [Data:Data] = [:]
    private(set) var bytes = 0
    private(set) var complete = true

    mutating func include(_ id: String?) {
        guard let id else {return}
        include(Data(id.utf8))
    }
    mutating func include(_ value: Data) {
        guard !ids.contains(value) else {return}
        guard ids.count < 32768,bytes + value.count <= 4*1024*1024 else {complete = false;return}
        ids.insert(value);bytes += value.count
    }
    mutating func refuse() {
        ids = [];selectedTasks = [];attemptTasks = [];projectFacts = [:];bytes = 0;complete = false
    }
    mutating func includeProject(_ id: String,facts: Data) {
        let key = Data(id.utf8)
        guard projectFacts[key] == nil else {return}
        guard bytes + facts.count <= 4*1024*1024 else {complete = false;return}
        projectFacts[key] = facts;bytes += facts.count
        include(id)
    }
}

extension CommandRouter {
    func workHealthPreparationProjectFacts(_ project: JSON) throws -> Data {
        try Data(jsonString([
            "archived":bool(project,"archived"),
            "settings":workHealthSettings(project),
            "generation":project["work_health_generation"] ?? "initial",
            "changed_at":project["work_health_changed_at"] ?? NSNull()
        ]).utf8)
    }

    /// Match scopedTaskGroups exactly, including string-shaped legacy members.
    /// Stream BLOB identities so Swift String normalization cannot collapse IDs.
    func visitWorkHealthPreparationMembers(_ db: Database,group: Data,project: Data,_ visit: (Data) throws -> Bool) throws {
        let rows = try Row.fetchCursor(db,sql:"""
            SELECT CAST(CASE WHEN member.type='object' THEN json_extract(member.value,'$.task_id') ELSE member.value END AS BLOB) AS member_id
            FROM records g,json_each(CASE WHEN json_array_length(json_extract(g.data,'$.members'))>0
                THEN json_extract(g.data,'$.members') ELSE json_extract(g.data,'$.task_ids') END) member
            WHERE g.id=CAST(? AS TEXT) AND g.project_id=CAST(? AS TEXT) AND g.type='group'
            """,arguments:[group,project])
        while let row = try rows.next() {
            if let id = row["member_id"] as Data?,try !visit(id) {break}
        }
    }

    func workHealthPreparationIsCurrent(_ db: Database,changes: [WorkHealthPreparationChanges.Change]?,dependencies: WorkHealthPreparationDependencies) throws -> Bool {
        guard dependencies.complete,let changes else {return false}
        let started = ProcessInfo.processInfo.systemUptime
        var checkedProjects = Set<Data>()
        var checkedGroups = Set<WorkHealthPreparationDependencies.Task>()
        for change in changes {
            // A large changed-group cohort yields instead of becoming another
            // long gate holder. The next ordinary health wake prepares again.
            guard ProcessInfo.processInfo.systemUptime-started < 0.05 else {return false}
            switch change.type {
            case Data("project".utf8):
                guard let expected = dependencies.projectFacts[change.id],checkedProjects.insert(change.id).inserted else {continue}
                guard let current = try? record(db,String(decoding:change.id,as:UTF8.self),type:"project"),
                      try workHealthPreparationProjectFacts(current) == expected else {return false}
            case Data("attempt".utf8):
                if dependencies.ids.contains(change.id) || dependencies.attemptTasks.contains(.init(project:change.project,id:change.task)) {return false}
            case Data("group".utf8):
                if dependencies.ids.contains(change.id) {return false}
                // Existing matching groups were captured above. A changed or
                // newly inserted group can introduce a matching membership too.
                guard dependencies.projectFacts[change.project] != nil,
                      checkedGroups.insert(.init(project:change.project,id:change.id)).inserted else {continue}
                guard let row = try Row.fetchOne(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE id=CAST(? AS TEXT) AND project_id=CAST(? AS TEXT) AND type='group'",arguments:[change.id,change.project]) else {continue}
                guard let group = try? GRDBRecordEnvelopeAdapter.decode(row,expectedType:"group").object else {return false}
                guard group["kind"] as? String == "triage",!bool(group,"archived") else {continue}
                var matching = false,expired = false
                try visitWorkHealthPreparationMembers(db,group:change.id,project:change.project) {member in
                    if ProcessInfo.processInfo.systemUptime-started >= 0.05 {expired = true;return false}
                    matching = dependencies.selectedTasks.contains(.init(project:change.project,id:member))
                    return !matching
                }
                if matching || expired {return false}
            default:
                if dependencies.ids.contains(change.id) {return false}
            }
        }
        return true
    }
}
