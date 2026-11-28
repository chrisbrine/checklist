import XCTest
import Foundation
import CryptoKit
import GRDB
import ChecklistIPC
import ChecklistProviders
import ChecklistBridges
@testable import ChecklistCore
@testable import ChecklistService

/// Real private-store closure/resumption and persistence, with fake native proof.
/// No native host, registry, listener, Codex files or Keychain is used.
final class NativeBootstrapContinuationTests: XCTestCase {
    private typealias JSON = [String: Any]
    private final class ResultBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        func set(_ value: Value) { lock.withLock { stored = value } }
        var value: Value? { lock.withLock { stored } }
    }
    private final class Evidence: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0, pauses = 0
        var refusedScans = Set<Int>()
        var pause: (@Sendable () -> Void)?
        let host = CodexProcess(pid: 24681, executable: "/Applications/Synthetic.app/Contents/MacOS/codex", role: .appHost)
        func scan() -> CodexHostScan {
            lock.withLock {
                reads += 1
                return .init(hosts: [host], holders: [host], unreadable: refusedScans.contains(reads),
                    execClaim: false, incompleteNonCodex: reads, blockers: [])
            }
        }
        func retry() {
            let callback = lock.withLock { pauses += 1; return pause }
            callback?()
        }
        var counts: [Int] { lock.withLock { [reads, pauses] } }
        var effects: CodexAppHostRestartEffects {
            .init(available: true, process: { $0.startSeconds == 5 ? .gone : .running },
                source: { _ in .init(host: .nativeApp, reason: .sourceVscode, source: "vscode") },
                scan: { [self] _ in scan() }, signed: { _ in true }, holds: { _ in true },
                pauseBeforeRetry: { [self] in retry() })
        }
    }
    private final class Fixture: @unchecked Sendable {
        let root: URL
        let coordinator: Coordinator
        let project: String
        let original: Enrollment
        let evidence = Evidence()
        let owner: Caller
        let token: String
        var router: CommandRouter { coordinator.router }

        init() throws {
            let fixtureRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/ChecklistQualification/r12-N/test-fixtures")
                .appendingPathComponent("native-bootstrap-continuation-" + UUID().uuidString)
            let fixtureOwner = Caller(role: "owner", installation: "native-continuation-fixture", projectIDs: [])
            let fixtureToken = "synthetic-continuation-credential"
            try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
            let router = try CommandRouter(root: fixtureRoot.appendingPathComponent("store"))
            let instance = try ChecklistInstance(home: fixtureRoot, environment: [:])
            let credentials = InstallationCredentialStore(root: fixtureRoot, instance: instance, legacyRead: nil)
            let fixtureCoordinator = Coordinator(router: router, enrollmentFile: fixtureRoot.appendingPathComponent("connections.json"),
                startBackgroundWork: false, credentials: credentials, instance: instance)
            let fixtureProject = try XCTUnwrap((try router.handle(method: "project_create", params: ["command_id": UUID().uuidString,
                "name": "Continuation fixture", "key_prefix": "NC", "root_path": fixtureRoot.path], caller: fixtureOwner)["data"] as? JSON)?["id"] as? String)
            let sid = UUID().uuidString.lowercased()
            let identity = SHA256.hash(data: Data("codex|\(sid)|\(fixtureProject)".utf8)).map { String(format: "%02x", $0) }.joined()
            var enrollment = Enrollment(installation: "auto-codex-" + identity.prefix(40), name: "Synthetic continuation", provider: "codex",
                role: "worker", projectIDs: [fixtureProject], sessionID: sid, workspace: fixtureRoot.path, profileID: nil,
                tokenDigest: SHA256.hash(data: Data(fixtureToken.utf8)).map { String(format: "%02x", $0) }.joined(), generation: "synthetic-original")
            enrollment.automatic = true; enrollment.nativeSessionID = sid
            enrollment.nativeExecutionDomain = "codex:24680:5:0"; enrollment.codexAppHostProven = true
            enrollment.identityVerification = CodexProviderPlugin().nativeHost?.identityVerification
            _ = try router.handle(method: "session_register", params: ["command_id": UUID().uuidString,
                "project_id": fixtureProject, "project_ids": [fixtureProject], "session_id": sid,
                "installation": enrollment.installation + "/" + enrollment.generation, "provider": "codex", "role": "worker",
                "workspace": fixtureRoot.path, "execution_domain": enrollment.nativeExecutionDomain!], caller: fixtureOwner)
            root = fixtureRoot; coordinator = fixtureCoordinator; project = fixtureProject
            original = enrollment; owner = fixtureOwner; token = fixtureToken
            coordinator.enrollments[enrollment.installation] = enrollment
            coordinator.nativeLifecycle.watchesEnabled = false
            coordinator.codexAppHostRestartEffects = evidence.effects
            try coordinator.saveEnrollments(); try credentials.write(enrollment.installation, token)
        }

        func close() throws {
            router.backupWrites.endBackup(router: router)
            for _ in 0..<3 { coordinator.storageQueue.sync {}; coordinator.workHealthQueue.sync {}; coordinator.queue.sync {} }
            coordinator.queue.sync { coordinator.storageWake?.cancel(); coordinator.workHealthWake?.cancel() }
            coordinator.queue.busyPeriods.flush()
            try router.closeStore()
            let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: root, to: trash.appendingPathComponent(root.lastPathComponent))
        }

        func bootstrap() throws -> Coordinator.BootstrapResult {
            try coordinator.bootstrapVerifiedWorkspace([:], native: .init(provider: "codex", session: original.sessionID,
                process: evidence.host.pid, executionDomain: "codex:24681:6:0", workspace: root.path), readCredential: coordinator.credentials.read)
        }
        func continuation() throws -> NativeBootstrapContinuation {
            try coordinator.queue.sync {
                do {
                    _ = try coordinator.withDeferredNativeResumption { try bootstrap() }
                    throw CoreError("TEST_CONTINUATION_MISSING", "Expected a native bootstrap continuation.")
                } catch let continuation as NativeBootstrapContinuation { return continuation }
            }
        }
        func start(_ continuation: NativeBootstrapContinuation) -> (DispatchSemaphore, ResultBox<Result<Coordinator.BootstrapResult, Error>>) {
            let done = DispatchSemaphore(value: 0), result = ResultBox<Result<Coordinator.BootstrapResult, Error>>()
            coordinator.queue.sync {
                coordinator.startNativeBootstrapContinuation(continuation) { outcome in result.set(outcome); done.signal() }
            }
            return (done, result)
        }
        func startAfterClosure(_ continuation: NativeBootstrapContinuation, interpose: () throws -> Void) throws
            -> (DispatchSemaphore, ResultBox<Result<Coordinator.BootstrapResult, Error>>) {
            let paused = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            // Pause the synthetic proof retry after the worker commits closure.
            evidence.refusedScans = [3]
            evidence.pause = { paused.signal(); _ = release.wait(timeout: .now() + 15) }
            let work = start(continuation)
            guard paused.wait(timeout: .now() + 10) == .success else {
                throw CoreError("TEST_CLOSURE_TIMEOUT", "The continuation did not reach its post-closure proof retry.")
            }
            try interpose()
            return work
        }
        func session() throws -> JSON {
            try XCTUnwrap(router.connectionSession(sessionID: original.sessionID, project: project, caller: owner))
        }
        func seedNotices(_ count: Int) throws {
            func call(_ method: String, _ params: JSON, caller: Caller? = nil) throws -> JSON {
                var params = params; params["command_id"] = UUID().uuidString
                return try XCTUnwrap(try router.handle(method: method, params: params, caller: caller ?? owner)["data"] as? JSON)
            }
            let epic = try call("epic_create", ["project_id": project, "name": "Continuation work"])
            var task = try call("task_create", ["project_id": project, "epic_id": epic["id"]!, "title": "Continuation work", "brief": "Owned synthetic fixture"])
            task = try call("task_edit", ["project_id": project, "task_id": task["id"]!, "expected_revision": task["revision"]!, "patch": ["readiness": "ready"]])
            _ = try call("work_claim", ["project_id": project, "task_id": task["id"]!, "expected_revision": task["revision"]!, "file_scopes": []],
                caller: Caller(role: "worker", installation: original.installation + "/" + original.generation, projectIDs: [project],
                    sessionID: original.sessionID, workspace: root.path, executionDomain: original.nativeExecutionDomain))
            for index in 0..<count { _ = try call("message_send", ["project_id": project, "task_id": task["id"]!, "body": "Generated notice \(index)"]) }
        }
        func summary(error: Error?) throws -> [String] {
            let current = try session(), local = try coordinator.queue.sync { try XCTUnwrap(coordinator.enrollments[original.installation]) }
            let recordEffects = try router.dbQueue.read { db -> [String] in
                var result: [String] = []
                for delivery in try router.records(db, type: "delivery", project: project) {
                    let receipt = try router.deliveryReceiptProjection(db, delivery)
                    result.append("delivery:" + (receipt["state"] as? String ?? "") + ":" + (delivery["recipient_role"] as? String ?? "")
                        + ":lineage=" + String(delivery["resumed_from_delivery_id"] != nil)
                        + ":current=" + String(delivery["recipient_authorization_generation"] as? String == current["authorization_generation"] as? String))
                }
                for attempt in try router.records(db, type: "attempt", project: project) {
                    result.append("attempt:" + (attempt["state"] as? String ?? "") + ":token=" + String(attempt["token_hash"] != nil))
                }
                result += try String.fetchAll(db, sql: "SELECT kind FROM events ORDER BY seq").map { "event:" + $0 }
                return result
            }
            return [errorCode(error), current["state"] as? String ?? "", String(current["owner_revoked"] as? Bool == true),
                String(local.revoked == true), String(local.ownerRevoked == true),
                String(local.generation == original.generation), String(try coordinator.credentials.read(original.installation) == token)]
                + evidence.counts.map(String.init) + recordEffects
        }
        private func errorCode(_ error: Error?) -> String {
            (error as? ChecklistError)?.code ?? (error as? CoreError)?.code ?? (error == nil ? "success" : "other-error")
        }
    }

    func testGeneratedProofRetriesMatchSynchronousResults() throws {
        for mask in 0..<16 {
            let refused = Set((3...6).filter { mask & (1 << ($0 - 3)) != 0 })
            let synchronous = try Fixture(), asynchronous = try Fixture()
            defer { XCTAssertNoThrow(try synchronous.close()); XCTAssertNoThrow(try asynchronous.close()) }
            try synchronous.seedNotices(mask % 4); try asynchronous.seedNotices(mask % 4)
            synchronous.evidence.refusedScans = refused; asynchronous.evidence.refusedScans = refused
            var synchronousError: Error?
            do { _ = try synchronous.coordinator.queue.sync { try synchronous.bootstrap() } } catch { synchronousError = error }
            let continuation = try asynchronous.continuation(), (done, result) = asynchronous.start(continuation)
            XCTAssertEqual(done.wait(timeout: .now() + 20), .success)
            var asynchronousError: Error?
            do { _ = try XCTUnwrap(result.value).get() } catch { asynchronousError = error }
            XCTAssertEqual(try synchronous.summary(error: synchronousError), try asynchronous.summary(error: asynchronousError), "Refused scans: \(refused)")
        }
    }

    func testBlockedProofRetryLeavesCommandQueueAndPooledReadAvailable() throws {
        let fixture = try Fixture()
        defer { XCTAssertNoThrow(try fixture.close()) }
        fixture.evidence.refusedScans = [3]
        let paused = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        fixture.evidence.pause = { paused.signal(); _ = release.wait(timeout: .now() + 15) }
        let continuation = try fixture.continuation(), (done, result) = fixture.start(continuation)
        XCTAssertEqual(paused.wait(timeout: .now() + 10), .success)
        let read = DispatchSemaphore(value: 0), failure = ResultBox<Error>()
        fixture.coordinator.queue.async {
            do { _ = try fixture.router.handle(method: "service_info", params: [:], caller: fixture.owner) }
            catch { failure.set(error) }
            read.signal()
        }
        XCTAssertEqual(read.wait(timeout: .now() + 5), .success, "Read must finish while retry worker is still paused")
        XCTAssertNil(failure.value)
        XCTAssertEqual(try fixture.session()["state"] as? String, "ended")
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success)
        XCTAssertTrue(try XCTUnwrap(result.value).get().changed)
        XCTAssertEqual(fixture.evidence.counts, [7, 1])
    }

    func testFinalProofOwnerRevocationRestoresFencedGenerationAndCredential() throws {
        let fixture = try Fixture()
        defer { XCTAssertNoThrow(try fixture.close()) }
        fixture.evidence.refusedScans = [5]
        let paused = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        fixture.evidence.pause = { paused.signal(); _ = release.wait(timeout: .now() + 15) }
        let continuation = try fixture.continuation(), (done, result) = fixture.start(continuation)
        XCTAssertEqual(paused.wait(timeout: .now() + 10), .success)
        fixture.coordinator.queue.sync {
            fixture.coordinator.enrollments[fixture.original.installation]?.ownerRevoked = true
            fixture.coordinator.enrollments[fixture.original.installation]?.revoked = true
        }
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success)
        XCTAssertThrowsError(try XCTUnwrap(result.value).get()) { XCTAssertEqual(($0 as? ChecklistError)?.code, "CONNECTION_REVOKED") }
        let local = try fixture.coordinator.queue.sync { try XCTUnwrap(fixture.coordinator.enrollments[fixture.original.installation]) }
        XCTAssertEqual(local.generation, fixture.original.generation)
        XCTAssertTrue(local.revoked == true && local.ownerRevoked == true)
        XCTAssertEqual(try fixture.coordinator.credentials.read(local.installation), fixture.token)
        XCTAssertEqual(try fixture.session()["state"] as? String, "ended")
    }

    func testCoreRefusalRollsBackOnlyUncommittedStaging() throws {
        let fixture = try Fixture()
        defer { XCTAssertNoThrow(try fixture.close()) }
        let continuation = try fixture.continuation()
        let (done, result) = try fixture.startAfterClosure(continuation) {
            let closureID = try XCTUnwrap(try fixture.session()["native_closure_ref"] as? String)
            try fixture.router.dbQueue.write { db in
                var closure = try fixture.router.record(db, closureID, type: "native_closure")
                closure["state"] = "release_pending"
                try fixture.router.save(db, fixture.router.revised(closure), type: "native_closure")
            }
        }
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success)
        XCTAssertThrowsError(try XCTUnwrap(result.value).get()) { XCTAssertEqual(($0 as? CoreError)?.code, "NATIVE_CLOSURE_PENDING") }
        let local = try fixture.coordinator.queue.sync { try XCTUnwrap(fixture.coordinator.enrollments[fixture.original.installation]) }
        XCTAssertEqual(local.generation, fixture.original.generation); XCTAssertTrue(local.revoked == true)
        XCTAssertEqual(try fixture.coordinator.credentials.read(local.installation), fixture.token)
        XCTAssertEqual(try fixture.session()["state"] as? String, "ended")
    }

    func testPartialPersistenceFailureAttemptsCredentialRestoration() throws {
        let fixture = try Fixture()
        defer { XCTAssertNoThrow(try fixture.close()) }
        let continuation = try fixture.continuation()
        let enrollmentFile = fixture.coordinator.enrollmentFile
        let (done, result) = try fixture.startAfterClosure(continuation) {
            try FileManager.default.moveItem(at: enrollmentFile, to: fixture.root.appendingPathComponent("saved-connections.json"))
            try FileManager.default.createDirectory(at: enrollmentFile, withIntermediateDirectories: false)
        }
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success)
        XCTAssertThrowsError(try XCTUnwrap(result.value).get()) { error in
            XCTAssertEqual((error as? ChecklistError)?.code, "CONNECTION_RECOVERY_REQUIRED")
            XCTAssertEqual((error as? ChecklistError)?.details["rollback_failed"] as? Bool, true)
        }
        let local = try fixture.coordinator.queue.sync { try XCTUnwrap(fixture.coordinator.enrollments[fixture.original.installation]) }
        XCTAssertEqual(local.generation, fixture.original.generation); XCTAssertTrue(local.revoked == true)
        XCTAssertEqual(try fixture.coordinator.credentials.read(local.installation), fixture.token,
                       "Credential restoration still runs when enrollment restoration fails")
        XCTAssertEqual(try fixture.session()["state"] as? String, "ended")
    }

    func testUncommittedRollbackDoesNotOverwriteReplacementEnrollmentOrCredential() throws {
        let fixture = try Fixture()
        defer { XCTAssertNoThrow(try fixture.close()) }
        fixture.evidence.refusedScans = [5]
        let paused = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        fixture.evidence.pause = { paused.signal(); _ = release.wait(timeout: .now() + 15) }
        let continuation = try fixture.continuation(), (done, result) = fixture.start(continuation)
        XCTAssertEqual(paused.wait(timeout: .now() + 10), .success)
        let replacementToken = "synthetic-replacement-credential"
        try fixture.coordinator.queue.sync {
            var replacement = try XCTUnwrap(fixture.coordinator.enrollments[fixture.original.installation])
            replacement.generation = "synthetic-replacement"
            replacement.tokenDigest = SHA256.hash(data: Data(replacementToken.utf8)).map { String(format: "%02x", $0) }.joined()
            fixture.coordinator.enrollments[replacement.installation] = replacement
            try fixture.coordinator.credentials.write(replacement.installation, replacementToken)
            try fixture.coordinator.saveEnrollments()
        }
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success)
        XCTAssertThrowsError(try XCTUnwrap(result.value).get()) { XCTAssertEqual(($0 as? CoreError)?.code, "RECIPIENT_CHANGED") }
        let local = try fixture.coordinator.queue.sync { try XCTUnwrap(fixture.coordinator.enrollments[fixture.original.installation]) }
        XCTAssertEqual(local.generation, "synthetic-replacement")
        XCTAssertEqual(try fixture.coordinator.credentials.read(local.installation), replacementToken)
    }

    func testOwnerRevocationAfterCoreCommitNeverRestoresOldGeneration() throws {
        let fixture = try Fixture()
        defer { XCTAssertNoThrow(try fixture.close()) }
        let continuation = try fixture.continuation(), hookFailure = ResultBox<Error>()
        // Register after closure. This runs after the actual resumption COMMIT,
        // before its worker returns, and creates a later independent owner fence.
        let (done, result) = try fixture.startAfterClosure(continuation) {
            fixture.router.dbQueue.writeWithoutTransaction { db in
                db.afterNextTransaction { committed in
                    do {
                        try committed.inTransaction {
                            var session = try fixture.router.record(committed, fixture.original.sessionID, type: "session")
                            session["state"] = "revoked"; session["owner_revoked"] = true
                            session["authorization_generation"] = UUID().uuidString
                            try fixture.router.save(committed, fixture.router.revised(session), type: "session")
                            return .commit
                        }
                    } catch { hookFailure.set(error) }
                }
            }
        }
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success)
        XCTAssertNil(hookFailure.value)
        XCTAssertThrowsError(try XCTUnwrap(result.value).get()) { XCTAssertEqual(($0 as? ChecklistError)?.code, "CONNECTION_REVOKED") }
        let local = try fixture.coordinator.queue.sync { try XCTUnwrap(fixture.coordinator.enrollments[fixture.original.installation]) }
        let session = try fixture.session()
        XCTAssertNotEqual(local.generation, fixture.original.generation)
        XCTAssertTrue(local.revoked == true && local.ownerRevoked == true)
        XCTAssertEqual(session["installation"] as? String, local.installation + "/" + local.generation)
        XCTAssertNotEqual(try fixture.coordinator.credentials.read(local.installation), fixture.token)
        XCTAssertTrue(session["owner_revoked"] as? Bool == true)
    }

    func testExplicitOwnerAllowAgainSupersedesSavedOwnerFlag() throws {
        let fixture = try Fixture()
        defer { XCTAssertNoThrow(try fixture.close()) }
        for method in ["connection_revoke", "connection_allow"] {
            let session = try fixture.session()
            _ = try fixture.router.handle(method: method, params: ["command_id": UUID().uuidString,
                "project_id": fixture.project, "session_id": fixture.original.sessionID,
                "installation": session["installation"]!, "expected_revision": session["revision"]!], caller: fixture.owner)
        }
        fixture.coordinator.queue.sync {
            fixture.coordinator.enrollments[fixture.original.installation]?.ownerRevoked = true
            fixture.coordinator.enrollments[fixture.original.installation]?.revoked = true
        }
        let continuation = try fixture.continuation(), (done, result) = fixture.start(continuation)
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success)
        XCTAssertTrue(try XCTUnwrap(result.value).get().changed)
        XCTAssertEqual(fixture.evidence.counts, [0, 0])
        XCTAssertEqual(try fixture.session()["state"] as? String, "connected")
        let local = try fixture.coordinator.queue.sync { try XCTUnwrap(fixture.coordinator.enrollments[fixture.original.installation]) }
        XCTAssertFalse(local.revoked == true || local.ownerRevoked == true)
        XCTAssertNotEqual(try fixture.coordinator.credentials.read(local.installation), fixture.token)
    }

    func testFreshBootstrapOfStagedConversationWaitsForItsRealCommit() throws {
        let fixture = try Fixture()
        defer { XCTAssertNoThrow(try fixture.close()) }
        try fixture.seedNotices(3)
        // Pause the real continuation after local credential/enrollment staging,
        // before Core writer admission, while pooled reads see the ended generation.
        fixture.evidence.refusedScans = [5]
        let paused = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        fixture.evidence.pause = { paused.signal(); _ = release.wait(timeout: .now() + 15) }
        let continuation = try fixture.continuation(), (done, result) = fixture.start(continuation)
        XCTAssertEqual(paused.wait(timeout: .now() + 10), .success)
        let secondDone = DispatchSemaphore(value: 0), second = ResultBox<Result<Coordinator.BootstrapResult, Error>>()
        let queued = fixture.coordinator.queue.sync { () -> Bool in
            do {
                let staged = try XCTUnwrap(fixture.coordinator.enrollments[fixture.original.installation])
                XCTAssertNotEqual(staged.generation, fixture.original.generation)
                let canonical = try fixture.session()
                XCTAssertEqual(canonical["state"] as? String, "ended")
                XCTAssertEqual(canonical["installation"] as? String, fixture.original.installation + "/" + fixture.original.generation)
                let current = try fixture.coordinator.attemptCurrentNativeBootstrap({
                    try fixture.coordinator.bootstrapVerifiedWorkspace([:], native: .init(provider: "codex", session: fixture.original.sessionID,
                        process: fixture.evidence.host.pid, executionDomain: "codex:24681:6:0", workspace: fixture.root.path),
                        readCredential: fixture.coordinator.credentials.read, currentConnectionOnly: true)
                }, retry: {
                    second.set(Result { try fixture.bootstrap() }); secondDone.signal()
                })
                XCTAssertNil(current, "Staged authority must not reply before its real Core commit")
                XCTAssertNil(second.value)
                XCTAssertEqual(fixture.coordinator.nativeLifecycle.connectionRequests.count, 1)
                XCTAssertTrue(fixture.coordinator.nativeLifecycle.resumptionInFlight)
                return current == nil
            } catch {
                XCTFail("A fresh bootstrap must wait for the staged generation instead of failing early: \(error)")
                return false
            }
        }
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success)
        XCTAssertTrue(try XCTUnwrap(result.value).get().changed)
        guard queued else { return }
        XCTAssertEqual(secondDone.wait(timeout: .now() + 20), .success)
        let secondResult = try XCTUnwrap(second.value).get()
        XCTAssertFalse(secondResult.changed, "Retry reuses the now-committed generation")
        let current = try XCTUnwrap(fixture.coordinator.enrollments[fixture.original.installation])
        let session = try fixture.session()
        XCTAssertEqual(session["installation"] as? String, current.installation + "/" + current.generation)
        XCTAssertEqual(session["state"] as? String, "connected")
        XCTAssertEqual((secondResult.reply["data"] as? JSON)?["installation"] as? String, current.installation)
        XCTAssertNotEqual(current.generation, fixture.original.generation)
    }

}
