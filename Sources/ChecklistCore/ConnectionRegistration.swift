import Foundation
import GRDB

public struct ConnectionRegistrationIntent {
    public let commandID: String
    public let digest: String
}

/// No credential material crosses into Core or a cached/public receipt.
public struct ConnectionRegistrationPreparation {
    public let sessionParameters: [String: Any]
    public let installation: String
    public let mcpExecutable: String
    public init(sessionParameters: [String: Any], installation: String, mcpExecutable: String) {
        self.sessionParameters = sessionParameters; self.installation = installation; self.mcpExecutable = mcpExecutable
    }
}

extension CommandRouter {
    /// Internal service authentication read. Returns one current canonical
    /// session, including ended/revoked state, without rendering a session list.
    /// Never caches authority or repairs a missing registration.
    public func connectionSession(sessionID: String, project: String, caller: Caller) throws -> [String: Any]? {
        try owner(caller)
        let lease = try storageAdmission.acquire(); defer { lease.finish() }
        return try readForPreparation { db in
            let pid = try self.scope(db,["project_id":project],caller)
            do { return try self.scoped(db,sessionID,pid,type:"session") }
            catch let error as CoreError where error.code == "NOT_FOUND" { return nil }
        }
    }

    private func connectionReceipt(_ db: Database, command: String, digest: String, principal: String) throws -> JSON? {
        guard let row = try Row.fetchOne(db, sql: "SELECT digest,result FROM commands WHERE principal=? AND command_id=?", arguments: [principal, command]) else { return nil }
        guard row["digest"] as String == digest else { throw CoreError("IDEMPOTENCY_CONFLICT", "This pairing command ID already belongs to different original intent.") }
        let output = jsonObject(row["result"])
        guard output["_connection_registration"] is JSON else { throw CoreError("IDEMPOTENCY_CONFLICT", "This command ID does not identify a pairing receipt.") }
        return output
    }

    private func connectionAuthority(_ db: Database, receipt: JSON) throws -> JSON {
        guard let basis = receipt["_connection_registration"] as? JSON,
              let sid = basis["session_id"] as? String else { return ["registration_current": false, "state": "unavailable"] }
        let session: JSON
        do { session = try record(db, sid, type: "session") }
        catch let error as CoreError where error.code == "NOT_FOUND" { return ["registration_current": false, "state": "unavailable"] }
        let state = session["state"] as? String ?? "unknown"
        let matches = session["installation"] as? String == basis["installation"] as? String
            && session["authorization_generation"] as? String == basis["authorization_generation"] as? String
            && session["role"] as? String == basis["role"] as? String
            && session["provider"] as? String == basis["provider"] as? String
            && Set(strings(session, "project_ids")) == Set(strings(basis, "project_ids"))
            && !["ended", "revoked"].contains(state)
        return ["registration_current": matches, "state": matches ? state : (["ended", "revoked"].contains(state) ? state : "changed")]
    }

    private func presentingConnectionReceipt(_ db: Database, _ stored: JSON) -> JSON {
        var output = stored; output.removeValue(forKey: "_connection_registration")
        var data = output["data"] as? JSON ?? [:]
        do { data["current_authority"] = try connectionAuthority(db, receipt: stored) }
        catch {
            data["current_authority"] = ["registration_current": false, "state": "unavailable"]
            data["recovery_warning"] = "Pairing committed; its current connection state could not be refreshed. Read the saved command receipt before repair."
        }
        output["data"] = data
        return output
    }

    /// Used by credential authentication to fence a prepared enrollment after a
    /// crash/failed commit. It never creates, rotates or repairs a session.
    public func connectionRegistrationIsCurrent(commandID: String, digest: String, sessionID: String, installation: String, receiptPrincipal: String, caller: Caller) throws -> Bool {
        try owner(caller)
        let operationLease = try storageAdmission.acquire()
        defer { operationLease.finish() }
        return try ArchiveStorageGate.withExclusive(root: root) { _ in
        return try dbQueue.read { db in
            guard let stored = try connectionReceipt(db, command: commandID, digest: digest, principal: receiptPrincipal),
                  let basis = stored["_connection_registration"] as? JSON,
                  basis["session_id"] as? String == sessionID,
                  (basis["installation"] as? String)?.hasPrefix(installation + "/") == true else { return false }
            return bool(try connectionAuthority(db, receipt: stored), "registration_current")
        }
        }
    }

