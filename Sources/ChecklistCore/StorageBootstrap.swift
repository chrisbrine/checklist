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
        defer {StorageUpgradeProgress.clear(root:root)}
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
                if let external,external.schema_revision < SchemaMigrations.currentSchema {
                    StorageUpgradeProgress.update(root:root,stage:"preparation_validation",seconds:90)
                }
                switch try readOnlyPreflight(database) {
                case .legacy(let incarnation):
                    guard serviceLease != nil else { throw StoreRecovery.required("upgrade_requires_exclusive_service") }
                    if let external {
                        guard external.state == "preparing",(1...SchemaMigrations.currentSchema).contains(external.schema_revision),external.incarnation == incarnation else { throw StoreRecovery.required("legacy_identity_mismatch") };identity = external
                    } else {
                        identity = StoreIdentityReceipt(format_version:1,logical_store_id:uuid(),incarnation:incarnation,database_generation:1,schema_revision:1,state:"preparing")
                        try directory.publishReceipt(identity.encoded(),name:StoreIdentityReceipt.fileName,replacingPreparedReceipt:false)
                    }
                case .current(let current):
                    guard let external else { throw StoreRecovery.required("initialized_identity_receipt_missing") }
                    let matching = current == external.withState("ready")
                    let planned = current.schema_revision < external.schema_revision && (2...SchemaMigrations.currentSchema).contains(external.schema_revision) && external.state == "preparing" && current.withSchema(external.schema_revision) == external.withState("ready")
                    guard matching || planned else { throw StoreRecovery.required("external_database_identity_mismatch") }
                    if current.schema_revision < SchemaMigrations.currentSchema { guard serviceLease != nil else { throw StoreRecovery.required("upgrade_requires_exclusive_service") } }
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
                if version < SchemaMigrations.currentSchema {
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
                    let prepared = identity.withSchema(SchemaMigrations.currentSchema).withState("preparing")
                    let plan = version < 3 ? try queue.read { try ManagedPathRelocation.plan($0, root: root, budget: .production()) } : ManagedPathRelocation.Plan(decisions:[:])
                    if !fresh {StorageUpgradeProgress.update(root:root,stage:"final_migration",seconds:90)}
                    try directory.publishReceipt(prepared.encoded(),name:StoreIdentityReceipt.fileName,replacingPreparedReceipt:true)
                    try queue.write { db in
                        if let expected = protected["source_fingerprint"] as? String {
                            guard try SchemaMigrations.contentFingerprint(db) == expected else { throw StoreRecovery.required("migration_source_changed_after_rehearsal") }
                        }
                        if version < 1 && !fresh { try SchemaMigrations.adoptBaseline(db,identity:identity.withSchema(1),fresh:false) }
                        if version < 2 { try SchemaMigrations.upgradeProtocol(db,identity:prepared,protectedSnapshot:protected) }
                        if version < 3 { try SchemaMigrations.upgradeManagedPaths(db,identity:prepared,root:root,plan:plan,protectedSnapshot:protected) }
                        try SchemaMigrations.upgradeTriageMembership(db,identity:prepared,protectedSnapshot:protected)
                        observe(.upgradeBeforeCommit)
                    }
                    observe(.upgradeCommitted)
                }
                let ready = identity.withSchema(SchemaMigrations.currentSchema).withState("ready")
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
    // Internal visibility allows owned-copy qualification of this exact protected path.
    static func prepareUpgrade(queue: DatabaseQueue, root: URL, identity: StoreIdentityReceipt, permit: ArchiveStoragePermit, qualificationBudget: StorageSnapshotBudget? = nil) throws -> JSON {
        StorageUpgradeProgress.update(root:root,stage:"preparation_validation",seconds:90)
        var reason = "preparation_unavailable"
        do {
            if let prepared = try StorageUpgradePreparation.reusable(queue:queue,root:root,identity:identity) {return prepared}
            if try StorageObjectFiles(root:root).regularOrLinkExists(StorageUpgradePreparation.receiptName) {reason = "source_changed_after_preparation"}
        } catch {
            // Invalid preparation is never permission to skip protection.
            reason = "preparation_invalid"
            fputs("Upgrade preparation cannot be reused; taking a fresh protected snapshot.\n",stderr)
        }
        StorageUpgradeProgress.update(root:root,stage:"protected_snapshot",seconds:900,reason:reason)
        let parent = root.appendingPathComponent("backups",isDirectory:true)
        let files = try StorageObjectFiles(root:root)
        let (parentFD,_) = try files.parent("backups/.preupgrade",create:true);Darwin.close(parentFD)
        // The bound covers every durable object copy and both verification passes.
        let operation = UUID(), budget = qualificationBudget ?? StorageSnapshotBudget.production()
        let source = try StorageSnapshotSource(source:root,parent:parent,storeID:identity.logical_store_id,permit:permit)
        let receipt = try StorageSnapshot.build(source,operation:operation,budget:budget)
        StorageUpgradeProgress.update(root:root,stage:"migration_rehearsal",seconds:360)
        return try StorageUpgradePreparation.rehearse(root:root,identity:identity,operation:operation,manifestSHA256:receipt.manifestSHA256,budget:budget)
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
