import Foundation
import os
import Darwin
import CryptoKit

// Descriptor-relative immutable object and snapshot publication primitives.
enum StorageSnapshotFailure: Error {
    case invalidFixture, unsupportedAuthority, sourceChanged, incomplete
    case limit, canceled, deadline, io, publicationUncertain
    case freeSpace(measured: Int64)
    case systemCall(StorageSystemFailure)
}

/// Shared only by the synchronous snapshot attempt and its verification passes.
final class StorageSnapshotMeasurement {
    let checkLock = NSLock()
    let observerLock = NSLock()
    var bytes: Int64 = 0
    var metadataBytes: Int64 = 0
    var objects: Int = 0
    var lowerBound = true
    var writerLeaseSeconds: TimeInterval = 0
    // CL-340: free bytes on the backup volume, measured once before copying.
    var availableBytes: Int64?
}

struct StorageSnapshotBudget {
    // CL-163: bounded product policy, shared by owner backup and pre-upgrade.
    // CL-270: compact metadata and backup-local content sharing qualify capture growth.
    // CL-340: no fixed logical byte ceiling. Free space on the backup volume, less
    // a safety margin, bounds the bytes, so the limit grows with the store.
    static let byteLimit: Int64 = .max
    static let freeSpaceMinimumMarginBytes: Int64 = 1_073_741_824
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
    var parallelism: Int = 4
    var pagesPerStep: Int32 = 64
    var folderAccess = StorageFolderAccess()
    var cloneFile: (Int32,Int32,String) -> Int32 = { fclonefileat($0,$1,$2,0) }
    var linkFile: (Int32, String, Int32, String) -> Int32 = { linkat($0, $1, $2, $3, 0) }
    var availableBytes: (URL) throws -> Int64 = Self.volumeAvailableBytes

    static func volumeAvailableBytes(_ url: URL) throws -> Int64 {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { throw StorageSnapshotFailure.failed("statfs") }
        let free = Int64(clamping: info.f_bavail).multipliedReportingOverflow(by: Int64(info.f_bsize))
        return free.overflow ? .max : free.partialValue
    }
    /// Safety margin kept free on the backup volume: 10% of the bytes, at least 1 GiB.
    static func freeSpaceMargin(for bytes: Int64) -> Int64 { max(freeSpaceMinimumMarginBytes, bytes / 10) }
    /// The fixed ceiling (none in production) and, once measured, the free
    /// space on the backup volume less the minimum margin.
    var effectiveMaximumBytes: Int64 {
        guard let available = measurement.availableBytes else { return maximumBytes }
        return min(maximumBytes, max(0, available - Self.freeSpaceMinimumMarginBytes))
    }
    private var limitedByFreeSpace: Bool { measurement.availableBytes != nil && effectiveMaximumBytes < maximumBytes }

    /// Measures the backup volume once per attempt and refuses at once when
    /// not even the minimum margin is free.
    func measureFreeSpace(_ parent: URL) throws {
        measurement.availableBytes = max(0, try availableBytes(parent))
        try requireFreeSpace(forMeasured: 0)
    }
    /// Refuses before copying when the measured bytes plus the margin do not fit.
    func requireFreeSpace(forMeasured bytes: Int64) throws {
        guard let available = measurement.availableBytes else { return }
        let margin = Self.freeSpaceMargin(for: bytes), needed = bytes.addingReportingOverflow(margin)
        guard needed.overflow || needed.partialValue > available else { return }
        throw freeSpaceFailure(measured: bytes, margin: margin, available: available)
    }
    func freeSpaceFailure(measured: Int64, margin: Int64, available: Int64) -> CoreError {
        let needed = measured.addingReportingOverflow(margin), required = needed.overflow ? Int64.max : needed.partialValue
        let next = "Keep the store and existing backups. Free space on the backup volume, then retry backup_create with a new command ID. Do not delete retained captures or attachments to make it fit."
        return CoreError("BACKUP_CAPACITY_EXCEEDED",
            "Backup stopped: it needs at least \(required) free bytes on the backup volume (\(measured) measured store bytes plus a \(margin)-byte safety margin), but the volume has \(available) free bytes. " + next,
            details: ["reason": "snapshot_free_space", "measured_bytes": measured, "measured_objects": measurement.objects,
                      "required_free_bytes": required, "available_bytes": available, "free_space_margin_bytes": margin, "next_step": next])
    }

