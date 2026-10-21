import Foundation

/// Derived lookups for one installed snapshot. Replacing the snapshot replaces
/// this value; these records never establish command or completion authority.
struct SnapshotRecordIndex {
    private let collections: [String: Collection]

    init(snapshot: [String: Any]) {
        var result: [String: Collection] = [:]
        for (name, value) in snapshot {
            guard let rows = value as? [[String: Any]] else { continue }
            result[name] = Collection(rows: rows)
        }
        collections = result
    }

    func records(in collection: String) -> [Record] {
        collections[collection]?.ordered ?? []
    }

    func records(in collection: String, projectID: String) -> [Record] {
        collections[collection]?.byProject[RecordIdentity(projectID)] ?? []
    }

    func records(in collection: String, projectID: String, taskID: String) -> [Record] {
        collections[collection]?.byTask[ScopedID(projectID: projectID, id: taskID)] ?? []
    }

    /// A duplicate ID retains the first record in source order, matching the
    /// previous array lookup. Supplying a project never falls back to another.
    func record(in collection: String, id: String, projectID: String? = nil) -> Record? {
        guard !id.isEmpty, let rows = collections[collection] else { return nil }
        if let projectID {
            return rows.firstByScopedID[ScopedID(projectID: projectID, id: id)]
        }
        return rows.firstByID[RecordIdentity(id)]
    }

    private struct ScopedID: Hashable {
        let projectID: RecordIdentity
        let id: RecordIdentity
        init(projectID: String, id: String) {
            self.projectID = RecordIdentity(projectID)
            self.id = RecordIdentity(id)
        }
    }

    private struct Collection {
        let ordered: [Record]
        let firstByID: [RecordIdentity: Record]
        let firstByScopedID: [ScopedID: Record]
        let byProject: [RecordIdentity: [Record]]
        let byTask: [ScopedID: [Record]]

        init(rows: [[String: Any]]) {
            let records = rows.map(Record.init)
            var ids: [RecordIdentity: Record] = [:]
            var scopedIDs: [ScopedID: Record] = [:]
            var projects: [RecordIdentity: [Record]] = [:]
            var tasks: [ScopedID: [Record]] = [:]
            for record in records {
                if !record.id.isEmpty, ids[RecordIdentity(record.id)] == nil { ids[RecordIdentity(record.id)] = record }
                let projectID = record.string("project_id")
                guard !projectID.isEmpty else { continue }
                projects[RecordIdentity(projectID), default: []].append(record)
                if !record.id.isEmpty {
                    let key = ScopedID(projectID: projectID, id: record.id)
                    if scopedIDs[key] == nil { scopedIDs[key] = record }
                }
                let taskID = record.string("task_id")
                if !taskID.isEmpty {
                    tasks[ScopedID(projectID: projectID, id: taskID), default: []].append(record)
                }
            }
            ordered = records
            firstByID = ids
            firstByScopedID = scopedIDs
            byProject = projects
            byTask = tasks
        }
    }
}
