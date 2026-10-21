import Foundation

/// Credentials and enrollment persistence may fail; neither is allowed to run
/// after session registration. The caller snapshots prior state before entering.
public enum ConnectionCommit {
    public static func perform<Result>(saveCredential: () throws -> Void, saveEnrollment: () throws -> Void, registerSession: () throws -> Result, rollback: () throws -> Void) throws -> Result {
        do {
            try saveCredential()
            try saveEnrollment()
            return try registerSession()
        } catch {
            let original = error
            do { try rollback() }
            catch { throw ChecklistError("CONNECTION_RECOVERY_REQUIRED", "Pairing could not restore its previous local state. Original failure: " + original.localizedDescription, details: ["command_outcome": "unknown", "original_failure": original.localizedDescription, "rollback_failed": true]) }
            throw original
        }
    }

    /// Attempt both restorations even when one fails; never silently leave a
    /// credential changed because restoring the enrollment file failed first.
    public static func restore(enrollment: () throws -> Void, credential: () throws -> Void) throws {
        var errors: [Error] = []
        do { try enrollment() } catch { errors.append(error) }
        do { try credential() } catch { errors.append(error) }
        if let first = errors.first { throw first }
    }

    /// A crash/failed rollback must not make a staged or stale enrollment usable.
    public static func registrationMatches(_ session: [String: Any], sessionID: String, installation: String, generation: String, role: String, provider: String, projects: [String]) -> Bool {
        let membership = Set(session["project_ids"] as? [String] ?? (session["project_id"] as? String).map { [$0] } ?? [])
        return session["id"] as? String == sessionID
            && session["installation"] as? String == installation + "/" + generation
            && session["role"] as? String == role && session["provider"] as? String == provider
            && !["ended", "revoked"].contains(session["state"] as? String ?? "")
            && Set(projects).isSubset(of: membership)
    }
}
