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
    /// An immutable, populated unit fixture. Its workspace is always a sibling
    /// of the template store; copies keep that separation and private bytes.
    public final class Template: @unchecked Sendable {
        fileprivate let source: Result<URL, Error>
        public init(name: String, prepare: @escaping (CommandRouter, URL) throws -> Void) {
            source = Result {
                try TestStore.publishTemplate(name: name) { pending in
                    let workspace = pending.appendingPathComponent("workspace", isDirectory: true)
                    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                    let router = try CommandRouter(root: pending.appendingPathComponent("store"))
                    do {
                        try router.dbQueue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA synchronous=NORMAL") }
                        try prepare(router, workspace)
                        try router.dbQueue.write {
                            try $0.execute(sql: "INSERT INTO metadata(key,value) VALUES (?,?)",
                                           arguments: [TestStore.workspaceKey, workspace.resolvingSymlinksInPath().path])
                        }
                        try router.closeStore()
                    } catch { try? router.closeStore(); throw error }
                }
            }
        }
    }
    private static let workspaceKey = "test-store-template-workspace"

    public static func router(root: URL, serviceLease: StorageServiceLease? = nil,
                              cliCommand: String = "/Applications/Checklist.app/Contents/MacOS/checklist",
                              providerPlugins: ProviderPluginRegistry = .bundled,
                              durable: Bool = ProcessInfo.processInfo.environment["CHECKLIST_QUALIFICATION"] == "1",
                              template: Template? = nil, workspace: URL? = nil) throws -> CommandRouter {
        let anchored = root.resolvingSymlinksInPath()
        // Reopen existing fixtures through production admission; never replace data.
        if !FileManager.default.fileExists(atPath: anchored.appendingPathComponent("checklist.sqlite").path),
           !FileManager.default.fileExists(atPath: anchored.appendingPathComponent(StoreIdentityReceipt.fileName).path) {
            try StoreDirectory(root: anchored).requireFreshScaffoldingOnly()
            try seed(anchored, template: template, workspace: workspace)
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
    private static func publishTemplate(name: String, prepare: (URL) throws -> Void) throws -> URL {
        guard let executable = Bundle(for: TestStoreBundleMarker.self).executableURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        guard let modified = attributes[.modificationDate] as? Date, let size = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        let key = "\(executable.path):\(modified.timeIntervalSince1970):\(size):\(name)"
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
        try prepare(pending) // Close/checkpoint before publishing copyable database bytes.
        try FileManager.default.moveItem(at: pending, to: ready)
        return ready
    }

    // The loaded test image and its environment are fixed for this process.
    // Swift's lazy static initialization also shares publication across local
    // fixture threads; independent workers still take the publication file lock.
    private static let publishedTemplate = Result {
        try publishTemplate(name: "empty") { pending in
            let router = try CommandRouter(root: pending)
            try router.closeStore()
        }
    }

    private static func clone(_ source: URL, to destination: URL) throws {
        let kind = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
        if kind.isDirectory == true && kind.isSymbolicLink != true {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try clone(child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        } else if kind.isSymbolicLink == true {
            try FileManager.default.copyItem(at: source, to: destination)
        } else if kind.isRegularFile == true {
            if clonefile(source.path, destination.path, 0) != 0 {
                guard [ENOTSUP, EXDEV, ENOSYS, EINVAL].contains(errno) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                try FileManager.default.copyItem(at: source, to: destination)
            }
        } else { throw CocoaError(.fileReadUnsupportedScheme) }
    }

    private static func seed(_ root: URL, template: Template?, workspace: URL?) throws {
        let source: URL
        if let template {
            guard let workspace else { throw CocoaError(.fileNoSuchFile) }
            let prepared = try template.source.get()
            source = prepared.appendingPathComponent("store")
            try clone(prepared.appendingPathComponent("workspace"), to: workspace)
            try clone(source.appendingPathComponent("objects"), to: root.appendingPathComponent("objects"))
        } else { source = try publishedTemplate.get() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let database = root.appendingPathComponent("checklist.sqlite")
        let original = source.appendingPathComponent("checklist.sqlite")
        try clone(original, to: database)
        let identity = StoreIdentityReceipt(format_version: 1, logical_store_id: UUID().uuidString.lowercased(),
                                          incarnation: UUID().uuidString.lowercased(), database_generation: 1,
                                          schema_revision: SchemaMigrations.currentSchema, state: "ready")
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
                if template != nil, let workspace {
                    let oldWorkspace = try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key=?", arguments: [workspaceKey]) ?? ""
                    let oldIncarnation = try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='incarnation'")
                    guard !oldWorkspace.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    // Relocate only canonical workspace authority. Descriptions,
                    // evidence and command/event history remain literal source bytes.
                    for row in try Row.fetchAll(db, sql: "SELECT id,type,data FROM records WHERE type IN ('project','storage_job')") {
                        var value = jsonObject(row["data"])
                        let type: String = row["type"]
                        if type == "project", let path = value["root_path"] as? String,
                           path == oldWorkspace || path.hasPrefix(oldWorkspace + "/") {
                            value["root_path"] = workspace.resolvingSymlinksInPath().path + path.dropFirst(oldWorkspace.count)
                        }
                        if type == "storage_job", value["incarnation"] as? String == oldIncarnation {
                            value["incarnation"] = identity.incarnation
                        }
                        try db.execute(sql: "UPDATE records SET data=? WHERE id=?", arguments: [try jsonString(value), row["id"] as String])
                    }
                    try db.execute(sql: "DELETE FROM metadata WHERE key=?", arguments: [workspaceKey])
                }
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
