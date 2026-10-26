import Foundation
import ChecklistProviders

/// A translated native notice remains untrusted input until it is correlated
/// with one exact message and the kernel-verified recipient process.
public struct NativeProviderHostStatus: Equatable, Sendable {
    public let status: String
    public let deliveryState: String
    public let originalMessageID: String?
    public let noticeID: String?
    public let protocolVersion: Int?
    public let reason: String?

    public func refers(to messageID: String, recipientPID: Int32, notifierPID: Int32) -> Bool {
        notifierPID > 0 && notifierPID == recipientPID && originalMessageID == messageID
    }
}

/// Dispatches only reviewed bundled native implementations after capability
/// qualification. A manifest, provider name or endpoint cannot create a route.
/// Claude's framing, verified-peer checks and write-only receipt stay unchanged.
public enum NativeProviderTransport {
    /// The service's own relay uses the actual restricted sender class. Provider
    /// permission metadata is constructed by its adapter, never by message text.
    public static func send(provider: String, content: String, messageID: String, replyAddress: String, displayName: String,
                            endpoint: String, expectedPeerPID: Int32? = nil,
                            expectedRegistration: NativeLifecycleRegistration? = nil,
                            timeout: TimeInterval = 5, registry: ProviderPluginRegistry = .bundled,
                            effects: any NativePeerTransportEffects = NativePeerTransportAdapters.current) throws -> NativeWriteReceipt {
        try send(provider: provider, content: content, messageID: messageID,
                 sender: ClaudePeerSender(replyAddress: replyAddress, displayName: displayName, permissionClass: .prompting),
                 endpoint: endpoint, expectedPeerPID: expectedPeerPID, expectedRegistration: expectedRegistration,
                 timeout: timeout, registry: registry, effects: effects)
    }

    /// Compatibility entrypoint for the existing provider-specific bridge API.
    public static func send(provider: String, content: String, messageID: String, sender: ClaudePeerSender,
                            endpoint: String, expectedPeerPID: Int32? = nil,
                            expectedRegistration: NativeLifecycleRegistration? = nil,
                            timeout: TimeInterval = 5, registry: ProviderPluginRegistry = .bundled,
                            effects: any NativePeerTransportEffects = NativePeerTransportAdapters.current) throws -> NativeWriteReceipt {
        guard nativePlugin(provider: provider, registry: registry) != nil else {
            throw NativeBridgeError.invalid("ADAPTER_UNAVAILABLE: No qualified bundled native peer transport is available for this provider.")
        }
        guard expectedRegistration == nil || expectedRegistration?.provider == provider else {
            throw NativeBridgeError.invalid("RECIPIENT_CHANGED: native registration belongs to another provider.")
        }
        return try effects.send(content: content, messageID: messageID, sender: sender,
            endpoint: endpoint, expectedPeerPID: expectedPeerPID, expectedRegistration: expectedRegistration, timeout: timeout, providerRegistry:registry)
    }

    /// Provider-owned socket naming is diagnostic routing evidence, not peer
    /// authentication. The transport still verifies the connected kernel peer.
    public static func endpointPID(provider: String, endpoint: String, registry: ProviderPluginRegistry = .bundled) -> Int32? {
        nativePlugin(provider: provider, registry: registry)?.nativeEndpointPID(endpoint)
    }

    public static func expectedEndpoint(provider: String, processID: Int32, registry: ProviderPluginRegistry = .bundled) -> String? {
        nativePlugin(provider: provider, registry: registry)?.expectedNativeEndpoint(processID)
    }

    /// The existing explicit enrollment accepts the host's local socket family;
    /// socket permissions and actual peer identity still need independent checks.
    public static func validatesEndpoint(provider: String, endpoint: String, registry: ProviderPluginRegistry = .bundled) -> Bool {
        nativePlugin(provider: provider, registry: registry)?.validatesNativeEndpoint(endpoint) == true
    }

    public static func parseHostStatus(provider: String, object: [String: Any], registry: ProviderPluginRegistry = .bundled) -> NativeProviderHostStatus? {
        nativePlugin(provider: provider, registry: registry)?.parseNativeHostStatus(object)
    }

    public static func parseReply(provider: String, object: [String: Any], registry: ProviderPluginRegistry = .bundled) -> (messageID: String, body: String)? {
        nativePlugin(provider: provider, registry: registry)?.parseNativeReply(object)
    }

    private static func nativePlugin(provider: String, registry: ProviderPluginRegistry) -> ClaudeProviderPlugin? {
        registry.plugin(provider, requiring: .nativePeer) as? ClaudeProviderPlugin
    }
}
