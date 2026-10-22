import XCTest
import Darwin
import ChecklistProviders
@testable import ChecklistBridges

/// Reviewed-source test plugin; it is never installed, launched or enrolled.
struct BridgeFixtureProviderPlugin: ChecklistProviderPlugin {
    let manifest: ProviderPluginManifest
    var nativeHost: ProviderNativeHost? = nil

    init(provider: String = "fixture", capabilities: Set<ProviderCapability> = [.workSession, .pickup, .correlatedReply], registryDirectory: String? = nil) {
        manifest = .init(pluginID: "org.checklist.fixture", version: "1.0.0", providerID: provider,
                         displayName: "Synthetic provider", capabilities: capabilities)
        if let registryDirectory {
            nativeHost = .init(executable: "fixture-host", signingIdentifier: "fixture", signingTeam: "fixture",
                               applicationBundleID: "org.checklist.fixture", registryDirectory: registryDirectory,
                               identityVerification: "synthetic_fixture")
        }
    }

    func observe(environment: [String: String], workspace: String, registry: [String: Any]?) -> ProviderObservedSession? {
        guard let session = environment["FIXTURE_SESSION"], UUID(uuidString: session) != nil,
              workspace.hasPrefix("/") else { return nil }
        return .init(sessionID: session, workspace: workspace, endpoint: registry?["fixture_endpoint"] as? String,
                     title: "Observed by fixture plugin")
    }
}

final class NativeProviderTransportTests: XCTestCase {
    private let sender = ClaudePeerSender(replyAddress: "uds:/tmp/checklist-fixture-reply.sock", displayName: "Synthetic peer", permissionClass: .prompting)

    func testOnlyQualifiedBundledNativePeerExposesEndpointBehavior() throws {
        XCTAssertEqual(NativeProviderTransport.endpointPID(provider: "claude", endpoint: "/tmp/cc-socks/24680.sock"), 24680)
        XCTAssertEqual(NativeProviderTransport.expectedEndpoint(provider: "claude", processID: 24680), "/tmp/cc-socks/24680.sock")
        XCTAssertTrue(NativeProviderTransport.validatesEndpoint(provider: "claude", endpoint: "/tmp/cc-socks/24680.sock"))
        XCTAssertFalse(NativeProviderTransport.validatesEndpoint(provider: "claude", endpoint: "/tmp/another-host/24680.sock"))
        XCTAssertNil(NativeProviderTransport.expectedEndpoint(provider: "claude", processID: 1))
        for provider in ["codex", "unavailable"] {
            XCTAssertNil(NativeProviderTransport.endpointPID(provider: provider, endpoint: "/tmp/cc-socks/24680.sock"))
            XCTAssertNil(NativeProviderTransport.expectedEndpoint(provider: provider, processID: 24680))
            XCTAssertFalse(NativeProviderTransport.validatesEndpoint(provider: provider, endpoint: "/tmp/cc-socks/24680.sock"))
        }
        let plugin = ClaudeProviderPlugin()
        for entry in [ProviderPluginRegistration(plugin: plugin, enabled: false, qualifiedCapabilities: plugin.manifest.capabilities),
                      ProviderPluginRegistration(plugin: plugin, enabled: true)] {
            let registry = try ProviderPluginRegistry([entry])
            XCTAssertNil(NativeProviderTransport.endpointPID(provider: "claude", endpoint: "/tmp/cc-socks/24680.sock", registry: registry))
            XCTAssertNil(NativeProviderTransport.expectedEndpoint(provider: "claude", processID: 24680, registry: registry))
            XCTAssertFalse(NativeProviderTransport.validatesEndpoint(provider: "claude", endpoint: "/tmp/cc-socks/24680.sock", registry: registry))
        }
    }

