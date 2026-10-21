import XCTest
@testable import ChecklistBridges

final class NativeSessionContextTests: XCTestCase {
    let child = "a85c9a24-fce8-49ba-a738-67594bb90a67"
    let parent = "442869b6-60df-4b59-b572-c2ac85566e2a"

    func testCodexUsesActualChildExportInsteadOfParent() throws {
        let value = try XCTUnwrap(NativeSessionContext.observed(provider: "codex", environment: ["CODEX_THREAD_ID": child, "CODEX_SESSION_ID": parent], currentDirectory: "/tmp"))
        XCTAssertEqual(value.nativeSessionID, child)
        XCTAssertEqual(value.provider, "codex")
        XCTAssertNil(value.parameters["role"])
        XCTAssertNil(value.parameters["profile_id"])
        XCTAssertNil(value.parameters["credential"])
    }

    func testInvalidChildDoesNotFallBackToParent() {
        XCTAssertNil(NativeSessionContext.observed(provider: "codex", environment: ["CODEX_THREAD_ID": "unknown", "CODEX_SESSION_ID": parent], currentDirectory: "/tmp"))
    }

    func testMissingNativeIdentityDoesNotInventOne() {
        XCTAssertNil(NativeSessionContext.observed(provider: "codex", environment: [:], currentDirectory: "/tmp"))
        XCTAssertNil(NativeSessionContext.observed(provider: "claude", environment: [:], currentDirectory: "/tmp"))
        XCTAssertNil(NativeSessionContext.observed(provider: "future-provider", environment: ["CODEX_THREAD_ID": child], currentDirectory: "/tmp"))
    }

    func testRelativeWorkspaceRejected() {
        XCTAssertNil(NativeSessionContext.observed(provider: "codex", environment: ["CODEX_THREAD_ID": child], currentDirectory: "somewhere"))
    }

    func testClaudeRegistryProvidesMetadataWithoutUserIDs() throws {
        let registry: [String: Any] = ["sessionId": child, "cwd": "/tmp", "messagingSocketPath": "/tmp/cc-socks/synthetic.sock", "name": "Game\n review"]
        let value = try XCTUnwrap(NativeSessionContext.observed(provider: "claude", environment: [:], currentDirectory: "/tmp/project", registry: registry))
        XCTAssertEqual(value.nativeSessionID, child)
        XCTAssertEqual(value.nativeEndpoint, "/tmp/cc-socks/synthetic.sock")
        XCTAssertEqual(value.hostTitle, "Game review")
    }

    func testClaudeRegistryCannotReplaceAnotherWorkspace() {
        XCTAssertNil(NativeSessionContext.observed(provider: "claude", environment: [:], currentDirectory: "/var", registry: ["sessionId": child, "cwd": "/tmp"]))
    }

    func testClaudeRegistryConflictDoesNotSelectAnotherSession() {
        XCTAssertNil(NativeSessionContext.observed(provider: "claude", environment: ["CLAUDE_SESSION_ID": parent], currentDirectory: "/tmp", registry: ["sessionId": child, "cwd": "/tmp"]))
    }

    func testClaudeEndpointConflictRejected() {
        XCTAssertNil(NativeSessionContext.observed(provider: "claude", environment: ["CLAUDE_CODE_MESSAGING_SOCKET": "uds:/tmp/cc-socks/one.sock"], currentDirectory: "/tmp", registry: ["sessionId": child, "cwd": "/tmp", "messagingSocketPath": "/tmp/cc-socks/two.sock"]))
    }

    func testClaudeHostExportNormalizesUDSAddress() throws {
        let value = try XCTUnwrap(NativeSessionContext.observed(provider: "claude", environment: ["CLAUDE_SESSION_ID": child, "CLAUDE_CODE_MESSAGING_SOCKET": "uds:/tmp/cc-socks/synthetic.sock"], currentDirectory: "/tmp"))
        XCTAssertEqual(value.nativeEndpoint, "/tmp/cc-socks/synthetic.sock")
    }
}
