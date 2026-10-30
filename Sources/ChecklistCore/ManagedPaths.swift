import Foundation
import GRDB
import Darwin

/// Stored managed descriptors are relative to this instance. Outside absolute
/// descriptors are never filesystem authority, including during preflight.
public enum ManagedPaths {
    public static func relative(_ stored: String, family: String, root: URL) throws -> String? {
        _ = try StorageObjectFiles.parts(family)
        let parts = try StorageObjectFiles.parts(stored, absolute: stored.hasPrefix("/"))
        let value: String
        if stored.hasPrefix("/") {
            let prefix = root.standardizedFileURL.path + "/"
            guard stored.utf8.starts(with: prefix.utf8) else {
                // Validate the declared family layout without touching the path.
                guard parts.contains(family.split(separator: "/").first.map(String.init) ?? "") else { throw StorageSnapshotFailure.unsupportedAuthority }
                return nil
            }
            value = String(stored.dropFirst(prefix.count))
        } else { value = stored }
        _ = try StorageObjectFiles.parts(value)
        guard value.utf8.starts(with: (family + "/").utf8) else { throw StorageSnapshotFailure.unsupportedAuthority }
        return value
    }

    public static func resolve(_ stored: String, family: String, root: URL) throws -> URL? {
        guard let relative = try relative(stored, family: family, root: root) else { return nil }
        let files = try StorageObjectFiles(root: root)
        let (parent, name) = try files.parent(relative); defer { Darwin.close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT) else { throw StorageSnapshotFailure.failed("fstatat",path:relative,root:root.path) }
        return root.appendingPathComponent(relative)
    }
}

