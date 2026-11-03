import XCTest
import Darwin
@testable import ChecklistBridges

/// Temporary folders only. A short /tmp path keeps each name inside the socket address limit.
final class NativeReplyListenerStartTests: XCTestCase {
    private var directory: String!
    private var ownPath: String { directory + "/\(getpid()).sock" }

    override func setUpWithError() throws {
        directory = "/tmp/cl415-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: directory)
    }

    /// A bound socket. With `listening` false, or after a close, a connection is refused.
    private func socketFile(_ path: String, listening: Bool, backlog: Int32 = 8) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        var address = try NativeSocketIO.socketAddress(path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(chmod(path, 0o600), 0)
        if listening { XCTAssertEqual(listen(descriptor, backlog), 0) }
        return descriptor
    }
    private func staleSocket(_ path: String) throws {
        Darwin.close(try socketFile(path, listening: false))
    }
    private func inode(_ path: String) -> ino_t? {
        var found = stat()
        return lstat(path, &found) == 0 ? found.st_ino : nil
    }
    private func assertRefused(_ path: String, _ expected: String, line: UInt = #line) {
        XCTAssertThrowsError(try NativeReplyListener(path: path), line: line) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.hasPrefix("Refusing to replace an existing reply path"), text, line: line)
            XCTAssertTrue(text.contains(expected), text, line: line)
        }
    }

    func testStaleSocketAtOwnPIDPathIsReplacedAndTheNewListenerReceives() throws {
        try staleSocket(ownPath)
        let stale = inode(ownPath)
        XCTAssertEqual(try NativeSocketIO.connectResult(ownPath), ECONNREFUSED)
        let listener = try NativeReplyListener(path: ownPath)
        XCTAssertNotEqual(inode(ownPath), stale)
        let sender = ClaudePeerSender(replyAddress: "uds:/tmp/reply.sock", displayName: "Synthetic", permissionClass: .prompting)
        _ = try ClaudeLocalBridge.send(content: "synthetic", messageID: "stale-socket", sender: sender, endpoint: listener.path)
        XCTAssertFalse(try listener.receive().isEmpty)
    }

    func testLiveListenerAtOwnPIDPathRefusesAndStays() throws {
        let holder = try socketFile(ownPath, listening: true)
        defer { Darwin.close(holder); unlink(ownPath) }
        let held = inode(ownPath)
        assertRefused(ownPath, "a process listens on it")
        XCTAssertEqual(inode(ownPath), held)
    }

    func testRegularFileAtOwnPIDPathRefusesAndKeepsItsBytes() throws {
        try Data("keep".utf8).write(to: URL(fileURLWithPath: ownPath))
        defer { unlink(ownPath) }
        assertRefused(ownPath, "it is not a socket")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: ownPath)), Data("keep".utf8))
    }

    func testSymlinkAtOwnPIDPathRefusesAndItsTargetStays() throws {
        let target = directory + "/target.sock"
        try staleSocket(target)
        defer { unlink(target) }
        XCTAssertEqual(symlink(target, ownPath), 0)
        defer { unlink(ownPath) }
        assertRefused(ownPath, "it is not a socket")
        XCTAssertNotNil(inode(target))
    }

    /// The rule depends on the PID in the name: a stale socket with any other name is not ours.
    func testStaleSocketWithAnotherNameRefusesAndStays() throws {
        for name in ["inbox.sock", "\(getpid() + 1).sock"] {
            let path = directory + "/" + name
            try staleSocket(path)
            defer { unlink(path) }
            let found = inode(path)
            assertRefused(path, "own socket name")
            XCTAssertEqual(inode(path), found)
        }
    }

    /// Measures a limit of the connection test: Darwin refuses a connection to a live listener with a
    /// full queue. The name rule covers it: no other live process can have made a socket with this PID.
    func testFullQueueListenerRefusesAConnectionAtDarwinLevel() throws {
        let path = directory + "/queue.sock"
        let holder = try socketFile(path, listening: true, backlog: 1)
        defer { Darwin.close(holder); unlink(path) }
        var clients: [Int32] = []
        defer { clients.forEach { Darwin.close($0) } }
        var result: Int32 = 0
        for _ in 0..<64 where result == 0 {
            let client = socket(AF_UNIX, SOCK_STREAM, 0)
            clients.append(client)
            var address = try NativeSocketIO.socketAddress(path)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            result = connected == 0 ? 0 : errno
        }
        XCTAssertEqual(result, ECONNREFUSED)
    }

    func testListenerEndRemovesItsOwnSocket() throws {
        var listener: NativeReplyListener? = try NativeReplyListener(path: ownPath)
        XCTAssertNotNil(inode(ownPath))
        listener = nil
        XCTAssertNil(listener)
        XCTAssertNil(inode(ownPath))
    }

    func testStopSignalRemovesTheSocketAndThenFinishes() throws {
        let listener = try NativeReplyListener(path: ownPath)
        let finished = expectation(description: "finish")
        finished.assertForOverFulfill = false
        let handler = NativeReplyStopHandler(listener: listener, signals: [SIGUSR2]) { number in
            XCTAssertEqual(number, SIGUSR2)
            finished.fulfill()
        }
        // The source registers on its own queue, and a signal before that registration has no effect.
        for _ in 0..<50 where inode(ownPath) != nil {
            kill(getpid(), SIGUSR2)
            usleep(100_000)
        }
        wait(for: [finished], timeout: 5)
        XCTAssertNil(inode(ownPath))
        withExtendedLifetime(handler) {}
    }

    /// The stop removes only the file that this listener created.
    func testRemovalLeavesALaterFileAtThePath() throws {
        let listener = try NativeReplyListener(path: ownPath)
        unlink(ownPath)
        try Data("later".utf8).write(to: URL(fileURLWithPath: ownPath))
        defer { unlink(ownPath) }
        listener.removeSocketFile()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: ownPath)), Data("later".utf8))
    }
}
