import Foundation
import Darwin

public enum NativeBridgeError: LocalizedError {
    case invalid(String)
    case system(String, Int32)
    case timedOut
    case outcomeUnknown(String)
    public var deliveryMayHaveOccurred: Bool {
        if case .outcomeUnknown = self { return true }
        return false
    }
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .system(let operation, let code): return "\(operation): \(String(cString: strerror(code)))"
        case .timedOut: return "Native socket deadline elapsed; recipient acknowledgment is unknown."
        case .outcomeUnknown(let reason): return "DELIVERY_UNCERTAIN: \(reason) Reconcile the original delivery before any explicit retry."
        }
    }
}

/// Actual sender permission class, not a desired recipient mode. The service must
/// obtain this from its paired host context; task content cannot set it.
public enum ClaudePermissionClass: String, Codable, Sendable { case bypass, prompting }

public struct ClaudePeerSender: Sendable {
    public let replyAddress: String
    public let displayName: String
    public let permissionClass: ClaudePermissionClass
    public init(replyAddress: String, displayName: String, permissionClass: ClaudePermissionClass) {
        self.replyAddress = replyAddress; self.displayName = displayName; self.permissionClass = permissionClass
    }
}

public struct NativeWriteReceipt: Codable, Sendable {
    public let status: String
    public let byteCount: Int
    public let socketDevice: UInt64
    public let socketInode: UInt64
    public let peerPID: Int32
    public let recordedAt: Date
}

public struct NativeReplyFrame: Sendable {
    public let data: Data
    /// Zero means the sender closed before Darwin could expose a peer PID.
    /// Never substitute a PID/name asserted in message text for this value.
    public let peerPID: Int32
    public let peerUID: UInt32
}

/// A narrow, same-user local transport. It does not discover sessions, enroll a
/// route, change permissions, retry, interpret replies or launch a model.
public enum ClaudeLocalBridge {
    public static let maximumFrameBytes = 256 * 1024
    public static let maximumContentUTF8Bytes = 128 * 1024

    public static func envelope(content: String, messageID: String, sender: ClaudePeerSender) throws -> Data {
        guard !content.isEmpty,content.utf8.count <= maximumContentUTF8Bytes else { throw NativeBridgeError.invalid("Message content is empty or exceeds the 128 KiB Checklist content cap.") }
        guard NativeRelayText.validMessageID(messageID)
        else { throw NativeBridgeError.invalid("Invalid stable message identifier.") }
        guard NativeRelayText.validReplyAddress(sender.replyAddress)
        else { throw NativeBridgeError.invalid("Reply address must be a canonical explicit local uds address.") }
        let name = NativeRelayText.bounded(sender.displayName,maximumUTF8Bytes:NativeRelayContent.maximumDisplayNameUTF8Bytes,allowLineBreaks:false)
        let displayName = String(name.text.prefix(NativeRelayContent.maximumDisplayNameCharacters))
        let safeContent = NativeRelayText.bounded(content,maximumUTF8Bytes:maximumContentUTF8Bytes,allowLineBreaks:true).text
        guard !displayName.isEmpty,!safeContent.isEmpty else { throw NativeBridgeError.invalid("Message content and sender display name must contain visible text.") }
        let wrapped = "<cross-session-message from=\"\(sender.replyAddress)\" from-name=\"\(NativeRelayText.escaped(displayName))\" from-mode=\"\(sender.permissionClass.rawValue)\">\n\(NativeRelayText.escaped(safeContent))\n</cross-session-message>"
        let object: [String: Any] = [
            "type": "user", "from": sender.replyAddress,
            "msg_id": messageID, "uuid": UUID().uuidString.lowercased(), "priority": "next",
            "message": ["role": "user", "content": wrapped]
        ]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        guard data.count <= maximumFrameBytes else { throw NativeBridgeError.invalid("Native message exceeds the 256 KiB Checklist transport cap.") }
        return data
    }

