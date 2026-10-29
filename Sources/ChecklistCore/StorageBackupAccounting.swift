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
    private let queue = DispatchQueue(label: "checklist.backup-accounting", qos: .utility)
    private let idle = DispatchGroup()
    private var building = false
    private var published: (fingerprint: Fingerprint, originals: Set<Data>?)?
    private(set) var buildCount = 0
    private(set) var parsedReceiptCount = 0
    /// Test seam: runs on the build queue before each receipt read.
    var beforeReceiptRead: (@Sendable () -> Void)?
    // Incremental state, touched only by the single build: unique keys, the number of
    // complete receipts that list each key, and each receipt's key ids.
    private var ids: [Data: Int32] = [:]
    private var counts: [Int32] = []
    private var receipts: [ReceiptRow: [Int32]] = [:]
    private var invalid: Set<ReceiptRow> = []

    static func fingerprint(_ db: Database, incarnation: String) throws -> Fingerprint {
        let rows = try Row.fetchAll(db, sql: "SELECT rowid AS id, key, octet_length(value) AS bytes FROM metadata WHERE key GLOB 'backup-generation:*' ORDER BY rowid")
        return .init(incarnation: incarnation, rows: try rows.map { row in
            guard let id: Int64 = row["id"], let key: String = row["key"], let bytes: Int64 = row["bytes"] else { throw StoreRecovery.required("backup_receipt_index_invalid") }
            return ReceiptRow(rowid: id, key: key, bytes: bytes)
        })
    }
    /// Historical presence keys of one complete receipt; throws for any other receipt.
    static func receiptKeys(_ raw: String, root: URL) throws -> [Data] {
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
        return keys
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
                let present = Set(target.rows)
                for (row, keys) in receipts where !present.contains(row) {
                    receipts[row] = nil
                    for id in keys { counts[Int(id)] -= 1 }
                }
                invalid.formIntersection(present)
                for row in target.rows where receipts[row] == nil && !invalid.contains(row) {
                    hook?()
                    var raw: String?
                    try read { raw = try String.fetchOne($0, sql: "SELECT value FROM metadata WHERE rowid=? AND key=?", arguments: [row.rowid, row.key]) }
                    guard let raw else { continue } // Removed meanwhile; the next pass sees it.
                    lock.lock(); parsedReceiptCount += 1; lock.unlock()
                    guard let keys = try? autoreleasepool(invoking: { try Self.receiptKeys(raw, root: root) }) else { invalid.insert(row); continue }
                    receipts[row] = keys.map { key in
                        if let id = ids[key] { counts[Int(id)] += 1; return id }
                        let id = Int32(counts.count); ids[key] = id; counts.append(1); return id
                    }
                }
                let originals: Set<Data>? = invalid.isEmpty ? Set(ids.lazy.filter { self.counts[Int($0.value)] > 0 }.map(\.key)) : nil
                lock.lock(); published = (target, originals); lock.unlock()
            }
        } catch {
            // A failed read leaves the last published state; the next request retries.
        }
    }
}
