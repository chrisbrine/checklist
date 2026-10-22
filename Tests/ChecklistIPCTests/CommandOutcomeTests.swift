import XCTest
import GRDB
@testable import ChecklistCore
@testable import ChecklistIPC

final class CommandOutcomeTests: XCTestCase {
    var root: URL!
    var router: CommandRouter!
    let owner = Caller(role: "owner", installation: "disposable-outcome-test", projectIDs: [])
    override func setUpWithError() throws {
        let parent=FileManager.default.temporaryDirectory.appendingPathComponent("ChecklistSyntheticTests")
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        root=parent.appendingPathComponent("command-outcome-"+UUID().uuidString);router=try CommandRouter(root:root)
    }
    override func tearDownWithError() throws { router = nil; try? FileManager.default.removeItem(at: root) }
    func call(_ method: String, _ p: [String: Any] = [:]) throws -> [String: Any] {
        var p = p
        if !CommandRouter.readMethods.contains(method), p["command_id"] == nil { p["command_id"] = UUID().uuidString }
        return try router.handle(method: method, params: p, caller: owner)
    }
    func fixture() throws -> (String, String) {
        let project = try call("project_create", ["name": "Disposable", "root_path": root.path, "key_prefix": "FT"])["data"] as! [String: Any]
        let task = try call("task_create", ["project_id": project["id"]!, "title": "Lost reply"])["data"] as! [String: Any]
        return (project["id"] as! String, task["id"] as! String)
    }
    func bytes(_ x: Any) throws -> Data { try JSONSerialization.data(withJSONObject: x) }

    func testScopedWorkspaceAndCleanupReadsKeepReadEnvelopesAndCoreClassification() throws {
        XCTAssertEqual(CommandReply.readMethods.subtracting(["connection_list","task_handoff_prepare"]),CommandRouter.readMethods)
        for method in ["workspace_page","cleanup_job_get","cleanup_job_list","work_health_get","message_delivery_list"] {
            XCTAssertFalse(CommandReply.expectsMutation(method))
            let reply:[String:Any] = ["data":["rows":[],"_checklist":["schema_version":1]]]
            let decoded=try CommandReply.decode(bytes(reply),method:method,commandID:nil)
            XCTAssertEqual(try jsonString(decoded),try jsonString(reply))
        }
    }

    func testCommittedMutationWithMalformedOrMismatchedReplyReconcilesOnlyOriginalID() throws {
        let (pid, tid) = try fixture(), commandID = UUID().uuidString
        let input: [String: Any] = ["project_id": pid, "task_id": tid, "command_id": commandID, "body": "Unsent draft remains local until a confirmed result"]
        let committed = try call("message_send", input), messageID = (committed["data"] as! [String: Any])["id"] as! String
        let malformed: [Data] = [Data([0xff, 0xfe]), Data("[1]".utf8), Data("{}".utf8), Data("{\"data\":[]}".utf8), Data("{\"error\":{}}".utf8), try bytes(["data": [:], "error": ["code": "INVALID_INPUT", "message": "rejected"]]), try bytes(["data": [:], "command_id": UUID().uuidString]), try bytes(["data": [:], "command_id": 12])]
        for reply in malformed {
            do { _ = try CommandReply.decode(reply, method: "message_send", commandID: commandID); XCTFail("Ambiguity was accepted") }
            catch {
                let failure = try XCTUnwrap(error as? ChecklistError)
                XCTAssertEqual(failure.code, "OUTCOME_UNKNOWN"); XCTAssertEqual(failure.details["command_id"] as? String, commandID)
                XCTAssertTrue(failure.localizedDescription.contains(commandID)); XCTAssertTrue(CommandReply.shouldRetainPending(after: failure))
                let replay = try call("message_send", input)
                XCTAssertEqual(replay["replayed"] as? Bool, true)
                XCTAssertEqual((replay["data"] as! [String: Any])["id"] as? String, messageID)
            }
        }
        XCTAssertEqual(try router.dbQueue.read { try router.records($0, type: "message", project: pid).count }, 1)
    }