/// A read-only relocation decision. Only local files are inspected. An origin
/// is inferred only when every managed absolute descriptor has the same exact
/// prefix before its declared family. Each relocated descriptor needs local
/// content proof; disagreement or absent proof leaves the old value unavailable.
enum ManagedPathRelocation {
    static let captureBindingsKey = "managed-capture-paths-v3"
    static func captureBindings(_ db: Database, root: URL) throws -> [Data: String] {
        guard (try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0) >= 3 else { return [:] }
        guard let raw = try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key=?", arguments: [captureBindingsKey]) else { return [:] }
        guard let entries = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [JSON] else { throw StorageSnapshotFailure.unsupportedAuthority }
        var result: [Data: String] = [:]
        for entry in entries {
            guard Set(entry.keys) == ["stored", "relative"], let stored = entry["stored"] as? String, let relative = entry["relative"] as? String,
                  !relative.hasPrefix("/"), try ManagedPaths.relative(relative, family: "source-captures", root: root) == relative else { throw StorageSnapshotFailure.unsupportedAuthority }
            _ = try ManagedPaths.relative(stored, family: "source-captures", root: root)
            let key = Data(stored.utf8)
            guard result[key] == nil else { throw StorageSnapshotFailure.unsupportedAuthority }
            result[key] = relative
        }
        return result
    }
    struct Field {
        let keys: [String]
        let stored: String
        let family: String
        let files: [Proof]
    }
    struct Proof {
        let suffix: String
        let sha: String?
        let size: Int64?
        let link: String?
    }
    struct Decision { let relative: String?; let reason: String? }
    struct Plan {
        var decisions: [Data: Decision]
        func decision(_ stored: String, family: String, root: URL) throws -> Decision {
            if let local = try ManagedPaths.relative(stored, family: family, root: root) { return .init(relative: local, reason: nil) }
            return decisions[Data(stored.utf8)] ?? .init(relative: nil, reason: "outside_store_root")
        }
        func rewrite(_ value: inout JSON, type: String, root: URL) throws {
            for field in try fields(value, type: type) {
                if let relative = try decision(field.stored, family: field.family, root: root).relative {
                    set(&value, keys: field.keys, value: relative)
                }
            }
        }
    }
    private static func set(_ object: inout JSON, keys: [String], value: String) {
        guard let first = keys.first else { return }
        if keys.count == 1 { object[first] = value }
        else if var child = object[first] as? JSON { set(&child, keys: Array(keys.dropFirst()), value: value); object[first] = child }
    }
    static func fields(_ value: JSON, type: String) throws -> [Field] {
        var result: [Field] = []
        func digest(_ raw: Any?) throws -> String? {
            guard let raw else { return nil }
            guard let sha = raw as? String, sha.utf8.count == 64,
                  sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw StorageSnapshotFailure.unsupportedAuthority }
            return sha
        }
        func add(_ key: String, _ family: String, sha: Any? = nil, size: Any? = nil) throws {
            guard let raw = value[key] else { return }
            guard let path = raw as? String, !path.isEmpty else { throw StorageSnapshotFailure.unsupportedAuthority }
            let count = (size as? NSNumber)?.int64Value
            if let count, count < 0 { throw StorageSnapshotFailure.unsupportedAuthority }
            result.append(.init(keys: [key], stored: path, family: family, files: [.init(suffix: "", sha: try digest(sha), size: count, link: nil)]))
        }
        switch type {
        case "attachment" where value["mode"] as? String == "managed":
            try add("path", "objects", sha: value["sha256"], size: value["size"])
            try add("preview_path", "objects")
        case "project": try add("icon_path", "icons", sha: (value["icon_asset"] as? JSON)?["sha256"])
        case "source_execution":
            try add("output_path", "source-executions", sha: value["output_sha256"])
            // Working directories are authorized by the corresponding capture,
            // never by the directory merely existing.
            if let raw = value["working_directory"] {
                guard let path = raw as? String, !path.isEmpty else { throw StorageSnapshotFailure.unsupportedAuthority }
                result.append(.init(keys: ["working_directory"], stored: path, family: "source-captures", files: []))
            }
        case "source_capture":
            guard let path = value["snapshot_path"] as? String, let entries = value["files"] as? [JSON] else { throw StorageSnapshotFailure.unsupportedAuthority }
            var proofs: [Proof] = []
            for entry in entries {
                guard let name = entry["path"] as? String else { throw StorageSnapshotFailure.unsupportedAuthority }
                _ = try StorageObjectFiles.parts(name)
                if entry["kind"] as? String == "deleted" { continue }
                let sha = try digest(entry["sha256"])
                guard sha != nil else { throw StorageSnapshotFailure.unsupportedAuthority }
                let link = entry["kind"] as? String == "symlink" ? entry["target"] as? String : nil
                guard entry["kind"] as? String == "file" || link != nil else { throw StorageSnapshotFailure.unsupportedAuthority }
                proofs.append(.init(suffix: "/" + name, sha: sha, size: (entry["size"] as? NSNumber)?.int64Value, link: link))
            }
            result.append(.init(keys: ["snapshot_path"], stored: path, family: "source-captures", files: proofs))
        case "manifest":
            if let evidence = value["evidence"] as? JSON, let capture = evidence["source_capture"] as? JSON {
                result = try fields(capture, type: "source_capture").map { .init(keys: ["evidence", "source_capture"] + $0.keys, stored: $0.stored, family: $0.family, files: $0.files) }
            }
        default: break
        }
        return result
    }
    private static func originCandidates(_ path: String, family: String) throws -> Set<Data> {
        let parts = try StorageObjectFiles.parts(path, absolute: true)
        let indices = parts.indices.filter { parts[$0] == family && $0 + 1 < parts.count }
        guard !indices.isEmpty else { throw StorageSnapshotFailure.unsupportedAuthority }
        return Set(indices.map { Data(("/" + parts.prefix($0).joined(separator: "/")).utf8) })
    }
    /// Current schemas never establish a new relocation. Snapshot inventory
    /// validates each record's fields during its existing envelope pass; scanning
    /// and decoding the entire database here would produce the same bindings.
    static func snapshotPlan(_ db: Database,root: URL,budget: StorageSnapshotBudget,objectRoot: URL? = nil) throws -> Plan {
        if (try Int.fetchOne(db,sql:"PRAGMA user_version") ?? 0) >= 3 {
            return Plan(decisions:try captureBindings(db,root:root).mapValues { Decision(relative:$0,reason:nil) })
        }
        return try plan(db,root:root,budget:budget,objectRoot:objectRoot)
    }

    static func plan(_ db: Database, root: URL, budget: StorageSnapshotBudget, objectRoot: URL? = nil) throws -> Plan {
        var localFiles: StorageObjectFiles?
        let bindings = try captureBindings(db, root: root)
        let mayRelocateLegacy = (try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0) < 3
        var all: [Field] = [], prefixes: Set<Data>?
        let rows = try Row.fetchCursor(db, sql: "SELECT " + CommandRouter.canonicalRecordColumns + " FROM records ORDER BY rowid")
        var count = 0
        while let row = try rows.next() {
            try budget.check(); count += 1
            guard count <= budget.maximumRecords else { throw StorageSnapshotFailure.limit }
            let record = try GRDBRecordEnvelopeAdapter.decode(row)
            let fields = try fields(record.object, type: record.type)
            for field in fields where field.stored.hasPrefix("/") && bindings[Data(field.stored.utf8)] == nil {
                let candidates: Set<Data>
                if try ManagedPaths.relative(field.stored, family: field.family, root: root) != nil { candidates = [Data(root.standardizedFileURL.path.utf8)] }
                else { candidates = try originCandidates(field.stored, family: field.family) }
                prefixes = prefixes.map { $0.intersection(candidates) } ?? candidates
            }
            all += fields
        }
        var decisions = bindings.mapValues { Decision(relative: $0, reason: nil) }
        // Prove captures before execution working-directory references.
        for field in all where field.keys.last != "working_directory" {
            let key = Data(field.stored.utf8)
            if bindings[key] != nil { continue }
            if try ManagedPaths.relative(field.stored, family: field.family, root: root) != nil { continue }
            // Only a protected legacy upgrade may establish a new binding.
            // Unproved leftovers in protocol 3 cannot silently become available.
            guard mayRelocateLegacy else { decisions[key] = .init(relative: nil, reason: "outside_store_root"); continue }
            guard let prefixes, prefixes.count == 1, let origin = prefixes.first else { decisions[key] = .init(relative: nil, reason: "ambiguous_origin_root"); continue }
            let originPath = String(decoding: origin, as: UTF8.self)
            let prefix = originPath == "/" ? "/" : originPath + "/"
            guard field.stored.utf8.starts(with: prefix.utf8),
                  let relative = try ManagedPaths.relative(String(field.stored.dropFirst(prefix.count)), family: field.family, root: root) else {
                decisions[key] = .init(relative: nil, reason: "ambiguous_origin_root"); continue
            }
            var reason: String?
            do {
                if localFiles == nil { localFiles = try StorageObjectFiles(root: objectRoot ?? root) }
                let files = localFiles!
                for proof in field.files {
                    try budget.check()
                    let relative = relative + proof.suffix
                    if let link = proof.link {
                        guard try files.linkTarget(relative) == link, StorageObjectFiles.sha(Data(link.utf8)) == proof.sha else { reason = "relocated_digest_mismatch"; break }
                    } else {
                        let actual = try files.digest(relative, budget: budget)
                        guard proof.sha == nil || proof.sha == actual.0, proof.size == nil || proof.size == actual.1 else { reason = "relocated_digest_mismatch"; break }
                    }
                }
                if field.files.isEmpty {
                    // Empty captures still need a local, no-follow directory.
                    let (parent, name) = try files.parent(relative); defer { Darwin.close(parent) }
                    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw StorageSnapshotFailure.io }; Darwin.close(fd)
                }
            } catch let failure as StorageSnapshotFailure {
                switch failure { case .deadline, .limit, .canceled: throw failure; default: reason = "relocated_object_unavailable" }
            }
            let decision = Decision(relative: reason == nil ? relative : nil, reason: reason)
            // Repeated manifest authority must agree, never let a weaker proof win.
            if let prior = decisions[key], prior.relative == nil { continue }
            decisions[key] = decision
        }
        for field in all where field.keys.last == "working_directory" {
            let key = Data(field.stored.utf8)
            if try ManagedPaths.relative(field.stored, family: field.family, root: root) != nil { continue }
            if decisions[key] == nil { decisions[key] = .init(relative: nil, reason: "capture_not_proven") }
        }
        return Plan(decisions: decisions)
    }
    static func apply(_ db: Database, root: URL, plan: Plan) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT rowid,type,data FROM records WHERE type IN ('attachment','project','source_capture','manifest','source_execution')")
        var bindings = try captureBindings(db, root: root)
        for row in rows {
            let raw: String = row["data"], type: String = row["type"], rowID: Int64 = row["rowid"]
            var value = jsonObject(raw)
            if type == "manifest" {
                // Evidence and whole-manifest digests are immutable review authority.
                // Store only the proved local descriptor outside those bytes.
                for field in try fields(value, type: type) {
                    if let relative = try plan.decision(field.stored, family: field.family, root: root).relative { bindings[Data(field.stored.utf8)] = relative }
                }
                continue
            }
            try plan.rewrite(&value, type: type, root: root)
            if try jsonString(value) != jsonString(jsonObject(raw)) { try db.execute(sql: "UPDATE records SET data=? WHERE rowid=?", arguments: [try jsonString(value), rowID]) }
        }
        let entries: [JSON] = bindings.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map { ["stored": String(decoding: $0.key, as: UTF8.self), "relative": $0.value] }
        try db.execute(sql: "INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [captureBindingsKey, try jsonString(entries)])
    }
}
