import Foundation
import XCTest
import Darwin
import CryptoKit
import GRDB
import SQLite3
import ChecklistProviders
@testable import ChecklistCore

/// Unit/integration fixtures use a private copy of an empty current-schema store.
/// Storage bootstrap, migration, backup and crash tests keep CommandRouter directly.
private final class TestStoreBundleMarker: NSObject {}

public enum TestStore {
    /// Immutable filesystem preparation (for example a tiny committed Git
    /// repository). Every test receives private inodes, including Git metadata.
    public final class DirectoryTemplate: @unchecked Sendable {
        private let source: Result<URL, Error>
        public init(name: String, prepare: @escaping (URL) throws -> Void) {
            source = Result {
                try TestStore.publishTemplate(name: "directory-" + name) { pending in
                    try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
                    try prepare(pending)
                }
            }
        }
        public func copy(to destination: URL) throws {
            try TestStore.clone(source.get(), to: destination)
        }
    }
    /// An immutable, populated unit fixture. Its workspace is always a sibling
    /// of the template store; copies keep that separation and private bytes.
    public final class Template: @unchecked Sendable {
        fileprivate let source: Result<URL, Error>
        public init(name: String, prepare: @escaping (CommandRouter, URL) throws -> Void) {
            source = Result {
                try TestStore.publishTemplate(name: name) { pending in
                    let workspace = pending.appendingPathComponent("workspace", isDirectory: true)
                    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                    // Populated phases start from the same current-schema seed
                    // as unit fixtures. The empty seed alone pays fresh migration;
                    // each phase still opens through production admission/recovery.
                    let router = try TestFixtureTimings.measure("template.open") { try TestStore.router(root: pending.appendingPathComponent("store"), durable: false) }
                    do {
                        try router.dbQueue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA synchronous=NORMAL") }
                        try TestFixtureTimings.measure("template.prepare") { try prepare(router, workspace) }
                        try router.dbQueue.write {
                            try $0.execute(sql: "INSERT INTO metadata(key,value) VALUES (?,?)",
                                           arguments: [TestStore.workspaceKey, workspace.resolvingSymlinksInPath().path])
                        }
                        try TestFixtureTimings.measure("template.close") { try router.closeStore() }
                    } catch { try? router.closeStore(); throw error }
                }
            }
        }
    }
    private static let workspaceKey = "test-store-template-workspace"

