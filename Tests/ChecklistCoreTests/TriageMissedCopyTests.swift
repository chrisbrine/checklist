import XCTest
import GRDB
@testable import ChecklistCore

// CL-461: a stale binding leaves immutable omission evidence, then an explicit,
// verified resume picks up bounded pages without inventing or repeating receipts.
extension EvidenceAuthorityTests {
    private typealias MissedFixture = (p: JSON, group: JSON, task: JSON, o: Caller, holder: Caller, peer: Caller)

    private func missedFixture() throws -> MissedFixture {
        let phase = try preparedPhase("cl461-missed-triage-copy") { f in
            let p = try f.project(), o = try f.native(p, "missed-orchestrator", domain: "claude:461:1:0", provider: "claude")
            let h = try f.native(p, "missed-holder", domain: "codex:holder"), peer = try f.native(p, "missed-peer", domain: "codex:peer")
            let group = try f.call("triage_orchestrate", ["project_id": p["id"]!, "action": "start"], o)
            let task = try f.ready(p)
            _ = try f.call("group_membership", ["project_id": p["id"]!, "group_id": group["id"]!, "expected_revision": group["revision"]!, "task_id": task["id"]!, "action": "add"], o)
            let current = try f.missedRecord(task["id"]!, "task")
            _ = try f.claim(p, current, caller: h)
            return ["project": p, "group": group, "task": task, "o": o.sessionID!, "holder": h.sessionID!, "peer": peer.sessionID!]
        }
        return (phase["project"] as! JSON, phase["group"] as! JSON, phase["task"] as! JSON,
                try phaseCaller(phase["o"]!), try phaseCaller(phase["holder"]!), try phaseCaller(phase["peer"]!))
    }

    private func missedRecord(_ id: Any, _ type: String) throws -> JSON {
        try router.dbQueue.read { try router.record($0, id as! String, type: type) }
    }

    private func missedResumeConversation(_ p: JSON, _ worker: Caller) throws -> Caller {
        let session = try missedRecord(worker.sessionID!, "session")
        _ = try router.reconcileVerifiedNativeClosure(VerifiedNativeClosure(projectID: p["id"] as! String,
            sessionID: worker.sessionID!, installation: worker.installation, executionDomain: worker.executionDomain!, provider: "claude",
            authorizationGeneration: router.sessionGeneration(session), processState: "gone", registryState: "absent", registryDigest: nil),
            caller: Caller(role: "owner", installation: "native-lifecycle", projectIDs: []))
        let installation = worker.installation + "/resumed", domain = worker.executionDomain! + "/resumed"
        _ = try router.resumeVerifiedNativeSession(NativeSessionResumption(projectID: p["id"] as! String,
            sessionID: worker.sessionID!, provider: "claude", oldInstallation: worker.installation, oldExecutionDomain: worker.executionDomain!,
            newInstallation: installation, newExecutionDomain: domain),
            caller: Caller(role: "owner", installation: "native-thread-bootstrap", projectIDs: []))
        return Caller(role: "worker", installation: installation, projectIDs: worker.projectIDs, sessionID: worker.sessionID,
                      workspace: workspace.path, executionDomain: domain)
    }

    private func missedOrchestrateInput(_ f: MissedFixture, _ action: String) throws -> JSON {
        ["project_id": f.p["id"]!, "triage_id": f.group["id"]!, "expected_revision": try missedRecord(f.group["id"]!, "group")["revision"]!,
         "action": action, "reason": "Continue the same verified conversation"]
    }

    private func missedNote(_ f: MissedFixture, _ sender: Caller?, _ extra: JSON = [:]) throws -> JSON {
        var input: JSON = ["project_id": f.p["id"]!, "task_id": f.task["id"]!, "body": "A member ticket note during recovery"]
        for (key, value) in extra { input[key] = value }
        return try call("message_send", input, sender)
    }

    private func missedReceipts(_ f: MissedFixture, _ messageID: Any) throws -> [JSON] {
        try router.dbQueue.read { db in
            try router.records(db, type: "delivery", project: f.p["id"] as? String).filter {
                $0["message_id"] as? String == messageID as? String && $0["recipient_session_id"] as? String == f.o.sessionID
            }
        }
    }

    private func missedOmission(_ f: MissedFixture, _ message: JSON, file: StaticString = #filePath, line: UInt = #line) throws -> JSON {
        let omissions = try XCTUnwrap(message["delivery_omissions"] as? [JSON], file: file, line: line)
        XCTAssertEqual(omissions.count, 1, file: file, line: line)
        let omission = try XCTUnwrap(omissions.first, file: file, line: line)
        let original = try XCTUnwrap(f.group["orchestration"] as? JSON)
        XCTAssertEqual(omission["project_id"] as? String, f.p["id"] as? String, file: file, line: line)
        XCTAssertEqual(omission["message_id"] as? String, message["id"] as? String, file: file, line: line)
        XCTAssertEqual(omission["triage_id"] as? String, f.group["id"] as? String, file: file, line: line)
        XCTAssertEqual(omission["orchestration_id"] as? String, original["id"] as? String, file: file, line: line)
        XCTAssertEqual(omission["binding_authorization_generation"] as? String, original["session_authorization_generation"] as? String, file: file, line: line)
        XCTAssertEqual(omission["recipient_session_id"] as? String, f.o.sessionID, file: file, line: line)
        XCTAssertEqual(omission["recipient_role"] as? String, "triage_orchestrator", file: file, line: line)
        XCTAssertEqual(omission["state"] as? String, "not_delivered_binding_stale", file: file, line: line)
        XCTAssertFalse((omission["reason"] as? String ?? "").isEmpty, file: file, line: line)
        XCTAssertFalse((omission["recipient_display"] as? String ?? "").isEmpty, file: file, line: line)
        XCTAssertNil(omission["id"], "An omission is not a delivery receipt.", file: file, line: line)
        XCTAssertTrue(try missedReceipts(f, message["id"]!).isEmpty, file: file, line: line)
        return omission
    }