    func notify(_ event: String) throws {
        measurement.observerLock.lock(); defer { measurement.observerLock.unlock() }
        try observe(event)
    }

    func check() throws {
        measurement.checkLock.lock(); defer { measurement.checkLock.unlock() }
        if canceled() { throw StorageSnapshotFailure.canceled }
        guard uptime() < deadlineUptime else { throw StorageSnapshotFailure.deadline }
    }

    func capacityFailure(_ reason: String) -> CoreError {
        let qualifier = measurement.lowerBound ? "at least " : ""
        let limit = effectiveMaximumBytes
        let bytesLimit = limit == .max ? "no fixed byte limit" : limitedByFreeSpace
            ? "\(limit) bytes (free space on the backup volume less a \(Self.freeSpaceMinimumMarginBytes)-byte margin)" : "\(limit) bytes"
        let next = "Keep the store and existing backups. Retry backup_create with a new command ID on an idle Mac for a time limit; for a capacity limit, use a Checklist build supporting this store size. Do not delete retained captures or attachments to make it fit."
        return CoreError(reason == "snapshot_deadline" ? "BACKUP_DEADLINE_EXCEEDED" : "BACKUP_CAPACITY_EXCEEDED",
            "Backup could not finish: \(qualifier)\(measurement.bytes) bytes in \(qualifier)\(measurement.objects) managed objects were measured. Limits: \(bytesLimit), \(maximumObjects) objects, \(maximumManifestBytes) manifest bytes, \(maximumObjectBytes) bytes per managed file, \(maximumRecords) records; owner and pre-upgrade backups allow \(Int(Self.productionSeconds)) seconds. " + next,
            details: ["reason": reason, "measured_bytes": measurement.bytes, "measured_objects": measurement.objects,
                      "measurement_is_lower_bound": measurement.lowerBound, "maximum_bytes": limit,
                      "maximum_objects": maximumObjects, "maximum_manifest_bytes": maximumManifestBytes,
                      "maximum_object_bytes": maximumObjectBytes, "maximum_records": maximumRecords,
                      "production_deadline_seconds": Int(Self.productionSeconds), "next_step": next])
    }
    func reporting(_ error: Error) -> Error {
        guard let failure = error as? StorageSnapshotFailure else { return error }
        switch failure {
        case .limit: return capacityFailure("snapshot_capacity")
        case .freeSpace(let measured):
            guard let available = measurement.availableBytes else { return capacityFailure("snapshot_capacity") }
            return freeSpaceFailure(measured: measured, margin: Self.freeSpaceMinimumMarginBytes, available: available)
        case .deadline: return capacityFailure("snapshot_deadline")
        default: return error
        }
    }

