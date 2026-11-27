import Foundation
import GRDB

/// Workspace authority applies across projects. Stream only root spellings and
/// retain the canonical roots that cover a selected path.
struct CleanupWorkspaceProtection {
    // Filter on the covering scope index before loading any project payload.
    // The byte executor can recheck roots without scanning every record page.
    static let projectRowIDs = "SELECT rowid FROM records INDEXED BY records_scope WHERE type='project'"
    private var roots = Set<String>()
    private(set) var signatures = Set<Data>()

    init(_ db: Database,paths: [String]) throws {
        guard !paths.isEmpty else {return}
        var ancestors = Set<String>()
        for path in paths {ancestors.formUnion(Self.ancestors(of:Self.canonical(path)))}
        let projects = try Row.fetchCursor(db,sql:"""
            SELECT CAST(id AS BLOB) id,json_extract(data,'$.root_path') root
            FROM records WHERE rowid IN (\(Self.projectRowIDs)) AND json_type(data,'$.root_path')='text'
            """)
        var bytes = 0
        while let row = try projects.next() {
            let path: String = row["root"]
            guard !path.isEmpty else {continue}
            let workspace = Self.canonical(path)
            guard ancestors.contains(workspace) else {continue}
            var signature: Data = row["id"]
            let charge = signature.count + 1 + max(path.utf8.count,workspace.utf8.count)
            guard charge <= TicketCleanupInventory.rowByteLimit else {
                throw CoreError("CLEANUP_INVENTORY_LIMIT","A protecting project root exceeds the 4 MiB workspace authority entry limit; bytes retained.")
            }
            guard signatures.count < TicketCleanupInventory.rowLimit else {
                throw CoreError("CLEANUP_INVENTORY_LIMIT","Selected paths exceed the 4,096-entry workspace authority limit; bytes retained.")
            }
            guard charge <= TicketCleanupInventory.byteLimit - bytes else {
                throw CoreError("CLEANUP_INVENTORY_LIMIT","Selected paths exceed the 16 MiB workspace authority limit; bytes retained.")
            }
            signature.append(0)
            signature.append(contentsOf:workspace.utf8)
            signatures.insert(signature)
            roots.insert(workspace)
            bytes += charge
        }
    }

    func protects(_ path: String) -> Bool {
        !roots.isEmpty && Self.ancestors(of:Self.canonical(path)).contains {roots.contains($0)}
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath:path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func ancestors(of path: String) -> [String] {
        // The previous check used equality or a prefix ending at a slash.
        var result = [path]
        for index in path.indices.dropFirst() where path[index] == "/" {
            result.append(String(path[..<index]))
        }
        return result
    }
}