    func testTriageMissedOwnerAnswerRecordsOmissionAndExplicitResumeDeliversExactlyOnce() throws {
        let f = try missedFixture()
        let request = try call("human_request_create", ["project_id": f.p["id"]!, "task_id": f.task["id"]!,
            "questions": [["id": "decision", "prompt": "May work proceed?"]]], f.holder)
        let resumed = try missedResumeConversation(f.p, f.o)
        let answer = try call("human_request_answer", ["project_id": f.p["id"]!, "request_id": request["id"]!,
            "expected_revision": request["revision"]!, "answers": [["question_id": "decision", "text": "Proceed"]]])
        let message = try XCTUnwrap(answer["message"] as? JSON)
        let omission = try missedOmission(f, message)
        let continuation = try XCTUnwrap(answer["continuation_deliveries"] as? [JSON])
        XCTAssertTrue(continuation.contains { NSDictionary(dictionary: $0).isEqual(to: omission) })
        XCTAssertEqual(continuation.filter { $0["recipient_session_id"] as? String == f.holder.sessionID && $0["state"] as? String == "queued" }.count, 1)
        let stored = try missedRecord(message["id"]!, "message")
        XCTAssertEqual(try jsonString(stored["delivery_omissions"]!), try jsonString(message["delivery_omissions"]!))
        let input = try missedOrchestrateInput(f, "resume"), command = UUID().uuidString
        let result = try call("triage_orchestrate", input, resumed, command: command)
        XCTAssertEqual(result["missed_notes_delivered"] as? Int, 1)
        XCTAssertEqual(result["missed_note_delivery_has_more"] as? Bool, false)
        let receipts = try missedReceipts(f, message["id"]!)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?["recipient_role"] as? String, "triage_orchestrator")
        XCTAssertEqual(receipts.first?["recipient_authorization_generation"] as? String,
                       try missedRecord(resumed.sessionID!, "session")["authorization_generation"] as? String)
        XCTAssertEqual(try jsonString(call("triage_orchestrate", input, resumed, command: command)), try jsonString(result))
        let next = try call("triage_orchestrate", missedOrchestrateInput(f, "checkpoint"), resumed)
        XCTAssertEqual(next["missed_notes_delivered"] as? Int, 0)
        XCTAssertEqual(try missedReceipts(f, message["id"]!).count, 1)
        let inbox = try call("session_inbox", ["project_id": f.p["id"]!], resumed)
        XCTAssertTrue((inbox["messages"] as! [JSON]).contains { $0["id"] as? String == message["id"] as? String && $0["human_request_id"] as? String == request["id"] as? String })
    }

    private func missedBoundedPage(_ count: Int) throws {
        let f = try missedFixture(), resumed = try missedResumeConversation(f.p, f.o)
        let first = try missedNote(f, f.peer)
        _ = try missedOmission(f, first)
        // Clone real send-time evidence; commands under test still queue every receipt.
        let ids = try router.dbQueue.write { db -> [String] in
            let prototype = try router.record(db, first["id"] as! String, type: "message")
            var ids = [first["id"] as! String]
            for index in 1..<count {
                var message = prototype
                let id = UUID().uuidString
                message["id"] = id; message["body"] = "Distinct missed note \(index)"
                message["delivery_omissions"] = (prototype["delivery_omissions"] as! [JSON]).map { value in
                    var omission = value; omission["message_id"] = id; return omission
                }
                try router.save(db, message, type: "message"); ids.append(id)
            }
            return ids
        }
        let input = try missedOrchestrateInput(f, "resume"), command = UUID().uuidString
        let result = try call("triage_orchestrate", input, resumed, command: command)
        XCTAssertEqual(result["missed_notes_delivered"] as? Int, 50)
        XCTAssertEqual(result["missed_note_delivery_has_more"] as? Bool, true)
        XCTAssertEqual(try ids.reduce(0) { try $0 + missedReceipts(f, $1).count }, 50)
        XCTAssertEqual(try jsonString(call("triage_orchestrate", input, resumed, command: command)), try jsonString(result))
        XCTAssertEqual(try ids.reduce(0) { try $0 + missedReceipts(f, $1).count }, 50, "A command retry must not consume the next page.")
        let next = try call("triage_orchestrate", missedOrchestrateInput(f, "checkpoint"), resumed)
        XCTAssertEqual(next["missed_notes_delivered"] as? Int, count - 50)
        XCTAssertEqual(next["missed_note_delivery_has_more"] as? Bool, false)
        let empty = try call("triage_orchestrate", missedOrchestrateInput(f, "checkpoint"), resumed)
        XCTAssertEqual(empty["missed_notes_delivered"] as? Int, 0)
        XCTAssertEqual(empty["missed_note_delivery_has_more"] as? Bool, false)
        for id in ids { XCTAssertEqual(try missedReceipts(f, id).count, 1) }
    }

    func testTriageMissedCopiesPageFiftyOfFiftyOneAndCheckpointFinishes() throws { try missedBoundedPage(51) }
    func testTriageMissedCopiesPageFiftyOfFiftyTwoAndResumeRetryKeepsNextPage() throws { try missedBoundedPage(52) }

    func testTriageMissedCopiesSkipSelfHolderAudienceAndOrdinaryExplicitRecipients() throws {
        let f = try missedFixture(), resumed = try missedResumeConversation(f.p, f.o)
        let own = try missedNote(f, resumed)
        let holderOnly = try missedNote(f, f.peer, ["audience": "holder"])
        let explicit = try missedNote(f, f.peer, ["recipient": ["kind": "session", "session_id": f.holder.sessionID!]])
        let explicitOrchestrator = try missedNote(f, f.peer, ["recipient": ["kind": "session", "session_id": resumed.sessionID!]])
        for message in [own, holderOnly, explicit, explicitOrchestrator] { XCTAssertNil(message["delivery_omissions"]) }
        let result = try call("triage_orchestrate", missedOrchestrateInput(f, "resume"), resumed)
        XCTAssertEqual(result["missed_notes_delivered"] as? Int, 0)
        for message in [own, holderOnly, explicit] { XCTAssertTrue(try missedReceipts(f, message["id"]!).isEmpty) }
        XCTAssertEqual(try missedReceipts(f, explicitOrchestrator["id"]!).count, 1)
    }

    func testTriageMissedCopiesRespectAnyExistingReceiptAcrossGenerationsAndMentionDelivery() throws {
        let f = try missedFixture()
        let explicit = try missedNote(f, f.peer, ["recipient": ["kind": "session", "session_id": f.o.sessionID!]])
        let oldGeneration = try XCTUnwrap(try missedReceipts(f, explicit["id"]!).first?["recipient_authorization_generation"] as? String)
        let resumed = try missedResumeConversation(f.p, f.o)
        let missed = try missedNote(f, f.peer)
        let omission = try missedOmission(f, missed)
        try router.dbQueue.write { db in
            // Retained omission + an earlier exact receipt can coexist after a retry
            // or an independent delivery route. Session identity, not generation,
            // decides whether the orchestrator already has that message.
            var stored = try router.record(db, explicit["id"] as! String, type: "message")
            var retained = omission; retained["message_id"] = explicit["id"]!
            stored["delivery_omissions"] = [retained]; try router.save(db, stored, type: "message")
            let current = try router.record(db, resumed.sessionID!, type: "session")
            let recipient: JSON = ["session_id": resumed.sessionID!, "recipient_role": "mention", "authorization_generation": router.sessionGeneration(current)]
            _ = try router.queueOrdinaryDeliveries(db, message: router.record(db, missed["id"] as! String, type: "message"), recipients: [recipient])
        }
        // Native resumption can independently make an old receipt available in
        // the new generation. This command must add nothing to either route.
        let explicitBefore = try missedReceipts(f, explicit["id"]!).compactMap { $0["id"] as? String }
        let mentionBefore = try missedReceipts(f, missed["id"]!).compactMap { $0["id"] as? String }
        let result = try call("triage_orchestrate", missedOrchestrateInput(f, "resume"), resumed)
        XCTAssertEqual(result["missed_notes_delivered"] as? Int, 0)
        XCTAssertEqual(try missedReceipts(f, explicit["id"]!).compactMap { $0["id"] as? String }, explicitBefore)
        XCTAssertEqual(try missedReceipts(f, explicit["id"]!).first?["recipient_authorization_generation"] as? String, oldGeneration)
        XCTAssertEqual(try missedReceipts(f, missed["id"]!).compactMap { $0["id"] as? String }, mentionBefore)
        XCTAssertEqual(try missedReceipts(f, missed["id"]!).first?["recipient_role"] as? String, "mention")
    }

    func testTriageMissedCopiesKeepSendTimeMembershipAndSecondStalePeriodAncestry() throws {
        let f = try missedFixture(), resumed = try missedResumeConversation(f.p, f.o)
        let first = try missedNote(f, f.peer)
        _ = try missedOmission(f, first)
        _ = try call("group_membership", ["project_id": f.p["id"]!, "group_id": f.group["id"]!,
            "expected_revision": try missedRecord(f.group["id"]!, "group")["revision"]!, "task_id": f.task["id"]!, "action": "remove"], f.peer)
        let departed = try missedNote(f, f.peer)
        XCTAssertNil(departed["delivery_omissions"])
        let rebound = try call("triage_orchestrate", missedOrchestrateInput(f, "resume"), resumed)
        XCTAssertEqual(rebound["missed_notes_delivered"] as? Int, 1, "A ticket that belonged at send time retains its missed copy.")
        XCTAssertEqual(try missedReceipts(f, first["id"]!).count, 1)
        _ = try call("group_membership", ["project_id": f.p["id"]!, "group_id": f.group["id"]!,
            "expected_revision": try missedRecord(f.group["id"]!, "group")["revision"]!, "task_id": f.task["id"]!, "action": "add"], resumed)
        let again = try missedResumeConversation(f.p, resumed)
        let second = try missedNote(f, f.peer)
        let omissions = try XCTUnwrap(second["delivery_omissions"] as? [JSON])
        XCTAssertEqual(omissions.first?["orchestration_id"] as? String, (rebound["orchestration"] as? JSON)?["id"] as? String)
        let firstBefore = try missedReceipts(f, first["id"]!).compactMap { $0["id"] as? String }
        let result = try call("triage_orchestrate", missedOrchestrateInput(f, "resume"), again)
        XCTAssertEqual(result["missed_notes_delivered"] as? Int, 1)
        let ancestors = (result["orchestration"] as? JSON)?["missed_note_orchestration_ids"] as? [String] ?? []
        XCTAssertEqual(ancestors, [(rebound["orchestration"] as! JSON)["id"] as! String], "An exhausted earlier window need not be scanned again.")
        XCTAssertEqual((result["orchestration"] as? JSON)?["missed_note_delivery_pending"] as? Bool, false)
        XCTAssertEqual(try missedReceipts(f, first["id"]!).compactMap { $0["id"] as? String }, firstBefore,
                       "The second Triage resume adds no receipt to a note already handled by native resumption.")
        XCTAssertEqual(try missedReceipts(f, second["id"]!).count, 1)
        XCTAssertTrue(try missedReceipts(f, departed["id"]!).isEmpty)
    }

    func testTriageMissedMandatoryHealthAndRoleChangeNoticesReplayOnce() throws {
        let f = try missedFixture(), resumed = try missedResumeConversation(f.p, f.o)
        _ = try router.runWorkHealthChecks(at: Date().addingTimeInterval(7200))
        let health = try XCTUnwrap(try router.dbQueue.read { db in
            try router.records(db, type: "message", project: f.p["id"] as? String).first {
                $0["kind"] as? String == "work_health" && $0["task_id"] as? String == f.task["id"] as? String
            }
        })
        _ = try missedOmission(f, health)
        let notices = try router.dbQueue.write { db in
            try router.roleChangeNotices(db, task: router.record(db, f.task["id"] as! String, type: "task"),
                earlier: [f.holder.sessionID!], body: "A mandatory role change notice", caller: f.peer)
        }
        let roleChange = try XCTUnwrap(notices.first)
        _ = try missedOmission(f, roleChange)
        let result = try call("triage_orchestrate", missedOrchestrateInput(f, "resume"), resumed)
        XCTAssertEqual(result["missed_notes_delivered"] as? Int, 2)
        for message in [health, roleChange] { XCTAssertEqual(try missedReceipts(f, message["id"]!).count, 1) }
        let next = try call("triage_orchestrate", missedOrchestrateInput(f, "checkpoint"), resumed)
        XCTAssertEqual(next["missed_notes_delivered"] as? Int, 0)
    }

    func testTriageMissedBindingRefusalStartsWithChangedConversationAndReadyResumeCommand() throws {
        let f = try missedFixture(), resumed = try missedResumeConversation(f.p, f.o)
        XCTAssertThrowsError(try call("triage_orchestrate", missedOrchestrateInput(f, "checkpoint"), resumed)) { error in
            let failure = error as? CoreError
            XCTAssertEqual(failure?.code, "FORBIDDEN")
            XCTAssertTrue(failure?.message.hasPrefix("A new installation or process of this conversation changed its Triage binding.") ?? false)
            XCTAssertTrue(failure?.message.contains("action=resume") ?? false)
            XCTAssertTrue(failure?.message.contains(f.group["id"] as! String) ?? false)
            let command = failure?.details["resume_command"] as? JSON
            XCTAssertEqual(command?["method"] as? String, "triage_orchestrate")
            let arguments = command?["arguments"] as? JSON
            XCTAssertEqual(arguments?["action"] as? String, "resume")
            XCTAssertEqual(arguments?["project_id"] as? String, f.p["id"] as? String)
            XCTAssertEqual(arguments?["triage_id"] as? String, f.group["id"] as? String)
            XCTAssertNotNil(arguments?["expected_revision"] as? Int)
            XCTAssertFalse((arguments?["reason"] as? String ?? "").isEmpty)
        }
        let other = f.peer
        assertCode("FORBIDDEN") { _ = try self.call("triage_orchestrate", self.missedOrchestrateInput(f, "resume"), other) }
        let group = try missedRecord(f.group["id"]!, "group")
        XCTAssertEqual(try jsonString(group["orchestration"]!), try jsonString(f.group["orchestration"]!))
    }

    func testTriageMissedUnverifiedGenerationCannotFinishOrResumeButGetsRecoveryCommand() throws {
        let f = try missedFixture()
        var session = try missedRecord(f.o.sessionID!, "session")
        session = try call("session_update", ["project_id": f.p["id"]!, "session_id": f.o.sessionID!,
            "expected_revision": session["revision"]!, "state": "ended"])
        _ = try call("session_update", ["project_id": f.p["id"]!, "session_id": f.o.sessionID!,
            "expected_revision": session["revision"]!, "state": "connected"])
        for action in ["checkpoint", "finish"] {
            XCTAssertThrowsError(try call("triage_orchestrate", missedOrchestrateInput(f, action), f.o)) { error in
                let failure = error as? CoreError
                XCTAssertEqual(failure?.code, "FORBIDDEN")
                XCTAssertTrue(failure?.message.hasPrefix("A new installation or process of this conversation changed its Triage binding.") ?? false)
                XCTAssertEqual(((failure?.details["resume_command"] as? JSON)?["arguments"] as? JSON)?["action"] as? String, "resume")
            }
        }
        assertCode("FORBIDDEN") { _ = try self.call("triage_orchestrate", self.missedOrchestrateInput(f, "resume"), f.o) }
        let group = try missedRecord(f.group["id"]!, "group")
        XCTAssertEqual(try jsonString(group["orchestration"]!), try jsonString(f.group["orchestration"]!))
    }

    func testTriageMissedLegacyDefaultAndOwnerAnswerReplayWithoutStoredOmissions() throws {
        let f = try missedFixture()
        let request = try call("human_request_create", ["project_id": f.p["id"]!, "task_id": f.task["id"]!,
            "questions": [["id": "decision", "prompt": "May legacy work proceed?"]]], f.holder)
        let resumed = try missedResumeConversation(f.p, f.o)
        let note = try missedNote(f, f.peer)
        let answer = try call("human_request_answer", ["project_id": f.p["id"]!, "request_id": request["id"]!,
            "expected_revision": request["revision"]!, "answers": [["question_id": "decision", "text": "Proceed"]]])
        let responseNote = try XCTUnwrap(answer["message"] as? JSON)
        for message in [note, responseNote] { _ = try missedOmission(f, message) }
        // Build 324 kept the real messages, routing, memberships and deliveries,
        // but did not save the omitted orchestrator copy or continuation entry.
        try router.dbQueue.write { db in
            for message in [note, responseNote] {
                var stored = try router.record(db, message["id"] as! String, type: "message")
                stored.removeValue(forKey: "delivery_omissions")
                try router.save(db, stored, type: "message")
            }
            var storedRequest = try router.record(db, request["id"] as! String, type: "request")
            storedRequest["continuation_deliveries"] = (storedRequest["continuation_deliveries"] as! [JSON]).filter {
                $0["state"] as? String != "not_delivered_binding_stale"
            }
            try router.save(db, storedRequest, type: "request")
        }
        let input = try missedOrchestrateInput(f, "resume"), command = UUID().uuidString
        let result = try call("triage_orchestrate", input, resumed, command: command)
        XCTAssertEqual(result["missed_notes_delivered"] as? Int, 2)
        XCTAssertEqual(result["missed_note_delivery_has_more"] as? Bool, false)
        let orchestration = try XCTUnwrap(result["orchestration"] as? JSON)
        XCTAssertEqual(orchestration["missed_note_delivery_pending"] as? Bool, false)
        let windows = try XCTUnwrap(orchestration["missed_note_windows"] as? [JSON])
        XCTAssertEqual(windows.count, 1)
        XCTAssertNotNil(windows.first?["native_closure_ref"] as? String)
        XCTAssertFalse((windows.first?["cutover_ref"] as? String ?? "").isEmpty)
        XCTAssertNil(windows.first?["through_message_id"])
        for message in [note, responseNote] { XCTAssertEqual(try missedReceipts(f, message["id"]!).count, 1) }
        XCTAssertEqual(try jsonString(call("triage_orchestrate", input, resumed, command: command)), try jsonString(result))
        let checkpoint = try call("triage_orchestrate", missedOrchestrateInput(f, "checkpoint"), resumed)
        XCTAssertEqual(checkpoint["missed_notes_delivered"] as? Int, 0)
        for message in [note, responseNote] { XCTAssertEqual(try missedReceipts(f, message["id"]!).count, 1) }
    }

    func testTriageMissedLegacyMembershipUsesRowOrderForEqualSecondJoinAndExit() throws {
        let f = try missedFixture(), task = try ready(f.p)
        _ = try claim(f.p, task, caller: f.holder)
        let scoped: MissedFixture = (f.p, f.group, task, f.o, f.holder, f.peer)
        let resumed = try missedResumeConversation(f.p, f.o)
        let beforeJoin = try missedNote(scoped, f.peer)
        XCTAssertNil(beforeJoin["delivery_omissions"])
        _ = try call("group_membership", ["project_id": f.p["id"]!, "group_id": f.group["id"]!,
            "expected_revision": try missedRecord(f.group["id"]!, "group")["revision"]!, "task_id": task["id"]!, "action": "add"])
        let memberNote = try missedNote(scoped, f.peer)
        _ = try missedOmission(scoped, memberNote)
        let explicitHolder = try missedNote(scoped, f.peer, ["recipient": ["kind": "session", "session_id": f.holder.sessionID!]])
        XCTAssertNil(explicitHolder["delivery_omissions"])
        _ = try call("group_membership", ["project_id": f.p["id"]!, "group_id": f.group["id"]!,
            "expected_revision": try missedRecord(f.group["id"]!, "group")["revision"]!, "task_id": task["id"]!, "action": "remove"], f.peer)
        let afterExit = try missedNote(scoped, f.peer)
        XCTAssertNil(afterExit["delivery_omissions"])
        let stamp = "2026-11-14T00:00:00Z"
        try router.dbQueue.write { db in
            for message in [beforeJoin, memberNote, explicitHolder, afterExit] {
                var stored = try router.record(db, message["id"] as! String, type: "message")
                stored.removeValue(forKey: "delivery_omissions"); stored["created_at"] = stamp
                try router.save(db, stored, type: "message")
            }
            for type in ["triage_membership_interval", "triage_membership_exit"] {
                let rows = try router.records(db, type: type, project: f.p["id"] as? String).filter {
                    $0["task_id"] as? String == task["id"] as? String
                }
                XCTAssertEqual(rows.count, 1)
                for var row in rows {
                    row[type == "triage_membership_interval" ? "joined_at" : "exited_at"] = stamp
                    try router.save(db, row, type: type)
                }
            }
        }
        XCTAssertFalse(router.triageMemberIDs(try missedRecord(f.group["id"]!, "group")).contains(task["id"] as! String))
        let result = try call("triage_orchestrate", missedOrchestrateInput(f, "resume"), resumed)
        XCTAssertEqual(result["missed_notes_delivered"] as? Int, 1)
        XCTAssertEqual(try missedReceipts(scoped, memberNote["id"]!).count, 1, "A departed member keeps its legacy send-time copy.")
        for message in [beforeJoin, explicitHolder, afterExit] { XCTAssertTrue(try missedReceipts(scoped, message["id"]!).isEmpty) }
        let checkpoint = try call("triage_orchestrate", missedOrchestrateInput(f, "checkpoint"), resumed)
        XCTAssertEqual(checkpoint["missed_notes_delivered"] as? Int, 0)
        XCTAssertEqual(try missedReceipts(scoped, memberNote["id"]!).count, 1)
    }

    func testTriageMissedLateDirectionPickupCannotInventPreMembershipOmission() throws {
        let f = try missedFixture(), task = try ready(f.p)
        let scoped: MissedFixture = (f.p, f.group, task, f.o, f.holder, f.peer)
        let direction = try missedNote(scoped, nil, ["requires_action": true])
        XCTAssertNil(direction["delivery_omissions"])
        XCTAssertTrue((direction["deliveries"] as! [JSON]).isEmpty)
        _ = try missedResumeConversation(f.p, f.o)
        _ = try call("group_membership", ["project_id": f.p["id"]!, "group_id": f.group["id"]!,
            "expected_revision": try missedRecord(f.group["id"]!, "group")["revision"]!, "task_id": task["id"]!, "action": "add"])
        _ = try claim(f.p, missedRecord(task["id"]!, "task"), caller: f.holder)
        _ = try call("task_context", ["project_id": f.p["id"]!, "task_id": task["id"]!], f.holder)
        let stored = try missedRecord(direction["id"]!, "message")
        XCTAssertNil(stored["delivery_omissions"], "Late pickup must not rewrite send-time membership.")
        let deliveries = try router.dbQueue.read { db in
            try router.records(db, type: "delivery", project: f.p["id"] as? String).filter {
                $0["message_id"] as? String == direction["id"] as? String
            }
        }
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries.first?["recipient_session_id"] as? String, f.holder.sessionID)
        XCTAssertTrue(try missedReceipts(scoped, direction["id"]!).isEmpty)
    }

    private func missedLegacyNotes(_ f: MissedFixture, count: Int) throws -> [String] {
        let first = try missedNote(f, f.peer)
        _ = try missedOmission(f, first)
        return try router.dbQueue.write { db in
            var prototype = try router.record(db, first["id"] as! String, type: "message")
            prototype.removeValue(forKey: "delivery_omissions")
            try router.save(db, prototype, type: "message")
            var ids = [first["id"] as! String]
            for index in 1..<count {
                var note = prototype
                let id = UUID().uuidString
                note["id"] = id; note["body"] = "Distinct legacy missed copy \(index)"
                try router.save(db, note, type: "message"); ids.append(id)
            }
            return ids
        }
    }

    func testTriageMissedLegacyFiftyTwoCopiesResumeRetryAndCheckpointAreBounded() throws {
        let f = try missedFixture(), resumed = try missedResumeConversation(f.p, f.o)
        let ids = try missedLegacyNotes(f, count: 52)
        let input = try missedOrchestrateInput(f, "resume"), command = UUID().uuidString
        let result = try call("triage_orchestrate", input, resumed, command: command)
        XCTAssertEqual(result["missed_notes_delivered"] as? Int, 50)
        XCTAssertEqual(result["missed_note_delivery_has_more"] as? Bool, true)
        XCTAssertEqual((result["orchestration"] as? JSON)?["missed_note_delivery_pending"] as? Bool, true)
        for id in ids.prefix(50) { XCTAssertEqual(try missedReceipts(f, id).count, 1) }
        for id in ids.suffix(2) { XCTAssertTrue(try missedReceipts(f, id).isEmpty) }
        XCTAssertEqual(try jsonString(call("triage_orchestrate", input, resumed, command: command)), try jsonString(result))
        for id in ids.suffix(2) { XCTAssertTrue(try missedReceipts(f, id).isEmpty, "A command replay cannot drain another legacy page.") }
        let next = try call("triage_orchestrate", missedOrchestrateInput(f, "checkpoint"), resumed)
        XCTAssertEqual(next["missed_notes_delivered"] as? Int, 2)
        XCTAssertEqual(next["missed_note_delivery_has_more"] as? Bool, false)
        XCTAssertEqual((next["orchestration"] as? JSON)?["missed_note_delivery_pending"] as? Bool, false)
        for id in ids { XCTAssertEqual(try missedReceipts(f, id).count, 1) }
        let empty = try call("triage_orchestrate", missedOrchestrateInput(f, "checkpoint"), resumed)
        XCTAssertEqual(empty["missed_notes_delivered"] as? Int, 0)
    }

    func testTriageMissedSecondNativeResumePreservesUndrainedLegacyWindow() throws {
        let f = try missedFixture(), resumed = try missedResumeConversation(f.p, f.o)
        let ids = try missedLegacyNotes(f, count: 52)
        let first = try call("triage_orchestrate", missedOrchestrateInput(f, "resume"), resumed)
        XCTAssertEqual(first["missed_notes_delivered"] as? Int, 50)
        XCTAssertEqual(first["missed_note_delivery_has_more"] as? Bool, true)
        let again = try missedResumeConversation(f.p, resumed)
        let secondGapNote = try missedNote(f, f.peer)
        try router.dbQueue.write { db in
            var note = try router.record(db, secondGapNote["id"] as! String, type: "message")
            note.removeValue(forKey: "delivery_omissions")
            try router.save(db, note, type: "message")
        }
        var before: [String: [String]] = [:]
        for id in ids + [secondGapNote["id"] as! String] {
            before[id] = try missedReceipts(f, id).compactMap { $0["id"] as? String }
        }
        for id in ids.prefix(50) { XCTAssertFalse(before[id]!.isEmpty) }
        for id in ids.suffix(2) { XCTAssertTrue(before[id]!.isEmpty) }
        let input = try missedOrchestrateInput(f, "resume"), command = UUID().uuidString
        let result = try call("triage_orchestrate", input, again, command: command)
        XCTAssertEqual(result["missed_notes_delivered"] as? Int, 3)
        XCTAssertEqual(result["missed_note_delivery_has_more"] as? Bool, false)
        let orchestration = try XCTUnwrap(result["orchestration"] as? JSON)
        XCTAssertEqual(orchestration["missed_note_delivery_pending"] as? Bool, false)
        XCTAssertEqual((orchestration["missed_note_windows"] as? [JSON])?.count, 2)
        XCTAssertEqual(Set(orchestration["missed_note_orchestration_ids"] as? [String] ?? []),
                       Set([(f.group["orchestration"] as! JSON)["id"] as! String, (first["orchestration"] as! JSON)["id"] as! String]))
        // Existing native redelivery is outside this command. Compare the full
        // receipt IDs at its boundary, rather than counting all generations.
        for id in ids.prefix(50) {
            XCTAssertEqual(try missedReceipts(f, id).compactMap { $0["id"] as? String }, before[id])
        }
        for id in Array(ids.suffix(2)) + [secondGapNote["id"] as! String] { XCTAssertEqual(try missedReceipts(f, id).count, 1) }
        XCTAssertEqual(try jsonString(call("triage_orchestrate", input, again, command: command)), try jsonString(result))
        let next = try call("triage_orchestrate", missedOrchestrateInput(f, "checkpoint"), again)
        XCTAssertEqual(next["missed_notes_delivered"] as? Int, 0)
        for id in ids.prefix(50) {
            XCTAssertEqual(try missedReceipts(f, id).compactMap { $0["id"] as? String }, before[id])
        }
        for id in Array(ids.suffix(2)) + [secondGapNote["id"] as! String] { XCTAssertEqual(try missedReceipts(f, id).count, 1) }
    }

    func testTriageCurrentRoutingMatchesLegacyOverGeneratedSendersAudiencesAndHolders() throws {
        let f = try missedFixture()
        var cases = 0
        try router.dbQueue.write { db in
            let task = try router.record(db, f.task["id"] as! String, type: "task")
            func recipient(_ caller: Caller, _ role: String) throws -> JSON {
                let session = try router.record(db, caller.sessionID!, type: "session")
                return ["project_id": f.p["id"]!, "session_id": caller.sessionID!, "recipient_role": role,
                        "display_name": session["label"] ?? "Worker", "authorization_generation": router.sessionGeneration(session)]
            }
            let holder = try recipient(f.holder, "handler"), child = try recipient(f.peer, "registered_child")
            let orchestratorHolder = try recipient(f.o, "handler"), orchestratorChild = try recipient(f.o, "registered_child")
            let configurations: [[JSON]] = [[], [holder], [holder, child], [orchestratorHolder],
                                            [orchestratorHolder, child], [holder, orchestratorChild], [child, holder]]
            let senders: [String?] = [nil, f.o.sessionID, f.holder.sessionID, f.peer.sessionID]
            func normalized(_ deliveries: [JSON]) throws -> [String] {
                try deliveries.map { value in
                    var receipt = value
                    for key in ["id", "message_id", "created_at", "updated_at"] { receipt.removeValue(forKey: key) }
                    return try jsonString(receipt)
                }.sorted()
            }
            func deliver(_ recipients: [JSON], sender: String?) throws -> [JSON] {
                var message: JSON = ["id": UUID().uuidString, "project_id": f.p["id"]!, "task_id": f.task["id"]!,
                    "origin": "agent", "kind": "note", "body": "Generated current routing case", "revision": 1, "created_at": now()]
                if let sender { message["author_session_id"] = sender }
                try router.save(db, message, type: "message")
                return try router.queueOrdinaryDeliveries(db, message: message, recipients: recipients)
            }
            for holders in configurations {
                for sender in senders {
                    for audience in TicketAudience.allCases {
                        let legacy = try missedLegacyRouting(db, task: task, holders: holders, sender: sender, audience: audience)
                        let current = try router.withTriageOrchestratorCopy(db, task: task, holders: holders, sender: sender, audience: audience)
                        let context = "case \(cases): \(audience.rawValue), sender \(sender ?? "owner"), \(holders.count) holders"
                        XCTAssertEqual(try legacy.map { try jsonString($0) }, try current.map { try jsonString($0) }, context)
                        let oldDeliveries = try deliver(legacy, sender: sender), newDeliveries = try deliver(current, sender: sender)
                        XCTAssertEqual(try normalized(oldDeliveries), try normalized(newDeliveries), context)
                        XCTAssertEqual(Set(newDeliveries.compactMap { $0["recipient_session_id"] as? String }).count, newDeliveries.count, context)
                        if let sender { XCTAssertFalse(newDeliveries.contains { $0["recipient_session_id"] as? String == sender }, context) }
                        cases += 1
                    }
                }
            }
        }
        XCTAssertEqual(cases, 84)
    }
}

