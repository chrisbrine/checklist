import Foundation
import ChecklistContracts

/// Wire ambiguity is separate from a definitive semantic rejection.
public enum CommandReply {
    public static let readMethods = CommandMethods.serviceReads
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
                details["recovery_action"] = ClientUpdateRequired.recoveryAction
            }
            let uncertain = details["command_outcome"] as? String == "unknown" || ["OUTCOME_UNKNOWN", "INVALID_RESPONSE", "SERVICE_UNAVAILABLE", "COMMAND_FAILED"].contains(code)
            details["command_outcome"] = uncertain ? "unknown" : "rejected"
            if let commandID { details["command_id"] = commandID }
            throw ChecklistError(code, message, details: details)
        }
        guard let data = object["data"] as? [String: Any] else { throw ambiguous("missing_result_data") }
        if expectsMutation(method) {
            guard let commandID, object["command_id"] as? String == commandID else { throw ambiguous("missing_mutation_identity") }
            if object["command_outcome"] as? String == "queued" {
                guard data["state"] as? String == "queued",data["queued"] as? Bool == true,
                      data["command_id"] as? String == commandID,data["status_method"] as? String == "command_status",
                      let admission = object["write_admission"] as? [String:Any],admission["queued"] as? Bool == true,
                      admission["locked"] as? Bool == true,!(admission["reason"] as? String ?? "").isEmpty else {throw ambiguous("invalid_queued_receipt")}
                return object
            }
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
            let connected = data["connected"] as? Bool == true && data["installation"] is String && data["session_id"] is String
            let verifiedWorkspace = data["connected"] as? Bool == false
                && data["state"] as? String == "project_setup_required" && data["native_context_verified"] as? Bool == true
                && (data["workspace"] as? String)?.hasPrefix("/") == true
                && ["codex","claude"].contains(data["provider"] as? String ?? "")
                && (data["session_id"] as? String).flatMap(UUID.init(uuidString:)) != nil
            guard connected || verifiedWorkspace else { throw ambiguous("missing_bootstrap_result") }
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