    func testDefinitiveRejectionDiffersFromUnknownFailureAndReadMalformedReply() throws {
        let id = UUID().uuidString
        let rejected = try bytes(["error": ["code": "REVISION_CONFLICT", "message": "Read current revision", "details": ["current_revision": 5]]])
        do { _ = try CommandReply.decode(rejected, method: "message_send", commandID: id); XCTFail() }
        catch { XCTAssertFalse(CommandReply.shouldRetainPending(after: error)); XCTAssertEqual((error as? ChecklistError)?.details["current_revision"] as? Int, 5) }
        do { _ = try CommandReply.decode(try bytes(["error": ["code": "COMMAND_FAILED", "message": "Commit state was not established"]]), method: "message_send", commandID: id); XCTFail() }
        catch { XCTAssertTrue(CommandReply.shouldRetainPending(after: error)); XCTAssertEqual((error as? ChecklistError)?.details["command_id"] as? String, id) }
        do { _ = try CommandReply.decode(try bytes(["error": ["code": "CONNECTION_RECOVERY_REQUIRED", "message": "Repair the staged connection", "details": ["command_outcome": "unknown"]]]), method: "message_send", commandID: id); XCTFail() }
        catch { XCTAssertTrue(CommandReply.shouldRetainPending(after: error)); XCTAssertEqual((error as? ChecklistError)?.details["command_id"] as? String, id) }
        XCTAssertTrue(CommandReply.shouldRetainPending(after: NSError(domain: NSCocoaErrorDomain, code: 3840)))
        let unknown = CommandReply.unknown(commandID: id, reason: "reply_timeout")
        XCTAssertTrue(unknown.localizedDescription.contains(id))
        do { _ = try CommandReply.decode(Data("{}".utf8), method: "service_info", commandID: nil); XCTFail() }
        catch { XCTAssertEqual((error as? ChecklistError)?.code, "INVALID_RESPONSE") }
    }

    func testValidEnvelopePreservesLiveHumanAnswerMetadataOutsideSemanticReceipt() throws {
        let id = UUID().uuidString
        let input: [String: Any] = ["command_id": id, "event_cursor": "opaque-caller-cursor", "data": ["id": "original-result", "_checklist": ["pending_human_answers": ["schema_version": 1, "status": "pending_pickup", "items": [["request_id": UUID().uuidString]]]]]]
        let decoded = try CommandReply.decode(bytes(input), method: "message_send", commandID: id)
        XCTAssertEqual(try jsonString(decoded), try jsonString(input))
        XCTAssertNotNil((decoded["data"] as? [String: Any])?["_checklist"])
    }

    func testR2FiveUncorrelatedOrObservationOnlyRepliesRemainUnknownAndReadsStayCompatible() throws {
        XCTAssertEqual(CommandReply.readMethods.subtracting(["connection_list", "task_handoff_prepare"]), CommandRouter.readMethods)
        let id = UUID().uuidString
        let hint: [String: Any] = ["_checklist": ["pending_human_answers": ["schema_version": 1, "status": "pending_pickup", "items": []]]]
        let rejected: [[String: Any]] = [["data": [:]], ["data": hint], ["data": ["id": "uncorrelated-result"]], ["command_id": id, "data": [:]], ["command_id": id, "data": hint]]
        for value in rejected {
            XCTAssertThrowsError(try CommandReply.decode(bytes(value), method: "message_send", commandID: id)) { error in
                XCTAssertTrue(CommandReply.shouldRetainPending(after: error)); XCTAssertEqual((error as? ChecklistError)?.details["command_id"] as? String, id)
            }
        }
        let valid: [String: Any] = ["command_id": id, "data": ["id": "durable-result", "_checklist": hint["_checklist"]!]]
        XCTAssertEqual(try jsonString(CommandReply.decode(bytes(valid), method: "message_send", commandID: id)), try jsonString(valid))
        for method in ["service_info", "review_context", "review_prepare", "source_execution_get", "connection_list", "task_handoff_prepare"] {
            let read: [String: Any] = ["data": ["read_result": [], "_checklist": hint["_checklist"]!]]
            XCTAssertEqual(try jsonString(CommandReply.decode(bytes(read), method: method, commandID: id)), try jsonString(read))
        }
        let handshake: [String: Any] = ["data": ["connected": true, "installation": "actual-bootstrap", "session_id": "actual-session"]]
        XCTAssertEqual(try jsonString(CommandReply.decode(bytes(handshake), method: "connection_bootstrap", commandID: nil)), try jsonString(handshake))
    }