// Frozen from base6 (649c1e0), with only router qualification changed.
extension EvidenceAuthorityTests {
    private func missedLegacyRecipient(_ db: Database, group: JSON) -> JSON? {
        guard let orchestration = group["orchestration"] as? JSON, orchestration["state"] as? String == "active",
              let sid = orchestration["session_id"] as? String, let pid = group["project_id"] as? String,
              let session = try? router.scoped(db, sid, pid, type: "session"), session["role"] as? String == "worker",
              router.canReceive(session, project: pid),
              router.sessionGeneration(session) == orchestration["session_authorization_generation"] as? String else { return nil }
        return ["project_id": pid, "session_id": sid, "recipient_role": "triage_orchestrator", "triage_id": group["id"] ?? NSNull(),
                "display_name": session["label"] ?? router.sessionThreadLabel(session), "authorization_generation": router.sessionGeneration(session)]
    }


    private func missedLegacyRouting(_ db: Database, task: JSON, holders allHolders: [JSON], sender: String?,
                                    audience: TicketAudience = .all) throws -> [JSON] {
        let stored = try StoredTaskRecord(task), pid = stored.projectID
        let key = task["key"] as? String ?? "this ticket"
        let group = try router.ticketOrchestratedTriage(db, task: task)
        let orchestrator = group.flatMap { missedLegacyRecipient(db, group: $0) }
        if audience == .orchestrator {
            guard group != nil else {
                throw CoreError("TRIAGE_ORCHESTRATOR_REQUIRED", "\(key) is not in a Triage with an orchestrator. Use audience all or holder. No message was saved.")
            }
            guard orchestrator != nil else {
                throw CoreError("RECIPIENT_CHANGED", "The Triage orchestrator's route ended or its authorization generation changed. No message was saved.")
            }
        }
        let holderIDs = Set(allHolders.compactMap { $0["session_id"] as? String })
        let root = allHolders.first { $0["recipient_role"] as? String == "handler" } ?? allHolders.first
        let holderThread = (root?["session_id"] as? String).flatMap { try? router.scoped(db, $0, pid, type: "session") }.map(router.sessionThreadLabel)
        var holders = audience == .orchestrator ? [] : allHolders.filter { $0["session_id"] as? String != sender }
        guard audience != .holder, var copy = orchestrator, let osid = copy["session_id"] as? String, osid != sender,
              audience == .orchestrator || !holderIDs.contains(osid) else { return holders }
        if let holderThread {
            copy["label"] = !holders.isEmpty ? "Also sent to \(holderThread), which holds \(key)."
                : audience == .orchestrator ? "Sent to the Triage orchestrator only; \(holderThread) holds \(key)."
                : "Sent by \(holderThread), which holds \(key)."
        } else {
            copy["label"] = "\(key) has no current holder; sent to the Triage orchestrator."
        }
        let orchestratorThread = (try? router.scoped(db, osid, pid, type: "session")).map(router.sessionThreadLabel) ?? osid
        let triageName = group?["name"] as? String ?? "its Triage"
        holders = holders.map { var holder = $0; holder["label"] = "Also sent to \(orchestratorThread), which orchestrates \(triageName)."; return holder }
        return holders + [copy]
    }

}

