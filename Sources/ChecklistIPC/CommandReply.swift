import Foundation

/// Wire ambiguity is separate from a definitive semantic rejection.
public enum CommandReply {
    // The extra service reads are observed in Coordinator.execute; all Core reads
    // are checked against CommandRouter.readMethods by the boundary contract test.
    public static let readMethods: Set<String> = ["media_original_read", "media_example_read_lease", "media_example_read_release", "media_navigation", "media_round_page", "media_round_header", "media_item_get", "media_publication_preview", "media_type_get", "media_intake_get", "media_item_page", "media_item_counts", "media_approved_examples", "workspace_page", "cleanup_job_get", "cleanup_job_list", "service_info", "tool_catalog", "snapshot", "changes_wait", "delivery_pending", "storage_status", "diagnostics_summary", "project_list", "project_resolve", "project_settings_get", "policy_get", "taxonomy_get", "task_get", "task_list", "task_context", "session_list", "session_inbox", "assistant_inbox", "assistant_projects", "history_list", "attachment_list", "attachment_read", "attachment_cleanup_preview", "agent_resolve", "triage_list", "epic_list", "development_status", "policy_preview", "relation_list", "review_batch_inputs", "batch_get", "batch_list", "source_execution_get", "review_prepare", "review_context", "connection_list", "task_handoff_prepare"]
    public static func expectsMutation(_ method: String) -> Bool { !readMethods.contains(method) && method != "connection_bootstrap" }

    public static func unknown(commandID: String?, reason: String) -> ChecklistError {
        var details: [String: Any] = ["command_outcome": "unknown", "reason": reason]
        if let commandID { details["command_id"] = commandID }
        return ChecklistError("OUTCOME_UNKNOWN", "The service outcome is unknown. Reconcile the original command before retrying a mutation.", details: details)
    }

    public static func decode(_ bytes: Data, method: String, commandID: String?) throws -> [String: Any] {
        func ambiguous(_ reason: String) -> ChecklistError {
            commandID != nil ? unknown(commandID: commandID, reason: reason) : ChecklistError("INVALID_RESPONSE", "Service returned an invalid envelope.", details: ["reason": reason])
        }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: bytes) }
        catch { throw ambiguous("invalid_json") }
        guard let object = value as? [String: Any] else { throw ambiguous("nonobject_envelope") }
        if let returned = object["command_id"], let commandID {
            guard let identity = returned as? String, identity == commandID else { throw ambiguous("command_identity_mismatch") }
        }
        if let raw = object["error"] {
            guard object["data"] == nil, let error = raw as? [String: Any],
                  let code = error["code"] as? String, !code.isEmpty,
                  let message = error["message"] as? String, !message.isEmpty else { throw ambiguous("invalid_error_envelope") }
            var details = error["details"] as? [String: Any] ?? [:]
            if code == ClientUpdateRequired.code {
                details["command_outcome"] = "rejected"
                details["command_executed"] = false
            }
            let uncertain = details["command_outcome"] as? String == "unknown" || ["OUTCOME_UNKNOWN", "INVALID_RESPONSE", "SERVICE_UNAVAILABLE", "COMMAND_FAILED"].contains(code)
            details["command_outcome"] = uncertain ? "unknown" : "rejected"
            if let commandID { details["command_id"] = commandID }
            throw ChecklistError(code, message, details: details)
        }
        guard let data = object["data"] as? [String: Any] else { throw ambiguous("missing_result_data") }
        if expectsMutation(method) {
            guard let commandID, object["command_id"] as? String == commandID else { throw ambiguous("missing_mutation_identity") }
            // Live notices/cursors are observations, never the semantic result of
            // the pending mutation. Existing domain/form validation remains above.
            let observations: Set<String> = ["_checklist", "event_cursor", "pending_message_ids", "policy_changes", "next_cursor", "current_authority", "recovery_warning"]
            guard data.keys.contains(where: { !observations.contains($0) }) else { throw ambiguous("missing_mutation_result") }
            if method == "connection_pair" {
                guard data["paired"] as? Bool == true, data["installation"] is String, data["session_id"] is String else { throw ambiguous("missing_pairing_result") }
            } else if method == "connection_revoke" {
                guard data["disconnected"] as? Bool == true else { throw ambiguous("missing_disconnect_result") }
            } else if method == "human_request_answer" {
                guard isHumanAnswerResult(data) else { throw ambiguous("missing_human_answer_result") }
            }
        } else if method == "connection_bootstrap" {
            guard data["connected"] as? Bool == true, data["installation"] is String, data["session_id"] is String else { throw ambiguous("missing_bootstrap_result") }
        }
        return object
    }

    // requestWrite returns the revised request with the appended response for
    // every answer action. Clarification, Cannot do and Not checked legitimately
    // leave it pending; a complete flag or unrelated result alone is not a receipt.
    // Exact request/form-to-draft comparison remains in RequestAnswerCompletion.
    private static func isHumanAnswerResult(_ data: [String: Any]) -> Bool {
        func nonempty(_ object: [String: Any], _ key: String) -> Bool {
            guard let value = object[key] as? String else { return false }
            return !value.isEmpty
        }
        guard ["id", "project_id", "task_id", "form_identity"].allSatisfy({ nonempty(data, $0) }),
              let revision = data["revision"] as? Int, revision > 0,
              let formRevision = data["form_revision"] as? Int, formRevision > 0,
              let responses = data["responses"] as? [[String: Any]], let response = responses.last,
              nonempty(response, "id"),
              response["form_revision"] as? Int == formRevision,
              response["form_identity"] as? String == data["form_identity"] as? String,
              let action = response["action"] as? String,
              ["answered", "send", "clarification", "clarify", "cannot_do"].contains(action),
              let complete = response["complete"] as? Bool,
              response["answers"] is [[String: Any]], response["files"] is [[String: Any]],
              data["state"] as? String == (complete ? "answered" : "pending") else { return false }
        return !complete || ["answered", "send"].contains(action)
    }

    /// Unknown/untyped failures retain the original saved request. Only an actual
    /// validated rejection (or an explicitly classified pre-send failure) clears it.
    public static func shouldRetainPending(after error: Error) -> Bool {
        guard let error = error as? ChecklistError else { return true }
        return !["rejected", "not_sent"].contains(error.details["command_outcome"] as? String ?? "unknown")
    }

    public static func recoveryMessage(_ error: Error, commandID: String?) -> String {
        guard let commandID, !error.localizedDescription.contains(commandID) else { return error.localizedDescription }
        return error.localizedDescription + " Command ID: \(commandID). Reconcile this original command before another change."
    }
}
