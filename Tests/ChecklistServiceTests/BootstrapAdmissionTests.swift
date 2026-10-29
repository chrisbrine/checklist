import XCTest
import CryptoKit
import GRDB
import ChecklistIPC
@testable import ChecklistCore
@testable import ChecklistService

/// Synthetic store and injected credentials only. No listener, host registry or Keychain.
final class BootstrapAdmissionTests: XCTestCase {
    private var root: URL!
    private var coordinator: Coordinator!
    private var project: String!
    private var enrollment: Enrollment!
    private let credential = "synthetic-bootstrap-credential"
    private let owner = Caller(role: "owner", installation: "bootstrap-test-owner", projectIDs: [])

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let router = try CommandRouter(root: root.appendingPathComponent("store"))
        project = try XCTUnwrap((try router.handle(method: "project_create", params: ["command_id": UUID().uuidString,
            "name": "Bootstrap admission fixture", "key_prefix": "BA", "root_path": root.path], caller: owner)["data"] as? [String: Any])?["id"] as? String)
        coordinator = Coordinator(router: router, enrollmentFile: root.appendingPathComponent("connections.json"), startBackgroundWork: false)
        let sid = UUID().uuidString
        let identity = SHA256.hash(data: Data("codex|\(sid)|\(project!)".utf8)).map { String(format: "%02x", $0) }.joined()
        enrollment = Enrollment(installation: "auto-codex-" + identity.prefix(40), name: "Synthetic bootstrap worker", provider: "codex", role: "worker",
            projectIDs: [project], sessionID: sid, workspace: root.path, profileID: nil,
            tokenDigest: SHA256.hash(data: Data(credential.utf8)).map { String(format: "%02x", $0) }.joined(), generation: "synthetic-generation")
        enrollment.automatic = true; enrollment.nativeSessionID = sid; enrollment.nativeExecutionDomain = "synthetic-host-domain"
        _ = try router.handle(method: "session_register", params: ["command_id": UUID().uuidString, "project_id": project!,
            "project_ids": [project!], "session_id": sid, "installation": enrollment.installation + "/" + enrollment.generation,
            "provider": "codex", "role": "worker", "workspace": root.path, "execution_domain": enrollment.nativeExecutionDomain!], caller: owner)
        coordinator.enrollments[enrollment.installation] = enrollment
    }

    override func tearDownWithError() throws {
        if let coordinator {
            coordinator.router.backupWrites.endBackup(router: coordinator.router)
            for _ in 0..<2 { coordinator.storageQueue.sync {}; coordinator.queue.sync {} }
            coordinator.queue.sync { coordinator.storageWake?.cancel(); coordinator.workHealthWake?.cancel() }
            try coordinator.router.closeStore()
        }
        coordinator = nil
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func native(domain: String? = nil, session: String? = nil) -> Coordinator.VerifiedNativeWorkspace {
        .init(provider: "codex", session: session ?? enrollment.sessionID, process: getpid(),
              executionDomain: domain ?? enrollment.nativeExecutionDomain!, workspace: root.path)
    }
    private func bootstrap(_ native: Coordinator.VerifiedNativeWorkspace? = nil) throws -> Coordinator.BootstrapResult {
        try coordinator.bootstrapVerifiedWorkspace([:], native: native ?? self.native(), readCredential: { _ in self.credential })
    }
    private func refuses(_ expected: String, _ body: () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? ChecklistError)?.code ?? (error as? CoreError)?.code, expected, file: file, line: line)
        }
    }

    func testNewUnverifiedConnectionIsRejectedBeforeWriterAdmission() throws {
        try coordinator.router.backupWrites.beginCapture()
        let connection = NSXPCConnection(machServiceName: "org.checklist.synthetic.unconnected")
        defer { connection.invalidate() }
        refuses("NATIVE_CLIENT_REQUIRED") {
            try self.coordinator.route(["method": "connection_bootstrap", "params": [:]], connection: connection)
        }
        XCTAssertTrue(coordinator.backupDeferredCalls.isEmpty)
    }

    func testFreshBootstrapReadsAndTwoQueuedWritesFinishWhileActualWriterIsHeld() throws {
        let router = coordinator.router
        let epic = try XCTUnwrap(try router.handle(method: "epic_create", params: ["command_id": UUID().uuidString,
            "project_id": project!, "name": "Bootstrap fixture tickets"], caller: owner)["data"] as? [String: Any])
        var task = try XCTUnwrap(try router.handle(method: "task_create", params: ["command_id": UUID().uuidString,
            "project_id": project!, "epic_id": epic["id"]!, "title": "Before capture"], caller: owner)["data"] as? [String: Any])
        let original = Data("Immutable original through a fresh bootstrap".utf8)
        let source = root.appendingPathComponent("source.bin")
        try original.write(to: source)
        let attachment = try XCTUnwrap(try router.handle(method: "attachment_add", params: ["command_id": UUID().uuidString,
            "project_id": project!, "task_id": task["id"]!, "path": source.path], caller: owner)["data"] as? [String: Any])
        task = try XCTUnwrap(try router.handle(method: "task_get", params: ["project_id": project!, "task_id": task["id"]!], caller: owner)["data"] as? [String: Any])
        try router.backupWrites.beginCapture()
        let opened = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let closed = expectation(description: "Synthetic writer released")
        DispatchQueue.global().async {
            defer { closed.fulfill() }
            do {
                try router.dbQueue.writeWithoutTransaction { db in
                    try db.execute(sql: "BEGIN IMMEDIATE")
                    defer { try? db.execute(sql: "ROLLBACK") }
                    opened.signal()
                    _ = release.wait(timeout: .now() + 5)
                }
            } catch { XCTFail("Synthetic writer failed: \(error)") }
        }
        XCTAssertEqual(opened.wait(timeout: .now() + 5), .success)
        var writerFinished = false
        defer { if !writerFinished { release.signal(); wait(for: [closed], timeout: 10) } }
        let worker = Caller(role: "worker", installation: enrollment.installation + "/" + enrollment.generation,
            projectIDs: [project], sessionID: enrollment.sessionID, workspace: root.path, executionDomain: enrollment.nativeExecutionDomain)
        let note = UUID().uuidString, edit = UUID().uuidString
        let commands: [(String, [String: Any])] = [
            ("task_get", ["project_id": project!, "task_id": task["id"]!]),
            ("attachment_read", ["project_id": project!, "attachment_id": attachment["id"]!, "representation": "original"]),
            ("message_send", ["project_id": project!, "task_id": task["id"]!, "body": "First accepted", "command_id": note]),
            ("task_edit", ["project_id": project!, "task_id": task["id"]!, "expected_revision": task["revision"]!, "patch": ["title": "Second accepted"], "command_id": edit])]
        for (method, params) in commands {
            let started = ProcessInfo.processInfo.systemUptime
            let connected = try bootstrap()
            XCTAssertFalse(connected.changed)
            XCTAssertEqual((connected.reply["data"] as? [String: Any])?["installation"] as? String, enrollment.installation)
            let reply = try router.handle(method: method, params: params, caller: worker)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            print("P320d synthetic fresh bootstrap + \(method): \(elapsed) seconds with writer held")
            XCTAssertLessThan(elapsed, 1, "Fresh bootstrap + \(method) must not wait for capture")
            let admission = try XCTUnwrap(reply["write_admission"] as? [String: Any])
            XCTAssertEqual(admission["locked"] as? Bool, true)
            XCTAssertEqual(admission["reason"] as? String, "backup_in_progress")
            if method == "message_send" || method == "task_edit" {
                XCTAssertEqual(reply["command_outcome"] as? String, "queued")
                XCTAssertEqual(reply["command_id"] as? String, params["command_id"] as? String)
                XCTAssertEqual((reply["data"] as? [String: Any])?["status_method"] as? String, "command_status")
                XCTAssertEqual(admission["queued"] as? Bool, true)
            } else if method == "task_get" {
                XCTAssertEqual((reply["data"] as? [String: Any])?["title"] as? String, "Before capture")
            } else {
                XCTAssertEqual((reply["data"] as? [String: Any])?["content_base64"] as? String, original.base64EncodedString())
            }
        }
        XCTAssertEqual(coordinator.enrollments[enrollment.installation]?.generation, enrollment.generation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.enrollmentFile.path))
        release.signal(); wait(for: [closed], timeout: 10)
        writerFinished = true
        // Swap the admission observer only after all coordinator-bound reads finish.
        let drained = DispatchSemaphore(value: 0)
        router.observeWriteAdmission { if router.writeAdmissionStatus["locked"] as? Bool == false { drained.signal() } }
        router.backupWrites.endCapture(router: router)
        XCTAssertEqual(drained.wait(timeout: .now() + 10), .success)
        for command in [note, edit] {
            let status = try router.handle(method: "command_status", params: ["project_id": project!, "command_id": command], caller: worker)
            XCTAssertEqual((status["data"] as? [String: Any])?["state"] as? String, "applied")
        }
        try router.dbQueue.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT command_id FROM commands WHERE command_id IN (?,?) ORDER BY rowid", arguments: [note, edit]), [note, edit])
        }
        router.observeWriteAdmission {}
    }

    func testLockedBootstrapRechecksCredentialAndCurrentGeneration() throws {
        try coordinator.router.backupWrites.beginCapture()
        for token: String? in [nil, "wrong-credential"] {
            refuses("CONNECTION_REPAIR_REQUIRED") {
                try self.coordinator.bootstrapVerifiedWorkspace([:], native: self.native(), readCredential: { _ in token })
            }
        }
        enrollment.generation = "uncommitted-generation"
        coordinator.enrollments[enrollment.installation] = enrollment
        refuses("CONNECTION_REPAIR_REQUIRED") { try self.bootstrap() }
    }

    func testLockedBootstrapRejectsChangedBindingAndRole() throws {
        try coordinator.router.backupWrites.beginCapture()
        let original = enrollment!
        enrollment.workspace = root.appendingPathComponent("foreign").path
        coordinator.enrollments[enrollment.installation] = enrollment
        refuses("BINDING_CHANGED") { try self.bootstrap() }
        enrollment = original; enrollment.role = "assistant"
        coordinator.enrollments[enrollment.installation] = enrollment
        refuses("CONNECTION_REPAIR_REQUIRED") { try self.bootstrap() }
    }

    func testLockedBootstrapRejectsRevokedCanonicalSession() throws {
        let session = try XCTUnwrap(coordinator.router.connectionSession(sessionID: enrollment.sessionID, project: project, caller: owner))
        _ = try coordinator.router.handle(method: "session_update", params: ["command_id": UUID().uuidString, "project_id": project!,
            "session_id": enrollment.sessionID, "expected_revision": session["revision"]!, "state": "revoked"], caller: owner)
        try coordinator.router.backupWrites.beginCapture()
        refuses("CONNECTION_REVOKED") { try self.bootstrap() }
    }

    func testLockedBootstrapDefersNewEnrollmentRepairAndHostRotationWithoutPreparingAuthority() throws {
        try coordinator.router.backupWrites.beginCapture()
        refuses("BACKUP_SERVICE_CALL_DEFERRED") { try self.bootstrap(self.native(session: UUID().uuidString)) }
        refuses("BACKUP_SERVICE_CALL_DEFERRED") { try self.bootstrap(self.native(domain: "different-host-domain")) }
        var missing = enrollment!
        missing.sessionID = UUID().uuidString; missing.nativeSessionID = missing.sessionID
        let identity = SHA256.hash(data: Data("codex|\(missing.sessionID)|\(project!)".utf8)).map { String(format: "%02x", $0) }.joined()
        missing.installation = "auto-codex-" + identity.prefix(40)
        coordinator.enrollments[missing.installation] = missing
        refuses("BACKUP_SERVICE_CALL_DEFERRED") { try self.bootstrap(self.native(session: missing.sessionID)) }
        XCTAssertEqual(coordinator.enrollments.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.enrollmentFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.router.root.appendingPathComponent("backup-write-queue").path), "No queued registration can outlive a failed bootstrap")
    }
}
