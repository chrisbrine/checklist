import Foundation
import ChecklistProviders
import Darwin

/// Native socket effects require an explicit platform implementation. This
/// boundary conveys authenticated expectations; it does not enroll a recipient,
/// authorize a message, retry a write, or substitute another runtime.
public protocol NativePeerTransportEffects {
    func send(content: String, messageID: String, sender: ClaudePeerSender,
              endpoint: String, expectedPeerPID: Int32?,
              expectedRegistration: NativeLifecycleRegistration?,
              timeout: TimeInterval, providerRegistry: ProviderPluginRegistry) throws -> NativeWriteReceipt
}

/// The macOS implementation retains the private-socket, kernel-peer, exact
/// process/registry and partial-write uncertainty checks of the native transport.
public struct MacOSNativePeerTransportEffects: NativePeerTransportEffects {
    public init() {}

    public func send(content: String, messageID: String, sender: ClaudePeerSender,
                     endpoint: String, expectedPeerPID: Int32?,
                     expectedRegistration: NativeLifecycleRegistration?,
                     timeout: TimeInterval, providerRegistry: ProviderPluginRegistry) throws -> NativeWriteReceipt {
        let frame = try ClaudeLocalBridge.envelope(content: content, messageID: messageID, sender: sender)
        let before = try NativeSocketIO.checkedSocket(endpoint)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NativeBridgeError.system("socket", errno) }
        defer { Darwin.close(descriptor) }
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw NativeBridgeError.system("fcntl", errno) }
        var address = try NativeSocketIO.socketAddress(endpoint)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        let deadline = Date().addingTimeInterval(min(max(timeout, 0.05), 10))
        if result != 0 {
            guard errno == EINPROGRESS else { throw NativeBridgeError.system("connect", errno) }
            try NativeSocketIO.waitFor(descriptor, events: Int16(POLLOUT), deadline: deadline)
            var failure: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length) == 0 else { throw NativeBridgeError.system("getsockopt", errno) }
            guard failure == 0 else { throw NativeBridgeError.system("connect", failure) }
        }
        try NativeSocketIO.checkPeer(descriptor)
        let connectedPID = try NativeSocketIO.peerProcessID(descriptor)
        if let expectedPeerPID, connectedPID != expectedPeerPID {
            throw NativeBridgeError.invalid("RECIPIENT_CHANGED: native socket process does not match the explicitly enrolled recipient.")
        }
        let after = try NativeSocketIO.checkedSocket(endpoint)
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino else { throw NativeBridgeError.invalid("RECIPIENT_CHANGED: enrolled socket changed during connection.") }
        if let expectedRegistration {
            let current = NativeLifecycleInspector.inspect(expectedRegistration, providerRegistry:providerRegistry)
            guard connectedPID == expectedRegistration.processID,
                  current.process == .running, current.registry == .matching else {
                throw NativeBridgeError.invalid("RECIPIENT_CHANGED: connected peer no longer matches the exact native process and conversation registry.")
            }
        }
        var sent = 0
        do { try frame.withUnsafeBytes { bytes in
            while sent < bytes.count {
                try NativeSocketIO.waitFor(descriptor, events: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw NativeBridgeError.system("send", errno)
                }
                guard count > 0 else { throw NativeBridgeError.invalid("Socket closed before complete message write; delivery is uncertain.") }
                sent += count
            }
        } } catch {
            if sent > 0 { throw NativeBridgeError.outcomeUnknown(error.localizedDescription) }
            throw error
        }
        // Completing a write proves neither provider acceptance nor model consumption.
        return NativeWriteReceipt(status: "transport_written", byteCount: frame.count,
                                  socketDevice: UInt64(after.st_dev), socketInode: UInt64(after.st_ino), peerPID: connectedPID, recordedAt: Date())
    }
}

/// Unsupported platforms fail closed. An unavailable native capability never
/// falls back to CLI/model execution or changes permissions/enrollment.
public struct UnsupportedNativePeerTransportEffects: NativePeerTransportEffects {
    public init() {}

    public func send(content: String, messageID: String, sender: ClaudePeerSender,
                     endpoint: String, expectedPeerPID: Int32?,
                     expectedRegistration: NativeLifecycleRegistration?,
                     timeout: TimeInterval, providerRegistry: ProviderPluginRegistry) throws -> NativeWriteReceipt {
        throw NativeBridgeError.invalid("ADAPTER_UNAVAILABLE: Native peer transport is unavailable on this platform.")
    }
}

/// Platform selection stays within Bridges; shared modules receive no authority.
public enum NativePeerTransportAdapters {
    public static var current: any NativePeerTransportEffects {
        #if os(macOS)
        MacOSNativePeerTransportEffects()
        #else
        UnsupportedNativePeerTransportEffects()
        #endif
    }
}

