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
    /// Nil when launchd cannot be asked.
    public var serviceJobRunning: @Sendable () -> Bool?
    /// The supported on-demand start of this installation's own launchd job.
    public var startService: @Sendable () throws -> Void

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
        stderr: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) },
        serviceJobRunning: @escaping @Sendable () -> Bool? = { LaunchdServiceJob.isRunning(label: ChecklistInstance.current.machServiceName) },
        startService: @escaping @Sendable () throws -> Void = { try ChecklistClient.startService(timeLimit: 8) }
    ) {
        self.shimUpdate = shimUpdate
        self.makeClient = makeClient; self.discover = discover; self.now = now
        self.sleep = sleep; self.stderr = stderr
        self.serviceJobRunning = serviceJobRunning; self.startService = startService
    }
}

/// Errors that mean only that the service did not answer yet (stalled, stopped,
/// restarting or upgrading its store). Other errors are configuration results.
enum ServiceWait {
    static func applies(_ error: Error) -> Bool {
        guard let error = error as? ChecklistError else { return false }
        return ["OUTCOME_UNKNOWN", "SERVICE_UNAVAILABLE"].contains(error.code) || StorageUpgradeStatus(error: error) != nil
    }

    /// No listener answered at all, as opposed to a reply timeout from a busy service.
    static func notRunning(_ error: Error) -> Bool {
        guard let error = error as? ChecklistError else { return false }
        if error.code == "SERVICE_UNAVAILABLE" { return true }
        return error.code == "OUTCOME_UNKNOWN" && ["connection_ended", "transport_error_after_send"].contains(error.details["reason"] as? String ?? "")
    }
}

/// The launchd job label equals the instance's Mach service name.
public enum LaunchdServiceJob {
    public static func isRunning(label: String) -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(label)"]
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        return String(decoding: data, as: UTF8.self).contains("state = running")
    }
}

struct BridgeError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
