import Foundation
import GRDB
import Darwin

extension CommandRouter {
    static let storageIncompleteBackupMethods: Set<String> = ["backup_incomplete_preview","backup_incomplete_retire"]

    /// Project only receipt headers; never decode retained object catalogs.
    func backupCompletionReceipts(_ db: Database) throws -> [JSON] {
        var receipts = try Row.fetchAll(db,sql:"SELECT key,json_object('format',json_extract(value,'$.format'),'operation_id',json_extract(value,'$.operation_id'),'state',json_extract(value,'$.state'),'manifest_sha256',json_extract(value,'$.manifest_sha256'),'summary',json_extract(value,'$.summary'),'historical_catalog',json_extract(value,'$.historical_catalog')) AS header FROM metadata WHERE key GLOB 'backup-generation:*'").map {row -> JSON in
            var value = jsonObject(row["header"]);value["generation_key"] = row["key"] as String;return value
        }
        var protected: [JSON] = []
        for key in ["preupgrade_snapshot","backup-protected-history"] {
            guard let raw = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[key]) else {continue}
            guard let value = try? JSONSerialization.jsonObject(with:Data(raw.utf8)) else {throw StoreRecovery.required("backup_protected_history_invalid")}
            if key == "preupgrade_snapshot",let receipt = value as? JSON {protected.append(receipt)}
            else if key == "backup-protected-history",let history = value as? [JSON] {protected += history}
            else {throw StoreRecovery.required("backup_protected_history_invalid")}
        }
        let files = try StorageObjectFiles(root:root)
        if try files.regularOrLinkExists(StorageUpgradePreparation.receiptName) {
            let receipt = try JSONDecoder().decode(StorageUpgradePreparation.Receipt.self,from:files.read(StorageUpgradePreparation.receiptName,maximum:16_384))
            guard receipt.sourceRoot == root.path else {throw StoreRecovery.required("backup_prepared_protection_invalid")}
            protected.append(receipt.protected)
        }
        for receipt in protected {
            guard bool(receipt,"protected"),let path = receipt["path"] as? String,path.hasPrefix("/"),
                  let digest = receipt["manifest_sha256"] as? String,digest.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,
                  let fingerprint = receipt["source_fingerprint"] as? String,fingerprint.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,
                  let operation = receipt["operation_id"] as? String,UUID(uuidString:operation) != nil else {continue}
            let local = StorageBackupProtectionAliases.paths(path,root:root).contains(root.appendingPathComponent("backups/snapshot-" + operation.lowercased()).path) ? root.appendingPathComponent("backups/snapshot-" + operation.lowercased()).path : path
            if receipts.contains(where:{backupCompletionPath($0) == local}) {continue}
            receipts.append(["state":"complete","operation_id":operation,"manifest_sha256":digest,"generation_key":"","completion_source":"protected_upgrade_receipt","summary":["path":local,"manifest_sha256":digest,"verification":"manifest_database_managed_files"]])
        }
        return receipts
    }

    func backupCompletionPath(_ receipt: JSON) -> String? {
        guard receipt["state"] as? String == "complete",!(receipt["historical_catalog"] is JSON),
              let summary = receipt["summary"] as? JSON,summary["verification"] as? String == "manifest_database_managed_files",
              let digest = receipt["manifest_sha256"] as? String,digest.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,
              summary["manifest_sha256"] as? String == digest,let path = summary["path"] as? String,path.hasPrefix("/"),
              !URL(fileURLWithPath:path).lastPathComponent.hasPrefix(".") else {return nil}
        if receipt["format"] as? Int == 2 {return try? StorageBackupReceiptLocation.location(receipt,root:root).path}
        return path
    }

    /// Like agent backup creation, this installation-wide maintenance route
    /// requires one actual enrolled project session with agent changes allowed.
    @discardableResult
    func requireIncompleteBackupAuthority(params: JSON,caller: Caller,expectedGeneration: String? = nil) throws -> String? {
        if caller.isOwner {return nil}
        try worker(caller)
        return try readForPreparation {db in
            let project = try scope(db,params,caller,write:true)
            let generation = try backupWriteAuthorization(db,params:params,caller:caller)
            guard expectedGeneration == nil || generation == expectedGeneration else {
                throw CoreError("CONNECTION_REVOKED","The incomplete backup retirement belongs to an earlier session authorization generation.")
            }
            try requireAgentEditAuthority(db,project:record(db,project,type:"project"),caller:caller)
            return generation
        }
    }

    /// A manifest proves bytes, not that the publishing command completed.
    /// Local managed artifacts require the durable receipt as well. External
    /// exported generations retain the independent full-verification route.
    func requireCompletedBackupForRestore(_ source: URL,manifestSHA256: String? = nil) throws {
        let name = source.lastPathComponent
        let unpublished = [".snapshot-staging-",".snapshot-incomplete-",".snapshot-failed-"].contains {name.hasPrefix($0)}
        let managed = (try? requireManagedBackupPath(source)) != nil
        guard unpublished || managed else {return}
        let complete = try readForPreparation {db in
            try backupCompletionReceipts(db).contains {receipt in
                backupCompletionPath(receipt) == source.path && (manifestSHA256 == nil || receipt["manifest_sha256"] as? String == manifestSHA256)
            }
        }
        guard !unpublished,complete else {
            throw CoreError("BACKUP_INCOMPLETE","This backup folder is incomplete: it has no completed publication receipt. Keep it or use backup_incomplete_preview and backup_incomplete_retire.",details:["state":"incomplete","reason":unpublished ? "unpublished_backup_folder" : "no_complete_receipt","path":source.path,"command_outcome":"rejected"])
        }
    }

    /// No manifest exists yet, so the existing manifest lease cannot be used.
    /// The caller holds the store's object gate and has refused active capture.
    /// Pin the no-follow directory/ancestors, take an exclusive directory lease,
    /// and require the exact preview inode plus continued manifest absence.
    func moveIncompleteBackupWithoutManifest(_ entry: JSON) throws {
        guard entry["state"] as? String != "complete",let path = entry["path"] as? String,let target = entry["trash_path"] as? String else {throw StorageSnapshotFailure.incomplete}
        let source = URL(fileURLWithPath:path),destination = URL(fileURLWithPath:target)
        try requireManagedBackupPath(source)
        func changed() -> CoreError {CoreError("BACKUP_PRUNE_SOURCE_CHANGED","The incomplete backup folder changed; it was retained.")}
        func exact(_ files: StorageObjectFiles,reconciling: Bool = false) throws {
            var info = stat()
            guard fstat(files.descriptor,&info) == 0,info.st_mode & S_IFMT == S_IFDIR,
                  Int64(info.st_dev) == (entry["device"] as? NSNumber)?.int64Value,
                  UInt64(info.st_ino) == (entry["inode"] as? NSNumber)?.uint64Value,
                  try !files.regularOrLinkExists("manifest.json") else {throw changed()}
            if !reconciling {
                guard UInt32(info.st_mode) == (entry["directory_mode"] as? NSNumber)?.uint32Value,
                      Int64(info.st_mtimespec.tv_sec) == (entry["directory_mtime_seconds"] as? NSNumber)?.int64Value,
                      Int64(info.st_mtimespec.tv_nsec) == (entry["directory_mtime_nanoseconds"] as? NSNumber)?.int64Value,
                      Int64(info.st_ctimespec.tv_sec) == (entry["directory_ctime_seconds"] as? NSNumber)?.int64Value,
                      Int64(info.st_ctimespec.tv_nsec) == (entry["directory_ctime_nanoseconds"] as? NSNumber)?.int64Value else {throw changed()}
            }
        }
        var info = stat()
        if lstat(source.path,&info) != 0 {
            guard errno == ENOENT else {throw changed()}
            // Reconcile only the exact directory moved by this durable intent.
            try exact(StorageObjectFiles(root:destination,folderAccess:.insideTrash),reconciling:true)
            return
        }
        let files = try StorageObjectFiles(root:source,pinRootForGates:true)
        while flock(files.descriptor,LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR {continue}
            if errno == EWOULDBLOCK {throw CoreError("BACKUP_IN_USE","This incomplete backup folder is in use; it was retained.")}
            throw CoreError("BACKUP_USE_UNAVAILABLE","The incomplete backup directory lease is unavailable; it was retained.",details:["posix_errno":errno])
        }
        defer {_ = flock(files.descriptor,LOCK_UN)}
        try exact(files)
        let parent = try StorageObjectFiles(root:source.deletingLastPathComponent()),trash = try StorageObjectFiles(root:destination.deletingLastPathComponent(),folderAccess:.insideTrash)
        try files.requireNamedRoot(source)
        try exact(files)
        guard renameatx_np(parent.descriptor,source.lastPathComponent,trash.descriptor,destination.lastPathComponent,UInt32(RENAME_EXCL)) == 0 else {throw CoreError("BACKUP_PRUNE_IO","The incomplete backup folder could not move atomically to same-volume Trash; it was retained.",details:["posix_errno":errno])}
        try parent.synchronizePublicationDirectory();try trash.synchronizePublicationDirectory()
    }
}