// VS1 independent regression: retained pre-upgrade mandatory exact-recipient
// notices lack the newly introduced omission field. Keep ordinary exact routes
// distinct; this test asserts the ticket's unrestricted missed-note requirement.
extension EvidenceAuthorityTests {
    func testVS1LegacyMandatoryRoleChangeMustReachResumedOrchestrator() throws {
        let f = try missedFixture(), resumed = try missedResumeConversation(f.p, f.o)
        let project = try missedRecord(f.p["id"]!, "project")
        let takeover = try call("work_takeover", ["project_id": f.p["id"]!, "task_id": f.task["id"]!,
            "expected_revision": try missedRecord(f.task["id"]!, "task")["revision"]!,
            "reason": "Independent reviewer synthetic takeover", "policy_revision": project["policy_revision"] ?? 1], f.peer)
        let noticeRef = try XCTUnwrap((takeover["takeover_notices"] as? [JSON])?.first)
        let notice = try missedRecord(noticeRef["message_id"]!, "message")
        _ = try missedOmission(f, notice)
        print("VS1 takeover notice reply has omission=\(noticeRef["delivery_omissions"] != nil)")
        try router.dbQueue.write { db in
            var legacy = try router.record(db, notice["id"] as! String, type: "message")
            legacy.removeValue(forKey: "delivery_omissions")
            XCTAssertNil(legacy["ordinary_routing"])
            XCTAssertNil(legacy["human_request_id"])
            XCTAssertEqual(legacy["requires_action"] as? Bool, false)
            try router.save(db, legacy, type: "message")
        }
        let result = try call("triage_orchestrate", missedOrchestrateInput(f, "resume"), resumed)
        print("VS1 legacy mandatory replay count=\(result["missed_notes_delivered"] ?? -1) has_more=\(result["missed_note_delivery_has_more"] ?? true)")
        XCTAssertEqual(result["missed_notes_delivered"] as? Int, 1, "The mandatory member-ticket notice was missed while binding was stale")
        XCTAssertEqual(try missedReceipts(f, notice["id"]!).count, 1)
    }
}