    /// Logical published payload bytes, including intent/manifest and link text.
    func adding(_ bytes: Int64, to total: Int64) throws -> Int64 {
        let sum = total.addingReportingOverflow(bytes)
        guard bytes >= 0, total >= 0, !sum.overflow, sum.partialValue <= maximumBytes else { throw StorageSnapshotFailure.limit }
        // Preserve the cause: record, object and metadata limits also throw .limit.
        // Carry the attempted total so the needed/free guidance describes this refusal.
        guard sum.partialValue <= effectiveMaximumBytes else { throw StorageSnapshotFailure.freeSpace(measured: sum.partialValue) }
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
    private var walk: StorageObjectWalk?
    private var hardLinkSource: StorageObjectFiles?
    private let walkDirectories: Bool
    private let reuseDigests: Bool
    private var digests: [StorageFileDigestIdentity:(String,Int64)] = [:]

    init(root: URL, folderAccess: StorageFolderAccess = .init(), pinRootForGates: Bool = false, batchSynchronization: Bool = false, walkDirectories: Bool = false, reuseDigests: Bool = false) throws {
        guard root.isFileURL, root.path.hasPrefix("/") else { throw StorageSnapshotFailure.io }
        self.root = root.standardizedFileURL
        self.folderAccess = folderAccess
        self.batchSynchronization = batchSynchronization
        self.walkDirectories = walkDirectories
        self.reuseDigests = reuseDigests
        // Foundation standardization can turn physical /private/tmp and
        // /private/var paths back into these macOS aliases. Resolve ONLY the
        // verified platform prefix; all selected descendants still traverse
        // with O_NOFOLLOW, including the store's own final entry.
        var descriptorPath = self.root.path
        for alias in ["/tmp","/var"] where descriptorPath.hasPrefix(alias + "/") {
            guard let physical = realpath(alias,nil) else { throw StorageSnapshotFailure.failed("realpath",path:alias) }
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
            guard descriptor >= 0 else { throw CoreError("STORAGE_ROOT_UNAVAILABLE","The pinned root could not be duplicated.",details:["posix_errno":errno]) }
        } else { descriptor = try folderAccess.open(path:descriptorPath,folder:self.root) }
        if pinRootForGates {
            do {gateAncestors = try pinGateAncestors(descriptorPath)}
            catch {Darwin.close(descriptor);throw error}
            PinnedRoots.shared.insert(self,key:rootKey)
        }
    }
    /// Operation-local duplicate of the already validated root, rather than a
    /// second path lookup which could select a replacement root.
    init(copying files: StorageObjectFiles, batchSynchronization: Bool = false, walkDirectories: Bool = true, reuseDigests: Bool = false) throws {
        root = files.root;folderAccess = files.folderAccess;rootKey = files.rootKey
        self.batchSynchronization = batchSynchronization;self.walkDirectories = walkDirectories;self.reuseDigests = reuseDigests
        descriptor = fcntl(files.descriptor,F_DUPFD_CLOEXEC,0)
        guard descriptor >= 0 else { throw StorageSnapshotFailure.failed("fcntl",root:files.root.path) }
    }

    deinit {
        walk = nil
        if gateAncestors != nil { PinnedRoots.shared.remove(self,key:rootKey) }
        for ancestor in gateAncestors ?? [] { Darwin.close(ancestor.parent) }
        Darwin.close(descriptor)
    }

    private func pinGateAncestors(_ physicalPath: String) throws -> [GateAncestor] {
        let parts = try Self.parts(physicalPath,absolute:true)
        guard parts.count <= 64 else { throw StorageSnapshotFailure.unsupportedAuthority }
        var ancestors: [GateAncestor] = [],current = Darwin.open("/",O_RDONLY | O_DIRECTORY | O_CLOEXEC),transferred = false
        guard current >= 0 else { throw CoreError("STORAGE_ROOT_UNAVAILABLE","The root ancestry could not be opened.",details:["posix_errno":errno]) }
        defer {
            Darwin.close(current)
            if !transferred { for ancestor in ancestors { Darwin.close(ancestor.parent) } }
        }
        for part in parts {
            // The complete root has already passed the bounded access boundary.
            let next = openat(current,part,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard next >= 0 else { throw CoreError("STORAGE_ROOT_UNAVAILABLE","The root ancestry could not be pinned.",details:["posix_errno":errno]) }
            var info = stat()
            guard fstat(next,&info) == 0 else {
                let failure = CoreError("STORAGE_ROOT_UNAVAILABLE","The root ancestry could not be inspected.",details:["posix_errno":errno])
                Darwin.close(next);throw failure
            }
            ancestors.append(.init(parent:current,name:part,device:info.st_dev,inode:info.st_ino))
            current = next
        }
        var actual = stat(),pinned = stat()
        guard fstat(current,&actual) == 0,fstat(descriptor,&pinned) == 0 else {throw CoreError("STORAGE_ROOT_UNAVAILABLE","The pinned root could not be inspected.",details:["posix_errno":errno])}
        guard actual.st_dev == pinned.st_dev,actual.st_ino == pinned.st_ino else {throw StorageSnapshotFailure.sourceChanged}
        transferred = true
        return ancestors
    }

    /// The router may reuse its already-open store root for its lifetime. Check
    /// the named directory still denotes that inode before lending the authority.
    /// This reuses no selected external source or backup destination descriptor.
    func requireNamedRoot(_ expected: URL) throws {
        func changed(_ code: Int32? = nil) -> CoreError {
            var details: JSON = ["reason":"store_root_identity_changed"]
            if let code {details["posix_errno"] = code}
            return CoreError("STORAGE_GATE_UNAVAILABLE","The pinned store folder ‘\(root.path)’ changed or is unavailable. Preserve the store and restart Checklist.",details:details)
        }
        guard Data(root.path.utf8) == Data(expected.standardizedFileURL.path.utf8),let ancestors = gateAncestors else { throw changed() }
        // Each lookup is relative to its retained parent descriptor. A rename
        // between checks cannot redirect the next lookup through a symlink.
        for ancestor in ancestors {
            var entry = stat()
            guard fstatat(ancestor.parent,ancestor.name,&entry,AT_SYMLINK_NOFOLLOW) == 0 else {throw changed(errno)}
            guard entry.st_mode & S_IFMT == S_IFDIR,entry.st_dev == ancestor.device,entry.st_ino == ancestor.inode else { throw changed() }
        }
        var actual = stat()
        guard let last = ancestors.last else {throw changed()}
        guard fstat(descriptor,&actual) == 0 else {throw changed(errno)}
        guard actual.st_dev == last.device,actual.st_ino == last.inode else {throw changed()}
    }

    private final class PinnedRoots: Sendable {
        private struct Entry { weak var root: StorageObjectFiles?; let id: ObjectIdentifier }
        static let shared = PinnedRoots()
        // Entries are lock-owned; unchecked access only retains roots for immutable gate/descriptor reads, never batch state.
        private let entries = OSAllocatedUnfairLock(uncheckedState: [Data:[Entry]]())
        func root(for key: Data) -> StorageObjectFiles? {
            // Retain before unlocking; validation and all I/O happen outside it.
            entries.withLockUnchecked { entries in
                for entry in entries[key] ?? [] { if let root = entry.root { return root } }
                return nil
            }
        }
        func insert(_ root: StorageObjectFiles,key: Data) {
            entries.withLockUnchecked { $0[key,default:[]].append(Entry(root:root,id:ObjectIdentifier(root))) }
        }
        func remove(_ root: StorageObjectFiles,key: Data) {
            entries.withLockUnchecked { entries in
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
        if walkDirectories {
            if walk == nil { walk = StorageObjectWalk(root:descriptor,rootPath:root.path) }
            if let directory = try walk!.parent(parts,create:create) { return (directory,name) }
        }
        var current = dup(descriptor)
        guard current >= 0 else { throw CoreError("STORAGE_OBJECT_UNAVAILABLE","The managed object parent could not be opened safely.",details:["posix_errno":errno]) }
        do {
            for part in parts {
                if create, mkdirat(current, part, 0o700) != 0, errno != EEXIST { throw CoreError("STORAGE_OBJECT_UNAVAILABLE","The managed object parent could not be opened safely.",details:["posix_errno":errno]) }
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw CoreError("STORAGE_OBJECT_UNAVAILABLE","The managed object parent could not be opened safely.",details:["posix_errno":errno]) }
                if create, !batchSynchronization, fsync(current) != 0 { Darwin.close(next); throw CoreError("STORAGE_OBJECT_UNAVAILABLE","The managed object parent could not be opened safely.",details:["posix_errno":errno]) }
                Darwin.close(current); current = next
            }
            return (current, name)
        } catch { Darwin.close(current); throw error }
    }

    func finishWalk() throws {
        try walk?.finish()
        try hardLinkSource?.finishWalk()
    }

    func regularOrLinkExists(_ path: String) throws -> Bool {
        let parentFD: Int32, name: String
        do { (parentFD, name) = try parent(path) }
        catch { if StorageFolderAccess.isMissing(error) { return false }; throw error }
        defer { Darwin.close(parentFD) }
        var info = stat()
        if fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return false }; throw StorageSnapshotFailure.failed("fstatat",path:path,root:root.path)
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
        guard opened >= 0 else { if errno == ENOENT { return false };throw StorageSnapshotFailure.failed("openat",path:path,root:root.path) }
        Darwin.close(opened)
        return true
    }

    func openRegular<T>(_ path: String, _ body: (Int32) throws -> T) throws -> T {
        let (directory, name) = try parent(path); defer { Darwin.close(directory) }
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw StorageSnapshotFailure.failed("openat",path:path,root:root.path) }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw StorageSnapshotFailure.unsupportedAuthority }
        return try body(file)
    }

