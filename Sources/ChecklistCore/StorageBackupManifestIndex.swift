import Foundation
import CryptoKit
import GRDB
import Darwin

/// Derived membership accelerator. The complete object descriptors remain in the
/// immutable manifest; deletion still pins and verifies that manifest and payload.
/// Receipts bind both digests so a cache can never substitute another generation.
enum StorageBackupManifestIndex {
    /// Internal crash/fault seam; production installs no callback.
    nonisolated(unsafe) static var historicalCatalogObserve: ((String) throws -> Void)?
    static func prepare(root: URL, manifest: StorageSnapshotManifest, manifestSHA256: String) throws -> JSON {
        let keys = manifest.objects.map { object in
            Data(SHA256.hash(data: StorageBackupRetentionIndex.key(path:object.descriptor.relativePath,sha:object.sha256,size:object.size)))
        }.sorted {$0.lexicographicallyPrecedes($1)}
        return try prepareKeys(root:root,keys:keys,binding:manifestSHA256)
    }
    private static func prepareKeys(root: URL,keys: [Data],binding: String) throws -> JSON {
        var data = Data();data.reserveCapacity(keys.count * 32)
        for key in keys {data.append(key)}
        let relative = "backups/.indexes/" + binding + ".keys"
        let files = try StorageObjectFiles(root:root)
        let (parent,name) = try files.parent(relative,create:true);defer {Darwin.close(parent)}
        if try files.regularOrLinkExists(relative) {
            guard try files.read(relative,maximum:StorageSnapshotBudget.manifestByteLimit) == data else {throw StoreRecovery.required("backup_manifest_index_changed")}
        } else {
            let temporary = "." + UUID().uuidString.lowercased()
            let fd = openat(parent,temporary,O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,0o600)
            guard fd >= 0 else {throw StorageSnapshotFailure.io}
            defer {Darwin.close(fd);_ = unlinkat(parent,temporary,0)}
            try data.withUnsafeBytes {raw in
                var written = 0
                while written < raw.count {
                    let count = Darwin.write(fd,raw.baseAddress!.advanced(by:written),raw.count-written)
                    if count < 0 && errno == EINTR {continue}
                    guard count > 0 else {throw StorageSnapshotFailure.io};written += count
                }
            }
            guard fsync(fd) == 0,renameat(parent,temporary,parent,name) == 0,fsync(parent) == 0 else {throw StorageSnapshotFailure.io}
        }
        return ["path":relative,"sha256":hash(data),"count":keys.count]
    }

