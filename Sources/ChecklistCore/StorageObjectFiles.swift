import Foundation
import Darwin
import CryptoKit

// Descriptor-relative immutable object and snapshot publication primitives.
enum StorageSnapshotFailure: Error {
    case invalidFixture, unsupportedAuthority, sourceChanged, incomplete
    case limit, canceled, deadline, io, publicationUncertain
}

/// Shared only by the synchronous snapshot attempt and its verification passes.
final class StorageSnapshotMeasurement {
    var bytes: Int64 = 0
    var metadataBytes: Int64 = 0
    var objects: Int = 0
    var lowerBound = true
}

struct StorageSnapshotBudget {
    // CL-163: bounded product policy, shared by owner backup and pre-upgrade.
    // CL-270: compact metadata and backup-local content sharing qualify capture growth.
    static let byteLimit: Int64 = 8 * 1_073_741_824
    static let objectLimit = 500_000
    static let manifestByteLimit = 128 * 1_048_576
    static let productionSeconds: TimeInterval = 1_800
    static func production() -> Self {
        .init(deadlineUptime: ProcessInfo.processInfo.systemUptime + productionSeconds, canceled: { false })
    }
    let deadlineUptime: TimeInterval
    let canceled: () -> Bool
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var measurement = StorageSnapshotMeasurement()
    // Private fixture barriers/faults. Never installed as a service callback.
    var observe: (String) throws -> Void = { _ in }
    var maximumBytes: Int64 = Self.byteLimit
    var maximumObjectBytes: Int64 = 524_288_000
    var maximumObjects: Int = Self.objectLimit
    var maximumManifestBytes: Int = Self.manifestByteLimit
    var maximumRecords: Int = 100_000
    var pagesPerStep: Int32 = 64
    var folderAccess = StorageFolderAccess()
    var linkFile: (Int32, String, Int32, String) -> Int32 = { linkat($0, $1, $2, $3, 0) }

    func check() throws {
        if canceled() { throw StorageSnapshotFailure.canceled }
        guard uptime() < deadlineUptime else { throw StorageSnapshotFailure.deadline }
    }

    func capacityFailure(_ reason: String) -> CoreError {
        let qualifier = measurement.lowerBound ? "at least " : ""
        let next = "Keep the store and existing backups. Retry on an idle Mac for a time limit; for a capacity limit, use a Checklist build supporting this store size. Do not delete retained captures or attachments to make it fit."
        return CoreError(reason == "snapshot_deadline" ? "BACKUP_DEADLINE_EXCEEDED" : "BACKUP_CAPACITY_EXCEEDED",
            "Backup could not finish: \(qualifier)\(measurement.bytes) bytes in \(qualifier)\(measurement.objects) managed objects were measured. Limits: \(maximumBytes) bytes, \(maximumObjects) objects, \(maximumManifestBytes) manifest bytes, \(maximumObjectBytes) bytes per managed file, \(maximumRecords) records; owner and pre-upgrade backups allow \(Int(Self.productionSeconds)) seconds. " + next,
            details: ["reason": reason, "measured_bytes": measurement.bytes, "measured_objects": measurement.objects,
                      "measurement_is_lower_bound": measurement.lowerBound, "maximum_bytes": maximumBytes,
                      "maximum_objects": maximumObjects, "maximum_manifest_bytes": maximumManifestBytes,
                      "maximum_object_bytes": maximumObjectBytes, "maximum_records": maximumRecords,
                      "production_deadline_seconds": Int(Self.productionSeconds), "next_step": next])
    }
    func reporting(_ error: Error) -> Error {
        guard let failure = error as? StorageSnapshotFailure else { return error }
        switch failure {
        case .limit: return capacityFailure("snapshot_capacity")
        case .deadline: return capacityFailure("snapshot_deadline")
        default: return error
        }
    }

    /// Logical published payload bytes, including intent/manifest and link text.
    func adding(_ bytes: Int64, to total: Int64) throws -> Int64 {
        let sum = total.addingReportingOverflow(bytes)
        guard bytes >= 0, total >= 0, !sum.overflow, sum.partialValue <= maximumBytes else { throw StorageSnapshotFailure.limit }
        return sum.partialValue
    }
}

