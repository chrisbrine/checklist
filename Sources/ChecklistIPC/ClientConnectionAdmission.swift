import Foundation
import Darwin
import Security

/// Kernel facts about a peer's executable file and running code. Reading them opens no file
/// and reads no code signature, so a repeat client is admitted without disk reads.
public struct ClientExecutableKey: Hashable, Sendable {
    public let path: String
    public let device: UInt64
    public let inode: UInt64
    public let modified: [Int]
    public let size: Int64
    public let kernelCDHash: Data?

    public init(path: String, device: UInt64, inode: UInt64, modified: [Int], size: Int64, kernelCDHash: Data?) {
        self.path = path; self.device = device; self.inode = inode; self.modified = modified; self.size = size; self.kernelCDHash = kernelCDHash
    }

    private typealias CodeSigningOps = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
    private nonisolated(unsafe) static let codeSigningOps: CodeSigningOps? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops").map { unsafeBitCast($0, to: CodeSigningOps.self) }

    /// Kernel path (`proc_pidpath`), file metadata (`stat`) and the kernel's cdhash (`csops`).
    public static func process(_ pid: pid_t) -> ClientExecutableKey? {
        var bytes = [CChar](repeating: 0, count: 4096)
        guard pid > 0, proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        let path = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        var hash = [UInt8](repeating: 0, count: 20)
        let kernel = codeSigningOps?(pid, 5 /* CS_OPS_CDHASH */, &hash, hash.count) == 0 ? Data(hash) : nil
        return .init(path: path, device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino),
                     modified: [Int(info.st_mtimespec.tv_sec), Int(info.st_mtimespec.tv_nsec), Int(info.st_ctimespec.tv_sec), Int(info.st_ctimespec.tv_nsec)],
                     size: Int64(info.st_size), kernelCDHash: kernel)
    }
}

/// Connection boundary stamps; exported only on an explicitly timed request.
public struct ClientAdmissionTiming: Sendable {
    public let listenerUptime: TimeInterval
    public let identityStartedUptime: TimeInterval
    public let identityFinishedUptime: TimeInterval
    public let admittedUptime: TimeInterval
    public let cacheHit: Bool

    public var fields: [String: Any] {
        ["listener_uptime_s": listenerUptime, "identity_started_uptime_s": identityStartedUptime,
         "identity_finished_uptime_s": identityFinishedUptime, "admitted_uptime_s": admittedUptime, "cache_hit": cacheHit]
    }
}

/// A PID check selects the peer. XPC still checks the exact hash on every command message.
/// The signature of each executable is read once; later clients of the same unchanged
/// executable reuse that identity. A first read runs off the listener's serial queue.
public struct ClientConnectionAdmission {
    public let requirement: String?
    public let currentHashes: Set<Data>
    private let identifiers: Set<String>
    private let identitySource: (NSXPCConnection) -> ClientBuildIdentity?
    private let keySource: (NSXPCConnection) -> ClientExecutableKey?
    private let cache = IdentityCache()
    private static let checks = DispatchQueue(label: "org.checklist.client-admission", qos: .userInitiated, attributes: .concurrent)

    public init(currentClients: [ClientBuildIdentity], checklistIdentifiers: Set<String>,
                identitySource: @escaping (NSXPCConnection) -> ClientBuildIdentity? = Self.processIdentity,
                keySource: @escaping (NSXPCConnection) -> ClientExecutableKey? = { ClientExecutableKey.process($0.processIdentifier) }) {
        currentHashes = Set(currentClients.map(\.cdhash))
        identifiers = checklistIdentifiers
        self.identitySource = identitySource
        self.keySource = keySource
        let text = currentClients.map { "cdhash H\"" + $0.cdhash.map { String(format: "%02x", $0) }.joined() + "\"" }.joined(separator: " or ")
        var parsed: SecRequirement?
        requirement = !currentClients.isEmpty && currentClients.allSatisfy { !$0.cdhash.isEmpty }
            && SecRequirementCreateWithString(text as CFString, [], &parsed) == errSecSuccess ? text : nil
    }

    public static func processIdentity(_ connection: NSXPCConnection) -> ClientBuildIdentity? {
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else { return nil }
        return ClientBuildIdentity.running(guest)
    }

    /// A cached executable is classified at once. Otherwise the connection is held unresumed
    /// while a concurrent queue reads its signature; a refused peer is then invalidated.
    public func accept(_ connection: NSXPCConnection, peer: @escaping () -> any ChecklistRPC) -> Bool {
        accept(connection, timedPeer: { _ in peer() })
    }

    /// Admission precedes the request's diagnostic switch. Retain four monotonic
    /// stamps per connection, and expose them only on explicitly timed replies.
    public func accept(_ connection: NSXPCConnection, timedPeer: @escaping (ClientAdmissionTiming) -> any ChecklistRPC) -> Bool {
        let listener = ProcessInfo.processInfo.systemUptime
        guard requirement != nil else { return false }
        let key = keySource(connection)
        if let key, let identity = cache.identity(for: key) {
            let checked = ProcessInfo.processInfo.systemUptime
            return admit(connection, identity, listener: listener, started: listener, finished: checked, cacheHit: true, peer: timedPeer)
        }
        let check = Deferred { [self] in
            let started = ProcessInfo.processInfo.systemUptime
            let identity = identitySource(connection)
            let finished = ProcessInfo.processInfo.systemUptime
            // Cache only when the executable did not change during the read.
            if let key, let identity, keySource(connection) == key { cache.store(identity, for: key) }
            // A refused peer gets no exported object; resuming before invalidation tells
            // the client at once instead of leaving its first message unanswered.
            if !admit(connection, identity, listener: listener, started: started, finished: finished, cacheHit: false, peer: timedPeer) { connection.resume(); connection.invalidate() }
        }
        Self.checks.async { check.run() }
        return true
    }

    private func admit(_ connection: NSXPCConnection, _ identity: ClientBuildIdentity?, listener: TimeInterval, started: TimeInterval, finished: TimeInterval, cacheHit: Bool, peer: (ClientAdmissionTiming) -> any ChecklistRPC) -> Bool {
        switch ClientBuildAdmission.classify(identity, currentHashes: currentHashes, checklistIdentifiers: identifiers) {
        case .current:
            guard let requirement else { return false }
            connection.setCodeSigningRequirement(requirement)
            connection.exportedObject = peer(.init(listenerUptime: listener, identityStartedUptime: started,
                identityFinishedUptime: finished, admittedUptime: ProcessInfo.processInfo.systemUptime, cacheHit: cacheHit))
        case .outdated:
            connection.exportedObject = OutdatedClientPeer()
        case .refused:
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: ChecklistRPC.self)
        connection.resume()
        return true
    }

    private struct Deferred: @unchecked Sendable { let run: () -> Void }
}

/// Verified identities by executable key. A full cache is emptied rather than grown.
private final class IdentityCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ClientExecutableKey: ClientBuildIdentity] = [:]
    func identity(for key: ClientExecutableKey) -> ClientBuildIdentity? {
        lock.lock(); defer { lock.unlock() }; return entries[key]
    }
    func store(_ identity: ClientBuildIdentity, for key: ClientExecutableKey) {
        lock.lock(); defer { lock.unlock() }
        if entries.count >= 64 { entries.removeAll() }
        entries[key] = identity
    }
}
