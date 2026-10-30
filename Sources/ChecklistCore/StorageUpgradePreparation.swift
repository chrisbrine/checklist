import Foundation
import GRDB
import Darwin
import CryptoKit

/// Installer preparation never opens a router, takes the service lifetime lease,
/// or migrates the source. The old service remains the only application writer.
public enum StorageUpgradePreparation {
    static let receiptName = "preupgrade-ready.json"
    struct Receipt: Codable {
        let format: Int
        let sourceRoot: String
        let identity: StoreIdentityReceipt
        let operation: UUID
        let manifestSHA256: String
        let sourceFingerprint: String
        let targetChecksum: String
        let executableSHA256: String
        let fileIdentities: String
        var protected: JSON { ["operation_id":operation.uuidString.lowercased(),"path":generation.path,
            "manifest_sha256":manifestSHA256,"source_fingerprint":sourceFingerprint,
            "target_migration_checksum":targetChecksum,"protected":true,"prepared_online":true] }
        var generation: URL { URL(fileURLWithPath:sourceRoot).appendingPathComponent("backups/" + StorageSnapshot.names(operation).published) }
    }

    public static func prepare(root: URL) throws -> [String:Any] {
        try prepare(root:root,requiringUpgrade:true)
    }

    /// Internal qualification seam exercises the identical preparation path on an
    /// owned current-schema copy without falsifying its migration ledger.
    static func prepare(root: URL,requiringUpgrade: Bool,qualificationBudget: StorageSnapshotBudget? = nil) throws -> [String:Any] {
        let root = StoreDirectory.anchoredRoot(root)
        var rootInfo = stat()
        if lstat(root.path,&rootInfo) != 0,errno == ENOENT {
            return ["needs_upgrade":false,"prepared":false,"expected_offline_seconds":30]
        }
        let files = try StorageObjectFiles(root:root)
        guard try files.regularOrLinkExists("checklist.sqlite") else {
            return ["needs_upgrade":false,"prepared":false,"expected_offline_seconds":30]
        }
        var config = Configuration();config.readonly = true
        config.prepareDatabase { try SchemaMigrations.installStorageCollation($0) }
        let source = try DatabaseQueue(path:root.appendingPathComponent("checklist.sqlite").path,configuration:config)
        defer {try? source.close()}
        let state = try source.read { try SchemaMigrations.inspect($0) }
        guard case .current(let identity) = state else {
            return ["needs_upgrade":true,"prepared":false,"expected_offline_seconds":900,"reason":"legacy_store_requires_offline_preparation"]
        }
        guard !requiringUpgrade || identity.schema_revision < SchemaMigrations.currentSchema else {
            return ["needs_upgrade":false,"prepared":false,"expected_offline_seconds":30]
        }
        let external = try StoreIdentityReceipt.decode(files.read(StoreIdentityReceipt.fileName,maximum:4096))
        guard external == identity else { throw StoreRecovery.required("external_database_identity_mismatch") }
        return try StorageSnapshotRetention.withCapture(root:root) { retention in
            let operation = UUID(), budget = qualificationBudget ?? StorageSnapshotBudget.production()
            let (fd,_) = try files.parent("backups/.preupgrade",create:true);Darwin.close(fd)
            let parent = root.appendingPathComponent("backups")
            let started = ProcessInfo.processInfo.systemUptime
            let snapshot = try StorageSnapshot.buildOnline(source:root,parent:parent,storeID:identity.logical_store_id,
                publicationName:StorageSnapshot.names(operation).published,operation:operation,budget:budget,retention:retention)
            fputs("Upgrade preparation: protected snapshot verified in \(ProcessInfo.processInfo.systemUptime-started) s; preparation has not stopped the old service.\n",stderr)
            let generation = parent.appendingPathComponent(StorageSnapshot.names(operation).published)
            let protected = try rehearse(root:root,identity:identity,operation:operation,manifestSHA256:snapshot.manifestSHA256,budget:budget)
            let manifest = try manifest(generation)
            // Hash the source only during online preparation. An identity collected
            // after each hash cannot bless a source edit that predates that hash.
            let identities = try fileIdentities(root:root,generation:generation,manifest:manifest,budget:budget,verifySource:true)
            let receipt = Receipt(format:2,sourceRoot:root.path,identity:identity,operation:operation,
                manifestSHA256:snapshot.manifestSHA256,sourceFingerprint:protected["source_fingerprint"] as! String,
                targetChecksum:SchemaMigrations.backupReceiptChecksum,executableSHA256:try executableSHA256(),fileIdentities:identities)
            try publish(try StorageSnapshot.encoded(receipt),name:receiptName,root:root)
            let unchanged = try source.read { try SchemaMigrations.contentFingerprint($0) == receipt.sourceFingerprint }
            return ["needs_upgrade":true,"prepared":true,"expected_offline_seconds":unchanged ? 90 : 900,
                    "reason":unchanged ? "prepared_snapshot_and_rehearsal" : "source_changed_after_preparation",
                    "protected_backup":generation.path,"preparation_seconds":ProcessInfo.processInfo.systemUptime-started]
        }
    }

