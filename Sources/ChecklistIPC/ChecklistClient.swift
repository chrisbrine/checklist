import Foundation
import ServiceManagement

/// The GUI and stdio MCP shims share one on-demand XPC coordination service.
public final class ChecklistClient: @unchecked Sendable {
    private static let registrationLock=NSLock()
    private static var registrationChecked=false
    private let owner: Bool
    private let installation: String
    private let workspace: String?
    private let nativeContext: [String: Any]?
    private let usesStoredCredential: Bool
    /// `usesStoredCredential: false` is an unenrolled caller: the service answers only limited `service_info`.
    public init(owner: Bool = false, installation: String = "default", workspace: String? = nil, nativeContext: [String: Any]? = nil, usesStoredCredential: Bool = true) {
        self.owner = owner; self.installation = installation; self.workspace = workspace; self.nativeContext = nativeContext; self.usesStoredCredential = usesStoredCredential
    }

    /// Enrollment evidence only: the service verifies the actual signed CLI peer,
    /// native host ancestry, working directory and registered project itself.
    /// No caller-selected role, profile or credential is accepted by this path.
    public func bootstrap(_ nativeContext: [String: Any], timeBudget: TimeInterval? = nil) throws -> [String: Any] {
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
        try ChecklistPaths.prepare()
        let request: [String: Any] = ["method": "connection_bootstrap", "params": nativeContext, "installation": "automatic", "owner_channel": false]
        let bytes = try JSONSerialization.data(withJSONObject: request)
        do { return try requestOnce(bytes, replyTimeout: remaining()) }
        catch let error as ChecklistError where error.code == "SERVICE_UNAVAILABLE" {
            if let deadline {
                let serviceDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 8)
                do { try Self.startService(timeLimit: max(0, serviceDeadline - ProcessInfo.processInfo.systemUptime)) }
                catch {
                    _ = try remaining()
                    throw error
                }
                _ = try remaining()
            } else { try Self.startService() }
            return try requestOnce(bytes, replyTimeout: remaining())
        }
    }

    /// Wait for the service's result by default. A caller with a bounded lifetime can
    /// supply a timeout; expiry does not cancel the command or authorize a new UUID.
    public func call(_ method: String, _ params: [String: Any] = [:], replyTimeout: TimeInterval? = nil) throws -> [String: Any] {
        try ChecklistPaths.prepare()
        if owner { try Self.registerInstalledBuild() }
        var command = params
        if command["command_id"] == nil && CommandReply.expectsMutation(method) { command["command_id"] = UUID().uuidString.lowercased() }
        var request: [String: Any] = ["method": method, "params": command, "installation": installation]
        // This is only a requested channel. The service verifies the XPC peer's code identity.
        request["owner_channel"] = owner
        if let workspace { request["workspace"] = workspace }
        if let nativeContext, !owner { request["native_context"] = nativeContext }
        if !owner, usesStoredCredential, let token = try ChecklistKeychain.read(installation) { request["credential"] = token }
        let bytes = try JSONSerialization.data(withJSONObject: request)
        do { return try requestOnce(bytes, replyTimeout: replyTimeout) }
        catch let error as ChecklistError where error.code == "SERVICE_UNAVAILABLE" {
            try Self.startService()
            return try requestOnce(bytes, replyTimeout: replyTimeout)
        }
    }

    private static func registerInstalledBuild() throws {
        registrationLock.lock();defer { registrationLock.unlock() }
        guard !registrationChecked else { return }
        if ChecklistInstance.current.slot != nil { return }
        guard Bundle.main.bundleIdentifier == ChecklistInstance.current.bundleIdentifier,Bundle.main.executableURL?.lastPathComponent == "ChecklistApp" else { throw ChecklistError("OWNER_CHANNEL_REQUIRED","Owner operations require the actual native application.") }
        let service=SMAppService.agent(plistName:ChecklistInstance.current.agentPlistName)
        let retired=SMAppService.agent(plistName:ChecklistInstance.current.retiredAgentPlistName)
        if retired.status == .enabled || retired.status == .requiresApproval {
            let signal=DispatchSemaphore(value:0)
            Task.detached { try? await retired.unregister();signal.signal() }
            guard signal.wait(timeout:.now()+8) == .success else { throw ChecklistError("SERVICE_REGISTRATION_FAILED","The previous Checklist development service could not be unregistered.") }
        }
        let url=Bundle.main.resourceURL?.appendingPathComponent("build-info.json")
        let bytes=url.flatMap { try? Data(contentsOf:$0) }
        let info=bytes.flatMap { (try? JSONSerialization.jsonObject(with:$0)) as? [String:Any] }
        let build=info?["build_id"] as? String ?? "development"
        let previous=UserDefaults.standard.string(forKey:"registeredServiceBuild")
        if previous != build && service.status != .notRegistered && service.status != .notFound {
            // Ad-hoc development builds change code requirements. Replace only our own registration.
            let signal=DispatchSemaphore(value:0)
            var failure:Error?
            Task.detached {
                do { try await service.unregister() } catch { failure=error }
                signal.signal()
            }
            guard signal.wait(timeout:.now()+8) == .success else { throw ChecklistError("SERVICE_REGISTRATION_FAILED","The previous Checklist service did not unregister within eight seconds.") }
            if let failure { throw ChecklistError("SERVICE_REGISTRATION_FAILED",failure.localizedDescription) }
        }
        if previous != build || service.status == .notRegistered || service.status == .notFound { try service.register() }
        guard service.status == .enabled else { throw ChecklistError("SERVICE_SETUP_REQUIRED","Allow Checklist's background service in System Settings → General → Login Items & Extensions, then retry.") }
        UserDefaults.standard.set(build,forKey:"registeredServiceBuild")
        registrationChecked=true
    }

    // The connection argument lets qualification use an anonymous XPC listener,
    // exercising this exact client without contacting the installed service.
    func requestOnce(_ bytes: Data, replyTimeout: TimeInterval? = nil, connection suppliedConnection: NSXPCConnection? = nil) throws -> [String: Any] {
        if let replyTimeout, !replyTimeout.isFinite || replyTimeout < 0 {
            throw ChecklistError("INVALID_INPUT", "The reply timeout must be a finite, nonnegative number of seconds.")
        }
        let request = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        let commandID = (request?["params"] as? [String: Any])?["command_id"] as? String
        let connection = suppliedConnection ?? NSXPCConnection(machServiceName: ChecklistInstance.current.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: ChecklistRPC.self)
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var response: Data?
        var transportError: Error?
        var finished = false
        func complete(_ value: Data?, _ error: Error?) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true; response = value; transportError = error
            lock.unlock(); semaphore.signal()
        }
        connection.interruptionHandler = { complete(nil, nil) }
        connection.invalidationHandler = { complete(nil, nil) }
        connection.resume()
        defer { connection.invalidate() }
        guard let remote = connection.remoteObjectProxyWithErrorHandler({ error in
            complete(nil, error)
        }) as? ChecklistRPC else { throw ChecklistError("SERVICE_UNAVAILABLE", "XPC service unavailable.") }
        remote.execute(bytes) { value in complete(value, nil) }
        let deadline: DispatchTime = replyTimeout.map { .now() + max(0, $0) } ?? .distantFuture
        guard semaphore.wait(timeout: deadline) == .success else {
            throw CommandReply.unknown(commandID: commandID, reason: "reply_timeout")
        }
        lock.lock(); let received = response; let failure = transportError; lock.unlock()
        guard let received else {
            // execute was already invoked; a proxy failure cannot prove noncommit.
            let error = CommandReply.unknown(commandID: commandID, reason: failure == nil ? "connection_ended" : "transport_error_after_send")
            if ChecklistInstance.current.slot != nil {
                throw ChecklistError(error.code, error.message + " " + ChecklistInstance.current.startInstruction, details:error.details)
            }
            throw error
        }
        return try CommandReply.decode(received, method: request?["method"] as? String ?? "", commandID: commandID)
    }

    public static func startService(timeLimit: TimeInterval = 8) throws {
        if ChecklistInstance.current.slot != nil { throw ChecklistError("SERVICE_UNAVAILABLE", ChecklistInstance.current.startInstruction) }
        try ChecklistPaths.prepare()
        // Launchd owns singleton startup and Mach rights; opening XPC starts infrastructure only.
        let deadline = ProcessInfo.processInfo.systemUptime + min(8, timeLimit)
        while ProcessInfo.processInfo.systemUptime < deadline {
            let client = ChecklistClient()
            let probe = try JSONSerialization.data(withJSONObject:["method":"service_info","params":[:],"installation":"startup"])
            let left = deadline - ProcessInfo.processInfo.systemUptime
            if (try? client.requestOnce(probe, replyTimeout: min(1, max(0, left)))) != nil { return }
            let pause = min(0.08, deadline - ProcessInfo.processInfo.systemUptime)
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        }
        throw ChecklistError("SERVICE_UNAVAILABLE", "The registered Mach service did not respond. Check Checklist background service status; no second store was created.")
    }
}
