import Foundation
import GRDB

extension CommandRouter {
    static let assistantGrantKeys: Set<String> = ["read","create_drafts_on_request","post_notes_on_request","receive_messages","receive_notifications"]
    func assistantPermission(_ caller: Caller,_ project: String,_ permission: String) throws {
        guard caller.role == "assistant" else { return }
        guard caller.projectIDs.contains(project),caller.assistantGrants[project]?["read"] == true,caller.assistantGrants[project]?[permission] == true else { throw CoreError("FORBIDDEN","This assistant's current project grant does not allow \(permission.replacingOccurrences(of:"_",with:" ")).") }
    }
    func normalizedAssistantGrants(_ raw: Any?, projects: [String]) throws -> [String:[String:Bool]] {
        guard let raw = raw else { return Dictionary(uniqueKeysWithValues:projects.map { ($0,Dictionary(uniqueKeysWithValues:Self.assistantGrantKeys.map { ($0,false) })) }) }
        guard let map = raw as? [String:[String:Bool]],Set(map.keys).isSubset(of:Set(projects)) else { throw CoreError("INVALID_INPUT","Assistant grants must contain only enrolled project IDs and Boolean permissions.") }
        var result: [String:[String:Bool]] = [:]
        for pid in projects {
            let values = map[pid] ?? [:]
            guard Set(values.keys).isSubset(of:Self.assistantGrantKeys) else { throw CoreError("INVALID_INPUT","An assistant grant contains an unknown permission.") }
            result[pid] = Dictionary(uniqueKeysWithValues:Self.assistantGrantKeys.map { ($0,values[$0] ?? false) })
        }
        return result
    }
    func canReceive(_ session: JSON,project: String) -> Bool {
        guard !["revoked","ended"].contains(session["state"] as? String ?? ""),(strings(session,"project_ids").contains(project) || session["project_id"] as? String == project) else { return false }
        guard session["role"] as? String == "assistant" else { return session["role"] as? String == "worker" }
        let grants = session["assistant_grants"] as? [String:[String:Bool]] ?? [:]
        return grants[project]?["read"] == true && grants[project]?["receive_messages"] == true
    }
    func authorizationScope(_ db: Database,_ caller: Caller) throws -> String {
        let base = caller.projectIDs.sorted().joined(separator:",")+":"+caller.role
        guard caller.role == "assistant" else { return base }
        let digest = hash(Data((try jsonString(caller.assistantGrants)).utf8))
        let generation = caller.sessionID.flatMap { try? record(db,$0,type:"session")["authorization_generation"] as? String } ?? "unpaired"
        return base+":"+digest+":"+generation
    }
    func sessionProjection(_ source: JSON,project: String,caller: Caller) -> JSON {
        guard !caller.isOwner else { return source }
        var session = source
        for key in ["assistant_grants","installation","workspace","grant_generation","execution_domain"] { session.removeValue(forKey:key) }
        session["project_ids"] = [project]
        session["project_id"] = project
        return session
    }
}

extension CommandRouter {
    func sessionGeneration(_ session: JSON) -> String { session["authorization_generation"] as? String ?? "unqualified-legacy" }
    func callerSessionGeneration(_ db: Database,_ caller: Caller,project: String) throws -> String {
        guard let sid = caller.sessionID else { return caller.isOwner ? "human" : "unpaired" }
        let session = try scoped(db,sid,project,type:"session")
        guard !["revoked","ended"].contains(session["state"] as? String ?? "") else { throw CoreError("RECIPIENT_CHANGED","This session authorization has ended. Pair the actual current session before continuing.") }
        return sessionGeneration(session)
    }
    func deliveryCurrent(_ db: Database,_ delivery: JSON) throws -> Bool {
        guard let sid = delivery["recipient_session_id"] as? String,let pid = delivery["project_id"] as? String,let session = try? scoped(db,sid,pid,type:"session") else { return false }
        return canReceive(session,project:pid) && delivery["recipient_authorization_generation"] as? String == sessionGeneration(session)
    }
    func qualifiedPersonalAssistant(_ profile: JSON,_ session: JSON) -> Bool {
        profile["identity_source"] as? String == "host" && profile["host_identity_verified"] as? Bool == true && session["role"] as? String == "assistant" && session["host_identity_verified"] as? Bool == true && session["adapter_registry_id"] as? String == "codex.dot" && profile["host_identity_ref"] as? String != nil && profile["host_identity_ref"] as? String == session["host_identity_ref"] as? String
    }
}
