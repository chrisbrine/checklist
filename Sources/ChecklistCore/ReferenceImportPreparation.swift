import Foundation
import GRDB
import Darwin

/// The content identity of one regular file, taken without reading it: a content write
/// changes the size or modification time, a replacement the device or inode. A change of
/// permissions or ownership alone (finding b906f027) leaves it equal.
struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    init?(descriptor: Int32) {
        var info = stat()
        guard fstat(descriptor,&info) == 0,info.st_mode & S_IFMT == S_IFREG else { return nil }
        device = UInt64(info.st_dev); inode = UInt64(info.st_ino); size = Int64(info.st_size)
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }

    /// `lstat`: a symlink in the final component is not a regular file.
    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        device = UInt64(info.st_dev); inode = UInt64(info.st_ino); size = Int64(info.st_size)
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }
}

/// Bytes hashed before the object gate and the SQL writer (CL-71, finding d21e29c2).
struct VerifiedObject {
    let sha256: String
    let identity: FileIdentity
}

/// A reference-mode import read and hashed before the writer. The transaction uses it only
/// for the same command input and an unchanged file identity.
struct PreparedReferenceImport {
    let path: String
    let sha256: String
    let size: Int
    let identity: FileIdentity
    let digest: String
}

extension CommandRouter {
    /// Before the writer: hash one file once and keep its identity. The identity must be the
    /// same before and after the read, so a concurrent change is not cached. Every other
    /// outcome (a missing or irregular file, a read error, a change during the read or a
    /// wrong hash) is recorded as failed, so the writer never reads it (finding 4485fafb).
    func prefetchVerifiedObject(_ path: String, sha256: String, into preparation: inout CommandPreparation) {
        guard preparation.verifiedObjects[path] == nil, !preparation.failedObjects.contains(path) else { return }
        guard (try? managedRelative(path,family:"objects")) != nil else { preparation.failedObjects.insert(path); return }
        if let before = try? managedIdentity(path), let data = try? managedRead(path,family:"objects",maximum:500 * 1024 * 1024),
           (try? managedIdentity(path)) == before, hash(data) == sha256 {
            preparation.verifiedObjects[path] = VerifiedObject(sha256: sha256, identity: before)
        } else { preparation.failedObjects.insert(path) }
    }

    /// Inside the writer: an unchanged content identity stands in for re-reading bytes that
    /// this command hashed before the writer. A prepared object whose identity changed, or
    /// whose hash already failed, fails at once (finding b906f027); only an object that this
    /// command did not prepare is read here.
    func objectBytesMatch(_ path: String, sha256: String) -> Bool {
        guard (try? managedRelative(path,family:"objects")) != nil else { return false }
        let preparation = commandPreparation
        if preparation.failedObjects.contains(path) { return false }
        if let verified = preparation.verifiedObjects[path] { return verified.sha256 == sha256 && (try? managedIdentity(path)) == verified.identity }
        guard let data = try? managedRead(path,family:"objects",maximum:500 * 1024 * 1024) else { return false }
        return hash(data) == sha256
    }

    /// Size of a verified object, or nil when this command did not prefetch it.
    func verifiedObjectSize(_ path: String, sha256: String) -> Int? {
        guard let verified = commandPreparation.verifiedObjects[path], verified.sha256 == sha256, (try? managedIdentity(path)) == verified.identity else { return nil }
        return Int(verified.identity.size)
    }

    /// Every string value of `key` anywhere in a command input (evidence refs nest at several levels).
    static func referencedValues(_ value: Any, key: String) -> Set<String> {
        switch value {
        case let object as [String: Any]:
            var found = Set<String>()
            for (name, child) in object { if name == key, let text = child as? String { found.insert(text) } else { found.formUnion(referencedValues(child, key: key)) } }
            return found
        case let array as [Any]: return array.reduce(into: Set<String>()) { $0.formUnion(referencedValues($1, key: key)) }
        default: return []
        }
    }

    /// Reads and hashes a reference-mode `attachment_add` before the writer. The same
    /// authority and containment checks run again in the transaction.
    func prepareReferenceImport(method: String, params p: JSON, caller c: Caller) throws -> PreparedReferenceImport? {
        guard method == "attachment_add", ["reference", "external_reference"].contains(p["mode"] as? String ?? "managed") else { return nil }
        var path = "", roots: [String] = [], replay = false
        try readForPreparation { db in
            let pid = try self.scope(db, p, c, write: true)
            try self.assistantPermission(c, pid, "post_notes_on_request")
            _ = try self.task(db, p, pid)
            if let command = p["command_id"] as? String, try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM commands WHERE principal=? AND command_id=?)", arguments: [c.principal, command]) == true { replay = true; return }
            let source = p["source"] as? JSON ?? [:], raw = p["path"] as? String ?? source["path"] as? String ?? ""
            guard !raw.isEmpty else { throw CoreError("FILE_ACCESS_REQUIRED", "Choose a local file.") }
            let project = try self.record(db, pid, type: "project")
            if source["kind"] as? String == "workspace_file", !raw.hasPrefix("/"), let base = project["root_path"] as? String { path = canonical(URL(fileURLWithPath: base).appendingPathComponent(raw).path) } else { path = canonical(raw) }
            if !c.isOwner {
                guard let workspace = c.workspace, containsPath(canonical(workspace), path), let base = project["root_path"] as? String, containsPath(base, path) else { throw CoreError("FILE_ACCESS_REQUIRED", "Agent file imports must stay inside its enrolled workspace.") }
                roots = self.agentReadRoots(c, project: project)
            }
        }
        if replay { return nil }
        guard let before = FileIdentity(path: path) else { throw CoreError("INVALID_INPUT", "Attach a regular file. Directories can be provided as human-request references.") }
        guard before.size <= 500 * 1024 * 1024 else { throw CoreError("FILE_TOO_LARGE", "This local importer accepts files up to 500 MiB.") }
        let bytes = c.isOwner ? try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) : try SafeFileRead.read(path, maximum: 500 * 1024 * 1024, allowedRoots: roots).bytes
        guard FileIdentity(path: path) == before else { throw CoreError("SOURCE_CHANGED", "The file changed during import.") }
        let digest = hash(bytes)
        if let expected = p["expected_sha256"] as? String, expected != digest { throw CoreError("SOURCE_CHANGED", "The file changed before import.") }
        return PreparedReferenceImport(path: path, sha256: digest, size: bytes.count, identity: before, digest: hash(Data((method + (try jsonString(p))).utf8)))
    }
}