    static func reusable(queue: DatabaseQueue,root: URL,identity: StoreIdentityReceipt) throws -> JSON? {
        let files = try StorageObjectFiles(root:root)
        guard try files.regularOrLinkExists(receiptName) else { return nil }
        let receipt = try JSONDecoder().decode(Receipt.self,from:files.read(receiptName,maximum:16_384))
        guard receipt.format == 2,receipt.sourceRoot.utf8.elementsEqual(root.path.utf8),
              receipt.identity.withState("ready") == identity.withSchema(receipt.identity.schema_revision).withState("ready"),
              receipt.targetChecksum == SchemaMigrations.backupReceiptChecksum,
              receipt.executableSHA256 == (try executableSHA256()) else {throw StorageSnapshotFailure.incomplete}
        guard try queue.read({try SchemaMigrations.contentFingerprint($0)}) == receipt.sourceFingerprint else {return nil}
        let useLease = try StorageBackupUseLease(root:receipt.generation)
        defer {withExtendedLifetime(useLease) {}}
        let generationFiles = useLease.files
        let bytes = try generationFiles.read("manifest.json",maximum:StorageSnapshotBudget.manifestByteLimit)
        try useLease.requireCurrent()
        guard StorageObjectFiles.sha(bytes) == receipt.manifestSHA256 else {throw StorageSnapshotFailure.sourceChanged}
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:bytes)
        guard manifest.storeID == receipt.identity.logical_store_id,manifest.schema == receipt.identity.schema_revision,
              manifest.sourceRoot.utf8.elementsEqual(root.path.utf8),manifest.operationID == receipt.operation.uuidString.lowercased() else {throw StorageSnapshotFailure.incomplete}
        guard try fileIdentities(root:root,generation:receipt.generation,manifest:manifest,budget:.production(),verifySource:false) == receipt.fileIdentities else {throw StorageSnapshotFailure.sourceChanged}
        try useLease.requireCurrent()
        return receipt.protected
    }

    /// Bind rehearsal to the actual staged executable, not just a migration
    /// name/checksum which another build may share. Bundle relocation is allowed.
    static func executableSHA256() throws -> String {
        var path = [CChar](repeating:0,count:4096)
        guard proc_pidpath(getpid(),&path,UInt32(path.count)) > 0 else {throw StorageSnapshotFailure.io}
        return StorageObjectFiles.sha(try Data(contentsOf:URL(fileURLWithPath:String(cString:path)),options:.mappedIfSafe))
    }

    static func manifest(_ generation: URL) throws -> StorageSnapshotManifest {
        let useLease = try StorageBackupUseLease(root:generation)
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:useLease.files.read("manifest.json",maximum:StorageSnapshotBudget.manifestByteLimit))
        try useLease.requireCurrent()
        return manifest
    }

    /// The snapshot builder already durably verified backup bytes. Remember all
    /// source AND backup identities (including ctime), then recheck under the
    /// stopped service lease/object gate. A changed/missing object forces a new
    /// protected snapshot; database equality alone cannot authorize this reuse.
    static func fileIdentities(root: URL,generation: URL,manifest: StorageSnapshotManifest,budget: StorageSnapshotBudget,verifySource: Bool) throws -> String {
        let source = try StorageObjectFiles(root:root),copy = try StorageObjectFiles(root:generation)
        let sourceWalk = MetadataWalk(source),copyWalk = MetadataWalk(copy)
        var digest = SHA256()
        func identity(_ walk: MetadataWalk,_ path: String) throws -> Data {
            let (fd,name,owned) = try walk.parent(path)
            defer {if owned {Darwin.close(fd)}}
            var info = stat()
            guard fstatat(fd,name,&info,AT_SYMLINK_NOFOLLOW) == 0,
                  [S_IFREG,S_IFLNK].contains(info.st_mode & S_IFMT) else {throw StorageSnapshotFailure.sourceChanged}
            return Data("\(path)\u{0}\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)\n".utf8)
        }
        for path in ["manifest.json","intent.json","database.sqlite"] {
            let before = try identity(copyWalk,path)
            if verifySource,path == "database.sqlite" {
                guard try copy.digest(path,budget:budget) == (manifest.databaseSHA256,manifest.databaseSize),
                      try identity(copyWalk,path) == before else {throw StorageSnapshotFailure.sourceChanged}
            }
            if verifySource,path == "intent.json" {
                let intent = try JSONDecoder().decode([String:String].self,from:copy.read(path,maximum:1024))
                guard intent == ["format":String(manifest.format),"kind":StorageSnapshot.kind,"operation_id":manifest.operationID,
                                 "store_id":manifest.storeID,"source_root":manifest.sourceRoot],
                      try identity(copyWalk,path) == before else {throw StorageSnapshotFailure.sourceChanged}
            }
            digest.update(data:before)
        }
        for object in manifest.objects {
            try budget.check()
            let path = object.descriptor.relativePath,before = try identity(sourceWalk,path)
            let copyPath = "managed/" + path,copyBefore = try identity(copyWalk,copyPath)
            if verifySource {
                if object.descriptor.kind == "symlink" {
                    guard try source.linkTarget(path) == object.descriptor.linkTarget,try copy.linkTarget(copyPath) == object.descriptor.linkTarget else {throw StorageSnapshotFailure.sourceChanged}
                } else {
                    let actual = try source.digest(path,budget:budget)
                    guard actual == (object.sha256,object.size),try copy.digest(copyPath,budget:budget) == actual else {throw StorageSnapshotFailure.sourceChanged}
                }
                guard try identity(sourceWalk,path) == before,try identity(copyWalk,copyPath) == copyBefore else {throw StorageSnapshotFailure.sourceChanged}
            }
            digest.update(data:before);digest.update(data:copyBefore)
        }
        try sourceWalk.finish();try copyWalk.finish()
        return StorageObjectFiles.hex(digest.finalize())
    }

    /// Retain only the current path's ancestors (at most 64 descriptors). Shared
    /// prefixes need no repeated open/close. Before releasing an ancestor, verify
    /// its name still denotes the pinned directory and it did not change during
    /// this walk. All traversal remains descriptor-relative and no-follow.
    private final class MetadataWalk {
        struct Directory { let name: String;let descriptor: Int32;let info: stat }
        let files: StorageObjectFiles
        var directories: [Directory] = []
        init(_ files: StorageObjectFiles) { self.files = files }
        deinit { for directory in directories {Darwin.close(directory.descriptor)} }
        func pop() throws {
            let directory = directories.removeLast()
            defer {Darwin.close(directory.descriptor)}
            let parent = directories.last?.descriptor ?? files.descriptor
            var current = stat()
            guard fstatat(parent,directory.name,&current,AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_mode & S_IFMT == S_IFDIR,
                  current.st_dev == directory.info.st_dev,current.st_ino == directory.info.st_ino,
                  current.st_mtimespec.tv_sec == directory.info.st_mtimespec.tv_sec,current.st_mtimespec.tv_nsec == directory.info.st_mtimespec.tv_nsec,
                  current.st_ctimespec.tv_sec == directory.info.st_ctimespec.tv_sec,current.st_ctimespec.tv_nsec == directory.info.st_ctimespec.tv_nsec else {throw StorageSnapshotFailure.sourceChanged}
        }
        func parent(_ path: String) throws -> (Int32,String,Bool) {
            var parts = try StorageObjectFiles.parts(path)
            let name = parts.removeLast()
            if parts.count > 64 {
                try finish()
                let (descriptor,name) = try files.parent(path)
                return (descriptor,name,true)
            }
            var shared = 0
            while shared < min(parts.count,directories.count),parts[shared] == directories[shared].name {shared += 1}
            while directories.count > shared {try pop()}
            for part in parts.dropFirst(shared) {
                let parent = directories.last?.descriptor ?? files.descriptor
                let descriptor = openat(parent,part,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard descriptor >= 0 else {throw StorageSnapshotFailure.sourceChanged}
                var info = stat()
                guard fstat(descriptor,&info) == 0 else {Darwin.close(descriptor);throw StorageSnapshotFailure.io}
                directories.append(.init(name:part,descriptor:descriptor,info:info))
            }
            return (directories.last?.descriptor ?? files.descriptor,name,false)
        }
        func finish() throws {while !directories.isEmpty {try pop()}}
    }

    static func rehearse(root: URL,identity: StoreIdentityReceipt,operation: UUID,manifestSHA256: String,budget: StorageSnapshotBudget) throws -> JSON {
        let generation = root.appendingPathComponent("backups/" + StorageSnapshot.names(operation).published)
        let useLease = try StorageBackupUseLease(root:generation)
        defer {withExtendedLifetime(useLease) {}}
        guard try useLease.manifestSHA256() == manifestSHA256 else {throw StorageSnapshotFailure.sourceChanged}
        let copyURL = generation.appendingPathComponent("database.sqlite")
        var read = Configuration();read.readonly = true;read.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let copy = try DatabaseQueue(path:copyURL.path,configuration:read)
        let fingerprint = try copy.read {try SchemaMigrations.contentFingerprint($0)};try copy.close()
        let protected: JSON = ["operation_id":operation.uuidString.lowercased(),"path":generation.path,"manifest_sha256":manifestSHA256,
            "source_fingerprint":fingerprint,"target_migration_checksum":SchemaMigrations.backupReceiptChecksum,"protected":true]
        let files = try StorageObjectFiles(root:root)
        let (fd,_) = try files.parent("staging/.preupgrade",create:true);Darwin.close(fd)
        let rehearsal = root.appendingPathComponent("staging/preupgrade-" + operation.uuidString.lowercased() + ".sqlite")
        try FileManager.default.copyItem(at:copyURL,to:rehearsal)
        var writer = Configuration();writer.prepareDatabase {db in try SchemaMigrations.installStorageCollation(db);try db.execute(sql:"PRAGMA foreign_keys=ON;PRAGMA synchronous=FULL")}
        let candidate = try DatabaseQueue(path:try StorageBootstrap.writableURI(rehearsal),configuration:writer)
        do {
            let version = try candidate.read {try Int.fetchOne($0,sql:"PRAGMA user_version") ?? -1}
            // Protocol 3→4 changes no managed paths. Avoid scanning every capture
            // twice for a relocation plan which that migration never consumes.
            let plan = version < 3 ? try candidate.read {try ManagedPathRelocation.plan($0,root:root,budget:budget)} : .init(decisions:[:])
            try candidate.write {db in
                if version < 1 {try SchemaMigrations.adoptBaseline(db,identity:identity.withSchema(1),fresh:false)}
                if version < 2 {try SchemaMigrations.upgradeProtocol(db,identity:identity.withSchema(2),protectedSnapshot:protected)}
                if version < 3 {try SchemaMigrations.upgradeManagedPaths(db,identity:identity.withSchema(3),root:root,plan:plan,protectedSnapshot:protected)}
                if version < 4 {try SchemaMigrations.upgradeTriageMembership(db,identity:identity.withSchema(4),protectedSnapshot:protected)}
                if version < 5 {try SchemaMigrations.upgradeBackupReceipts(db,identity:identity.withSchema(5),root:root,protectedSnapshot:protected)}
            }
            try StorageBackupReceiptMigration.finishCompaction(candidate)
            try candidate.read {db in _ = try SchemaMigrations.inspect(db);guard try String.fetchOne(db,sql:"PRAGMA integrity_check") == "ok" else {throw StoreRecovery.required("migration_rehearsal_integrity_failed")}}
            try candidate.close()
        } catch {try? candidate.close();throw error}
        try files.synchronizeOwnedFile("staging/" + rehearsal.lastPathComponent)
        try useLease.requireCurrent()
        return protected
    }

    static func publish(_ data: Data,name: String,root: URL) throws {
        let files = try StorageObjectFiles(root:root),temporary = ".upgrade-" + uuid()
        try files.writeNew(temporary,bytes:data)
        guard renameat(files.descriptor,temporary,files.descriptor,name) == 0,fsync(files.descriptor) == 0 else {throw StorageSnapshotFailure.io}
    }
}

/// Advisory only: no grant, write receipt or completion evidence. Clients require
/// the publishing PID to be alive and expire stale markers after process death.
enum StorageUpgradeProgress {
    static func update(root: URL,stage: String,seconds: Int,reason: String? = nil) {
        var value: JSON = ["state":"upgrading","stage":stage,"estimated_remaining_seconds":seconds,"updated_at":now(),"pid":Int(getpid())]
        if let reason {value["reason"] = reason}
        try? StorageUpgradePreparation.publish(JSONSerialization.data(withJSONObject:value,options:.sortedKeys),name:"upgrade-progress.json",root:root)
        fputs("Checklist upgrading: \(stage), estimate \(seconds) s\(reason.map {", " + $0} ?? "").\n",stderr)
    }
    static func clear(root: URL) {
        if let files = try? StorageObjectFiles(root:root) {_ = unlinkat(files.descriptor,"upgrade-progress.json",0);_ = fsync(files.descriptor)}
    }
}
