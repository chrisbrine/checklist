import XCTest
import CryptoKit
import ChecklistProviders
import ChecklistBridges
import ChecklistIPC
import GRDB
@testable import ChecklistCore
@testable import ChecklistService

/// Private stores and fake evidence only. No process, Codex store, socket or host I/O.
final class CodexAppHostRestartTests: XCTestCase {
    private typealias JSON = [String: Any]
    private final class Evidence: @unchecked Sendable {
        var oldState: NativeLifecycleObservation.ProcessState = .gone
        var newState: NativeLifecycleObservation.ProcessState = .running
        var source = CodexQueueObservation(host: .nativeApp, reason: .sourceVscode, source: "vscode")
        var host = CodexProcess(pid: 24681, executable: "/Applications/Synthetic.app/Contents/MacOS/codex", role: .appHost)
        var extra: [CodexProcess] = []
        var extraHosts: [CodexProcess] = []
        var blockers: [CodexProcessBlocker] = []
        var scanUnavailable = false
        var incompleteNonCodex = 0
        var holds = true, signed = true, unreadable = false, execClaim = false
        var scans = 0, processReads = 0
        var onScan: (() throws -> Void)?
        var scanFailure: Error?
        var pauses = 0
        var onPause: (() throws -> Void)?
    }
    private let evidence = Evidence()
    private var root: URL!, coordinator: Coordinator!, enrollment: Enrollment!, project: String!
    private let owner = Caller(role: "owner", installation: "restart-fixture-owner", projectIDs: [])
    private let token = "synthetic-restart-credential"
    private var router: CommandRouter { coordinator.router }

