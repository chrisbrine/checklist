import Foundation
import GRDB

/// Produced only by the bundled service's authenticated native observer. There
/// is deliberately no public JSON command or worker-supplied closed flag.
public struct VerifiedNativeClosure: Sendable {
    public let projectID: String
    public let sessionID: String
    public let installation: String
    public let executionDomain: String
    public let provider: String
    public let authorizationGeneration: String
    public let processState: String
    public let registryState: String
    public let registryDigest: String?
    public init(projectID: String, sessionID: String, installation: String, executionDomain: String,
                provider: String, authorizationGeneration: String, processState: String, registryState: String, registryDigest: String?) {
        self.projectID = projectID; self.sessionID = sessionID; self.installation = installation
        self.executionDomain = executionDomain; self.provider = provider
        self.authorizationGeneration = authorizationGeneration
        self.processState = processState; self.registryState = registryState; self.registryDigest = registryDigest
    }
}

/// A host can resume a closed conversation (same native session ID) in a new
/// process. The bundled service supplies both generations after it verified the
/// new process; there is no public JSON command for this either.
public struct NativeSessionResumption: Sendable {
    public let projectID: String
    public let sessionID: String
    public let provider: String
    public let oldInstallation: String
    public let oldExecutionDomain: String
    public let newInstallation: String
    public let newExecutionDomain: String
    public init(projectID: String, sessionID: String, provider: String, oldInstallation: String, oldExecutionDomain: String,
                newInstallation: String, newExecutionDomain: String) {
        self.projectID = projectID; self.sessionID = sessionID; self.provider = provider
        self.oldInstallation = oldInstallation; self.oldExecutionDomain = oldExecutionDomain
        self.newInstallation = newInstallation; self.newExecutionDomain = newExecutionDomain
    }
}

extension CommandRouter {
    /// Reconnects a conversation whose earlier process had a verified closure. The
    /// session gets a new authorization generation; released attempts, history and
    /// deliveries queued for the ended generation stay with that generation.
    /// An owner disconnect (`revoked`) or a closure with work still stopping refuses.
    public func resumeVerifiedNativeSession(_ resumption: NativeSessionResumption, caller: Caller) throws -> [String: Any] {
        try owner(caller)
        guard caller.installation == "native-thread-bootstrap" else {
            throw CoreError("FORBIDDEN", "Only the bundled native connection service can resume a closed conversation.")
        }
        guard !resumption.newInstallation.isEmpty, !resumption.newExecutionDomain.isEmpty,
              !EnvelopeStorageIdentity.equal(resumption.newInstallation, resumption.oldInstallation),
              !EnvelopeStorageIdentity.equal(resumption.newExecutionDomain, resumption.oldExecutionDomain) else {
            throw CoreError("NATIVE_SESSION_MISMATCH", "A resumed conversation needs a new verified process and a new connection generation.")
        }
        let lease = try storageAdmission.acquire(); defer { lease.finish() }
        return try ArchiveStorageGate.withExclusive(root: root) { _ in
          try dbQueue.writeWithoutTransaction { db in
            var result: JSON = [:]
            try self.withValidatedDomainTransaction(db) {
            var session = try scoped(db, resumption.sessionID, resumption.projectID, type: "session")
            guard EnvelopeStorageIdentity.equal(session["installation"] as? String ?? "", resumption.oldInstallation),
                  EnvelopeStorageIdentity.equal(session["execution_domain"] as? String ?? "", resumption.oldExecutionDomain),
                  EnvelopeStorageIdentity.equal(session["provider"] as? String ?? "", resumption.provider),
                  session["role"] as? String == "worker" else {
                throw CoreError("RECIPIENT_CHANGED", "This session belongs to a different native registration generation.")
            }
            guard session["state"] as? String == "ended", !bool(session, "owner_revoked"),
                  let observationID = session["native_closure_ref"] as? String, !observationID.isEmpty else {
                throw CoreError("CONNECTION_REVOKED", session["state"] as? String == "revoked" || bool(session, "owner_revoked")
                    ? "The owner disconnected this thread in Checklist. It cannot reconnect automatically."
                    : "This thread has no verified closure of its earlier process, so it cannot reconnect as a new process.")
            }
            let observation = try scoped(db, observationID, resumption.projectID, type: "native_closure")
            guard EnvelopeStorageIdentity.equal(observation["session_id"] as? String ?? "", resumption.sessionID),
                  EnvelopeStorageIdentity.equal(observation["installation"] as? String ?? "", resumption.oldInstallation),
                  EnvelopeStorageIdentity.equal(observation["execution_domain"] as? String ?? "", resumption.oldExecutionDomain) else {
                throw CoreError("RECIPIENT_CHANGED", "The recorded closure belongs to a different native registration generation.")
            }
            guard observation["state"] as? String == "released" else {
                throw CoreError("NATIVE_CLOSURE_PENDING", "Work from the earlier process must stop and return for pickup before this thread can reconnect.")
            }
            let endedGeneration = sessionGeneration(session)
            session["state"] = "connected"; session["installation"] = resumption.newInstallation
            session["execution_domain"] = resumption.newExecutionDomain; session["authorization_generation"] = uuid()
            session["prior_native_closure_refs"] = strings(session, "prior_native_closure_refs") + [observationID]
            session.removeValue(forKey: "native_closure_ref"); session.removeValue(forKey: "ended_at")
            session["resumed_at"] = now(); session["last_seen"] = now()
            session = revised(session); try save(db, session, type: "session")
            try event(db, caller: caller, project: resumption.projectID, entity: resumption.sessionID,
                      kind: "native_session_resumed", data: ["observation_ref": observationID, "ended_authorization_generation": endedGeneration])
            result = session
            return .commit
            }
            return result
          }
        }
    }

