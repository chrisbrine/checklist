import Foundation
import GRDB

/// CL-343: process-wide historical backup accounting, one per store root.
/// A request reads only the receipt fingerprint (rowid, key and byte length,
/// never the receipt values). It uses the warm index, or answers "unavailable"
/// while one background build parses each new receipt in its own short read.
final class StorageBackupAccountingCache: @unchecked Sendable {
    /// Receipts are inserted complete (a new rowid). INSERT OR REPLACE also gives a
    /// new rowid, and an in-place UPDATE that completes a receipt changes its length.
    struct ReceiptRow: Hashable { let rowid: Int64; let key: String; let bytes: Int64 }
    struct Fingerprint: Equatable { let incarnation: String; let rows: [ReceiptRow] }
    typealias Reader = @Sendable (_ body: (Database) throws -> Void) throws -> Void

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: StorageBackupAccountingCache] = [:]
    static func shared(root: URL) -> StorageBackupAccountingCache {
        registryLock.lock(); defer { registryLock.unlock() }
        let key = root.standardizedFileURL.path
        if let cache = registry[key] { return cache }
        let cache = StorageBackupAccountingCache(); registry[key] = cache; return cache
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "checklist.backup-accounting", qos: .default)
    private let idle = DispatchGroup()
    private var building = false
    private var published: (fingerprint: Fingerprint, originals: Set<Data>?)?
    private(set) var buildCount = 0
    private(set) var parsedReceiptCount = 0
    /// Test seam: runs on the build queue before each receipt read.
    var beforeReceiptRead: (@Sendable () -> Void)?
    /// CL-355: one parsed receipt. Key ids are sorted and keep duplicate entries;
    /// `copy` is the independent backup directory and manifest (cleanup rule).
    struct Receipt { let ids: [Int32]; let entries: Int; let copy: (path: String, manifest: String)? }
    // Incremental per-receipt state shared by the background accounting build and
    // ticket cleanup steps (CL-355). `state` guards it; it is never held during a read.
    private let state = NSLock()
    private var ids: [Data: Int32] = [:]
    private var counts: [Int32] = []
    private var receipts: [ReceiptRow: Receipt] = [:]
    private var invalid: Set<ReceiptRow> = []

    static func fingerprint(_ db: Database, incarnation: String) throws -> Fingerprint {
        let rows = try Row.fetchAll(db, sql: "SELECT rowid AS id, key, octet_length(value) AS bytes FROM metadata WHERE key GLOB 'backup-generation:*' ORDER BY rowid")
        return .init(incarnation: incarnation, rows: try rows.map { row in
            guard let id: Int64 = row["id"], let key: String = row["key"], let bytes: Int64 = row["bytes"] else { throw StoreRecovery.required("backup_receipt_index_invalid") }
            return ReceiptRow(rowid: id, key: key, bytes: bytes)
        })
    }
    /// Reference decode (Foundation) used only by storageBackupRetentionIndex for
    /// equality tests. Historical presence keys of one complete receipt; throws for any other receipt.
    static func receiptKeys(_ raw: String, root: URL) throws -> [Data] { try parseReceipt(raw, root: root).keys }
    /// Keys, entry count and independent-copy descriptor of one complete receipt.
    /// The copy rule is the cleanup's: an absolute summary path, verification
    /// `manifest_database_managed_files` and one 64-hex manifest digest in both places.
    static func parseReceipt(_ raw: String, root: URL) throws -> (keys: [Data], entries: Int, copy: (path: String, manifest: String)?) {
        guard let value = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? JSON,
              value["state"] as? String == "complete", let entries = value["objects"] as? [JSON] else { throw StoreRecovery.required("backup_receipt_index_invalid") }
        var keys: [Data] = []; keys.reserveCapacity(entries.count)
        for entry in entries {
            guard let path = entry["path"] as? String, let sha = entry["sha256"] as? String, let size = entry["size"] as? NSNumber, size.int64Value >= 0 else { throw StoreRecovery.required("backup_receipt_index_invalid") }
            // Historical presence is metadata, not permission to open a backup or origin path.
            if let relative = try? ManagedPaths.relative(path, family: path.contains("source-captures/") ? "source-captures" : path.contains("source-build-cache/") ? "source-build-cache" : "objects", root: root) {
                keys.append(StorageBackupRetentionIndex.key(path: relative, sha: sha, size: size.int64Value))
            }
        }
        let summary = value["summary"] as? JSON
        var copy: (path: String, manifest: String)?
        if let path = summary?["path"] as? String, path.hasPrefix("/"), summary?["verification"] as? String == "manifest_database_managed_files",
           let manifest = value["manifest_sha256"] as? String, manifest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
           manifest == summary?["manifest_sha256"] as? String { copy = (path, manifest) }
        return (keys, entries.count, copy)
    }

    typealias Parsed = (keys: [Data], entries: Int, copy: (path: String, manifest: String)?)
    /// One receipt from SQLite JSON extraction of only path, sha256 and size per
    /// entry (no Foundation parse of the whole receipt). Nil when the row is gone;
    /// throws backup_receipt_index_invalid for any receipt receiptKeys would refuse.
    static func extractReceipt(_ db: Database, row: ReceiptRow, root: URL) throws -> Parsed? {
        guard let header = try Row.fetchOne(db, sql: "SELECT CASE WHEN json_valid(value) THEN COALESCE(json_extract(value,'$.state')='complete' AND json_type(value,'$.objects')='array',0) ELSE 0 END AS valid,json_extract(value,'$.summary.path') AS path,json_extract(value,'$.summary.verification') AS verification,json_extract(value,'$.manifest_sha256') AS manifest,json_extract(value,'$.summary.manifest_sha256') AS summary_manifest FROM metadata WHERE rowid=? AND key=?", arguments: [row.rowid, row.key]) else { return nil }
        guard header["valid"] as Bool? == true else { throw StoreRecovery.required("backup_receipt_index_invalid") }
        func text(_ column: String) -> String? { String.fromDatabaseValue(header[column] as DatabaseValue) }
        var copy: (path: String, manifest: String)?
        if let path = text("path"), path.hasPrefix("/"), text("verification") == "manifest_database_managed_files",
           let manifest = text("manifest"), manifest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, manifest == text("summary_manifest") { copy = (path, manifest) }
        let entries = try Row.fetchCursor(db, sql: """
            SELECT COALESCE(type='object' AND typeof(path)='text' AND typeof(sha)='text' AND typeof(size) IN ('integer','real') AND size>=0,0) AS valid,path,sha,CAST(size AS INTEGER) AS size FROM (
                SELECT j.type,json_extract(CASE WHEN j.type='object' THEN j.value ELSE '{}' END,'$.path') path,
                    json_extract(CASE WHEN j.type='object' THEN j.value ELSE '{}' END,'$.sha256') sha,
                    json_extract(CASE WHEN j.type='object' THEN j.value ELSE '{}' END,'$.size') size
                FROM metadata m,json_each(m.value,'$.objects') j WHERE m.rowid=? AND m.key=?)
            """, arguments: [row.rowid, row.key])
        var keys: [Data] = [], count = 0
        while let entry = try entries.next() {
            try autoreleasepool {
                count += 1
                guard entry["valid"] as Bool, let path: String = entry["path"], let sha: String = entry["sha"], let size: Int64 = entry["size"] else { throw StoreRecovery.required("backup_receipt_index_invalid") }
                if let relative = try? ManagedPaths.relative(path, family: path.contains("source-captures/") ? "source-captures" : path.contains("source-build-cache/") ? "source-build-cache" : "objects", root: root) {
                    keys.append(StorageBackupRetentionIndex.key(path: relative, sha: sha, size: size))
                }
            }
        }
        return (keys, count, copy)
    }

    /// Brings the shared per-receipt state to `target`: drops removed receipts and
    /// parses each missing one from its own short read. Parsed or invalid receipts
    /// are never parsed again while their fingerprint row stays.
    private func sync(_ target: Fingerprint, root: URL, hook: (@Sendable () -> Void)?, extract: (ReceiptRow) throws -> Parsed?) throws {
        let present = Set(target.rows)
        state.lock()
        for (row, receipt) in receipts where !present.contains(row) {
            receipts[row] = nil
            for id in receipt.ids { counts[Int(id)] -= 1 }
        }
        invalid.formIntersection(present)
        let missing = target.rows.filter { receipts[$0] == nil && !invalid.contains($0) }
        state.unlock()
        for row in missing {
            hook?()
            let parsed: Parsed?
            do {
                guard let value = try extract(row) else { continue } // Removed meanwhile; the next pass sees it.
                parsed = value
            } catch let error as CoreError where error.code == "RECOVERY_REQUIRED" { parsed = nil }
            state.lock()
            if receipts[row] == nil && !invalid.contains(row) { // Another step may have added it meanwhile.
                parsedReceiptCount += 1
                if let parsed {
                    receipts[row] = Receipt(ids: parsed.keys.map { key in
                        if let id = ids[key] { counts[Int(id)] += 1; return id }
                        let id = Int32(counts.count); ids[key] = id; counts.append(1); return id
                    }.sorted(), entries: parsed.entries, copy: parsed.copy)
                } else { invalid.insert(row) }
            }
            state.unlock()
        }
    }

    /// One immutable observation of the existing shared receipt index. Requested
    /// objects are evaluated in key-sized chunks by CleanupLookup; neither a
    /// wanted set nor the key x backup-copy product is materialized.
    func cleanupIndex(_ db: Database, root: URL, incarnation: String, limit: Int) throws -> StorageBackupRetentionIndex {
        let target = try Self.fingerprint(db, incarnation: incarnation)
        guard target.rows.count <= 1024, target.rows.reduce(Int64(0), { $0 + $1.bytes }) <= 2 * 1024 * 1024 * 1024 else { throw CoreError("CLEANUP_INVENTORY_LIMIT", "Backup generation observation exceeds its bound; bytes retained.") }
        let ordered = target.rows.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        for _ in 0..<3 {
            try sync(target, root: root, hook: nil) { row in try Self.extractReceipt(db, row: row, root: root) }
            state.lock()
            if ordered.contains(where: invalid.contains) { state.unlock(); throw StoreRecovery.required("backup_receipt_index_invalid") }
            let selected = ordered.compactMap { receipts[$0] }
            // Swift collections share immutable storage here. A later cache
            // mutation copies its own storage, never changes this observation.
            let snapshotIDs = ids
            state.unlock()
            guard selected.count == ordered.count else { continue }
            guard selected.reduce(0, { $0 + $1.entries }) <= 10_000_000 else { throw CoreError("CLEANUP_INVENTORY_LIMIT", "Backup generation observation exceeds its bound; bytes retained.") }
            let lookup = CleanupLookup(ids:snapshotIDs,receipts:selected,root:root)
            guard lookup.retainedBytes <= limit else { throw CoreError("CLEANUP_INVENTORY_LIMIT", "Backup descriptors exceed the cleanup memory bound; bytes retained.") }
            return .init(originals:[],root:root,copyManifests:lookup.manifests,cleanupLookup:lookup)
        }
        throw CoreError("CLEANUP_INVENTORY_LIMIT", "Backup generations changed during the cleanup observation; bytes retained.")
    }

    /// Shares the already bounded per-receipt Int32 arrays and interned key map.
    /// Only generation descriptors are added to a cleanup observation. One key
    /// and one candidate URL survive each iterator step, even for an arbitrarily
    /// large requested-object list. Alternatives are visited only if verification
    /// needs them, preserving fallback when an older completed copy is missing.
    final class CleanupLookup {
        private let ids: [Data:Int32]
        private let receipts: [Receipt]
        private let independent: [Receipt]
        let manifests: [String:String]
        let retainedBytes: Int
        init(ids: [Data:Int32],receipts: [Receipt],root: URL) {
            self.ids = ids;self.receipts = receipts
            var manifests: [String:String] = [:]
            var bytes = 256 + receipts.count * 128
            for receipt in receipts {
                if let copy = receipt.copy {manifests[copy.path] = copy.manifest;bytes += copy.path.utf8.count + copy.manifest.utf8.count + 256}
            }
            self.manifests = manifests;self.retainedBytes = bytes
            independent = receipts.filter {$0.copy != nil}.sorted {a,b in
                let left = a.copy!.path,right = b.copy!.path
                let localLeft = left.hasPrefix(root.path + "/"),localRight = right.hasPrefix(root.path + "/")
                return localLeft != localRight ? localLeft : left < right
            }
        }
        private func contains(_ receipt: Receipt,id: Int32) -> Bool {
            let position = StorageBackupAccountingCache.bound(receipt.ids,id,above:false)
            return position < receipt.ids.count && receipt.ids[position] == id
        }
        func containsOriginal(_ key: Data) -> Bool {
            guard let id = ids[key] else {return false}
            return receipts.contains {contains($0,id:id)}
        }
        func hasIndependentCopy(_ key: Data) -> Bool {
            guard let id = ids[key] else {return false}
            return independent.contains {contains($0,id:id)}
        }
        func copies(for key: Data) -> AnySequence<URL> {
            guard let id = ids[key] else {return AnySequence([])}
            return AnySequence { [self] in
                var index = 0,previous: String?
                return AnyIterator<URL> {
                    while index < self.independent.count {
                        let receipt = self.independent[index];index += 1
                        guard self.contains(receipt,id:id),let path = receipt.copy?.path,path != previous else {continue}
                        previous = path
                        return URL(fileURLWithPath:path,isDirectory:true)
                    }
                    return nil
                }
            }
        }
    }
    /// First index in sorted `ids` whose value is >= id (or > id when `above`).
    private static func bound(_ ids: [Int32], _ id: Int32, above: Bool) -> Int {
        var low = 0, high = ids.count
        while low < high { let mid = (low + high) / 2; if ids[mid] < id || (above && ids[mid] == id) { low = mid + 1 } else { high = mid } }
        return low
    }

    /// Request path: never parses a receipt and never waits for a build.
    /// Nil means cold, rebuilding or an unreadable receipt ("unavailable").
    func index(_ db: Database, root: URL, incarnation: String, read: @escaping Reader) throws -> StorageBackupRetentionIndex? {
        let target = try Self.fingerprint(db, incarnation: incarnation)
        lock.lock()
        if let published, published.fingerprint == target { lock.unlock(); return published.originals.map { StorageBackupRetentionIndex(originals: $0, root: root) } }
        let start = !building
        if start { building = true; buildCount += 1; idle.enter() }
        lock.unlock()
        if start { queue.async { self.build(root: root, incarnation: incarnation, read: read) } }
        return nil
    }
    /// Test helper: true when no build is running.
    func waitUntilIdle(timeout: TimeInterval = 120) -> Bool { idle.wait(timeout: .now() + timeout) == .success }

    private func build(root: URL, incarnation: String, read: Reader) {
        defer { lock.lock(); building = false; lock.unlock(); idle.leave() }
        do {
            while true {
                var target = Fingerprint(incarnation: incarnation, rows: [])
                try read { target = try Self.fingerprint($0, incarnation: incarnation) }
                lock.lock(); let current = published?.fingerprint; let hook = beforeReceiptRead; lock.unlock()
                if current == target { return }
                try sync(target, root: root, hook: hook) { row in
                    var value: Parsed?
                    try read { value = try Self.extractReceipt($0, row: row, root: root) }
                    return value
                }
                // Publish only when the shared state is exactly this fingerprint.
                let present = Set(target.rows)
                state.lock()
                let exact = receipts.count + invalid.count == present.count && receipts.keys.allSatisfy(present.contains) && invalid.isSubset(of: present)
                let originals: Set<Data>? = invalid.isEmpty ? Set(ids.lazy.filter { self.counts[Int($0.value)] > 0 }.map(\.key)) : nil
                state.unlock()
                guard exact else { continue }
                lock.lock(); published = (target, originals); lock.unlock()
            }
        } catch {
            // A failed read leaves the last published state; the next request retries.
        }
    }
}
