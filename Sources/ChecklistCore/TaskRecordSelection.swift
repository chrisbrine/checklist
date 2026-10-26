import Foundation
import GRDB

/// Request-local row selection only. Every consuming query must repeat its
/// authoritative project/type/task predicates; row IDs never grant authority.
private final class TaskRecordSelectionFrame {
    let database: Database
    let project: SnapshotRecordIdentity?
    let taskIDs: Set<SnapshotRecordIdentity>
    let serializedTaskIDs: String
    let previous: TaskRecordSelectionFrame?
    var families: [SnapshotRecordIdentity: [SnapshotRecordIdentity: [Int64]]] = [:]
    var unavailable = Set<SnapshotRecordIdentity>()
    var rowCount = 0
    var familyBytes: [SnapshotRecordIdentity:Int] = [:]
    init(database: Database, tasks: [JSON], previous: TaskRecordSelectionFrame?) throws {
        self.database = database
        self.previous = previous
        let projects = Set(tasks.compactMap {($0["project_id"] as? String).map(SnapshotRecordIdentity.init)})
        let ids = tasks.compactMap {$0["id"] as? String}
        // Invalid/mixed scopes fall back, rather than sharing a partial scope.
        project = !tasks.isEmpty && projects.count == 1 && tasks.allSatisfy {$0["project_id"] is String && $0["id"] is String} ? projects.first : nil
        taskIDs = Set(ids.map(SnapshotRecordIdentity.init))
        serializedTaskIDs = try jsonString(ids)
    }
    func invalidate(_ type: SnapshotRecordIdentity) {
        if let removed = families.removeValue(forKey:type) {rowCount -= removed.values.reduce(0) {$0+$1.count}}
        familyBytes.removeValue(forKey:type)
        // A formerly oversized family may now fit, or budget may have changed.
        unavailable.removeAll()
    }
}

extension CommandRouter {
    private static var taskRecordSelectionKey: String {"ChecklistCore.TaskRecordSelection.frame.v1"}

    func withTaskRecordSelection<T>(_ db: Database, tasks: [JSON], _ body: () throws -> T) throws -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[Self.taskRecordSelectionKey]
        let frame = try TaskRecordSelectionFrame(database:db,tasks:tasks,previous:previous as? TaskRecordSelectionFrame)
        dictionary[Self.taskRecordSelectionKey] = frame
        defer {
            if let previous {dictionary[Self.taskRecordSelectionKey] = previous}
            else {dictionary.removeObject(forKey:Self.taskRecordSelectionKey)}
        }
        return try body()
    }

    /// nil means generic query fallback; [] is a complete empty selection.
    /// At most 4096 row IDs are retained across all selected families.
    func selectedTaskRecordIDs(_ db: Database, type: String, task: JSON) throws -> [Int64]? {
        guard let frame = Thread.current.threadDictionary[Self.taskRecordSelectionKey] as? TaskRecordSelectionFrame,
              frame.database === db,let project = task["project_id"] as? String,let taskID = task["id"] as? String,
              frame.project == SnapshotRecordIdentity(project),frame.taskIDs.contains(SnapshotRecordIdentity(taskID)),
              frame.serializedTaskIDs.utf8.count <= 4*1024*1024 else {return nil}
        let family = SnapshotRecordIdentity(type), identity = SnapshotRecordIdentity(taskID)
        if let selected = frame.families[family] {return selected[identity] ?? []}
        if frame.unavailable.contains(family) {return nil}
        guard frame.families.count + frame.unavailable.count < 64 else {return nil}
        let remaining = 4096-frame.rowCount
        let rows = try Row.fetchAll(db,sql:"""
            SELECT rowid AS selection_rowid, CAST(json_extract(data,'$.task_id') AS BLOB) AS selection_task
            FROM records INDEXED BY records_scope
            WHERE project_id=CAST(? AS TEXT) AND type=CAST(? AS TEXT)
              AND CAST(json_extract(data,'$.task_id') AS BLOB) IN
                  (SELECT CAST(value AS BLOB) FROM json_each(?))
            ORDER BY rowid LIMIT ?
            """,arguments:[Data(project.utf8),Data(type.utf8),frame.serializedTaskIDs,remaining+1])
        guard rows.count <= remaining else {frame.unavailable.insert(family);return nil}
        var selected: [SnapshotRecordIdentity:[Int64]] = [:]
        for row in rows {
            let bytes: Data = row["selection_task"]
            let id = SnapshotRecordIdentity(String(decoding:bytes,as:UTF8.self))
            selected[id,default:[]].append(row["selection_rowid"] as Int64)
        }
        let bytes = selected.keys.reduce(type.utf8.count) {$0+$1.bytes.count} + rows.count*MemoryLayout<Int64>.size
        guard frame.serializedTaskIDs.utf8.count + frame.familyBytes.values.reduce(0,+) + bytes <= 4*1024*1024 else {frame.unavailable.insert(family);return nil}
        frame.familyBytes[family] = bytes
        frame.rowCount += rows.count
        frame.families[family] = selected
        return selected[identity] ?? []
    }

    /// Called only after a successful family write. Invalidate suspended outer
    /// frames too, so nested scopes cannot restore stale row selections.
    func invalidateTaskRecordSelection(_ db: Database, type: String) {
        var frame = Thread.current.threadDictionary[Self.taskRecordSelectionKey] as? TaskRecordSelectionFrame
        while let current = frame {
            if current.database === db {current.invalidate(SnapshotRecordIdentity(type))}
            frame = current.previous
        }
    }
}
