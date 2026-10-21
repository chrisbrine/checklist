import Foundation

extension ChecklistClient {
    /// The synchronous client remains available to command-line callers. Async
    /// callers suspend while the service returns its original command outcome.
    public func callAsync(_ method: String, _ params: [String: Any] = [:], replyTimeout: TimeInterval? = nil) async throws -> [String: Any] {
        try await Self.offloadBlockingCall { try self.call(method, params, replyTimeout: replyTimeout) }
    }

    /// Shared by the real client and anonymous-connection qualification tests.
    static func offloadBlockingCall<Value>(_ operation: @escaping () throws -> Value) async throws -> Value {
        // XPC replies need dispatch workers. A detached Swift task still uses
        // the cooperative executor, whose threads must not wait on semaphores.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