    public static func send(content: String, messageID: String, sender: ClaudePeerSender,
                            endpoint: String, expectedPeerPID: Int32? = nil,
                            expectedRegistration: NativeLifecycleRegistration? = nil,
                            timeout: TimeInterval = 5) throws -> NativeWriteReceipt {
        let frame = try envelope(content: content, messageID: messageID, sender: sender)
        let before = try checkedSocket(endpoint)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NativeBridgeError.system("socket", errno) }
        defer { Darwin.close(descriptor) }
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw NativeBridgeError.system("fcntl", errno) }
        var address = try socketAddress(endpoint)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        let deadline = Date().addingTimeInterval(min(max(timeout, 0.05), 10))
        if result != 0 {
            guard errno == EINPROGRESS else { throw NativeBridgeError.system("connect", errno) }
            try waitFor(descriptor, events: Int16(POLLOUT), deadline: deadline)
            var failure: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length) == 0 else { throw NativeBridgeError.system("getsockopt", errno) }
            guard failure == 0 else { throw NativeBridgeError.system("connect", failure) }
        }
        try checkPeer(descriptor)
        let connectedPID = try peerProcessID(descriptor)
        if let expectedPeerPID, connectedPID != expectedPeerPID {
            throw NativeBridgeError.invalid("RECIPIENT_CHANGED: native socket process does not match the explicitly enrolled recipient.")
        }
        let after = try checkedSocket(endpoint)
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino else { throw NativeBridgeError.invalid("RECIPIENT_CHANGED: enrolled socket changed during connection.") }
        if let expectedRegistration {
            let current = NativeLifecycleInspector.inspect(expectedRegistration)
            guard connectedPID == expectedRegistration.processID,
                  current.process == .running, current.registry == .matching else {
                throw NativeBridgeError.invalid("RECIPIENT_CHANGED: connected peer no longer matches the exact native process and conversation registry.")
            }
        }
        var sent = 0
        do { try frame.withUnsafeBytes { bytes in
            while sent < bytes.count {
                try waitFor(descriptor, events: Int16(POLLOUT), deadline: deadline)
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

/// Claude's own notice about an inbound peer message. Claude writes it to the
/// sender's `from` socket on a new connection, not on the write connection.
/// Observed on engine 2.1.299: `held`, with `orig_msg_id` echoing the sender's UUID
/// `msg_id` and `msg_id` naming the notice itself. Other status words are unqualified.
public struct ClaudePeerMessageStatus: Equatable, Sendable {
    public let status: String
    /// The delivery record state: held, refused or expired.
    public let deliveryState: String
    /// The sender's message ID as echoed by Claude; the only correlation key.
    public let originalMessageID: String?
    /// The notice's own ID. It never names the sender's message.
    public let noticeID: String?
    public let protocolVersion: Int?
    public let reason: String?

    public static func parse(_ object: [String: Any]) -> ClaudePeerMessageStatus? {
        guard object["type"] as? String == "control", object["action"] as? String == "peer_message_status",
              let status = object["status"] as? String,
              let state = ["held": "held", "refused": "refused", "expired": "expired"][status] else { return nil }
        return ClaudePeerMessageStatus(status: status, deliveryState: state,
                                       originalMessageID: (object["orig_msg_id"] as? String).map { String($0.prefix(128)) },
                                       noticeID: (object["msg_id"] as? String).map { String($0.prefix(128)) },
                                       protocolVersion: (object["msgV"] as? NSNumber)?.intValue,
                                       reason: (object["reason"] as? String).map { String($0.prefix(300)) })
    }

    /// True only when the kernel-reported notifier is the recipient process and Claude echoed
    /// this exact message ID. There is no fallback: an absent or different ID stays uncorrelated.
    public func refers(to messageID: String, recipientPID: Int32, notifierPID: Int32) -> Bool {
        notifierPID > 0 && notifierPID == recipientPID && originalMessageID == messageID
    }
}

/// Chooses which recipient a native reply came from. Only kernel peer identity selects it;
/// message text, display names and delivery order never do.
public enum NativeReplyRouting {
    /// The PID in a Claude socket name, `/tmp/cc-socks/<pid>.sock`.
    public static func endpointPID(_ endpoint: String) -> Int32? {
        Int32(URL(fileURLWithPath: endpoint).deletingPathExtension().lastPathComponent).flatMap { $0 > 0 ? $0 : nil }
    }

    /// The correlated message ID and reply text of a `CHECKLIST_REPLY <uuid>:` frame. Claude wraps
    /// peer text in `<cross-session-message …>…</cross-session-message>`; only the reply text is kept.
    public static func reply(in content: String) -> (messageID: String, body: String)? {
        guard let range = content.range(of: "CHECKLIST_REPLY [a-fA-F0-9-]{36}:", options: .regularExpression) else { return nil }
        let messageID = String(content[range].dropFirst("CHECKLIST_REPLY ".count).dropLast())
        var body = Substring(content[range.upperBound...])
        if let close = body.range(of: "</cross-session-message>", options: .backwards) { body = body[..<close.lowerBound] }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (messageID, text)
    }

    /// The one recipient session whose enrolled socket belongs to the reply's kernel peer, or nil
    /// when no route or more than one session matches.
    public static func recipient(peerPID: Int32, routes: [(sessionID: String, endpoint: String)]) -> String? {
        guard peerPID > 0 else { return nil }
        let sessions = Set(routes.filter { endpointPID($0.endpoint) == peerPID }.map(\.sessionID))
        return sessions.count == 1 ? sessions.first : nil
    }
}

/// A bounded same-user receipt listener. Frames are untrusted native input. The
/// caller correlates message/recipient IDs and records actual evidence; a body
/// containing a nonce is not automatically an acknowledgment.
public final class NativeReplyListener: @unchecked Sendable {
    public let path: String
    private var descriptor: Int32
    private let createdDevice: dev_t
    private let createdInode: ino_t
    public var address: String { "uds:" + path }

    public init(path: String) throws {
        self.path = path
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var attributes = stat()
        guard lstat(directory, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR,
              attributes.st_uid == getuid(), attributes.st_mode & 0o022 == 0
        else { throw NativeBridgeError.invalid("Reply directory must be an existing same-user directory without group/world write access.") }
        guard lstat(path, &attributes) != 0, errno == ENOENT else { throw NativeBridgeError.invalid("Refusing to replace an existing reply path.") }
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw NativeBridgeError.system("socket", errno) }
        do {
            var address = try socketAddress(path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { throw NativeBridgeError.system("bind", errno) }
            guard chmod(path, 0o600) == 0, listen(socketFD, 8) == 0 else { throw NativeBridgeError.system("listen", errno) }
            let created = try checkedSocket(path)
            createdDevice = created.st_dev; createdInode = created.st_ino
            descriptor = socketFD
        } catch {
            Darwin.close(socketFD)
            throw error
        }
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
        var current = stat()
        if lstat(path, &current) == 0, current.st_dev == createdDevice, current.st_ino == createdInode { unlink(path) }
    }

    public func receive(timeout: TimeInterval = 5) throws -> Data {
        try receiveFrame(timeout: timeout).data
    }

    public func receiveFrame(timeout: TimeInterval = 5) throws -> NativeReplyFrame {
        let deadline = Date().addingTimeInterval(min(max(timeout, 0.05), 60))
        try waitFor(descriptor, events: Int16(POLLIN), deadline: deadline)
        let peer = accept(descriptor, nil, nil)
        guard peer >= 0 else { throw NativeBridgeError.system("accept", errno) }
        defer { Darwin.close(peer) }
        try checkPeer(peer)
        let peerPID = (try? peerProcessID(peer)) ?? 0
        var peerUID: uid_t = 0; var peerGID: gid_t = 0
        guard getpeereid(peer, &peerUID, &peerGID) == 0, peerUID == getuid() else {
            throw NativeBridgeError.invalid("Reply peer identity changed or is unavailable.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count < ClaudeLocalBridge.maximumFrameBytes {
            try waitFor(peer, events: Int16(POLLIN), deadline: deadline)
            let count = recv(peer, &buffer, buffer.count, 0)
            if count < 0 {
                if errno == EINTR { continue }
                throw NativeBridgeError.system("recv", errno)
            }
            guard count > 0 else { throw NativeBridgeError.invalid("Incomplete native reply frame.") }
            data.append(contentsOf: buffer.prefix(count))
            if let newline = data.firstIndex(of: 0x0A) {
                let frame = Data(data[..<newline])
                guard frame.count <= ClaudeLocalBridge.maximumFrameBytes else { throw NativeBridgeError.invalid("Native reply exceeded the 256 KiB frame cap.") }
                guard let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any], object["type"] as? String != "auth" else {
                    throw NativeBridgeError.invalid("Invalid receipt frame; authentication material is never retained as message evidence.")
                }
                return NativeReplyFrame(data: frame, peerPID: peerPID, peerUID: peerUID)
            }
        }
        throw NativeBridgeError.invalid("Native reply exceeded the 256 KiB frame cap.")
    }
}

private func socketAddress(_ path: String) throws -> sockaddr_un {
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

private func checkedSocket(_ path: String) throws -> stat {
    var attributes = stat()
    guard lstat(path, &attributes) == 0 else { throw NativeBridgeError.system("lstat socket", errno) }
    guard attributes.st_mode & S_IFMT == S_IFSOCK, attributes.st_uid == getuid(), attributes.st_mode & 0o077 == 0 else {
        throw NativeBridgeError.invalid("Endpoint must be a same-user private Unix socket, with no symlink or group/world access.")
    }
    return attributes
}

private func checkPeer(_ descriptor: Int32) throws {
    var uid: uid_t = 0; var gid: gid_t = 0
    guard getpeereid(descriptor, &uid, &gid) == 0 else { throw NativeBridgeError.system("getpeereid", errno) }
    guard uid == getuid() else { throw NativeBridgeError.invalid("Native peer belongs to another user.") }
}

private func peerProcessID(_ descriptor: Int32) throws -> Int32 {
    var pid: pid_t = 0
    var length = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else {
        throw NativeBridgeError.system("LOCAL_PEERPID", errno)
    }
    return pid
}

private func waitFor(_ descriptor: Int32, events: Int16, deadline: Date) throws {
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
