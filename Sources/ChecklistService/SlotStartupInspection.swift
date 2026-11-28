import CryptoKit
import Darwin
import Foundation
import ChecklistCore
import ChecklistIPC

/// The launch configuration pins the receipt bytes. The service checks the original
/// data directory before preparation and verifies the observations at SQLite open.
struct SlotStartupInspection: Sendable {
    static let environmentKey = "CHECKLIST_SLOT_INSPECTION_SHA256"
    static let receiptName = "slot-start-inspection.json"
    static let storeNames = ["checklist.sqlite", "checklist.sqlite-wal", "checklist.sqlite-journal", "checklist.sqlite-shm"]
    private static let maximumBytes = 16 * 1024 * 1024
    private static let blockSize = 1024 * 1024
    // StoreDirectory, StorageServiceLease and ArchiveStorageGate create these.
    private static let storageLocks: Set<String> = ["checklist.bootstrap.lock", "service.lock", ".archive-storage.lock"]

    struct Refusal: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private struct StoreFile: Decodable, Sendable {
        let name: String
        let stamp: [String]?
        let sha256: String?
    }

    private struct PathObservation: Decodable, Sendable {
        let path: String
        let expected: [String]
    }

    private struct Paths: Decodable, Sendable {
        let named: [PathObservation]
        let canonical: [PathObservation]
        let directories: [PathObservation]
        let rootEntries: [String]?

        enum CodingKeys: String, CodingKey {
            case named, canonical, directories
            case rootEntries = "root_entries"
        }
    }

    private struct Receipt: Decodable {
        let format: Int
        let slot: Int
        let files: [StoreFile]
        let observations: Data
        let observationsSHA256: String

        enum CodingKeys: String, CodingKey {
            case format, slot, files, observations
            case observationsSHA256 = "observations_sha256"
        }
    }

    private let root: URL
    private let files: [StoreFile]
    private let paths: Paths

    var openingCheck: StoreOpeningCheck {
        StoreOpeningCheck { boundary in
            switch boundary {
            case .beforeOpen: try verifyBeforeOpeningStore(preparedRoot: true)
            case .readOnlyOpened: try verifyOpenedStore(writer: false)
            // SQLite can create or update its shared-memory index in read-only preflight.
            case .writerOpened: try verifyOpenedStore(writer: true)
            }
        }
    }

    func verifyOpenedStore(writer: Bool) throws {
        if !writer { try verifyPaths(preparedRoot: true) }
        try verifyStoreNames(includeSharedMemory: !writer)
    }

    static func load(instance: ChecklistInstance, environment: [String: String]) throws -> Self? {
        guard let slot = instance.slot else { return nil }
        let root = instance.root
        guard let expected = environment[environmentKey] else {
            let empty = Self(root: root, files: storeNames.map { StoreFile(name: $0, stamp: nil, sha256: nil) },
                             paths: Paths(named: [], canonical: [], directories: [], rootEntries: nil))
            do { try empty.verifyStoreNames() }
            catch { throw Refusal("An existing test store needs an inspection receipt. Stop and start its slot.") }
            return empty
        }
        let url = root.deletingLastPathComponent().appendingPathComponent(receiptName)
        let raw = try readReceipt(url)
        guard digest(raw) == expected else { throw Refusal("The slot inspection receipt differs from its launch configuration.") }
        let receipt = try JSONDecoder().decode(Receipt.self, from: raw)
        guard receipt.format == 1, receipt.slot == slot, receipt.files.map(\.name) == storeNames,
              receipt.files.first?.stamp != nil, digest(receipt.observations) == receipt.observationsSHA256 else {
            throw Refusal("Invalid slot inspection receipt.")
        }
        let paths = try JSONDecoder().decode(Paths.self, from: receipt.observations)
        guard paths.rootEntries != nil else { throw Refusal("Missing slot data directory membership.") }
        let inspection = Self(root: root, files: receipt.files, paths: paths)
        try inspection.verifyStoreNames()
        // The slot's own preparation will chmod the data directory and may
        // create its service lock. Verify its original stamp before either write.
        for observation in paths.directories where observation.path == root.path {
            guard try named(observation.path, full: true) == observation.expected else {
                throw Refusal("The inspected slot data directory changed.")
            }
        }
        return inspection
    }

    func verifyBeforeOpeningStore(preparedRoot: Bool = false) throws {
        for file in files where file.stamp != nil { try verifyBytes(file) }
        try verifyPaths(preparedRoot: preparedRoot)
        try verifyStoreNames()
    }