    static func prepareHistorical(root: URL,raw: String,keyRoot: URL? = nil) throws -> JSON {
        let value = jsonObject(raw)
        guard value["state"] as? String == "complete",let objects = value["objects"] as? [JSON] else {throw StoreRecovery.required("backup_receipt_index_invalid")}
        let bytes = Data(raw.utf8),sha = hash(bytes),path = "objects/backup-catalogs/" + sha + ".json"
        let files = try StorageObjectFiles(root:root)
        if try files.regularOrLinkExists(path) {
            guard try files.read(path,maximum:StorageSnapshotBudget.manifestByteLimit) == bytes else {throw StoreRecovery.required("backup_historical_catalog_changed")}
        } else {
            let (parent,name) = try files.parent(path,create:true);defer {Darwin.close(parent)}
            let temporary = ".catalog-" + UUID().uuidString.lowercased()
            let fd = openat(parent,temporary,O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,0o600)
            guard fd >= 0 else {throw StorageSnapshotFailure.io}
            defer {Darwin.close(fd);_ = unlinkat(parent,temporary,0)}
            try bytes.withUnsafeBytes {raw in
                var written = 0
                while written < raw.count {
                    let count = Darwin.write(fd,raw.baseAddress!.advanced(by:written),raw.count-written)
                    if count < 0 && errno == EINTR {continue}
                    guard count > 0 else {throw StorageSnapshotFailure.io};written += count
                }
            }
            guard fsync(fd) == 0 else {throw StorageSnapshotFailure.io}
            try historicalCatalogObserve?("catalog_staged")
            guard renameatx_np(parent,temporary,parent,name,UInt32(RENAME_EXCL)) == 0,fsync(parent) == 0 else {throw StorageSnapshotFailure.io}
            try historicalCatalogObserve?("catalog_published")
        }
        let normalizationRoot = keyRoot ?? root
        let parsed = try StorageBackupAccountingCache.parseReceipt(raw,root:normalizationRoot)
        let keys = parsed.keys.map {Data(SHA256.hash(data:$0))}.sorted {$0.lexicographicallyPrecedes($1)}
        var total: Int64 = 0
        for object in objects {
            guard let size = object["size"] as? NSNumber,size.int64Value >= 0 else {throw StoreRecovery.required("backup_receipt_index_invalid")}
            let (sum,overflow) = total.addingReportingOverflow(size.int64Value)
            guard !overflow else {throw StoreRecovery.required("backup_receipt_index_invalid")};total = sum
        }
        return ["historical_catalog":["path":path,"sha256":sha,"size":bytes.count,"object_count":objects.count,"key_root":normalizationRoot.standardizedFileURL.path],
                "manifest_index":try prepareKeys(root:root,keys:keys,binding:sha),"object_count":objects.count,"object_bytes":total]
    }
    static func historicalRaw(_ value: JSON,root: URL) throws -> String {
        guard let catalog = value["historical_catalog"] as? JSON,let path = catalog["path"] as? String,path.hasPrefix("objects/backup-catalogs/"),
              let sha = catalog["sha256"] as? String,let size = catalog["size"] as? NSNumber else {throw StoreRecovery.required("backup_historical_catalog_invalid")}
        let bytes = try StorageObjectFiles(root:root).read(path,maximum:StorageSnapshotBudget.manifestByteLimit)
        guard bytes.count == size.intValue,hash(bytes) == sha,let raw = String(data:bytes,encoding:.utf8) else {throw StoreRecovery.required("backup_historical_catalog_changed")}
        let original = jsonObject(raw)
        guard original["operation_id"] as? String == value["operation_id"] as? String,original["manifest_sha256"] as? String == value["manifest_sha256"] as? String,
              original["state"] as? String == "complete",original["format"] as? Int != 2,
              let objects = original["objects"] as? [JSON],objects.count == catalog["object_count"] as? Int else {throw StoreRecovery.required("backup_historical_catalog_invalid")}
        return raw
    }

    static func manifest(_ value: JSON,root: URL) throws -> StorageSnapshotManifest {
        try StorageBackupReceiptLocation.manifest(value,root:root)
    }

