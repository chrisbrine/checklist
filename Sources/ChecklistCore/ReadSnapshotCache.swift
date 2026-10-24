import Foundation
import GRDB
import CryptoKit
import SQLite3

/// Canonical records only: projections, time-dependent health, authority and
/// cursors are recomputed on every request. One bounded snapshot is retained.
final class ReadSnapshotCache {
    private final class Snapshot {
        weak var database: Database?
        let version: Int
        let namespace: Data
        var entries: [Data:[JSON]] = [:]
        var bytes = 0
        var records = 0
        init(_ db: Database, version: Int, namespace: Data) {
            database = db; self.version = version; self.namespace = namespace
        }
    }
    private final class Frame {
        let snapshot: Snapshot
        let readVersion: String?
        init(_ snapshot: Snapshot,readVersion: String?) {self.snapshot=snapshot;self.readVersion=readVersion}
    }
    private let lock = NSLock()
    private let contextKey = "ChecklistReadSnapshot-" + UUID().uuidString
    private var retained: Snapshot?
    private let versionKey = SymmetricKey(size:.bits256)

    /// Display identity is independent of which canonical-record cache happens
    /// to be retained. Interleaved callers/readers cannot rotate an unchanged
    /// caller's token. No SQLite snapshot bytes or local counters leave Core.
    func readVersion(_ db: Database) -> String? {
        guard let frame = Thread.current.threadDictionary[contextKey] as? Frame,frame.snapshot.database === db else {return nil}
        return frame.readVersion
    }

    private func snapshotReadVersion(_ db: Database,namespace: Data) -> String? {
        var snapshot: UnsafeMutablePointer<sqlite3_snapshot>?
        guard sqlite3_snapshot_get(db.sqliteConnection,"main",&snapshot) == SQLITE_OK,let snapshot else {
            // Empty WAL and non-WAL stores have no comparable snapshot handle.
            // Omit reusable display identity instead of guessing from a reader's
            // connection-local data_version. Canonical caching remains scoped.
            return nil
        }
        defer {sqlite3_snapshot_free(snapshot)}
        // Treat the complete fixed-size handle as opaque bytes. The keyed digest
        // is deterministic for this pinned WAL snapshot and exact caller scope,
        // including when an older reader finishes after a newer commit. It needs
        // no retained handles, per-caller map or growing generation history.
        var identity = Data(bytes:snapshot,count:MemoryLayout<sqlite3_snapshot>.size)
        identity.append(namespace)
        return "r2." + Data(HMAC<SHA256>.authenticationCode(for:identity,using:versionKey)).base64EncodedString()
    }

    func withSnapshot<T>(_ db: Database, caller: Caller, body: () throws -> T) throws -> T {
        // Foundation parsing and Thread dictionary bridging can autorelease
        // decoded payloads and boxed generations. Drain them before the next
        // command, even when the service queue inherits a long-lived pool.
        return try autoreleasepool {
            guard db.configuration.readonly else {return try body()}
            // DatabasePool.read pins a transaction before this pragma. data_version
            // belongs to this exact connection and changes on every external commit,
            // including maintenance, deletes and writes that emit no domain event.
            let version = try Int.fetchOne(db,sql:"PRAGMA data_version") ?? -1
            let namespace = Data(try jsonString(["role":caller.role,"installation":caller.installation,
                "projects":caller.projectIDs,"session":caller.sessionID ?? NSNull(),"workspace":caller.workspace ?? NSNull(),
                "grants":caller.assistantGrants,"domain":caller.executionDomain ?? NSNull(),"locale":Locale.current.identifier]).utf8)
            let snapshot = lock.withLock { () -> Snapshot in
                if let retained,retained.database === db,retained.version == version,retained.namespace == namespace {return retained}
                let value = Snapshot(db,version:version,namespace:namespace);retained = value;return value
            }
            let previous = Thread.current.threadDictionary[contextKey]
            Thread.current.threadDictionary[contextKey] = Frame(snapshot,readVersion:snapshotReadVersion(db,namespace:namespace))
            defer {Thread.current.threadDictionary[contextKey] = previous}
            return try body()
        }
    }

    func records(_ db: Database, key: [String?], load: () throws -> [Row]) throws -> [JSON] {
        guard let frame = Thread.current.threadDictionary[contextKey] as? Frame,frame.snapshot.database === db else {
            return try load().map {try GRDBRecordEnvelopeAdapter.decode($0).object}
        }
        let snapshot = frame.snapshot
        let key = Data(try jsonString(key.map {$0 as Any? ?? NSNull()}).utf8)
        if let value = snapshot.entries[key] {return value}
        let rows = try load()
        let values = try rows.map {try GRDBRecordEnvelopeAdapter.decode($0).object}
        let bytes = rows.reduce(0) {$0 + (($1["_envelope_data_bytes"] as Data?)?.count ?? 0)}
        // Count and encoded-byte bounds keep history corpora from becoming an
        // unbounded cache under traffic. Oversized reads are never retained.
        if values.count <= 2048 && bytes <= 4 * 1024 * 1024 {
            if snapshot.records + values.count > 2048 || snapshot.bytes + bytes > 4 * 1024 * 1024 || snapshot.entries.count >= 256 {
                snapshot.entries.removeAll(keepingCapacity:true);snapshot.bytes = 0;snapshot.records = 0
            }
            snapshot.entries[key] = values;snapshot.bytes += bytes;snapshot.records += values.count
        }
        return values
    }
}
