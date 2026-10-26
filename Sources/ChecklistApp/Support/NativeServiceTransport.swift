import Foundation
import ChecklistIPC

/// UI reads must settle even if a connected peer never sends its reply. A
/// mutation still waits for its original receipt rather than implying failure.
enum NativeServiceTransport {
    @MainActor static func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        // Full-backup verification uses the storage budget, including both file passes.
        let timeout: TimeInterval? = method == "restore_preview" ? 1_800 : (CommandReply.readMethods.contains(method) || method == "attachment_read_release" ? 30 : nil)
        // Keep the legacy async client's catchable rejection before Foundation serialization.
        guard JSONSerialization.isValidJSONObject(params) else {
            throw NSError(domain: NSCocoaErrorDomain, code: 3840, userInfo: [NSLocalizedDescriptionKey: "The request contains unsupported JSON values."])
        }
        let bytes = try JSONSerialization.data(withJSONObject: params)
        let response = try await ChecklistClient(owner: true).callAsyncData(method, bytes, replyTimeout: timeout)
        guard let reply = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw ChecklistError("INVALID_RESPONSE", "The Checklist service returned an invalid response.")
        }
        return reply
    }
}