    func testR2HumanAnswerRequiresActualRequestResponseAndPreservesUnresolvedResults() throws {
        let id = UUID().uuidString
        let malformed: [[String: Any]] = [["id": NSNull()], ["complete": true], ["triage_effect": ["kind": "none"]]]
        for data in malformed {
            XCTAssertThrowsError(try CommandReply.decode(bytes(["command_id": id, "data": data]), method: "human_request_answer", commandID: id)) { error in
                XCTAssertEqual((error as? ChecklistError)?.code, "OUTCOME_UNKNOWN")
                XCTAssertEqual((error as? ChecklistError)?.details["command_id"] as? String, id)
                XCTAssertTrue(CommandReply.shouldRetainPending(after: error))
            }
        }
        let (pid, tid) = try fixture()
        // These envelopes come from the actual Core endpoint, including all
        // unresolved actions and explicit check decline, rather than hand-built approximations.
        for action in ["answered", "send", "clarification", "clarify", "cannot_do", "declined"] {
            let request = try call("human_request_create", ["project_id": pid, "task_id": tid, "title": "Selected check \(action)", "blocking": false, "questions": [["id": "q", "type": "check", "prompt": "Run the selected check for \(action)"]]])["data"] as! [String: Any]
            let commandID = UUID().uuidString
            let result = action == "declined" ? "declined" : "passed"
            let answers: [[String: Any]] = ["answered", "send", "declined"].contains(action) ? [["question_id": "q", "result": result]] : []
            var envelope = try call("human_request_answer", ["project_id": pid, "request_id": request["id"]!, "expected_revision": request["revision"]!, "form_identity": request["form_identity"]!, "response": action == "declined" ? "answered" : action, "answers": answers, "explanation": "Actual disposable endpoint control", "command_id": commandID])
            var data = envelope["data"] as! [String: Any]
            data["_checklist"] = ["pending_human_answers": ["schema_version": 1, "status": "pending_pickup", "items": []]]
            envelope["data"] = data
            let decoded = try CommandReply.decode(bytes(envelope), method: "human_request_answer", commandID: commandID)
            XCTAssertEqual(try jsonString(decoded), try jsonString(envelope), action)
            XCTAssertEqual(data["state"] as? String, ["answered", "send", "declined"].contains(action) ? "answered" : "pending")
        }
        let read: [String: Any] = ["data": ["requests": []]]
        XCTAssertEqual(try jsonString(CommandReply.decode(bytes(read), method: "snapshot", commandID: id)), try jsonString(read))
        let handshake: [String: Any] = ["data": ["connected": true, "installation": "actual-bootstrap", "session_id": "actual-session"]]
        XCTAssertEqual(try jsonString(CommandReply.decode(bytes(handshake), method: "connection_bootstrap", commandID: nil)), try jsonString(handshake))
        let message: [String: Any] = ["command_id": id, "data": ["id": "durable-result", "_checklist": ["pending_human_answers": ["schema_version": 1, "status": "none", "items": []]]]]
        XCTAssertEqual(try jsonString(CommandReply.decode(bytes(message), method: "message_send", commandID: id)), try jsonString(message))
    }

    func testR1CheckedCredentialRemovalAndBothRestorationsReportFailure() throws {
        XCTAssertNoThrow(try ChecklistKeychain.checkRemovalStatus(0))
        XCTAssertNoThrow(try ChecklistKeychain.checkRemovalStatus(-25300))
        XCTAssertThrowsError(try ChecklistKeychain.checkRemovalStatus(-25293))
        var attemptedCredential = false
        XCTAssertThrowsError(try ConnectionCommit.restore(enrollment: { throw CocoaError(.fileWriteOutOfSpace) }, credential: { attemptedCredential = true; throw CocoaError(.fileWriteNoPermission) }))
        XCTAssertTrue(attemptedCredential)
    }