    private func fenceNativeClosureDeliveries(
        _ db: Database, proof: VerifiedNativeClosure, caller: Caller, originalGeneration: String, observationID: String
    ) throws {
        let sql = "SELECT " + Self.canonicalRecordColumns
            + " FROM records WHERE type='delivery' AND project_id=?"
            + " AND json_extract(data,'$.recipient_session_id')=? COLLATE BINARY"
            + " AND json_extract(data,'$.recipient_authorization_generation')=? COLLATE BINARY"
        let deliveries = try Row.fetchAll(db, sql: sql, arguments: [proof.projectID, proof.sessionID, originalGeneration])
        for row in deliveries {
            let delivery = try GRDBRecordEnvelopeAdapter.decode(row, expectedType: "delivery").object
            guard !["acknowledged", "addressed"].contains(delivery["state"] as? String ?? "") else { continue }
            let message = try scoped(db, (try StoredRecord(delivery, family: "native_record").string("message_id")), proof.projectID, type: "message")
            try event(db, caller: caller, project: proof.projectID,
                      entity: message["task_id"] as? String ?? message["conversation_id"] as? String ?? message["id"] as? String,
                      kind: "message_delivery_fenced", data: ["delivery_id": (try StoredRecord(delivery,
                       family: "native_record").requiredValue("id")), "message_id": (try StoredRecord(message,
                       family: "native_record").requiredValue("id")),
                          "recipient_session_id": proof.sessionID, "recipient_authorization_generation": originalGeneration,
                          "native_closure_ref": observationID])
        }
    }

