import Foundation

/// Only an evidence refusal from the service's Codex app restart verifier may
/// take this path. Generic retryable errors never reopen native bootstrap.
public enum CodexRestartRefusal {
    public static let reason = "codex_app_host_restart_evidence"
    public static func error(_ message: String, blockingProcesses: [[String: Any]] = []) -> ChecklistError {
        ChecklistError("NATIVE_SESSION_MISMATCH", message, details: ["retryable": true, "reason": reason,
            "blocking_processes": blockingProcesses])
    }
    public static func applies(_ error: Error) -> Bool {
        guard let error = error as? ChecklistError else { return false }
        return error.code == "NATIVE_SESSION_MISMATCH" && error.details["retryable"] as? Bool == true
            && error.details["reason"] as? String == reason
    }
}
