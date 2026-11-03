import Foundation
import ChecklistProviders
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
                            timeout: TimeInterval = 5, providerRegistry: ProviderPluginRegistry = .bundled) throws -> NativeWriteReceipt {
        try NativePeerTransportAdapters.current.send(content: content, messageID: messageID, sender: sender,
            endpoint: endpoint, expectedPeerPID: expectedPeerPID, expectedRegistration: expectedRegistration,
            timeout: timeout, providerRegistry: providerRegistry)
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

/// A named step of a listener's start or stop. Only a test passes an observer, to swap a file at
/// that step. A product run has no observer.
enum NativeReplySocketStep: Sendable {
    case afterBind, beforeIdentityCapture, beforeStopCheck, beforePrivateMove, afterPrivateMove, beforeRemoval
}

/// Sets the calling thread's working folder, or returns it to the process folder with -1. libSystem
/// exports this symbol, and the SDK headers do not declare it. It is the route to a relative `bind`
/// and `connect`, because this SDK has no `bindat` or `connectat`. No other thread sees the change.
@_silgen_name("pthread_fchdir_np")
private func setThreadWorkingFolder(_ descriptor: Int32) -> Int32

/// What separates this file from every other file. The birth time stays the same across a rename.
private struct NativeReplyFileIdentity: Equatable {
    let device: dev_t, inode: ino_t, birthSeconds: Int, birthNanoseconds: Int
    init(_ attributes: stat) {
        device = attributes.st_dev; inode = attributes.st_ino
        birthSeconds = attributes.st_birthtimespec.tv_sec; birthNanoseconds = attributes.st_birthtimespec.tv_nsec
    }
}

/// The reply folder, opened once. Each file action names a file relative to this descriptor, so a
/// later change to the folder's path has no effect on which folder the listener uses.
private final class NativeReplyFolder: @unchecked Sendable {
    let descriptor: Int32

    init(path: String) throws {
        let invalid = NativeBridgeError.invalid("Reply directory must be an existing same-user directory without group/world write access.")
        let opened = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw invalid }
        var attributes = stat()
        guard fstat(opened, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR,
              attributes.st_uid == getuid(), attributes.st_mode & 0o022 == 0
        else { Darwin.close(opened); throw invalid }
        descriptor = opened
    }

    deinit { Darwin.close(descriptor) }

    func status(_ name: String) -> stat? {
        var attributes = stat()
        return fstatat(descriptor, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 ? attributes : nil
    }

    private func inFolder<Result>(_ body: () throws -> Result) throws -> Result {
        guard setThreadWorkingFolder(descriptor) == 0 else { throw NativeBridgeError.system("pthread_fchdir_np", errno) }
        defer { _ = setThreadWorkingFolder(-1) }
        return try body()
    }

    /// The umask is process-wide, and other queues can create files during this one `bind`. So the
    /// mask removes only group and other bits: a file or folder from another queue gets at most a
    /// narrower group and other mode, and its owner keeps every bit. No other service code sets the
    /// umask. The socket's mode is 0700, and the owner needs only the write bit to connect.
    func bindSocket(_ socket: Int32, name: String) throws {
        var address = try NativeSocketIO.fileNameSocketAddress(name)
        let (result, code): (Int32, Int32) = try inFolder {
            let earlier = umask(0o077)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            let code = errno
            umask(earlier)
            return (result, code)
        }
        guard result == 0 else { throw NativeBridgeError.system("bind", code) }
    }

    func connectSocket(_ socket: Int32, name: String) throws {
        var address = try NativeSocketIO.fileNameSocketAddress(name)
        let (result, code): (Int32, Int32) = try inFolder {
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            return (result, errno)
        }
        guard result == 0 else { throw NativeBridgeError.system("connect", code) }
    }
}

/// A bounded same-user receipt listener. Frames are untrusted native input. The
/// caller correlates message/recipient IDs and records actual evidence; a body
/// containing a nonce is not automatically an acknowledgment.
///
/// The rule: the listener removes a file only with proof that the file is the socket that it bound,
/// and any doubt leaves the file untouched. A file that already exists stays: a name cannot show that
/// a socket is dead, because a child can hold a listener after its creator exits, and Darwin refuses
/// a connection to a live listener with a full queue.
///
/// The proof, at start: the path has one identity before and after a connection that this process
/// makes through the path and then receives on this listener with a random value. A start with no
/// proof closes its socket, leaves the file and fails. No failure path removes a file.
///
/// The limit: a process of the same user can still defeat the proof if it puts this socket at the
/// path for only the moment of the self-connection, or it can change the private folder of a stop.
public final class NativeReplyListener: @unchecked Sendable {
    public let path: String
    private var descriptor: Int32
    private let folder: NativeReplyFolder
    private let name: String
    private let observer: (@Sendable (NativeReplySocketStep) -> Void)?
    private let identityLock = NSLock()
    /// A stop makes one attempt, so this is nil after it, and nil always means that no removal occurs.
    private var provedIdentity: NativeReplyFileIdentity?
    public var address: String { "uds:" + path }
    /// False when a file already held `<pid>.sock`, so the listener bound a fallback name.
    public var hasProcessIDName: Bool { URL(fileURLWithPath: path).lastPathComponent == "\(getpid()).sock" }

    static let fallbackNameTries = 8
    static let selfConnectionSeconds: TimeInterval = 2

    /// Binds `<pid>.sock` in the folder, or `<pid>-<8 hex>.sock` if any file exists at that path.
    /// `bind` never replaces a file, so no check can go out of date before the bind.
    public static func start(directory: String, fallbackTag: () -> String = { String(format: "%08x", UInt32.random(in: .min ... .max)) }) throws -> NativeReplyListener {
        let processID = getpid()
        do { return try NativeReplyListener(path: "\(directory)/\(processID).sock") } catch NativeBridgeError.system("bind", EADDRINUSE) {}
        for _ in 0..<fallbackNameTries {
            do { return try NativeReplyListener(path: "\(directory)/\(processID)-\(fallbackTag()).sock") } catch NativeBridgeError.system("bind", EADDRINUSE) { continue }
        }
        throw NativeBridgeError.invalid("Every reply socket name that this service tried already exists, after \(fallbackNameTries) fallback names. No file changed.")
    }

    /// Binds exactly this path. An existing file at the path stops the bind with EADDRINUSE and stays.
    public convenience init(path: String) throws {
        try self.init(path: path, observer: nil)
    }

    init(path: String, observer: (@Sendable (NativeReplySocketStep) -> Void)?) throws {
        self.path = path
        self.observer = observer
        let location = URL(fileURLWithPath: path)
        name = location.lastPathComponent
        _ = try NativeSocketIO.socketAddress(path) // The address limit applies to the full path that a sender uses.
        folder = try NativeReplyFolder(path: location.deletingLastPathComponent().path)
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw NativeBridgeError.system("socket", errno) }
        do {
            try folder.bindSocket(socketFD, name: name)
            observer?(.afterBind)
            guard listen(socketFD, 8) == 0 else { throw NativeBridgeError.system("listen", errno) }
            provedIdentity = try Self.proveOwnership(listener: socketFD, folder: folder, name: name, observer: observer)
            descriptor = socketFD
        } catch {
            Darwin.close(socketFD)
            throw error
        }
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
        removeSocketFile()
    }

    /// Returns the identity at the path if the path reached this listener between two equal captures.
    /// The self-connection ends here, so the reply loop never sees it. A connection from another
    /// process in this short time also ends here. No sender has the address until the start returns.
    private static func proveOwnership(listener: Int32, folder: NativeReplyFolder, name: String,
                                       observer: (@Sendable (NativeReplySocketStep) -> Void)?) throws -> NativeReplyFileIdentity {
        observer?(.beforeIdentityCapture)
        let unproved = "The reply socket \(name) has no proof of ownership, so the file stays and the listener did not start."
        guard let before = folder.status(name), before.st_mode & S_IFMT == S_IFSOCK,
              before.st_uid == getuid(), before.st_mode & 0o077 == 0
        else { throw NativeBridgeError.invalid(unproved) }
        do { try receiveSelfConnection(listener: listener, folder: folder, name: name) }
        catch { throw NativeBridgeError.invalid("\(unproved) \(error.localizedDescription)") }
        guard let after = folder.status(name), after.st_mode & S_IFMT == S_IFSOCK,
              NativeReplyFileIdentity(after) == NativeReplyFileIdentity(before)
        else { throw NativeBridgeError.invalid(unproved) }
        return NativeReplyFileIdentity(before)
    }

    private static func receiveSelfConnection(listener: Int32, folder: NativeReplyFolder, name: String) throws {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else { throw NativeBridgeError.system("socket", errno) }
        defer { Darwin.close(client) }
        var noSignal: Int32 = 1 // The service ignores SIGPIPE only after this start.
        guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(client, F_SETFL, O_NONBLOCK) == 0 else { throw NativeBridgeError.system("client socket", errno) }
        try folder.connectSocket(client, name: name)
        let value = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        guard send(client, value, value.count, 0) == value.count else { throw NativeBridgeError.system("send", errno) }

        let flags = fcntl(listener, F_GETFL)
        guard flags >= 0, fcntl(listener, F_SETFL, flags | O_NONBLOCK) == 0 else { throw NativeBridgeError.system("fcntl", errno) }
        defer { _ = fcntl(listener, F_SETFL, flags) }
        let deadline = Date().addingTimeInterval(selfConnectionSeconds)
        while true {
            try NativeSocketIO.waitFor(listener, events: Int16(POLLIN), deadline: deadline)
            let accepted = accept(listener, nil, nil)
            guard accepted >= 0 else {
                if [EAGAIN, EINTR, ECONNABORTED].contains(errno) { continue }
                throw NativeBridgeError.system("accept", errno)
            }
            defer { Darwin.close(accepted) }
            if try connection(accepted, sends: value, deadline: deadline) { return }
        }
    }

    private static func connection(_ accepted: Int32, sends value: [UInt8], deadline: Date) throws -> Bool {
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: value.count)
        while received.count < value.count {
            try NativeSocketIO.waitFor(accepted, events: Int16(POLLIN), deadline: deadline)
            let count = recv(accepted, &buffer, value.count - received.count, 0)
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { return false }
            received.append(contentsOf: buffer.prefix(count))
        }
        return received == value
    }

    /// Removes the socket file that this listener proved, and never another file. The descriptor stays
    /// open, so a stop can run while the reply loop waits on it. The file first moves to a new private
    /// folder, where a later file at the path cannot take its place. A file that does not match moves
    /// back without replacing anything. If that fails, it stays in the private folder, and the log names it.
    public func removeSocketFile() {
        identityLock.lock(); defer { identityLock.unlock() }
        guard let identity = provedIdentity else { return }
        provedIdentity = nil

        observer?(.beforeStopCheck)
        guard let current = folder.status(name), NativeReplyFileIdentity(current) == identity else { return }
        observer?(.beforePrivateMove)
        var template = Array(".\(getpid())-stop-XXXXXXXX".utf8CString)
        guard mkdtempat_np(folder.descriptor, &template) != nil else { return report("cannot make a private folder, so \(path) stays", code: errno) }
        let privateName = String(cString: template)
        let opened = openat(folder.descriptor, privateName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { return report("cannot open \(privateName), so \(path) stays", code: errno) }
        defer { Darwin.close(opened) }
        guard renameatx_np(folder.descriptor, name, opened, name, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            unlinkat(folder.descriptor, privateName, AT_REMOVEDIR)
            if code != ENOENT { report("cannot move \(path), so it stays", code: code) }
            return
        }
        observer?(.afterPrivateMove)
        var moved = stat()
        if fstatat(opened, name, &moved, AT_SYMLINK_NOFOLLOW) == 0, moved.st_mode & S_IFMT == S_IFSOCK, NativeReplyFileIdentity(moved) == identity {
            observer?(.beforeRemoval)
            guard unlinkat(opened, name, 0) == 0 else { return report("cannot remove \(privateName)/\(name)", code: errno) }
        } else if renameatx_np(opened, name, folder.descriptor, name, UInt32(RENAME_EXCL)) != 0 {
            return report("a file that is not this socket stays at \(privateName)/\(name) in the reply folder", code: errno)
        }
        unlinkat(folder.descriptor, privateName, AT_REMOVEDIR)
    }

    private func report(_ text: String, code: Int32) {
        FileHandle.standardError.write(Data("Native reply listener stop: \(text): \(String(cString: strerror(code)))\n".utf8))
    }

    public func receive(timeout: TimeInterval = 5) throws -> Data {
        try receiveFrame(timeout: timeout).data
    }

    public func receiveFrame(timeout: TimeInterval = 5) throws -> NativeReplyFrame {
        let deadline = Date().addingTimeInterval(min(max(timeout, 0.05), 60))
        try NativeSocketIO.waitFor(descriptor, events: Int16(POLLIN), deadline: deadline)
        let peer = accept(descriptor, nil, nil)
        guard peer >= 0 else { throw NativeBridgeError.system("accept", errno) }
        defer { Darwin.close(peer) }
        try NativeSocketIO.checkPeer(peer)
        let peerPID = (try? NativeSocketIO.peerProcessID(peer)) ?? 0
        var peerUID: uid_t = 0; var peerGID: gid_t = 0
        guard getpeereid(peer, &peerUID, &peerGID) == 0, peerUID == getuid() else {
            throw NativeBridgeError.invalid("Reply peer identity changed or is unavailable.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count < ClaudeLocalBridge.maximumFrameBytes {
            try NativeSocketIO.waitFor(peer, events: Int16(POLLIN), deadline: deadline)
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

/// Removes the listener's socket at a normal stop, then ends the process with the signal's default
/// action, so launchd and the install script see the same stop as before. It uses its own queue,
/// so a busy command queue cannot delay a stop, and the removal stays off the POSIX signal callback.
/// A crash or SIGKILL still leaves the socket.
public final class NativeReplyStopHandler: @unchecked Sendable {
    private let sources: [any DispatchSourceSignal]

    public init(listener: NativeReplyListener, signals: [Int32] = [SIGTERM, SIGINT],
                finish: @escaping @Sendable (Int32) -> Void = { number in signal(number, SIG_DFL); kill(getpid(), number) }) {
        let queue = DispatchQueue(label: "org.checklist.native-reply-stop")
        sources = signals.map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { listener.removeSocketFile(); finish(number) }
            source.resume()
            // A caught signal returns to its default action at exec, and an ignored signal does not,
            // so child processes keep a working SIGTERM. The source still sees a caught signal.
            signal(number) { _ in }
            return source
        }
    }

    deinit { sources.forEach { $0.cancel() } }
}