    private func verifyPaths(preparedRoot: Bool) throws {
        for observation in paths.canonical {
            let (path, expected) = (observation.path, observation.expected)
            try Self.requirePath(path)
            let actual = try ChecklistInstance.slotInspectionCanonicalPath(path, permitDenied: expected == ["denied"])
            // Swift String equality folds Unicode canonical equivalents. Path
            // observations also bind the exact byte spelling recorded in Python.
            guard actual.map({ Data($0.utf8) }) == expected.map({ Data($0.utf8) }) else {
                throw Refusal("A slot inspection path alias changed.")
            }
        }
        for observation in paths.named {
            let (path, expected) = (observation.path, observation.expected)
            try Self.requirePath(path)
            let actual = try Self.named(path, full: false)
            // The service prepares its own data root with mode 0700.
            let expectedAfterPreparation = preparedRoot && path == root.path && expected.count == 3
                ? Array(expected.prefix(2)) + [String(S_IFDIR | 0o700)] : expected
            guard actual == expectedAfterPreparation else { throw Refusal("A slot inspection path changed.") }
        }
        for observation in paths.directories {
            let (path, expected) = (observation.path, observation.expected)
            try Self.requirePath(path)
            let actual = try Self.named(path, full: true)
            let matches = preparedRoot && path == root.path
                ? Array(actual.prefix(3)) == Array(expected.prefix(2)) + [String(S_IFDIR | 0o700)] : actual == expected
            guard (path == root.path || path.hasPrefix(root.path + "/")), matches else {
                throw Refusal("An inspected slot directory changed.")
            }
        }
        if let expected = paths.rootEntries {
            let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { !Self.storageLocks.contains($0) }
            guard Set(entries.map { Data($0.utf8) }) == Set(expected.map { Data($0.utf8) }) else {
                throw Refusal("The inspected slot data directory entries changed.")
            }
        }
    }

    /// Check named identities again after hashing and observing paths.
    private func verifyStoreNames(includeSharedMemory: Bool = true) throws {
        for file in files where includeSharedMemory || file.name != "checklist.sqlite-shm" {
            let expected = file.stamp ?? ["missing"]
            guard (file.stamp == nil) == (file.sha256 == nil),
                  try Self.named(root.appendingPathComponent(file.name).path, full: true) == expected else {
                throw Refusal("The inspected slot database, WAL or SQLite companion changed.")
            }
        }
    }

    private func verifyBytes(_ file: StoreFile) throws {
        let url = root.appendingPathComponent(file.name)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Refusal("Cannot read an inspected slot store file.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              Self.stamp(before) == file.stamp else { throw Refusal("An inspected slot store file changed before hashing.") }
        var hash = SHA256()
        while let block = try handle.read(upToCount: Self.blockSize), !block.isEmpty { hash.update(data: block) }
        var after = stat()
        guard fstat(descriptor, &after) == 0, Self.stamp(after) == file.stamp,
              Self.hex(hash.finalize()) == file.sha256 else {
            throw Refusal("An inspected slot store file changed or its SHA-256 differs.")
        }
    }

    private static func readReceipt(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Refusal("Cannot read the slot inspection receipt.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              info.st_size > 0, info.st_size <= maximumBytes,
              let bytes = try handle.read(upToCount: maximumBytes + 1), bytes.count == info.st_size else {
            throw Refusal("The slot inspection receipt is not a bounded private file.")
        }
        return bytes
    }

    private static func requirePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw Refusal("A slot inspection observation has an invalid path.")
        }
    }

    private static func named(_ path: String, full: Bool) throws -> [String] {
        var info = stat()
        if lstat(path, &info) == 0 {
            if full { return stamp(info) }
            let identity = [String(info.st_dev), String(info.st_ino), String(info.st_mode)]
            return info.st_mode & S_IFMT == S_IFLNK ? identity + [nanos(info.st_ctimespec)] : identity
        }
        switch errno {
        case ENOENT, ENOTDIR: return ["missing"]
        case EACCES, EPERM: return ["denied"]
        default: throw Refusal("Cannot verify a slot inspection path.")
        }
    }

    private static func stamp(_ info: stat) -> [String] {
        [String(info.st_dev), String(info.st_ino), String(info.st_mode), String(info.st_size),
         nanos(info.st_mtimespec), nanos(info.st_ctimespec)]
    }

    private static func nanos(_ time: timespec) -> String {
        String(Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec))
    }

    private static func digest(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    private static func hex(_ hash: SHA256Digest) -> String { hash.map { String(format: "%02x", $0) }.joined() }
}
