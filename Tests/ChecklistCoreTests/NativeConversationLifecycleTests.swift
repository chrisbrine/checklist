import XCTest
@testable import ChecklistCore

// Disposable Core fixtures establish atomic behavior, not real host closure or
// OS PID/socket reuse. Those acceptance observations remain native-only.
extension EvidenceAuthorityTests {
    private var lifecycleOwner: Caller { Caller(role: "owner", installation: "native-lifecycle", projectIDs: []) }
    private func closure(_ project: JSON, _ worker: Caller, domain: String? = nil,
                         process: String = "gone", registry: String = "absent") throws -> VerifiedNativeClosure {
        let generation = try router.dbQueue.read { try router.sessionGeneration(router.record($0, worker.sessionID!, type: "session")) }
        return VerifiedNativeClosure(projectID: project["id"] as! String, sessionID: worker.sessionID!,
            installation: worker.installation, executionDomain: domain ?? worker.executionDomain!, provider: "claude",
            authorizationGeneration: generation,
            processState: process, registryState: registry, registryDigest: nil)
    }
    func testMessageDeliveryReadBySenderHandlerAndProjectReader() throws {
        let p = try project(), t = try ready(p)
        let sender = try native(p, "receipt-sender", domain: "codex:201:1:0")
        let handler = try native(p, "receipt-handler", domain: "codex:202:1:0")
        let reader = try native(p, "receipt-reader", domain: "codex:203:1:0")
        _ = try claim(p, t, caller: handler)
        let note = try call("message_send", ["project_id": p["id"]!, "task_id": t["id"]!, "body": "Private body must not appear in receipt metadata"], sender)
        let delivery = try XCTUnwrap((note["deliveries"] as? [JSON])?.first)
        try router.dbQueue.write { db in
            var stored = try router.record(db, delivery["id"] as! String, type: "delivery")
            stored["transport_receipt"] = ["credential": "secret-transport-token"]
            stored["response_ref"] = ["body": "private recipient response"]
            try router.save(db, stored, type: "delivery")
        }
        let input: JSON = ["project_id": p["id"]!, "task_id": t["id"]!, "message_id": note["id"]!]
        // Read-only assistants need neither receive_messages nor note-writing permission.
        let assistant = Caller(role: "assistant", installation: "read-only", projectIDs: [p["id"] as! String], assistantGrants: [p["id"] as! String: ["read": true]])
        for caller in [sender, handler, reader, assistant] {
            let read = try call("message_delivery_list", input, caller)
            let receipts = try XCTUnwrap(read["deliveries"] as? [JSON])
            XCTAssertEqual(receipts.count, 1)
            let receipt = receipts[0]
            XCTAssertEqual(receipt["id"] as? String, delivery["id"] as? String)
            XCTAssertEqual(receipt["message_id"] as? String, note["id"] as? String)
            XCTAssertEqual(receipt["recipient_session_id"] as? String, handler.sessionID)
            XCTAssertEqual(receipt["recipient_authorization_generation"] as? String, delivery["recipient_authorization_generation"] as? String)
            XCTAssertEqual(receipt["state"] as? String, "queued")
            XCTAssertEqual(receipt["push_state"] as? String, "unavailable"); XCTAssertNotNil(receipt["created_at"])
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: read), as: UTF8.self)
            for secret in ["Private body", "secret-transport-token", "private recipient response", "transport_receipt", "response_ref"] { XCTAssertFalse(encoded.contains(secret)) }
        }
        // A retained delivered receipt is readable; public message_ack cannot mint this stage.
        try router.dbQueue.write { db in
            var stored = try router.record(db, delivery["id"] as! String, type: "delivery")
            stored["state"] = "delivered"; stored["delivered_at"] = "2026-10-22T16:00:00Z"
            try router.save(db, stored, type: "delivery")
        }
        var receipt = (try call("message_delivery_list", input, sender)["deliveries"] as! [JSON])[0]
        XCTAssertEqual(receipt["state"] as? String, "delivered"); XCTAssertNotNil(receipt["delivered_at"])
        _ = try call("message_ack", ["project_id": p["id"]!, "delivery_id": delivery["id"]!, "stage": "acknowledged"], handler)
        receipt = (try call("message_delivery_list", input, sender)["deliveries"] as! [JSON])[0]
        XCTAssertEqual(receipt["state"] as? String, "acknowledged"); XCTAssertNotNil(receipt["acknowledged_at"])
        let tool = try XCTUnwrap(router.toolCatalog(assistant).first { $0["name"] as? String == "message_delivery_list" })
        XCTAssertEqual((tool["annotations"] as? JSON)?["readOnlyHint"] as? Bool, true)
        // CL-248: a ticket note by task_id or a ticket-free Triage note by triage_id.
        XCTAssertEqual(Set((tool["inputSchema"] as! JSON)["required"] as! [String]), ["project_id", "message_id"])
        XCTAssertNotNil(((tool["inputSchema"] as! JSON)["properties"] as? JSON)?["triage_id"])
    }
    func testMessageDeliveryReadRefusesOutsideScopeAndOtherTicketOrPrivateConversation() throws {
        let p = try project(), t = try ready(p), other = try ready(p)
        let sender = try native(p, "receipt-scoped-sender", domain: "codex:204:1:0")
        let note = try call("message_send", ["project_id": p["id"]!, "task_id": t["id"]!, "body": "Scoped note"], sender)
        let input: JSON = ["project_id": p["id"]!, "task_id": t["id"]!, "message_id": note["id"]!]
        let outsider = Caller(role: "worker", installation: "outsider", projectIDs: [], workspace: workspace.path)
        assertCode("FORBIDDEN") { _ = try self.call("message_delivery_list", input, outsider) }
        let revokedSender = Caller(role: "worker", installation: sender.installation, projectIDs: [], sessionID: sender.sessionID, workspace: workspace.path, executionDomain: sender.executionDomain)
        assertCode("FORBIDDEN") { _ = try self.call("message_delivery_list", input, revokedSender) }
        let noRead = Caller(role: "assistant", installation: "no-read", projectIDs: [p["id"] as! String], assistantGrants: [p["id"] as! String: ["read": false]])
        assertCode("FORBIDDEN") { _ = try self.call("message_delivery_list", input, noRead) }
        var wrong = input; wrong["task_id"] = other["id"]!
        assertCode("NOT_FOUND") { _ = try self.call("message_delivery_list", wrong, sender) }
        let privateID = UUID().uuidString
        try router.dbQueue.write { db in
            try router.save(db, ["id": privateID, "project_id": p["id"]!, "body": "Other participants only", "revision": 1], type: "message")
        }
        wrong = input; wrong["message_id"] = privateID
        assertCode("NOT_FOUND") { _ = try self.call("message_delivery_list", wrong, sender) }
        let otherRoot = directory.appendingPathComponent("other-project")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let otherProject = try call("project_create", ["name": "Other project", "key_prefix": "O", "root_path": otherRoot.path])
        let otherTask = try ready(otherProject)
        let otherNote = try call("message_send", ["project_id": otherProject["id"]!, "task_id": otherTask["id"]!, "body": "Another project"])
        wrong = input; wrong["message_id"] = otherNote["id"]!
        assertCode("NOT_FOUND") { _ = try self.call("message_delivery_list", wrong, sender) }
    }
    func testMessageDeliveryReadSavedForPickupDoesNotCreateDelivery() throws {
        let p = try project(), t = try ready(p), sender = try native(p, "saved-sender", domain: "codex:205:1:0")
        let note = try call("message_send", ["project_id": p["id"]!, "task_id": t["id"]!, "body": "For future pickup"], sender)
        let read = try call("message_delivery_list", ["project_id": p["id"]!, "task_id": t["id"]!, "message_id": note["id"]!], sender)
        XCTAssertEqual(read["delivery_status"] as? String, "saved_for_pickup")
        XCTAssertEqual((read["deliveries"] as? [JSON])?.count, 0)
        XCTAssertEqual(read["created_at"] as? String, note["created_at"] as? String)
        XCTAssertTrue(try router.dbQueue.read { try router.records($0, type: "delivery", project: (p["id"] as! String)).isEmpty })
    }
    func testMessageDeliveryReadPreservesAcknowledgmentAfterNativeClosure() throws {
        let p = try project(), t = try ready(p), worker = try native(p, "acked-closure", domain: "claude:206:1:0", provider: "claude")
        _ = try claim(p, t, caller: worker)
        let note = try call("message_send", ["project_id": p["id"]!, "task_id": t["id"]!, "body": "Acknowledged before closure"])
        let delivery = try XCTUnwrap((note["deliveries"] as? [JSON])?.first)
        _ = try call("message_ack", ["project_id": p["id"]!, "delivery_id": delivery["id"]!, "stage": "acknowledged"], worker)
        _ = try router.reconcileVerifiedNativeClosure(closure(p, worker), caller: lifecycleOwner)
        let receipt = (try call("message_delivery_list", ["project_id": p["id"]!, "task_id": t["id"]!, "message_id": note["id"]!])["deliveries"] as! [JSON])[0]
        XCTAssertEqual(receipt["state"] as? String, "acknowledged"); XCTAssertNil(receipt["native_closure_ref"])
        let events = try call("history_list", ["project_id": p["id"]!, "task_id": t["id"]!])["events"] as! [JSON]
        XCTAssertFalse(events.contains { $0["kind"] as? String == "message_delivery_fenced" })
    }
    func testNativeClosureRejectsUnprovenOrDifferentRegistrationWithoutMutation() throws {
        let p = try project(), t = try ready(p), worker = try native(p, "closure", domain: "claude:123:5:0", provider: "claude")
        let a = try claim(p, t, caller: worker)
        assertCode("NATIVE_CLOSURE_UNPROVEN") { _ = try self.router.reconcileVerifiedNativeClosure(self.closure(p, worker), caller: self.owner) }
        assertCode("NATIVE_CLOSURE_UNPROVEN") { _ = try self.router.reconcileVerifiedNativeClosure(self.closure(p, worker, process: "running"), caller: self.lifecycleOwner) }
        assertCode("NATIVE_CLOSURE_UNPROVEN") { _ = try self.router.reconcileVerifiedNativeClosure(self.closure(p, worker, registry: "unknown"), caller: self.lifecycleOwner) }
        assertCode("RECIPIENT_CHANGED") { _ = try self.router.reconcileVerifiedNativeClosure(self.closure(p, worker, domain: "claude:123:6:0"), caller: self.lifecycleOwner) }
        let persisted = try router.dbQueue.read { try router.record($0, a["id"] as! String, type: "attempt") }
        XCTAssertEqual(persisted["state"] as? String, "active")
    }
    func testNativeClosureAtomicallyReleasesWithHistoryAndFencesQueuedDelivery() throws {
        let p = try project(), t = try ready(p), worker = try native(p, "closed", domain: "claude:123:5:0", provider: "claude")
        let a = try claim(p, t, caller: worker)
        let note = try call("message_send", ["project_id": p["id"]!, "task_id": t["id"]!, "body": "Queued before component closure"])
        let delivery = try XCTUnwrap((note["deliveries"] as? [JSON])?.first)
        let result = try router.reconcileVerifiedNativeClosure(closure(p, worker), caller: lifecycleOwner)
        XCTAssertEqual(result["released_attempt_ids"] as? [String], [a["id"] as! String])
        try router.dbQueue.read { db in
            let session = try router.record(db, worker.sessionID!, type: "session")
            let attempt = try router.record(db, a["id"] as! String, type: "attempt")
            let task = try router.record(db, t["id"] as! String, type: "task")
            let storedDelivery = try router.record(db, delivery["id"] as! String, type: "delivery")
            XCTAssertEqual(session["state"] as? String, "ended")
            XCTAssertEqual(attempt["state"] as? String, "released"); XCTAssertNil(attempt["token_hash"])
            XCTAssertEqual(attempt["native_closure_ref"] as? String, result["observation_ref"] as? String)
            XCTAssertNil(task["active_attempt_id"])
            XCTAssertEqual(task["status_id"] as? String, try router.status(db, p["id"] as! String, "queued")["id"] as? String)
            XCTAssertEqual(storedDelivery["state"] as? String, "queued"); XCTAssertFalse(try router.deliveryCurrent(db, storedDelivery))
        }
        let receipt = (try call("message_delivery_list", ["project_id": p["id"]!, "task_id": t["id"]!, "message_id": note["id"]!])["deliveries"] as! [JSON])[0]
        XCTAssertEqual(receipt["state"] as? String, "fenced")
        XCTAssertEqual(receipt["native_closure_ref"] as? String, result["observation_ref"] as? String)
        XCTAssertNotNil(receipt["fenced_at"]); XCTAssertNil(receipt["acknowledged_at"])
        _ = try router.reconcileVerifiedNativeClosure(closure(p, worker), caller: lifecycleOwner)
        let events = try call("history_list", ["project_id": p["id"]!, "task_id": t["id"]!])["events"] as! [JSON]
        let fences = events.filter { $0["kind"] as? String == "message_delivery_fenced" }
        XCTAssertEqual(fences.count, 1)
        let fence = try XCTUnwrap(fences.first?["data"] as? JSON)
        XCTAssertEqual(fence["delivery_id"] as? String, delivery["id"] as? String)
        XCTAssertEqual(fence["message_id"] as? String, note["id"] as? String)
        XCTAssertEqual(fence["native_closure_ref"] as? String, result["observation_ref"] as? String)
        var checkpoint = auth(p, a); checkpoint["progress"] = "stale fixture"
        assertCode("STALE_CLAIM") { _ = try self.call("work_checkpoint", checkpoint, worker) }
    }
    func testNativeClosureRepeatedObservationIsIdempotent() throws {
        let p = try project(), t = try ready(p), worker = try native(p, "repeat", domain: "claude:123:5:0", provider: "claude")
        _ = try claim(p, t, caller: worker)
        let first = try router.reconcileVerifiedNativeClosure(closure(p, worker), caller: lifecycleOwner)
        let id = first["observation_ref"] as! String
        let before = try router.dbQueue.read { try router.record($0, id, type: "native_closure") }
        let second = try router.reconcileVerifiedNativeClosure(closure(p, worker), caller: lifecycleOwner)
        let after = try router.dbQueue.read { try router.record($0, id, type: "native_closure") }
        XCTAssertEqual(before["revision"] as? Int, after["revision"] as? Int)
        XCTAssertEqual(second["released_attempt_ids"] as? [String], [])
    }
    func testNativeClosureRetainsSourceWriterUntilExplicitStopState() throws {
        let p = try project(), t = try ready(p), worker = try native(p, "writer", domain: "claude:123:5:0", provider: "claude")
        let a = try claim(p, t, files: [["path": "Sources", "access": "write"]], caller: worker), job = UUID().uuidString
        try router.dbQueue.write { db in
            try router.save(db, ["id": job, "project_id": p["id"]!, "task_id": t["id"]!, "attempt_id": a["id"]!, "state": "interrupted", "revision": 1], type: "source_execution")
        }
        let blocked = try router.reconcileVerifiedNativeClosure(closure(p, worker), caller: lifecycleOwner)
        XCTAssertEqual(blocked["pending_attempt_ids"] as? [String], [a["id"] as! String])
        let retained = try router.dbQueue.read { try router.record($0, a["id"] as! String, type: "attempt") }
        XCTAssertEqual(retained["state"] as? String, "active"); XCTAssertNotNil(retained["token_hash"])
        try router.dbQueue.write { db in
            var execution = try router.record(db, job, type: "source_execution")
            execution["state"] = "stopped"; try router.save(db, router.revised(execution), type: "source_execution")
        }
        let released = try router.reconcileVerifiedNativeClosure(closure(p, worker), caller: lifecycleOwner)
        XCTAssertEqual(released["released_attempt_ids"] as? [String], [a["id"] as! String])
    }
    func testNativeClosureRetainsParentWhileRealDelegatedFixtureWriterLives() throws {
        let p = try project(), t = try ready(p), parent = try native(p, "parent-closure", domain: "claude:123:5:0", provider: "claude")
        let child = try native(p, "child-closure", domain: "claude:124:5:0", provider: "claude")
        let a = try claim(p, t, files: [["path": "Sources", "access": "write"]], caller: parent)
        var input = auth(p, a); input["child_session_id"] = child.sessionID!; input["file_scopes"] = [["path": "Sources/Child.swift", "access": "write"]]
        let offer = try call("work_delegate", input, parent)
        let b = try call("work_child_accept", ["project_id": p["id"]!, "delegation_id": offer["id"]!], child)
        let blocked = try router.reconcileVerifiedNativeClosure(closure(p, parent), caller: lifecycleOwner)
        XCTAssertEqual(blocked["pending_attempt_ids"] as? [String], [a["id"] as! String])
        var release = auth(p, b); release["reason"] = "Component child stopped"; _ = try call("work_release", release, child)
        XCTAssertEqual(try router.reconcileVerifiedNativeClosure(closure(p, parent), caller: lifecycleOwner)["released_attempt_ids"] as? [String], [a["id"] as! String])
    }
    func testNewSessionAtSameFixtureAddressCannotReceiveOldQueuedDelivery() throws {
        let p = try project(), t = try ready(p), first = try native(p, "first-address", domain: "claude:123:5:0", provider: "claude")
        _ = try claim(p, t, caller: first)
        let note = try call("message_send", ["project_id": p["id"]!, "task_id": t["id"]!, "body": "Only the original fixture recipient"])
        _ = try router.reconcileVerifiedNativeClosure(closure(p, first), caller: lifecycleOwner)
        let second = try native(p, "second-address", domain: "claude:123:6:0", provider: "claude")
        let inbox = try call("session_inbox", ["project_id": p["id"]!], second)["deliveries"] as! [JSON]
        XCTAssertFalse(inbox.contains { $0["message_id"] as? String == note["id"] as? String })
    }
    private var bootstrapOwner: Caller { Caller(role: "owner", installation: "native-thread-bootstrap", projectIDs: []) }
    private func resumption(_ project: JSON, _ worker: Caller, installation: String = "fixture-resumed/2", domain: String = "claude:200:7:0") -> NativeSessionResumption {
        NativeSessionResumption(projectID: project["id"] as! String, sessionID: worker.sessionID!, provider: "claude",
            oldInstallation: worker.installation, oldExecutionDomain: worker.executionDomain!, newInstallation: installation, newExecutionDomain: domain)
    }
    func testResumedConversationGetsNewGenerationAndPicksUpReleasedWork() throws {
        let p = try project(), t = try ready(p), worker = try native(p, "resumed", domain: "claude:123:5:0", provider: "claude")
        let a = try claim(p, t, caller: worker)
        let note = try call("message_send", ["project_id": p["id"]!, "task_id": t["id"]!, "body": "Queued for the earlier process"])
        let closed = try router.reconcileVerifiedNativeClosure(closure(p, worker), caller: lifecycleOwner)
        let ended = try router.dbQueue.read { try router.record($0, worker.sessionID!, type: "session") }
        // Only the bundled connection service resumes, and only with a new process and generation.
        assertCode("FORBIDDEN") { _ = try self.router.resumeVerifiedNativeSession(self.resumption(p, worker), caller: self.owner) }
        assertCode("NATIVE_SESSION_MISMATCH") { _ = try self.router.resumeVerifiedNativeSession(self.resumption(p, worker, domain: worker.executionDomain!), caller: self.bootstrapOwner) }
        assertCode("NATIVE_SESSION_MISMATCH") { _ = try self.router.resumeVerifiedNativeSession(self.resumption(p, worker, installation: worker.installation), caller: self.bootstrapOwner) }
        let session = try router.resumeVerifiedNativeSession(resumption(p, worker), caller: bootstrapOwner)
        XCTAssertEqual(session["state"] as? String, "connected"); XCTAssertEqual(session["installation"] as? String, "fixture-resumed/2")
        XCTAssertEqual(session["execution_domain"] as? String, "claude:200:7:0"); XCTAssertNil(session["native_closure_ref"])
        XCTAssertEqual(session["prior_native_closure_refs"] as? [String], [closed["observation_ref"] as! String])
        XCTAssertNotEqual(session["authorization_generation"] as? String, ended["authorization_generation"] as? String)
        // The old generation keeps its released claim and fenced delivery; the resumed generation receives a new receipt.
        let resumed = Caller(role: "worker", installation: "fixture-resumed/2", projectIDs: [p["id"] as! String], sessionID: worker.sessionID!, workspace: workspace.path, executionDomain: "claude:200:7:0")
        var checkpoint = auth(p, a); checkpoint["progress"] = "old claim"
        assertCode("STALE_CLAIM") { _ = try self.call("work_checkpoint", checkpoint, resumed) }
        let inbox = try call("session_inbox", ["project_id": p["id"]!], resumed)["deliveries"] as! [JSON]
        let redelivered = try XCTUnwrap(inbox.first { $0["message_id"] as? String == note["id"] as? String })
        XCTAssertEqual(redelivered["recipient_authorization_generation"] as? String, session["authorization_generation"] as? String)
        XCTAssertNotNil(redelivered["resumed_from_delivery_id"])
        XCTAssertEqual(redelivered["resumed_native_closure_ref"] as? String, closed["observation_ref"] as? String)
        let info = try call("service_info", [:], resumed)
        let summary = try XCTUnwrap((info["native_recovery"] as? [JSON])?.first)
        let inboxSummary = try XCTUnwrap((call("session_inbox", ["project_id": p["id"]!], resumed)["native_recovery"] as? [JSON])?.first)
        XCTAssertEqual(try jsonString(summary), try jsonString(inboxSummary))
        let releasedClaim = try XCTUnwrap((summary["released_claims"] as? [JSON])?.first)
        XCTAssertEqual(releasedClaim["attempt_id"] as? String, a["id"] as? String)
        XCTAssertEqual(releasedClaim["key"] as? String, t["key"] as? String)
        XCTAssertNotNil(releasedClaim["released_at"])
        XCTAssertTrue((releasedClaim["recovery_step"] as? String ?? "").contains("work_claim"))
        XCTAssertEqual((summary["fenced_notices"] as? [JSON])?.count, 1)
        XCTAssertEqual((summary["fenced_notices"] as? [JSON])?.first?["body"] as? String, "Queued for the earlier process")
        XCTAssertFalse(bool(summary, "claims_restored")); XCTAssertFalse(bool(summary, "reading_is_acknowledgment"))
        // Repeated reads do not enqueue more copies or acknowledge either receipt.
        XCTAssertEqual((try call("session_inbox", ["project_id": p["id"]!], resumed)["deliveries"] as? [JSON])?.count, 1)
        let oldReceipt = (try call("message_delivery_list", ["project_id": p["id"]!, "task_id": t["id"]!, "message_id": note["id"]!], resumed)["deliveries"] as! [JSON])[0]
        XCTAssertEqual(oldReceipt["state"] as? String, "fenced")
        XCTAssertEqual(oldReceipt["native_closure_ref"] as? String, closed["observation_ref"] as? String)
        // The resumed thread picks the returned ticket up again with an ordinary claim.
        let returned = try router.dbQueue.read { try router.record($0, t["id"] as! String, type: "task") }
        let again = try claim(p, returned, caller: resumed)
        XCTAssertEqual(try router.dbQueue.read { try router.record($0, t["id"] as! String, type: "task") }["active_attempt_id"] as? String, again["id"] as? String)
        // A repeated resume or a replayed old closure cannot change the new generation.
        assertCode("RECIPIENT_CHANGED") { _ = try self.router.resumeVerifiedNativeSession(self.resumption(p, worker), caller: self.bootstrapOwner) }
        assertCode("RECIPIENT_CHANGED") { _ = try self.router.reconcileVerifiedNativeClosure(self.closure(p, worker), caller: self.lifecycleOwner) }
    }
    func testResumptionRecoveryIsPrivateAndRetainsAllReleasedClaims() throws {
        let p = try project(), tasks = try [ready(p), ready(p)]
        let worker = try native(p, "private-recovery", domain: "claude:123:5:0", provider: "claude")
        let attempts = try tasks.map { try claim(p, $0, caller: worker) }
        let acknowledged = try call("message_send", ["project_id": p["id"]!, "task_id": tasks[0]["id"]!, "body": "Already read"])
        let ack = try XCTUnwrap((acknowledged["deliveries"] as? [JSON])?.first)
        _ = try call("message_ack", ["project_id": p["id"]!, "delivery_id": ack["id"]!, "stage": "acknowledged"], worker)
        let notice = try call("message_send", ["project_id": p["id"]!, "task_id": tasks[1]["id"]!, "body": "Private stopped work notice"])
        _ = try router.reconcileVerifiedNativeClosure(closure(p, worker), caller: lifecycleOwner)
        let next = try router.resumeVerifiedNativeSession(resumption(p, worker), caller: bootstrapOwner)
        let resumed = Caller(role: "worker", installation: "fixture-resumed/2", projectIDs: [p["id"] as! String], sessionID: worker.sessionID!, workspace: workspace.path, executionDomain: "claude:200:7:0")
        let summary = try XCTUnwrap((call("service_info", [:], resumed)["native_recovery"] as? [JSON])?.first)
        XCTAssertEqual(Set((summary["released_claims"] as? [JSON] ?? []).compactMap { $0["attempt_id"] as? String }), Set(attempts.compactMap { $0["id"] as? String }))
        let inbox = try call("session_inbox", ["project_id": p["id"]!], resumed)
        let deliveries = inbox["deliveries"] as! [JSON]
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries[0]["message_id"] as? String, notice["id"] as? String)
        let other = try native(p, "foreign-recovery", domain: "claude:123:6:0", provider: "claude")
        XCTAssertTrue((try call("service_info", [:], other)["native_recovery"] as! [JSON]).isEmpty)
        let foreignInbox = try call("session_inbox", ["project_id": p["id"]!], other)
        XCTAssertTrue((foreignInbox["deliveries"] as! [JSON]).isEmpty)
        XCTAssertTrue((foreignInbox["native_recovery"] as! [JSON]).isEmpty)
        XCTAssertTrue((try call("service_info", [:], worker)["native_recovery"] as! [JSON]).isEmpty)
        assertCode("FORBIDDEN") { _ = try self.call("session_inbox", ["project_id": p["id"]!], worker) }
        let task = try call("task_get", ["project_id": p["id"]!, "task_id": tasks[0]["id"]!])
        XCTAssertTrue(((task["status_reason"] as? JSON)?["text"] as? String ?? "").contains("native closure"))
        // One more real mocked closure/resumption uses only that previous generation,
        // and the unacknowledged copy survives without un-fencing the original.
        _ = try router.reconcileVerifiedNativeClosure(closure(p, resumed), caller: lifecycleOwner)
        _ = try router.resumeVerifiedNativeSession(resumption(p, resumed, installation: "fixture-resumed/3", domain: "claude:300:8:0"), caller: bootstrapOwner)
        let third = Caller(role: "worker", installation: "fixture-resumed/3", projectIDs: [p["id"] as! String], sessionID: worker.sessionID!, workspace: workspace.path, executionDomain: "claude:300:8:0")
        let latest = try XCTUnwrap((call("service_info", [:], third)["native_recovery"] as? [JSON])?.first)
        XCTAssertNotEqual(latest["summary_id"] as? String, summary["summary_id"] as? String)
        XCTAssertTrue((latest["released_claims"] as! [JSON]).isEmpty)
        XCTAssertEqual((try call("session_inbox", ["project_id": p["id"]!], third)["deliveries"] as! [JSON]).count, 1)
        XCTAssertNotEqual(next["authorization_generation"] as? String, latest["summary_id"] as? String)
    }

    func testResumptionSummarySupportsEarlierBuildAndExcludesWithdrawnDirections() throws {
        let p = try project(), t = try ready(p), worker = try native(p,"legacy-summary",domain:"claude:123:5:0",provider:"claude")
        _ = try claim(p,t,caller:worker)
        let withdrawn = try call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"Withdraw this action","requires_action":true])
        _ = try call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"Action withdrawn","correction_of":withdrawn["id"]!,"kind":"retraction"])
        let addressed = try call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"Already resolved","requires_action":true])
        try router.dbQueue.write { db in
            var message = try router.record(db,addressed["id"] as! String,type:"message")
            message["addressed"] = true;try router.save(db,router.revised(message),type:"message")
        }
        let pending = try call("message_send",["project_id":p["id"]!,"task_id":t["id"]!,"body":"Still needs pickup"])
        _ = try router.reconcileVerifiedNativeClosure(closure(p,worker),caller:lifecycleOwner)
        let next = try router.resumeVerifiedNativeSession(resumption(p,worker),caller:bootstrapOwner)
        let resumed = Caller(role:"worker",installation:"fixture-resumed/2",projectIDs:[p["id"] as! String],sessionID:worker.sessionID!,workspace:workspace.path,executionDomain:"claude:200:7:0")
        let receipts = try call("session_inbox",["project_id":p["id"]!],resumed)["deliveries"] as! [JSON]
        for id in [withdrawn["id"] as! String,addressed["id"] as! String] {
            XCTAssertFalse(receipts.contains {$0["message_id"] as? String == id})
        }
        // Emulate the earlier build's resumed state: no fresh notice receipts.
        try router.dbQueue.write { db in
            for receipt in receipts { try db.execute(sql:"DELETE FROM records WHERE type='delivery' AND id=?",arguments:[receipt["id"] as! String]) }
        }
        let info = try call("service_info",[:],resumed), inbox = try call("session_inbox",["project_id":p["id"]!],resumed)
        XCTAssertTrue((inbox["deliveries"] as! [JSON]).isEmpty)
        let summary = try XCTUnwrap((info["native_recovery"] as? [JSON])?.first)
        XCTAssertEqual(try jsonString(info["native_recovery"]!),try jsonString(inbox["native_recovery"]!))
        let notices = summary["fenced_notices"] as! [JSON]
        XCTAssertTrue(notices.contains {$0["message_id"] as? String == pending["id"] as? String})
        for id in [withdrawn["id"] as! String,addressed["id"] as! String] { XCTAssertFalse(notices.contains {$0["message_id"] as? String == id}) }
        XCTAssertEqual(try router.dbQueue.read {try router.sessionGeneration(router.record($0,worker.sessionID!,type:"session"))},next["authorization_generation"] as? String)
    }
    func testNativeClosureOfChildDoesNotLabelActiveRootTicketReleased() throws {
        let p = try project(), t = try ready(p)
        let parent = try native(p,"live-root",domain:"claude:123:5:0",provider:"claude")
        let child = try native(p,"closed-child",domain:"claude:124:5:0",provider:"claude")
        let root = try claim(p,t,files:[["path":"Sources","access":"write"]],caller:parent)
        var input = auth(p,root);input["child_session_id"] = child.sessionID!;input["file_scopes"] = [["path":"Sources/Child.swift","access":"write"]]
        let offered = try call("work_delegate",input,parent)
        _ = try call("work_child_accept",["project_id":p["id"]!,"delegation_id":offered["id"]!],child)
        _ = try router.reconcileVerifiedNativeClosure(closure(p,child),caller:lifecycleOwner)
        let active = try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!])
        XCTAssertEqual(active["active_attempt_id"] as? String,root["id"] as? String)
        XCTAssertEqual(active["status_category"] as? String,"active")
        XCTAssertNil(active["status_reason"] as? JSON)
    }
    func testResumeRefusesOwnerDisconnectAndUnfinishedRelease() throws {
        let p = try project(), revoked = try native(p, "owner-revoked", domain: "claude:123:5:0", provider: "claude")
        let current = try router.dbQueue.read { try router.record($0, revoked.sessionID!, type: "session") }
        _ = try call("session_update", ["project_id": p["id"]!, "session_id": revoked.sessionID!, "state": "revoked", "expected_revision": current["revision"]!])
        assertCode("CONNECTION_REVOKED") { _ = try self.router.resumeVerifiedNativeSession(self.resumption(p, revoked), caller: self.bootstrapOwner) }
        // The owner's disconnect stays final after its process closes.
        _ = try router.reconcileVerifiedNativeClosure(closure(p, revoked), caller: lifecycleOwner)
        let closedAfterRevoke = try router.dbQueue.read { try router.record($0, revoked.sessionID!, type: "session") }
        XCTAssertEqual(closedAfterRevoke["state"] as? String, "ended"); XCTAssertEqual(closedAfterRevoke["owner_revoked"] as? Bool, true)
        assertCode("CONNECTION_REVOKED") { _ = try self.router.resumeVerifiedNativeSession(self.resumption(p, revoked), caller: self.bootstrapOwner) }
        // A running process has no closure to resume from.
        let running = try native(p, "running", domain: "claude:124:5:0", provider: "claude")
        assertCode("CONNECTION_REVOKED") { _ = try self.router.resumeVerifiedNativeSession(self.resumption(p, running), caller: self.bootstrapOwner) }
        // Work that is still stopping keeps the thread out until it returns for pickup.
        let t = try ready(p), writer = try native(p, "stopping", domain: "claude:125:5:0", provider: "claude")
        let a = try claim(p, t, files: [["path": "Sources", "access": "write"]], caller: writer), job = UUID().uuidString
        try router.dbQueue.write { db in
            try router.save(db, ["id": job, "project_id": p["id"]!, "task_id": t["id"]!, "attempt_id": a["id"]!, "state": "interrupted", "revision": 1], type: "source_execution")
        }
        _ = try router.reconcileVerifiedNativeClosure(closure(p, writer), caller: lifecycleOwner)
        assertCode("NATIVE_CLOSURE_PENDING") { _ = try self.router.resumeVerifiedNativeSession(self.resumption(p, writer), caller: self.bootstrapOwner) }
    }
    func testNativeClosureCannotReplayOntoOwnerReactivatedGeneration() throws {
        let p = try project(), t = try ready(p), worker = try native(p, "reactivated", domain: "claude:123:5:0", provider: "claude")
        _ = try claim(p, t, caller: worker)
        let staleProof = try closure(p, worker)
        _ = try router.reconcileVerifiedNativeClosure(staleProof, caller: lifecycleOwner)
        let ended = try router.dbQueue.read { try router.record($0, worker.sessionID!, type: "session") }
        _ = try call("session_update", ["project_id": p["id"]!, "session_id": worker.sessionID!, "state": "connected", "expected_revision": ended["revision"]!])
        let newerTask = try ready(p), newerAttempt = try claim(p, newerTask, caller: worker)
        assertCode("RECIPIENT_CHANGED") { _ = try self.router.reconcileVerifiedNativeClosure(staleProof, caller: self.lifecycleOwner) }
        assertCode("RECIPIENT_CHANGED") { _ = try self.router.reconcileVerifiedNativeClosure(self.closure(p, worker), caller: self.lifecycleOwner) }
        try router.dbQueue.read { db in
            XCTAssertEqual(try router.record(db, worker.sessionID!, type: "session")["state"] as? String, "connected")
            XCTAssertEqual(try router.record(db, newerAttempt["id"] as! String, type: "attempt")["state"] as? String, "active")
        }
    }
}
