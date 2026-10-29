import Foundation
import ServiceManagement
import os

/// Platform effects used by the local command client. These capabilities do not
/// grant owner/worker authority; the service still authenticates the signed peer.
public enum LocalPlatformCapability: String, CaseIterable, Sendable {
    case localCommandTransport = "local_command_transport"
    case servicePreparation = "service_preparation"
    case serviceRegistration = "service_registration"
    case serviceStartup = "service_startup"
    case installationCredentialRead = "installation_credential_read"
}

public protocol LocalCommandTransport: Sendable {
    func request(_ bytes: Data, replyTimeout: TimeInterval?) throws -> [String: Any]
}

public protocol LocalServiceLifecycle: Sendable {
    func prepare() throws
    func registerInstalledBuild() throws
    func startService(timeLimit: TimeInterval) throws
}

public protocol LocalCredentialReader: Sendable {
    func readInstallationCredential(_ installation: String) throws -> String?
}

/// Explicit composition at the native boundary, not a fallback runtime selector.
public struct LocalPlatformServices: Sendable {
    public let transport: any LocalCommandTransport
    public let lifecycle: any LocalServiceLifecycle
    public let credentials: any LocalCredentialReader
    /// Implementation support, not a probe of current authorization, registration
    /// or test-slot availability. Operations still enforce their native guards.
    public let supportedCapabilities: Set<LocalPlatformCapability>

    public init(transport: any LocalCommandTransport, lifecycle: any LocalServiceLifecycle,
                credentials: any LocalCredentialReader, supportedCapabilities: Set<LocalPlatformCapability>) {
        self.transport = transport
        self.lifecycle = lifecycle
        self.credentials = credentials
        self.supportedCapabilities = supportedCapabilities
    }

    public static var macOS: LocalPlatformServices {
        let transport = MacOSLocalCommandTransport()
        return LocalPlatformServices(transport: transport, lifecycle: MacOSLocalServiceLifecycle(transport: transport),
                                     credentials: MacOSLocalCredentialReader(), supportedCapabilities: Set(LocalPlatformCapability.allCases))
    }

    public static func unavailable(platform: String) -> LocalPlatformServices {
        let adapter = UnavailableLocalPlatformServices(platform: platform)
        return LocalPlatformServices(transport: adapter, lifecycle: adapter, credentials: adapter, supportedCapabilities: [])
    }
}

/// Missing capabilities fail explicitly without using another transport, storing
/// credentials, enrolling a caller or launching a CLI/model process.
public struct UnavailableLocalPlatformServices: LocalCommandTransport, LocalServiceLifecycle, LocalCredentialReader {
    public let platform: String
    public init(platform: String) { self.platform = platform }

    private func unavailable(_ capability: LocalPlatformCapability) -> ChecklistError {
        ChecklistError("PLATFORM_CAPABILITY_UNAVAILABLE", "This platform does not support \(capability.rawValue).",
                       details: ["capability": capability.rawValue, "platform": platform])
    }

    public func request(_ bytes: Data, replyTimeout: TimeInterval?) throws -> [String: Any] { throw unavailable(.localCommandTransport) }
    public func prepare() throws { throw unavailable(.servicePreparation) }
    public func registerInstalledBuild() throws { throw unavailable(.serviceRegistration) }
    public func startService(timeLimit: TimeInterval) throws { throw unavailable(.serviceStartup) }
    public func readInstallationCredential(_ installation: String) throws -> String? { throw unavailable(.installationCredentialRead) }
}

public struct MacOSLocalCredentialReader: LocalCredentialReader {
    public init() {}
    public func readInstallationCredential(_ installation: String) throws -> String? {
        try ChecklistKeychain.read(installation)
    }
}

public struct MacOSLocalCommandTransport: LocalCommandTransport {
    public init() {}
    public func request(_ bytes: Data, replyTimeout: TimeInterval?) throws -> [String: Any] {
        try request(bytes, replyTimeout: replyTimeout, connection: nil)
    }