/// Shared only by the macOS sender and bounded reply listener in this module.
/// None of these helpers are a public authority or capability API.
enum NativeSocketIO {
    static func socketAddress(_ path: String) throws -> sockaddr_un {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw NativeBridgeError.invalid("Socket path must be absolute and contain no NUL.") }
        return try unixAddress(path)
    }

    /// An address with one file name, for a `bind` or a `connect` that a folder descriptor resolves.
    static func fileNameSocketAddress(_ name: String) throws -> sockaddr_un {
        guard !name.isEmpty, !name.utf8.contains(0), !name.contains("/") else { throw NativeBridgeError.invalid("Socket name must be one file name.") }
        return try unixAddress(name)
    }

    private static func unixAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8) + [UInt8(0)]
        guard bytes.count <= capacity else { throw NativeBridgeError.invalid("Unix socket path is too long.") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
        return address
    }

    static func checkedSocket(_ path: String) throws -> stat {
        var attributes = stat()
        guard lstat(path, &attributes) == 0 else { throw NativeBridgeError.system("lstat socket", errno) }
        guard attributes.st_mode & S_IFMT == S_IFSOCK, attributes.st_uid == getuid(), attributes.st_mode & 0o077 == 0 else {
            throw NativeBridgeError.invalid("Endpoint must be a same-user private Unix socket, with no symlink or group/world access.")
        }
        return attributes
    }

    static func checkPeer(_ descriptor: Int32) throws {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0 else { throw NativeBridgeError.system("getpeereid", errno) }
        guard uid == getuid() else { throw NativeBridgeError.invalid("Native peer belongs to another user.") }
    }

    static func peerProcessID(_ descriptor: Int32) throws -> Int32 {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else {
            throw NativeBridgeError.system("LOCAL_PEERPID", errno)
        }
        return pid
    }

    static func waitFor(_ descriptor: Int32, events: Int16, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw NativeBridgeError.timedOut }
            var descriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up)))
            if result < 0 { if errno == EINTR { continue }; throw NativeBridgeError.system("poll", errno) }
            guard result != 0 else { throw NativeBridgeError.timedOut }
            guard descriptor.revents & (Int16(POLLERR) | Int16(POLLNVAL)) == 0 else { throw NativeBridgeError.invalid("Native socket became unavailable.") }
            if descriptor.revents & events != 0 { return }
            if descriptor.revents & Int16(POLLHUP) != 0 { throw NativeBridgeError.invalid("Native socket closed.") }
        }
    }
}

/// Exit success records queue-command acceptance only. It does not prove that
/// the thread received the note, started a turn, read it or acknowledged it.
public struct CodexQueueReceipt: Equatable, Sendable {
    public let exitStatus: Int32
    public let byteCount: Int
    public let itemID: String?
    public init(exitStatus: Int32, byteCount: Int, itemID: String? = nil) {
        self.exitStatus = exitStatus; self.byteCount = byteCount; self.itemID = itemID
    }
}

public protocol CodexQueueTransportEffects {
    func queue(content: String, registration: NativeLifecycleRegistration, timeout: TimeInterval) throws -> CodexQueueReceipt
}

/// One bounded invocation of the running app host's own executable. An idle thread
/// cannot register again after an app restart, so the registered PID does not select it.
/// No shell, model start, remote endpoint, retry or caller-selected executable is used.
/// The preflight checked this path's signature. A file swapped in after that check is not seen.
public struct MacOSCodexQueueTransportEffects: CodexQueueTransportEffects {
    let executable: String
    public init(executable: String) { self.executable = executable }
    public func queue(content: String, registration: NativeLifecycleRegistration, timeout: TimeInterval) throws -> CodexQueueReceipt {
        guard registration.provider == "codex",URL(fileURLWithPath:executable).lastPathComponent == "codex" else {
            throw NativeBridgeError.invalid("CODEX_QUEUE_EXECUTABLE_UNPROVEN: the app host is not the Codex executable.")
        }
        guard UUID(uuidString:registration.sessionID) != nil else {
            throw NativeBridgeError.invalid("CODEX_QUEUE_THREAD_INVALID: registered thread is not a UUID.")
        }
        let environment = try CodexCommandEnvironment.current()
        let result = try BoundedCodexCommand.run(executable:executable,
            arguments:["queue","--thread",registration.sessionID,"--message",content],
            environment:environment,timeout:timeout,captureOutput:true)
        guard result.exitedNormally, result.exitStatus == 0 else {
            // A failed process can have committed its queue write before failure.
            throw NativeBridgeError.outcomeUnknown("Codex queue ended without a successful exit (status \(result.exitStatus)).")
        }
        // Codex 0.159.0 prints this receipt on stdout. Invalid/truncated output
        // cannot identify the item, but does not undo successful queue acceptance.
        let itemID = result.outputOverflow ? nil : CodexQueueOutput.itemID(result.output,threadID:registration.sessionID)
        return CodexQueueReceipt(exitStatus:0,byteCount:content.utf8.count,itemID:itemID)
    }
}

public protocol CodexThreadOpenEffects {
    func open(threadID: String, timeout: TimeInterval) throws -> Int32
}

