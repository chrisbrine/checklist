import Foundation

/// Protection matching only: a copied historical path also keeps its strict
/// snapshot-name counterpart in this store. A name collision retains extra
/// bytes; this helper grants no read, copy or pruning authority.
enum StorageBackupProtectionAliases {
    static func paths(_ original: String, root: URL) -> Set<String> {
        var paths: Set<String> = [original]
        guard original.hasPrefix("/"), let parts = try? StorageObjectFiles.parts(original, absolute: true),
              let folder = parts.last, folder.hasPrefix("snapshot-"),
              UUID(uuidString: String(folder.dropFirst("snapshot-".count))) != nil else { return paths }
        paths.insert(root.appendingPathComponent("backups/" + folder, isDirectory: true).path)
        return paths
    }
}
