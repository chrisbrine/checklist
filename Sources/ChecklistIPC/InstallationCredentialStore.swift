import CryptoKit
import Darwin
import Foundation

/// Agent installation credentials of one instance (CL-374): one file per installation in
/// `OwnerPrivate/` under that instance's data root. The folder is mode 0700 and each file is
/// mode 0600. Every path step in the folder uses no-follow descriptor calls. A save replaces
/// the file atomically, flushes the file and the folder, and reads the value back.
///
/// Why a file and not the database: database content goes into backups, restores and copied
/// test slots. A credential must not travel with them. Backups list only record-owned files,
/// and the slot seed leaves `OwnerPrivate/` out. Each record also names its instance and data
/// root, so a copied file is refused.
///
/// Protection: any program under the same Mac account can read these files. The owner accepted
/// this on 30 Oct 2026 (request 8e06c68a, response db9f7d73). A credential alone grants nothing:
/// the service still checks the caller's code signature and native session.
public struct InstallationCredentialStore: Sendable {
    public typealias LegacyRead = @Sendable (String) throws -> String?

    private enum State: String, Codable {
        case credential
        /// A removed credential stays removed: the old Keychain item must not bring it back.
        case removed
        /// The one migration read found no old item, so no later read calls Keychain.
        case noLegacyItem = "no_legacy_item"
    }
    private struct Record: Codable {
        let schemaVersion: Int
        let kind: String
        let binding: String
        let installation: String
        let state: State
        let value: String?
    }
    private static let kind = "installation_credential"
    private static let maximumBytes = 64 * 1024

    public let directory: URL
    private let binding: String
    private let legacyRead: LegacyRead?

    public static func directory(root: URL) -> URL { root.appendingPathComponent("OwnerPrivate", isDirectory: true) }
    private static func canonical(_ url: URL) -> String { url.standardizedFileURL.path }

    /// The exact instance and data root that a record belongs to.
    public init(root: URL, instance: ChecklistInstance, legacyRead: LegacyRead?) {
        directory = Self.directory(root: root)
        binding = instance.bundleIdentifier + "|" + Self.canonical(root)
        self.legacyRead = legacyRead
    }

    /// The one migration read applies only to the live instance's fixed data root, from a real
    /// bundle. A test slot, a `CHECKLIST_DATA_ROOT` override, a temporary test root and an
    /// unbundled test executable never reach Keychain.
    public static func usesLegacyMigration(root: URL, instance: ChecklistInstance) -> Bool {
        instance.slot == nil && instance.bundleURL != nil
            && canonical(root) == canonical(instance.root) && canonical(root) == canonical(instance.ownerDataRoot)
    }

    public static func production(root: URL = ChecklistPaths.root, instance: ChecklistInstance = .current) -> InstallationCredentialStore {
        let service = instance.keychainService
        guard usesLegacyMigration(root: root, instance: instance) else {
            return InstallationCredentialStore(root: root, instance: instance, legacyRead: nil)
        }
        return InstallationCredentialStore(root: root, instance: instance, legacyRead: { account in
            try LegacyKeychainCredentialMigration.read(account: account, service: service)
        })
    }