    /// Bounded owner-only pairing boundary. The external preparation callback is
    /// not a cross-store transaction; failed preparation/commit still needs the
    /// caller's restoration and the generation/receipt authentication fence.
    public func commitConnectionRegistration(intent: [String: Any], caller: Caller,
        preparePersistence: (ConnectionRegistrationIntent) throws -> ConnectionRegistrationPreparation,
        rollback: () throws -> Void) throws -> [String: Any] {
        try owner(caller) // Always precedes admission, receipt lookup or callback.
        let operationLease = try storageAdmission.acquire()
        defer { operationLease.finish() }
        let command = try text(intent, "command_id", max: 100)
        guard UUID(uuidString: command) != nil else { throw CoreError("INVALID_INPUT", "Pairing command_id must be a UUID.") }
        let canonical = try jsonString(intent)
        guard canonical.utf8.count <= 2_000_000 else { throw CoreError("INVALID_INPUT", "Pairing intent is too large.") }
        let digest = hash(Data(("connection_pair" + canonical).utf8))
        return try ArchiveStorageGate.withExclusive(root: root) { _ in
        return try dbQueue.writeWithoutTransaction { db in
            var stored: JSON = [:], prepared = false
            do {
                try db.inTransaction(.immediate) {
                    try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:caller)
                    if var cached = try self.connectionReceipt(db, command: command, digest: digest, principal: caller.principal) {
                        cached["replayed"] = true; stored = cached; return .commit
                    }
                    // Replay has already been checked before random values or any
                    // credential I/O. Keep this initial synchronous exception short.
                    prepared = true
                    let preparation = try preparePersistence(ConnectionRegistrationIntent(commandID: command, digest: digest))
                    let params = preparation.sessionParameters
                    let allowed: Set<String> = ["project_id", "project_ids", "session_id", "installation", "provider", "role", "workspace", "profile_id", "name", "assistant_grants", "execution_domain"]
                    guard Set(params.keys).isSubset(of: allowed),
                          preparation.installation.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,79}$", options: .regularExpression) != nil,
                          let registration = params["installation"] as? String,
                          registration.hasPrefix(preparation.installation + "/"),
                          registration.count > preparation.installation.count + 1 else { throw CoreError("INVALID_INPUT", "Pairing preparation has an invalid registration shape.") }
                    let session = try self.sessionWrite(db, params, caller, "session_register")
                    let data: JSON = ["installation": preparation.installation, "session_id": (try StoredRecord(session,
                        family: "ConnectionRegistration").requiredValue("id")), "role": (try StoredRecord(session, family: "ConnectionRegistration").requiredValue("role")), "paired": true,
                        "workspace": session["workspace"] ?? "", "mcp_executable": preparation.mcpExecutable]
                    stored = ["data": data, "command_id": command,
                        "event_cursor": try self.cursor(db, caller: caller, scope: try self.authorizationScope(db, caller)),
                        "_connection_registration": ["session_id": (try StoredRecord(session, family: "ConnectionRegistration").requiredValue("id")),
                            "installation": (try StoredRecord(session, family: "ConnectionRegistration").requiredValue("installation")), "authorization_generation": (try StoredRecord(session,
                            family: "ConnectionRegistration").requiredValue("authorization_generation")), "role": (try StoredRecord(session,
                            family: "ConnectionRegistration").requiredValue("role")), "provider": (try StoredRecord(session, family: "ConnectionRegistration").requiredValue("provider")),
                            "project_ids": (try (session["project_ids"] ?? [StoredRecord(session, family: "ConnectionRegistration").requiredValue("project_id")]))]]
                    try db.execute(sql: "INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)", arguments: [caller.principal, command, digest, try jsonString(stored)])
                    return .commit
                }
            } catch {
                let original = error
                // A post-commit transport/maintenance failure cannot fabricate a
                // rollback. Query the exact durable receipt before restoration.
                let recovered: JSON?
                do { recovered = try self.connectionReceipt(db, command: command, digest: digest, principal: caller.principal) }
                catch let conflict as CoreError where conflict.code == "IDEMPOTENCY_CONFLICT" { throw original }
                catch { throw CoreError("OUTCOME_UNKNOWN", "Pairing outcome could not be established. Reconcile its original command ID before repair.", details: ["command_id": command, "command_outcome": "unknown", "original_failure": PublicErrorText.describe(original)]) }
                if let recovered { return self.presentingConnectionReceipt(db, recovered) }
                if prepared {
                    do { try rollback() }
                    catch {
                        throw CoreError("CONNECTION_RECOVERY_REQUIRED", "Pairing did not commit and prior local state needs repair. Original failure: " + PublicErrorText.describe(original),
                            details: ["command_id": command, "command_outcome": "unknown", "original_failure": PublicErrorText.describe(original), "rollback_failed": true])
                    }
                }
                throw original
            }
            // No throwing maintenance runs after the semantic receipt committed.
            return self.presentingConnectionReceipt(db, stored)
        }
        }
    }
}
