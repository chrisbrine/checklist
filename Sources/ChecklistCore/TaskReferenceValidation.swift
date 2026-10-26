import Foundation
import GRDB

/// A writer-confined change set, discarded with its enclosing transaction.
final class TaskReferenceFrame {
    let database: ObjectIdentifier
    var projects: [Data: TaskReferenceProject] = [:]
    init(_ db: Database) { database = ObjectIdentifier(db) }
}

struct TaskReferenceProject {
    let project: String
    var tasks: [Data: String] = [:]
    var targets: [String: [Data: String]] = [:]
}

struct TaskReferenceWrite {
    let frame: TaskReferenceFrame
    let id: String
    let type: String
    let oldProject: String?
    let project: String
}

private struct TaskReferenceKey: Hashable {
    let project: Data
    let type: String
    let id: Data
}

private struct TaskReferenceScope: Hashable {
    let project: Data
    let type: String
}

private struct CurrentTaskReference {
    let project: String
    let type: String
    let id: String
    var key: TaskReferenceKey { .init(project: Data(project.utf8), type: type, id: Data(id.utf8)) }
}

extension CommandRouter {
    /// The only outer commit owner validates after its complete callback. Nested
    /// calls share the frame and restore its snapshot with an actual savepoint.
    func withValidatedDomainTransaction(_ db: Database, _ body: () throws -> Database.TransactionCompletion) throws {
        if let frame = taskReferenceFrame {
            guard frame.database == ObjectIdentifier(db), db.isInsideTransaction else { throw referenceBoundaryFailure() }
            let snapshot = frame.projects
            do {
                var rolledBack = false
                try db.inSavepoint {
                    let completion = try body()
                    if case .rollback = completion { rolledBack = true }
                    return completion
                }
                if rolledBack { frame.projects = snapshot }
            } catch {
                frame.projects = snapshot
                throw error
            }
            return
        }
        // An unknown outer owner may not validate an incomplete intermediate graph.
        guard !db.isInsideTransaction else { throw referenceBoundaryFailure() }
        let frame = TaskReferenceFrame(db)
        taskReferenceFrame = frame
        defer { taskReferenceFrame = nil }
        try db.inTransaction {
            let completion = try body()
            if case .commit = completion { try validateCurrentTaskReferences(db, frame) }
            return completion
        }
    }

    /// Called after C1b envelope comparison and before the existing UPSERT.
    /// It performs no relationship lookup or incomplete-state validation.
    func prepareTaskReferenceWrite(_ db: Database, previous: Row?, next: DecodedEnvelope) throws -> TaskReferenceWrite? {
        guard ["task", "status", "tag", "group"].contains(next.type) else { return nil }
        guard let frame = taskReferenceFrame, frame.database == ObjectIdentifier(db), db.isInsideTransaction,
              let project = next.projectID else { throw referenceBoundaryFailure() }
        if next.type == "task",let previous, bool(try GRDBRecordEnvelopeAdapter.decode(previous,expectedType:"task").object,"purged") {
            throw CoreError("TICKET_PURGED","A permanently removed ticket cannot be changed or restored.")
        }
        // Covers internal/import writers as well as public commands. Legacy
        // tickets remain readable but must be repaired before their next save.
        if next.type == "task",!bool(next.object,"purged") { _ = try requiredEpicID(next.object["epic_id"]) }
        var oldProject: String?
        if let previous {
            // C1b already validated this exact prior envelope and witness. Do
            // not decode its payload again or validate removed historical links.
            let bytes: Data? = previous["_envelope_project_id_bytes"]
            guard let bytes, let original = String(data: bytes, encoding: .utf8), Data(original.utf8) == bytes else {
                throw referenceBoundaryFailure()
            }
            oldProject = original
        }
        return .init(frame: frame, id: next.id, type: next.type, oldProject: oldProject, project: project)
    }

