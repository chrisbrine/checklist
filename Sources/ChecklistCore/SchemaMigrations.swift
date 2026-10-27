import Foundation
import GRDB
import SQLite3
import CryptoKit

struct StoreIdentityReceipt: Codable, Equatable {
    static let fileName = "checklist-store.identity.json"
    let format_version: Int
    let logical_store_id: String
    let incarnation: String
    let database_generation: Int
    let schema_revision: Int
    let state: String
    func withState(_ state: String) -> Self {
        Self(format_version: format_version, logical_store_id: logical_store_id, incarnation: incarnation, database_generation: database_generation, schema_revision: schema_revision, state: state)
    }
    func withSchema(_ revision: Int) -> Self {
        Self(format_version:format_version,logical_store_id:logical_store_id,incarnation:incarnation,database_generation:database_generation,schema_revision:revision,state:state)
    }
    func encoded() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(self) }
    static func decode(_ bytes: Data) throws -> Self {
        let keys: Set<String> = ["format_version", "logical_store_id", "incarnation", "database_generation", "schema_revision", "state"]
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? JSON, Set(object.keys) == keys,
              let value = try? JSONDecoder().decode(Self.self, from: bytes) else { throw StoreRecovery.required("invalid_identity_receipt") }
        guard value.format_version == 1, (1...4).contains(value.schema_revision) else { throw StoreRecovery.upgradeUnavailable() }
        guard UUID(uuidString: value.logical_store_id) != nil, UUID(uuidString: value.incarnation) != nil,
              value.database_generation == 1, ["preparing", "ready"].contains(value.state) else { throw StoreRecovery.required("invalid_identity_receipt") }
        return value
    }
}

