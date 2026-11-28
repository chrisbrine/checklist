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
        let timed = CallTimingLog.enabled
        var phases: [String: Double] = [:]
        defer { if timed { Self.logCallTiming(method: "connection_bootstrap", started: started, phases: phases) } }
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
        let lifecycleStarted = timed ? ProcessInfo.processInfo.systemUptime : 0
        try platformServices.lifecycle.prepare()
        let encodingStarted = timed ? ProcessInfo.processInfo.systemUptime : 0
        var request: [String: Any] = ["method": "connection_bootstrap", "params": nativeContext, "installation": "automatic", "owner_channel": false]
        if timed { request["diagnostics_timing"] = true }
        let bytes = try JSONSerialization.data(withJSONObject: request)
        if timed {
            let prepared = ProcessInfo.processInfo.systemUptime
            phases["lifecycle_prepare_ms"] = (encodingStarted - lifecycleStarted) * 1000
            phases["request_encode_ms"] = (prepared - encodingStarted) * 1000
            phases["preparation_ms"] = (prepared - started) * 1000
        }
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
        let timed = CallTimingLog.enabled
        var phases: [String: Double] = [:]
        defer { if timed { Self.logCallTiming(method: method, started: started, phases: phases) } }
        try platformServices.lifecycle.prepare()
        if owner { try platformServices.lifecycle.registerInstalledBuild() }
        if timed { phases["lifecycle_prepare_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000 }
        var command = params
        if command["command_id"] == nil && CommandReply.expectsMutation(method) { command["command_id"] = UUID().uuidString.lowercased() }
        var request: [String: Any] = ["method": method, "params": command, "installation": installation]
        // This is only a requested channel. The service verifies the XPC peer's code identity.
        request["owner_channel"] = owner
        if let workspace { request["workspace"] = workspace }
        if let nativeContext, !owner { request["native_context"] = nativeContext }
        if !owner, usesStoredCredential {
            let credentialStarted = timed ? ProcessInfo.processInfo.systemUptime : 0
            if let token = try platformServices.credentials.readInstallationCredential(installation) { request["credential"] = token }
            if timed { phases["credential_read_ms"] = (ProcessInfo.processInfo.systemUptime - credentialStarted) * 1000 }
        }
        let encodingStarted = timed ? ProcessInfo.processInfo.systemUptime : 0
        if timed { request["diagnostics_timing"] = true }
        let bytes = try JSONSerialization.data(withJSONObject: request)
        if timed {
            let prepared = ProcessInfo.processInfo.systemUptime
            phases["request_encode_ms"] = (prepared - encodingStarted) * 1000
            phases["preparation_ms"] = (prepared - started) * 1000
        }
        do { return try requestOnce(bytes, replyTimeout: replyTimeout) }
        catch let error as ChecklistError where error.code == "SERVICE_UNAVAILABLE" {
            try platformServices.lifecycle.startService(timeLimit: 8)
            return try requestOnce(bytes, replyTimeout: replyTimeout)
        }
    }

    private static func logCallTiming(method: String, started: TimeInterval, phases: [String: Double]) {
        var fields: [String: Any] = phases
        fields["preparation_ms"] = phases["preparation_ms"] ?? 0
        fields["scope"] = "client"
        fields["method"] = method
        fields["total_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
        CallTimingLog.write(fields)
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

    /// Probe the existing owner channel once. Normal app requests own service
    /// registration. The probe has no startup retry or credential work.
    public static func probeOwnerService(replyTimeout: TimeInterval, platformServices: LocalPlatformServices = .macOS) async throws {
        try Task.checkCancellation()
        try await offloadBlockingCall {
            let bytes = try JSONSerialization.data(withJSONObject: [
                "method": "service_info", "params": [:], "installation": "default", "owner_channel": true
            ] as [String: Any])
            let reply = try platformServices.transport.request(bytes, replyTimeout: replyTimeout)
            guard let info = reply["data"] as? [String: Any], info["role"] as? String == "owner",
                  let incarnation = info["store_incarnation"] as? String, !incarnation.isEmpty else {
                throw ChecklistError("INVALID_RESPONSE", "The Checklist service did not confirm the owner channel.")
            }
        }
    }
}
