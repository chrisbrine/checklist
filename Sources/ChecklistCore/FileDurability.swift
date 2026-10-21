import Foundation
import Darwin

enum StoreRecovery {
    static func recordFailure(root: URL, error: Error) {
        // Content-free best effort; a failed/full volume may refuse this too.
        // Never replace database bytes or an initialized identity on failure.
        guard let directory = try? StoreDirectory(root:root) else { return }
        let value: JSON = ["format":1,"state":"recovery_required","code":(error as? CoreError)?.code ?? "STORAGE_FAILED","reason":(error as? CoreError)?.details["reason"] as? String ?? "storage_operation_failed","observed_at":now()]
        guard let bytes = try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys),let exists = try? directory.regularFileExists("checklist-storage.recovery.json") else { return }
        try? directory.publishReceipt(bytes,name:"checklist-storage.recovery.json",replacingPreparedReceipt:exists)
    }
    static func required(_ reason: String) -> CoreError {
        CoreError("RECOVERY_REQUIRED", "The existing store needs explicit recovery. Preserve its database, journal and managed files.", details: ["reason": reason])
    }
    static func upgradeUnavailable() -> CoreError {
        CoreError("UPGRADE_UNAVAILABLE", "This store version cannot be opened safely by this build. No incompatible upgrade or rollback was attempted.", details: ["reason": "unsupported_schema_or_identity_version"])
    }
}

/// Serializes this bootstrap protocol only. Unaware older binaries do not honor
/// this lock: it is deliberately NOT an incompatible-writer exclusion fence.
final class StoreDirectory {
    let root: URL
    let descriptor: Int32
    private var lockDescriptor: Int32
    static let lockName = "checklist.bootstrap.lock"

    static func anchoredRoot(_ root: URL) -> URL {
        // Resolve the caller-selected ancestor location (including macOS /var),
        // then refuse a symlink at the store's own final directory entry.
        root.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(root.lastPathComponent,isDirectory:true).standardizedFileURL
    }
    init(root: URL) throws {
        let root = Self.anchoredRoot(root)
        self.root = root
        var newlyCreated: [URL] = []
        var ancestor = root
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            newlyCreated.append(ancestor)
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { throw StoreRecovery.required("store_directory_unavailable") }
            ancestor = parent
        }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw StoreRecovery.required("store_directory_unavailable") }
        descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StoreRecovery.required("unsafe_or_unavailable_store_directory") }
        // A flushed receipt is insufficient if its newly created directory entry
        // can disappear. Flush each created ancestor and the root's parent too.
        do {
            for directory in newlyCreated.reversed() { try Self.flushDirectory(directory) }
            for directory in newlyCreated.reversed() { try Self.flushDirectory(directory.deletingLastPathComponent()) }
            try Self.flushDirectory(root.deletingLastPathComponent())
        } catch { Darwin.close(descriptor); throw error }
        let lock = openat(descriptor, Self.lockName, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { Darwin.close(descriptor); throw StoreRecovery.required("bootstrap_lock_unavailable") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lock); Darwin.close(descriptor)
            throw CoreError("STORE_BUSY", "Another guarded bootstrap is in progress. Retry after that operation has ended.")
        }
        lockDescriptor = lock
    }
    deinit { if lockDescriptor >= 0 { Darwin.close(lockDescriptor) }; Darwin.close(descriptor) }
    func releaseBootstrapLock() { if lockDescriptor >= 0 { _ = flock(lockDescriptor,LOCK_UN);Darwin.close(lockDescriptor);lockDescriptor = -1 } }

    private static func flushDirectory(_ directory: URL) throws {
        let file = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw StoreRecovery.required("store_ancestor_unavailable") }
        defer { Darwin.close(file) }
        guard fsync(file) == 0 else { throw StoreRecovery.required("store_ancestor_flush_failed") }
    }

    func regularFileExists(_ name: String) throws -> Bool {
        var value = stat()
        if fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return false }
            throw StoreRecovery.required("store_entry_unavailable")
        }
        guard value.st_mode & S_IFMT == S_IFREG else { throw StoreRecovery.required("unsafe_store_entry") }
        return true
    }
    func createDatabaseFile(_ name: String) throws {
        let file = openat(descriptor, name, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw StoreRecovery.required("fresh_database_creation_failed") }
        Darwin.close(file)
        try synchronizeDirectory()
    }
    func readReceipt(_ name: String) throws -> Data {
        guard try regularFileExists(name) else { throw StoreRecovery.required("identity_receipt_missing") }
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw StoreRecovery.required("identity_receipt_unavailable") }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_size > 0, info.st_size <= 16_384 else { throw StoreRecovery.required("invalid_identity_receipt") }
        var data = Data(count: Int(info.st_size)); var offset = 0
        try data.withUnsafeMutableBytes { bytes in
            while offset < bytes.count {
                let count = Darwin.read(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw StoreRecovery.required("identity_receipt_read_failed") }
                offset += count
            }
        }
        return data
    }
    func publishReceipt(_ bytes: Data, name: String, replacingPreparedReceipt: Bool) throws {
        let temporary = ".checklist-bootstrap-" + UUID().uuidString + ".tmp"
        let file = openat(descriptor, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw StoreRecovery.required("identity_staging_failed") }
        defer { Darwin.close(file); _ = unlinkat(descriptor, temporary, 0) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw StoreRecovery.required("identity_write_failed") }
                offset += count
            }
        }
        guard fsync(file) == 0, fcntl(file, F_FULLFSYNC) == 0 else { throw StoreRecovery.required("identity_flush_failed") }
        let status = replacingPreparedReceipt
            ? renameat(descriptor, temporary, descriptor, name)
            : linkat(descriptor, temporary, descriptor, name, 0)
        guard status == 0 else { throw StoreRecovery.required("identity_publication_failed") }
        _ = unlinkat(descriptor, temporary, 0)
        try synchronizeDirectory()
    }
    func synchronizeDirectory() throws {
        guard fsync(descriptor) == 0 else { throw StoreRecovery.required("store_directory_flush_failed") }
    }
    func ensureObjectsDirectory() throws {
        if mkdirat(descriptor, "objects", 0o700) != 0, errno != EEXIST { throw StoreRecovery.required("objects_directory_unavailable") }
        let objects = openat(descriptor, "objects", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard objects >= 0 else { throw StoreRecovery.required("unsafe_objects_directory") }
        Darwin.close(objects); try synchronizeDirectory()
    }
    func requireFreshScaffoldingOnly() throws {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: root.path) }
        catch { throw StoreRecovery.required("store_directory_unavailable") }
        for name in names {
            if [Self.lockName, "service.lock", "service.endpoint", ".archive-storage.lock"].contains(name) { _ = try regularFileExists(name); continue }
            if name == "objects" {
                let objects = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard objects >= 0 else { throw StoreRecovery.required("unsafe_objects_directory") }
                Darwin.close(objects)
                guard (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(name).path).isEmpty) == true else { throw StoreRecovery.required("prior_store_evidence_without_database") }
                continue
            }
            throw StoreRecovery.required("prior_store_evidence_without_database")
        }
    }
}