/// Descriptor-relative, no-follow access for this store generation.
/// This is not a replacement object store or an authority grant from a path.
final class StorageObjectFiles {
    let root: URL
    let descriptor: Int32
    let folderAccess: StorageFolderAccess
    private let rootKey: Data
    private struct GateAncestor { let parent: Int32; let name: String; let device: dev_t; let inode: ino_t }
    private var gateAncestors: [GateAncestor]?
    // Enabled only for a newly created, unpublished snapshot/restore stage.
    private let batchSynchronization: Bool
    private var pendingDirectories: Set<String> = []

    init(root: URL, folderAccess: StorageFolderAccess = .init(), pinRootForGates: Bool = false, batchSynchronization: Bool = false) throws {
        guard root.isFileURL, root.path.hasPrefix("/") else { throw StorageSnapshotFailure.io }
        self.root = root.standardizedFileURL
        self.folderAccess = folderAccess
        self.batchSynchronization = batchSynchronization
        // Foundation standardization can turn physical /private/tmp and
        // /private/var paths back into these macOS aliases. Resolve ONLY the
        // verified platform prefix; all selected descendants still traverse
        // with O_NOFOLLOW, including the store's own final entry.
        var descriptorPath = self.root.path
        for alias in ["/tmp","/var"] where descriptorPath.hasPrefix(alias + "/") {
            guard let physical = realpath(alias,nil) else { throw StorageSnapshotFailure.io }
            defer { free(physical) }
            let prefix = String(cString:physical)
            guard prefix == "/private" + alias else { throw StorageSnapshotFailure.io }
            descriptorPath = prefix + descriptorPath.dropFirst(alias.count)
            break
        }
        _ = try Self.parts(descriptorPath, absolute: true)
        rootKey = Data(descriptorPath.utf8)
        if !pinRootForGates,folderAccess.reusePinnedRoots,let pinned = PinnedRoots.shared.root(for:rootKey) {
            try pinned.requireNamedRoot(self.root)
            descriptor = fcntl(pinned.descriptor,F_DUPFD_CLOEXEC,0)
            guard descriptor >= 0 else { throw StorageSnapshotFailure.io }
        } else { descriptor = try folderAccess.open(path:descriptorPath,folder:self.root) }
        if pinRootForGates {
            gateAncestors = try pinGateAncestors(descriptorPath)
            PinnedRoots.shared.insert(self,key:rootKey)
        }
    }
    deinit {
        if gateAncestors != nil { PinnedRoots.shared.remove(self,key:rootKey) }
        for ancestor in gateAncestors ?? [] { Darwin.close(ancestor.parent) }
        Darwin.close(descriptor)
    }