/// Ordered immutable migration definitions. Incompatible/future versions are
/// refused; supported apply requires copy rehearsal and a protected snapshot at
/// bootstrap under the exclusive supported-service lifetime lease.
enum SchemaMigrations {
    static let baselineSQL = """
    CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, project_id TEXT, type TEXT NOT NULL, revision INTEGER NOT NULL, data TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS records_scope ON records(project_id,type);
    CREATE TABLE IF NOT EXISTS commands(principal TEXT NOT NULL, command_id TEXT NOT NULL, digest TEXT NOT NULL, result TEXT NOT NULL, PRIMARY KEY(principal,command_id));
    CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, project_id TEXT, entity_id TEXT, actor TEXT NOT NULL, kind TEXT NOT NULL, occurred_at TEXT NOT NULL, data TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS events_scope ON events(project_id,entity_id,seq);
    CREATE TABLE IF NOT EXISTS cursors(token TEXT PRIMARY KEY, principal TEXT NOT NULL, scope TEXT NOT NULL, sequence INTEGER NOT NULL, incarnation TEXT NOT NULL, created_at REAL NOT NULL);
    """
    static let incarnationSQL = "INSERT INTO metadata(key,value) VALUES ('incarnation',?)"
    static let enrollmentSQL = "INSERT INTO metadata(key,value) VALUES ('store_identity',?),('schema_migrations',?)"
    static let versionSQL = "PRAGMA user_version=1"
    static var definitionChecksum: String {
        let definition = [baselineSQL, incarnationSQL, enrollmentSQL, versionSQL,
                          "identity-format=1;schema=1;generation=1;reader-min=0;writer-min=0;writer-max=1;phase=applied"].joined(separator: "\n-- next bootstrap definition --\n")
        return hash(Data(definition.utf8))
    }
    static var ledger: JSON { ["migration_id": "0001-compatible-baseline-identity", "checksum": definitionChecksum, "from_version": 0, "to_version": 1, "minimum_reader": 0, "minimum_writer": 0, "maximum_writer": 1, "phase": "applied"] }
    static let storageCollation = "checklist_storage_v2"
    static func installStorageCollation(_ db: Database) throws {
        // Length-aware raw bytes, including NUL and malformed UTF-8. No String
        // decoding/normalization and no fatal-on-registration GRDB wrapper.
        let rc = sqlite3_create_collation_v2(db.sqliteConnection, storageCollation, SQLITE_UTF8, nil, { _, an, ap, bn, bp in
            let n = min(an,bn)
            if n > 0,let ap,let bp {
                let order = memcmp(ap,bp,Int(n))
                if order != 0 { return order < 0 ? -1 : 1 }
            }
            return an == bn ? 0 : (an < bn ? -1 : 1)
        }, nil)
        guard rc == SQLITE_OK else { throw StoreRecovery.required("storage_collation_registration_failed") }
    }
    static var currentSQL: String {
        baselineSQL.replacingOccurrences(of:" TEXT",with:" TEXT COLLATE " + storageCollation)
    }
    static var protocolChecksum: String {
        hash(Data((currentSQL + "\nraw-utf8-binary-v2;preserve-rowids-event-sequence;reader=2;writer=2;repair-forward-only").utf8))
    }
    static var protocolLedger: JSON { ["migration_id":"0002-storage-authority-protocol","checksum":protocolChecksum,"from_version":1,"to_version":2,"minimum_reader":2,"minimum_writer":2,"maximum_writer":2,"phase":"applied"] }
    static func upgradeProtocol(_ db: Database, identity: StoreIdentityReceipt, protectedSnapshot: JSON) throws {
        guard case .current(let old) = try inspect(db), old.schema_revision == 1,
              old.logical_store_id == identity.logical_store_id, old.incarnation == identity.incarnation else { throw StoreRecovery.required("migration_source_changed") }
        // Full transaction: on failure the original tables and receipts survive.
        // Event AUTOINCREMENT and every rowid are preserved, including deleted-seq high water.
        let sequence = try Int64.fetchOne(db,sql:"SELECT seq FROM sqlite_sequence WHERE name='events'") ?? 0
        for table in ["metadata","records","commands","events","cursors"] { try db.execute(sql:"ALTER TABLE " + table + " RENAME TO " + table + "_v1") }
        try db.execute(sql:"DROP INDEX records_scope; DROP INDEX events_scope")
        try db.execute(sql:currentSQL)
        // Preserve the rowid itself for tables whose bounded pages order by it.
        for table in ["metadata","records","commands","cursors"] {
            try db.execute(sql:"INSERT INTO " + table + "(rowid," + (try Row.fetchAll(db,sql:"PRAGMA table_info(" + table + ")")).map { $0["name"] as String }.joined(separator:",") + ") SELECT rowid,* FROM " + table + "_v1 ORDER BY rowid")
        }
        try db.execute(sql:"INSERT INTO events SELECT * FROM events_v1 ORDER BY seq")
        try db.execute(sql:"INSERT INTO sqlite_sequence(name,seq) SELECT 'events',? WHERE NOT EXISTS(SELECT 1 FROM sqlite_sequence WHERE name='events')",arguments:[sequence])
        try db.execute(sql:"UPDATE sqlite_sequence SET seq=MAX(seq,?) WHERE name='events'",arguments:[sequence])
        for table in ["metadata","records","commands","events","cursors"] { try db.execute(sql:"DROP TABLE " + table + "_v1") }
        let ready = identity.withSchema(2).withState("ready")
        try db.execute(sql:"UPDATE metadata SET value=? WHERE key='store_identity'",arguments:[String(decoding:try ready.encoded(),as:UTF8.self)])
        try db.execute(sql:"UPDATE metadata SET value=? WHERE key='schema_migrations'",arguments:[try jsonString([ledger,protocolLedger])])
        try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('preupgrade_snapshot',?)",arguments:[try jsonString(protectedSnapshot)])
        try db.execute(sql:"PRAGMA user_version=2")
        guard case .current(let actual) = try inspect(db), actual == ready else { throw StoreRecovery.required("migration_result_invalid") }
    }
    static var managedPathsChecksum: String { hash(Data("0003-instance-local-managed-paths;reader=3;writer=3;protected-relative-rewrite;single-origin-local-content-proof;immutable-manifest-capture-sidecar".utf8)) }
    /// 0004 (CL-125): one orchestrator per Triage, one Triage per ticket, plans and
    /// automatic archive of empty plans (docs/triage-orchestrators.md#store-upgrade-rules).
    static let currentSchema = 4
    static var triageMembershipChecksum: String { hash(Data("0004-triage-orchestrator-membership;reader=4;writer=4;one-triage-per-ticket;upgrade-single-membership;plans;empty-plan-archive;phase-history-label".utf8)) }
    static var triageMembershipLedger: JSON { ["migration_id":"0004-triage-orchestrator-membership","checksum":triageMembershipChecksum,"from_version":3,"to_version":4,"minimum_reader":4,"minimum_writer":4,"maximum_writer":4,"phase":"applied"] }
    static func ledgers(_ version: Int) -> [JSON] { Array([ledger,protocolLedger,managedPathsLedger,triageMembershipLedger].prefix(max(0,version))) }
    static func upgradeTriageMembership(_ db: Database, identity: StoreIdentityReceipt, protectedSnapshot: JSON) throws {
        guard case .current(let old) = try inspect(db), old.schema_revision == 3,
              old.logical_store_id == identity.logical_store_id, old.incarnation == identity.incarnation else { throw StoreRecovery.required("migration_source_changed") }
        try TriageMembershipUpgrade.apply(db)
        let ready = identity.withSchema(4).withState("ready")
        try db.execute(sql:"UPDATE metadata SET value=? WHERE key='store_identity'",arguments:[String(decoding:try ready.encoded(),as:UTF8.self)])
        try db.execute(sql:"UPDATE metadata SET value=? WHERE key='schema_migrations'",arguments:[try jsonString(ledgers(4))])
        try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('preupgrade_snapshot',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[try jsonString(protectedSnapshot)])
        try db.execute(sql:"PRAGMA user_version=4")
        guard case .current(let actual) = try inspect(db), actual == ready else { throw StoreRecovery.required("migration_result_invalid") }
    }
    static var managedPathsLedger: JSON { ["migration_id":"0003-instance-local-managed-paths","checksum":managedPathsChecksum,"from_version":2,"to_version":3,"minimum_reader":3,"minimum_writer":3,"maximum_writer":3,"phase":"applied"] }
    static func upgradeManagedPaths(_ db: Database, identity: StoreIdentityReceipt, root: URL, plan: ManagedPathRelocation.Plan, protectedSnapshot: JSON) throws {
        guard case .current(let old) = try inspect(db), old.schema_revision == 2,
              old.logical_store_id == identity.logical_store_id, old.incarnation == identity.incarnation else { throw StoreRecovery.required("migration_source_changed") }
        try ManagedPathRelocation.apply(db, root: root, plan: plan)
        let ready = identity.withSchema(3).withState("ready")
        try db.execute(sql:"UPDATE metadata SET value=? WHERE key='store_identity'",arguments:[String(decoding:try ready.encoded(),as:UTF8.self)])
        try db.execute(sql:"UPDATE metadata SET value=? WHERE key='schema_migrations'",arguments:[try jsonString([ledger,protocolLedger,managedPathsLedger])])
        try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('preupgrade_snapshot',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[try jsonString(protectedSnapshot)])
        try db.execute(sql:"PRAGMA user_version=3")
        guard case .current(let actual) = try inspect(db), actual == ready else { throw StoreRecovery.required("migration_result_invalid") }
    }
    static func contentFingerprint(_ db: Database) throws -> String {
        var digest = SHA256()
        func feed(_ bytes: Data) { var length = UInt64(bytes.count).bigEndian;withUnsafeBytes(of:&length) { digest.update(data:Data($0)) };digest.update(data:bytes) }
        for table in ["metadata","records","commands","events","cursors","sqlite_sequence"] {
            feed(Data(table.utf8))
            let rows = try Row.fetchCursor(db,sql:"SELECT rowid,* FROM " + table + " ORDER BY rowid")
            while let row = try rows.next() {
                for i in 0..<row.count {
                    let value: DatabaseValue = row[i]
                    switch value.storage {
                    case .null: feed(Data([0]))
                    case .int64(let n): feed(Data(("i" + String(n)).utf8))
                    case .double(let n): var bits = n.bitPattern.bigEndian;feed(Data([2]));withUnsafeBytes(of:&bits) { feed(Data($0)) }
                    case .string: // Obtain complete SQL bytes, not GRDB's cString projection.
                        // The full-row snapshot uses witnesses; fingerprint uses SQL's hex
                        // representation below instead of this lossy value.
                        break
                    case .blob(let bytes): feed(Data([4]));feed(bytes)
                    }
                }
            }
            let columns = try Row.fetchAll(db,sql:"PRAGMA table_info(" + table + ")").map { $0["name"] as String }
            let textRows = try Row.fetchCursor(db,sql:"SELECT " + columns.map { "typeof(\"" + $0 + "\"),hex(CAST(\"" + $0 + "\" AS BLOB))" }.joined(separator:",") + " FROM " + table + " ORDER BY rowid")
            while let row = try textRows.next() { for i in 0..<row.count { feed(Data((row[i] as String).utf8)) } }
        }
        return digest.finalize().map { String(format:"%02x",$0) }.joined()
    }
    enum State { case legacy(String), current(StoreIdentityReceipt) }

