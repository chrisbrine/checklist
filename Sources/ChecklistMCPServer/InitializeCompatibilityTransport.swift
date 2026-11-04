import Foundation
import Logging
import MCP

/// Swift MCP SDK 0.12.1 decodes experimental client capabilities as strings,
/// although MCP clients can send object-valued extension settings. Checklist
/// implements no experimental client extension, so omit that optional metadata
/// before the SDK decodes an otherwise valid initialize request. This neither
/// advertises extension support nor changes native connection authority.
actor InitializeCompatibilityTransport: Transport {
    nonisolated let logger: Logger
    private let base: any Transport

    init(_ base: any Transport) async {
        self.base = base
        logger = await base.logger
    }

    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func send(_ data: Data) async throws { try await base.send(data) }

    func receive() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in await base.receive() {
                        continuation.yield(Self.supportedInitialize(data))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated static func supportedInitialize(_ data: Data) -> Data {
        guard var request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              request["method"] as? String == Initialize.name,
              var parameters = request["params"] as? [String: Any],
              var capabilities = parameters["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"] as? [String: Any],
              !experimental.isEmpty,
              experimental.values.allSatisfy({ $0 is [String: Any] }) else { return data }

        capabilities.removeValue(forKey: "experimental")
        parameters["capabilities"] = capabilities
        request["params"] = parameters
        guard let supported = try? JSONSerialization.data(withJSONObject: request),
              (try? JSONDecoder().decode(Request<Initialize>.self, from: supported)) != nil else {
            // Keep malformed envelopes, core capabilities and parameters intact
            // for the SDK's existing refusal, rather than repairing them here.
            return data
        }
        return supported
    }
}