    private func pinGateAncestors(_ physicalPath: String) throws -> [GateAncestor] {
        let parts = try Self.parts(physicalPath,absolute:true)
        guard parts.count <= 64 else { throw StorageSnapshotFailure.unsupportedAuthority }
        var ancestors: [GateAncestor] = [],current = Darwin.open("/",O_RDONLY | O_DIRECTORY | O_CLOEXEC),transferred = false
        guard current >= 0 else { throw StorageSnapshotFailure.io }
        defer {
            Darwin.close(current)
            if !transferred { for ancestor in ancestors { Darwin.close(ancestor.parent) } }
        }
        for part in parts {
            // The complete root has already passed the bounded access boundary.
            let next = openat(current,part,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard next >= 0 else { throw StorageSnapshotFailure.io }
            var info = stat()
            guard fstat(next,&info) == 0 else { Darwin.close(next);throw StorageSnapshotFailure.io }
            ancestors.append(.init(parent:current,name:part,device:info.st_dev,inode:info.st_ino))
            current = next
        }
        var actual = stat(),pinned = stat()
        guard fstat(current,&actual) == 0,fstat(descriptor,&pinned) == 0,actual.st_dev == pinned.st_dev,actual.st_ino == pinned.st_ino else { throw StorageSnapshotFailure.sourceChanged }
        transferred = true
        return ancestors
    }

    /// The router may reuse its already-open store root for its lifetime. Check
    /// the named directory still denotes that inode before lending the authority.
    /// This reuses no selected external source or backup destination descriptor.
    func requireNamedRoot(_ expected: URL) throws {
        func changed() -> CoreError {
            CoreError("STORAGE_GATE_UNAVAILABLE","The pinned store folder ‘\(root.path)’ changed or is unavailable. Preserve the store and restart Checklist.",details:["reason":"store_root_identity_changed"])
        }
        guard Data(root.path.utf8) == Data(expected.standardizedFileURL.path.utf8),let ancestors = gateAncestors else { throw changed() }
        // Each lookup is relative to its retained parent descriptor. A rename
        // between checks cannot redirect the next lookup through a symlink.
        for ancestor in ancestors {
            var entry = stat()
            guard fstatat(ancestor.parent,ancestor.name,&entry,AT_SYMLINK_NOFOLLOW) == 0,
                  entry.st_mode & S_IFMT == S_IFDIR,entry.st_dev == ancestor.device,entry.st_ino == ancestor.inode else { throw changed() }
        }
        var actual = stat()
        guard let last = ancestors.last,fstat(descriptor,&actual) == 0,actual.st_dev == last.device,actual.st_ino == last.inode else { throw changed() }
    }

    private final class PinnedRoots {
        private struct Entry { weak var root: StorageObjectFiles?; let id: ObjectIdentifier }
        static let shared = PinnedRoots()
        private let lock = NSLock()
        private var entries: [Data:[Entry]] = [:]
        func root(for key: Data) -> StorageObjectFiles? {
            // Retain before unlocking; validation and all I/O happen outside it.
            var retained: StorageObjectFiles?
            lock.lock()
            for entry in entries[key] ?? [] {
                if let root = entry.root { retained = root;break }
            }
            lock.unlock()
            return retained
        }
        func insert(_ root: StorageObjectFiles,key: Data) {
            lock.withLock { entries[key,default:[]].append(Entry(root:root,id:ObjectIdentifier(root))) }
        }
        func remove(_ root: StorageObjectFiles,key: Data) {
            lock.withLock {
                let remaining = (entries[key] ?? []).filter { $0.id != ObjectIdentifier(root) }
                entries[key] = remaining.isEmpty ? nil : remaining
            }
        }
    }

    static func parts(_ path: String, absolute: Bool = false) throws -> [String] {
        guard !path.contains("\0"), absolute == path.hasPrefix("/") else { throw StorageSnapshotFailure.unsupportedAuthority }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." }) else { throw StorageSnapshotFailure.unsupportedAuthority }
        return parts
    }

    func parent(_ path: String, create: Bool = false) throws -> (Int32, String) {
        var parts = try Self.parts(path)
        let name = parts.removeLast()
        if create, batchSynchronization {
            var prefix = ""; pendingDirectories.insert(prefix)
            for part in parts { prefix = prefix.isEmpty ? part : prefix + "/" + part; pendingDirectories.insert(prefix) }
        }
        var current = dup(descriptor)
        guard current >= 0 else { throw StorageSnapshotFailure.io }
        do {
            for part in parts {
                if create, mkdirat(current, part, 0o700) != 0, errno != EEXIST { throw StorageSnapshotFailure.io }
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw StorageSnapshotFailure.io }
                if create, !batchSynchronization, fsync(current) != 0 { Darwin.close(next); throw StorageSnapshotFailure.io }
                Darwin.close(current); current = next
            }
            return (current, name)
        } catch { Darwin.close(current); throw error }
    }