    func size(_ path: String) throws -> Int64 {
        let (directory,name) = try parent(path);defer { Darwin.close(directory) }
        var info = stat()
        guard fstatat(directory,name,&info,AT_SYMLINK_NOFOLLOW) == 0 else { throw StorageSnapshotFailure.failed("fstatat",path:path,root:root.path) }
        guard info.st_mode & S_IFMT == S_IFREG,info.st_size >= 0 else { throw StorageSnapshotFailure.unsupportedAuthority }
        return Int64(info.st_size)
    }

    func read(_ path: String, maximum: Int) throws -> Data {
        try openRegular(path) { file in
            var result = Data(), buffer = Data(count: 65_536)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw StorageSnapshotFailure.failed("read",path:path,root:root.path) }
                if count == 0 { return result }
                guard result.count <= maximum - count else { throw StorageSnapshotFailure.limit }
                result.append(contentsOf: buffer.prefix(count))
            }
        }
    }

    func writeNew(_ path: String, bytes: Data, permissions: mode_t = 0o600) throws {
        let (directory, name) = try parent(path, create: true); defer { Darwin.close(directory) }
        let file = openat(directory, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw StorageSnapshotFailure.failed("openat",path:path,root:root.path) }
        defer { Darwin.close(file) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw StorageSnapshotFailure.failed("write",path:path,root:root.path) }; offset += count
            }
        }
        guard fchmod(file,permissions) == 0 else { throw StorageSnapshotFailure.failed("fchmod",path:path,root:root.path) }
        try Self.flush(file)
        guard fsync(directory) == 0 else { throw StorageSnapshotFailure.failed("fsync",path:path,root:root.path) }
    }

    func synchronizeOwnedFile(_ path: String) throws {
        let (directory, name) = try parent(path); defer { Darwin.close(directory) }
        let file = openat(directory, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw StorageSnapshotFailure.failed("openat",path:path,root:root.path) }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw StorageSnapshotFailure.unsupportedAuthority }
        try Self.flush(file)
        guard fsync(directory) == 0 else { throw StorageSnapshotFailure.failed("fsync",path:path,root:root.path) }
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
            guard errno == ENOENT else { throw StorageSnapshotFailure.failed("fstatat",root:root.path) }; return
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              unlinkat(descriptor, "database.sqlite-shm", 0) == 0, fsync(descriptor) == 0 else { throw StorageSnapshotFailure.failed("fsync",root:root.path) }
    }

    func digest(_ path: String, budget: StorageSnapshotBudget) throws -> (String, Int64) {
        try openRegular(path) { file in
            var before = stat(); guard fstat(file, &before) == 0 else { throw StorageSnapshotFailure.failed("fstat",path:path,root:root.path) }
            let identity = StorageFileDigestIdentity(before)
            if reuseDigests,let cached = digests[identity] { try budget.check(); return cached }
            var digest = SHA256(), count: Int64 = 0, buffer = Data(count: 65_536)
            while true {
                try budget.check()
                let size = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
                if size < 0, errno == EINTR { continue }
                guard size >= 0 else { throw StorageSnapshotFailure.failed("read",path:path,root:root.path) }
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
            let value = (Self.hex(digest.finalize()),count)
            if reuseDigests,digests.count < 131_072 { digests[identity] = value }
            return value
        }
    }

    func copy(_ path: String, to destination: StorageObjectFiles, expected: String?, budget: StorageSnapshotBudget, targetPath: String? = nil, executable: Bool = false, logicalBytesBeforeCopy: Int64? = nil) throws -> (String, Int64) {
        let target = targetPath ?? ("managed/" + path)
        let (directory,name) = try destination.parent(target,create:true);defer { Darwin.close(directory) }
        return try openRegular(path) { file in
            var before = stat();guard fstat(file,&before) == 0 else { throw StorageSnapshotFailure.failed("fstat",path:path,root:root.path) }
            let identity = StorageFileDigestIdentity(before)
            // A source which grew after inventory still uses the bounded byte
            // loop; cloning it first would materialize beyond that logical cap.
            let mayClone = before.st_size >= 0 && before.st_size <= budget.maximumObjectBytes &&
                (try? budget.adding(Int64(before.st_size),to:logicalBytesBeforeCopy ?? 0)) != nil
            let cloned = mayClone && budget.cloneFile(file,directory,name) == 0
            let cloneErrno = errno
            if mayClone,!cloned,![EXDEV,ENOTSUP,EINVAL,EPERM,ENOSYS].contains(cloneErrno) { throw StorageSnapshotFailure.failed("clonefile",path:path,root:root.path,code:cloneErrno) }
            var cloneIdentity: StorageFileDigestIdentity?
            var cloneMetadata: Int32 = -1
            defer { if cloneMetadata >= 0 { Darwin.close(cloneMetadata) } }
            if cloned {
                // Clones can inherit read-only permissions. Pin the new inode
                // while granting only this owned copy its normal writable mode.
                let metadata = openat(directory,name,O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                cloneMetadata = metadata
                guard metadata >= 0 else { throw StorageSnapshotFailure.failed("openat",path:path,root:root.path) }
                var info = stat()
                let valid = fstat(metadata,&info) == 0 && info.st_mode & S_IFMT == S_IFREG &&
                    (info.st_dev != before.st_dev || info.st_ino != before.st_ino) && fchmod(metadata,0o600) == 0
                // Keep this descriptor pinned through output reopen/check so
                // a removed clone's inode cannot be reused across that boundary.
                guard valid else { throw StorageSnapshotFailure.sourceChanged }
                cloneIdentity = StorageFileDigestIdentity(info)
            }
            let output = openat(directory,name,(cloned ? O_RDWR : O_CREAT | O_EXCL | O_WRONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,0o600)
            guard output >= 0 else { throw StorageSnapshotFailure.failed("openat",path:path,root:root.path) };defer { Darwin.close(output) }
            if let cloneIdentity {
                var info = stat()
                guard fstat(output,&info) == 0,info.st_dev == cloneIdentity.device,info.st_ino == cloneIdentity.inode else { throw StorageSnapshotFailure.sourceChanged }
                do {
                    guard info.st_size <= budget.maximumObjectBytes else { throw budget.capacityFailure("snapshot_object_bytes") }
                    _ = try budget.adding(Int64(info.st_size),to:logicalBytesBeforeCopy ?? 0)
                } catch {
                    // Even a concurrent growth during clone leaves a bounded
                    // incomplete owned file, never an oversized partial payload.
                    guard ftruncate(output,0) == 0 else { throw StorageSnapshotFailure.failed("ftruncate",path:path,root:root.path) }
                    guard fsync(output) == 0 else { throw StorageSnapshotFailure.failed("fsync",path:path,root:root.path) }
                    throw error
                }
            }
            let copied: (String,Int64)
            if cloned,reuseDigests,let cached = digests[identity] { copied = cached }
            else {
                var digest = SHA256(),total: Int64 = 0,buffer = Data(count:65_536)
                while true {
                    try budget.check()
                    let size = buffer.withUnsafeMutableBytes { Darwin.read(file,$0.baseAddress,$0.count) }
                    if size < 0,errno == EINTR { continue }
                    guard size >= 0 else { throw StorageSnapshotFailure.failed("read",path:path,root:root.path) };if size == 0 { break }
                    total += Int64(size)
                    guard total <= budget.maximumObjectBytes else { throw budget.capacityFailure("snapshot_object_bytes") }
                    if let prefix = logicalBytesBeforeCopy { _ = try budget.adding(total,to:prefix) }
                    digest.update(data:buffer.prefix(size))
                    if !cloned {
                        try buffer.withUnsafeBytes { raw in
                            var offset = 0
                            while offset < size {
                                let count = Darwin.write(output,raw.baseAddress!.advanced(by:offset),size-offset)
                                if count < 0,errno == EINTR { continue }
                                guard count > 0 else { throw StorageSnapshotFailure.failed("write",path:path,root:root.path) };offset += count
                            }
                        }
                    }
                }
                copied = (Self.hex(digest.finalize()),total)
            }
            var after = stat()
            guard fstat(file,&after) == 0,StorageFileDigestIdentity(after) == identity,copied.1 == after.st_size else { throw StorageSnapshotFailure.sourceChanged }
            guard copied.1 <= budget.maximumObjectBytes else { throw budget.capacityFailure("snapshot_object_bytes") }
            if let prefix = logicalBytesBeforeCopy { _ = try budget.adding(copied.1,to:prefix) }
            guard expected == nil || copied.0 == expected else { throw StorageSnapshotFailure.sourceChanged }
            if reuseDigests,digests.count < 131_072 { digests[identity] = copied }
            guard fchmod(output,executable ? 0o700 : 0o600) == 0 else { throw StorageSnapshotFailure.failed("fchmod",path:path,root:root.path) }
            if destination.batchSynchronization {
                guard fsync(output) == 0 else { throw StorageSnapshotFailure.failed("fsync",path:path,root:root.path) }
            } else { try Self.flush(output) }
            guard destination.batchSynchronization || fsync(directory) == 0 else { throw StorageSnapshotFailure.failed("fsync",path:path,root:root.path) }
            // A clone's success or the source cache never attests destination
            // bytes: independently hash the materialized inode in this pass.
            let verified = try destination.digest(target,budget:budget)
            guard verified == copied else { throw StorageSnapshotFailure.sourceChanged }
            return copied
        }
    }

    /// A duplicate links only to already fsynced bytes inside this owned stage.
    /// Every pathname remains in the manifest and receives full verification.
    func writeHardLink(_ path: String, to existing: String,
                       link: (Int32, String, Int32, String) -> Int32) throws -> Bool {
        // Keep source and destination walks separate: alternating their paths
        // otherwise reopens both ancestor chains for every duplicate payload.
        // This duplicate still anchors the exact same owned stage inode.
        if hardLinkSource == nil { hardLinkSource = try StorageObjectFiles(copying:self) }
        let reader = hardLinkSource!
        return try reader.openRegular(existing) { file in
            let (source, sourceName) = try reader.parent(existing); defer { Darwin.close(source) }
            let (destination, name) = try parent(path, create: true); defer { Darwin.close(destination) }
            if link(source, sourceName, destination, name) != 0 {
                // Keep owner destinations without hard links and saturated link
                // groups usable; fallback copies retain all normal byte checks.
                if [EMLINK, ENOTSUP, EPERM].contains(errno) { return false }
                throw StorageSnapshotFailure.failed("linkat",path:path,root:root.path)
            }
            var pinned = stat(), linked = stat()
            guard fstat(file, &pinned) == 0, fstatat(destination, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                  pinned.st_dev == linked.st_dev, pinned.st_ino == linked.st_ino,
                  linked.st_mode & S_IFMT == S_IFREG else { throw StorageSnapshotFailure.sourceChanged }
            guard batchSynchronization || fsync(destination) == 0 else { throw StorageSnapshotFailure.failed("fsync",path:path,root:root.path) }
            return true
        }
    }

    func linkTarget(_ path: String) throws -> String {
        let (directory, name) = try parent(path); defer { Darwin.close(directory) }
        var buffer = [UInt8](repeating: 0, count: 4097)
        let count = readlinkat(directory, name, &buffer, buffer.count)
        guard count >= 0 else {throw CoreError("STORAGE_OBJECT_UNAVAILABLE","The managed link could not be read safely.",details:["posix_errno":errno])}
        guard count > 0, count < buffer.count, let value = String(bytes: buffer.prefix(count), encoding: .utf8) else { throw StorageSnapshotFailure.unsupportedAuthority }
        return value
    }
    func writeLink(_ path: String, target: String) throws {
        let (directory, name) = try parent(path, create: true); defer { Darwin.close(directory) }
        guard symlinkat(target, directory, name) == 0, (batchSynchronization || fsync(directory) == 0) else { throw StorageSnapshotFailure.failed("symlinkat",path:path,root:root.path) }
    }
    func makeDirectory(_ name: String, batchSynchronization: Bool = false) throws -> StorageObjectFiles {
        _ = try Self.parts(name)
        guard !name.contains("/"), mkdirat(descriptor, name, 0o700) == 0, fsync(descriptor) == 0 else { throw StorageSnapshotFailure.failed("mkdirat",path:name,root:root.path) }
        return try StorageObjectFiles(root: root.appendingPathComponent(name, isDirectory: true),folderAccess:folderAccess,batchSynchronization:batchSynchronization)
    }
    /// Each regular file has already been fsynced. Sync all directory entries
    /// bottom-up before creating the commit manifest/receipt. Its F_FULLFSYNC
    /// then persists every earlier fsync on this same device (fcntl(2)).
    /// A partial stage has no publication authority.
    func synchronizeCopiedDirectories(budget: StorageSnapshotBudget) throws {
        guard batchSynchronization else { return }
        var rootInfo = stat(); guard fstat(descriptor, &rootInfo) == 0 else { throw StorageSnapshotFailure.failed("fstat",root:root.path) }
        for path in pendingDirectories.sorted(by: { $0.utf8.count > $1.utf8.count }) {
            try budget.check()
            let (directory, _) = try parent(path.isEmpty ? ".sync" : path + "/.sync")
            defer { Darwin.close(directory) }
            var info = stat()
            guard fstat(directory, &info) == 0, info.st_dev == rootInfo.st_dev else { throw StorageSnapshotFailure.unsupportedAuthority }
            guard fsync(directory) == 0 else { throw StorageSnapshotFailure.failed("fsync",root:root.path) }
        }
        pendingDirectories.removeAll()
    }

    func publish(_ staging: String, as name: String, beforeFlush: () throws -> Void = {}) throws {
        guard !staging.contains("/"), !name.contains("/") else { throw StorageSnapshotFailure.io }
        guard renameatx_np(descriptor, staging, descriptor, name, UInt32(RENAME_EXCL)) == 0 else { throw StorageSnapshotFailure.failed("renameatx_np",path:name,root:root.path) }
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
            guard directory >= 0 else { throw StorageSnapshotFailure.failed("openat",root:root.path) }
            guard let entries = fdopendir(directory) else { Darwin.close(directory);throw StorageSnapshotFailure.failed("fdopendir",root:root.path) }
            defer { closedir(entries) }
            while true {
                errno = 0
                guard let entry = readdir(entries) else {
                    guard errno == 0 else { throw StorageSnapshotFailure.failed("readdir",root:root.path) }
                    break
                }
                try budget.check()
                guard let name = withUnsafeBytes(of:entry.pointee.d_name, { bytes in
                    String(bytes:bytes.prefix(while:{$0 != 0}),encoding:.utf8)
                }) else { throw StorageSnapshotFailure.unsupportedAuthority }
                if name == "." || name == ".." { continue }
                let path = relative.isEmpty ? name : relative + "/" + name
                var info = stat()
                guard fstatat(dirfd(entries),name,&info,AT_SYMLINK_NOFOLLOW) == 0 else { throw StorageSnapshotFailure.failed("fstatat",root:root.path) }
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
        guard fsync(file) == 0, fcntl(file, F_FULLFSYNC) == 0 else { throw StorageSnapshotFailure.failed("fsync") }
    }
    static func hex<S: Sequence>(_ digest: S) -> String where S.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []; bytes.reserveCapacity(64)
        for byte in digest { bytes.append(digits[Int(byte >> 4)]); bytes.append(digits[Int(byte & 15)]) }
        return String(decoding: bytes, as: UTF8.self)
    }
    static func sha(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
}
