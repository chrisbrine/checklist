import XCTest
import ChecklistProviders
@testable import ChecklistBridges

final class NativePlatformAdapterTests: XCTestCase {
    private let sender = ClaudePeerSender(replyAddress: "uds:/tmp/checklist-adapter-reply.sock",
                                         displayName: "Synthetic peer", permissionClass: .prompting)

    func testUnsupportedAdapterFailsWithPreciseUnavailableCapability() throws {
        let effects = UnsupportedNativePeerTransportEffects()
        XCTAssertThrowsError(try effects.send(content: "Synthetic note", messageID: "adapter-fixture", sender: sender,
            endpoint: "/missing/socket", expectedPeerPID: nil, expectedRegistration: nil, timeout: 5,
            providerRegistry: .bundled)) { error in
            XCTAssertEqual(error.localizedDescription, "ADAPTER_UNAVAILABLE: Native peer transport is unavailable on this platform.")
            XCTAssertFalse((error as? NativeBridgeError)?.deliveryMayHaveOccurred ?? true)
        }
        XCTAssertThrowsError(try NativeProviderTransport.send(provider: "claude", content: "Synthetic note", messageID: "adapter-fixture",
            sender: sender, endpoint: "/missing/socket", effects: effects)) { error in
            XCTAssertEqual(error.localizedDescription, "ADAPTER_UNAVAILABLE: Native peer transport is unavailable on this platform.")
        }
    }

    func testTransportForwardsExactIdentityAndTransportReceiptToExplicitAdapter() throws {
        let effects = RecordingNativePeerTransportEffects()
        let registration = try XCTUnwrap(NativeLifecycleRegistration(provider: "claude", sessionID: UUID().uuidString,
            executionDomain: "claude:24680:5:42", registryPath: "/tmp/synthetic-native-registration.json"))
        let receipt = try NativeProviderTransport.send(provider: "claude", content: "Synthetic note", messageID: "adapter-fixture",
            sender: sender, endpoint: "/tmp/cc-socks/24680.sock", expectedPeerPID: 24680,
            expectedRegistration: registration, timeout: 0.75, effects: effects)
        let call = try XCTUnwrap(effects.calls.first)
        XCTAssertEqual(effects.calls.count, 1)
        XCTAssertEqual(call.content, "Synthetic note")
        XCTAssertEqual(call.messageID, "adapter-fixture")
        XCTAssertEqual(call.sender.replyAddress, sender.replyAddress)
        XCTAssertEqual(call.sender.displayName, sender.displayName)
        XCTAssertEqual(call.sender.permissionClass, .prompting)
        XCTAssertEqual(call.endpoint, "/tmp/cc-socks/24680.sock")
        XCTAssertEqual(call.expectedPeerPID, 24680)
        XCTAssertEqual(call.registration?.provider, registration.provider)
        XCTAssertEqual(call.registration?.sessionID, registration.sessionID)
        XCTAssertEqual(call.registration?.processID, registration.processID)
        XCTAssertEqual(call.registration?.startSeconds, registration.startSeconds)
        XCTAssertEqual(call.registration?.startMicroseconds, registration.startMicroseconds)
        XCTAssertEqual(call.registration?.registryPath, registration.registryPath)
        XCTAssertEqual(call.timeout, 0.75)
        XCTAssertTrue(call.qualifiedClaude)
        XCTAssertEqual(receipt.status, "transport_written")
        XCTAssertEqual(receipt.byteCount, effects.receipt.byteCount)
        XCTAssertEqual(receipt.socketDevice, effects.receipt.socketDevice)
        XCTAssertEqual(receipt.socketInode, effects.receipt.socketInode)
        XCTAssertEqual(receipt.peerPID, effects.receipt.peerPID)
        XCTAssertEqual(receipt.recordedAt, effects.receipt.recordedAt)
    }

    func testServiceRelayRetainsPromptingPermissionWithExplicitAdapter() throws {
        let effects = RecordingNativePeerTransportEffects()
        _ = try NativeProviderTransport.send(provider: "claude", content: "Synthetic relay", messageID: "adapter-fixture",
            replyAddress: sender.replyAddress, displayName: "Checklist", endpoint: "/tmp/cc-socks/24680.sock", effects: effects)
        let call = try XCTUnwrap(effects.calls.first)
        XCTAssertEqual(effects.calls.count, 1)
        XCTAssertEqual(call.sender.permissionClass, .prompting)
        XCTAssertEqual(call.sender.replyAddress, sender.replyAddress)
        XCTAssertEqual(call.sender.displayName, "Checklist")
    }

