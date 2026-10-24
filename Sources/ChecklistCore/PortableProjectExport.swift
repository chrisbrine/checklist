import Foundation

/// Portable history keeps attribution, never a credential or a current host/session route.
/// This projection is for project exports only; recovery snapshots retain the canonical
/// records and fence their authority when a disposable restored incarnation is prepared.
enum PortableProjectExport {
    // Exact structural fields, not substrings or user-authored text. Generations used by
    // media/configuration concurrency are unrelated to session authority and stay intact.
    private static let authorityFields: Set<String> = [
        "token_hash", "claim_token", "credential", "credentials", "access_token", "refresh_token",
        "api_key", "pairing_secret", "signing_secret", "token_digest",
        "incarnation", "store_incarnation", "session_generation", "authorization_generation",
        "session_authorization_generation", "recipient_authorization_generation",
        "requester_authorization_generation", "source_authorization_generation",
        "reply_recipient_authorization_generation", "reply_sender_authorization_generation",
        "finished_by_authorization_generation", "old_authorization_generation", "ended_authorization_generation",
        "participant_authorization_generations", "sender_generation", "target_generation", "route_generation",
        "grant_generation", "assistant_grants", "assistant_relay_grants", "sender_authorization_scope",
        "native_endpoint", "native_binding", "native_device", "native_inode",
        "execution_domain", "author_execution_domain", "target_domain",
        "callback_url", "callback_destination", "webhook_url"
    ]

    static func project(_ value: JSON) -> JSON {
        var portable: JSON = [:]
        for (key, value) in value where !authorityFields.contains(key) {
            if let object = value as? JSON { portable[key] = project(object) }
            else if let array = value as? [Any] { portable[key] = array.map(projectValue) }
            else { portable[key] = value }
        }
        return portable
    }

    private static func projectValue(_ value: Any) -> Any {
        if let object = value as? JSON { return project(object) }
        if let array = value as? [Any] { return array.map(projectValue) }
        return value
    }
}
