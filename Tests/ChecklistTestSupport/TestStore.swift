import Foundation
import XCTest
import Darwin
import CryptoKit
import GRDB
import ChecklistProviders
@testable import ChecklistCore

/// Unit/integration fixtures use a private copy of an empty current-schema store.
/// Storage bootstrap, migration, backup and crash tests keep CommandRouter directly.
private final class TestStoreBundleMarker: NSObject {}

public enum TestStore {
    public static func router(root: URL, serviceLease: StorageServiceLease? = nil,
                              cliCommand: String = "/Applications/Checklist.app/Contents/MacOS/checklist",
                              providerPlugins: ProviderPluginRegistry = .bundled,
                              durable: Bool = ProcessInfo.processInfo.environment["CHECKLIST_QUALIFICATION"] == "1") throws -> CommandRouter {
        let anchored = root.resolvingSymlinksInPath()
        // Reopen existing fixtures through production admission; never replace data.
        if !FileManager.default.fileExists(atPath: anchored.appendingPathComponent("checklist.sqlite").path),
           !FileManager.default.fileExists(atPath: anchored.appendingPathComponent(StoreIdentityReceipt.fileName).path) {
            try StoreDirectory(root: anchored).requireFreshScaffoldingOnly()
            try seed(anchored)
        }
        let router = try CommandRouter(root: root, serviceLease: serviceLease, cliCommand: cliCommand, providerPlugins: providerPlugins)
        if !durable {
            // Disposable unit fixtures need transaction/reopen semantics, not a
            // power-loss durability barrier on every command. Qualification and
            // direct CommandRouter storage/crash fixtures retain production FULL.
            try router.dbQueue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA synchronous=NORMAL") }
        }
        return router
    }

    private static var templateRoot: URL {
        if let path = ProcessInfo.processInfo.environment["CHECKLIST_TEST_TEMPLATE_ROOT"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        var path = Bundle(for: TestStoreBundleMarker.self).bundleURL.standardizedFileURL
        while path.path != "/" {
            if path.lastPathComponent == ".build" { return path.appendingPathComponent("test-store-templates") }
            path.deleteLastPathComponent()
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("checklist-test-templates-\(getuid())")
    }

    /// The linked test bundle identity avoids reusing a seed after a rebuild.
    /// A single lock protects template publication across SwiftPM's test processes;
    /// no test writes a published template, and every destination is private.
    private static func template() throws -> URL {
        guard let executable = Bundle(for: TestStoreBundleMarker.self).executableURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        guard let modified = attributes[.modificationDate] as? Date, let size = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        let key = "\(executable.path):\(modified.timeIntervalSince1970):\(size)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let cache = templateRoot.appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = Darwin.open(cache.appendingPathComponent("template.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(lock, LOCK_UN) }
        let ready = cache.appendingPathComponent("ready", isDirectory: true)
        if FileManager.default.fileExists(atPath: ready.path) { return ready }
        let pending = cache.appendingPathComponent("pending-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: pending) }
        let router = try CommandRouter(root: pending)
        try router.closeStore() // Close/checkpoint before publishing copyable database bytes.
        try FileManager.default.moveItem(at: pending, to: ready)
        return ready
    }

    // The loaded test image and its environment are fixed for this process.
    // Swift's lazy static initialization also shares publication across local
    // fixture threads; independent workers still take the publication file lock.
    private static let publishedTemplate = Result { try template() }

    private static func seed(_ root: URL) throws {
        let source = try publishedTemplate.get()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let database = root.appendingPathComponent("checklist.sqlite")
        let original = source.appendingPathComponent("checklist.sqlite")
        if clonefile(original.path, database.path, 0) != 0 {
            guard [ENOTSUP, EXDEV, ENOSYS, EINVAL].contains(errno) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try FileManager.default.copyItem(at: original, to: database)
        }
        let identity = StoreIdentityReceipt(format_version: 1, logical_store_id: UUID().uuidString.lowercased(),
                                          incarnation: UUID().uuidString.lowercased(), database_generation: 1,
                                          schema_revision: 3, state: "ready")
        var configuration = Configuration()
        configuration.prepareDatabase {
            try SchemaMigrations.installStorageCollation($0)
            // Only disposable fixture seeding: the returned production router
            // reopens with production FULL; only unit fixtures then select NORMAL.
            try $0.execute(sql: "PRAGMA synchronous=OFF")
        }
        let queue = try DatabaseQueue(path: database.path, configuration: configuration)
        do {
            try queue.write { db in
                try db.execute(sql: "UPDATE metadata SET value=? WHERE key='incarnation'", arguments: [identity.incarnation])
                try db.execute(sql: "UPDATE metadata SET value=? WHERE key='store_identity'", arguments: [String(decoding: try identity.encoded(), as: UTF8.self)])
                try db.execute(sql: "DELETE FROM metadata WHERE key='cursor_seal_key'")
                // Give this clone a fresh key during private seed preparation,
                // avoiding a durable metadata write on the production reopen.
                _ = try SealedCursor.storeKey(db)
            }
            try queue.close()
        } catch { try? queue.close(); throw error }
        let receipt = root.appendingPathComponent(StoreIdentityReceipt.fileName)
        try identity.encoded().write(to: receipt, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
    }
}

/// Scale, timing and soak coverage. Kept in its original test classes so all
/// fixture helpers and assertions remain identical to the ordinary test build.
public enum QualificationSuite {
    public static func requireEnabled() throws {
        guard ProcessInfo.processInfo.environment["CHECKLIST_QUALIFICATION"] == "1" else {
            throw XCTSkip("Qualification suite: run script/affected_tests.py --full --qualification")
        }
    }
}
