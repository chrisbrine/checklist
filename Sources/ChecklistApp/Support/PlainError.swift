import Foundation
import ChecklistIPC

/// CL-58: the app shows errors as plain text. The CLI and the service keep "CODE: message" for agents
/// and diagnostics; the app shows what happened and what to do, without the code prefix.
enum PlainError {
    static func text(_ error: Error) -> String {
        guard let failure = error as? ChecklistError else { return error.localizedDescription }
        let isChange = failure.details["command_id"] != nil
        switch failure.code {
        case "OUTCOME_UNKNOWN", "COMMAND_FAILED":
            return isChange ? "The service may already have saved this change. Use Check the last change before you make another change."
                            : "Checklist did not get an answer from its service in time. Try again."
        case "SERVICE_UNAVAILABLE", "SERVICE_REGISTRATION_FAILED": return DisabledReasons.offline
        case "INVALID_RESPONSE": return "The service sent an answer that the app cannot read. Try again."
        case "STORE_BUSY", "STORAGE_DRAINING", "STORAGE_NOT_READY": return "Checklist is busy with its storage. Try again in a moment."
        default: return failure.message.isEmpty ? "The Checklist service could not complete this request." : failure.message
        }
    }
}