/// The native service must retain this lease from before opening any database
/// until its process exits. Old released services hold the same service.lock;
/// acquiring it proves that their process can no longer run a pending unlink.
/// It is not an OS security boundary against owner-written database tools.
public final class StorageServiceLease: @unchecked Sendable {
    let directory: StoreDirectory
    private let file: Int32
    public init(root: URL) throws {
        directory = try StoreDirectory(root:root)
        file = openat(directory.descriptor,"service.lock",O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard file >= 0 else { throw StoreRecovery.required("service_lock_unavailable") }
        var info = stat()
        guard fstat(file,&info) == 0,info.st_mode & S_IFMT == S_IFREG,info.st_nlink == 1 else { Darwin.close(file);throw StoreRecovery.required("unsafe_service_lock") }
        guard flock(file,LOCK_EX | LOCK_NB) == 0 else { Darwin.close(file);throw CoreError("STORE_BUSY","Another Checklist service still owns storage. Its active work must drain or its process must exit before upgrade.") }
        directory.releaseBootstrapLock()
    }
    deinit { _ = flock(file,LOCK_UN);Darwin.close(file) }
    func requireRoot(_ root: URL) throws {
        guard Data(directory.root.standardizedFileURL.path.utf8) == Data(root.standardizedFileURL.path.utf8) else { throw StoreRecovery.required("service_lease_root_mismatch") }
        var entry = stat(),actual = stat()
        guard fstat(file,&actual) == 0,fstatat(directory.descriptor,"service.lock",&entry,AT_SYMLINK_NOFOLLOW) == 0,actual.st_dev == entry.st_dev,actual.st_ino == entry.st_ino else { throw StoreRecovery.required("service_lock_identity_changed") }
    }
}