    func testUnavailableDisabledAndUnqualifiedNativePeerRefuseBeforeSocketIO() throws {
        let plugin = ClaudeProviderPlugin()
        let unavailable = try ProviderPluginRegistry([])
        let disabled = try ProviderPluginRegistry([.init(plugin: plugin, enabled: false, qualifiedCapabilities: plugin.manifest.capabilities)])
        let unqualified = try ProviderPluginRegistry([.init(plugin: plugin, enabled: true)])
        for registry in [unavailable, disabled, unqualified] {
            XCTAssertThrowsError(try NativeProviderTransport.send(provider: "claude", content: "Synthetic note", messageID: "fixture",
                sender: sender, endpoint: "/missing/socket", registry: registry)) { error in
                XCTAssertTrue(error.localizedDescription.hasPrefix("ADAPTER_UNAVAILABLE:"))
            }
        }
        XCTAssertThrowsError(try NativeProviderTransport.send(provider: "codex", content: "Synthetic note", messageID: "fixture",
            sender: sender, endpoint: "/missing/socket")) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("ADAPTER_UNAVAILABLE:"))
        }
    }

    func testManifestCannotImpersonateBundledNativeImplementation() throws {
        let plugin = BridgeFixtureProviderPlugin(provider: "claude", capabilities: [.nativePeer, .correlatedReply])
        let registry = try ProviderPluginRegistry([.init(plugin: plugin, enabled: true, qualifiedCapabilities: plugin.manifest.capabilities)])
        XCTAssertNotNil(registry.plugin("claude", requiring: .nativePeer))
        XCTAssertNil(NativeProviderTransport.expectedEndpoint(provider: "claude", processID: 24680, registry: registry))
        XCTAssertThrowsError(try NativeProviderTransport.send(provider: "claude", content: "Synthetic note", messageID: "fixture",
            sender: sender, endpoint: "/missing/socket", registry: registry)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("ADAPTER_UNAVAILABLE:"))
        }
    }

    func testDispatchPreservesClaudeSyntheticFrameAndTransportOnlyReceipt() throws {
        let directory = URL(fileURLWithPath: "/tmp/checklist-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let listener = try NativeReplyListener(path: directory.appendingPathComponent("inbox.sock").path)
        let receipt = try NativeProviderTransport.send(provider: "claude", content: "Synthetic transport only", messageID: "plugin-fixture",
            sender: sender, endpoint: listener.path, expectedPeerPID: getpid())
        XCTAssertEqual(receipt.status, "transport_written")
        XCTAssertEqual(receipt.peerPID, getpid())
        let bytes = try listener.receive()
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let message = try XCTUnwrap(frame["message"] as? [String: Any])
        XCTAssertEqual(frame["msg_id"] as? String, "plugin-fixture")
        XCTAssertEqual(frame["from"] as? String, sender.replyAddress)
        XCTAssertTrue((message["content"] as? String)?.contains("from-mode=\"prompting\"") == true)
    }

    func testDispatchRejectsAnotherProvidersRegistrationBeforeSocketIO() throws {
        let registration = try XCTUnwrap(NativeLifecycleRegistration(provider: "codex", sessionID: UUID().uuidString,
            executionDomain: "codex:24680:5:0", registryPath: nil))
        XCTAssertThrowsError(try NativeProviderTransport.send(provider: "claude", content: "Synthetic note", messageID: "fixture",
            sender: sender, endpoint: "/missing/socket", expectedRegistration: registration)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("RECIPIENT_CHANGED:"))
        }
    }

    func testIncomingDecodersRequireQualifiedReviewedNativePeer() throws {
        let status: [String: Any] = ["type": "control", "action": "peer_message_status", "status": "held", "orig_msg_id": "original"]
        let reply: [String: Any] = ["type": "user", "message": ["content": "CHECKLIST_REPLY 5ba99b10-f835-4756-8575-623821763df4: Synthetic reply."]]
        for provider in ["codex", "unavailable"] {
            XCTAssertNil(NativeProviderTransport.parseHostStatus(provider: provider, object: status))
            XCTAssertNil(NativeProviderTransport.parseReply(provider: provider, object: reply))
        }
        let plugin = ClaudeProviderPlugin()
        let impersonator = BridgeFixtureProviderPlugin(provider: "claude", capabilities: [.nativePeer, .correlatedReply])
        for entry in [ProviderPluginRegistration(plugin: plugin, enabled: false, qualifiedCapabilities: plugin.manifest.capabilities),
                      ProviderPluginRegistration(plugin: plugin, enabled: true),
                      ProviderPluginRegistration(plugin: impersonator, enabled: true, qualifiedCapabilities: impersonator.manifest.capabilities)] {
            let registry = try ProviderPluginRegistry([entry])
            XCTAssertNil(NativeProviderTransport.parseHostStatus(provider: "claude", object: status, registry: registry))
            XCTAssertNil(NativeProviderTransport.parseReply(provider: "claude", object: reply, registry: registry))
        }
    }

    func testHostStatusTranslationPreservesMetadataAndExactCorrelation() throws {
        let original = "00000000-0000-4000-8000-00000000000a"
        let notice = "00000000-0000-4000-8000-000000000001"
        for state in ["held", "refused", "expired"] {
            let object: [String: Any] = ["type": "control", "action": "peer_message_status", "status": state,
                "orig_msg_id": original, "msg_id": notice, "msgV": 1, "reason": "Synthetic native notice"]
            let status = try XCTUnwrap(NativeProviderTransport.parseHostStatus(provider: "claude", object: object))
            XCTAssertEqual(status.status, state)
            XCTAssertEqual(status.deliveryState, state)
            XCTAssertEqual(status.originalMessageID, original)
            XCTAssertEqual(status.noticeID, notice)
            XCTAssertEqual(status.protocolVersion, 1)
            XCTAssertEqual(status.reason, "Synthetic native notice")
            XCTAssertTrue(status.refers(to: original, recipientPID: 80, notifierPID: 80))
            XCTAssertFalse(status.refers(to: notice, recipientPID: 80, notifierPID: 80))
            XCTAssertFalse(status.refers(to: "another-message", recipientPID: 80, notifierPID: 80))
            XCTAssertFalse(status.refers(to: original, recipientPID: 80, notifierPID: 81))
            XCTAssertFalse(status.refers(to: original, recipientPID: 80, notifierPID: 0))
        }
        let unechoed = try XCTUnwrap(NativeProviderTransport.parseHostStatus(provider: "claude", object:
            ["type": "control", "action": "peer_message_status", "status": "held", "msg_id": original]))
        XCTAssertNil(unechoed.originalMessageID)
        XCTAssertFalse(unechoed.refers(to: original, recipientPID: 80, notifierPID: 80))
        XCTAssertNil(NativeProviderTransport.parseHostStatus(provider: "claude", object:
            ["type": "control", "action": "peer_message_status", "status": "delivered"]))
    }

    func testReplyTranslationRetainsExistingEnvelopeAndFrameRules() throws {
        let mid = "5ba99b10-f835-4756-8575-623821763df4"
        let content = "<cross-session-message from=\"uds:/tmp/cc-socks/1.sock\" from-mode=\"bypass\">\n"
            + "CHECKLIST_REPLY \(mid): Synthetic reply.\n</cross-session-message>"
        let reply = try XCTUnwrap(NativeProviderTransport.parseReply(provider: "claude", object:
            ["type": "user", "message": ["content": content]]))
        XCTAssertEqual(reply.messageID, mid)
        XCTAssertEqual(reply.body, "Synthetic reply.")
        XCTAssertNil(NativeProviderTransport.parseReply(provider: "claude", object: ["type": "control", "message": ["content": content]]))
        XCTAssertNil(NativeProviderTransport.parseReply(provider: "claude", object: ["type": "user", "message": ["content": [content]]]))
        XCTAssertNil(NativeProviderTransport.parseReply(provider: "claude", object: ["type": "user", "message": ["content": "No reply marker"]]))
        XCTAssertNil(NativeProviderTransport.parseReply(provider: "claude", object:
            ["type": "user", "message": ["content": "CHECKLIST_REPLY \(mid):\n</cross-session-message>"]]))
    }

    func testServiceRelaySendOverloadConstructsActualPromptingPermission() throws {
        let directory = URL(fileURLWithPath: "/tmp/checklist-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let listener = try NativeReplyListener(path: directory.appendingPathComponent("inbox.sock").path)
        let receipt = try NativeProviderTransport.send(provider: "claude", content: "Synthetic restricted relay", messageID: "relay-fixture",
            replyAddress: listener.address, displayName: "Checklist", endpoint: listener.path, expectedPeerPID: getpid())
        XCTAssertEqual(receipt.status, "transport_written")
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: listener.receive()) as? [String: Any])
        let message = try XCTUnwrap(frame["message"] as? [String: Any])
        XCTAssertEqual(frame["from"] as? String, listener.address)
        XCTAssertTrue((message["content"] as? String)?.contains("from-mode=\"prompting\"") == true)
    }
}
