import Foundation
import ChecklistIPC

/// UI reads must settle even if a connected peer never sends its reply. A
/// mutation still waits for its original receipt rather than implying failure.
enum NativeServiceTransport {
    static func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let timeout: TimeInterval? = CommandReply.readMethods.contains(method) || method == "attachment_read_release" ? 30 : nil
        return try await ChecklistClient(owner: true).callAsync(method, params, replyTimeout: timeout)
    }
}
