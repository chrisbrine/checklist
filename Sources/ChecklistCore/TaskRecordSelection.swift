import Foundation
import GRDB

/// Complete row IDs from one read snapshot, with no records or database handle.
struct TaskRecordSelectionSnapshot {
    fileprivate let project: SnapshotRecordIdentity?
    fileprivate let taskIDs: Set<SnapshotRecordIdentity>
    fileprivate let families: [SnapshotRecordIdentity: [SnapshotRecordIdentity: [Int64]]]
}

/// Request-local row selection only. Every consuming query must repeat its
/// authoritative project/type/task predicates; row IDs never grant authority.
private final class TaskRecordSelectionFrame {
    let database: Database
    let project: SnapshotRecordIdentity?
    let taskIDs: Set<SnapshotRecordIdentity>
    let serializedTaskIDs: String?
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
    init(database: Database, snapshot: TaskRecordSelectionSnapshot, previous: TaskRecordSelectionFrame?) {
        self.database = database
        self.previous = previous
        project = snapshot.project
        taskIDs = snapshot.taskIDs
        families = snapshot.families
        rowCount = families.values.reduce(0) { total, tasks in total + tasks.values.reduce(0) { $0 + $1.count } }
        // A prepared frame uses the ordinary query for families the reader
        // could not prepare or that this transaction has since changed.
        serializedTaskIDs = nil
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
    private static var taskRecordSelectionFrame: TaskRecordSelectionFrame? {
        Thread.current.threadDictionary[taskRecordSelectionKey] as? TaskRecordSelectionFrame
    }

    func withTaskRecordSelection<T>(_ db: Database, tasks: [JSON], _ body: () throws -> T) throws -> T {
        let frame = try TaskRecordSelectionFrame(database:db,tasks:tasks,previous:Self.taskRecordSelectionFrame)
        return try withTaskRecordSelectionFrame(frame,body)
    }

    func prepareTaskRecordSelection(_ db: Database, task: JSON, types: [String]) throws -> TaskRecordSelectionSnapshot {
        let frame = try TaskRecordSelectionFrame(database:db,tasks:[task],previous:Self.taskRecordSelectionFrame)
        return try withTaskRecordSelectionFrame(frame) {
            for type in types { _ = try selectedTaskRecordIDs(db,type:type,task:task) }
            return .init(project:frame.project,taskIDs:frame.taskIDs,families:frame.families)
        }
    }

    func withTaskRecordSelectionSnapshot<T>(_ db: Database, snapshot: TaskRecordSelectionSnapshot, _ body: () throws -> T) rethrows -> T {
        let frame = TaskRecordSelectionFrame(database:db,snapshot:snapshot,previous:Self.taskRecordSelectionFrame)
        return try withTaskRecordSelectionFrame(frame,body)
    }

    private func withTaskRecordSelectionFrame<T>(_ frame: TaskRecordSelectionFrame, _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        dictionary[Self.taskRecordSelectionKey] = frame
        defer {
            if let previous = frame.previous {dictionary[Self.taskRecordSelectionKey] = previous}
            else {dictionary.removeObject(forKey:Self.taskRecordSelectionKey)}
        }
        return try body()
    }

    /// nil means generic query fallback; [] is a complete empty selection.
    /// At most 4096 row IDs are retained across all selected families.
    func selectedTaskRecordIDs(_ db: Database, type: String, task: JSON, prepareIfNeeded: Bool = true) throws -> [Int64]? {
        guard let frame = Self.taskRecordSelectionFrame,
              frame.database === db,let project = task["project_id"] as? String,let taskID = task["id"] as? String,
              frame.project == SnapshotRecordIdentity(project),frame.taskIDs.contains(SnapshotRecordIdentity(taskID)) else {return nil}
        let family = SnapshotRecordIdentity(type), identity = SnapshotRecordIdentity(taskID)
        if let selected = frame.families[family] {return selected[identity] ?? []}
        guard prepareIfNeeded,let serializedTaskIDs = frame.serializedTaskIDs,serializedTaskIDs.utf8.count <= 4*1024*1024,
              !frame.unavailable.contains(family) else {return nil}
        guard frame.families.count + frame.unavailable.count < 64 else {return nil}
        let remaining = 4096-frame.rowCount
        let rows = try self.fetchStoreRows(db,sql:"""
            SELECT rowid AS selection_rowid, CAST(json_extract(data,'$.task_id') AS BLOB) AS selection_task
            FROM records INDEXED BY records_scope
            WHERE project_id=CAST(? AS TEXT) AND type=CAST(? AS TEXT)
              AND CAST(json_extract(data,'$.task_id') AS BLOB) IN
                  (SELECT CAST(value AS BLOB) FROM json_each(?))
            ORDER BY rowid LIMIT ?
            """,arguments:[Data(project.utf8),Data(type.utf8),serializedTaskIDs,remaining+1])
        guard rows.count <= remaining else {frame.unavailable.insert(family);return nil}
        var selected: [SnapshotRecordIdentity:[Int64]] = [:]
        for row in rows {
            let bytes: Data = row["selection_task"]
            let id = SnapshotRecordIdentity(String(decoding:bytes,as:UTF8.self))
            selected[id,default:[]].append(row["selection_rowid"] as Int64)
        }
        let bytes = selected.keys.reduce(type.utf8.count) {$0+$1.bytes.count} + rows.count*MemoryLayout<Int64>.size
        guard serializedTaskIDs.utf8.count + frame.familyBytes.values.reduce(0,+) + bytes <= 4*1024*1024 else {frame.unavailable.insert(family);return nil}
        frame.familyBytes[family] = bytes
        frame.rowCount += rows.count
        frame.families[family] = selected
        return selected[identity] ?? []
    }

    /// Called only after a successful family write. Invalidate suspended outer
    /// frames too, so nested scopes cannot restore stale row selections.
    func invalidateTaskRecordSelection(_ db: Database, type: String) {
        var frame = Self.taskRecordSelectionFrame
        while let current = frame {
            if current.database === db {current.invalidate(SnapshotRecordIdentity(type))}
            frame = current.previous
        }
    }

    /// The claim inserts an attempt before projecting current and prior work.
    /// A prepared selection can include that exact inserted row without scanning
    /// retained attempts. Other writes and overlays keep ordinary invalidation.
    func includeInsertedAttemptInTaskRecordSelection(_ db: Database, attempt: JSON, rowID: Int64) {
        let family = SnapshotRecordIdentity("attempt")
        var frame = Self.taskRecordSelectionFrame
        while let current = frame {
            frame = current.previous
            guard current.database === db else { continue }
            guard current.serializedTaskIDs == nil, current.families[family] != nil,
                  let project = attempt["project_id"] as? String, current.project == SnapshotRecordIdentity(project),
                  let task = attempt["task_id"] as? String, current.taskIDs.contains(SnapshotRecordIdentity(task)),
                  current.rowCount < 4096 else {
                current.invalidate(family)
                continue
            }
            current.families[family]?[SnapshotRecordIdentity(task),default:[]].append(rowID)
            current.rowCount += 1
        }
    }
}