    func fileName(_ installation: String) -> String {
        Self.kind + "-" + SHA256.hash(data: Data(installation.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    /// The file decides when it exists. An untrusted or foreign file throws and never falls
    /// back to Keychain. A failed old-store read throws its plain error and leaves no record,
    /// so a later read can retry it. A failed save during migration does not fail the read:
    /// a sandboxed CLI can read this folder but not write it, and the value is still correct.
    public func read(_ installation: String) throws -> String? {
        if let record = try load(installation) { return record.state == .credential ? record.value : nil }
        guard let legacyRead else { return nil }
        guard let value = try legacyRead(installation) else {
            _ = try? save(record(installation, .noLegacyItem, nil), replacing: false)
            return nil
        }
        // Another process can rotate this credential during the read. Its value wins.
        if (try? save(record(installation, .credential, value), replacing: false)) == false,
           let current = try load(installation) {
            return current.state == .credential ? current.value : nil
        }
        return value
    }

    public func write(_ installation: String, _ value: String) throws {
        _ = try save(record(installation, .credential, value), replacing: true)
    }

    public func removeChecked(_ installation: String) throws {
        _ = try save(record(installation, .removed, nil), replacing: true)
    }

    public func remove(_ installation: String) { try? removeChecked(installation) }

    private func record(_ installation: String, _ state: State, _ value: String?) -> Record {
        Record(schemaVersion: 1, kind: Self.kind, binding: binding, installation: installation, state: state, value: value)
    }

    private func load(_ installation: String) throws -> Record? {
        guard let folder = try openFolder(create: false) else { return nil }
        defer { close(folder) }
        return try load(installation, folder: folder)
    }

    private func load(_ installation: String, folder: Int32) throws -> Record? {
        let file = openat(folder, fileName(installation), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0 {
            if errno == ENOENT { return nil }
            throw failure("open", errno)
        }
        defer { close(file) }
        var status = stat()
        guard fstat(file, &status) == 0 else { throw failure("inspect", errno) }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_uid == geteuid(), status.st_mode & 0o077 == 0 else { throw failure("trust", EPERM) }
        guard status.st_size <= Self.maximumBytes else { throw failure("read", EFBIG) }
        var bytes = Data(capacity: Int(status.st_size))
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(file, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("read", errno)
            }
            if count == 0 { break }
            bytes.append(contentsOf: chunk[0..<count])
            guard bytes.count <= Self.maximumBytes else { throw failure("read", EFBIG) }
        }
        guard let record = try? JSONDecoder().decode(Record.self, from: bytes), record.schemaVersion == 1, record.kind == Self.kind,
              record.state != .credential || record.value != nil else { throw failure("decode", EILSEQ) }
        guard record.binding.utf8.elementsEqual(binding.utf8), record.installation.utf8.elementsEqual(installation.utf8) else {
            throw ChecklistError("CREDENTIAL_INSTANCE_MISMATCH", "This saved agent credential belongs to another Checklist instance or connection, so Checklist refused it. Connect again from a new conversation, or select Allow again on the ticket.")
        }
        return record
    }

    /// Returns false only when `replacing` is false and a record already exists.
    private func save(_ record: Record, replacing: Bool) throws -> Bool {
        let bytes: Data
        do { bytes = try JSONEncoder().encode(record) } catch { throw failure("encode", EINVAL) }
        guard let folder = try openFolder(create: true) else { throw failure("open", ENOENT) }
        defer { close(folder) }
        let name = fileName(record.installation)
        let temporary = "." + name + "." + UUID().uuidString.lowercased() + ".tmp"
        do {
            let file = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard file >= 0 else { throw failure("create", errno) }
            do {
                defer { close(file) }
                guard fchmod(file, 0o600) == 0 else { throw failure("protect", errno) }
                try writeAll(bytes, to: file)
                guard fsync(file) == 0 else { throw failure("flush", errno) }
            }
            if replacing {
                guard renameat(folder, temporary, folder, name) == 0 else { throw failure("replace", errno) }
            } else if renameatx_np(folder, temporary, folder, name, UInt32(RENAME_EXCL)) != 0 {
                if errno == EEXIST { unlinkat(folder, temporary, 0); return false }
                throw failure("replace", errno)
            }
            guard fsync(folder) == 0 else { throw failure("flush", errno) }
            let saved = try load(record.installation, folder: folder)
            // A migration save can lose only to a later rotation, which wins.
            if replacing, saved?.state != record.state || saved?.value != record.value { throw failure("verify", EIO) }
        } catch {
            unlinkat(folder, temporary, 0)
            throw error
        }
        removeLeftoverTemporaries(of: name, folder: folder)
        return true
    }

    private func openFolder(create: Bool) throws -> Int32? {
        if create {
            do { try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw failure("create", Self.posixCode(error)) }
            if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw failure("create", errno) }
        }
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if folder < 0 {
            if !create, errno == ENOENT { return nil }
            throw failure("open", errno)
        }
        do {
            var status = stat()
            guard fstat(folder, &status) == 0 else { throw failure("inspect", errno) }
            guard status.st_uid == geteuid() else { throw failure("trust", EPERM) }
            if status.st_mode & 0o777 != 0o700, fchmod(folder, 0o700) != 0 { throw failure("protect", errno) }
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
                let count = Darwin.write(file, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw failure("write", errno)
                }
                offset += count
            }
        }
    }

    /// A crash can leave a temporary copy of a record behind. Only this record's copies match.
    private func removeLeftoverTemporaries(of name: String, folder: Int32) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for entry in names where entry.hasPrefix("." + name + ".") && entry.hasSuffix(".tmp") { unlinkat(folder, entry, 0) }
    }

    private func failure(_ operation: String, _ code: Int32) -> ChecklistError {
        ChecklistError("CREDENTIAL_STORE_UNAVAILABLE", "Checklist could not \(operation) a saved agent credential: \(String(cString: strerror(code))) (errno \(code)). Fix or move the item in the OwnerPrivate folder of Checklist's app data, then connect again from a new conversation or select Allow again on the ticket.",
                       details: ["operation": operation, "errno": Int(code)])
    }

    private static func posixCode(_ error: Error) -> Int32 {
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain { return Int32(failure.code) }
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain { return Int32(underlying.code) }
        return EIO
    }
}
