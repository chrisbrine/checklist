import Foundation
import XCTest
import MCP
import ChecklistIPC
import ChecklistBridges
@testable import ChecklistMCPServer

final class InitializeCompatibilityTransportTests: XCTestCase {
    // Codex rust-v0.166.0-alpha.5.1, codex-mcp/src/rmcp_client.rs:
    // start_server_task adds this object when an auth-change receiver exists.
    // The actual failing installed thread's wire payload was not captured.
    private let initialize = Data(#"{"jsonrpc":"2.0","id":41,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"codex-mcp-client","version":"0.166.0-alpha.5.1","title":"Codex"},"capabilities":{"experimental":{"codex/auth-change":{}},"roots":{"listChanged":true},"elicitation":{"form":{},"url":{}}},"_meta":{"fixture":"preserve"}}}"#.utf8)

    func testCodexExperimentalObjectFailsPinnedSDKAndPreservesCoreInitialization() throws {
        // Request wraps the underlying parameter decoding failure as dataCorrupted.
        XCTAssertThrowsError(try JSONDecoder().decode(Request<Initialize>.self, from: initialize))
        let parameters = try JSONSerialization.data(withJSONObject: XCTUnwrap(object(initialize)["params"]))
        XCTAssertThrowsError(try JSONDecoder().decode(Initialize.Parameters.self, from: parameters)) { error in
            guard case DecodingError.typeMismatch(let type, let context) = error else {
                return XCTFail("Expected experimental capability type mismatch: \(error)")
            }
            XCTAssertTrue(type == String.self)
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["capabilities", "experimental", "codex/auth-change"])
        }
        let supported = InitializeCompatibilityTransport.supportedInitialize(initialize)
        let decoded = try JSONDecoder().decode(Request<Initialize>.self, from: supported)
        XCTAssertEqual(decoded.id, .number(41))
        XCTAssertEqual(decoded.params.protocolVersion, "2025-06-18")
        XCTAssertEqual(decoded.params.clientInfo.name, "codex-mcp-client")
        XCTAssertEqual(decoded.params.clientInfo.title, "Codex")
        XCTAssertEqual(decoded.params.capabilities.roots?.listChanged, true)
        XCTAssertNotNil(decoded.params.capabilities.elicitation?.form)
        XCTAssertNotNil(decoded.params.capabilities.elicitation?.url)
        XCTAssertNil(decoded.params.capabilities.experimental)
        var expected = try object(initialize)
        var params = try XCTUnwrap(expected["params"] as? [String: Any])
        var capabilities = try XCTUnwrap(params["capabilities"] as? [String: Any])
        capabilities.removeValue(forKey: "experimental")
        params["capabilities"] = capabilities
        expected["params"] = params
        XCTAssertEqual(try object(supported) as NSDictionary, expected as NSDictionary)
    }

    func testOtherFramesAndMalformedInitializeStayByteExact() throws {
        let frames = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"capabilities":{"experimental":{"codex/auth-change":{}}}}}"#,
            #"{"jsonrpc":"2.0","method":"initialize","params":{"capabilities":{"experimental":{"codex/auth-change":{}}}}}"#,
            #"{"jsonrpc":"1.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":{"codex/auth-change":{}}}}}"#,
            #"{"jsonrpc":"2.0","id":true,"method":"initialize","params":{"capabilities":{"experimental":{"codex/auth-change":{}}}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":{"codex/auth-change":{}},"roots":{"listChanged":"invalid"}}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":{"codex/auth-change":true}}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":[{}]}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":{"legacy":"string"}}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":{}}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}"#,
            #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#,
            #"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"experimental":{"fixture":{}}}}}"#,
            "malformed JSON"
        ]
        for frame in frames {
            let bytes = Data(frame.utf8)
            XCTAssertEqual(InitializeCompatibilityTransport.supportedInitialize(bytes), bytes, frame)
        }
    }

    func testRawCodexInitializeThenCatalogAndPingUseOnlyFakeBridge() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let environment = BridgeEnvironment(makeClient: { _ in FakeClient() },
            discover: { _ in XCTFail("No native discovery is allowed"); return .noHost },
            now: { 0 }, sleep: { _ in XCTFail("No startup wait is allowed") }, stderr: { _ in },
            serviceJobRunning: { XCTFail("No service inspection is allowed"); return nil },
            startService: { XCTFail("No service start is allowed") })
        let bridge = Bridge(configuration: .init(workspace: "/synthetic/checklist", automatic: false), environment: environment)
        let server = try await ChecklistMCPServer.start(bridge: bridge, transport: pair.server)
        try await pair.client.connect()
        addTeardownBlock { await pair.client.disconnect(); await server.stop() }
        var replies = await pair.client.receive().makeAsyncIterator()

        try await pair.client.send(initialize)
        let initialized = try await reply(&replies)
        XCTAssertNil(initialized["error"])
        XCTAssertEqual((initialized["id"] as? NSNumber)?.intValue, 41)
        let result = try XCTUnwrap(initialized["result"] as? [String: Any])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "Checklist")
        XCTAssertNil((result["capabilities"] as? [String: Any])?["experimental"])

        try await pair.client.send(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        try await pair.client.send(Data(#"{"jsonrpc":"2.0","id":42,"method":"tools/list","params":{}}"#.utf8))
        let catalog = try await reply(&replies)
        let tools = try XCTUnwrap((catalog["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["service_info"])
        try await pair.client.send(Data(#"{"jsonrpc":"2.0","id":43,"method":"ping","params":{}}"#.utf8))
        let ping = try await reply(&replies)
        XCTAssertEqual((ping["id"] as? NSNumber)?.intValue, 43)
        XCTAssertNil(ping["error"])
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func reply(_ replies: inout AsyncThrowingStream<Data, Error>.Iterator) async throws -> [String: Any] {
        let bytes = try await replies.next()
        return try object(XCTUnwrap(bytes))
    }

    private struct FakeClient: BridgeClient {
        func bootstrap(_ nativeContext: [String: Any], timeBudget: TimeInterval?) throws -> [String: Any] {
            XCTFail("No real or synthetic enrollment is allowed")
            throw ChecklistError("UNEXPECTED_BOOTSTRAP", "Fake bootstrap must not run.")
        }
        func call(_ method: String, _ params: [String: Any], replyTimeout: TimeInterval?) throws -> [String: Any] {
            guard method == "tool_catalog" else {
                XCTFail("Unexpected fake bridge call: " + method)
                throw ChecklistError("UNEXPECTED_CALL", "Only the fake catalog is used.")
            }
            return ["data": ["tools": [["name": "service_info", "description": "Fake local status", "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]]]]]
        }
    }
}