    func regularOrLinkExists(_ path: String) throws -> Bool {
        let parentFD: Int32, name: String
        do { (parentFD, name) = try parent(path) }
        catch { if StorageFolderAccess.isMissing(error) { return false }; throw error }
        defer { Darwin.close(parentFD) }
        var info = stat()
        if fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return false }; throw StorageSnapshotFailure.io
        }
        guard [S_IFREG,S_IFLNK].contains(info.st_mode & S_IFMT) else { throw StorageSnapshotFailure.unsupportedAuthority }
        return true
    }

    func directoryExists(_ path: String) throws -> Bool {
        let parent: Int32,name: String
        do { (parent,name) = try self.parent(path) }
        catch where StorageFolderAccess.isMissing(error) { return false }
        defer { Darwin.close(parent) }
        let opened = openat(parent,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard opened >= 0 else { if errno == ENOENT { return false };throw StorageSnapshotFailure.io }
        Darwin.close(opened)
        return true
    }

    func openRegular<T>(_ path: String, _ body: (Int32) throws -> T) throws -> T {
        let (directory, name) = try parent(path); defer { Darwin.close(directory) }
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw StorageSnapshotFailure.io }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw StorageSnapshotFailure.unsupportedAuthority }
        return try body(file)
    }

    func size(_ path: String) throws -> Int64 {
        try openRegular(path) { file in
            var info = stat()
            guard fstat(file, &info) == 0, info.st_size >= 0 else { throw StorageSnapshotFailure.io }
            return Int64(info.st_size)
        }
    }

    func read(_ path: String, maximum: Int) throws -> Data {
        try openRegular(path) { file in
            var result = Data(), buffer = Data(count: 65_536)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw StorageSnapshotFailure.io }
                if count == 0 { return result }
                guard result.count <= maximum - count else { throw StorageSnapshotFailure.limit }
                result.append(contentsOf: buffer.prefix(count))
            }
        }
    }

    func writeNew(_ path: String, bytes: Data, permissions: mode_t = 0o600) throws {
        let (directory, name) = try parent(path, create: true); defer { Darwin.close(directory) }
        let file = openat(directory, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw StorageSnapshotFailure.io }
        defer { Darwin.close(file) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw StorageSnapshotFailure.io }; offset += count
            }
        }
        guard fchmod(file,permissions) == 0 else { throw StorageSnapshotFailure.io }
        try Self.flush(file)
        guard fsync(directory) == 0 else { throw StorageSnapshotFailure.io }
    }

    func synchronizeOwnedFile(_ path: String) throws {
        let (directory, name) = try parent(path); defer { Darwin.close(directory) }
        let file = openat(directory, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw StorageSnapshotFailure.io }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw StorageSnapshotFailure.unsupportedAuthority }
        try Self.flush(file)
        guard fsync(directory) == 0 else { throw StorageSnapshotFailure.io }
    }

    /// Only for the private destination after its last writable handle closes.
    /// DELETE-mode header plus absent WAL is required; never touch source WAL.
    func removeClosedCopySharedMemory() throws {
        try openRegular("database.sqlite") { file in
            var header = [UInt8](repeating: 0, count: 20)
            guard pread(file, &header, header.count, 0) == 20, header[18] == 1, header[19] == 1 else { throw StorageSnapshotFailure.incomplete }
        }
        var info = stat()
        guard fstatat(descriptor, "database.sqlite-wal", &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw StorageSnapshotFailure.incomplete }
        if fstatat(descriptor, "database.sqlite-shm", &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw StorageSnapshotFailure.io }; return
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              unlinkat(descriptor, "database.sqlite-shm", 0) == 0, fsync(descriptor) == 0 else { throw StorageSnapshotFailure.io }
    }

    func digest(_ path: String, budget: StorageSnapshotBudget) throws -> (String, Int64) {
        try openRegular(path) { file in
            var before = stat(); guard fstat(file, &before) == 0 else { throw StorageSnapshotFailure.io }
            var digest = SHA256(), count: Int64 = 0, buffer = Data(count: 65_536)
            while true {
                try budget.check()
                let size = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
                if size < 0, errno == EINTR { continue }
                guard size >= 0 else { throw StorageSnapshotFailure.io }
                if size == 0 { break }
                count += Int64(size)
                guard count <= budget.maximumBytes else { throw StorageSnapshotFailure.limit }
                digest.update(data: buffer.prefix(size))
            }
            var after = stat()
            guard fstat(file, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_size == after.st_size, count == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw StorageSnapshotFailure.sourceChanged }
            return (Self.hex(digest.finalize()), count)
        }
    }

    func copy(_ path: String, to destination: StorageObjectFiles, expected: String?, budget: StorageSnapshotBudget, targetPath: String? = nil, executable: Bool = false) throws -> (String, Int64) {
        let target = targetPath ?? ("managed/" + path)
        let (directory, name) = try destination.parent(target, create: true); defer { Darwin.close(directory) }
        let output = openat(directory, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw StorageSnapshotFailure.io }
        defer { Darwin.close(output) }
        let copied = try openRegular(path) { file -> (String, Int64) in
            var before = stat(); guard fstat(file, &before) == 0 else { throw StorageSnapshotFailure.io }
            var digest = SHA256(), total: Int64 = 0, buffer = Data(count: 65_536)
            while true {
                try budget.check()
                let size = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
                if size < 0, errno == EINTR { continue }
                guard size >= 0 else { throw StorageSnapshotFailure.io }
                if size == 0 { break }
                total += Int64(size)
                guard total <= budget.maximumObjectBytes else { throw StorageSnapshotFailure.limit }
                digest.update(data: buffer.prefix(size))
                try buffer.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < size {
                        let count = Darwin.write(output, raw.baseAddress!.advanced(by: offset), size - offset)
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else { throw StorageSnapshotFailure.io }; offset += count
                    }
                }
            }
            var after = stat(); guard fstat(file, &after) == 0,
                before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
                before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                total == after.st_size else { throw StorageSnapshotFailure.sourceChanged }
            return (Self.hex(digest.finalize()), total)
        }
        guard expected == nil || copied.0 == expected else { throw StorageSnapshotFailure.sourceChanged }
        guard fchmod(output, executable ? 0o700 : 0o600) == 0 else {throw StorageSnapshotFailure.io}
        if destination.batchSynchronization {
            guard fsync(output) == 0 else { throw StorageSnapshotFailure.io }
        } else { try Self.flush(output) }
        guard destination.batchSynchronization || fsync(directory) == 0 else { throw StorageSnapshotFailure.io }
        let verified = try destination.digest(target, budget: budget)
        guard verified == copied else { throw StorageSnapshotFailure.sourceChanged }
        return copied
    }

    /// A duplicate links only to already fsynced bytes inside this owned stage.
    /// Every pathname remains in the manifest and receives full verification.
    func writeHardLink(_ path: String, to existing: String,
                       link: (Int32, String, Int32, String) -> Int32) throws -> Bool {
        return try openRegular(existing) { file in
            let (source, sourceName) = try parent(existing); defer { Darwin.close(source) }
            let (destination, name) = try parent(path, create: true); defer { Darwin.close(destination) }
            if link(source, sourceName, destination, name) != 0 {
                // Keep owner destinations without hard links and saturated link
                // groups usable; fallback copies retain all normal byte checks.
                if [EMLINK, ENOTSUP, EPERM].contains(errno) { return false }
                throw StorageSnapshotFailure.io
            }
            var pinned = stat(), linked = stat()
            guard fstat(file, &pinned) == 0, fstatat(destination, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                  pinned.st_dev == linked.st_dev, pinned.st_ino == linked.st_ino,
                  linked.st_mode & S_IFMT == S_IFREG else { throw StorageSnapshotFailure.sourceChanged }
            guard batchSynchronization || fsync(destination) == 0 else { throw StorageSnapshotFailure.io }
            return true
        }
    }

    func linkTarget(_ path: String) throws -> String {
        let (directory, name) = try parent(path); defer { Darwin.close(directory) }
        var buffer = [UInt8](repeating: 0, count: 4097)
        let count = readlinkat(directory, name, &buffer, buffer.count)
        guard count > 0, count < buffer.count, let value = String(bytes: buffer.prefix(count), encoding: .utf8) else { throw StorageSnapshotFailure.unsupportedAuthority }
        return value
    }
    func writeLink(_ path: String, target: String) throws {
        let (directory, name) = try parent(path, create: true); defer { Darwin.close(directory) }
        guard symlinkat(target, directory, name) == 0, (batchSynchronization || fsync(directory) == 0) else { throw StorageSnapshotFailure.io }
    }
    func makeDirectory(_ name: String, batchSynchronization: Bool = false) throws -> StorageObjectFiles {
        _ = try Self.parts(name)
        guard !name.contains("/"), mkdirat(descriptor, name, 0o700) == 0, fsync(descriptor) == 0 else { throw StorageSnapshotFailure.io }
        return try StorageObjectFiles(root: root.appendingPathComponent(name, isDirectory: true),folderAccess:folderAccess,batchSynchronization:batchSynchronization)
    }
    /// Each regular file has already been fsynced. Sync all directory entries
    /// bottom-up before creating the commit manifest/receipt. Its F_FULLFSYNC
    /// then persists every earlier fsync on this same device (fcntl(2)).
    /// A partial stage has no publication authority.
    func synchronizeCopiedDirectories(budget: StorageSnapshotBudget) throws {
        guard batchSynchronization else { return }
        var rootInfo = stat(); guard fstat(descriptor, &rootInfo) == 0 else { throw StorageSnapshotFailure.io }
        for path in pendingDirectories.sorted(by: { $0.utf8.count > $1.utf8.count }) {
            try budget.check()
            let (directory, _) = try parent(path.isEmpty ? ".sync" : path + "/.sync")
            defer { Darwin.close(directory) }
            var info = stat()
            guard fstat(directory, &info) == 0, info.st_dev == rootInfo.st_dev else { throw StorageSnapshotFailure.unsupportedAuthority }
            guard fsync(directory) == 0 else { throw StorageSnapshotFailure.io }
        }
        pendingDirectories.removeAll()
    }

    func publish(_ staging: String, as name: String, beforeFlush: () throws -> Void = {}) throws {
        guard !staging.contains("/"), !name.contains("/") else { throw StorageSnapshotFailure.io }
        guard renameatx_np(descriptor, staging, descriptor, name, UInt32(RENAME_EXCL)) == 0 else { throw StorageSnapshotFailure.io }
        try synchronizePublicationDirectory(beforeFlush: beforeFlush)
    }
    func synchronizePublicationDirectory(beforeFlush: () throws -> Void = {}) throws {
        do { try beforeFlush() } catch { throw StorageSnapshotFailure.publicationUncertain }
        guard fsync(descriptor) == 0 else { throw StorageSnapshotFailure.publicationUncertain }
    }
    func listedFiles(budget: StorageSnapshotBudget) throws -> Set<String> {
        // Enumerate relative to the already-open root; never resolve a managed
        // descendant through Foundation or a symlink.
        var files: Set<String> = [], directories = [""]
        while let relative = directories.popLast() {
            try budget.check()
            let directory: Int32
            if relative.isEmpty { directory = dup(descriptor) }
            else {
                let (parent,name) = try self.parent(relative)
                defer { Darwin.close(parent) }
                directory = openat(parent,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            }
            guard directory >= 0 else { throw StorageSnapshotFailure.io }
            guard let entries = fdopendir(directory) else { Darwin.close(directory);throw StorageSnapshotFailure.io }
            defer { closedir(entries) }
            while true {
                errno = 0
                guard let entry = readdir(entries) else {
                    guard errno == 0 else { throw StorageSnapshotFailure.io }
                    break
                }
                try budget.check()
                guard let name = withUnsafeBytes(of:entry.pointee.d_name, { bytes in
                    String(bytes:bytes.prefix(while:{$0 != 0}),encoding:.utf8)
                }) else { throw StorageSnapshotFailure.unsupportedAuthority }
                if name == "." || name == ".." { continue }
                let path = relative.isEmpty ? name : relative + "/" + name
                var info = stat()
                guard fstatat(dirfd(entries),name,&info,AT_SYMLINK_NOFOLLOW) == 0 else { throw StorageSnapshotFailure.io }
                switch info.st_mode & S_IFMT {
                case S_IFDIR: directories.append(path)
                case S_IFREG, S_IFLNK: files.insert(path)
                default: throw StorageSnapshotFailure.unsupportedAuthority
                }
                guard files.count <= budget.maximumObjects + 3 else { throw StorageSnapshotFailure.limit }
            }
        }
        return files
    }
    static func flush(_ file: Int32) throws {
        guard fsync(file) == 0, fcntl(file, F_FULLFSYNC) == 0 else { throw StorageSnapshotFailure.io }
    }
    static func hex<S: Sequence>(_ digest: S) -> String where S.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []; bytes.reserveCapacity(64)
        for byte in digest { bytes.append(digits[Int(byte >> 4)]); bytes.append(digits[Int(byte & 15)]) }
        return String(decoding: bytes, as: UTF8.self)
    }
    static func sha(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
}