    public static func router(root: URL, serviceLease: StorageServiceLease? = nil,
                              cliCommand: String = "/Applications/Checklist.app/Contents/MacOS/checklist",
                              providerPlugins: ProviderPluginRegistry = .bundled,
                              automaticBackupRetentionTrashRoot: URL? = nil,
                              durable: Bool = ProcessInfo.processInfo.environment["CHECKLIST_QUALIFICATION"] == "1",
                              template: Template? = nil, workspace: URL? = nil,
                              trackEpicReferences: Bool = false,
                              sourceGitMemo: Bool = ProcessInfo.processInfo.environment["CHECKLIST_QUALIFICATION"] != "1") throws -> CommandRouter {
        SourceGitFixtureMemo.configure(enabled: sourceGitMemo)
        let anchored = root.resolvingSymlinksInPath()
        // Reopen existing fixtures through production admission; never replace data.
        var fresh: CommandRouter.FixtureFreshStore?
        if !FileManager.default.fileExists(atPath: anchored.appendingPathComponent("checklist.sqlite").path),
           !FileManager.default.fileExists(atPath: anchored.appendingPathComponent(StoreIdentityReceipt.fileName).path) {
            try StoreDirectory(root: anchored).requireFreshScaffoldingOnly()
            let seeded = try TestFixtureTimings.measure("store.seed") { try seed(anchored, template: template, workspace: workspace) }
            // CL-363: a disposable unit fixture states what it just cloned, so the startup leaves
            // out the preflight and, for a clone with no row and no managed file, the sweeps and
            // pruning statements that can find nothing. Durable and qualification fixtures, a
            // reopened store and every direct CommandRouter keep the complete production startup.
            if !durable { fresh = .init(identity: seeded.identity, empty: seeded.empty) }
        }
        let router = try TestFixtureTimings.measure("store.open") { try TestFixtureTimings.startup { try CommandRouter(root: root, serviceLease: serviceLease, cliCommand: cliCommand, providerPlugins: providerPlugins, automaticBackupRetentionTrashRoot: automaticBackupRetentionTrashRoot, fixtureTrackEpicReferences: durable || trackEpicReferences || ProcessInfo.processInfo.environment["CHECKLIST_QUALIFICATION"] == "1", fixtureFreshStore: fresh) } }
        if !durable {
            ValidationCatalogFixture.configure(router)
            router.fixtureStoreRows = { db, sql, arguments in
                try Row.fetchAll(db.cachedStatement(sql: sql), arguments: arguments)
            }
            router.fixtureStoreStatement = { db, sql, arguments in
                try db.cachedStatement(sql: sql).execute(arguments: arguments)
            }
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

    /// `empty`: the clone of the database alone (no managed file or staging folder), with no row
    /// in `records`, `commands` or `cursors`, counted in the clone itself.
    private static func seed(_ root: URL, template: Template?, workspace: URL?) throws -> (identity: StoreIdentityReceipt, empty: Bool) {
        let source: URL
        if let template {
            guard let workspace else { throw CocoaError(.fileNoSuchFile) }
            let prepared = try template.source.get()
            source = prepared.appendingPathComponent("store")
            try clone(prepared.appendingPathComponent("workspace"), to: workspace)
            // Populated phases may already contain captured source, icons or
            // execution output as well as attachments. Copy private managed
            // bytes before startup admission/recovery observes their records.
            for family in ["objects", "icons", "source-captures", "source-executions", "source-build-cache"] {
                let path = source.appendingPathComponent(family)
                if FileManager.default.fileExists(atPath: path.path) {
                    try clone(path, to: root.appendingPathComponent(family))
                }
            }
        } else { source = try publishedTemplate.get() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let database = root.appendingPathComponent("checklist.sqlite")
        let original = source.appendingPathComponent("checklist.sqlite")
        try TestFixtureTimings.measure("seed.database-copy") { try clone(original, to: database) }
        let identity = StoreIdentityReceipt(format_version: 1, logical_store_id: UUID().uuidString.lowercased(),
                                          incarnation: UUID().uuidString.lowercased(), database_generation: 1,
                                          schema_revision: SchemaMigrations.currentSchema, state: "ready")
        let receipt = root.appendingPathComponent(StoreIdentityReceipt.fileName)
        if template == nil {
            // CL-363: the clone of the empty template needs four metadata rows only. SQLite writes
            // the same rows as the GRDB path below, without the setup of a GRDB connection.
            let empty = try TestFixtureTimings.measure("seed.identity-and-relocation") { try writeIdentity(identity, database: database) }
            try TestFixtureTimings.measure("seed.receipt-file") { try identity.encoded().write(to: receipt, options: .atomic) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
            return (identity, empty)
        }
        var configuration = Configuration()
        configuration.prepareDatabase {
            try SchemaMigrations.installStorageCollation($0)
            // Only disposable fixture seeding: the returned production router
            // reopens with production FULL; only unit fixtures then select NORMAL.
            try $0.execute(sql: "PRAGMA synchronous=OFF")
        }
        let queue = try TestFixtureTimings.measure("seed.sqlite-open") { try DatabaseQueue(path: database.path, configuration: configuration) }
        do {
            try TestFixtureTimings.measure("seed.identity-and-relocation") { try queue.write { db in
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
            }
            try TestFixtureTimings.measure("seed.sqlite-close") { try queue.close() }
        } catch { try? queue.close(); throw error }
        try TestFixtureTimings.measure("seed.receipt-file") { try identity.encoded().write(to: receipt, options: .atomic) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        return (identity, false)
    }

    /// The identity, incarnation and a new cursor seal key of one private clone, in one
    /// transaction with relaxed synchronization (disposable seed preparation only).
    /// Returns true when the clone has no row in `records`, `commands` or `cursors`.
    private static func writeIdentity(_ identity: StoreIdentityReceipt, database: URL) throws -> Bool {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let connection else {
            sqlite3_close(connection)
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_close(connection) }
        // The metadata key uses the storage collation. This is the comparison of
        // `SchemaMigrations.installStorageCollation`: raw bytes first, then the length.
        guard sqlite3_create_collation_v2(connection, SchemaMigrations.storageCollation, SQLITE_UTF8, nil, { _, an, ap, bn, bp in
            let n = min(an, bn)
            if n > 0, let ap, let bp {
                let order = memcmp(ap, bp, Int(n))
                if order != 0 { return order < 0 ? -1 : 1 }
            }
            return an == bn ? 0 : (an < bn ? -1 : 1)
        }, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        @discardableResult func run(_ sql: String, _ values: [String] = []) throws -> Int64? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            defer { sqlite3_finalize(statement) }
            for (index, value) in values.enumerated() {
                guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            }
            var first: Int64?
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                if first == nil { first = sqlite3_column_int64(statement, 0) }
                code = sqlite3_step(statement)
            }
            guard code == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
            return first
        }
        try run("PRAGMA synchronous=OFF")
        try run("BEGIN IMMEDIATE")
        do {
            try run("UPDATE metadata SET value=? WHERE key='incarnation'", [identity.incarnation])
            try run("UPDATE metadata SET value=? WHERE key='store_identity'", [String(decoding: try identity.encoded(), as: UTF8.self)])
            try run("DELETE FROM metadata WHERE key='cursor_seal_key'")
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
            try run("INSERT OR REPLACE INTO metadata(key,value) VALUES ('cursor_seal_key',?)", [key])
            let rows = try run("SELECT (SELECT COUNT(*) FROM records) + (SELECT COUNT(*) FROM commands) + (SELECT COUNT(*) FROM cursors)")
            try run("COMMIT")
            return rows == 0
        } catch { try? run("ROLLBACK"); throw error }
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
