import Foundation
import ChecklistProviders
import GRDB

extension CommandRouter {
    /// The service calls this only after the normal native process/session/cwd
    /// verification. Ordinary router payloads cannot select this authority.
    /// Credential/enrollment preparation uses the same rollback fence as pairing;
    /// the project, registered worker grant and command receipt commit together.
    public func commitWorkspaceProjectCreation(intent: [String: Any], caller: Caller, provider: String,
        preparePersistence: (String) throws -> [String: Any], rollback: () throws -> Void) throws -> [String: Any] {
        guard caller.role == "worker", let sessionID = caller.sessionID, UUID(uuidString: sessionID) != nil,
              let workspace = caller.workspace, workspace.hasPrefix("/"),
              let domain = caller.executionDomain, !domain.isEmpty, !caller.installation.isEmpty,
              providerPlugins.plugin(provider, requiring: .workSession) != nil else {
            throw CoreError("FORBIDDEN", "Project creation requires a verified native worker conversation and its actual workspace.")
        }
        let allowed: Set<String> = ["command_id","name","key_prefix","root_path","icon","accent"]
        guard Set(intent.keys).isSubset(of: allowed),
              let encoded = try? JSONSerialization.data(withJSONObject: intent), encoded.count <= 2_000_000 else {
            throw CoreError("INVALID_INPUT", "Project creation accepts only name, key_prefix, root_path, icon, accent and command_id.")
        }
        for (key, value) in intent {
            guard let value = value as? String, value.utf8.count <= 4000 else {
                throw CoreError("INVALID_INPUT", "\(key) must contain at most 4,000 bytes of text.")
            }
        }
        let command = try text(intent, "command_id", max: 100)
        guard UUID(uuidString: command) != nil else { throw CoreError("INVALID_INPUT", "command_id must be a UUID.") }
        let path = canonical(workspace)
        if let supplied = intent["root_path"] as? String {
            guard supplied.hasPrefix("/"), reservationKey(supplied) == reservationKey(path) else {
                throw CoreError("ROOT_MISMATCH", "A conversation can create a project only for its actual verified workspace folder.")
            }
        }
        let digest = hash(Data(("project_create" + (try jsonString(intent))).utf8))
        let operationLease = try storageAdmission.acquire()
        defer { operationLease.finish() }
        return try ArchiveStorageGate.withExclusive(root: root) { _ in
            try dbQueue.writeWithoutTransaction { db in
                func receipt() throws -> JSON? {
                    guard let row = try Row.fetchOne(db, sql: "SELECT digest,result FROM commands WHERE principal=? AND command_id=?", arguments: [caller.principal, command]) else { return nil }
                    guard row["digest"] as String == digest else { throw CoreError("IDEMPOTENCY_CONFLICT", "This command ID was already used with different input.") }
                    let value = jsonObject(row["result"])
                    if Self.isPrunedResult(value) { throw Self.expiredCommandError(command) }
                    return value
                }
                var output: JSON = [:], prepared = false
                do {
                    try self.withValidatedDomainTransaction(db) {
                        try self.requirePendingCommandIntent(db, command: command, digest: digest, caller: caller)
                        if var cached = try receipt() { cached["replayed"] = true; output = cached; return .commit }
                        var isDirectory: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                            throw CoreError("FILE_ACCESS_REQUIRED", "The verified workspace must be an existing directory.")
                        }
                        let key = self.reservationKey(path)
                        for project in try self.records(db, type: "project") {
                            guard let root = project["root_path"] as? String, !root.isEmpty else { continue }
                            let old = self.reservationKey(root)
                            if old == key { throw CoreError("PROJECT_ALREADY_REGISTERED", "This workspace is already registered as a Checklist project.") }
                            if containsPath(old, key) || containsPath(key, old) { throw CoreError("ROOT_OVERLAP", "This directory overlaps an enrolled writable project.") }
                        }
                        guard caller.projectIDs.isEmpty else { throw CoreError("PROJECT_ALREADY_REGISTERED", "This conversation is already bound to a Checklist project.") }
                        guard (try? self.record(db, sessionID, type: "session")) == nil else {
                            throw CoreError("SESSION_ID_CONFLICT", "This native session is already registered and cannot acquire another workspace grant.")
                        }
                        var params = intent; params["root_path"] = path
                        let project = try self.insertProject(db, params, caller)
                        let projectID = project["id"] as! String
                        prepared = true
                        let registration = try preparePersistence(projectID)
                        let fields: Set<String> = ["project_id","project_ids","session_id","installation","provider","role","workspace","name","execution_domain"]
                        guard Set(registration.keys).isSubset(of: fields),
                              registration["project_id"] as? String == projectID,
                              strings(registration, "project_ids") == [projectID],
                              registration["session_id"] as? String == sessionID,
                              registration["installation"] as? String == caller.installation,
                              registration["provider"] as? String == provider,
                              registration["role"] as? String == "worker",
                              registration["workspace"] as? String == path,
                              registration["execution_domain"] as? String == domain else {
                            throw CoreError("INVALID_INPUT", "Native project registration must grant only the creating conversation and its verified workspace.")
                        }
                        let registrar = Caller(role: "owner", installation: "native-project-registration", projectIDs: [])
                        _ = try self.sessionWrite(db, registration, registrar, "session_register")
                        var bound = caller; bound.projectIDs = [projectID]
                        output = ["data": project, "command_id": command, "event_cursor": try self.cursor(db, caller: bound, scope: try self.authorizationScope(db, bound))]
                        try db.execute(sql: "INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)", arguments: [caller.principal, command, digest, try jsonString(output)])
                        return .commit
                    }
                } catch {
                    let original = error
                    // A durable receipt wins over a post-commit failure; never
                    // restore credentials for an operation that actually committed.
                    do { if let committed = try receipt() { return committed } }
                    catch let conflict as CoreError where conflict.code == "IDEMPOTENCY_CONFLICT" { throw original }
                    catch {
                        throw CoreError("OUTCOME_UNKNOWN", "Project creation outcome could not be established. Retry the original command ID before repair.", details: ["command_id": command, "command_outcome": "unknown"])
                    }
                    if prepared {
                        do { try rollback() }
                        catch { throw CoreError("CONNECTION_RECOVERY_REQUIRED", "Project creation did not commit and its prepared connection needs repair.", details: ["command_id": command, "command_outcome": "unknown", "rollback_failed": true]) }
                    }
                    throw original
                }
                return output
            }
        }
    }
}
