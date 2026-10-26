import Foundation

/// The GUI and stdio MCP shims share one on-demand XPC coordination service.
public final class ChecklistClient: @unchecked Sendable {
    private let owner: Bool
    private let installation: String
    private let workspace: String?
    private let nativeContext: [String: Any]?
    private let usesStoredCredential: Bool
    private let platformServices: LocalPlatformServices
    /// `usesStoredCredential: false` is an unenrolled caller: the service answers only limited `service_info`.
    public init(owner: Bool = false, installation: String = "default", workspace: String? = nil, nativeContext: [String: Any]? = nil, usesStoredCredential: Bool = true, platformServices: LocalPlatformServices = .macOS) {
        self.owner = owner; self.installation = installation; self.workspace = workspace; self.nativeContext = nativeContext; self.usesStoredCredential = usesStoredCredential
        self.platformServices = platformServices
    }

    /// Enrollment evidence only: the service verifies the actual signed CLI peer,
    /// native host ancestry, working directory and registered project itself.
    /// No caller-selected role, profile or credential is accepted by this path.
    public func bootstrap(_ nativeContext: [String: Any], timeBudget: TimeInterval? = nil) throws -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        var preparationMS: Double = 0
        defer { if CallTimingLog.enabled { CallTimingLog.write(["scope":"client", "method":"connection_bootstrap", "preparation_ms":preparationMS, "total_ms":(ProcessInfo.processInfo.systemUptime-started)*1000]) } }
        if let timeBudget, !timeBudget.isFinite || timeBudget < 0 {
            throw ChecklistError("INVALID_INPUT", "The bootstrap time budget must be a finite, nonnegative number of seconds.")
        }
        let deadline = timeBudget.map { ProcessInfo.processInfo.systemUptime + $0 }
        func remaining(_ limit: TimeInterval = 15) throws -> TimeInterval {
            guard let deadline else { return limit }
            let left = deadline - ProcessInfo.processInfo.systemUptime
            guard left > 0 else { throw CommandReply.unknown(commandID: nil, reason: "reply_timeout") }
            return min(limit, left)
        }
        _ = try remaining()
        try platformServices.lifecycle.prepare()
        var request: [String: Any] = ["method": "connection_bootstrap", "params": nativeContext, "installation": "automatic", "owner_channel": false]
        if CallTimingLog.enabled { request["diagnostics_timing"] = true }
        let bytes = try JSONSerialization.data(withJSONObject: request)
        preparationMS = (ProcessInfo.processInfo.systemUptime-started)*1000
        do { return try requestOnce(bytes, replyTimeout: remaining()) }
        catch let error as ChecklistError where error.code == "SERVICE_UNAVAILABLE" {
            if let deadline {
                let serviceDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 8)
                do { try platformServices.lifecycle.startService(timeLimit: max(0, serviceDeadline - ProcessInfo.processInfo.systemUptime)) }
                catch {
                    _ = try remaining()
                    throw error
                }
                _ = try remaining()
            } else { try platformServices.lifecycle.startService(timeLimit: 8) }
            return try requestOnce(bytes, replyTimeout: remaining())
        }
    }

    /// Wait for the service's result by default. A caller with a bounded lifetime can
    /// supply a timeout; expiry does not cancel the command or authorize a new UUID.
    public func call(_ method: String, _ params: [String: Any] = [:], replyTimeout: TimeInterval? = nil) throws -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        var preparationMS: Double = 0
        defer { if CallTimingLog.enabled { CallTimingLog.write(["scope":"client", "method":method, "preparation_ms":preparationMS, "total_ms":(ProcessInfo.processInfo.systemUptime-started)*1000]) } }
        try platformServices.lifecycle.prepare()
        if owner { try platformServices.lifecycle.registerInstalledBuild() }
        var command = params
        if command["command_id"] == nil && CommandReply.expectsMutation(method) { command["command_id"] = UUID().uuidString.lowercased() }
        var request: [String: Any] = ["method": method, "params": command, "installation": installation]
        // This is only a requested channel. The service verifies the XPC peer's code identity.
        request["owner_channel"] = owner
        if let workspace { request["workspace"] = workspace }
        if let nativeContext, !owner { request["native_context"] = nativeContext }
        if !owner, usesStoredCredential, let token = try platformServices.credentials.readInstallationCredential(installation) { request["credential"] = token }
        if CallTimingLog.enabled { request["diagnostics_timing"] = true }
        let bytes = try JSONSerialization.data(withJSONObject: request)
        preparationMS = (ProcessInfo.processInfo.systemUptime-started)*1000
        do { return try requestOnce(bytes, replyTimeout: replyTimeout) }
        catch let error as ChecklistError where error.code == "SERVICE_UNAVAILABLE" {
            try platformServices.lifecycle.startService(timeLimit: 8)
            return try requestOnce(bytes, replyTimeout: replyTimeout)
        }
    }

    // The connection argument preserves the anonymous-listener qualification seam.
    func requestOnce(_ bytes: Data, replyTimeout: TimeInterval? = nil, connection suppliedConnection: NSXPCConnection? = nil) throws -> [String: Any] {
        if let suppliedConnection {
            return try MacOSLocalCommandTransport().request(bytes, replyTimeout: replyTimeout, connection: suppliedConnection)
        }
        return try platformServices.transport.request(bytes, replyTimeout: replyTimeout)
    }

    public static func startService(timeLimit: TimeInterval = 8) throws {
        try LocalPlatformServices.macOS.lifecycle.startService(timeLimit: timeLimit)
    }
}