    func registered(_ pid: String, session: String, generation: String, commandID: String = UUID().uuidString) throws -> [String: Any] {
        try call("session_register", ["command_id": commandID, "project_id": pid, "session_id": session, "installation": "pair/" + generation, "provider": "codex", "role": "worker", "workspace": root.path])["data"] as! [String: Any]
    }
    func testCredentialAndEnrollmentFailuresCannotRegisterOrChangePriorSession() throws {
        let (pid, _) = try fixture(), sid = UUID().uuidString
        let prior = try registered(pid, session: sid, generation: "old")
        for failAt in ["credential", "enrollment"] {
            var credential = "old-token", enrollment = "old-enrollment", registrations = 0
            XCTAssertThrowsError(try ConnectionCommit.perform(saveCredential: { if failAt == "credential" { throw ChecklistError("KEYCHAIN_UNAVAILABLE", "simulated only") }; credential = "new-token" }, saveEnrollment: { enrollment = "new-enrollment"; throw CocoaError(.fileWriteOutOfSpace) }, registerSession: { registrations += 1; return try self.registered(pid, session: sid, generation: "new") }, rollback: { credential = "old-token"; enrollment = "old-enrollment" }))
            XCTAssertEqual(registrations, 0); XCTAssertEqual(credential, "old-token"); XCTAssertEqual(enrollment, "old-enrollment")
            let after = try router.dbQueue.read { try router.record($0, sid, type: "session") }
            XCTAssertEqual(try jsonString(after), try jsonString(prior))
        }
    }
    func testFailedRollbackReportsRepairAndCannotAuthenticateStagedGeneration() throws {
        let (pid, _) = try fixture(), sid = UUID().uuidString
        let prior = try registered(pid, session: sid, generation: "old")
        XCTAssertThrowsError(try ConnectionCommit.perform(saveCredential: {}, saveEnrollment: { throw CocoaError(.fileWriteOutOfSpace) }, registerSession: { XCTFail("Registration before persistence"); return prior }, rollback: { throw CocoaError(.fileWriteNoPermission) })) { error in
            XCTAssertEqual((error as? ChecklistError)?.code, "CONNECTION_RECOVERY_REQUIRED"); XCTAssertTrue(CommandReply.shouldRetainPending(after: error))
        }
        XCTAssertFalse(ConnectionCommit.registrationMatches(prior, sessionID: sid, installation: "pair", generation: "new", role: "worker", provider: "codex", projects: [pid]))
        XCTAssertTrue(ConnectionCommit.registrationMatches(prior, sessionID: sid, installation: "pair", generation: "old", role: "worker", provider: "codex", projects: [pid]))
        var revoked = prior; revoked["state"] = "revoked"
        XCTAssertFalse(ConnectionCommit.registrationMatches(revoked, sessionID: sid, installation: "pair", generation: "old", role: "worker", provider: "codex", projects: [pid]))
        XCTAssertFalse(ConnectionCommit.registrationMatches([:], sessionID: sid, installation: "pair", generation: "new", role: "worker", provider: "codex", projects: [pid]))
    }
    func testSuccessfulRegistrationRunsOnlyAfterBothPersistenceBoundaries() throws {
        let (pid, _) = try fixture(), sid = UUID().uuidString
        var order: [String] = []
        let session = try ConnectionCommit.perform(saveCredential: { order.append("credential") }, saveEnrollment: { order.append("enrollment") }, registerSession: { XCTAssertEqual(order, ["credential", "enrollment"]); order.append("registration"); return try self.registered(pid, session: sid, generation: "new") }, rollback: { XCTFail("success rollback") })
        XCTAssertEqual(order, ["credential", "enrollment", "registration"])
        XCTAssertTrue(ConnectionCommit.registrationMatches(session, sessionID: sid, installation: "pair", generation: "new", role: "worker", provider: "codex", projects: [pid]))
    }
}