    static func inspect(_ db: Database) throws -> State {
        let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1
        guard (0...currentSchema).contains(version) else { throw StoreRecovery.upgradeUnavailable() }
        try validateContainer(db)
        guard try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok",
              let incarnation = try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='incarnation'"), UUID(uuidString: incarnation) != nil else { throw StoreRecovery.required("invalid_legacy_store") }
        let identity = try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='store_identity'")
        let receipts = try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='schema_migrations'")
        if version == 0 {
            guard identity == nil, receipts == nil else { throw StoreRecovery.required("inconsistent_migration_state") }
            return .legacy(incarnation)
        }
        guard let identity, let receipts else { throw StoreRecovery.required("missing_migration_identity") }
        let value = try StoreIdentityReceipt.decode(Data(identity.utf8))
        guard value.state == "ready", value.incarnation == incarnation else { throw StoreRecovery.required("database_identity_mismatch") }
        guard let array = try? JSONSerialization.jsonObject(with: Data(receipts.utf8)) as? [JSON], array.count == version,
              try jsonString(array) == jsonString(ledgers(version)), value.schema_revision == version else { throw StoreRecovery.required("migration_checksum_or_order_mismatch") }
        return .current(value)
    }
    static func adoptBaseline(_ db: Database, identity: StoreIdentityReceipt, fresh: Bool) throws {
        if fresh {
            guard try String.fetchAll(db, sql: "SELECT name FROM sqlite_master").isEmpty else { throw StoreRecovery.required("fresh_database_changed") }
            try db.execute(sql: baselineSQL)
            try db.execute(sql: incarnationSQL, arguments: [identity.incarnation])
        } else {
            switch try inspect(db) {
            case .legacy(let incarnation): guard incarnation == identity.incarnation else { throw StoreRecovery.required("database_identity_changed") }
            case .current(let current): guard current == identity.withState("ready") else { throw StoreRecovery.required("database_identity_changed") }; return
            }
        }
        try db.execute(sql: enrollmentSQL, arguments: [String(decoding: try identity.withState("ready").encoded(), as: UTF8.self), try jsonString([ledger])])
        try db.execute(sql: versionSQL)
        guard case .current(let current) = try inspect(db), current == identity.withState("ready") else { throw StoreRecovery.required("baseline_adoption_validation_failed") }
    }
    static func validateContainer(_ db: Database) throws {
        try validateKnownSQLObjects(db)
        let shape: [String: [(String, String, Int, Int)]] = [
            "metadata": [("key","TEXT",0,1),("value","TEXT",1,0)],
            "records": [("id","TEXT",0,1),("project_id","TEXT",0,0),("type","TEXT",1,0),("revision","INTEGER",1,0),("data","TEXT",1,0)],
            "commands": [("principal","TEXT",1,1),("command_id","TEXT",1,2),("digest","TEXT",1,0),("result","TEXT",1,0)],
            "events": [("seq","INTEGER",0,1),("id","TEXT",1,0),("project_id","TEXT",0,0),("entity_id","TEXT",0,0),("actor","TEXT",1,0),("kind","TEXT",1,0),("occurred_at","TEXT",1,0),("data","TEXT",1,0)],
            "cursors": [("token","TEXT",0,1),("principal","TEXT",1,0),("scope","TEXT",1,0),("sequence","INTEGER",1,0),("incarnation","TEXT",1,0),("created_at","REAL",1,0)]]
        let tables = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name <> 'sqlite_sequence'"))
        guard tables == Set(shape.keys) else { throw StoreRecovery.required("unsupported_container_shape") }
        for (table, expected) in shape {
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
            guard rows.count == expected.count else { throw StoreRecovery.required("unsupported_container_shape") }
            for (row, column) in zip(rows, expected) {
                guard row["name"] as String == column.0, (row["type"] as String).uppercased() == column.1,
                      row["notnull"] as Int == column.2, row["pk"] as Int == column.3 else { throw StoreRecovery.required("unsupported_container_shape") }
            }
        }
        for (index, columns) in ["records_scope": ["project_id", "type"], "events_scope": ["project_id", "entity_id", "seq"]] {
            let rows = try Row.fetchAll(db, sql: "PRAGMA index_info(\(index))")
            guard rows.map({ $0["name"] as String }) == columns else { throw StoreRecovery.required("unsupported_container_indexes") }
        }
    }
    /// Column tuples and quick_check alone cannot prove the persisted program
    /// is the unchanged baseline. In particular, metadata enrollment must never
    /// execute an unknown trigger. This check is shared by read-only preflight
    /// and adoptBaseline's inspection inside the writer transaction.
    private static func validateKnownSQLObjects(_ db: Database) throws {
        let names: [(String, String, String)] = [
            ("table", "metadata", "metadata"),
            ("table", "records", "records"),
            ("index", "records_scope", "records"),
            ("table", "commands", "commands"),
            ("table", "events", "events"),
            ("index", "events_scope", "events"),
            ("table", "cursors", "cursors")]
        let version = try Int.fetchOne(db,sql:"PRAGMA user_version") ?? 0
        let statements = (version >= 2 ? currentSQL : baselineSQL).split(separator: ";").map(String.init).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard statements.count == names.count else { throw StoreRecovery.required("unsupported_container_sql_objects") }
        let expected = Dictionary(uniqueKeysWithValues: zip(names, statements).map { entry in
            (entry.0.1, (entry.0.0, entry.0.2, normalizedDefinition(entry.1)))
        })
        // Enumerate generated objects explicitly too. A prefix/LIKE filter is
        // not safe: '_' is a LIKE wildcard and can hide a user-defined trigger
        // such as sqliteXlegacy_trigger. Nothing persisted is skipped by name.
        let generated: [String: (String, String, String?)] = [
            "sqlite_sequence": ("table", "sqlite_sequence", "CREATE TABLE sqlite_sequence(name,seq)"),
            "sqlite_autoindex_metadata_1": ("index", "metadata", nil),
            "sqlite_autoindex_records_1": ("index", "records", nil),
            "sqlite_autoindex_commands_1": ("index", "commands", nil),
            "sqlite_autoindex_events_1": ("index", "events", nil),
            "sqlite_autoindex_cursors_1": ("index", "cursors", nil)]
        let rows = try Row.fetchAll(db, sql: "SELECT type,name,tbl_name,sql FROM sqlite_master")
        guard rows.count == expected.count + generated.count else { throw StoreRecovery.required("unsupported_container_sql_objects") }
        for row in rows {
            let name: String = row["name"], type: String = row["type"], table: String = row["tbl_name"]
            let sql: String? = row["sql"]
            if let definition = expected[name] {
                guard type == definition.0, table == definition.1,
                      sql.map(normalizedDefinition) == definition.2 else { throw StoreRecovery.required("unsupported_container_sql_objects") }
            } else if let definition = generated[name] {
                guard type == definition.0, table == definition.1,
                      sql.map(normalizedDefinition) == definition.2.map(normalizedDefinition) else { throw StoreRecovery.required("unsupported_container_sql_objects") }
            } else { throw StoreRecovery.required("unsupported_container_sql_objects") }
        }
    }
    private static func normalizedDefinition(_ sql: String) -> String {
        sql.lowercased().components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
            .replacingOccurrences(of: "if not exists ", with: "")
            .filter { !$0.isWhitespace }
    }

}