    // Qualification supplies an anonymous listener to exercise the same native
    // transport without contacting the installed Mach service.
    func request(_ bytes: Data, replyTimeout: TimeInterval?, connection suppliedConnection: NSXPCConnection?, upgradeRoot: URL = ChecklistPaths.root) throws -> [String: Any] {
        if let replyTimeout, !replyTimeout.isFinite || replyTimeout < 0 {
            throw ChecklistError("INVALID_INPUT", "The reply timeout must be a finite, nonnegative number of seconds.")
        }
        let started = ProcessInfo.processInfo.systemUptime
        let request = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        var diagnostic: [String:Any] = [:]
        defer { if request?["diagnostics_timing"] as? Bool == true {
            diagnostic["scope"] = "ipc"; diagnostic["method"] = request?["method"] as? String ?? ""
            diagnostic["total_ms"] = (ProcessInfo.processInfo.systemUptime-started)*1000
            CallTimingLog.write(diagnostic)
        } }
        let commandID = (request?["params"] as? [String: Any])?["command_id"] as? String
        func upgradeStatus() -> StorageUpgradeStatus? { suppliedConnection == nil ? StorageUpgradeStatus.read(root: upgradeRoot) : nil }
        if let upgrade = upgradeStatus() { throw upgrade.error(commandID: commandID) }
        let connection = suppliedConnection ?? NSXPCConnection(machServiceName: ChecklistInstance.current.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: ChecklistRPC.self)
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = OSAllocatedUnfairLock(initialState: (finished: false, response: Optional<Data>.none, error: Optional<Error>.none))
        let complete: @Sendable (Data?, Error?) -> Void = { value, error in
            let accepted = outcome.withLock { state in
                guard !state.finished else { return false }
                state.finished = true; state.response = value; state.error = error
                return true
            }
            if accepted { semaphore.signal() }
        }
        connection.interruptionHandler = { complete(nil, nil) }
        connection.invalidationHandler = { complete(nil, nil) }
        connection.resume()
        defer { connection.invalidate() }
        guard let remote = connection.remoteObjectProxyWithErrorHandler({ error in
            complete(nil, error)
        }) as? ChecklistRPC else { throw ChecklistError("SERVICE_UNAVAILABLE", "XPC service unavailable.") }
        let sent = ProcessInfo.processInfo.systemUptime
        diagnostic["connection_setup_ms"] = (sent-started)*1000
        remote.execute(bytes) { value in complete(value, nil) }
        let deadline: DispatchTime = replyTimeout.map { .now() + max(0, $0) } ?? .distantFuture
        guard semaphore.wait(timeout: deadline) == .success else {
            if let upgrade = upgradeStatus() { throw upgrade.error(commandID: commandID, outcomeUnknown: true, transportReason: "reply_timeout") }
            throw CommandReply.unknown(commandID: commandID, reason: "reply_timeout")
        }
        let (received, failure) = outcome.withLock { ($0.response, $0.error) }
        guard let received else {
            // execute was already invoked; a proxy failure cannot prove noncommit.
            if let upgrade = upgradeStatus() { throw upgrade.error(commandID: commandID, outcomeUnknown: true, transportReason: failure == nil ? "connection_ended" : "transport_error_after_send") }
            let error = CommandReply.unknown(commandID: commandID, reason: failure == nil ? "connection_ended" : "transport_error_after_send")
            if ChecklistInstance.current.slot != nil {
                throw ChecklistError(error.code, error.message + " " + ChecklistInstance.current.startInstruction, details:error.details)
            }
            throw error
        }
        diagnostic["send_to_reply_ms"] = (ProcessInfo.processInfo.systemUptime-sent)*1000
        diagnostic["round_trip_ms"] = (ProcessInfo.processInfo.systemUptime-started)*1000
        if request?["diagnostics_timing"] as? Bool == true, let object = try? JSONSerialization.jsonObject(with:received) as? [String:Any] { diagnostic["service"] = object["_checklist_timing"] }
        return try CommandReply.decode(received, method: request?["method"] as? String ?? "", commandID: commandID)
    }

}

public struct MacOSLocalServiceLifecycle: LocalServiceLifecycle {
    private static let registrationState = OSAllocatedUnfairLock(initialState: false)
    private let transport: any LocalCommandTransport

    public init(transport: any LocalCommandTransport = MacOSLocalCommandTransport()) { self.transport = transport }
    public func prepare() throws { try ChecklistPaths.prepare() }

    public func registerInstalledBuild() throws {
        try Self.registrationState.withLock { registrationChecked in
            guard !registrationChecked else { return }
            if ChecklistInstance.current.slot != nil { return }
            guard Bundle.main.bundleIdentifier == ChecklistInstance.current.bundleIdentifier,Bundle.main.executableURL?.lastPathComponent == "ChecklistApp" else { throw ChecklistError("OWNER_CHANNEL_REQUIRED","Owner operations require the actual native application.") }
            let service=SMAppService.agent(plistName:ChecklistInstance.current.agentPlistName)
            let retired=SMAppService.agent(plistName:ChecklistInstance.current.retiredAgentPlistName)
            if retired.status == .enabled || retired.status == .requiresApproval {
                let signal=DispatchSemaphore(value:0)
                let retiredPlistName = ChecklistInstance.current.retiredAgentPlistName
                Task.detached {
                    try? await SMAppService.agent(plistName: retiredPlistName).unregister()
                    signal.signal()
                }
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
                let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
                let servicePlistName = ChecklistInstance.current.agentPlistName
                Task.detached {
                    do { try await SMAppService.agent(plistName: servicePlistName).unregister() }
                    catch { failure.withLock { $0 = error.localizedDescription } }
                    signal.signal()
                }
                guard signal.wait(timeout:.now()+8) == .success else { throw ChecklistError("SERVICE_REGISTRATION_FAILED","The previous Checklist service did not unregister within eight seconds.") }
                if let message = failure.withLock({ $0 }) { throw ChecklistError("SERVICE_REGISTRATION_FAILED", message) }
            }
            if previous != build || service.status == .notRegistered || service.status == .notFound { try service.register() }
            guard service.status == .enabled else { throw ChecklistError("SERVICE_SETUP_REQUIRED","Allow Checklist's background service in System Settings → General → Login Items & Extensions, then retry.") }
            UserDefaults.standard.set(build,forKey:"registeredServiceBuild")
            registrationChecked=true
        }
    }

    public func startService(timeLimit: TimeInterval = 8) throws {
        if ChecklistInstance.current.slot != nil { throw ChecklistError("SERVICE_UNAVAILABLE", ChecklistInstance.current.startInstruction) }
        try ChecklistPaths.prepare()
        // Launchd owns singleton startup and Mach rights; opening XPC starts infrastructure only.
        let deadline = ProcessInfo.processInfo.systemUptime + min(8, timeLimit)
        while ProcessInfo.processInfo.systemUptime < deadline {
            let probe = try JSONSerialization.data(withJSONObject:["method":"service_info","params":[:],"installation":"startup"])
            let left = deadline - ProcessInfo.processInfo.systemUptime
            if (try? transport.request(probe, replyTimeout: min(1, max(0, left)))) != nil { return }
            let pause = min(0.08, deadline - ProcessInfo.processInfo.systemUptime)
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        }
        throw ChecklistError("SERVICE_UNAVAILABLE", "The registered Mach service did not respond. Check Checklist background service status; no second store was created.")
    }
}
