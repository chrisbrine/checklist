import Foundation
import GRDB
import CryptoKit

/// Ephemeral preparation only; the service store remains the sole durable authority.
/// Keep the observing connection alive: SQLite data_version is comparable only on
/// the SAME connection, and detects other connections' commits, including same-revision
/// edits. The writer checks it after BEGIN IMMEDIATE, when no other writer can commit.
/// CL-307: when data_version moved, the writer compares only the media records the
/// command read (revision and payload digest) and the project's media insert marks, so
/// unrelated writes (ticket cleanup, work health, notes) never refuse a media command.
struct PreparedMediaCommand {
    /// A media record the preparation read: its revision and payload digest.
    struct Observed: Equatable { let revision: Int64; let digest: Data }
    struct Write {
        let id: Data
        let project: Data
        let type: Data
        let revision: Int64
        let data: Data
        let previousRevision: Int64?
    }
    let observer: DatabaseQueue
    let dataVersion: Int64
    let project: String
    let writes: [Write]
    let result: JSON
    let encodedResult: String
    let resources: PreparedMediaResources
    var observed: [Data: Observed] = [:]
    var insertMarks: [Int64?] = []
    /// Durable records (and their canonical payload bytes) that preparation read through
    /// the overlay. They scale with the records the command touches, not the project size.
    var readRecords = 0
    var readBytes = 0

    func commit(_ db: Database,router: CommandRouter? = nil,caller: Caller? = nil) throws {
        let current = try observer.read { try Int64.fetchOne($0,sql:"PRAGMA data_version")! }
        if current != dataVersion {
            // Another connection committed: refuse only when a record this command read or
            // writes changed, or a new media record of this project appeared.
            for (id,seen) in observed {
                let row = try Row.fetchOne(db,sql:"SELECT revision,CAST(data AS BLOB) AS data FROM records WHERE id=CAST(? AS TEXT)",arguments:[id])
                guard let row,row["revision"] as Int64 == seen.revision,MediaPreparationOverlay.digest(row["data"] as Data? ?? Data()) == seen.digest else {
                    throw CoreError("MEDIA_CONTEXT_CHANGED","A media record this command uses changed during preparation. Refresh and retry. No records changed.")
                }
            }
            guard try MediaPreparationOverlay.insertMarks(db,project:project) == insertMarks else {
                throw CoreError("MEDIA_CONTEXT_CHANGED","New media records were added during preparation. Refresh and retry. No records changed.")
            }
        }
        guard resources.captures.isEmpty && resources.originals.isEmpty || router != nil && caller != nil else {
            throw CoreError("MEDIA_CAPTURE_REQUIRED","Prepared file checks require the owning router and current caller.")
        }
        for capture in resources.captures.values {
            try router!.validateMediaAttachmentImport(db,project:project,owner:capture.owner,prepared:capture.prepared,caller:caller!)
        }
        for original in resources.originals { _ = try router!.validatePreparedAttachment(db,project:project,prepared:original) }
        for write in writes {
            if let previous = write.previousRevision {
                try db.execute(sql:"UPDATE records SET revision=?,data=CAST(? AS TEXT) WHERE id=CAST(? AS TEXT) AND project_id=CAST(? AS TEXT) AND type=CAST(? AS TEXT) AND revision=?",arguments:[write.revision,write.data,write.id,write.project,write.type,previous])
                guard db.changesCount == 1 else { throw CoreError("MEDIA_CONTEXT_CHANGED","A prepared media identity changed. No records changed.") }
            } else {
                try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES (CAST(? AS TEXT),CAST(? AS TEXT),CAST(? AS TEXT),?,CAST(? AS TEXT))",arguments:[write.id,write.project,write.type,write.revision,write.data])
            }
        }
        for capture in resources.captures.values {
            let prepared = capture.prepared
            try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[prepared.principal,prepared.command,prepared.digest,capture.encodedReceipt])
        }
    }
}

