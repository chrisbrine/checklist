import Foundation

/// A receipt from a different physical root cannot authorize opening its old
/// absolute path. Its snapshot name is resolved only in this instance's backups.
enum StorageBackupReceiptLocation {
    static func location(_ value: JSON, root: URL) throws -> URL {
        guard value["state"] as? String == "complete", let summary = value["summary"] as? JSON,
              let path = summary["path"] as? String, path.hasPrefix("/"), !path.contains("\0"),
              let digest = value["manifest_sha256"] as? String,
              digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              digest == summary["manifest_sha256"] as? String,
              ["manifest_database_managed_files", "historical_manifest_only"].contains(summary["verification"] as? String ?? "") else {
            throw StoreRecovery.required("backup_receipt_index_invalid")
        }
        if let source = summary["source_root"] as? String, source.utf8.elementsEqual(root.path.utf8) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let folder = try StorageObjectFiles.parts(path, absolute: true).last ?? ""
        guard folder.hasPrefix("snapshot-"), UUID(uuidString: String(folder.dropFirst("snapshot-".count))) != nil else {
            throw StoreRecovery.required("backup_receipt_index_invalid")
        }
        return root.appendingPathComponent("backups/" + folder, isDirectory: true)
    }

    static func manifest(_ value: JSON, root: URL) throws -> StorageSnapshotManifest {
        let selected = try location(value, root: root)
        let summary = value["summary"] as! JSON
        let lease = try StorageBackupUseLease(root: selected)
        let bytes = try lease.files.read("manifest.json", maximum: StorageSnapshotBudget.manifestByteLimit)
        try lease.requireCurrent()
        guard hash(bytes) == value["manifest_sha256"] as? String else { throw StoreRecovery.required("backup_manifest_changed") }
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self, from: bytes)
        guard [1, 2].contains(manifest.format), manifest.kind == StorageSnapshot.kind,
              let operation = value["operation_id"] as? String, manifest.operationID.utf8.elementsEqual(operation.utf8),
              let store = summary["store_id"] as? String, manifest.storeID.utf8.elementsEqual(store.utf8),
              let source = summary["source_root"] as? String, manifest.sourceRoot.utf8.elementsEqual(source.utf8) else {
            throw StoreRecovery.required("backup_manifest_binding_invalid")
        }
        try lease.requireCurrent()
        return manifest
    }
}