    public func reconcileVerifiedNativeClosure(_ proof: VerifiedNativeClosure, caller: Caller) throws -> [String: Any] {
        try owner(caller)
        guard caller.installation == "native-lifecycle",
              !proof.authorizationGeneration.isEmpty,
              ["gone", "replaced"].contains(proof.processState), ["absent", "replaced"].contains(proof.registryState) else {
            throw CoreError("NATIVE_CLOSURE_UNPROVEN", "Positive native process and registry closure evidence is required.")
        }
        let lease = try storageAdmission.acquire(); defer { lease.finish() }
        return try ArchiveStorageGate.withExclusive(root: root) { _ in
          try dbQueue.writeWithoutTransaction { db in
            var result: JSON = [:]
            try self.withValidatedDomainTransaction(db) {
            var session = try scoped(db, proof.sessionID, proof.projectID, type: "session")
            guard EnvelopeStorageIdentity.equal(session["installation"] as? String ?? "", proof.installation),
                  EnvelopeStorageIdentity.equal(session["execution_domain"] as? String ?? "", proof.executionDomain),
                  EnvelopeStorageIdentity.equal(session["provider"] as? String ?? "", proof.provider),
                  session["role"] as? String == "worker" else {
                throw CoreError("RECIPIENT_CHANGED", "This closure belongs to a different native registration generation.")
            }
            let observationID = "native-closure-" + hash(Data([proof.projectID, proof.sessionID, proof.installation, proof.executionDomain].joined(separator: "\0").utf8))
            var observation: JSON
            do { observation = try scoped(db, observationID, proof.projectID, type: "native_closure") }
            catch let error as CoreError where error.code == "NOT_FOUND" {
                observation = ["id": observationID, "project_id": proof.projectID, "session_id": proof.sessionID,
                    "installation": proof.installation, "execution_domain": proof.executionDomain, "provider": proof.provider,
                    "process_state": proof.processState, "registry_state": proof.registryState,
                    "registry_digest": proof.registryDigest ?? "", "observed_at": now(), "revision": 0]
            }
            let firstObservation = int(observation, "revision") == 0
            if firstObservation {
                guard EnvelopeStorageIdentity.equal(sessionGeneration(session), proof.authorizationGeneration) else {
                    throw CoreError("RECIPIENT_CHANGED", "The native closure proof belongs to an older session authorization.")
                }
                observation["old_authorization_generation"] = proof.authorizationGeneration
                let endedGeneration = uuid()
                observation["ended_authorization_generation"] = endedGeneration
                // An owner disconnect stays final when its process later closes.
                if session["state"] as? String == "revoked", !bool(session,"owner_reconnect_allowed") { session["owner_revoked"] = true }
                session["state"] = "ended"; session["authorization_generation"] = endedGeneration
                session["native_closure_ref"] = observationID; session["ended_at"] = now()
                try save(db, revised(session), type: "session")
                try event(db, caller: caller, project: proof.projectID, entity: proof.sessionID,
                          kind: "native_session_closed", data: ["observation_ref": observationID])
            } else {
                let oldGeneration = observation["old_authorization_generation"] as? String ?? ""
                let endedGeneration = observation["ended_authorization_generation"] as? String ?? ""
                guard !oldGeneration.isEmpty, !endedGeneration.isEmpty,
                      [oldGeneration, endedGeneration].contains(proof.authorizationGeneration),
                      session["state"] as? String == "ended", session["native_closure_ref"] as? String == observationID,
                      EnvelopeStorageIdentity.equal(sessionGeneration(session), endedGeneration) else {
                    throw CoreError("RECIPIENT_CHANGED", "A newer session authorization cannot inherit or replay this native closure.")
                }
            }
            let originalGeneration = (try StoredRecord(observation, family: "native_record").string("old_authorization_generation"))
            let sql = "SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='attempt' AND project_id=CAST(? AS TEXT) AND CASE WHEN json_valid(data) THEN json_extract(data,'$.state') END='active' AND CASE WHEN json_valid(data) THEN json_extract(data,'$.session_id') END=CAST(? AS TEXT) COLLATE BINARY AND CASE WHEN json_valid(data) THEN json_extract(data,'$.installation') END=CAST(? AS TEXT) COLLATE BINARY AND CASE WHEN json_valid(data) THEN json_extract(data,'$.session_authorization_generation') END=CAST(? AS TEXT) COLLATE BINARY"
            var attempts = try Row.fetchAll(db, sql: sql, arguments: [Data(proof.projectID.utf8), Data(proof.sessionID.utf8), Data(proof.installation.utf8), Data(originalGeneration.utf8)])
                .map { try GRDBRecordEnvelopeAdapter.decode($0, expectedType: "attempt").object }
            // Same-session descendants, if any, relinquish before their parent.
            attempts = try nativeAttemptsDeepestFirst(attempts)
            var released: [String] = [], pending: [String] = []
            for var attempt in attempts {
                let aid = (try StoredRecord(attempt, family: "native_record").string("id"))
                do { try requireNoSourceExecutions(db, attempt: attempt); try requireNoWritableChildren(db, attempt: attempt) }
                catch let error as CoreError where ["SOURCE_EXECUTION_ACTIVE", "CHILD_WRITERS_ACTIVE"].contains(error.code) {
                    if attempt["native_closure_pending"] as? String != observationID || attempt["native_closure_blocker"] as? String != error.code {
                        attempt["native_closure_pending"] = observationID; attempt["native_closure_blocker"] = error.code
                        try save(db, revised(attempt), type: "attempt")
                        try event(db, caller: caller, project: proof.projectID, entity: attempt["task_id"] as? String,
                                  kind: "native_closure_release_pending", data: ["attempt_id": aid, "observation_ref": observationID, "reason": error.code])
                    }
                    pending.append(aid); continue
                }
                if let rid = attempt["review_request_id"] as? String {
                    var request = try scoped(db, rid, proof.projectID, type: "review_request")
                    request["state"] = "queued"; try save(db, revised(request), type: "review_request")
                }
                attempt["state"] = "released"; attempt["reason"] = "Verified native process and registry closure."
                attempt["native_closure_ref"] = observationID; attempt.removeValue(forKey: "token_hash")
                attempt.removeValue(forKey: "native_closure_pending"); attempt.removeValue(forKey: "native_closure_blocker")
                try save(db, revised(attempt), type: "attempt")
                var task = try scoped(db, (try StoredRecord(attempt, family: "native_record").string("task_id")), proof.projectID, type: "task")
                if task["active_attempt_id"] as? String == aid {
                    task.removeValue(forKey: "active_attempt_id"); task["status_id"] = try status(db, proof.projectID, "queued")["id"]
                    task = revised(task); try save(db, task, type: "task")
                    try recordTicketStatusAction(db, task: task, caller: caller)
                }
                try event(db, caller: caller, project: proof.projectID, entity: task["id"] as? String,
                          kind: "work_released_native_closure", data: ["attempt_id": aid, "observation_ref": observationID])
                released.append(aid)
            }
            let nextState = pending.isEmpty ? "released" : "release_pending"
            let allReleased = Array(Set(strings(observation, "released_attempt_ids") + released)).sorted()
            if int(observation, "revision") == 0 || observation["state"] as? String != nextState
                || strings(observation, "released_attempt_ids") != allReleased || strings(observation, "pending_attempt_ids") != pending {
                observation["state"] = nextState; observation["released_attempt_ids"] = allReleased; observation["pending_attempt_ids"] = pending
                try save(db, revised(observation), type: "native_closure")
            }
            if firstObservation {
                try fenceNativeClosureDeliveries(
                    db, proof: proof, caller: caller, originalGeneration: originalGeneration, observationID: observationID
                )
            }
            result = ["session_id": proof.sessionID, "state": "ended", "observation_ref": observationID,
                    "released_attempt_ids": released, "pending_attempt_ids": pending]
            return .commit
            }
            return result
          }
        }
    }
}