/// The relay authorizes this effect only after an accepted queue item remains.
/// An argument array and a canonical UUID prevent URL/command injection.
public struct MacOSCodexThreadOpenEffects: CodexThreadOpenEffects {
    public init() {}
    public func open(threadID: String, timeout: TimeInterval) throws -> Int32 {
        let arguments = try Self.arguments(threadID:threadID)
        let result = try BoundedCodexCommand.run(executable:"/usr/bin/open",arguments:arguments,
            environment:try CodexCommandEnvironment.current(),timeout:timeout,captureOutput:false)
        guard result.exitedNormally else {
            throw NativeBridgeError.outcomeUnknown("Codex thread open terminated without a normal exit.")
        }
        return result.exitStatus
    }

    static func arguments(threadID: String) throws -> [String] {
        guard let uuid = UUID(uuidString:threadID) else {
            throw NativeBridgeError.invalid("CODEX_OPEN_THREAD_INVALID: thread is not a UUID.")
        }
        return ["-g","codex://threads/"+uuid.uuidString.lowercased()]
    }
}

enum CodexQueueOutput {
    static func itemID(_ output: Data, threadID: String) -> String? {
        guard let expected = UUID(uuidString:threadID),
              var line = String(data:output,encoding:.utf8) else { return nil }
        if line.hasSuffix("\n") { line.removeLast() }
        guard !line.contains("\n"), !line.contains("\r"),
              line.hasPrefix("Queued message "), line.hasSuffix(".") else { return nil }
        let content = line.dropFirst("Queued message ".count).dropLast()
        let parts = content.components(separatedBy:" for thread ")
        guard parts.count == 2, UUID(uuidString:parts[1]) == expected,
              !parts[0].isEmpty, parts[0].utf8.count <= 160,
              parts[0].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return parts[0]
    }
}

/// Derive the same on-disk home as the production observer from the OS account,
/// never from a caller's HOME or CODEX_HOME override.
enum CodexCommandEnvironment {
    static func current() throws -> [String:String] {
        var account = passwd()
        var found: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating:0,count:16_384)
        let capacity = buffer.count
        let status = getpwuid_r(getuid(),&account,&buffer,capacity,&found)
        guard status == 0, found != nil, let directory = account.pw_dir else {
            throw NativeBridgeError.invalid("CODEX_HOME_UNAVAILABLE: OS account home cannot be resolved.")
        }
        return try pinned(ProcessInfo.processInfo.environment,home:String(cString:directory))
    }

    static func pinned(_ environment: [String:String], home: String) throws -> [String:String] {
        guard home.hasPrefix("/"), !home.utf8.contains(0) else {
            throw NativeBridgeError.invalid("CODEX_HOME_UNAVAILABLE: OS account home is invalid.")
        }
        var result = environment
        result["HOME"] = home
        result["CODEX_HOME"] = URL(fileURLWithPath:home).appendingPathComponent(".codex").path
        return result
    }
}

/// Drain without waiting for EOF: a descendant may retain stdout after its
/// parent exits. Output is bounded even if the child writes continuously.
enum BoundedCodexCommand {
    struct Result {
        let exitStatus: Int32
        let exitedNormally: Bool
        let output: Data
        let outputOverflow: Bool
    }

    static func run(executable: String, arguments: [String], environment: [String:String],
                    timeout: TimeInterval, captureOutput: Bool) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath:executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = captureOutput ? output.fileHandleForWriting : FileHandle.nullDevice
        defer { try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close() }
        if captureOutput {
            let descriptor = output.fileHandleForReading.fileDescriptor
            guard fcntl(descriptor,F_SETFL,O_NONBLOCK) == 0 else { throw NativeBridgeError.system("fcntl queue output",errno) }
        }
        let finished = DispatchSemaphore(value:0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if captureOutput { try? output.fileHandleForWriting.close() }
        let deadline = ProcessInfo.processInfo.systemUptime + min(max(timeout,0.05),5)
        var bytes = Data()
        var overflow = false
        func drain() {
            guard captureOutput else { return }
            var chunk = [UInt8](repeating:0,count:4096)
            for _ in 0..<16 {
                let capacity = chunk.count
                let count = Darwin.read(output.fileHandleForReading.fileDescriptor,&chunk,capacity)
                guard count > 0 else { break }
                let room = max(0,4096-bytes.count)
                bytes.append(contentsOf:chunk.prefix(min(room,count)))
                if count > room { overflow = true }
            }
        }
        while true {
            drain()
            if finished.wait(timeout:.now()) == .success { break }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                if process.isRunning { process.terminate() }
                if finished.wait(timeout:.now()+0.1) != .success, process.isRunning {
                    _ = kill(process.processIdentifier,SIGKILL)
                }
                throw NativeBridgeError.outcomeUnknown("Codex command exceeded its bounded deadline; its effect may already have occurred.")
            }
            if finished.wait(timeout:.now()+min(remaining,0.01)) == .success { break }
        }
        drain()
        return Result(exitStatus:process.terminationStatus,exitedNormally:process.terminationReason == .exit,
                      output:bytes,outputOverflow:overflow)
    }
}