extension EvidenceAuthorityTests {
    private func missedLegacyRoleNotice(_ reference: JSON) throws -> JSON {
        let notice = try missedRecord(reference["message_id"]!, "message")
        return try router.dbQueue.write { db in
            var legacy = notice
            legacy.removeValue(forKey: "delivery_omissions")
            XCTAssertNil(legacy["ordinary_routing"])
            XCTAssertNil(legacy["human_request_id"])
            XCTAssertEqual(legacy["requires_action"] as? Bool, false)
            XCTAssertEqual(legacy["origin"] as? String, "agent")
            XCTAssertEqual(legacy["kind"] as? String, "note")
            try router.save(db, legacy, type: "message")
            return legacy
        }
    }

    private func missedTakeover(_ f: MissedFixture, _ caller: Caller, command: String = UUID().uuidString) throws -> JSON {
        try call("work_takeover", ["project_id": f.p["id"]!, "task_id": f.task["id"]!,
            "expected_revision": try missedRecord(f.task["id"]!, "task")["revision"]!,
            "reason": "Continue the member ticket during Triage recovery"], caller, command: command)
    }

    private func missedFreshRoleClaim() throws -> (f: MissedFixture, attempt: JSON) {
        var f = try missedFixture()
        f.task = try ready(f.p)
        _ = try call("group_membership", ["project_id": f.p["id"]!, "group_id": f.group["id"]!,
            "expected_revision": try missedRecord(f.group["id"]!, "group")["revision"]!,
            "task_id": f.task["id"]!, "action": "add"], f.o)
        let attempt = try claim(f.p, missedRecord(f.task["id"]!, "task"), files: [["path": "Sources", "access": "write"]], caller: f.holder)
        return (f, attempt)
    }