/// CL-307: a copy-on-write overlay over the read-only snapshot. A TEMP view named
/// `records` shadows the durable table on the preparation connection only; reads use the
/// durable indexes and see only the records a command asks for, and writes land in a
/// TEMP table. The connection opens read-only, so the durable file cannot change.
enum MediaPreparationOverlay {
    static let label = "checklist.media-preparation"
    final class Reads: @unchecked Sendable { var records = 0; var bytes = 0; var observed: [Data: PreparedMediaCommand.Observed] = [:] }
    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data:data)) }
    /// The highest rowid of each media family in the project (indexed by records_scope).
    /// A new media record raises one, so a concurrent insert the command could have read
    /// (an item in its round, a row of its intake) still refuses the prepared command.
    static func insertMarks(_ db: Database,project: String) throws -> [Int64?] {
        try MediaRecordRegistry.families.sorted().map { type in
            try Int64.fetchOne(db,sql:"SELECT max(rowid) FROM main.records WHERE project_id=CAST(? AS TEXT) AND type=CAST(? AS TEXT)",arguments:[Data(project.utf8),Data(type.utf8)])
        }
    }

    private static func literal(_ value: String) -> String {
        "CAST(x'" + Data(value.utf8).map { String(format:"%02x",$0) }.joined() + "' AS TEXT)"
    }
    static func install(_ db: Database,project: String,session: String,reads: Reads) throws {
        db.add(function:DatabaseFunction("checklist_media_prepared_read",argumentCount:4,pure:true) { values in
            let data = Data.fromDatabaseValue(values[3]) ?? Data()
            reads.records += 1;reads.bytes += data.count
            // Fence every media record read (first observation; the snapshot is pinned).
            if let type = String.fromDatabaseValue(values[1]),MediaRecordRegistry.families.contains(type),
               let id = Data.fromDatabaseValue(values[0]),reads.observed[id] == nil {
                reads.observed[id] = .init(revision:Int64.fromDatabaseValue(values[2]) ?? 0,digest:digest(data))
            }
            return 1
        })
        let pid = literal(project),sid = literal(session)
        // Same visibility as the former workspace copy: this project's records, the project
        // record and the caller's session. New rows sort after every durable rowid.
        // V43A: the TEMP columns use the durable storage collation. A view column takes its
        // collation from the left-most arm; with BINARY there, `id=?` on the view could not
        // use the durable ID index and every ID lookup read the whole project.
        let text = "TEXT COLLATE " + SchemaMigrations.storageCollation
        try db.execute(sql:"""
        CREATE TEMP TABLE media_prepared(id \(text) PRIMARY KEY,project_id \(text),type \(text) NOT NULL,revision INTEGER NOT NULL,data \(text) NOT NULL,rid INTEGER NOT NULL);
        CREATE TEMP VIEW records(rowid,id,project_id,type,revision,data) AS
          SELECT rid,id,project_id,type,revision,data FROM temp.media_prepared
          UNION ALL
          SELECT s.rowid,s.id,s.project_id,s.type,s.revision,s.data FROM main.records s
          WHERE (s.project_id=\(pid) OR s.id=\(pid) OR s.id=\(sid))
            AND NOT EXISTS(SELECT 1 FROM temp.media_prepared o WHERE o.id=s.id)
            AND checklist_media_prepared_read(CAST(s.id AS BLOB),s.type,s.revision,CAST(s.data AS BLOB));
        CREATE TEMP TRIGGER media_prepared_insert INSTEAD OF INSERT ON records BEGIN
          SELECT RAISE(ABORT,'UNIQUE constraint failed: records.id')
            WHERE EXISTS(SELECT 1 FROM temp.media_prepared WHERE id=NEW.id) OR EXISTS(SELECT 1 FROM main.records WHERE id=NEW.id);
          INSERT INTO temp.media_prepared(id,project_id,type,revision,data,rid)
            VALUES(NEW.id,NEW.project_id,NEW.type,NEW.revision,NEW.data,4611686018427387904+(SELECT count(*) FROM temp.media_prepared));
        END;
        CREATE TEMP TRIGGER media_prepared_update INSTEAD OF UPDATE ON records BEGIN
          SELECT RAISE(ABORT,'Media preparation cannot change a record identity.') WHERE NEW.id IS NOT OLD.id;
          INSERT OR REPLACE INTO temp.media_prepared(id,project_id,type,revision,data,rid)
            VALUES(NEW.id,NEW.project_id,NEW.type,NEW.revision,NEW.data,
              COALESCE((SELECT rid FROM temp.media_prepared WHERE id=OLD.id),(SELECT rowid FROM main.records WHERE id=OLD.id)));
        END;
        CREATE TEMP TRIGGER media_prepared_delete INSTEAD OF DELETE ON records BEGIN
          SELECT RAISE(ABORT,'Media preparation cannot delete records.');
        END;
        """)
    }
    /// Every row the command wrote, in byte order of its ID.
    static func changed(_ db: Database) throws -> [DecodedEnvelope] {
        try Row.fetchAll(db,sql:"SELECT " + CommandRouter.canonicalRecordColumns + " FROM temp.media_prepared ORDER BY id COLLATE BINARY").map { try GRDBRecordEnvelopeAdapter.decode($0) }
    }
    /// The declared dependencies of the changed rows, resolved through the same overlay
    /// (prepared rows first, then the snapshot) with indexed ID reads.
    static func dependencies(_ db: Database,of changed: [DecodedEnvelope]) throws -> [DecodedEnvelope] {
        var ids = Set<String>()
        for envelope in changed {
            let value = envelope.object
            for reference in value["record_references"] as? [JSON] ?? [] { if let id = reference["id"] as? String { ids.insert(id) } }
            for key in ["attachment_owner_id","owner_id","attachment_id"] { if let id = value[key] as? String { ids.insert(id) } }
        }
        ids.subtract(changed.map(\.id))
        // One primary-key read per ID: an IN-list over json_each is not pushed into the view.
        return try ids.sorted().compactMap { id in
            try Row.fetchOne(db,sql:"SELECT " + CommandRouter.canonicalRecordColumns + " FROM records WHERE id = CAST(? AS TEXT)",arguments:[Data(id.utf8)]).map { try GRDBRecordEnvelopeAdapter.decode($0) }
        }
    }
}

