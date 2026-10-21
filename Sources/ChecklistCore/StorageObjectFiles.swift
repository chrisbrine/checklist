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
    // The qualified retained store needs ~1.7 GiB, 56k objects and a 35 MB manifest.
    static let byteLimit: Int64 = 8 * 1_073_741_824
    static let objectLimit = 200_000
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

    init(root: URL) throws {
        guard root.isFileURL, root.path.hasPrefix("/") else { throw StorageSnapshotFailure.io }
        self.root = root.standardizedFileURL
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw StorageSnapshotFailure.io }
        do {
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
            for part in try Self.parts(descriptorPath, absolute: true) {
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw StorageSnapshotFailure.io }
                Darwin.close(current); current = next
            }
        } catch { Darwin.close(current); throw error }
        descriptor = current
    }
    deinit { Darwin.close(descriptor) }

    static func parts(_ path: String, absolute: Bool = false) throws -> [String] {
        guard !path.contains("\0"), absolute == path.hasPrefix("/") else { throw StorageSnapshotFailure.unsupportedAuthority }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." }) else { throw StorageSnapshotFailure.unsupportedAuthority }
        return parts
    }

    func parent(_ path: String, create: Bool = false) throws -> (Int32, String) {
        var parts = try Self.parts(path)
        let name = parts.removeLast()
        var current = dup(descriptor)
        guard current >= 0 else { throw StorageSnapshotFailure.io }
        do {
            for part in parts {
                if create, mkdirat(current, part, 0o700) != 0, errno != EEXIST { throw StorageSnapshotFailure.io }
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw StorageSnapshotFailure.io }
                if create, fsync(current) != 0 { Darwin.close(next); throw StorageSnapshotFailure.io }
                Darwin.close(current); current = next
            }
            return (current, name)
        } catch { Darwin.close(current); throw error }
    }

    func regularOrLinkExists(_ path: String) throws -> Bool {
        let parentFD: Int32, name: String
        do { (parentFD, name) = try parent(path) }
        catch { if errno == ENOENT { return false }; throw error }
        defer { Darwin.close(parentFD) }
        var info = stat()
        if fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return false }; throw StorageSnapshotFailure.io
        }
        guard [S_IFREG,S_IFLNK].contains(info.st_mode & S_IFMT) else { throw StorageSnapshotFailure.unsupportedAuthority }
        return true
    }

    func openRegular<T>(_ path: String, _ body: (Int32) throws -> T) throws -> T {
        let (directory, name) = try parent(path); defer { Darwin.close(directory) }
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
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
            var result = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = Darwin.read(file, &buffer, buffer.count)
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
            var digest = SHA256(), count: Int64 = 0, buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                try budget.check()
                let size = Darwin.read(file, &buffer, buffer.count)
                if size < 0, errno == EINTR { continue }
                guard size >= 0 else { throw StorageSnapshotFailure.io }
                if size == 0 { break }
                count += Int64(size)
                guard count <= budget.maximumBytes else { throw StorageSnapshotFailure.limit }
                digest.update(data: Data(buffer.prefix(size)))
            }
            return (Self.hex(digest.finalize()), count)
        }
    }

    func copy(_ path: String, to destination: StorageObjectFiles, expected: String?, budget: StorageSnapshotBudget) throws -> (String, Int64) {
        let target = "managed/" + path
        let (directory, name) = try destination.parent(target, create: true); defer { Darwin.close(directory) }
        let output = openat(directory, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw StorageSnapshotFailure.io }
        defer { Darwin.close(output) }
        let copied = try openRegular(path) { file -> (String, Int64) in
            var before = stat(); guard fstat(file, &before) == 0 else { throw StorageSnapshotFailure.io }
            var digest = SHA256(), total: Int64 = 0, buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                try budget.check()
                let size = Darwin.read(file, &buffer, buffer.count)
                if size < 0, errno == EINTR { continue }
                guard size >= 0 else { throw StorageSnapshotFailure.io }
                if size == 0 { break }
                total += Int64(size)
                guard total <= budget.maximumObjectBytes else { throw StorageSnapshotFailure.limit }
                digest.update(data: Data(buffer.prefix(size)))
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
        try Self.flush(output)
        guard fsync(directory) == 0 else { throw StorageSnapshotFailure.io }
        let verified = try destination.digest(target, budget: budget)
        guard verified == copied else { throw StorageSnapshotFailure.sourceChanged }
        return copied
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
        guard symlinkat(target, directory, name) == 0, fsync(directory) == 0 else { throw StorageSnapshotFailure.io }
    }
    func makeDirectory(_ name: String) throws -> StorageObjectFiles {
        _ = try Self.parts(name)
        guard !name.contains("/"), mkdirat(descriptor, name, 0o700) == 0, fsync(descriptor) == 0 else { throw StorageSnapshotFailure.io }
        return try StorageObjectFiles(root: root.appendingPathComponent(name, isDirectory: true))
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
        guard let entries = FileManager.default.enumerator(atPath: root.path) else { throw StorageSnapshotFailure.io }
        var files: Set<String> = []
        while let path = entries.nextObject() as? String {
            try budget.check()
            let (directory, name) = try parent(path); defer { Darwin.close(directory) }
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw StorageSnapshotFailure.io }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: break
            case S_IFREG: files.insert(path)
            // Captured links resolve to files. There are no link descendants to
            // skip; skipDescendants here can skip the next sibling link.
            case S_IFLNK: files.insert(path)
            default: throw StorageSnapshotFailure.unsupportedAuthority
            }
            guard files.count <= budget.maximumObjects + 3 else { throw StorageSnapshotFailure.limit }
        }
        return files
    }
    static func flush(_ file: Int32) throws {
        guard fsync(file) == 0, fcntl(file, F_FULLFSYNC) == 0 else { throw StorageSnapshotFailure.io }
    }
    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
    static func sha(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
}
