import Foundation
import GRDB

/// Opaque identity uses preserved UTF-8, not human-text canonical equivalence.
struct SnapshotRecordIdentity: Hashable {
    let bytes: [UInt8]
    init(_ value: String) { bytes = Array(value.utf8) }
}

enum SnapshotMessageProjection {
    static func hydrate(_ messages: [JSON], loadDeliveries: () throws -> [JSON]) rethrows -> [JSON] {
        guard !messages.isEmpty else { return [] }
        // Optional keys preserve the prior as? String comparison's nil/nil bucket.
        var byMessage: [SnapshotRecordIdentity?: [JSON]] = [:]
        for row in try loadDeliveries() {
            let key = (row["message_id"] as? String).map(SnapshotRecordIdentity.init)
            byMessage[key, default: []].append(row)
        }
        return messages.map { source in
            var row = source
            let key = (row["id"] as? String).map(SnapshotRecordIdentity.init)
            row["deliveries"] = byMessage[key] ?? []
            return row
        }
    }
}

/// Only an owner snapshot may use this read projection. It lives for one database
/// transaction; command guards and selected completion checks still read the database.
struct SnapshotReadProjection {
    private struct TaskKey: Hashable {
        let project: SnapshotRecordIdentity
        let task: SnapshotRecordIdentity
        init(project: String, task: String) {
            self.project = SnapshotRecordIdentity(project)
            self.task = SnapshotRecordIdentity(task)
        }
    }
    let collections: [String: [JSON]]
    private let tasksByID: [SnapshotRecordIdentity: JSON]
    private let statusesByID: [SnapshotRecordIdentity: JSON]
    private let tagsByProject: [SnapshotRecordIdentity: [JSON]]
    private let prerequisitesByTask: [TaskKey: [JSON]]
    private let attentionByTask: [TaskKey: [Result<Bool, Error>]]

    init(router: CommandRouter, database: Database, tasks: [JSON]) throws {
        var loaded: [String: [JSON]] = [:]
        for type in ["status", "tag", "group", "relation"] { loaded[type] = try router.records(database, type: type) }
        collections = loaded
        tasksByID = Self.firstByID(tasks)
        statusesByID = Self.firstByID(loaded["status"] ?? [])
        var tags: [SnapshotRecordIdentity: [JSON]] = [:]
        for tag in loaded["tag"] ?? [] { tags[SnapshotRecordIdentity(tag["project_id"] as? String ?? ""), default: []].append(tag) }
        tagsByProject = tags
        var prerequisites: [TaskKey: [JSON]] = [:]
        for edge in loaded["relation"] ?? [] where edge["state"] as? String != "removed" && edge["relation"] as? String == "depends_on" {
            if let project = edge["project_id"] as? String, let source = edge["source_task_id"] as? String {
                prerequisites[TaskKey(project: project, task: source), default: []].append(edge)
            }
        }
        prerequisitesByTask = prerequisites
        let taskIndex = tasksByID, statusIndex = statusesByID
        var attention: [TaskKey: [Result<Bool, Error>]] = [:]
        for group in loaded["group"] ?? [] where group["kind"] as? String == "triage" && !bool(group, "archived") {
            let project = group["project_id"] as! String
            let members = Self.exactMemberIDs(group)
            // Keep a failure deferred until a member actually needs triage attention:
            // an active attempt or active status retains the existing short circuit.
            let result = Result { try router.projectedTriageAttention(group, memberIDs: members,
                taskLookup: { try Self.scoped(taskIndex, id: $0, project: project) },
                statusLookup: { try Self.scoped(statusIndex, id: $0, project: project) }) }
            for member in members {
                attention[TaskKey(project: project, task: member), default: []].append(result)
            }
        }
        attentionByTask = attention
    }

    func project(_ router: CommandRouter, task: JSON) throws -> JSON {
        let project = task["project_id"] as! String, key = TaskKey(project: project, task: task["id"] as! String)
        let prerequisites = router.projectedPrerequisites(task: task, relations: prerequisitesByTask[key] ?? [],
            taskLookup: { try Self.scoped(tasksByID, id: $0, project: project) },
            statusLookup: { try Self.scoped(statusesByID, id: $0, project: project) })
        let attention = try router.projectedTaskAttention(task,
            statusLookup: { try Self.scoped(statusesByID, id: $0, project: project) }) {
                for result in attentionByTask[key] ?? [] { if try result.get() { return true } }
                return false
            }
        let status = statusesByID[SnapshotRecordIdentity(task["status_id"] as? String ?? "")]
        let canonical = try router.projectedCanonicalTaskID(task: task, taskLookup: { try Self.scoped(tasksByID, id: $0, project: project) })
        let relation = router.projectedRelationTask(task: task, prerequisites: prerequisites, category: status?["category"] as? String ?? "unknown", canonicalID: canonical)
        let tagIDs = Set(strings(task, "tag_ids").map(SnapshotRecordIdentity.init))
        let tags = (tagsByProject[SnapshotRecordIdentity(project)] ?? []).filter { tagIDs.contains(SnapshotRecordIdentity($0["id"] as? String ?? "")) }
        var result = router.assembledTaskProjection(task, status: status, activeAttention: attention, tags: tags, relation: relation)
        // Only an explicit selected task_get may carry current completion authority.
        result.removeValue(forKey: "completion_eligibility")
        return result
    }

    private static func firstByID(_ rows: [JSON]) -> [SnapshotRecordIdentity: JSON] {
        var result: [SnapshotRecordIdentity: JSON] = [:]
        for row in rows {
            if let id = row["id"] as? String {
                let key = SnapshotRecordIdentity(id)
                if result[key] == nil { result[key] = row }
            }
        }
        return result
    }
    private static func scoped(_ rows: [SnapshotRecordIdentity: JSON], id: String, project: String) throws -> JSON {
        guard let row = rows[SnapshotRecordIdentity(id)] else { throw CoreError("NOT_FOUND", "This record is not available.") }
        guard let pid = row["project_id"] as? String, SnapshotRecordIdentity(pid) == SnapshotRecordIdentity(project) else { throw CoreError("NOT_FOUND", "This record is not available in this project.") }
        return row
    }
    private static func exactMemberIDs(_ group: JSON) -> [String] {
        let members = (group["members"] as? [JSON] ?? []).compactMap { $0["task_id"] as? String }
        var seen = Set<SnapshotRecordIdentity>()
        return (members.isEmpty ? strings(group, "task_ids") : members).filter { seen.insert(SnapshotRecordIdentity($0)).inserted }
    }
}

extension CommandRouter {
    /// Presence is owner-only, even false. Reject before a read transaction, cursor,
    /// maintenance or dynamic notice can be performed for a crafted worker input.
    func ownerCompletionEligibilityRequested(_ params: JSON, caller: Caller) throws -> Bool {
        guard let value = params["include_completion_eligibility"] else { return false }
        try owner(caller)
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw CoreError("INVALID_INPUT", "include_completion_eligibility must be a boolean.")
        }
        return number.boolValue
    }
}