    func testTriageMissedLegacyHandoffReplaysOnceButSameAgeExactNoteStaysPrivate() throws {
        let (f, attempt) = try missedFreshRoleClaim(), resumed = try missedResumeConversation(f.p, f.o)
        var input = auth(f.p, attempt)
        input["target_session_id"] = f.peer.sessionID!; input["summary"] = "Continue from the saved checkpoint"
        let offer = try call("work_handoff_offer", input, f.holder)
        let accepted = try call("work_handoff_accept", ["project_id": f.p["id"]!, "offer_id": offer["id"]!], f.peer)
        let reference = try XCTUnwrap((accepted["handoff_notices"] as? [JSON])?.first)
        let notice = try missedLegacyRoleNotice(reference)
        let privateNote = try missedNote(f, f.peer, ["body": notice["body"]!, "recipient": ["kind": "session", "session_id": f.holder.sessionID!]])
        try router.dbQueue.write { db in
            var sameAge = try router.record(db, privateNote["id"] as! String, type: "message")
            sameAge["created_at"] = notice["created_at"]
            XCTAssertNil(sameAge["ordinary_routing"]); XCTAssertNil(sameAge["delivery_omissions"])
            try router.save(db, sameAge, type: "message")
        }
        let resume = try missedOrchestrateInput(f, "resume"), command = UUID().uuidString
        let result = try call("triage_orchestrate", resume, resumed, command: command)
        XCTAssertEqual(result["missed_notes_delivered"] as? Int, 1)
        XCTAssertEqual(result["missed_note_delivery_has_more"] as? Bool, false)
        XCTAssertEqual(try missedReceipts(f, notice["id"]!).count, 1)
        XCTAssertEqual(try missedReceipts(f, privateNote["id"]!).count, 0)
        XCTAssertEqual(try jsonString(call("triage_orchestrate", resume, resumed, command: command)), try jsonString(result))
        XCTAssertEqual(try call("triage_orchestrate", missedOrchestrateInput(f, "checkpoint"), resumed)["missed_notes_delivered"] as? Int, 0)
        XCTAssertEqual(try missedReceipts(f, notice["id"]!).count, 1)
        XCTAssertEqual(try missedReceipts(f, privateNote["id"]!).count, 0)
    }

