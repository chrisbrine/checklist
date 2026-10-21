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
        // The old generation keeps its released claim and queued delivery.
        let resumed = Caller(role: "worker", installation: "fixture-resumed/2", projectIDs: [p["id"] as! String], sessionID: worker.sessionID!, workspace: workspace.path, executionDomain: "claude:200:7:0")
        var checkpoint = auth(p, a); checkpoint["progress"] = "old claim"
        assertCode("STALE_CLAIM") { _ = try self.call("work_checkpoint", checkpoint, resumed) }
        let inbox = try call("session_inbox", ["project_id": p["id"]!], resumed)["deliveries"] as! [JSON]
        XCTAssertFalse(inbox.contains { $0["message_id"] as? String == note["id"] as? String })
        // The resumed thread picks the returned ticket up again with an ordinary claim.
        let returned = try router.dbQueue.read { try router.record($0, t["id"] as! String, type: "task") }
        let again = try claim(p, returned, caller: resumed)
        XCTAssertEqual(try router.dbQueue.read { try router.record($0, t["id"] as! String, type: "task") }["active_attempt_id"] as? String, again["id"] as? String)
        // A repeated resume or a replayed old closure cannot change the new generation.
        assertCode("RECIPIENT_CHANGED") { _ = try self.router.resumeVerifiedNativeSession(self.resumption(p, worker), caller: self.bootstrapOwner) }
        assertCode("RECIPIENT_CHANGED") { _ = try self.router.reconcileVerifiedNativeClosure(self.closure(p, worker), caller: self.lifecycleOwner) }
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