    func testUnqualifiedProviderCannotReachExplicitAdapter() throws {
        let effects = RecordingNativePeerTransportEffects()
        let plugin = ClaudeProviderPlugin()
        let disabled = try ProviderPluginRegistry([.init(plugin: plugin, enabled: false, qualifiedCapabilities: plugin.manifest.capabilities)])
        let unqualified = try ProviderPluginRegistry([.init(plugin: plugin, enabled: true)])
        let impersonator = BridgeFixtureProviderPlugin(provider: "claude", capabilities: [.nativePeer, .correlatedReply])
        let impersonated = try ProviderPluginRegistry([.init(plugin: impersonator, enabled: true, qualifiedCapabilities: impersonator.manifest.capabilities)])
        for registry in [try ProviderPluginRegistry([]), disabled, unqualified, impersonated] {
            XCTAssertThrowsError(try NativeProviderTransport.send(provider: "claude", content: "Synthetic note", messageID: "adapter-fixture",
                sender: sender, endpoint: "/missing/socket", registry: registry, effects: effects)) { error in
                XCTAssertEqual(error.localizedDescription, "ADAPTER_UNAVAILABLE: No qualified bundled native peer transport is available for this provider.")
            }
        }
        XCTAssertThrowsError(try NativeProviderTransport.send(provider: "codex", content: "Synthetic note", messageID: "adapter-fixture",
            sender: sender, endpoint: "/missing/socket", effects: effects))
        XCTAssertTrue(effects.calls.isEmpty)
    }

    func testAnotherProvidersRegistrationCannotReachExplicitAdapter() throws {
        let effects = RecordingNativePeerTransportEffects()
        let registration = try XCTUnwrap(NativeLifecycleRegistration(provider: "codex", sessionID: UUID().uuidString,
            executionDomain: "codex:24680:5:0", registryPath: nil))
        XCTAssertThrowsError(try NativeProviderTransport.send(provider: "claude", content: "Synthetic note", messageID: "adapter-fixture",
            sender: sender, endpoint: "/missing/socket", expectedRegistration: registration, effects: effects)) { error in
            XCTAssertEqual(error.localizedDescription, "RECIPIENT_CHANGED: native registration belongs to another provider.")
        }
        XCTAssertTrue(effects.calls.isEmpty)
    }

    func testTransportPreservesUncertainWriteAndNeverRetriesAdapter() throws {
        let effects = RecordingNativePeerTransportEffects()
        effects.failure = .outcomeUnknown("Synthetic partial write")
        XCTAssertThrowsError(try NativeProviderTransport.send(provider: "claude", content: "Synthetic note", messageID: "adapter-fixture",
            sender: sender, endpoint: "/missing/socket", effects: effects)) { error in
            XCTAssertTrue((error as? NativeBridgeError)?.deliveryMayHaveOccurred == true)
            XCTAssertEqual(error.localizedDescription, "DELIVERY_UNCERTAIN: Synthetic partial write Reconcile the original delivery before any explicit retry.")
        }
        XCTAssertEqual(effects.calls.count, 1)
    }
}

private final class RecordingNativePeerTransportEffects: NativePeerTransportEffects {
    struct Call {
        let content: String
        let messageID: String
        let sender: ClaudePeerSender
        let endpoint: String
        let expectedPeerPID: Int32?
        let registration: NativeLifecycleRegistration?
        let timeout: TimeInterval
        let qualifiedClaude: Bool
    }
    var calls: [Call] = []
    var failure: NativeBridgeError?
    let receipt = NativeWriteReceipt(status: "transport_written", byteCount: 101,
                                    socketDevice: 31, socketInode: 42, peerPID: 24680,
                                    recordedAt: Date(timeIntervalSince1970: 1234))

    func send(content: String, messageID: String, sender: ClaudePeerSender,
              endpoint: String, expectedPeerPID: Int32?, expectedRegistration: NativeLifecycleRegistration?,
              timeout: TimeInterval, providerRegistry: ProviderPluginRegistry) throws -> NativeWriteReceipt {
        calls.append(.init(content: content, messageID: messageID, sender: sender, endpoint: endpoint,
                           expectedPeerPID: expectedPeerPID, registration: expectedRegistration, timeout: timeout,
                           qualifiedClaude: providerRegistry.plugin("claude", requiring: .nativePeer) is ClaudeProviderPlugin))
        if let failure { throw failure }
        return receipt
    }
}
