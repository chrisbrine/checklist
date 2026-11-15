import XCTest
import CryptoKit
import GRDB
import ChecklistIPC
import ChecklistBridges
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

    func testNewEnrollmentStillRejectsCanonicalSessionWhenLocalEnrollmentIsMissing() throws {
        let original = try coordinator.router.connectionSession(sessionID:enrollment.sessionID,project:project,caller:owner)
        coordinator.enrollments.removeValue(forKey:enrollment.installation)
        refuses("SESSION_ID_CONFLICT") { try self.bootstrap() }
        XCTAssertTrue(coordinator.enrollments.isEmpty)
        XCTAssertEqual(try coordinator.router.connectionSession(sessionID:enrollment.sessionID,project:project,caller:owner)?["installation"] as? String,original?["installation"] as? String)
        let fresh = try bootstrap(native(session:UUID().uuidString))
        XCTAssertTrue(fresh.changed)
        XCTAssertEqual(coordinator.enrollments.count,1)
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

    func testWorkerDeferralReportedAfterBackupUnlockResumesWithoutAnotherEvent() throws {
        let coordinator = coordinator!, resumed = expectation(description: "Late worker resumes after completed unlock")
        try coordinator.router.backupWrites.beginCapture()
        coordinator.router.backupWrites.endBackup(router: coordinator.router)
        // Drain the only unlock notification before the worker reports its
        // earlier refusal. A later notification must not be needed to reply.
        coordinator.queue.sync {}
        coordinator.queue.sync {
            XCTAssertFalse(coordinator.router.writeAdmissionStatus["locked"] as? Bool == true)
            coordinator.afterBackupWriteAdmission { resumed.fulfill() }
            XCTAssertTrue(coordinator.backupDeferredCalls.isEmpty)
        }
        wait(for: [resumed], timeout: 10)
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
        // Fixture setup executes the domain handler directly; the service wire
        // command now returns an operation (covered by CommandOperationServiceTests).
        let attachment = try XCTUnwrap(try router.executeBackupQueuedWrite(method: "attachment_add", params: ["command_id": UUID().uuidString,
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
            ("attachment_read", ["project_id": project!, "attachment_id": attachment["id"]!, "representation": "metadata"]),
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
                // Metadata remains a short synchronous read during capture. Original
                // bytes use operation acceptance and are qualified separately.
                XCTAssertEqual((reply["data"] as? [String: Any])?["id"] as? String, attachment["id"] as? String)
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

    private func prepareCurrentReader() {
        enrollment.identityVerification = "native_process_verified_thread_observed"
        enrollment.codexAppHostProven = true
        coordinator.enrollments[enrollment.installation] = enrollment
    }

    private func currentBootstrap(_ native: Coordinator.VerifiedNativeWorkspace? = nil,
                                  context: [String: Any] = [:], credential: String? = nil) throws -> Coordinator.BootstrapResult {
        try coordinator.bootstrapVerifiedWorkspace(context, native: native ?? self.native(),
            readCredential: { _ in credential ?? self.credential }, currentConnectionOnly: true)
    }

    private func requiresNativeWriter(_ body: () throws -> Coordinator.BootstrapResult,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try JSONEncoder().encode(coordinator.enrollments)
        let session = try coordinator.router.connectionSession(sessionID: enrollment.sessionID, project: project, caller: owner)
        let canonical = try session.map { try JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }
        var inspections = 0
        coordinator.nativeLifecycle.inspect = { _ in
            inspections += 1
            return .init(process: .gone, registry: .absent, detail: "Must not inspect on the current path")
        }
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertTrue(error is NativeBootstrapRequiresWrite, "Unexpected error: \(error)", file: file, line: line)
        }
        let after = try JSONEncoder().encode(coordinator.enrollments)
        // JSONEncoder dictionary order is unspecified; compare objects instead.
        XCTAssertEqual(try JSONSerialization.jsonObject(with: before) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: after) as? NSDictionary, file: file, line: line)
        let current = try coordinator.router.connectionSession(sessionID: enrollment.sessionID, project: project, caller: owner)
        XCTAssertEqual(try current.map { try JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }, canonical, file: file, line: line)
        XCTAssertEqual(inspections, 0, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.enrollmentFile.path), file: file, line: line)
        XCTAssertTrue(coordinator.nativeLifecycle.deferredWrites.isEmpty, file: file, line: line)
    }

    func testCurrentBootstrapAndScopedReadPassResumptionAndDeferredWriteBacklogs() throws {
        prepareCurrentReader()
        let coordinator = coordinator!, enrollment = enrollment!, credential = credential, done = expectation(description: "Current bootstrap read")
        coordinator.queue.sync {
            coordinator.nativeLifecycle.resumptionInFlight = true
            coordinator.performNativeLifecycleWrite { /* must remain deferred */ }
            coordinator.enqueueNativeConnectionRequest { /* must remain FIFO */ }
        }
        defer {
            coordinator.queue.sync { coordinator.finishNativeBootstrapWork {} }
            for _ in 0..<4 { coordinator.queue.sync {} }
        }
        coordinator.queue.async {
            do {
                let result = try XCTUnwrap(coordinator.attemptCurrentNativeBootstrap({
                    try coordinator.bootstrapVerifiedWorkspace([:], native: .init(provider: "codex", session: enrollment.sessionID,
                        process: getpid(), executionDomain: enrollment.nativeExecutionDomain!, workspace: enrollment.workspace!),
                        readCredential: { _ in credential }, currentConnectionOnly: true)
                }, retry: { XCTFail("An unchanged current bootstrap must not join the FIFO") }))
                XCTAssertFalse(result.changed)
                let caller = Caller(role: "worker", installation: enrollment.installation + "/" + enrollment.generation,
                    projectIDs: enrollment.projectIDs, sessionID: enrollment.sessionID, workspace: enrollment.workspace,
                    executionDomain: enrollment.nativeExecutionDomain)
                let info = try coordinator.router.handle(method: "service_info", params: [:], caller: caller)
                XCTAssertNil(info["error"])
                XCTAssertEqual(coordinator.nativeLifecycle.connectionRequestOffset, 0)
                XCTAssertEqual(coordinator.nativeLifecycle.deferredWriteOffset, 0)
                XCTAssertTrue(coordinator.nativeLifecycle.resumptionInFlight)
            } catch { XCTFail("Current connection failed: \(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
        // Repeat at the drain boundary, while resumption is over but writes own admission.
        try coordinator.queue.sync {
            coordinator.nativeLifecycle.resumptionInFlight = false
            coordinator.nativeLifecycle.deferredWriteScheduled = true
            XCTAssertFalse(try currentBootstrap().changed)
            coordinator.nativeLifecycle.resumptionInFlight = true
            coordinator.nativeLifecycle.deferredWriteScheduled = false
        }
    }

    func testCurrentBootstrapDefersNewEnrollmentBeforeCreatingAuthority() throws {
        prepareCurrentReader()
        try requiresNativeWriter { try currentBootstrap(native(session: UUID().uuidString)) }
    }

    func testCurrentBootstrapDefersRegistrationRepairBeforeWriting() throws {
        prepareCurrentReader()
        let fresh = UUID().uuidString
        enrollment.sessionID = fresh; enrollment.nativeSessionID = fresh
        let digest = SHA256.hash(data: Data("codex|\(fresh)|\(project!)".utf8)).map { String(format: "%02x", $0) }.joined()
        coordinator.enrollments.removeValue(forKey: enrollment.installation)
        enrollment.installation = "auto-codex-" + digest.prefix(40)
        coordinator.enrollments[enrollment.installation] = enrollment
        try requiresNativeWriter { try currentBootstrap() }
    }

    func testCurrentBootstrapDefersClosureBeforeInspectingOrFencingTheOldHost() throws {
        prepareCurrentReader()
        try requiresNativeWriter { try currentBootstrap(native(domain: "codex:28680:6:0")) }
    }

    func testCurrentBootstrapDefersRevokedEnrollmentResumption() throws {
        prepareCurrentReader()
        enrollment.revoked = true
        coordinator.enrollments[enrollment.installation] = enrollment
        try requiresNativeWriter { try currentBootstrap() }
    }

    func testCurrentBootstrapDefersOwnerAllowedGenerationRotation() throws {
        prepareCurrentReader()
        let session = try XCTUnwrap(coordinator.router.connectionSession(sessionID: enrollment.sessionID, project: project, caller: owner))
        _ = try coordinator.router.handle(method: "connection_revoke", params: ["command_id": UUID().uuidString,
            "project_id": project!, "session_id": enrollment.sessionID, "installation": session["installation"]!, "expected_revision": session["revision"]!], caller: owner)
        let revoked = try XCTUnwrap(coordinator.router.connectionSession(sessionID: enrollment.sessionID, project: project, caller: owner))
        _ = try coordinator.router.handle(method: "connection_allow", params: ["command_id": UUID().uuidString,
            "project_id": project!, "session_id": enrollment.sessionID, "installation": revoked["installation"]!, "expected_revision": revoked["revision"]!], caller: owner)
        try requiresNativeWriter { try currentBootstrap() }
    }

    func testCurrentBootstrapRejectsStagedGenerationAndCredential() throws {
        prepareCurrentReader()
        refuses("CONNECTION_REPAIR_REQUIRED") { try currentBootstrap(credential: "wrong-credential") }
        enrollment.generation = "uncommitted-generation"
        coordinator.enrollments[enrollment.installation] = enrollment
        refuses("CONNECTION_REPAIR_REQUIRED") { try currentBootstrap() }
    }

    func testCurrentBootstrapRejectsCanonicalOwnerRevocation() throws {
        prepareCurrentReader()
        let session = try XCTUnwrap(coordinator.router.connectionSession(sessionID: enrollment.sessionID, project: project, caller: owner))
        _ = try coordinator.router.handle(method: "connection_revoke", params: ["command_id": UUID().uuidString,
            "project_id": project!, "session_id": enrollment.sessionID, "installation": session["installation"]!, "expected_revision": session["revision"]!], caller: owner)
        enrollment.generation = "staged-owner-revoked-generation"
        coordinator.enrollments[enrollment.installation] = enrollment
        coordinator.nativeLifecycle.resumptionInFlight = true
        defer { coordinator.nativeLifecycle.resumptionInFlight = false }
        refuses("CONNECTION_REVOKED") { try currentBootstrap() }
    }

    private func codexProof(_ proven: Bool) throws {
        enrollment.codexAppHostProven = false
        enrollment.nativeExecutionDomain = "codex:24680:5:0"
        coordinator.enrollments[enrollment.installation] = enrollment
        var session = try XCTUnwrap(coordinator.router.connectionSession(sessionID: enrollment.sessionID, project: project, caller: owner))
        session["execution_domain"] = enrollment.nativeExecutionDomain
        try coordinator.router.dbQueue.write { try coordinator.router.save($0, session, type: "session") }
        coordinator.codexAppHostRestartEffects = .init(available: true, process: { _ in .running },
            source: { _ in .init(host: .nativeApp, reason: .sourceVscode, source: "vscode") }, scan: { _ in nil },
            signed: { _ in true }, holds: { _ in proven }, pauseBeforeRetry: {})
    }

    func testCurrentBootstrapDefersCodexProofEnrichment() throws {
        prepareCurrentReader()
        try codexProof(true)
        try requiresNativeWriter { try currentBootstrap() }
    }

    func testCurrentBootstrapWithoutNewCodexProofStillPassesTheWriter() throws {
        prepareCurrentReader()
        try codexProof(false)
        coordinator.nativeLifecycle.resumptionInFlight = true
        defer { coordinator.nativeLifecycle.resumptionInFlight = false }
        XCTAssertFalse(try currentBootstrap().changed)
        XCTAssertEqual(coordinator.enrollments[enrollment.installation]?.codexAppHostProven, false)
        XCTAssertTrue(coordinator.nativeLifecycle.deferredWrites.isEmpty)
    }

    func testCurrentBootstrapDefersRelayGrantGenerationChanges() throws {
        prepareCurrentReader()
        try requiresNativeWriter { try currentBootstrap(context: ["mode": "assistant_relay", "project_ref": project!]) }
    }

    func testCurrentBootstrapDefersChangedIdentityMetadata() throws {
        prepareCurrentReader()
        for change in 0..<4 {
            let original = enrollment!
            switch change {
            case 0: enrollment.automatic = false
            case 1: enrollment.nativeSessionID = UUID().uuidString
            case 2: enrollment.identityVerification = "unproved"
            default: enrollment.role = "assistant"
            }
            coordinator.enrollments[enrollment.installation] = enrollment
            try requiresNativeWriter { try currentBootstrap() }
            enrollment = original; coordinator.enrollments[enrollment.installation] = original
        }
    }

    func testPeerVerifiesFreshBootstrapBeforeWaitingForResumption() throws {
        let coordinator = coordinator!, done = expectation(description: "Native peer rejected promptly")
        let connection = NSXPCConnection(machServiceName: "org.checklist.synthetic.unconnected")
        defer { connection.invalidate() }
        let peer = Peer(coordinator: coordinator, connection: connection)
        coordinator.queue.sync { coordinator.nativeLifecycle.resumptionInFlight = true }
        defer { coordinator.queue.sync { coordinator.finishNativeBootstrapWork {} } }
        let request = try JSONSerialization.data(withJSONObject: ["method": "connection_bootstrap", "params": [:]])
        peer.execute(request) { bytes in
            let reply = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
            XCTAssertEqual((reply?["error"] as? [String: Any])?["code"] as? String, "NATIVE_CLIENT_REQUIRED")
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
        coordinator.queue.sync { XCTAssertTrue(coordinator.nativeLifecycle.connectionRequests.isEmpty) }
    }


    /// Frozen pre-N2 current-enrollment branch, after project/installation
    /// resolution. Generated inputs keep host proof and native identity current;
    /// this reference never enters the legacy registration/resumption branches.
    private func legacyCurrentBootstrap(_ existing: Enrollment, credential: String) throws -> Coordinator.BootstrapResult {
        let session = try coordinator.router.connectionSession(sessionID: existing.sessionID, project: project, caller: owner)
        if let session {
            guard session["owner_revoked"] as? Bool != true else {
                throw ChecklistError("CONNECTION_REVOKED", "The owner disconnected this conversation in Checklist. It stays refused until the owner selects Allow again on its ticket.")
            }
        }
        guard existing.sessionID == enrollment.sessionID, existing.workspace == root.path,
              existing.provider == "codex", existing.projectIDs == [project!] else {
            throw ChecklistError("BINDING_CHANGED", "The registered workspace changed. Review this connection in Checklist before reconnecting.")
        }
        guard existing.assistantRelay != true else {
            throw ChecklistError("CONNECTION_MODE_MISMATCH", "This native thread cannot change its access role.")
        }
        guard SHA256.hash(data: Data(credential.utf8)).map({ String(format: "%02x", $0) }).joined() == existing.tokenDigest else {
            throw ChecklistError("CONNECTION_REPAIR_REQUIRED", "This thread's saved credential does not match its enrollment. Repair it in Checklist.")
        }
        if let session {
            guard !["revoked", "ended"].contains(session["state"] as? String ?? "") else {
                throw ChecklistError("CONNECTION_REVOKED", "This thread was ended or disconnected. Its authority cannot be resumed automatically.")
            }
            guard ConnectionCommit.registrationMatches(session, sessionID: existing.sessionID, installation: existing.installation,
                generation: existing.generation, role: existing.role, provider: existing.provider, projects: existing.projectIDs) else {
                throw ChecklistError("CONNECTION_REPAIR_REQUIRED", "This prepared connection does not match its committed session. Repair it in Checklist.")
            }
        }
        try coordinator.requireCommittedRegistration(existing, project: project, caller: owner)
        return .init(reply: coordinator.connectionResult(existing, project: project), changed: false)
    }

    func testGeneratedCurrentBootstrapMatchesLegacyRepliesAndRefusals() throws {
        prepareCurrentReader()
        let baseline = enrollment!
        let originalSession = try XCTUnwrap(coordinator.router.connectionSession(sessionID: baseline.sessionID, project: project, caller: owner))
        func outcome(_ body: () throws -> Coordinator.BootstrapResult) throws -> Data {
            let value: [String: Any]
            do {
                let result = try body()
                value = ["reply": result.reply, "changed": result.changed]
            } catch let error as ChecklistError { value = ["code": error.code, "message": error.message] }
            catch let error as CoreError { value = ["code": error.code, "message": error.message] }
            return try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        }
        for flags in 0..<256 {
            var existing = baseline, session = originalSession
            let token = flags & 1 == 0 ? credential : "wrong-generated-credential"
            if flags & 2 != 0 { existing.generation = "uncommitted-generated" }
            if flags & 4 != 0 { session["state"] = flags & 1 == 0 ? "revoked" : "ended" }
            if flags & 8 != 0 { session["owner_revoked"] = true }
            if flags & 16 != 0 { existing.workspace = root.appendingPathComponent("foreign").path }
            if flags & 32 != 0 { existing.projectIDs = ["foreign-project"] }
            if flags & 64 != 0 { session["installation"] = "foreign-installation/generation" }
            if flags & 128 != 0 { session["provider"] = "claude" }
            coordinator.enrollments[existing.installation] = existing
            try coordinator.router.dbQueue.write { try coordinator.router.save($0, session, type: "session") }
            let old = try outcome { try legacyCurrentBootstrap(existing, credential: token) }
            let current = try outcome { try currentBootstrap(credential: token) }
            XCTAssertEqual(old, current, "Generated current-bootstrap flags \(flags)")
        }
        coordinator.enrollments[baseline.installation] = baseline
        try coordinator.router.dbQueue.write { try coordinator.router.save($0, originalSession, type: "session") }
    }


    private final class BootstrapTrace: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func add(_ value: String) { lock.withLock { entries.append(value) } }
        var values: [String] { lock.withLock { entries } }
    }

    func testStateChangingBootstrapRetryKeepsFIFOAndRepliesAfterCommittedRegistration() throws {
        prepareCurrentReader()
        let coordinator = coordinator!, root = root!, project = project!, trace = BootstrapTrace()
        let sid = UUID().uuidString, done = expectation(description: "New enrollment committed")
        let native = Coordinator.VerifiedNativeWorkspace(provider: "codex", session: sid, process: getpid(),
            executionDomain: "codex:24680:5:0", workspace: root.path)
        try coordinator.queue.sync {
            coordinator.nativeLifecycle.resumptionInFlight = true
            coordinator.performNativeLifecycleWrite { trace.add("deferred-write") }
            coordinator.enqueueNativeConnectionRequest { trace.add("earlier-bootstrap") }
            let result = try coordinator.attemptCurrentNativeBootstrap({
                try coordinator.bootstrapVerifiedWorkspace([:], native: native, readCredential: coordinator.credentials.read,
                    currentConnectionOnly: true)
            }, retry: {
                do {
                    let result = try coordinator.bootstrapVerifiedWorkspace([:], native: native, readCredential: coordinator.credentials.read)
                    XCTAssertTrue(result.changed)
                    let data = try XCTUnwrap(result.reply["data"] as? [String: Any])
                    let installation = try XCTUnwrap(data["installation"] as? String)
                    let current = try XCTUnwrap(coordinator.enrollments[installation])
                    try coordinator.requireCommittedRegistration(current, project: project,
                        caller: Caller(role: "owner", installation: "fifo-test", projectIDs: []))
                    trace.add("reply-after-commit")
                } catch { trace.add("unexpected-error: \(error)") }
                done.fulfill()
            })
            XCTAssertNil(result)
            XCTAssertEqual(coordinator.nativeLifecycle.connectionRequests.count, 2)
            XCTAssertEqual(coordinator.nativeLifecycle.connectionRequestOffset, 0)
            XCTAssertEqual(coordinator.enrollments.count, 1)
            XCTAssertTrue(trace.values.isEmpty)
            coordinator.finishNativeBootstrapWork {}
        }
        wait(for: [done], timeout: 10)
        coordinator.queue.sync {}
        XCTAssertEqual(trace.values, ["deferred-write", "earlier-bootstrap", "reply-after-commit"])
        XCTAssertFalse(coordinator.nativeLifecycle.connectionRequestScheduled)
    }

    func testQueuedBootstrapRechecksOwnerRevocationBeforeProofPersistence() throws {
        prepareCurrentReader()
        try codexProof(true)
        let coordinator = coordinator!, native = native(), project = project!, enrollment = enrollment!, owner = owner, credential = credential
        let trace = BootstrapTrace(), done = expectation(description: "Queued bootstrap reverified")
        try coordinator.queue.sync {
            coordinator.nativeLifecycle.resumptionInFlight = true
            coordinator.enqueueNativeConnectionRequest {
                do {
                    let session = try XCTUnwrap(coordinator.router.connectionSession(sessionID: enrollment.sessionID, project: project, caller: owner))
                    _ = try coordinator.router.handle(method: "connection_revoke", params: ["command_id": UUID().uuidString,
                        "project_id": project, "session_id": enrollment.sessionID, "installation": session["installation"]!,
                        "expected_revision": session["revision"]!], caller: owner)
                    trace.add("owner-revoked")
                } catch { trace.add("unexpected-revoke: \(error)") }
            }
            XCTAssertNil(try coordinator.attemptCurrentNativeBootstrap({
                try coordinator.bootstrapVerifiedWorkspace([:], native: native, readCredential: { _ in credential },
                    currentConnectionOnly: true)
            }, retry: {
                do {
                    _ = try coordinator.bootstrapVerifiedWorkspace([:], native: native, readCredential: { _ in credential })
                    trace.add("unexpected-authority")
                } catch let error as ChecklistError { trace.add(error.code) }
                catch { trace.add("unexpected-error: \(error)") }
                done.fulfill()
            }))
            coordinator.finishNativeBootstrapWork {}
        }
        wait(for: [done], timeout: 10)
        coordinator.queue.sync {
            XCTAssertEqual(coordinator.enrollments[enrollment.installation]?.codexAppHostProven, false)
            XCTAssertTrue(coordinator.nativeLifecycle.deferredWrites.isEmpty)
        }
        XCTAssertEqual(trace.values, ["owner-revoked", "CONNECTION_REVOKED"])
    }

    func testCurrentAdmissionDoesNotQueueAnAuthenticationFailure() throws {
        prepareCurrentReader()
        coordinator.queue.sync {
            refuses("CONNECTION_REPAIR_REQUIRED") {
                try coordinator.attemptCurrentNativeBootstrap({ try currentBootstrap(credential: "invalid") }, retry: {
                    XCTFail("An authentication refusal must never retry as a state change")
                }) as Any
            }
            XCTAssertTrue(coordinator.nativeLifecycle.connectionRequests.isEmpty)
        }
    }

}