    func testTriageMissedLegacyRoleChangesPageFiftyOfFiftyTwoAndDeduplicate() throws {
        let f = try missedFixture(), resumed = try missedResumeConversation(f.p, f.o)
        var ids: [String] = []
        for index in 0..<52 {
            let taken = try missedTakeover(f, index.isMultiple(of: 2) ? f.peer : f.holder)
            let reference = try XCTUnwrap((taken["takeover_notices"] as? [JSON])?.first)
            ids.append(try missedLegacyRoleNotice(reference)["id"] as! String)
        }
        let input = try missedOrchestrateInput(f, "resume"), command = UUID().uuidString
        let result = try call("triage_orchestrate", input, resumed, command: command)
        XCTAssertEqual(result["missed_notes_delivered"] as? Int, 50)
        XCTAssertEqual(result["missed_note_delivery_has_more"] as? Bool, true)
        XCTAssertEqual(try ids.reduce(0) { try $0 + missedReceipts(f, $1).count }, 50)
        XCTAssertEqual(try jsonString(call("triage_orchestrate", input, resumed, command: command)), try jsonString(result))
        XCTAssertEqual(try ids.reduce(0) { try $0 + missedReceipts(f, $1).count }, 50)
        let next = try call("triage_orchestrate", missedOrchestrateInput(f, "checkpoint"), resumed)
        XCTAssertEqual(next["missed_notes_delivered"] as? Int, 2)
        XCTAssertEqual(next["missed_note_delivery_has_more"] as? Bool, false)
        XCTAssertEqual(try call("triage_orchestrate", missedOrchestrateInput(f, "checkpoint"), resumed)["missed_notes_delivered"] as? Int, 0)
        for id in ids { XCTAssertEqual(try missedReceipts(f, id).count, 1) }
    }

