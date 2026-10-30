import Foundation
import GRDB

/// Schema 5 removes the repeated object catalog only after proving that the
/// immutable manifest retains exactly those historical path/content bindings.
/// Files written before SQL COMMIT are immutable, content-addressed indexes;
/// an interrupted transaction may leave an unused index, never a missing receipt.
enum StorageBackupReceiptMigration {
    static let vacuumKey = "backup-receipts-v5-vacuum"
    /// Internal owned-copy timing seam; no service callback is installed.
    nonisolated(unsafe) static var observe: ((String,TimeInterval) -> Void)?

    static func apply(_ db: Database, root: URL, identity: StoreIdentityReceipt) throws {
        let started = ProcessInfo.processInfo.systemUptime
        defer {observe?("migration_sql_and_indexes",ProcessInfo.processInfo.systemUptime-started)}
        let keys = try String.fetchAll(db,sql:"SELECT key FROM metadata WHERE key GLOB 'backup-generation:*' ORDER BY rowid")
        for key in keys {
            try autoreleasepool {
                guard let row = try Row.fetchOne(db,sql:"SELECT json_valid(value) AS valid,CASE WHEN json_valid(value) THEN json_remove(value,'$.objects') END AS compact,CASE WHEN json_valid(value) THEN json_type(value,'$.objects') END AS objects FROM metadata WHERE key=?",arguments:[key]),
                      row["valid"] as Bool,let raw: String = row["compact"],
                      var value = try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? JSON,
                      value["state"] as? String == "complete",let operation = value["operation_id"] as? String,
                      key == "backup-generation:" + operation,UUID(uuidString:operation) != nil,
                      let sha = value["manifest_sha256"] as? String,sha.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,
                      row["objects"] as String? == "array" else {throw StoreRecovery.required("backup_receipt_migration_invalid")}
                // The stored absolute destination is historical provenance only.
                // A relocated/seeded store may open only its own backups folder.
                let resolved = try? StorageBackupReceiptManifest.resolve(value,db:db,key:key,root:root,identity:identity)
                guard let resolved else {
                    guard let original = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[key]) else {throw StoreRecovery.required("backup_receipt_migration_invalid")}
                    let summary = value["summary"] as? JSON
                    let keyRoot = (summary?["source_root"] as? String).flatMap {$0.hasPrefix("/") ? URL(fileURLWithPath:$0,isDirectory:true) : nil} ?? root
                    let external = try StorageBackupManifestIndex.prepareHistorical(root:root,raw:original,keyRoot:keyRoot)
                    guard let catalog = external["historical_catalog"] as? JSON else {throw StoreRecovery.required("backup_receipt_migration_invalid")}
                    try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:["backup-historical-catalog:" + operation,try jsonString(catalog)])
                    for (field,contents) in external {value[field] = contents}
                    value["format"] = 2;value["current_physical_verified"] = false
                    if var summary = value["summary"] as? JSON {
                        summary["verification"] = "historical_catalog_only";value["summary"] = summary
                    }
                    try db.execute(sql:"UPDATE metadata SET value=? WHERE key=?",arguments:[try jsonString(value),key])
                    return
                }
                let manifest = resolved.manifest
                defer {withExtendedLifetime(resolved.lease) {}}
                let summary = value["summary"] as! JSON
                var boundSummary = summary
                boundSummary["store_id"] = manifest.storeID;boundSummary["source_root"] = manifest.sourceRoot
                boundSummary["path"] = resolved.path.path
                value["summary"] = boundSummary
                value["format"] = 2;value["object_count"] = resolved.count;value["object_bytes"] = resolved.objectBytes
                value["manifest_index"] = try StorageBackupManifestIndex.prepare(root:root,manifest:manifest,manifestSHA256:sha)
                try db.execute(sql:"UPDATE metadata SET value=? WHERE key=?",arguments:[try jsonString(value),key])
            }
        }
        // VACUUM is forbidden inside this transaction. A durable pending marker
        // makes death after COMMIT repair forward before the store serves work.
        if !keys.isEmpty {try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?, 'pending') ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[vacuumKey])}
    }

    static func finishCompaction(_ queue: DatabaseQueue) throws {
        guard try queue.read({try String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key=?",arguments:[vacuumKey])}) != nil else {return}
        try queue.writeWithoutTransaction {try compact($0)}
    }
    /// The router's storage boundary uses the same SQLite operation in focused tests.
    static func finishCompaction(_ storage: any TransactionStorage) throws {
        guard try storage.read({try String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key=?",arguments:[vacuumKey])}) != nil else {return}
        try storage.writeWithoutTransaction {try compact($0)}
    }
    private static func compact(_ db: Database) throws {
        let started = ProcessInfo.processInfo.systemUptime
        defer {observe?("checkpoint_and_vacuum",ProcessInfo.processInfo.systemUptime-started)}
        _ = try Row.fetchAll(db,sql:"PRAGMA wal_checkpoint(TRUNCATE)")
        try db.execute(sql:"VACUUM")
        _ = try Row.fetchAll(db,sql:"PRAGMA wal_checkpoint(TRUNCATE)")
        try db.execute(sql:"DELETE FROM metadata WHERE key=?",arguments:[vacuumKey])
    }
}
