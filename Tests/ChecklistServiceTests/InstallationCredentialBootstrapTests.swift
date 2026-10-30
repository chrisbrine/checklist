import XCTest
import CryptoKit
import ChecklistIPC
import ChecklistProviders
@testable import ChecklistCore
@testable import ChecklistService

/// CL-374: enrolled sessions through the real bootstrap stages, with a counting fake of the
/// old store. Synthetic store only. No listener, host registry or Keychain.
final class InstallationCredentialBootstrapTests: XCTestCase {
    private final class FakeOldStore: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        private var failure: Error?
        private var count = 0
        var reads: Int { lock.withLock { count } }
        func set(_ account: String, _ value: String) { lock.withLock { values[account] = value } }
        func fail(_ error: Error?) { lock.withLock { failure = error } }
        func read(_ account: String) throws -> String? {
            try lock.withLock {
                count += 1
                if let failure { throw failure }
                return values[account]
            }
        }
    }
    private var root: URL!
    private var coordinator: Coordinator!
    private var project: String!
    private var enrollment: Enrollment!
    private let old = FakeOldStore()
    private let oldToken = "synthetic-old-store-token"
    private let owner = Caller(role: "owner", installation: "credential-test-owner", projectIDs: [])

    private func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let router = try CommandRouter(root: root.appendingPathComponent("store"))
        project = try XCTUnwrap((try router.handle(method: "project_create", params: ["command_id": UUID().uuidString,
            "name": "Credential fixture", "key_prefix": "CF", "root_path": root.path], caller: owner)["data"] as? [String: Any])?["id"] as? String)
        let instance = try ChecklistInstance(home: root, environment: [:])
        let store = InstallationCredentialStore(root: root, instance: instance, legacyRead: { [old] in try old.read($0) })
        coordinator = Coordinator(router: router, enrollmentFile: root.appendingPathComponent("connections.json"), startBackgroundWork: false, credentials: store)
        let sid = UUID().uuidString
        let identity = SHA256.hash(data: Data("codex|\(sid)|\(project!)".utf8)).map { String(format: "%02x", $0) }.joined()
        enrollment = Enrollment(installation: "auto-codex-" + identity.prefix(40), name: "Synthetic worker", provider: "codex", role: "worker",
            projectIDs: [project], sessionID: sid, workspace: root.path, profileID: nil, tokenDigest: digest(oldToken), generation: "synthetic-generation")
        enrollment.automatic = true; enrollment.nativeSessionID = sid; enrollment.nativeExecutionDomain = "synthetic-host-domain"
        enrollment.identityVerification = ProviderPluginRegistry.bundled.plugin("codex", requiring: .workSession)?.nativeHost?.identityVerification
        _ = try router.handle(method: "session_register", params: ["command_id": UUID().uuidString, "project_id": project!,
            "project_ids": [project!], "session_id": sid, "installation": enrollment.installation + "/" + enrollment.generation,
            "provider": "codex", "role": "worker", "workspace": root.path, "execution_domain": enrollment.nativeExecutionDomain!], caller: owner)
        coordinator.enrollments[enrollment.installation] = enrollment
        try coordinator.saveEnrollments()
    }
    override func tearDownWithError() throws {
        if let coordinator {
            for _ in 0..<2 { coordinator.storageQueue.sync {}; coordinator.queue.sync {} }
            coordinator.queue.sync { coordinator.storageWake?.cancel(); coordinator.workHealthWake?.cancel() }
            try coordinator.router.closeStore()
        }
        coordinator = nil
        if let root { try FileManager.default.removeItem(at: root) }
    }
    private func native() -> Coordinator.VerifiedNativeWorkspace {
        .init(provider: "codex", session: enrollment.sessionID, process: getpid(), executionDomain: enrollment.nativeExecutionDomain!, workspace: root.path)
    }
    private func bootstrap(read: ((String) throws -> String?)? = nil) throws -> Coordinator.BootstrapResult {
        try coordinator.bootstrapVerifiedWorkspace([:], native: native(), readCredential: read ?? coordinator.credentials.read)
    }
    private func refuses(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Any) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? ChecklistError)?.code ?? (error as? CoreError)?.code, code, file: file, line: line)
        }
    }
    private func allowAgain() throws {
        let session = try XCTUnwrap(coordinator.router.connectionSession(sessionID: enrollment.sessionID, project: project, caller: owner))
        func input() throws -> [String: Any] {
            let current = try XCTUnwrap(coordinator.router.connectionSession(sessionID: enrollment.sessionID, project: project, caller: owner))
            return ["command_id": UUID().uuidString, "project_id": project!, "session_id": enrollment.sessionID, "installation": session["installation"]!, "expected_revision": current["revision"]!]
        }
        _ = try coordinator.router.handle(method: "connection_revoke", params: input(), caller: owner)
        _ = try coordinator.router.handle(method: "connection_allow", params: input(), caller: owner)
    }

    func testEnrolledSessionWithOnlyTheOldStoreKeepsWorkingWithoutARotationAndReadsItOnce() throws {
        old.set(enrollment.installation, oldToken)
        for _ in 0..<3 {
            let result = try bootstrap()
            XCTAssertFalse(result.changed, "No reconnect and no rotation")
        }
        XCTAssertEqual(old.reads, 1)
        XCTAssertEqual(coordinator.enrollments[enrollment.installation]?.tokenDigest, digest(oldToken))
        XCTAssertEqual(coordinator.enrollments[enrollment.installation]?.generation, "synthetic-generation")
        XCTAssertEqual(try coordinator.credentials.read(enrollment.installation), oldToken)
    }

    func testOldStoreFailureGivesThePlainErrorAndChangesNothing() throws {
        old.set(enrollment.installation, oldToken)
        old.fail(ChecklistError("KEYCHAIN_UNAVAILABLE", "Cannot read the paired installation (-25308)."))
        refuses("KEYCHAIN_UNAVAILABLE") { try self.bootstrap() }
        XCTAssertEqual(coordinator.enrollments[enrollment.installation]?.generation, "synthetic-generation")
        old.fail(nil)
        XCTAssertFalse(try bootstrap().changed, "The next read recovers when the old item is readable again")
    }

    func testNeitherStoreIsARepairState() throws {
        refuses("CONNECTION_REPAIR_REQUIRED") { try self.bootstrap() }
    }

    func testOwnerAllowAgainRecoversAnUnreadableOldItemWithAFileCredential() throws {
        old.set(enrollment.installation, oldToken)
        old.fail(ChecklistError("KEYCHAIN_UNAVAILABLE", "Cannot read the paired installation (-25308)."))
        try allowAgain()
        let result = try bootstrap()
        XCTAssertTrue(result.changed)
        let token = try XCTUnwrap(try coordinator.credentials.read(enrollment.installation))
        XCTAssertNotEqual(token, oldToken)
        XCTAssertEqual(coordinator.enrollments[enrollment.installation]?.tokenDigest, digest(token))
        XCTAssertFalse(try bootstrap().changed, "It keeps working from the file")
    }

    func testRollbackFailsOnlyForARotatedCredentialAndAllowAgainRecoversIt() throws {
        old.set(enrollment.installation, oldToken)
        XCTAssertFalse(try bootstrap().changed)
        // The previous bundle: this stage with only the old-store read. The item is unchanged.
        let previous: (String) throws -> String? = { [old] in try old.read($0) }
        XCTAssertFalse(try bootstrap(read: previous).changed, "An unrotated credential works after a rollback")
        // A rotation on the new build writes the file only.
        try allowAgain()
        XCTAssertTrue(try bootstrap().changed)
        let rotated = try XCTUnwrap(try coordinator.credentials.read(enrollment.installation))
        XCTAssertNotEqual(rotated, oldToken)
        XCTAssertEqual(try old.read(enrollment.installation), oldToken, "The old store keeps the old value")
        refuses("CONNECTION_REPAIR_REQUIRED") { try self.bootstrap(read: previous) }
        // Forward again, the file still matches the enrollment.
        XCTAssertFalse(try bootstrap().changed)
    }

    func testRollbackNewProcessWithAMismatchedCredentialAfterClosureIsRefusedAsADisconnect() throws {
        // A previous bundle with an older Keychain value: the same reconnect check, after a verified closure.
        try coordinator.credentials.write(enrollment.installation, "older-value-than-the-enrollment")
        coordinator.enrollments[enrollment.installation]?.revoked = true
        let later = Coordinator.VerifiedNativeWorkspace(provider: "codex", session: enrollment.sessionID, process: getpid(), executionDomain: "synthetic-later-domain", workspace: root.path)
        refuses("CONNECTION_REVOKED") { try self.coordinator.bootstrapVerifiedWorkspace([:], native: later, readCredential: self.coordinator.credentials.read) }
        XCTAssertEqual(coordinator.enrollments[enrollment.installation]?.generation, "synthetic-generation")
    }

    func testAFailedRegistrationOfAReconnectRestoresTheEarlierCredentialAndEnrollment() throws {
        try coordinator.credentials.write(enrollment.installation, oldToken)
        try allowAgain()
        // Core refuses the reconnect after both writes, because the session names another process.
        try coordinator.router.dbQueue.write { db in
            var session = try coordinator.router.record(db, enrollment.sessionID, type: "session")
            session["execution_domain"] = "synthetic-moved-domain"
            try coordinator.router.save(db, session, type: "session")
        }
        refuses("CONNECTION_REVOKED") { try self.bootstrap() }
        XCTAssertEqual(try coordinator.credentials.read(enrollment.installation), oldToken)
        XCTAssertEqual(coordinator.enrollments[enrollment.installation]?.tokenDigest, digest(oldToken))
        XCTAssertEqual(coordinator.enrollments[enrollment.installation]?.generation, "synthetic-generation")
    }

    func testDefaultCoordinatorStoreStaysBesideItsEnrollmentFileWithoutTheOldStore() throws {
        let other = try CommandRouter(root: root.appendingPathComponent("other-store"))
        let folder = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plain = Coordinator(router: other, enrollmentFile: folder.appendingPathComponent("connections.json"), startBackgroundWork: false)
        defer { plain.queue.sync { plain.storageWake?.cancel(); plain.workHealthWake?.cancel() }; try? other.closeStore() }
        XCTAssertEqual(plain.credentials.directory.path, folder.appendingPathComponent("OwnerPrivate").path)
        XCTAssertNil(try plain.credentials.read("absent"), "A temporary root has no old-store route")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.credentials.directory.path), "No marker is written without an old store")
    }
}