    func testTriageMissedLegacyTakeoverCopiesOnlyFirstNoticeForMultipleEarlierHolders() throws {
        let (f, attempt) = try missedFreshRoleClaim()
        var input = auth(f.p, attempt)
        input["child_session_id"] = f.peer.sessionID!
        input["file_scopes"] = [["path": "Sources/Child.swift", "access": "write"]]
        let delegation = try call("work_delegate", input, f.holder)
        _ = try call("work_child_accept", ["project_id": f.p["id"]!, "delegation_id": delegation["id"]!], f.peer)
        let taker = try native(f.p, "legacy-taker", domain: "codex:legacy-taker")
        let resumed = try missedResumeConversation(f.p, f.o)
        let taken = try missedTakeover(f, taker), references = try XCTUnwrap(taken["takeover_notices"] as? [JSON])
        XCTAssertEqual(references.count, 2)
        let notices = try references.map(missedLegacyRoleNotice)
        let result = try call("triage_orchestrate", missedOrchestrateInput(f, "resume"), resumed)
        XCTAssertEqual(result["missed_notes_delivered"] as? Int, 1)
        XCTAssertEqual(try missedReceipts(f, notices[0]["id"]!).count, 1)
        XCTAssertEqual(try missedReceipts(f, notices[1]["id"]!).count, 0, "The original route copied only notices[0] to the orchestrator.")
    }

    func testTriageMissedLegacyRoleChangeRejectsMismatchedStoredLinks() throws {
        for field in ["project_id", "task_id", "session_id", "principal", "message_id"] {
            let f = try missedFixture(), resumed = try missedResumeConversation(f.p, f.o), command = UUID().uuidString
            let taken = try missedTakeover(f, f.peer, command: command)
            let notice = try missedLegacyRoleNotice(XCTUnwrap((taken["takeover_notices"] as? [JSON])?.first))
            try router.dbQueue.write { db in
                let literal = try XCTUnwrap(String.fetchOne(db, sql: "SELECT result FROM commands WHERE principal=? AND command_id=?", arguments: [f.peer.principal, command]))
                var result = jsonObject(literal), data = result["data"] as! JSON
                if field == "message_id" {
                    var references = data["takeover_notices"] as! [JSON]
                    references[0]["message_id"] = UUID().uuidString; data["takeover_notices"] = references
                } else if field != "principal" { data[field] = UUID().uuidString }
                result["data"] = data
                try db.execute(sql: "UPDATE commands SET result=?,principal=? WHERE principal=? AND command_id=?",
                    arguments: [try jsonString(result), field == "principal" ? "unrelated-principal" : f.peer.principal, f.peer.principal, command])
            }
            let result = try call("triage_orchestrate", missedOrchestrateInput(f, "resume"), resumed)
            XCTAssertEqual(result["missed_notes_delivered"] as? Int, 0, field)
            XCTAssertEqual(try missedReceipts(f, notice["id"]!).count, 0, field)
        }
    }

    func testTriageMissedLegacyRoleChangeWithExpiredLinkIsNotGuessedFromHistoryOrText() throws {
        let f = try missedFixture(), resumed = try missedResumeConversation(f.p, f.o), command = UUID().uuidString
        let taken = try missedTakeover(f, f.peer, command: command)
        let notice = try missedLegacyRoleNotice(XCTUnwrap((taken["takeover_notices"] as? [JSON])?.first))
        let date = Date().addingTimeInterval(CommandRouter.commandMarkInterval + 1)
        try router.pruneRoutineRecords(now: date)
        try router.pruneRoutineRecords(now: date.addingTimeInterval(CommandRouter.commandResultRetention + 1))
        try router.dbQueue.read { db in
            let literal = try XCTUnwrap(String.fetchOne(db, sql: "SELECT result FROM commands WHERE principal=? AND command_id=?", arguments: [f.peer.principal, command]))
            XCTAssertTrue(CommandRouter.isPrunedResult(jsonObject(literal)))
            let attempt = try router.record(db, taken["id"] as! String, type: "attempt")
            XCTAssertNil(attempt["takeover_notices"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events WHERE project_id=? AND entity_id=? AND kind='work_taken_over'", arguments: [f.p["id"] as! String, f.task["id"] as! String]), 1)
        }
        let result = try call("triage_orchestrate", missedOrchestrateInput(f, "resume"), resumed)
        XCTAssertEqual(result["missed_notes_delivered"] as? Int, 0)
        XCTAssertEqual(try missedReceipts(f, notice["id"]!).count, 0)
    }
}
