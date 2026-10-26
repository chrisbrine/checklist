import Foundation

extension ChecklistClient {
    /// The synchronous client remains available to command-line callers. Async
    /// callers suspend while the service returns its original command outcome.
    public func callAsync(_ method: String, _ params: [String: Any] = [:], replyTimeout: TimeInterval? = nil) async throws -> [String: Any] {
        try await Self.offloadBlockingJSONCall(params) {
            try self.call(method, $0, replyTimeout: replyTimeout)
        }
    }

    /// Actor-owned clients transfer immutable wire bytes; Foundation graphs stay
    /// local to the caller and the dispatch worker, including error replies.
    public func callAsyncData(_ method: String, _ params: Data, replyTimeout: TimeInterval? = nil) async throws -> Data {
        try await Self.offloadBlockingJSONDataCall(params) {
            try self.call(method, $0, replyTimeout: replyTimeout)
        }
    }

    /// Keep Foundation object graphs local to each side of the worker boundary.
    static func offloadBlockingJSONCall(_ params: [String: Any], operation: @escaping @Sendable ([String: Any]) throws -> [String: Any]) async throws -> [String: Any] {
        // Dictionaries contain arbitrary Foundation values. Send an immutable JSON
        // value copy to the dispatch worker and decode the reply on the caller.
        guard JSONSerialization.isValidJSONObject(params) else {
            throw NSError(domain: NSCocoaErrorDomain, code: 3840, userInfo: [NSLocalizedDescriptionKey: "The request contains unsupported JSON values."])
        }
        let request = try JSONSerialization.data(withJSONObject: params)
        let response = try await Self.offloadBlockingJSONDataCall(request, operation: operation)
        return try JSONSerialization.jsonObject(with: response) as! [String: Any]
    }

    private static func offloadBlockingJSONDataCall(_ request: Data, operation: @escaping @Sendable ([String: Any]) throws -> [String: Any]) async throws -> Data {
        try await Self.offloadBlockingCall {
            guard let parameters = try JSONSerialization.jsonObject(with: request) as? [String: Any] else {
                throw NSError(domain: NSCocoaErrorDomain, code: 3840, userInfo: [NSLocalizedDescriptionKey: "The request is not a JSON object."])
            }
            let reply = try operation(parameters)
            guard JSONSerialization.isValidJSONObject(reply) else {
                throw NSError(domain: NSCocoaErrorDomain, code: 3840, userInfo: [NSLocalizedDescriptionKey: "The reply contains unsupported JSON values."])
            }
            return try JSONSerialization.data(withJSONObject: reply)
        }
    }

    /// Shared by the real client and anonymous-connection qualification tests.
    static func offloadBlockingCall<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
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
