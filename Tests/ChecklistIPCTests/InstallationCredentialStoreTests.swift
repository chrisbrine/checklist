import Foundation
import XCTest
@testable import ChecklistIPC

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// CL-374. The old store is a counting fake in every case. No case calls Keychain.
final class InstallationCredentialStoreTests: XCTestCase {
    private final class FakeOldStore: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String]
        private var failure: Error?
        private(set) var reads = 0
        var onRead: (() -> Void)?
        init(_ values: [String: String] = [:], failure: Error? = nil) { self.values = values; self.failure = failure }
        func setFailure(_ error: Error?) { lock.withLock { failure = error } }
        func value(_ account: String) -> String? { lock.withLock { values[account] } }
        func read(_ account: String) throws -> String? {
            let (result, hook): (Result<String?, Error>, (() -> Void)?) = lock.withLock {
                reads += 1
                if let failure { return (.failure(failure), onRead) }
                return (.success(values[account]), onRead)
            }
            hook?()
            return try result.get()
        }
    }

    private var root: URL!
    private let installation = "auto-codex-synthetic"
    private let oldStoreFailure = ChecklistError("KEYCHAIN_UNAVAILABLE", "Cannot read the paired installation (-25308).")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("cl374-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    private func liveInstance() throws -> ChecklistInstance { try ChecklistInstance(home: root, environment: [:]) }
    private func store(_ old: FakeOldStore? = nil, root storeRoot: URL? = nil, instance: ChecklistInstance? = nil) throws -> InstallationCredentialStore {
        try InstallationCredentialStore(root: storeRoot ?? root, instance: instance ?? liveInstance(), legacyRead: old.map { old in { try old.read($0) } })
    }
    private func file(_ store: InstallationCredentialStore, _ name: String? = nil) -> URL {
        store.directory.appendingPathComponent(store.fileName(name ?? installation))
    }
    private func assertCode(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Any?) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual(($0 as? ChecklistError)?.code, code, file: file, line: line) }
    }
    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testCredentialOnlyInTheOldStoreMigratesOnceAndStaysInTheOldStore() throws {
        let old = FakeOldStore([installation: "old-token"]), store = try store(old)
        XCTAssertEqual(try store.read(installation), "old-token")
        XCTAssertEqual(try store.read(installation), "old-token")
        XCTAssertEqual(try store.read(installation), "old-token")
        XCTAssertEqual(old.reads, 1, "The old store is read once")
        XCTAssertEqual(old.value(installation), "old-token", "A rollback still finds the old item")
        XCTAssertEqual(try mode(file(store)), 0o600)
        XCTAssertEqual(try mode(store.directory), 0o700)
    }

    func testBothStoresPresentUsesTheFileAndNeverReadsTheOldStore() throws {
        let old = FakeOldStore([installation: "old-token"]), store = try store(old)
        try store.write(installation, "file-token")
        XCTAssertEqual(try store.read(installation), "file-token")
        XCTAssertEqual(old.reads, 0)
        XCTAssertEqual(old.value(installation), "old-token", "A write goes to the file only")
    }

    func testNeitherStorePresentReturnsNilAndChecksTheOldStoreOnce() throws {
        let old = FakeOldStore(), store = try store(old)
        XCTAssertNil(try store.read(installation))
        XCTAssertNil(try store.read(installation))
        XCTAssertEqual(old.reads, 1)
        try store.write(installation, "new-token")
        XCTAssertEqual(try store.read(installation), "new-token")
    }

    func testOldStoreFailureGivesThePlainErrorLeavesNoRecordAndCanRecover() throws {
        let old = FakeOldStore([installation: "old-token"], failure: oldStoreFailure), store = try store(old)
        assertCode("KEYCHAIN_UNAVAILABLE") { try store.read(installation) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(store).path), "A failed read must not look like a migrated credential")
        assertCode("KEYCHAIN_UNAVAILABLE") { try store.read(installation) }
        old.setFailure(nil)
        XCTAssertEqual(try store.read(installation), "old-token")
        XCTAssertEqual(old.reads, 3)
    }

    func testRemovalNeverBringsBackTheOldItem() throws {
        let old = FakeOldStore([installation: "old-token"]), store = try store(old)
        XCTAssertEqual(try store.read(installation), "old-token")
        try store.removeChecked(installation)
        XCTAssertNil(try store.read(installation))
        XCTAssertEqual(old.reads, 1, "An owner disconnect stays final after the file is removed")
        let unread = "never-read"
        store.remove(unread)
        XCTAssertNil(try store.read(unread))
        XCTAssertEqual(old.reads, 1)
    }

    func testRotationDuringTheOldStoreReadWins() throws {
        let old = FakeOldStore([installation: "old-token"]), store = try store(old)
        old.onRead = { [installation] in try? store.write(installation, "rotated-token") }
        XCTAssertEqual(try store.read(installation), "rotated-token")
        old.onRead = nil
        XCTAssertEqual(try store.read(installation), "rotated-token")
    }

    func testConcurrentFirstReadsAgreeAndLeaveNoTemporaryFile() throws {
        let old = FakeOldStore([installation: "old-token"]), store = try store(old)
        let results = NSLock(); var values: [String?] = []
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            let value = try? store.read(installation)
            results.withLock { values.append(value ?? nil) }
        }
        XCTAssertEqual(Set(values), ["old-token"])
        let left = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(left, [])
    }

    func testAnUnwritableFolderDoesNotFailTheMigrationRead() throws {
        let old = FakeOldStore([installation: "old-token"]), store = try store(old)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        XCTAssertEqual(try store.read(installation), "old-token", "A sandboxed CLI can read but not write")
        XCTAssertEqual(try store.read(installation), "old-token")
        XCTAssertEqual(old.reads, 2, "The next read retries")
        assertCode("CREDENTIAL_STORE_UNAVAILABLE") { try store.write(self.installation, "new-token") }
    }

    func testRollbackPathKeepsAnUnrotatedCredentialAndShowsARotatedOneAsAMismatch() throws {
        // The previous bundle reads only the old store. The new bundle writes only the file.
        let old = FakeOldStore(["unrotated": "token-a", "rotated": "token-b"]), store = try store(old)
        XCTAssertEqual(try store.read("unrotated"), "token-a")
        XCTAssertEqual(try store.read("rotated"), "token-b")
        try store.write("rotated", "token-b2")
        try store.write("created-on-new-build", "token-c")
        XCTAssertEqual(try old.read("unrotated"), "token-a", "The previous bundle keeps working here")
        XCTAssertEqual(try old.read("rotated"), "token-b", "The previous bundle sees the old value, which fails the digest check")
        XCTAssertNil(try old.read("created-on-new-build"), "The previous bundle has no credential here")
        // Forward again: the file decides, so a value written only by the previous bundle stays unseen.
        XCTAssertEqual(try store.read("rotated"), "token-b2")
    }

    func testFailedEnrollmentWriteRestoresThePriorCredential() throws {
        let old = FakeOldStore([installation: "old-token"]), store = try store(old)
        let prior = try store.read(installation)
        var registrations = 0
        XCTAssertThrowsError(try ConnectionCommit.perform(saveCredential: { try store.write(self.installation, "new-token") },
                                                          saveEnrollment: { throw CocoaError(.fileWriteOutOfSpace) },
                                                          registerSession: { registrations += 1 },
                                                          rollback: { try ConnectionCommit.restore(enrollment: {}, credential: {
            if let prior { try store.write(self.installation, prior) } else { try store.removeChecked(self.installation) }
        }) }))
        XCTAssertEqual(registrations, 0)
        XCTAssertEqual(try store.read(installation), "old-token")
    }

    func testFailedEnrollmentWriteOfANewConnectionLeavesNoCredential() throws {
        let store = try store(FakeOldStore())
        let prior = try store.read(installation)
        XCTAssertNil(prior)
        XCTAssertThrowsError(try ConnectionCommit.perform(saveCredential: { try store.write(self.installation, "new-token") },
                                                          saveEnrollment: { throw CocoaError(.fileWriteOutOfSpace) },
                                                          registerSession: {},
                                                          rollback: { try ConnectionCommit.restore(enrollment: {}, credential: { try store.removeChecked(self.installation) }) }))
        XCTAssertNil(try store.read(installation))
    }

    func testFailedCredentialWriteNeverReachesEnrollmentAndAFailedRestoreIsReported() throws {
        let store = try store()
        try FileManager.default.createSymbolicLink(at: store.directory, withDestinationURL: FileManager.default.temporaryDirectory)
        var saved = 0
        XCTAssertThrowsError(try ConnectionCommit.perform(saveCredential: { try store.write(self.installation, "new-token") },
                                                          saveEnrollment: { saved += 1 }, registerSession: {}, rollback: {})) {
            XCTAssertEqual(($0 as? ChecklistError)?.code, "CREDENTIAL_STORE_UNAVAILABLE")
        }
        XCTAssertEqual(saved, 0)
        XCTAssertThrowsError(try ConnectionCommit.perform(saveCredential: {}, saveEnrollment: { throw CocoaError(.fileWriteOutOfSpace) }, registerSession: {},
                                                          rollback: { try store.removeChecked(self.installation) })) {
            XCTAssertEqual(($0 as? ChecklistError)?.code, "CONNECTION_RECOVERY_REQUIRED")
        }
    }

    func testACopiedFileOfAnotherInstanceRootOrInstallationIsRefusedWithoutAnOldStoreRead() throws {
        let live = try liveInstance(), source = try store()
        try source.write(installation, "live-token")
        let old = FakeOldStore([installation: "old-token"])

        let slot = try ChecklistInstance(slotValue: 2, home: root, environment: [:])
        let slotRoot = root.appendingPathComponent("slot-data", isDirectory: true)
        let slotStore = try store(old, root: slotRoot, instance: slot)
        try FileManager.default.createDirectory(at: slotStore.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: file(source), to: file(slotStore))
        assertCode("CREDENTIAL_INSTANCE_MISMATCH") { try slotStore.read(self.installation) }

        let copiedRoot = root.appendingPathComponent("store-copy", isDirectory: true)
        let copied = try store(old, root: copiedRoot, instance: live)
        try FileManager.default.createDirectory(at: copied.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: file(source), to: file(copied))
        assertCode("CREDENTIAL_INSTANCE_MISMATCH") { try copied.read(self.installation) }

        try FileManager.default.copyItem(at: file(source), to: file(source, "another-installation"))
        assertCode("CREDENTIAL_INSTANCE_MISMATCH") { try source.read("another-installation") }
        XCTAssertEqual(old.reads, 0)
        try copied.write(installation, "own-token")
        XCTAssertEqual(try copied.read(installation), "own-token", "A write replaces the refused file")
    }

    func testUntrustedFilesAreRefusedWithoutAnOldStoreRead() throws {
        let old = FakeOldStore([installation: "old-token"]), store = try store(old)
        try store.write(installation, "file-token")
        let path = file(store)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        assertCode("CREDENTIAL_STORE_UNAVAILABLE") { try store.read(self.installation) }

        try FileManager.default.removeItem(at: path)
        let elsewhere = root.appendingPathComponent("elsewhere.json")
        try Data("{}".utf8).write(to: elsewhere)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: elsewhere.path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: elsewhere)
        assertCode("CREDENTIAL_STORE_UNAVAILABLE") { try store.read(self.installation) }

        try FileManager.default.removeItem(at: path)
        try Data("not json".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        assertCode("CREDENTIAL_STORE_UNAVAILABLE") { try store.read(self.installation) }
        XCTAssertEqual(old.reads, 0)
        try store.write(installation, "repaired-token")
        XCTAssertEqual(try store.read(installation), "repaired-token")
    }

    func testOnlyTheBundledLiveInstanceAtItsFixedRootCanUseTheOldStore() throws {
        let home = root!, bundle = root.appendingPathComponent("Checklist.app", isDirectory: true)
        let live = try ChecklistInstance(bundleURL: bundle, home: home, environment: [:])
        XCTAssertTrue(InstallationCredentialStore.usesLegacyMigration(root: live.root, instance: live))
        XCTAssertTrue(InstallationCredentialStore.usesLegacyMigration(root: live.root.appendingPathComponent("connections.json").deletingLastPathComponent(), instance: live),
                      "The coordinator derives the same root from its enrollment file")
        XCTAssertFalse(InstallationCredentialStore.usesLegacyMigration(root: home.appendingPathComponent("temporary"), instance: live))
        let unbundled = try ChecklistInstance(home: home, environment: [:])
        XCTAssertFalse(InstallationCredentialStore.usesLegacyMigration(root: unbundled.root, instance: unbundled))
        let override = try ChecklistInstance(bundleURL: bundle, home: home, environment: ["CHECKLIST_DATA_ROOT": home.appendingPathComponent("override").path])
        XCTAssertFalse(InstallationCredentialStore.usesLegacyMigration(root: override.root, instance: override))
        for number in 1...4 {
            let slot = try ChecklistInstance(slotValue: number, bundleURL: bundle, home: home, environment: [:])
            XCTAssertFalse(InstallationCredentialStore.usesLegacyMigration(root: slot.root, instance: slot))
        }
        XCTAssertFalse(InstallationCredentialStore.usesLegacyMigration(root: ChecklistInstance.current.root, instance: ChecklistInstance.current),
                       "This test process cannot reach Keychain through the production store")
    }

    func testCoordinatorRootAndClientRootGiveTheSameRecordBinding() throws {
        let bundle = root.appendingPathComponent("Checklist.app", isDirectory: true)
        let live = try ChecklistInstance(bundleURL: bundle, home: root, environment: [:])
        let client = InstallationCredentialStore(root: live.root, instance: live, legacyRead: nil)
        let service = InstallationCredentialStore(root: live.root.appendingPathComponent("connections.json").deletingLastPathComponent(), instance: live, legacyRead: nil)
        try service.write(installation, "shared-token")
        XCTAssertEqual(try client.read(installation), "shared-token")
    }

    func testSourceKeepsKeychainCallsInTheOneMigrationFile() throws {
        let allowed = "Sources/ChecklistIPC/LegacyKeychainCredentialMigration.swift"
        let patterns = ["SecItem", "SecKeychain", "kSecClass", "kSecAttrService", "kSecValueData", "SecAccess", "SecTrustedApplication",
                        "LAContext", "LocalAuthentication", "KeychainWithoutUI", "import ChecklistLegacyKeychain", "ChecklistKeychain"]
        var scanned = 0
        for folder in ["Sources", "Packages"] {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: repository.appendingPathComponent(folder), includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where ["swift", "c", "h", "m", "mm"].contains(url.pathExtension) {
                let relative = String(url.path.dropFirst(repository.path.count + 1))
                if relative == allowed || relative.hasPrefix("Sources/ChecklistLegacyKeychain/") || relative.contains("/.build/") { continue }
                scanned += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                for pattern in patterns { XCTAssertFalse(text.contains(pattern), "\(relative) contains \(pattern)") }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "The scan found the sources")

        let migration = try String(contentsOf: repository.appendingPathComponent(allowed), encoding: .utf8)
        XCTAssertEqual(migration.components(separatedBy: "SecItemCopyMatching").count - 1, 1, "One read call")
        for write in ["SecItemAdd", "SecItemUpdate", "SecItemDelete", "SecAccess", "SecTrustedApplication"] { XCTAssertFalse(migration.contains(write), write) }
        XCTAssertTrue(migration.contains("Removal condition:"))
        let bridge = try String(contentsOf: repository.appendingPathComponent("Sources/ChecklistLegacyKeychain/ChecklistLegacyKeychain.c"), encoding: .utf8)
            + String(contentsOf: repository.appendingPathComponent("Sources/ChecklistLegacyKeychain/include/ChecklistLegacyKeychain.h"), encoding: .utf8)
        for removed in ["SecAccess", "SecTrustedApplication", "SecKeychainCreate", "SecKeychainDelete", "SecItem"] { XCTAssertFalse(bridge.contains(removed), removed) }
        let adapters = try String(contentsOf: repository.appendingPathComponent("docs/platform-adapters.md"), encoding: .utf8)
        XCTAssertTrue(adapters.contains("LegacyKeychainCredentialMigration"), "The remaining use is listed")
    }
}
