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
    /// One connection, with its descriptor open: errno, or 0 when the holder's queue took it.
    private func connect(_ path: String) throws -> (descriptor: Int32, result: Int32) {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try NativeSocketIO.socketAddress(path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return (client, connected == 0 ? 0 : errno)
    }
    /// Fills the holder's queue until Darwin refuses a connection, and returns the open clients.
    private func fillQueue(_ path: String) throws -> [Int32] {
        var clients: [Int32] = []
        for _ in 0..<64 {
            let attempt = try connect(path)
            clients.append(attempt.descriptor)
            if attempt.result != 0 {
                XCTAssertEqual(attempt.result, ECONNREFUSED)
                return clients
            }
        }
        XCTFail("The queue did not fill.")
        return clients
    }
    private func assertFallback(_ listener: NativeReplyListener, line: UInt = #line) {
        let name = URL(fileURLWithPath: listener.path).lastPathComponent
        XCTAssertNotNil(name.range(of: "^\(getpid())-[0-9a-f]{8}\\.sock$", options: .regularExpression), name, line: line)
        XCTAssertEqual(URL(fileURLWithPath: listener.path).deletingLastPathComponent().path, directory, line: line)
        XCTAssertFalse(listener.hasProcessIDName, line: line)
        XCTAssertEqual(listener.address, "uds:" + listener.path, line: line)
        XCTAssertNotNil(inode(listener.path), line: line)
    }
    /// A real frame through the bound path, with the bound address as the sender's reply address.
    private func assertReceives(_ listener: NativeReplyListener, line: UInt = #line) throws {
        let sender = ClaudePeerSender(replyAddress: listener.address, displayName: "Synthetic", permissionClass: .prompting)
        _ = try ClaudeLocalBridge.send(content: "synthetic", messageID: "listener-start", sender: sender, endpoint: listener.path)
        XCTAssertFalse(try listener.receive().isEmpty, line: line)
    }

    func testFreePathBindsTheProcessIDName() throws {
        let listener = try NativeReplyListener.start(directory: directory)
        XCTAssertEqual(listener.path, ownPath)
        XCTAssertTrue(listener.hasProcessIDName)
        XCTAssertEqual(listener.address, "uds:" + ownPath)
        try assertReceives(listener)
    }

    func testStaleSocketStaysAndTheListenerBindsAFallbackName() throws {
        try staleSocket(ownPath)
        let stale = inode(ownPath)
        XCTAssertEqual(try connect(ownPath).result, ECONNREFUSED)
        let listener = try NativeReplyListener.start(directory: directory)
        assertFallback(listener)
        XCTAssertEqual(inode(ownPath), stale)
        try assertReceives(listener)
    }

    func testRegularFileStaysAndTheListenerBindsAFallbackName() throws {
        try Data("keep".utf8).write(to: URL(fileURLWithPath: ownPath))
        let found = inode(ownPath)
        let listener = try NativeReplyListener.start(directory: directory)
        assertFallback(listener)
        XCTAssertEqual(inode(ownPath), found)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: ownPath)), Data("keep".utf8))
        try assertReceives(listener)
    }

    func testSymlinkAndItsTargetStayAndTheListenerBindsAFallbackName() throws {
        let target = directory + "/target.sock"
        try staleSocket(target)
        let targetInode = inode(target)
        XCTAssertEqual(symlink(target, ownPath), 0)
        let link = inode(ownPath)
        let listener = try NativeReplyListener.start(directory: directory)
        assertFallback(listener)
        XCTAssertEqual(inode(ownPath), link)
        XCTAssertEqual(inode(target), targetInode)
    }

    func testLiveListenerStaysAndStillAccepts() throws {
        let holder = try socketFile(ownPath, listening: true)
        defer { Darwin.close(holder) }
        let held = inode(ownPath)
        let listener = try NativeReplyListener.start(directory: directory)
        assertFallback(listener)
        XCTAssertEqual(inode(ownPath), held)
        let client = try connect(ownPath)
        defer { Darwin.close(client.descriptor) }
        XCTAssertEqual(client.result, 0)
        let accepted = accept(holder, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        Darwin.close(accepted)
    }

    /// The review's case: Darwin refuses a connection, and the holder is alive.
    func testFullQueueListenerStaysAndAcceptsAfterItsQueueDrains() throws {
        let holder = try socketFile(ownPath, listening: true, backlog: 1)
        defer { Darwin.close(holder) }
        let clients = try fillQueue(ownPath)
        defer { clients.forEach { Darwin.close($0) } }
        let held = inode(ownPath)
        let listener = try NativeReplyListener.start(directory: directory)
        assertFallback(listener)
        XCTAssertEqual(inode(ownPath), held)
        try assertReceives(listener)

        XCTAssertEqual(fcntl(holder, F_SETFL, O_NONBLOCK), 0)
        var drained = 0
        while case let accepted = accept(holder, nil, nil), accepted >= 0 {
            Darwin.close(accepted)
            drained += 1
        }
        XCTAssertGreaterThan(drained, 0)
        let client = try connect(ownPath)
        defer { Darwin.close(client.descriptor) }
        XCTAssertEqual(client.result, 0)
        let accepted = accept(holder, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        Darwin.close(accepted)
    }

    /// This test failed on the replaced code at its inode check: that code replaced the live socket.
    func testExactPathInitDoesNotReplaceAFullQueueListener() throws {
        let holder = try socketFile(ownPath, listening: true, backlog: 1)
        defer { Darwin.close(holder) }
        let clients = try fillQueue(ownPath)
        defer { clients.forEach { Darwin.close($0) } }
        let held = inode(ownPath)
        XCTAssertThrowsError(try NativeReplyListener(path: ownPath)) { error in
            guard case NativeBridgeError.system("bind", EADDRINUSE) = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(inode(ownPath), held)
    }

    func testFallbackCollisionTakesANewNameAndKeepsTheFile() throws {
        try staleSocket(ownPath)
        let taken = directory + "/\(getpid())-aaaaaaaa.sock"
        try Data("keep".utf8).write(to: URL(fileURLWithPath: taken))
        var tags = ["aaaaaaaa", "bbbbbbbb"]
        let listener = try NativeReplyListener.start(directory: directory, fallbackTag: { tags.removeFirst() })
        XCTAssertEqual(listener.path, directory + "/\(getpid())-bbbbbbbb.sock")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: taken)), Data("keep".utf8))
    }

    func testFallbackTriesHaveABoundAndNoFileChanges() throws {
        try staleSocket(ownPath)
        let taken = directory + "/\(getpid())-aaaaaaaa.sock"
        try Data("keep".utf8).write(to: URL(fileURLWithPath: taken))
        var calls = 0
        XCTAssertThrowsError(try NativeReplyListener.start(directory: directory, fallbackTag: { calls += 1; return "aaaaaaaa" })) { error in
            XCTAssertTrue(error.localizedDescription.contains("No file changed"), error.localizedDescription)
        }
        XCTAssertEqual(calls, NativeReplyListener.fallbackNameTries)
        XCTAssertEqual(calls, 8)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory).sorted(), [URL(fileURLWithPath: ownPath).lastPathComponent, URL(fileURLWithPath: taken).lastPathComponent].sorted())
    }

    /// `<pid>.sock` fits the 103-byte `sun_path` limit here, and the fallback name does not.
    func testFallbackNamePastTheAddressLimitFailsAndChangesNothing() throws {
        let name = "/\(getpid()).sock"
        let longDirectory = "/tmp/" + String(repeating: "d", count: 103 - name.utf8.count - "/tmp/".utf8.count)
        try FileManager.default.createDirectory(atPath: longDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: longDirectory) }
        try Data("keep".utf8).write(to: URL(fileURLWithPath: longDirectory + name))
        XCTAssertEqual((longDirectory + name).utf8.count, 103)
        XCTAssertThrowsError(try NativeReplyListener.start(directory: longDirectory)) { error in
            XCTAssertEqual(error.localizedDescription, "Unix socket path is too long.")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: longDirectory), [String(name.dropFirst())])
    }

    func testListenerEndRemovesOnlyItsBoundPath() throws {
        try staleSocket(ownPath)
        let stale = inode(ownPath)
        var listener: NativeReplyListener? = try NativeReplyListener.start(directory: directory)
        let bound = try XCTUnwrap(listener?.path)
        XCTAssertNotNil(inode(bound))
        listener = nil
        XCTAssertNil(listener)
        XCTAssertNil(inode(bound))
        XCTAssertEqual(inode(ownPath), stale)
    }

    func testListenerEndRemovesTheProcessIDName() throws {
        var listener: NativeReplyListener? = try NativeReplyListener.start(directory: directory)
        XCTAssertNotNil(inode(ownPath))
        listener = nil
        XCTAssertNil(listener)
        XCTAssertNil(inode(ownPath))
    }

    func testStopSignalRemovesTheFallbackPathAndThenFinishes() throws {
        try staleSocket(ownPath)
        let stale = inode(ownPath)
        let listener = try NativeReplyListener.start(directory: directory)
        assertFallback(listener)
        let finished = expectation(description: "finish")
        finished.assertForOverFulfill = false
        let handler = NativeReplyStopHandler(listener: listener, signals: [SIGUSR2]) { number in
            XCTAssertEqual(number, SIGUSR2)
            finished.fulfill()
        }
        // The source registers on its own queue, and a signal before that registration has no effect.
        for _ in 0..<50 where inode(listener.path) != nil {
            kill(getpid(), SIGUSR2)
            usleep(100_000)
        }
        wait(for: [finished], timeout: 5)
        XCTAssertNil(inode(listener.path))
        XCTAssertEqual(inode(ownPath), stale)
        withExtendedLifetime(handler) {}
    }

    /// The stop removes only the file that this listener created.
    func testRemovalLeavesALaterFileAtThePath() throws {
        let listener = try NativeReplyListener(path: ownPath)
        unlink(ownPath)
        try Data("later".utf8).write(to: URL(fileURLWithPath: ownPath))
        listener.removeSocketFile()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: ownPath)), Data("later".utf8))
    }
}
