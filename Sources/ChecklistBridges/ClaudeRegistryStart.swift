import Foundation
import ChecklistIPC

/// A spare Claude process can receive its registry after its MCP child starts.
/// This state permits only a bounded startup wait and one attempt per MCP request.
public struct ClaudeRegistryStart {
    public static let errorCode = "NATIVE_SESSION_MISMATCH"
    public static let registryMessage = "Claude's current session registry does not match this native process and workspace."
    public static let waitLimit: TimeInterval = 10
    public static let startupLimit: TimeInterval = 20
    public static let retryInterval: TimeInterval = 0.25
    public static let limitedToolNames = ["service_info"]

    public private(set) var error: Error?
    public private(set) var mayRetry = false
    public private(set) var attemptCount = 0
    public private(set) var firstReason: ClaudeRegistryReason?
    public private(set) var lastReason: ClaudeRegistryReason?
    private var startedAt: TimeInterval = 0
    private var elapsed: TimeInterval = 0
    private var reasonChanged = false
    private var hasRecoverySummary = false

    public init() {}

    public static func applies(error: Error, provider: String?, assistantRelay: Bool) -> Bool {
        guard provider == "claude", !assistantRelay, let error = error as? ChecklistError else { return false }
        return error.code == errorCode && error.message == registryMessage
    }

    public var notice: String? {
        error.map { "This conversation is not connected yet. " + $0.localizedDescription }
    }

    public var startupNotice: String? {
        guard let notice, let lastReason else { return notice }
        return notice + " Startup wait ended after \(attemptCount) attempts in \(elapsedMilliseconds) ms; last reason: \(lastReason.rawValue)."
    }

    private var elapsedMilliseconds: Int { Int((elapsed * 1000).rounded()) }

    public mutating func takeRecoverySummary() -> String? {
        guard hasRecoverySummary, let firstReason else { return nil }
        hasRecoverySummary = false
        var summary = "connected after \(attemptCount) attempts in \(elapsedMilliseconds) ms; Claude's session registry was not ready at first (\(firstReason.rawValue))."
        if reasonChanged, let lastReason { summary += " Last reason: \(lastReason.rawValue)." }
        return summary
    }

    public var connection: [String: Any]? {
        guard let notice else { return nil }
        return ["connected": false, "state": mayRetry ? "claude_registry_not_ready" : "connection_failed", "message": notice]
    }

    public mutating func start<Result>(command: String, assistantRelay: Bool,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        discover: () -> NativeSessionDiscovery,
        bootstrap: (NativeSessionContext?, TimeInterval?) throws -> Result?) throws -> Result? {
        startedAt = now(); elapsed = 0; attemptCount = 0
        firstReason = nil; lastReason = nil; reasonChanged = false; hasRecoverySummary = false
        let deadline = startedAt + Self.waitLimit
        while true {
            if attemptCount > 0, let error {
                elapsed = max(0, now() - startedAt)
                guard elapsed < Self.waitLimit else {
                    if command == "mcp" { return nil }
                    throw error
                }
            }
            let discovery = discover()
            var timeBudget: TimeInterval?
            if attemptCount > 0, let error {
                elapsed = max(0, now() - startedAt)
                guard elapsed < Self.waitLimit else {
                    if command == "mcp" { return nil }
                    throw error
                }
                timeBudget = min(15, Self.startupLimit - elapsed)
            }
            do { return try attempt(assistantRelay: assistantRelay, timeBudget: timeBudget, now: now, discovery: discovery, bootstrap: bootstrap) }
            catch {
                guard mayRetry, ["mcp", "tools", "call", "connect"].contains(command) else { throw error }
                let remaining = deadline - now()
                guard remaining > 0 else {
                    if command == "mcp" { return nil }
                    throw error
                }
                sleep(min(Self.retryInterval, remaining))
            }
        }
    }

    /// True means this request acquired a connection. Later requests return false.
    /// A permanent failure retains its text and ends further attempts.
    public mutating func retry<Result>(now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        discover: () -> NativeSessionDiscovery,
        bootstrap: (NativeSessionContext?) throws -> Result?) -> Bool {
        guard mayRetry else { return false }
        do { return try attempt(assistantRelay: false, timeBudget: nil, now: now, discovery: discover(),
                               bootstrap: { context, _ in try bootstrap(context) }) != nil }
        catch { return false }
    }

    private mutating func attempt<Result>(assistantRelay: Bool, timeBudget: TimeInterval?, now: () -> TimeInterval, discovery: NativeSessionDiscovery,
        bootstrap: (NativeSessionContext?, TimeInterval?) throws -> Result?) throws -> Result? {
        attemptCount += 1
        do {
            if discovery.registryReason != nil, !assistantRelay {
                throw ChecklistError(Self.errorCode, Self.registryMessage)
            }
            // Loss of native context must not select a stored connection.
            if discovery.context == nil, let error { throw error }
            let remainingBudget = timeBudget.map { min($0, max(0, Self.startupLimit - (now() - startedAt))) }
            let result = try bootstrap(discovery.context, remainingBudget)
            elapsed = max(0, now() - startedAt)
            hasRecoverySummary = result != nil && firstReason != nil
            error = nil; mayRetry = false
            return result
        } catch {
            self.error = error
            let provider = discovery.registryReason != nil ? "claude" : discovery.context?.provider
            mayRetry = Self.applies(error: error, provider: provider, assistantRelay: assistantRelay)
            elapsed = max(0, now() - startedAt)
            if mayRetry {
                let reason = discovery.registryReason ?? .serviceMismatch
                if firstReason == nil { firstReason = reason }
                if let lastReason, lastReason != reason { reasonChanged = true }
                lastReason = reason
            }
            throw error
        }
    }
}
