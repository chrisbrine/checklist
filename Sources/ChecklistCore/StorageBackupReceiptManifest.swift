import Foundation
import GRDB
import Darwin

/// Resolve only the current instance's snapshot namespace. Receipt paths retain
/// provenance, never permission to read another installation during migration.
enum StorageBackupReceiptManifest {
    struct Resolved {
        let path: URL
        let lease: StorageBackupUseLease
        let manifest: StorageSnapshotManifest
        let count: Int
        let objectBytes: Int64
    }
    static func resolve(_ value: JSON,db: Database,key: String,root: URL,identity: StoreIdentityReceipt) throws -> Resolved {
        guard let summary = value["summary"] as? JSON,let original = summary["path"] as? String,original.hasPrefix("/"),
              summary["verification"] as? String == "manifest_database_managed_files",
              let sha = value["manifest_sha256"] as? String,summary["manifest_sha256"] as? String == sha,
              let operation = value["operation_id"] as? String else {throw StoreRecovery.required("backup_receipt_migration_invalid")}
        let folder = try StorageObjectFiles.parts(original,absolute:true).last ?? ""
        guard folder.hasPrefix("snapshot-"),UUID(uuidString:String(folder.dropFirst("snapshot-".count))) != nil else {throw StoreRecovery.required("backup_receipt_migration_invalid")}
        let files = try StorageObjectFiles(root:root)
        // Descriptor walk rejects symlinked ancestors before a snapshot lease opens.
        let (parent,_) = try files.parent("backups/" + folder + "/manifest.json")
        Darwin.close(parent)
        let path = root.appendingPathComponent("backups/" + folder,isDirectory:true)
        let useLease = try StorageBackupUseLease(root:path)
        let bytes = try useLease.files.read("manifest.json",maximum:StorageSnapshotBudget.manifestByteLimit)
        try useLease.requireCurrent()
        guard StorageObjectFiles.sha(bytes) == sha else {throw StoreRecovery.required("backup_receipt_migration_manifest_mismatch")}
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:bytes)
        guard [1,2].contains(manifest.format),manifest.kind == StorageSnapshot.kind,
              manifest.operationID.utf8.elementsEqual(operation.utf8),manifest.storeID.utf8.elementsEqual(identity.logical_store_id.utf8) else {throw StoreRecovery.required("backup_receipt_migration_manifest_mismatch")}
        if let stored = summary["store_id"] as? String,!stored.utf8.elementsEqual(manifest.storeID.utf8) {throw StoreRecovery.required("backup_receipt_migration_manifest_mismatch")}
        if let stored = summary["source_root"] as? String,!stored.utf8.elementsEqual(manifest.sourceRoot.utf8) {throw StoreRecovery.required("backup_receipt_migration_manifest_mismatch")}
        let entries = try Row.fetchCursor(db,sql:"SELECT json_extract(value,'$.path') AS path,json_extract(value,'$.sha256') AS sha,json_extract(value,'$.size') AS size,json_type(value,'$.size') AS size_type FROM json_each((SELECT value FROM metadata WHERE key=?),'$.objects') ORDER BY CAST(key AS INTEGER)",arguments:[key])
        var count = 0,objectBytes: Int64 = 0
        while let entry = try entries.next() {
            guard count < manifest.objects.count,let stored: String = entry["path"],let digest: String = entry["sha"],let size: Int64 = entry["size"],
                  entry["size_type"] as String? == "integer",size >= 0 else {throw StoreRecovery.required("backup_receipt_migration_objects_mismatch")}
            let object = manifest.objects[count],relative: String
            if stored.hasPrefix("/") {
                let prefix = manifest.sourceRoot + "/"
                guard stored.utf8.starts(with:prefix.utf8) else {throw StoreRecovery.required("backup_receipt_migration_objects_mismatch")}
                relative = String(stored.dropFirst(prefix.count))
            } else {relative = stored}
            guard relative.utf8.elementsEqual(object.descriptor.relativePath.utf8),digest.utf8.elementsEqual(object.sha256.utf8),size == object.size else {throw StoreRecovery.required("backup_receipt_migration_objects_mismatch")}
            let (total,overflow) = objectBytes.addingReportingOverflow(size)
            guard !overflow else {throw StoreRecovery.required("backup_receipt_migration_objects_mismatch")}
            objectBytes = total;count += 1
        }
        guard count == manifest.objects.count else {throw StoreRecovery.required("backup_receipt_migration_objects_mismatch")}
        try useLease.requireCurrent()
        return Resolved(path:path,lease:useLease,manifest:manifest,count:count,objectBytes:objectBytes)
    }
}