    final class Lookup: StorageBackupMembershipLookup {
        struct Generation {let bytes: Data;let count: Int;let path: String;let manifest: String;var independent: Bool = true;var cacheBinding: String? = nil}
        let generations: [Generation]
        let legacy: StorageBackupMembershipLookup?
        let manifests: [String:String]
        var retainedBytes: Int {generations.count * 256 + (legacy?.retainedBytes ?? 0)}
        init(generations: [Generation],legacy: StorageBackupMembershipLookup?) {
            self.generations = generations;self.legacy = legacy
            var manifests = legacy?.manifests ?? [:]
            for generation in generations where generation.independent {manifests[generation.path] = generation.manifest}
            self.manifests = manifests
        }
        private func contains(_ generation: Generation,_ digest: [UInt8]) -> Bool {
            return generation.bytes.withUnsafeBytes {raw in
                guard let base = raw.baseAddress else {return false}
                var lo = 0,hi = generation.count
                while lo < hi {
                    let mid = (lo+hi)/2
                    let order = digest.withUnsafeBytes {memcmp(base.advanced(by:mid*32),$0.baseAddress!,32)}
                    if order < 0 {lo = mid+1} else {hi = mid}
                }
                return lo < generation.count && digest.withUnsafeBytes {memcmp(base.advanced(by:lo*32),$0.baseAddress!,32)} == 0
            }
        }
        func containsOriginal(_ key: Data) -> Bool {
            if legacy?.containsOriginal(key) == true {return true}
            let digest = Array(SHA256.hash(data:key));return generations.contains {contains($0,digest)}
        }
        func hasIndependentCopy(_ key: Data) -> Bool {
            if legacy?.hasIndependentCopy(key) == true {return true}
            let digest = Array(SHA256.hash(data:key));return generations.contains {$0.independent && contains($0,digest)}
        }
        func copies(for key: Data) -> AnySequence<URL> {
            AnySequence { [self] in
                let digest = Array(SHA256.hash(data:key))
                var position = 0
                var previous = Set<String>()
                var older = self.legacy?.copies(for:key).makeIterator()
                return AnyIterator<URL> {
                    while position < self.generations.count {
                        // Receipts arrive oldest first; prefer the newest verified generation.
                        let generation = self.generations[self.generations.count-1-position];position += 1
                        if generation.independent,self.contains(generation,digest),previous.insert(generation.path).inserted {return URL(fileURLWithPath:generation.path,isDirectory:true)}
                    }
                    return older?.next()
                }
            }
        }
    }
    private struct Cached {let identity: [Int64];let bytes: Data}
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String:Cached] = [:]
    /// Header-only admission before any compact key file is opened or rebuilt.
    /// Historical catalogs may contain more descriptors than normalized keys.
    static func preflight(_ db: Database) throws -> Int {
        let generations = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM metadata WHERE key GLOB 'backup-generation:*'") ?? 0
        guard generations <= 1024 else {throw CoreError("CLEANUP_INVENTORY_LIMIT","Backup generation observation exceeds its bound; bytes retained.")}
        let rows = try Row.fetchCursor(db,sql:"""
            SELECT json_extract(value,'$.object_count') AS objects,json_type(value,'$.object_count') AS object_type,
                json_extract(value,'$.manifest_index.count') AS keys,json_type(value,'$.manifest_index.count') AS key_type
            FROM metadata WHERE key GLOB 'backup-generation:*' AND json_extract(value,'$.format')=2
            """)
        var descriptors = 0
        while let row = try rows.next() {
            guard row["object_type"] as String? == "integer",row["key_type"] as String? == "integer",
                  let objects: Int = row["objects"],let keys: Int = row["keys"],
                  objects >= 0,objects <= 1_000_000,keys >= 0,keys <= objects else {throw StoreRecovery.required("backup_receipt_index_invalid")}
            descriptors += objects
            guard descriptors <= 10_000_000 else {throw CoreError("CLEANUP_INVENTORY_LIMIT","Backup generation observation exceeds its bound; bytes retained.")}
        }
        return descriptors
    }

    /// Validate/load derived bytes at startup, outside cleanup preparations. This
    /// cost is part of startup qualification, never charged to a byte continuation.
    static func warm(_ db: Database,root: URL) throws {
        _ = try preflight(db)
        let rows = try String.fetchCursor(db,sql:"SELECT value FROM metadata WHERE key GLOB 'backup-generation:*' AND json_extract(value,'$.format')=2")
        while let raw = try rows.next() {_ = try generation(jsonObject(raw),root:root)}
    }
    static func retainCached(root: URL, manifests: Set<String>) {
        let prefix = root.path + "/backups/.indexes/"
        lock.lock();defer {lock.unlock()}
        for key in cache.keys where key.hasPrefix(prefix) && !manifests.contains(where:{key.hasPrefix(prefix + $0 + ".keys:")}) {cache.removeValue(forKey:key)}
    }
    static func generation(_ value: JSON,root: URL) throws -> Lookup.Generation {
        guard let descriptor = value["manifest_index"] as? JSON,let relative = descriptor["path"] as? String,
              relative.hasPrefix("backups/.indexes/"),let digest = descriptor["sha256"] as? String,
              let count = descriptor["count"] as? Int,count >= 0,count <= 1_000_000,
              let manifest = value["manifest_sha256"] as? String,value["state"] as? String == "complete" else {throw StoreRecovery.required("backup_receipt_index_invalid")}
        let historical = value["historical_catalog"] as? JSON
        let summary = value["summary"] as? JSON ?? [:]
        let path: String
        if historical == nil {path = try StorageBackupReceiptLocation.location(value,root:root).path}
        else {path = summary["path"] as? String ?? ""}
        if historical == nil {
            guard path.hasPrefix("/"),["manifest_database_managed_files","historical_manifest_only"].contains(summary["verification"] as? String ?? ""),
                  manifest == summary["manifest_sha256"] as? String else {throw StoreRecovery.required("backup_receipt_index_invalid")}
        }
        let files = try StorageObjectFiles(root:root)
        if try !files.regularOrLinkExists(relative) {
            let rebuilt: JSON
            if let historical {
                let keyRoot = (historical["key_root"] as? String).map {URL(fileURLWithPath:$0,isDirectory:true)} ?? root
                rebuilt = try prepareHistorical(root:root,raw:historicalRaw(value,root:root),keyRoot:keyRoot)["manifest_index"] as! JSON
            }
            else {rebuilt = try prepare(root:root,manifest:Self.manifest(value,root:root),manifestSHA256:manifest)}
            guard rebuilt["sha256"] as? String == digest,rebuilt["count"] as? Int == count else {throw StoreRecovery.required("backup_manifest_index_changed")}
        }
        let (parent,name) = try files.parent(relative)
        defer {Darwin.close(parent)}
        let fd = openat(parent,name,O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {throw StoreRecovery.required("backup_manifest_index_missing")};defer {Darwin.close(fd)}
        var info = stat()
        guard fstat(fd,&info) == 0,info.st_mode & S_IFMT == S_IFREG,info.st_size == count * 32 else {throw StoreRecovery.required("backup_manifest_index_invalid")}
        let identity = [Int64(info.st_dev),Int64(info.st_ino),Int64(info.st_size),Int64(info.st_mtimespec.tv_sec),Int64(info.st_mtimespec.tv_nsec),Int64(info.st_ctimespec.tv_sec),Int64(info.st_ctimespec.tv_nsec)]
        let key = root.path + "/" + relative + ":" + digest
        lock.lock();let existing = cache[key];lock.unlock()
        let bytes: Data
        if let existing,existing.identity == identity {bytes = existing.bytes}
        else {
            // Read through the pinned descriptor, never a second path resolution.
            var data = Data(count:count * 32)
            try data.withUnsafeMutableBytes {raw in
                var offset = 0
                while offset < raw.count {
                    let n = pread(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset,off_t(offset))
                    if n < 0 && errno == EINTR {continue}
                    guard n > 0 else {throw StorageSnapshotFailure.io};offset += n
                }
            }
            guard hash(data) == digest else {throw StoreRecovery.required("backup_manifest_index_changed")}
            bytes = data
            lock.lock();cache[key] = Cached(identity:identity,bytes:bytes);lock.unlock()
        }
        return Lookup.Generation(bytes:bytes,count:count,path:path,manifest:manifest,independent:historical == nil && summary["verification"] as? String == "manifest_database_managed_files",cacheBinding:URL(fileURLWithPath:relative).deletingPathExtension().lastPathComponent)
    }
}
protocol StorageBackupMembershipLookup {
    var retainedBytes: Int {get}
    var manifests: [String:String] {get}
    func containsOriginal(_ key: Data) -> Bool
    func hasIndependentCopy(_ key: Data) -> Bool
    func copies(for key: Data) -> AnySequence<URL>
}
