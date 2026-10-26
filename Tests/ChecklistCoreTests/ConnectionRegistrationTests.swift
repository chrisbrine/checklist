import ChecklistTestSupport
import XCTest
import Foundation
import GRDB
import Darwin
@testable import ChecklistCore

final class ConnectionRegistrationTests: XCTestCase {
    var root: URL!
    var router: CommandRouter!
    let owner = Caller(role: "owner", installation: "pairing-fixture-owner", projectIDs: [])
    override func setUpWithError() throws {
        if ProcessInfo.processInfo.environment["CL82_CHILD_MODE"] != nil { return }
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        router = try TestStore.router(root: root)
    }
    override func tearDownWithError() throws { router = nil; if let root { try? FileManager.default.removeItem(at: root) } }
    func call(_ method: String, _ p: JSON) throws -> JSON {
        var p = p; if !CommandRouter.readMethods.contains(method), p["command_id"] == nil { p["command_id"] = uuid() }
        return try router.handle(method: method, params: p, caller: owner)["data"] as! JSON
    }
    func fixture() throws -> (pid: String, sid: String, prior: JSON) {
        let project = try call("project_create", ["name": "Pairing faults", "key_prefix": "PF", "root_path": root.path])
        let sid = uuid()
        let prior = try call("session_register", ["project_id": project["id"]!, "project_ids": [project["id"]!], "session_id": sid, "installation": "pairtest/old", "provider": "codex", "role": "worker", "workspace": root.path])
        return (project["id"] as! String, sid, prior)
    }
    func intent(_ pid: String, command: String = uuid()) -> JSON { ["command_id": command, "installation": "pairtest", "project_ids": [pid], "workspace": root.path, "provider": "codex", "role": "worker"] }
    func preparation(_ pid: String, sid: String, generation: String) -> ConnectionRegistrationPreparation {
        ConnectionRegistrationPreparation(sessionParameters: ["project_id": pid, "project_ids": [pid], "session_id": sid, "installation": "pairtest/" + generation, "provider": "codex", "role": "worker", "workspace": root.path], installation: "pairtest", mcpExecutable: "/synthetic/Checklist.app/checklist")
    }
    func receiptCount(_ command: String) throws -> Int { try router.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM commands WHERE command_id=?", arguments: [command])! } }
    func session(_ sid: String) throws -> JSON { try router.dbQueue.read { try router.record($0, sid, type: "session") } }
    func current(_ original: JSON, sid: String) throws -> Bool {
        let digest = ChecklistCore.hash(Data(("connection_pair" + (try jsonString(original))).utf8))
        return try router.connectionRegistrationIsCurrent(commandID: original["command_id"] as! String, digest: digest, sessionID: sid, installation: "pairtest", receiptPrincipal: owner.principal, caller: owner)
    }

    func testExactConnectionSessionKeepsScopeFreshnessAndAdmission() throws {
        let f = try fixture()
        let initial = try XCTUnwrap(router.connectionSession(sessionID:f.sid,project:f.pid,caller:owner))
        XCTAssertEqual(initial["id"] as? String,f.sid)
        XCTAssertNil(try router.connectionSession(sessionID:"missing",project:f.pid,caller:owner))
        XCTAssertThrowsError(try router.connectionSession(sessionID:f.sid,project:f.pid,caller:Caller(role:"worker",installation:"foreign",projectIDs:[f.pid]))) { error in
            XCTAssertEqual((error as? CoreError)?.code,"HUMAN_CHANNEL_REQUIRED")
        }
        let other = try call("project_create",["name":"Other","key_prefix":"OT"])
        XCTAssertNil(try router.connectionSession(sessionID:f.sid,project:other["id"] as! String,caller:owner))
        for state in ["ended","revoked"] {
            let current = try session(f.sid)
            _ = try call("session_update",["project_id":f.pid,"session_id":f.sid,"expected_revision":current["revision"]!,"state":state])
            XCTAssertEqual(try router.connectionSession(sessionID:f.sid,project:f.pid,caller:owner)?["state"] as? String,state)
        }
        let drain = try router.beginStorageDrain(caller:owner)
        XCTAssertTrue(try router.waitForStorageDrain(drain,timeout:1,caller:owner))
        XCTAssertThrowsError(try router.connectionSession(sessionID:f.sid,project:f.pid,caller:owner)) { error in
            XCTAssertEqual((error as? CoreError)?.code,"STORAGE_DRAINING")
        }
        try router.cancelStorageDrain(drain,caller:owner)
    }

    func testOriginalIntentReplaySkipsEveryPreparationAndKeepsExactSemanticReceipt() throws {
        let f = try fixture(), original = intent(f.pid)
        var preparations = 0, rotations = 0
        let marker = "SYNTHETIC_PRIVATE_MARKER_NEVER_A_RECEIPT"
        let first = try router.commitConnectionRegistration(intent: original, caller: owner, preparePersistence: { _ in
            preparations += 1; rotations += 1
            try Data(marker.utf8).write(to: self.root.appendingPathComponent("credential.marker"))
            return self.preparation(f.pid, sid: f.sid, generation: uuid())
        }, rollback: { XCTFail("No rollback after commit") })
        let registered = try session(f.sid)
        let replay = try router.commitConnectionRegistration(intent: original, caller: owner, preparePersistence: { _ in XCTFail("Replay generated/prepared new state"); throw CoreError("FIXTURE", "must not run") }, rollback: { XCTFail("Replay rollback") })
        XCTAssertEqual(preparations, 1); XCTAssertEqual(rotations, 1); XCTAssertEqual(replay["replayed"] as? Bool, true)
        XCTAssertEqual(try jsonString(first["data"]!), try jsonString(replay["data"]!)); XCTAssertEqual(first["command_id"] as? String, original["command_id"] as? String)
        XCTAssertEqual(try jsonString(session(f.sid)), try jsonString(registered)); XCTAssertTrue(try current(original, sid: f.sid))
        XCTAssertNil(first["_connection_registration"]); XCTAssertEqual(try receiptCount(original["command_id"] as! String), 1)
        let persistence = try router.dbQueue.read { db in
            (try String.fetchAll(db, sql: "SELECT result FROM commands")).joined() + (try String.fetchAll(db, sql: "SELECT data FROM events")).joined()
        }
        XCTAssertFalse(persistence.contains(marker)); XCTAssertFalse(try jsonString(first).contains(marker))
    }

    func testOwnerAndOriginalPayloadCheckedBeforePreparationAndRevokedReplayNeverRestoresAuthority() throws {
        let f = try fixture(), original = intent(f.pid)
        _ = try router.commitConnectionRegistration(intent: original, caller: owner, preparePersistence: { _ in self.preparation(f.pid, sid: f.sid, generation: "committed") }, rollback: {})
        var changed = original; changed["name"] = "different intent"
        XCTAssertThrowsError(try router.commitConnectionRegistration(intent: changed, caller: owner, preparePersistence: { _ in XCTFail(); return self.preparation(f.pid, sid: f.sid, generation: "wrong") }, rollback: { XCTFail() })) { error in XCTAssertEqual((error as? CoreError)?.code, "IDEMPOTENCY_CONFLICT") }
        XCTAssertThrowsError(try router.commitConnectionRegistration(intent: original, caller: Caller(role: "worker", installation: owner.installation, projectIDs: [f.pid]), preparePersistence: { _ in XCTFail(); return self.preparation(f.pid, sid: f.sid, generation: "wrong") }, rollback: { XCTFail() })) { error in XCTAssertEqual((error as? CoreError)?.code, "HUMAN_CHANNEL_REQUIRED") }
        let before = try session(f.sid)
        _ = try call("session_update", ["project_id": f.pid, "session_id": f.sid, "expected_revision": before["revision"]!, "state": "revoked"])
        let revoked = try session(f.sid)
        let replay = try router.commitConnectionRegistration(intent: original, caller: owner, preparePersistence: { _ in XCTFail(); return self.preparation(f.pid, sid: f.sid, generation: "wrong") }, rollback: { XCTFail() })
        let data = replay["data"] as! JSON
        XCTAssertEqual(data["paired"] as? Bool, true, "Historical semantic result is retained")
        XCTAssertEqual((data["current_authority"] as? JSON)?["registration_current"] as? Bool, false)
        XCTAssertEqual(try jsonString(session(f.sid)), try jsonString(revoked)); XCTAssertFalse(try current(original, sid: f.sid))
    }

    func testCredentialAndEnrollmentPreparationFailuresRestorePriorStateWithoutSessionOrReceipt() throws {
        let f = try fixture()
        for stage in ["credential_read", "credential_write", "enrollment_write"] {
            let original = intent(f.pid); var credential = "prior-marker", enrollment = "prior-generation", snapshots = false
            XCTAssertThrowsError(try router.commitConnectionRegistration(intent: original, caller: owner, preparePersistence: { _ in
                if stage == "credential_read" { throw CoreError("KEYCHAIN_UNAVAILABLE", "synthetic read failure") }
                snapshots = true
                if stage == "credential_write" { throw CoreError("KEYCHAIN_UNAVAILABLE", "synthetic write failure") }
                credential = "prepared-marker"; enrollment = "prepared-generation"
                throw CoreError("ENROLLMENT_WRITE_FAILED", "synthetic enrollment failure")
            }, rollback: { if snapshots { credential = "prior-marker"; enrollment = "prior-generation" } }))
            XCTAssertEqual(credential, "prior-marker"); XCTAssertEqual(enrollment, "prior-generation")
            XCTAssertEqual(try jsonString(session(f.sid)), try jsonString(f.prior)); XCTAssertEqual(try receiptCount(original["command_id"] as! String), 0)
            XCTAssertFalse(try current(original, sid: f.sid))
        }
    }

    func testFailedRestorationRetainsOriginalFailureAndPreparedAuthorityStaysDenied() throws {
        let f = try fixture(), original = intent(f.pid)
        XCTAssertThrowsError(try router.commitConnectionRegistration(intent: original, caller: owner, preparePersistence: { _ in throw CoreError("ENROLLMENT_WRITE_FAILED", "specific original preparation failure") }, rollback: { throw CoreError("RESTORE_FAILED", "synthetic restore failure") })) { error in
            let failure = error as? CoreError
            XCTAssertEqual(failure?.code, "CONNECTION_RECOVERY_REQUIRED")
            XCTAssertEqual(failure?.details["rollback_failed"] as? Bool, true)
            XCTAssertTrue((failure?.details["original_failure"] as? String)?.contains("specific original") == true)
        }
        XCTAssertEqual(try jsonString(session(f.sid)), try jsonString(f.prior)); XCTAssertFalse(try current(original, sid: f.sid))
    }

    func testActualDeferredSQLiteCommitFailureRollsBackSessionAndOuterReceiptAfterPreparation() throws {
        let f = try fixture(), original = intent(f.pid), command = original["command_id"] as! String
        try router.dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE fault_parent(id INTEGER PRIMARY KEY); CREATE TABLE fault_child(parent INTEGER REFERENCES fault_parent(id) DEFERRABLE INITIALLY DEFERRED)")
            try db.execute(sql: "CREATE TRIGGER pairing_commit_fault AFTER INSERT ON commands WHEN NEW.command_id='" + command + "' BEGIN INSERT INTO fault_child(parent) VALUES(999); END")
        }
        var prepared = false, restorations = 0
        XCTAssertThrowsError(try router.commitConnectionRegistration(intent: original, caller: owner, preparePersistence: { _ in prepared = true; return self.preparation(f.pid, sid: f.sid, generation: "uncommitted") }, rollback: { restorations += 1 })) { error in XCTAssertTrue(error is DatabaseError) }
        XCTAssertTrue(prepared); XCTAssertEqual(restorations, 1)
        XCTAssertEqual(try jsonString(session(f.sid)), try jsonString(f.prior)); XCTAssertEqual(try receiptCount(command), 0); XCTAssertFalse(try current(original, sid: f.sid))
    }

