import Foundation
import ChecklistIPC
import ChecklistBridges

public struct BridgeConfiguration: Sendable {
    public var installation: String
    public var workspace: String
    public var expectedSession: String?
    public var automatic: Bool
    public var assistantProject: String?
    public var command: String

    public init(installation: String = "default", workspace: String, expectedSession: String? = nil,
                automatic: Bool = true, assistantProject: String? = nil, command: String = "mcp") {
        self.installation = installation; self.workspace = workspace; self.expectedSession = expectedSession
        self.automatic = automatic; self.assistantProject = assistantProject; self.command = command
    }
}

public struct BridgeClientConfiguration {
    public let installation: String
    public let workspace: String
    public let nativeContext: [String: Any]?
    public let usesStoredCredential: Bool

    public init(installation: String = "default", workspace: String, nativeContext: [String: Any]? = nil,
                usesStoredCredential: Bool = true) {
        self.installation = installation; self.workspace = workspace
        self.nativeContext = nativeContext; self.usesStoredCredential = usesStoredCredential
    }
}

public protocol BridgeClient: Sendable {
    func bootstrap(_ nativeContext: [String: Any], timeBudget: TimeInterval?) throws -> [String: Any]
    func call(_ method: String, _ params: [String: Any], replyTimeout: TimeInterval?) throws -> [String: Any]
}

extension ChecklistClient: BridgeClient {}

extension BridgeClient {
    func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        try call(method, params, replyTimeout: nil)
    }
}

public struct BridgeEnvironment: Sendable {
    public var shimUpdate: ShimUpdateEnvironment?
    public var makeClient: @Sendable (BridgeClientConfiguration) -> any BridgeClient
    public var discover: @Sendable (_ assistantRelay: Bool) -> NativeSessionDiscovery
    public var now: @Sendable () -> TimeInterval
    public var sleep: @Sendable (TimeInterval) -> Void
    public var stderr: @Sendable (String) -> Void

    public init(
        shimUpdate: ShimUpdateEnvironment? = nil,
        makeClient: @escaping @Sendable (BridgeClientConfiguration) -> any BridgeClient = {
            ChecklistClient(installation: $0.installation, workspace: $0.workspace,
                            nativeContext: $0.nativeContext, usesStoredCredential: $0.usesStoredCredential)
        },
        discover: @escaping @Sendable (Bool) -> NativeSessionDiscovery = { assistantRelay in
            if assistantRelay {
                return NativeSessionContext.discover().map(NativeSessionDiscovery.available) ?? .unavailable
            }
            return NativeSessionContext.discovery()
        },
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        stderr: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) {
        self.shimUpdate = shimUpdate
        self.makeClient = makeClient; self.discover = discover; self.now = now
        self.sleep = sleep; self.stderr = stderr
    }
}

struct BridgeError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
