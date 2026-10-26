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