    func testDisposableProcessDeathBeforeAndAfterCommitKeepsCorrectReceiptAndGenerationFence() throws {
        let f = try fixture()
        for mode in ["after_credential", "after_enrollment", "before_commit", "after_commit"] {
            let original = intent(f.pid)
            try Data("CL82_DISPOSABLE_FAULT_TEST_ONLY".utf8).write(to: root.appendingPathComponent(".cl82-fixture"))
            let inputs: JSON = ["intent": original, "project_id": f.pid, "session_id": f.sid]
            try Data((try jsonString(inputs)).utf8).write(to: root.appendingPathComponent("crash-inputs.json"))
            let bundle = Bundle(for: ConnectionRegistrationTests.self).bundleURL
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest", "ChecklistCoreTests.ConnectionRegistrationTests/testOnlyDisposableCrashChild", bundle.path]
            var environment = ProcessInfo.processInfo.environment
            environment["CL82_CHILD_MODE"] = mode; environment["CL82_CHILD_ROOT"] = root.path; process.environment = environment
            let output = Pipe(); process.standardOutput = output; process.standardError = output
            router = nil
            try process.run(); process.waitUntilExit()
            let diagnostics = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationReason, .uncaughtSignal, diagnostics); XCTAssertEqual(process.terminationStatus, SIGKILL, diagnostics)
            router = try TestStore.router(root: root)
            let count = try receiptCount(original["command_id"] as! String)
            if mode == "after_commit" {
                XCTAssertEqual(count, 1); XCTAssertTrue(try current(original, sid: f.sid))
                let registration = try session(f.sid)
                let replay = try router.commitConnectionRegistration(intent: original, caller: owner, preparePersistence: { _ in XCTFail("Lost reply replay prepared again"); throw CoreError("FIXTURE", "must not run") }, rollback: { XCTFail() })
                XCTAssertEqual((replay["data"] as? JSON)?["session_id"] as? String, f.sid)
                XCTAssertEqual(try jsonString(session(f.sid)), try jsonString(registration))
            } else {
                XCTAssertEqual(count, 0); XCTAssertFalse(try current(original, sid: f.sid))
                XCTAssertEqual(try jsonString(session(f.sid)), try jsonString(f.prior))
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("prepared-credential.marker").path), "External preparation may survive; it is not current authority")
            }
        }
    }

    func testOnlyDisposableCrashChild() throws {
        guard let mode = ProcessInfo.processInfo.environment["CL82_CHILD_MODE"], let path = ProcessInfo.processInfo.environment["CL82_CHILD_ROOT"] else { throw XCTSkip("Only the disposable subprocess invokes this helper") }
        let directory = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard directory.path.hasPrefix(temporary + "/"), try Data(contentsOf: directory.appendingPathComponent(".cl82-fixture")) == Data("CL82_DISPOSABLE_FAULT_TEST_ONLY".utf8) else { throw CoreError("FIXTURE_ROOT_REQUIRED", "Refusing any non-disposable fault root") }
        let input = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("crash-inputs.json"))) as! JSON
        let original = input["intent"] as! JSON, pid = input["project_id"] as! String, sid = input["session_id"] as! String
        let child = try TestStore.router(root: directory); var armed = false
        if mode == "before_commit" {
            child.dbQueue.writeWithoutTransaction { db in db.trace { event in
                if armed && event.description.uppercased().hasPrefix("COMMIT") { raise(SIGKILL) }
            } }
        }
        _ = try child.commitConnectionRegistration(intent: original, caller: owner, preparePersistence: { operation in
            try Data("synthetic preparation only".utf8).write(to: directory.appendingPathComponent("prepared-credential.marker"))
            if mode == "after_credential" { raise(SIGKILL) }
            try Data((try jsonString(["command_id": operation.commandID, "digest": operation.digest, "session_id": sid, "generation": "prepared"])) .utf8).write(to: directory.appendingPathComponent("prepared-enrollment.json"))
            if mode == "after_enrollment" { raise(SIGKILL) }
            armed = true
            return ConnectionRegistrationPreparation(sessionParameters: ["project_id": pid, "project_ids": [pid], "session_id": sid, "installation": "pairtest/prepared", "provider": "codex", "role": "worker", "workspace": directory.path], installation: "pairtest", mcpExecutable: "/synthetic/Checklist.app/checklist")
        }, rollback: {})
        if mode == "after_commit" { raise(SIGKILL) }
        XCTFail("Crash helper reached an unexpected successful return")
    }
}
