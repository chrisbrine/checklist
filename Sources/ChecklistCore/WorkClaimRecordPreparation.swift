import Foundation
import GRDB

private struct WorkClaimRecordSnapshotChanged: Error {}

/// Writer-confined row IDs are enough to check membership of a reader selection.
/// Consuming queries repeat their predicates against current rows, including
/// deleted or moved rows. A new or changed candidate can add a missing row ID.
final class WorkClaimRecordChanges: TransactionObserver {
    struct Mark {
        fileprivate let sequence: UInt64
        fileprivate let dataVersion: Int64
        fileprivate let schemaVersion: Int64
    }

    private static let limit: UInt64 = 1024
    private var rowIDs = [Int64](repeating:0,count:Int(WorkClaimRecordChanges.limit))
    private var sequence: UInt64 = 0

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { eventKind.tableName == "records" }

    func databaseDidChange(with event: DatabaseEvent) {
        guard event.databaseName == "main", event.tableName == "records" else { return }
        rowIDs[Int(sequence % Self.limit)] = event.rowID
        sequence &+= 1
    }

    // An unspecified change abandons outstanding proofs. Rolled-back touches
    // can stay in the buffer because the validation reads only current rows.
    func databaseDidChange() { sequence &+= Self.limit + 1 }
    func databaseDidCommit(_ db: Database) {}
    func databaseDidRollback(_ db: Database) {}

    func mark(_ db: Database) throws -> Mark? {
        guard let dataVersion = try Int64.fetchOne(db.cachedStatement(sql:"PRAGMA main.data_version")),
              let schemaVersion = try Int64.fetchOne(db.cachedStatement(sql:"PRAGMA main.schema_version")) else { return nil }
        return .init(sequence:sequence,dataVersion:dataVersion,schemaVersion:schemaVersion)
    }

    func rowsSince(_ mark: Mark, in db: Database) throws -> [Int64]? {
        let age = sequence &- mark.sequence
        guard age <= Self.limit, let current = try self.mark(db),
              current.dataVersion == mark.dataVersion, current.schemaVersion == mark.schemaVersion else { return nil }
        return (0..<age).map { rowIDs[Int((mark.sequence &+ $0) % Self.limit)] }
    }
}

struct PreparedWorkClaimRecordSelection {
    fileprivate let selection: TaskRecordSelectionSnapshot
    fileprivate let mark: WorkClaimRecordChanges.Mark
    fileprivate let project: Data
    fileprivate let task: Data
    fileprivate let types: String
}

extension CommandRouter {
    private static let workClaimIncarnationSQL = "SELECT value FROM metadata WHERE key='incarnation'"

    func withWorkClaimRecordPreparation<T>(params: JSON, caller: Caller,
        commit: (PreparedWorkClaimRecordSelection?) throws -> T) throws -> T
    {
        guard let command = try? text(params, "command_id", max: 100), UUID(uuidString: command) != nil,
              let reader = try? openMaintenanceReader() else { return try commit(nil) }
        defer { try? reader.close() }

        for _ in 0..<2 {
            // Start the observation before pinning a reader snapshot. The mark
            // and the later check use the same writer connection.
            guard let mark = try? dbQueue.writeWithoutTransaction(work:"work_claim_record_fence",{
                try workClaimRecordChanges.mark($0)
            }) else { break }
            // The writer remains the owner of all authority, errors and idempotency.
            // A failed optional preparation takes the original command path.
            let prepared = try? reader.read { db in
                try autoreleasepool {
                    try self.prepareWorkClaimRecords(db, params: params, caller: caller, command: command, mark: mark)
                }
            }
            do {
                return try commit(prepared)
            } catch is WorkClaimRecordSnapshotChanged {
                // Retry after releasing the writer and object gate.
            }
        }
        return try commit(nil)
    }

    private func prepareWorkClaimRecords(_ db: Database, params: JSON, caller: Caller, command: String,
        mark: WorkClaimRecordChanges.Mark) throws -> PreparedWorkClaimRecordSelection?
    {
        // The writer checks receipts again, including conflicts and pruned results.
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM commands WHERE principal=? AND command_id=?)",
            arguments: [caller.principal, command]) == true { return nil }
        guard try String.fetchOne(db.cachedStatement(sql: Self.workClaimIncarnationSQL)) == incarnation else { return nil }
        try worker(caller)
        let project = try scope(db, params, caller, write: true)
        let task = try self.task(db, params, project)
        try revision(params, task)

        // A review claim changes its request before projection. The claim's
        // new attempt is added to its selected family by the successful insert.
        var types = ["message", "finding", "request", "review", "attempt", "manifest", "attachment", "task_alias",
            "task_session", "finding_resolution"]
        if params["phase"] as? String != "review" { types.append("review_request") }
        let selection = try prepareTaskRecordSelection(db, task: task, types: types)
        let identity = try StoredTaskRecord(task)
        return .init(selection:selection,mark:mark,project:Data(project.utf8),task:Data(identity.id.utf8),types:try jsonString(types))
    }

    func withPreparedWorkClaimRecordSelection<T>(_ db: Database, prepared: PreparedWorkClaimRecordSelection?,
        _ body: () throws -> T) throws -> T
    {
        guard let prepared else { return try body() }
        // Pin this transaction before checking the mark. A later external WAL
        // write makes SQLite refuse to upgrade the snapshot to a write.
        guard db.isInsideTransaction,
              try String.fetchOne(db.cachedStatement(sql:Self.workClaimIncarnationSQL)) == incarnation,
              let changed = try workClaimRecordChanges.rowsSince(prepared.mark,in:db) else {
            throw WorkClaimRecordSnapshotChanged()
        }
        if !changed.isEmpty {
            let sql = """
                SELECT EXISTS(SELECT 1 FROM json_each(?) changed CROSS JOIN records r ON r.rowid=changed.value
                WHERE CASE WHEN r.project_id=CAST(? AS TEXT) AND r.type IN (SELECT value FROM json_each(?))
                    THEN CASE WHEN json_valid(r.data) THEN CAST(json_extract(r.data,'$.task_id') AS BLOB)=? ELSE 1 END
                    ELSE 0 END)
                """
            if try Bool.fetchOne(db.cachedStatement(sql:sql),arguments:[try jsonString(changed),prepared.project,prepared.types,prepared.task]) == true {
                throw WorkClaimRecordSnapshotChanged()
            }
        }
        return try withTaskRecordSelectionSnapshot(db, snapshot: prepared.selection, body)
    }
}
