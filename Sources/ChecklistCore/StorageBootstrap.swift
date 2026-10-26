import Foundation
import GRDB
import Darwin

/// One fixed canonical store. Existing bytes are opened read/write without
/// CREATE only after read-only shape/integrity/version checks have passed.
enum StorageBootstrap {
    enum Boundary { case upgradeBeforeCommit, upgradeCommitted }
    struct Opened { let queue: DatabaseQueue; let incarnation: String }
    static func writableURI(_ database: URL) throws -> String {
        guard var value = URLComponents(url:database,resolvingAgainstBaseURL:false) else { throw StoreRecovery.required("database_location_unavailable") }
        value.queryItems = [URLQueryItem(name:"mode",value:"rw")]
        guard let uri = value.string else { throw StoreRecovery.required("database_location_unavailable") };return uri
    }
    static func open(root: URL, serviceLease: StorageServiceLease? = nil, prepareDatabase: @escaping @Sendable (Database)throws->Void = { _ in }, observe: (Boundary)->Void = { _ in }) throws -> Opened {
        let root = StoreDirectory.anchoredRoot(root)
        let directory = try StoreDirectory(root:root)
        if let serviceLease { try serviceLease.requireRoot(root) }
        return try ArchiveStorageGate.withExclusive(root:root) { permit in
            let database = root.appendingPathComponent("checklist.sqlite")
            let hasDatabase = try directory.regularFileExists("checklist.sqlite")
            let external = try directory.regularFileExists(StoreIdentityReceipt.fileName) ? StoreIdentityReceipt.decode(directory.readReceipt(StoreIdentityReceipt.fileName)) : nil
            for name in ["checklist.sqlite-wal","checklist.sqlite-shm"] { _ = try directory.regularFileExists(name) }
            guard hasDatabase || external == nil else { throw StoreRecovery.required("initialized_database_missing") }
            let identity: StoreIdentityReceipt, fresh: Bool
            if hasDatabase {
                switch try readOnlyPreflight(database) {
                case .legacy(let incarnation):
                    guard serviceLease != nil else { throw StoreRecovery.required("upgrade_requires_exclusive_service") }
                    if let external {
                        guard external.state == "preparing",[1,2,3].contains(external.schema_revision),external.incarnation == incarnation else { throw StoreRecovery.required("legacy_identity_mismatch") };identity = external
                    } else {
                        identity = StoreIdentityReceipt(format_version:1,logical_store_id:uuid(),incarnation:incarnation,database_generation:1,schema_revision:1,state:"preparing")
                        try directory.publishReceipt(identity.encoded(),name:StoreIdentityReceipt.fileName,replacingPreparedReceipt:false)
                    }
                case .current(let current):
                    guard let external else { throw StoreRecovery.required("initialized_identity_receipt_missing") }
                    let matching = current == external.withState("ready")
                    let planned = current.schema_revision < external.schema_revision && [2,3].contains(external.schema_revision) && external.state == "preparing" && current.withSchema(external.schema_revision) == external.withState("ready")
                    guard matching || planned else { throw StoreRecovery.required("external_database_identity_mismatch") }
                    if current.schema_revision < 3 { guard serviceLease != nil else { throw StoreRecovery.required("upgrade_requires_exclusive_service") } }
                    identity = external
                }
                fresh = false
            } else {
                try directory.requireFreshScaffoldingOnly()
                identity = StoreIdentityReceipt(format_version:1,logical_store_id:uuid(),incarnation:uuid(),database_generation:1,schema_revision:1,state:"preparing")
                try directory.publishReceipt(identity.encoded(),name:StoreIdentityReceipt.fileName,replacingPreparedReceipt:false)
                try directory.createDatabaseFile("checklist.sqlite");fresh = true
            }
            var configuration = Configuration()
            configuration.prepareDatabase { db in
                try SchemaMigrations.installStorageCollation(db);try prepareDatabase(db)
                try db.execute(sql:"PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000")
            }
            let queue: DatabaseQueue
            do { queue = try DatabaseQueue(path:writableURI(database),configuration:configuration) }
            catch { throw StoreRecovery.required("writable_database_unavailable") }
            do {
                let version = try queue.read { try Int.fetchOne($0,sql:"PRAGMA user_version") ?? -1 }
                if version < 1 && fresh {
                    try queue.write { try SchemaMigrations.adoptBaseline($0,identity:identity.withSchema(1),fresh:fresh) }
                }
                try queue.writeWithoutTransaction { db in
                    guard try String.fetchOne(db,sql:"PRAGMA journal_mode=WAL")?.lowercased() == "wal" else { throw StoreRecovery.required("wal_configuration_failed") }
                }
                try directory.ensureObjectsDirectory()
                if version < 3 {
                    let protected: JSON
                    if fresh {
                        protected = ["fresh_store":true,"operation_id":uuid()]
                    } else {
                        // Supported old services must have exited: they hold the same
                        // lifetime service.lock through all post-SQL filesystem work.
                        guard let serviceLease else { throw StoreRecovery.required("upgrade_requires_exclusive_service") }
                        try serviceLease.requireRoot(root)
                        protected = try prepareUpgrade(queue:queue,root:root,identity:identity,permit:permit)
                    }
                    let prepared = identity.withSchema(3).withState("preparing")
                    let plan = try queue.read { try ManagedPathRelocation.plan($0, root: root, budget: .production()) }
                    try directory.publishReceipt(prepared.encoded(),name:StoreIdentityReceipt.fileName,replacingPreparedReceipt:true)
                    try queue.write { db in
                        if let expected = protected["source_fingerprint"] as? String {
                            guard try SchemaMigrations.contentFingerprint(db) == expected else { throw StoreRecovery.required("migration_source_changed_after_rehearsal") }
                        }
                        if version < 1 && !fresh { try SchemaMigrations.adoptBaseline(db,identity:identity.withSchema(1),fresh:false) }
                        if version < 2 { try SchemaMigrations.upgradeProtocol(db,identity:prepared,protectedSnapshot:protected) }
                        try SchemaMigrations.upgradeManagedPaths(db,identity:prepared,root:root,plan:plan,protectedSnapshot:protected)
                        observe(.upgradeBeforeCommit)
                    }
                    observe(.upgradeCommitted)
                }
                let ready = identity.withSchema(3).withState("ready")
                // A crash after SQL COMMIT repairs only the external publication.
                // Never restore an older snapshot over later committed work.
                if external != ready {
                    try directory.publishReceipt(ready.encoded(),name:StoreIdentityReceipt.fileName,replacingPreparedReceipt:true)
                }
                // Group labels are an independent additive backfill. Protocol 3
                // still fences earlier binaries from the managed-path representation.
                try queue.write { try GroupKeys.backfill($0) }
                return Opened(queue:queue,incarnation:identity.incarnation)
            } catch let error as CoreError { try? queue.close();throw error }
            catch { try? queue.close();throw StoreRecovery.required("compatible_bootstrap_transaction_failed") }
        }
    }
    private static func prepareUpgrade(queue: DatabaseQueue, root: URL, identity: StoreIdentityReceipt, permit: ArchiveStoragePermit) throws -> JSON {
        let parent = root.appendingPathComponent("backups",isDirectory:true)
        let files = try StorageObjectFiles(root:root)
        let (parentFD,_) = try files.parent("backups/.preupgrade",create:true);Darwin.close(parentFD)
        // The bound covers every durable object copy and both verification passes.
        let operation = UUID(), budget = StorageSnapshotBudget.production()
        let source = try StorageSnapshotSource(source:root,parent:parent,storeID:identity.logical_store_id,permit:permit)
        let receipt = try StorageSnapshot.build(source,operation:operation,budget:budget)
        let generation = parent.appendingPathComponent(StorageSnapshot.names(operation).published,isDirectory:true)
        let copyURL = generation.appendingPathComponent("database.sqlite")
        var config = Configuration();config.readonly = true;config.prepareDatabase { try SchemaMigrations.installStorageCollation($0) }
        let copy = try DatabaseQueue(path:copyURL.path,configuration:config)
        let fingerprint = try copy.read { try SchemaMigrations.contentFingerprint($0) };try copy.close()
        let protected: JSON = ["operation_id":operation.uuidString.lowercased(),"path":generation.path,"manifest_sha256":receipt.manifestSHA256,"source_fingerprint":fingerprint,"target_migration_checksum":SchemaMigrations.managedPathsChecksum,"protected":true]
        // Rehearse the exact migration on the closed, checksummed SQLite copy.
        // This candidate is separate from both live store and protected backup.
        let rehearsal = root.appendingPathComponent("staging/preupgrade-" + operation.uuidString.lowercased() + ".sqlite")
        let (stageFD,_) = try files.parent("staging/.preupgrade",create:true);Darwin.close(stageFD)
        try FileManager.default.copyItem(at:copyURL,to:rehearsal)
        var writer = Configuration();writer.prepareDatabase { db in try SchemaMigrations.installStorageCollation(db);try db.execute(sql:"PRAGMA foreign_keys=ON;PRAGMA synchronous=FULL") }
        let candidate = try DatabaseQueue(path:try writableURI(rehearsal),configuration:writer)
        do {
            let plan = try candidate.read { try ManagedPathRelocation.plan($0, root: root, budget: budget) }
            try candidate.write { db in
                if try Int.fetchOne(db,sql:"PRAGMA user_version") == 0 { try SchemaMigrations.adoptBaseline(db,identity:identity.withSchema(1),fresh:false) }
                if try Int.fetchOne(db,sql:"PRAGMA user_version") == 1 { try SchemaMigrations.upgradeProtocol(db,identity:identity.withSchema(2),protectedSnapshot:protected) }
                try SchemaMigrations.upgradeManagedPaths(db,identity:identity.withSchema(3),root:root,plan:plan,protectedSnapshot:protected)
            }
            try candidate.read { db in _ = try SchemaMigrations.inspect(db);guard try String.fetchOne(db,sql:"PRAGMA integrity_check") == "ok" else { throw StoreRecovery.required("migration_rehearsal_integrity_failed") } }
            try candidate.close()
        } catch { try? candidate.close();throw error }
        try StorageObjectFiles(root:root).synchronizeOwnedFile("staging/" + rehearsal.lastPathComponent)
        return protected
    }
    private static func readOnlyPreflight(_ database: URL) throws -> SchemaMigrations.State {
        var config = Configuration();config.readonly = true
        config.prepareDatabase { db in try SchemaMigrations.installStorageCollation(db);try db.execute(sql:"PRAGMA busy_timeout=5000") }
        do {
            let queue = try DatabaseQueue(path:database.path,configuration:config);defer { try? queue.close() }
            return try queue.read { try SchemaMigrations.inspect($0) }
        } catch let error as CoreError { throw error }
        catch { throw StoreRecovery.required("existing_database_preflight_failed") }
    }
}