    /// Journal only successful writes. Old/new target projects both select
    /// inbound tasks; current task references are resolved from final rows.
    func recordTaskReferenceWrite(_ write: TaskReferenceWrite?) {
        guard let write else { return }
        let frame = write.frame
        var projects = [Data(write.project.utf8): write.project]
        if let old = write.oldProject { projects[Data(old.utf8)] = old }
        for (key, project) in projects {
            var work = frame.projects[key] ?? TaskReferenceProject(project: project)
            if write.type == "task" { work.tasks[Data(write.id.utf8)] = write.id }
            else { work.targets[write.type, default: [:]][Data(write.id.utf8)] = write.id }
            frame.projects[key] = work
        }
    }

    private func validateCurrentTaskReferences(_ db: Database, _ frame: TaskReferenceFrame) throws {
        guard frame.database == ObjectIdentifier(db), db.isInsideTransaction else { throw referenceBoundaryFailure() }
        guard !frame.projects.isEmpty else { return }
        var selected: [TaskReferenceKey: DecodedEnvelope] = [:]
        var seenRows: Set<Int64> = []
        for (projectKey, work) in frame.projects.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            func consume(_ rows: [Row]) throws {
                for row in rows {
                    let position: Int64 = row["_reference_position"]
                    guard seenRows.insert(position).inserted else { continue }
                    let task = try GRDBRecordEnvelopeAdapter.decode(row, expectedType: "task")
                    let project = try StoredRecord(task.object, family: "task").string("project_id")
                    selected[.init(project: Data(project.utf8), type: "task", id: Data(task.id.utf8))] = task
                }
            }
            for ids in referenceChunks(referenceOrder(work.tasks)) {
                let sql = "SELECT rowid AS _reference_position," + Self.canonicalRecordColumns + " FROM records WHERE type='task' AND project_id=CAST(? AS TEXT) AND id IN (" + referencePlaceholders(ids.count) + ") ORDER BY rowid"
                try consume(Row.fetchAll(db, sql: sql, arguments: referenceArguments(work.project, ids)))
            }
            for type in ["status", "tag", "group"] {
                for ids in referenceChunks(referenceOrder(work.targets[type] ?? [:])) {
                    let candidate = inboundReferenceCandidate(type, placeholders: referencePlaceholders(ids.count))
                    let sql = "SELECT rowid AS _reference_position," + Self.canonicalRecordColumns + " FROM records WHERE type='task' AND project_id=CAST(? AS TEXT) AND (" + candidate + ") ORDER BY rowid"
                    try consume(Row.fetchAll(db, sql: sql, arguments: referenceArguments(work.project, ids)))
                }
            }
            for id in work.tasks.keys {
                guard selected[.init(project: projectKey, type: "task", id: id)] != nil else { throw referenceFailure("selected_task_unavailable") }
            }
        }
        var references: [TaskReferenceKey: CurrentTaskReference] = [:]
        for task in selected.values {
            for reference in try currentReferences(task) { references[reference.key] = reference }
        }
        // Bulk target reads are grouped by exact project/type, in bounded chunks.
        // No per-save FK walk, global scan or per-task target refetch is added.
        var groups: [TaskReferenceScope: [Data: String]] = [:]
        for reference in references.values {
            let group = TaskReferenceScope(project: Data(reference.project.utf8), type: reference.type)
            groups[group, default: [:]][Data(reference.id.utf8)] = reference.id
        }
        var targets: [TaskReferenceKey: DecodedEnvelope] = [:]
        for (group, ids) in groups {
            for chunk in referenceChunks(referenceOrder(ids)) {
                var values: [DatabaseValueConvertible] = [group.project, Data(group.type.utf8)]
                values += chunk.map { Data($0.utf8) as DatabaseValueConvertible }
                let sql = "SELECT " + Self.canonicalRecordColumns + " FROM records WHERE project_id=CAST(? AS TEXT) AND type=CAST(? AS TEXT) AND id IN (" + referencePlaceholders(chunk.count) + ") ORDER BY rowid"
                for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(values)) {
                    let target = try GRDBRecordEnvelopeAdapter.decode(row, expectedType: group.type)
                    let project = try StoredRecord(target.object, family: "reference_target").string("project_id")
                    targets[.init(project: Data(project.utf8), type: target.type, id: Data(target.id.utf8))] = target
                }
            }
        }
        for reference in references.values {
            guard let target = targets[reference.key] else { throw referenceFailure("reference_unavailable") }
            if reference.type == "group", target.object["kind"] as? String != "epic" { throw referenceFailure("epic_kind") }
        }
    }

    private func currentReferences(_ task: DecodedEnvelope) throws -> [CurrentTaskReference] {
        let value = task.object
        let project = try StoredRecord(value, family: "task").string("project_id")
        if bool(value,"purged") {
            let allowed: Set<String> = ["id","project_id","key","title","revision","purged","purged_at","purged_by","trashed","archived"]
            guard Set(value.keys).isSubset(of:allowed),value["title"] as? String == "Purged ticket",
                  !(value["key"] as? String ?? "").isEmpty,!(value["purged_at"] as? String ?? "").isEmpty,
                  !(value["purged_by"] as? String ?? "").isEmpty,bool(value,"trashed"),bool(value,"archived") else {throw referenceFailure("purged_ticket_shape")}
            return []
        }
        guard let status = value["status_id"] as? String, !status.isEmpty else { throw referenceFailure("status_shape") }
        var references = [CurrentTaskReference(project: project, type: "status", id: status)]
        if let raw = value["tag_ids"] {
            guard let tags = raw as? [String], tags.allSatisfy({ !$0.isEmpty }) else { throw referenceFailure("tag_shape") }
            references += tags.map { CurrentTaskReference(project: project, type: "tag", id: $0) }
        }
        if let raw = value["epic_id"] {
            guard let epic = raw as? String, !epic.isEmpty else { throw referenceFailure("epic_shape") }
            references.append(.init(project: project, type: "group", id: epic))
        }
        return references
    }

    private func inboundReferenceCandidate(_ type: String, placeholders: String) -> String {
        let field: String
        if type == "tag" {
            field = "CASE WHEN json_type(data,'$.tag_ids')='array' THEN EXISTS(SELECT 1 FROM json_each(data,'$.tag_ids') r WHERE r.type='text' AND r.value COLLATE BINARY IN (" + placeholders + ")) ELSE 0 END"
        } else {
            let key = type == "status" ? "status_id" : "epic_id"
            field = "CASE WHEN json_type(data,'$." + key + "')='text' THEN json_extract(data,'$." + key + "') COLLATE BINARY IN (" + placeholders + ") ELSE 0 END"
        }
        // A well-formed object with no exact typed edge is not an inbound task;
        // unrelated legacy invalid references are preserved rather than scanned.
        // Unreadable task payloads in a changed target's own project prevent
        // establishing its inbound set. Foreign projects are never selected.
        return "CASE WHEN json_valid(data) THEN CASE WHEN json_type(data)='object' THEN (" + field + ") ELSE 1 END ELSE 1 END"
    }

    private func referenceOrder(_ values: [Data: String]) -> [String] {
        values.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }).map(\.value)
    }
    private func referenceChunks(_ values: [String]) -> [[String]] {
        stride(from: 0, to: values.count, by: 128).map { Array(values[$0..<min($0 + 128, values.count)]) }
    }
    private func referencePlaceholders(_ count: Int) -> String { Array(repeating: "CAST(? AS TEXT)", count: count).joined(separator: ",") }
    private func referenceArguments(_ project: String, _ ids: [String]) -> StatementArguments {
        StatementArguments([Data(project.utf8)] + ids.map { Data($0.utf8) })
    }
    private func referenceFailure(_ reason: String) -> CoreError {
        CoreError("TASK_REFERENCE_INVALID", "This ticket's current references cannot be used safely. Authorized diagnosis is required.", details: ["reason": reason])
    }
    private func referenceBoundaryFailure() -> CoreError {
        CoreError("DOMAIN_TRANSACTION_REQUIRED", "This record change requires a complete validated boundary.")
    }
}
