import XCTest
import ChecklistProviders
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

    func testObservationUsesQualifiedPluginInsteadOfProviderNameParsing() throws {
        let plugin = BridgeFixtureProviderPlugin()
        let registry = try ProviderPluginRegistry([.init(plugin: plugin, enabled: true, qualifiedCapabilities: plugin.manifest.capabilities)])
        let value = try XCTUnwrap(NativeSessionContext.observed(provider: "fixture", environment: ["FIXTURE_SESSION": child],
            currentDirectory: "/tmp", registry: ["fixture_endpoint": "/tmp/fixture.sock"], providerRegistry: registry))
        XCTAssertEqual(value.provider, "fixture")
        XCTAssertEqual(value.nativeSessionID, child)
        XCTAssertEqual(value.nativeEndpoint, "/tmp/fixture.sock")
        XCTAssertEqual(value.hostTitle, "Observed by fixture plugin")
        for entry in [ProviderPluginRegistration(plugin: plugin, enabled: false, qualifiedCapabilities: plugin.manifest.capabilities),
                      ProviderPluginRegistration(plugin: plugin, enabled: true)] {
            XCTAssertNil(NativeSessionContext.observed(provider: "fixture", environment: ["FIXTURE_SESSION": child], currentDirectory: "/tmp",
                providerRegistry: try ProviderPluginRegistry([entry])))
        }
    }

    func testDiscoveryReadsRegistryForPluginsNativeHostMetadata() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let pid: Int32 = 24680
        let file = directory.appendingPathComponent("\(pid).json")
        try JSONSerialization.data(withJSONObject: ["pid": pid, "fixture_endpoint": "/tmp/fixture.sock"]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let plugin = BridgeFixtureProviderPlugin(registryDirectory: ".fixture/sessions")
        let registry = try ProviderPluginRegistry([.init(plugin: plugin, enabled: true, qualifiedCapabilities: plugin.manifest.capabilities)])
        let result = NativeSessionContext.discovery(host: ("fixture", pid), environment: ["FIXTURE_SESSION": child],
            currentDirectory: "/tmp", registryDirectory: directory, providerRegistry: registry)
        XCTAssertEqual(result.context?.nativeEndpoint, "/tmp/fixture.sock")
        XCTAssertEqual(result.context?.provider, "fixture")
        XCTAssertNil(result.registryReason)
    }
}
