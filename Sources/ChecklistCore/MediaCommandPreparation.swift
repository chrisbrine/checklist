import Foundation
import GRDB

/// Ephemeral preparation only; the service store remains the sole durable authority.
/// Keep the observing connection alive: SQLite data_version is comparable only on
/// the SAME connection, and detects other connections' commits, including same-revision
/// edits. The writer checks it after BEGIN IMMEDIATE, when no other writer can commit.
struct PreparedMediaCommand {
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

    func commit(_ db: Database,router: CommandRouter? = nil,caller: Caller? = nil) throws {
        let current = try observer.read { try Int64.fetchOne($0,sql:"PRAGMA data_version")! }
        guard current == dataVersion else {
            throw CoreError("MEDIA_CONTEXT_CHANGED","The store changed during media preparation. Refresh and retry. No records changed.")
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

extension CommandRouter {
    /// CL-71 pattern for metadata: read/decode/validate/hash before the gate/writer,
    /// then commit only the prepared rows behind an unchanged snapshot identity.
    /// The bounded in-memory workspace exercises the same domain code and canonical
    /// save checks; it has no filesystem capture, event, receipt or publication.
    func prepareMediaCommand(method: String,params p: JSON,caller c: Caller,resources: PreparedMediaResources = .init()) throws -> PreparedMediaCommand? {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { try SchemaMigrations.installStorageCollation($0) }
        let observer = try DatabaseQueue(path:root.appendingPathComponent("checklist.sqlite").path,configuration:configuration)
        let scratch = try DatabaseQueue()
        defer { try? scratch.close() }
        return try observer.read { source in
            let version = try Int64.fetchOne(source,sql:"PRAGMA data_version")!
            let pid = try self.mediaAccess(source,p,c,write:true)
            let command = p["command_id"] as! String
            let digest = hash(Data((method + (try jsonString(p))).utf8))
            try self.requirePendingCommandIntent(source,command:command,digest:digest,caller:c)
            // Preserve replay behavior even if the original command's target changed.
            if try Bool.fetchOne(source,sql:"SELECT EXISTS(SELECT 1 FROM commands WHERE principal=? AND command_id=?)",arguments:[c.principal,command]) == true { return nil }
            return try scratch.write { db in
                try SchemaMigrations.installStorageCollation(db)
                try db.execute(sql:"CREATE TABLE records(id TEXT PRIMARY KEY,project_id TEXT,type TEXT NOT NULL,revision INTEGER NOT NULL,data TEXT NOT NULL)")
                let rows = try Row.fetchCursor(source,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE project_id=CAST(? AS TEXT) OR id=CAST(? AS TEXT) OR id=CAST(? AS TEXT) ORDER BY rowid LIMIT 100001",arguments:[Data(pid.utf8),Data(pid.utf8),Data((c.sessionID ?? "").utf8)])
                var originals: [Data:(revision:Int64,data:Data)] = [:]
                var bytes = 0
                while let row = try rows.next() {
                    let raw: Data = row["_envelope_data_bytes"]
                    bytes += raw.count
                    guard originals.count < 100_000,bytes <= 128 * 1024 * 1024 else {
                        throw CoreError("CAPACITY_EXCEEDED","Media preparation is limited to 100,000 records and 128 MiB of canonical payloads.")
                    }
                    let envelope = try GRDBRecordEnvelopeAdapter.decode(row)
                    let key = Data(envelope.id.utf8)
                    originals[key] = (envelope.revision,raw)
                    try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES (CAST(? AS TEXT),CAST(? AS TEXT),CAST(? AS TEXT),?,CAST(? AS TEXT))",arguments:[key,envelope.projectID.map {Data($0.utf8)},Data(envelope.type.utf8),envelope.revision,raw])
                }
                let result = try self.mediaCommand(db,method:method,p:p,c:c,project:pid,resources:resources)
                // Complete same-project dependencies are checked on the final prepared
                // graph, not an incomplete intermediate graph or a moving durable head.
                let final = try MediaRecordRegistry.envelopes(db,project:pid)
                try MediaRecordRegistry.validate(final)
                var writes: [PreparedMediaCommand.Write] = []
                for envelope in final {
                    guard case .text(let raw) = envelope.original.data else { throw CoreError("MEDIA_CAPTURE_INCOMPLETE","A prepared media payload is unavailable.") }
                    let key = Data(envelope.id.utf8),data = Data(raw.utf8)
                    if originals[key]?.data == data { continue }
                    guard MediaRecordRegistry.families.contains(envelope.type) || resources.allows(envelope) else { throw CoreError("MEDIA_CAPTURE_INCOMPLETE","Media preparation may change only registered media records.") }
                    writes.append(.init(id:key,project:Data(pid.utf8),type:Data(envelope.type.utf8),revision:envelope.revision,data:data,previousRevision:originals[key]?.revision))
                }
                return PreparedMediaCommand(observer:observer,dataVersion:version,project:pid,writes:writes,result:result,encodedResult:try jsonString(result),resources:resources)
            }
        }
    }
}
