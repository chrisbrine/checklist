import Foundation
import ChecklistIPC

/// Service write admission is independent of reachability and of the result of
/// any particular change. A queue acknowledgment never means the change saved.
struct WriteAdmissionState: Equatable {
    let generation: String
    let revision: Int
    let locked: Bool
    let queued: Bool
    let reason: String
    let message: String
    let estimatedRemainingSeconds: Double?

    init?(_ values: [String: Any]) {
        guard let locked = values["locked"] as? Bool,
              let queued = values["queued"] as? Bool else { return nil }
        generation = values["generation"] as? String ?? ""
        revision = values["revision"] as? Int ?? 0
        self.locked = locked; self.queued = queued
        reason = values["reason"] as? String ?? ""
        message = (values["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (reason == "backup_queue_draining" ? "Queued changes are being applied in order." : "A backup is in progress. Changes are queued until the database copy finishes; reads remain available.")
        estimatedRemainingSeconds = (values["estimated_remaining_seconds"] as? Double).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    var title: String { locked ? "Writes are locked and queued" : "Queued changes are being applied" }
    var estimateText: String? {
        estimatedRemainingSeconds.map { "Estimated wait: about \(max(1, Int(min($0.rounded(.up), Double(Int.max / 2))))) seconds." }
    }
}

/// Both workspace windows and windowless capture must receive the applied
/// original result before clearing recovery data or deleting staged files.
@MainActor enum QueuedCommandReply {
    typealias Transport = @MainActor (String, [String: Any]) async throws -> [String: Any]

    static func payload(_ reply: [String: Any]) throws -> [String: Any] {
        if let failure = reply["error"] as? [String: Any] {
            throw ChecklistError(failure["code"] as? String ?? "SERVICE_ERROR", failure["message"] as? String ?? "The Checklist service could not complete this request.", details: failure["details"] as? [String: Any] ?? [:])
        }
        return reply["data"] as? [String: Any] ?? reply["result"] as? [String: Any] ?? reply
    }

    static func resolve(_ reply: [String: Any], method: String, params: [String: Any], pause: UInt64 = 250_000_000,
                        transport: Transport, queued: @MainActor (String, Bool) -> Void = { _, _ in },
                        allowOriginalRetry: Bool = true) async throws -> [String: Any] {
        guard reply["command_outcome"] as? String == "queued" else { return reply }
        guard let commandID = params["command_id"] as? String,
              reply["command_id"] as? String == commandID,
              let acknowledgment = reply["data"] as? [String: Any], acknowledgment["queued"] as? Bool == true,
              acknowledgment["state"] as? String == "queued", acknowledgment["status_method"] as? String == "command_status" else {
            throw CommandReply.unknown(commandID: params["command_id"] as? String, reason: "invalid_queued_acknowledgment")
        }
        queued(commandID, true)
        defer { queued(commandID, false) }
        while true {
            try await Task.sleep(nanoseconds: pause)
            var statusParams: [String: Any] = ["command_id": commandID]
            if let project = params["project_id"] { statusParams["project_id"] = project }
            let statusReply = try await transport("command_status", statusParams)
            let status = try payload(statusReply)
            switch status["state"] as? String {
            case "queued": continue
            case "applied", "failed":
                if status["state"] as? String == "applied", status["retry_original"] as? Bool == true {
                    guard allowOriginalRetry else { throw CommandReply.unknown(commandID: commandID, reason: "queued_original_retry_unavailable") }
                    // Durable status receipts redact claim tokens. The same
                    // original command ID uses normal replay to refresh them.
                    let original = try await transport(method, params)
                    return try await resolve(original, method: method, params: params, pause: pause,
                        transport: transport, queued: queued, allowOriginalRetry: false)
                }
                let result: [String: Any]
                if let original = status["result"] as? [String: Any] { result = original }
                else if let failure = status["error"] as? [String: Any] { result = ["command_id": commandID, "error": failure] }
                else { throw CommandReply.unknown(commandID: commandID, reason: "missing_queued_command_result") }
                guard result["command_outcome"] as? String != "queued" else {
                    throw CommandReply.unknown(commandID: commandID, reason: "queued_acknowledgment_is_not_applied")
                }
                let bytes = try JSONSerialization.data(withJSONObject: result)
                return try CommandReply.decode(bytes, method: method, commandID: commandID)
            default:
                throw CommandReply.unknown(commandID: commandID, reason: "queued_command_status_unknown")
            }
        }
    }
}