extension CommandRouter {
    /// CL-71 pattern for metadata: read/decode/validate/hash before the gate/writer,
    /// then commit only the prepared rows behind an unchanged snapshot identity.
    /// CL-307: the overlay reads only the records the command touches plus the declared
    /// dependencies of what it writes, so time and memory follow the command, not the
    /// project size. It has no filesystem capture, event, receipt or publication.
    func prepareMediaCommand(method: String,params p: JSON,caller c: Caller,resources: PreparedMediaResources = .init()) throws -> PreparedMediaCommand? {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.label = MediaPreparationOverlay.label
        configuration.prepareDatabase { db in
            try SchemaMigrations.installStorageCollation(db)
            try db.execute(sql:"PRAGMA temp_store=MEMORY")
        }
        let observer = try DatabaseQueue(path:root.appendingPathComponent("checklist.sqlite").path,configuration:configuration)
        var prepared: PreparedMediaCommand?
        do {
            try observer.inDatabase { db in
                // The transaction pins one snapshot; ROLLBACK discards the TEMP overlay.
                try db.inTransaction(.deferred) {
                    prepared = try self.prepareMediaOverlay(db,observer:observer,method:method,p:p,c:c,resources:resources)
                    return .rollback
                }
            }
        } catch { try? observer.close();throw error }
        if prepared == nil { try? observer.close() }
        return prepared
    }

    private func prepareMediaOverlay(_ db: Database,observer: DatabaseQueue,method: String,p: JSON,c: Caller,resources: PreparedMediaResources) throws -> PreparedMediaCommand? {
        let version = try Int64.fetchOne(db,sql:"PRAGMA data_version")!
        let pid = try self.mediaAccess(db,p,c,write:true)
        let command = (try StoredRecord(p, family: "media").string("command_id"))
        let digest = hash(Data((method + (try jsonString(p))).utf8))
        try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:c)
        // Preserve replay behavior even if the original command's target changed.
        if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM commands WHERE principal=? AND command_id=?)",arguments:[c.principal,command]) == true { return nil }
        let reads = MediaPreparationOverlay.Reads()
        try MediaPreparationOverlay.install(db,project:pid,session:c.sessionID ?? "",reads:reads)
        let result = try self.mediaCommand(db,method:method,p:p,c:c,project:pid,resources:resources)
        // Same-project dependencies of every prepared row are checked on the final
        // prepared overlay, not an intermediate graph or a moving durable head.
        let changed = try MediaPreparationOverlay.changed(db).filter { EnvelopeStorageIdentity.equal($0.projectID,pid) }
        try MediaRecordRegistry.validate(changed,dependencies:try MediaPreparationOverlay.dependencies(db,of:changed))
        var writes: [PreparedMediaCommand.Write] = []
        for envelope in changed {
            guard case .text(let raw) = envelope.original.data else { throw CoreError("MEDIA_CAPTURE_INCOMPLETE","A prepared media payload is unavailable.") }
            let key = Data(envelope.id.utf8),data = Data(raw.utf8)
            let original = try Row.fetchOne(db,sql:"SELECT revision,CAST(data AS BLOB) AS data FROM main.records WHERE id=CAST(? AS TEXT) AND project_id=CAST(? AS TEXT)",arguments:[key,Data(pid.utf8)])
            if let original,(original["data"] as Data?) == data { continue }
            guard MediaRecordRegistry.families.contains(envelope.type) || resources.allows(envelope) else { throw CoreError("MEDIA_CAPTURE_INCOMPLETE","Media preparation may change only registered media records.") }
            writes.append(.init(id:key,project:Data(pid.utf8),type:Data(envelope.type.utf8),revision:envelope.revision,data:data,previousRevision:original.map { $0["revision"] as Int64 }))
        }
        var prepared = PreparedMediaCommand(observer:observer,dataVersion:version,project:pid,writes:writes,result:result,encodedResult:try jsonString(result),resources:resources)
        prepared.readRecords = reads.records;prepared.readBytes = reads.bytes
        prepared.observed = reads.observed;prepared.insertMarks = try MediaPreparationOverlay.insertMarks(db,project:pid)
        return prepared
    }
}
