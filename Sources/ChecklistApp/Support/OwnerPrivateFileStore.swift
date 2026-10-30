import ChecklistIPC
import CryptoKit
import Foundation

/// The real cause of a private file failure. It keeps the errno for the error details,
/// and its text states the cause and the next step.
struct OwnerPrivateFileError: LocalizedError, Equatable {
    let operation: String
    let code: Int32

    var details: [String: Any] {
        ["errno": Int(code), "operation": operation, "cause": String(cString: strerror(code))]
    }
    var errorDescription: String? {
        "Checklist could not \(operation) its private recovery file: \(String(cString: strerror(code))) (errno \(code)). \(nextStep)"
    }
    private var nextStep: String {
        switch code {
        case ENOSPC, EDQUOT: return "Free some disk space, then try again."
        case EROFS: return "Make the disk that holds Checklist's app data writable, then try again."
        case EACCES, EPERM: return "Give your account access to Checklist's app data folder (Settings > Show app data in Finder), then try again."
        case ELOOP, ENOTDIR, EISDIR: return "Move the item named OwnerPrivate, or the file inside it, out of Checklist's app data folder (Settings > Show app data in Finder), then try again."
        default: return "Try again. If it fails again, quit and reopen Checklist."
        }
    }
}

/// Owner-local records that must survive a crash: one file per key in a private folder of
/// the instance. The folder is mode 0700 and each file is mode 0600. Every path step in the
/// folder uses no-follow descriptor calls. A save replaces the file atomically, flushes the
/// file and the folder, and reads the bytes back. A stale, unreadable or unsafe earlier file
/// never blocks a save, because rename replaces the entry itself.
/// The folder is not part of the store inventory, backups, exports or portable commands.
struct OwnerPrivateFileStore: Sendable {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let kind: String
        let key: String
        let value: String
    }

    static func directory(for instance: ChecklistInstance) -> URL {
        instance.ownerDataRoot.appendingPathComponent("OwnerPrivate", isDirectory: true)
    }
    static let pendingCommandKind = "pending_command"
    static let claimKind = "claim"
    private static let maximumBytes = 64 * 1024 * 1024

    let directory: URL
    let kind: String

    init(directory: URL, kind: String) {
        precondition(kind.range(of: "^[a-z_]{1,30}$", options: .regularExpression) != nil)
        self.directory = directory
        self.kind = kind
    }

    func fileName(_ key: String) -> String {
        kind + "-" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    func save(_ value: String, key: String) throws {
        let bytes: Data
        do { bytes = try JSONEncoder().encode(Envelope(schemaVersion: 1, kind: kind, key: key, value: value)) }
        catch { throw OwnerPrivateFileError(operation: "encode", code: EINVAL) }
        let folder = try openFolder(create: true)!
        defer { close(folder) }
        let name = fileName(key)
        let temporary = "." + name + "." + UUID().uuidString.lowercased() + ".tmp"
        do {
            let file = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard file >= 0 else { throw OwnerPrivateFileError(operation: "create", code: errno) }
            do {
                defer { close(file) }
                guard fchmod(file, 0o600) == 0 else { throw OwnerPrivateFileError(operation: "protect", code: errno) }
                try writeAll(bytes, to: file)
                guard fsync(file) == 0 else { throw OwnerPrivateFileError(operation: "flush", code: errno) }
            }
            guard renameat(folder, temporary, folder, name) == 0 else { throw OwnerPrivateFileError(operation: "replace", code: errno) }
            guard fsync(folder) == 0 else { throw OwnerPrivateFileError(operation: "flush", code: errno) }
            guard try read(key, folder: folder) == value else { throw OwnerPrivateFileError(operation: "verify", code: EIO) }
        } catch {
            unlinkat(folder, temporary, 0)
            throw error
        }
        removeLeftoverTemporaries(of: name, folder: folder)
    }

    /// Absent returns nil. A file that exists but cannot be trusted or read throws, so a
    /// caller can tell the two states apart.
    func read(_ key: String) throws -> String? {
        guard let folder = try openFolder(create: false) else { return nil }
        defer { close(folder) }
        return try read(key, folder: folder)
    }

    /// Removes the record. A record that stays after a failed removal only keeps a safe offer.
    func remove(_ key: String) {
        guard let folder = try? openFolder(create: false) else { return }
        defer { close(folder) }
        let name = fileName(key)
        unlinkat(folder, name, 0)
        removeLeftoverTemporaries(of: name, folder: folder)
        fsync(folder)
    }

    private func read(_ key: String, folder: Int32) throws -> String? {
        let file = openat(folder, fileName(key), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0 {
            if errno == ENOENT { return nil }
            throw OwnerPrivateFileError(operation: "open", code: errno)
        }
        defer { close(file) }
        var status = stat()
        guard fstat(file, &status) == 0 else { throw OwnerPrivateFileError(operation: "inspect", code: errno) }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_uid == geteuid(), status.st_mode & 0o077 == 0 else {
            throw OwnerPrivateFileError(operation: "trust", code: EPERM)
        }
        guard status.st_size <= Self.maximumBytes else { throw OwnerPrivateFileError(operation: "read", code: EFBIG) }
        var bytes = Data(capacity: Int(status.st_size))
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(file, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw OwnerPrivateFileError(operation: "read", code: errno)
            }
            if count == 0 { break }
            bytes.append(contentsOf: chunk[0..<count])
            guard bytes.count <= Self.maximumBytes else { throw OwnerPrivateFileError(operation: "read", code: EFBIG) }
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: bytes), envelope.schemaVersion == 1,
              envelope.kind == kind, envelope.key.utf8.elementsEqual(key.utf8) else {
            throw OwnerPrivateFileError(operation: "decode", code: EILSEQ)
        }
        return envelope.value
    }

    private func openFolder(create: Bool) throws -> Int32? {
        if create {
            do { try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true) }
            catch { throw OwnerPrivateFileError(operation: "create", code: Self.posixCode(error)) }
            if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw OwnerPrivateFileError(operation: "create", code: errno) }
        }
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if folder < 0 {
            if !create, errno == ENOENT { return nil }
            throw OwnerPrivateFileError(operation: "open", code: errno)
        }
        do {
            var status = stat()
            guard fstat(folder, &status) == 0 else { throw OwnerPrivateFileError(operation: "inspect", code: errno) }
            guard status.st_uid == geteuid() else { throw OwnerPrivateFileError(operation: "trust", code: EPERM) }
            if status.st_mode & 0o777 != 0o700, fchmod(folder, 0o700) != 0 { throw OwnerPrivateFileError(operation: "protect", code: errno) }
        } catch {
            close(folder)
            throw error
        }
        return folder
    }

    private func writeAll(_ bytes: Data, to file: Int32) throws {
        try bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let count = write(file, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw OwnerPrivateFileError(operation: "write", code: errno)
                }
                offset += count
            }
        }
    }

    /// A crash can leave a temporary copy of a record behind. Only this key's copies match.
    private func removeLeftoverTemporaries(of name: String, folder: Int32) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for entry in names where entry.hasPrefix("." + name + ".") && entry.hasSuffix(".tmp") { unlinkat(folder, entry, 0) }
    }

    private static func posixCode(_ error: Error) -> Int32 {
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain { return Int32(failure.code) }
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain { return Int32(underlying.code) }
        return EIO
    }
}