    override func setUpWithError() throws {
        // The shared test storage root: CHECKLIST_TEST_STORAGE_ROOT when it is set, else the temporary folder.
        let parent = SlotNativeRelayTests.storageRoot().path
        root = URL(fileURLWithPath: parent).appendingPathComponent("codex-restart-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath().standardizedFileURL
        let router = try CommandRouter(root: root.appendingPathComponent("store"))
        let instance = try ChecklistInstance(home: root, environment: [:])
        let credentials = InstallationCredentialStore(root: root, instance: instance, legacyRead: nil)
        coordinator = Coordinator(router: router, enrollmentFile: root.appendingPathComponent("connections.json"),
            startBackgroundWork: false, credentials: credentials, instance: instance)
        project = try call("project_create", ["name": "Restart fixture", "key_prefix": "RF", "root_path": root.path])["id"] as? String
        let sid = UUID().uuidString.lowercased()
        let hash = SHA256.hash(data: Data("codex|\(sid)|\(project!)".utf8)).map { String(format: "%02x", $0) }.joined()
        enrollment = Enrollment(installation: "auto-codex-" + hash.prefix(40), name: "Synthetic app thread", provider: "codex",
            role: "worker", projectIDs: [project], sessionID: sid, workspace: root.path, profileID: nil,
            tokenDigest: SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined(), generation: "original-generation")
        enrollment.automatic = true; enrollment.nativeSessionID = sid
        enrollment.nativeExecutionDomain = "codex:24680:5:0"; enrollment.codexAppHostProven = true
        enrollment.identityVerification = CodexProviderPlugin().nativeHost?.identityVerification
        enrollment.nativeRelayRegistrationStore = "retained-registration-origin"
        _ = try call("session_register", ["project_id": project!, "project_ids": [project!], "session_id": sid,
            "installation": enrollment.installation + "/" + enrollment.generation, "provider": "codex", "role": "worker",
            "workspace": root.path, "execution_domain": enrollment.nativeExecutionDomain!])
        coordinator.enrollments[enrollment.installation] = enrollment
        try coordinator.saveEnrollments(); try credentials.write(enrollment.installation, token)
        coordinator.codexAppHostRestartEffects = .init(available: true, process: { [evidence] registration in
            evidence.processReads += 1
            return registration.startSeconds == 5 ? evidence.oldState : evidence.newState
        }, source: { [evidence] _ in evidence.source }, scan: { [evidence] _ in
            evidence.scans += 1
            do { try evidence.onScan?() } catch { evidence.scanFailure = error; return nil }
            if evidence.scanUnavailable { return nil }
            return .init(hosts: [evidence.host] + evidence.extraHosts, holders: (evidence.holds ? [evidence.host] : []) + evidence.extra,
                         unreadable: evidence.unreadable, execClaim: evidence.execClaim, incompleteNonCodex: evidence.incompleteNonCodex, blockers: evidence.blockers)
        }, signed: { [evidence] _ in evidence.signed }, holds: { [evidence] _ in evidence.holds }, pauseBeforeRetry: { [evidence] in
            evidence.pauses += 1
            do { try evidence.onPause?() } catch { evidence.scanFailure = error }
        })
    }
    override func tearDownWithError() throws {
        for _ in 0..<2 { coordinator?.storageQueue.sync {}; coordinator?.queue.sync {} }
        coordinator?.queue.sync { coordinator.storageWake?.cancel(); coordinator.workHealthWake?.cancel() }
        try coordinator?.router.closeStore(); coordinator = nil
        if let root { try FileManager.default.removeItem(at: root) }
    }
    @discardableResult private func call(_ method: String, _ input: JSON, _ caller: Caller? = nil) throws -> JSON {
        var input = input
        if !CommandRouter.readMethods.contains(method) { input["command_id"] = UUID().uuidString }
        return try router.handle(method: method, params: input, caller: caller ?? owner)["data"] as! JSON
    }
    private func worker(_ value: Enrollment? = nil) -> Caller {
        let e = value ?? enrollment!
        return Caller(role: "worker", installation: e.installation + "/" + e.generation, projectIDs: [project],
            sessionID: e.sessionID, workspace: root.path, executionDomain: e.nativeExecutionDomain)
    }
    @discardableResult private func bootstrap() throws -> Coordinator.BootstrapResult {
        try coordinator.bootstrapVerifiedWorkspace([:], native: .init(provider: "codex", session: enrollment.sessionID,
            process: evidence.host.pid, executionDomain: "codex:\(evidence.host.pid):6:0", workspace: root.path),
            readCredential: coordinator.credentials.read)
    }
    private func session() throws -> JSON { try XCTUnwrap(router.connectionSession(sessionID: enrollment.sessionID, project: project, caller: owner)) }
    private func refuses(_ code: String = "NATIVE_SESSION_MISMATCH", contains text: String, _ body: (() throws -> Void)? = nil,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body?() ?? { _ = try self.bootstrap() }(), file: file, line: line) { error in
            XCTAssertEqual((error as? ChecklistError)?.code ?? (error as? CoreError)?.code, code, file: file, line: line)
            XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription, file: file, line: line)
        }
    }
    private func claimedTask() throws -> (JSON, JSON) {
        let epic = try call("epic_create", ["project_id": project!, "name": "Restart"])
        var task = try call("task_create", ["project_id": project!, "epic_id": epic["id"]!, "title": "Restart work", "brief": "Synthetic only"])
        task = try call("task_edit", ["project_id": project!, "task_id": task["id"]!, "expected_revision": task["revision"]!, "patch": ["readiness": "ready"]])
        return (task, try call("work_claim", ["project_id": project!, "task_id": task["id"]!, "expected_revision": task["revision"]!,
            "file_scopes": [["path": "Sources", "access": "write"]]], worker()))
    }
    func testGoneHostReleasesWorkFencesOldAuthorityAndDeliversNewGenerationNote() throws {
        let (task, attempt) = try claimedTask(), before = try session()
        let note = try call("message_send", ["project_id": project!, "task_id": task["id"]!, "body": "Before restart"])
        let oldDelivery = try XCTUnwrap((note["deliveries"] as? [JSON])?.first)
        let result = try bootstrap()
        XCTAssertTrue(result.changed)
        let resumed = try XCTUnwrap(coordinator.enrollments[enrollment.installation]), after = try session()
        XCTAssertNotEqual(resumed.generation, enrollment.generation)
        XCTAssertNotEqual(after["authorization_generation"] as? String, before["authorization_generation"] as? String)
        XCTAssertEqual(after["id"] as? String, before["id"] as? String)
        XCTAssertEqual(resumed.installation, enrollment.installation)
        XCTAssertEqual(resumed.nativeRelayRegistrationStore, "retained-registration-origin")
        XCTAssertTrue(resumed.codexAppHostProven == true)
        XCTAssertNotEqual(try coordinator.credentials.read(resumed.installation), token)
        let released = try router.dbQueue.read { try router.record($0, attempt["id"] as! String, type: "attempt") }
        XCTAssertEqual(released["state"] as? String, "released"); XCTAssertNil(released["token_hash"])
        let receipt = try call("message_delivery_list", ["project_id": project!, "task_id": task["id"]!, "message_id": note["id"]!])
        let fenced = try XCTUnwrap((receipt["deliveries"] as? [JSON])?.first { $0["id"] as? String == oldDelivery["id"] as? String })
        XCTAssertEqual(fenced["state"] as? String, "fenced"); XCTAssertNil(fenced["acknowledged_at"])
        let closure = try router.dbQueue.read { try router.record($0, released["native_closure_ref"] as! String, type: "native_closure") }
        XCTAssertEqual(closure["evidence_basis"] as? String, "codex_app_host_restart")
        XCTAssertEqual(closure["registry_state"] as? String, "not_applicable")
        refuses("STALE_CLAIM", contains: "claim") {
            _ = try self.call("work_checkpoint", ["project_id": self.project!, "attempt_id": attempt["id"]!,
                "claim_token": attempt["claim_token"]!, "progress": "Old token"], self.worker(resumed))
        }
        let newNote = try call("message_send", ["project_id": project!, "task_id": task["id"]!, "body": "After restart",
            "recipient": ["kind": "session", "session_id": resumed.sessionID]])
        let inbox = try call("session_inbox", ["project_id": project!], worker(resumed))
        XCTAssertTrue((inbox["deliveries"] as? [JSON] ?? []).contains { $0["message_id"] as? String == newNote["id"] as? String })
        let newReceipt = try XCTUnwrap((newNote["deliveries"] as? [JSON])?.first)
        XCTAssertEqual(newReceipt["recipient_authorization_generation"] as? String, after["authorization_generation"] as? String)
        let events = try call("history_list", ["project_id": project!, "task_id": task["id"]!])["events"] as! [JSON]
        XCTAssertTrue(events.contains { $0["kind"] as? String == "work_released_native_closure" })
        XCTAssertFalse(events.contains { ($0["kind"] as? String ?? "").contains("review_pass") })
    }
    func testPIDReusedWithNewStartCanResume() throws {
        evidence.oldState = .replaced
        evidence.host = .init(pid: 24680, executable: evidence.host.executable, role: .appHost)
        XCTAssertTrue(try bootstrap().changed)
    }
    func testRunningAndUnknownOldProcessRefuseWithoutClosing() throws {
        for state in [NativeLifecycleObservation.ProcessState.running, .unknown] {
            evidence.oldState = state
            refuses(contains: state == .running ? "still identify a running process" : "lookup is unreadable or incomplete")
            XCTAssertEqual(try session()["state"] as? String, "connected")
            XCTAssertEqual(try coordinator.credentials.read(enrollment.installation), token)
        }
    }
    func testNewHostMustPositivelyHoldAndKeepItsStartIdentity() throws {
        evidence.holds = false; refuses(contains: "positively hold")
        evidence.holds = true; evidence.newState = .unknown; refuses(contains: "PID/start identity")
        evidence.newState = .running; evidence.signed = false; refuses(contains: "signature")
    }
    func testSecondExecNonHostOrAppHolderRefuses() throws {
        for role in [CodexProcessRole.exec, .unclassified, .appHost] {
            evidence.extra = [.init(pid: 24682, executable: "/synthetic/other", role: role)]
            refuses(contains: role == .exec ? "Another Codex process" : "no other process")
            XCTAssertEqual(try session()["state"] as? String, "connected")
        }
    }
    func testProcessNamingThreadOrLastAndUnreadableCodexRefuse() throws {
        evidence.execClaim = true; refuses(contains: "names its thread or --last")
        evidence.execClaim = false; evidence.unreadable = true; refuses(contains: "unreadable or incomplete")
    }
    func testExecSourceAndUnprovenOriginalAppKeepPartOneRefusal() throws {
        evidence.source = .init(host: .exec, reason: .sourceExec, source: "exec")
        refuses(contains: "source=vscode")
        evidence.source = .init(host: .nativeApp, reason: .sourceVscode, source: "vscode")
        coordinator.enrollments[enrollment.installation]?.codexAppHostProven = false
        refuses(contains: "old thread-to-host binding")
        XCTAssertEqual(evidence.scans, 0)
    }
    func testOwnerRevocationPrecedesEvidence() throws {
        let current = try session()
        _ = try call("connection_revoke", ["project_id": project!, "session_id": enrollment.sessionID,
            "installation": current["installation"]!, "expected_revision": current["revision"]!])
        refuses("CONNECTION_REVOKED", contains: "owner")
        XCTAssertEqual(evidence.processReads, 0)
    }
    func testChangedWorkspaceRefusesBeforeClosureOrEvidence() throws {
        coordinator.enrollments[enrollment.installation]?.workspace = root.appendingPathComponent("changed").path
        refuses("BINDING_CHANGED", contains: "workspace changed")
        XCTAssertEqual(evidence.processReads, 0)
        XCTAssertEqual(try session()["state"] as? String, "connected")
    }
    func testInterruptedCommitRestoresFencedEnrollmentAndCredentialThenCanRetry() throws {
        let (_, attempt) = try claimedTask()
        evidence.onScan = { [self] in
            if evidence.scans == 5 {
                XCTAssertNotEqual(try coordinator.credentials.read(enrollment.installation), token, "New credential prepared before final binding recheck")
                evidence.unreadable = true
            }
        }
        refuses(contains: "unreadable or incomplete")
        XCTAssertNil(evidence.scanFailure)
        XCTAssertEqual(coordinator.enrollments[enrollment.installation]?.generation, enrollment.generation)
        XCTAssertTrue(coordinator.enrollments[enrollment.installation]?.revoked == true)
        XCTAssertEqual(try coordinator.credentials.read(enrollment.installation), token)
        XCTAssertEqual(try session()["state"] as? String, "ended")
        XCTAssertEqual(try router.dbQueue.read { try router.record($0, attempt["id"] as! String, type: "attempt") }["state"] as? String, "released")
        evidence.onScan = nil; evidence.unreadable = false
        XCTAssertTrue(try bootstrap().changed)
    }
    func testSourceWriterKeepsClosurePendingUntilStopped() throws {
        let (task, attempt) = try claimedTask(), job = UUID().uuidString
        try router.dbQueue.write { db in
            try router.save(db, ["id": job, "project_id": project!, "task_id": task["id"]!, "attempt_id": attempt["id"]!,
                "state": "interrupted", "revision": 1], type: "source_execution")
        }
        refuses("NATIVE_CLOSURE_PENDING", contains: "must stop")
        XCTAssertEqual(try session()["state"] as? String, "ended")
        XCTAssertTrue(coordinator.enrollments[enrollment.installation]?.revoked == true)
        XCTAssertEqual(try coordinator.credentials.read(enrollment.installation), token)
        try router.dbQueue.write { db in
            var execution = try router.record(db, job, type: "source_execution"); execution["state"] = "stopped"
            try router.save(db, router.revised(execution), type: "source_execution")
        }
        XCTAssertTrue(try bootstrap().changed)
    }
    func testCrashStagedLocalGenerationStaysRefusedWithOldWorkReleased() throws {
        let (_, attempt) = try claimedTask()
        evidence.onScan = { [self] in if evidence.scans == 5 { evidence.unreadable = true } }
        refuses(contains: "unreadable or incomplete")
        evidence.onScan = nil; evidence.unreadable = false
        // Model process loss after the local writes but before the Core commit:
        // no rollback executes. The staged credential/enrollment is not authority.
        var staged = coordinator.enrollments[enrollment.installation]!
        staged.generation = "uncommitted-crash-generation"; staged.nativeExecutionDomain = "codex:24681:6:0"; staged.revoked = false
        staged.tokenDigest = SHA256.hash(data: Data("staged-token".utf8)).map { String(format: "%02x", $0) }.joined()
        coordinator.enrollments[staged.installation] = staged
        try coordinator.saveEnrollments(); try coordinator.credentials.write(staged.installation, "staged-token")
        refuses("CONNECTION_REVOKED", contains: "ended or disconnected")
        XCTAssertEqual(try session()["state"] as? String, "ended")
        XCTAssertEqual(try router.dbQueue.read { try router.record($0, attempt["id"] as! String, type: "attempt") }["state"] as? String, "released")
    }

    func testForeignWritableChildKeepsRestartPendingUntilExplicitRelease() throws {
        let (task, attempt) = try claimedTask(), childID = UUID().uuidString
        _ = try call("session_register", ["project_id": project!, "session_id": childID, "installation": "synthetic-child",
            "provider": "codex", "role": "worker", "workspace": root.path, "execution_domain": "codex:25000:5:0"])
        let child = Caller(role: "worker", installation: "synthetic-child", projectIDs: [project], sessionID: childID,
            workspace: root.path, executionDomain: "codex:25000:5:0")
        let offer = try call("work_delegate", ["project_id": project!, "attempt_id": attempt["id"]!,
            "claim_token": attempt["claim_token"]!, "child_session_id": childID,
            "file_scopes": [["path": "Sources/Child.swift", "access": "write"]]], worker())
        let accepted = try call("work_child_accept", ["project_id": project!, "delegation_id": offer["id"]!], child)
        refuses("NATIVE_CLOSURE_PENDING", contains: "must stop")
        XCTAssertEqual(try coordinator.credentials.read(enrollment.installation), token)
        let retained = try router.dbQueue.read { try router.record($0, attempt["id"] as! String, type: "attempt") }
        XCTAssertEqual(retained["state"] as? String, "active")
        XCTAssertEqual(retained["native_closure_blocker"] as? String, "CHILD_WRITERS_ACTIVE")
        _ = try call("work_release", ["project_id": project!, "attempt_id": accepted["id"]!,
            "claim_token": accepted["claim_token"]!, "reason": "Synthetic child stopped"], child)
        XCTAssertTrue(try bootstrap().changed)
        XCTAssertNil(try call("task_get", ["project_id": project!, "task_id": task["id"]!])["active_attempt_id"])
    }

    func testAppRegistrationProofDoesNotRequireEnabledQueueTransport() throws {
        XCTAssertFalse(coordinator.codexRoute.effects.enabled)
        XCTAssertTrue(coordinator.provesCodexAppRegistration(session: enrollment.sessionID, domain: "codex:24681:6:0"))
        evidence.source = .init(host: .exec, reason: .sourceExec, source: "exec")
        XCTAssertFalse(coordinator.provesCodexAppRegistration(session: enrollment.sessionID, domain: "codex:24681:6:0"))
    }

    func testRestartRecordsFinalIncompleteNonCodexCount() throws {
        evidence.incompleteNonCodex = 2
        evidence.onScan = { [evidence] in if evidence.scans == 5 { evidence.incompleteNonCodex = 7 } }
        XCTAssertTrue(try bootstrap().changed)
        let data = try XCTUnwrap(router.dbQueue.read { try String.fetchOne($0,
            sql: "SELECT data FROM events WHERE kind='native_session_resumed' AND entity_id=? ORDER BY seq DESC LIMIT 1",
            arguments: [enrollment.sessionID]) })
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(data.utf8)) as? JSON)
        XCTAssertEqual(event["incomplete_non_codex_first"] as? Int, 7)
        XCTAssertEqual(event["incomplete_non_codex"] as? Int, 7, "Success records the final pair, not the pre-closure count")
    }

    func testCountDriftAlonePassesEveryStageAndRecordsBothFinalSamples() throws {
        evidence.onScan = { [evidence] in evidence.incompleteNonCodex = evidence.scans }
        XCTAssertTrue(try bootstrap().changed)
        XCTAssertEqual(evidence.scans, 6, "All three stages compare pairs despite count drift")
        XCTAssertEqual(evidence.pauses, 0)
        let data = try XCTUnwrap(router.dbQueue.read { try String.fetchOne($0,
            sql: "SELECT data FROM events WHERE kind='native_session_resumed' AND entity_id=? ORDER BY seq DESC LIMIT 1",
            arguments: [enrollment.sessionID]) })
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(data.utf8)) as? JSON)
        XCTAssertEqual(event["incomplete_non_codex_first"] as? Int, 5)
        XCTAssertEqual(event["incomplete_non_codex"] as? Int, 6)
    }

    func testRestartRefusesWhenHostSetChangesBetweenScans() throws {
        evidence.onScan = { [evidence] in
            if evidence.scans == 2 { evidence.extraHosts = [.init(pid: 999, executable: evidence.host.executable, role: .appHost)] }
        }
        refuses(contains: "holder scan or thread source changed")
        XCTAssertEqual(try session()["state"] as? String, "connected")
    }

    func testUnreadableRefusalReportsIncompleteNonCodexCount() throws {
        evidence.unreadable = true; evidence.incompleteNonCodex = 4
        refuses(contains: "incompleteNonCodex=4")
    }

    func testEveryVerifierEvidenceRefusalCarriesScopedRetryMarker() throws {
        let old = try XCTUnwrap(NativeLifecycleRegistration(provider: "codex", sessionID: enrollment.sessionID,
            executionDomain: "codex:24680:5:0", registryPath: nil))
        let new = try XCTUnwrap(NativeLifecycleRegistration(provider: "codex", sessionID: enrollment.sessionID,
            executionDomain: "codex:24681:6:0", registryPath: nil))
        for scenario in ["running", "unknown", "source", "nil_scan", "unreadable", "exec_claim", "exec_holder", "other_holder",
                         "no_hold", "signature", "new_identity", "changed_scan", "changed_source"] {
            evidence.oldState = .gone; evidence.newState = .running
            evidence.source = .init(host: .nativeApp, reason: .sourceVscode, source: "vscode")
            evidence.scanUnavailable = false; evidence.unreadable = false; evidence.execClaim = false
            evidence.holds = true; evidence.signed = true; evidence.extra = []; evidence.extraHosts = []; evidence.scans = 0; evidence.onScan = nil
            evidence.incompleteNonCodex = 7
            switch scenario {
            case "running": evidence.oldState = .running
            case "unknown": evidence.oldState = .unknown
            case "source": evidence.source = .init(host: .exec, reason: .sourceExec, source: "exec")
            case "nil_scan": evidence.scanUnavailable = true
            case "unreadable": evidence.unreadable = true
            case "exec_claim": evidence.execClaim = true
            case "exec_holder": evidence.extra = [.init(pid: 30000, executable: "/synthetic/codex", role: .exec)]
            case "other_holder": evidence.extra = [.init(pid: 30000, executable: "/synthetic/other", role: .unclassified)]
            case "no_hold": evidence.holds = false
            case "signature": evidence.signed = false
            case "new_identity": evidence.newState = .unknown
            case "changed_scan": evidence.onScan = { [evidence] in
                if evidence.scans == 2 { evidence.extraHosts = [.init(pid: 999, executable: "codex", role: .appHost)] }
            }
            default: evidence.onScan = { [evidence] in if evidence.scans == 2 { evidence.source = .init(host: .exec, reason: .sourceExec, source: "exec") } }
            }
            XCTAssertThrowsError(try coordinator.verifyCodexRestartHost(old: old, new: new), scenario) { error in
                XCTAssertTrue(CodexRestartRefusal.applies(error), "\(scenario): \(error)")
                XCTAssertTrue(error.localizedDescription.contains("incompleteNonCodex="))
            }
        }
    }

    func testBlockerRefusalNamesEveryProcessWithoutPathsArgumentsOrPrompt() throws {
        let script = CodexProcess(pid: 30001, executable: "/private/secret-folder/wait.py", role: .unclassified)
        let exec = CodexProcess(pid: 30002, executable: "/private/secret-folder/codex", role: .exec)
        let noPath = CodexProcess(pid: 30003, executable: "private-prompt-as-argv-zero", role: .unclassified, diagnosticExecutable: "kernel-helper")
        evidence.incompleteNonCodex = 7; evidence.execClaim = true; evidence.extra = [exec, noPath]
        evidence.blockers = [.init(process: script, reason: .namesThread), .init(process: exec, reason: .namesLast)]
        XCTAssertThrowsError(try bootstrap()) { error in
            let failure = error as? ChecklistError
            XCTAssertTrue(CodexRestartRefusal.applies(error))
            let text = error.localizedDescription
            for value in ["PID 30001", "executable=wait.py", "role=unclassified", "reason=names_thread", "PID 30002",
                          "executable=codex", "role=exec", "reason=names_last", "reason=exec_holder", "PID 30003", "executable=kernel-helper", "reason=second_holder", "incompleteNonCodex=7"] {
                XCTAssertTrue(text.contains(value), text)
            }
            XCTAssertFalse(text.contains("secret-folder")); XCTAssertFalse(text.contains("private-prompt"))
            XCTAssertEqual((failure?.details["blocking_processes"] as? [[String: Any]])?.count, 4)
        }
    }

    func testPermanentBindingFailuresKeepNoRestartRetryMarker() throws {
        coordinator.enrollments[enrollment.installation]?.codexAppHostProven = false
        XCTAssertThrowsError(try bootstrap()) { XCTAssertFalse(CodexRestartRefusal.applies($0)) }
        coordinator.enrollments[enrollment.installation]?.codexAppHostProven = true
        coordinator.enrollments[enrollment.installation]?.workspace = root.appendingPathComponent("other").path
        XCTAssertThrowsError(try bootstrap()) { XCTAssertFalse(CodexRestartRefusal.applies($0)) }
        coordinator.enrollments[enrollment.installation]?.workspace = root.path
        coordinator.enrollments[enrollment.installation]?.ownerRevoked = true
        XCTAssertThrowsError(try bootstrap()) { XCTAssertFalse(CodexRestartRefusal.applies($0)) }
        XCTAssertEqual(evidence.pauses, 0)
    }

    func testHolderClaimAndBlockerDriftStillRefuseBeforeClosure() throws {
        for kind in ["holder", "claim", "blocker"] {
            evidence.scans = 0; evidence.extra = []; evidence.execClaim = false; evidence.blockers = []
            evidence.onScan = { [evidence] in
                guard evidence.scans == 2 else { return }
                let process = CodexProcess(pid: 30000, executable: "/synthetic/other", role: .unclassified)
                if kind == "holder" { evidence.extra = [process] }
                if kind == "claim" { evidence.execClaim = true }
                if kind == "blocker" { evidence.blockers = [.init(process: process, reason: .namesThread)] }
            }
            XCTAssertThrowsError(try bootstrap()) { XCTAssertTrue(CodexRestartRefusal.applies($0), kind) }
            XCTAssertEqual(try session()["state"] as? String, "connected")
            XCTAssertEqual(evidence.pauses, 0)
        }
    }

    func testTransientPostClosureFailureRecoversOnThirdAttemptWithOldAuthorityFenced() throws {
        let (task, attempt) = try claimedTask()
        let note = try call("message_send", ["project_id": project!, "task_id": task["id"]!, "body": "Before retry"])
        let delivery = try XCTUnwrap((note["deliveries"] as? [JSON])?.first)
        evidence.onScan = { [evidence] in evidence.unreadable = (3...4).contains(evidence.scans) }
        evidence.onPause = { [self] in
            XCTAssertEqual(try session()["state"] as? String, "ended")
            XCTAssertEqual(try coordinator.credentials.read(enrollment.installation), token)
            XCTAssertTrue(coordinator.enrollments[enrollment.installation]?.revoked == true)
            try router.dbQueue.read { db in
                let released = try router.record(db, attempt["id"] as! String, type: "attempt")
                XCTAssertEqual(released["state"] as? String, "released"); XCTAssertNil(released["token_hash"])
                let receipt = try router.deliveryReceiptProjection(db, router.record(db, delivery["id"] as! String, type: "delivery"))
                XCTAssertEqual(receipt["state"] as? String, "fenced")
                XCTAssertEqual(receipt["native_closure_ref"] as? String, released["native_closure_ref"] as? String)
            }
        }
        XCTAssertTrue(try bootstrap().changed)
        XCTAssertNil(evidence.scanFailure); XCTAssertEqual(evidence.pauses, 2); XCTAssertEqual(evidence.scans, 8)
        XCTAssertEqual(try session()["state"] as? String, "connected")
        let resumed = try XCTUnwrap(coordinator.enrollments[enrollment.installation])
        refuses("STALE_CLAIM", contains: "claim") {
            _ = try self.call("work_checkpoint", ["project_id": self.project!, "attempt_id": attempt["id"]!,
                "claim_token": attempt["claim_token"]!, "progress": "Old token"], self.worker(resumed))
        }
        let receipts = try call("message_delivery_list", ["project_id": project!, "task_id": task["id"]!, "message_id": note["id"]!])["deliveries"] as! [JSON]
        XCTAssertEqual(receipts.first { $0["id"] as? String == delivery["id"] as? String }?["state"] as? String, "fenced")
    }

    func testTransientCommitEvidenceFailureRecoversWithoutRestoringOldAuthority() throws {
        evidence.onScan = { [evidence] in evidence.unreadable = evidence.scans == 5 }
        evidence.onPause = { [self] in
            XCTAssertEqual(try session()["state"] as? String, "ended")
            XCTAssertNotEqual(try coordinator.credentials.read(enrollment.installation), token)
            XCTAssertNotEqual(coordinator.enrollments[enrollment.installation]?.generation, enrollment.generation)
        }
        XCTAssertTrue(try bootstrap().changed)
        XCTAssertNil(evidence.scanFailure); XCTAssertEqual(evidence.pauses, 1); XCTAssertEqual(evidence.scans, 7)
        XCTAssertEqual(try session()["state"] as? String, "connected")
    }

    func testPersistentPostClosureEvidenceFailureStopsAfterThreeAttempts() throws {
        evidence.onScan = { [evidence] in if evidence.scans >= 3 { evidence.unreadable = true } }
        XCTAssertThrowsError(try bootstrap()) { XCTAssertTrue(CodexRestartRefusal.applies($0)) }
        XCTAssertEqual(evidence.pauses, 2); XCTAssertEqual(evidence.scans, 5)
        XCTAssertEqual(try session()["state"] as? String, "ended")
        XCTAssertTrue(coordinator.enrollments[enrollment.installation]?.revoked == true)
        XCTAssertEqual(try coordinator.credentials.read(enrollment.installation), token)
    }

    private func revokeDuringRetry() throws {
        // Fake a canonical owner-revocation race in this owned store. The public
        // ticket disconnect action deliberately rejects an already-ended session.
        try router.dbQueue.write { db in
            var current = try router.record(db, enrollment.sessionID, type: "session")
            current["state"] = "revoked"; current["owner_revoked"] = true
            current["authorization_generation"] = UUID().uuidString
            try router.save(db, router.revised(current), type: "session")
        }
    }

    func testOwnerRevocationDuringPostClosureRetryStopsBeforeAnotherSample() throws {
        evidence.onScan = { [evidence] in evidence.unreadable = evidence.scans == 3 }
        evidence.onPause = { [self] in try revokeDuringRetry() }
        refuses("CONNECTION_REVOKED", contains: "owner")
        XCTAssertNil(evidence.scanFailure); XCTAssertEqual(evidence.pauses, 1); XCTAssertEqual(evidence.scans, 3)
        XCTAssertEqual(try session()["owner_revoked"] as? Bool, true)
        XCTAssertEqual(try coordinator.credentials.read(enrollment.installation), token)
        XCTAssertThrowsError(try bootstrap()) { XCTAssertFalse(CodexRestartRefusal.applies($0)) }
    }

    func testOwnerRevocationDuringCommitRetryRollsBackToFencedEnrollment() throws {
        evidence.onScan = { [evidence] in evidence.unreadable = evidence.scans == 5 }
        evidence.onPause = { [self] in try revokeDuringRetry() }
        refuses("CONNECTION_REVOKED", contains: "owner")
        XCTAssertNil(evidence.scanFailure); XCTAssertEqual(evidence.pauses, 1); XCTAssertEqual(evidence.scans, 5)
        XCTAssertEqual(try session()["owner_revoked"] as? Bool, true)
        XCTAssertTrue(coordinator.enrollments[enrollment.installation]?.revoked == true)
        XCTAssertEqual(try coordinator.credentials.read(enrollment.installation), token)
    }

    func testOwnerRevocationDuringSuccessfulFinalSamplePreventsCommit() throws {
        evidence.onScan = { [self] in if evidence.scans == 6 { try revokeDuringRetry() } }
        refuses("CONNECTION_REVOKED", contains: "owner")
        XCTAssertNil(evidence.scanFailure); XCTAssertEqual(evidence.pauses, 0)
        XCTAssertEqual(try session()["owner_revoked"] as? Bool, true)
        XCTAssertTrue(coordinator.enrollments[enrollment.installation]?.revoked == true)
        XCTAssertEqual(try coordinator.credentials.read(enrollment.installation), token)
    }

    func testLocalOwnerRevocationDuringCommitRetrySurvivesRollback() throws {
        evidence.onScan = { [evidence] in evidence.unreadable = evidence.scans == 5 }
        evidence.onPause = { [self] in
            coordinator.enrollments[enrollment.installation]?.ownerRevoked = true
            coordinator.enrollments[enrollment.installation]?.revoked = true
        }
        refuses("CONNECTION_REVOKED", contains: "owner")
        XCTAssertEqual(evidence.pauses, 1); XCTAssertEqual(evidence.scans, 5)
        XCTAssertTrue(coordinator.enrollments[enrollment.installation]?.ownerRevoked == true)
        XCTAssertTrue(coordinator.enrollments[enrollment.installation]?.revoked == true)
        XCTAssertEqual(try coordinator.credentials.read(enrollment.installation), token)
        XCTAssertEqual(try session()["state"] as? String, "ended")
        XCTAssertThrowsError(try bootstrap()) { XCTAssertFalse(CodexRestartRefusal.applies($0)) }
        XCTAssertEqual(evidence.scans, 5, "Later bootstrap cannot erase the owner's refusal")
    }

}
