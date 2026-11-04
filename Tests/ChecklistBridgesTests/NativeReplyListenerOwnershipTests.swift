import XCTest
import Darwin
@testable import ChecklistBridges

/// Controlled swaps at each named step of a start or a stop. Temporary folders only. A swap uses
/// `rename`, as a same-user process would, so a foreign file keeps its inode.
final class NativeReplyListenerOwnershipTests: XCTestCase {
    private var directory: String!
    private var path: String { directory + "/\(getpid()).sock" }
    private var foreign: String { directory + "/foreign" }
    private var aside: String { directory + "/aside" }

    override func setUpWithError() throws {
        directory = "/tmp/cl415o-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: directory)
    }

    private func attributes(_ path: String) -> stat? {
        var found = stat()
        return lstat(path, &found) == 0 ? found : nil
    }
    private func inode(_ path: String) -> ino_t? { attributes(path)?.st_ino }
    private func contents(_ path: String) -> Data? { try? Data(contentsOf: URL(fileURLWithPath: path)) }
    private func names() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted() }
    private func makeForeignFile(_ path: String, text: String = "keep", mode: mode_t = 0o644) throws -> ino_t {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(chmod(path, mode), 0)
        return try XCTUnwrap(inode(path))
    }
    /// A socket with `mode`, bound at `path`. With `listening` false, a connection is refused.
    private func makeForeignSocket(_ path: String, listening: Bool, mode: mode_t = 0o600) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try NativeSocketIO.socketAddress(path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(chmod(path, mode), 0)
        if listening { XCTAssertEqual(listen(descriptor, 8), 0) }
        return descriptor
    }
    /// Runs `body` once, at `step`, and moves the listener's own file aside first when `displace` is true.
    private func at(_ step: NativeReplySocketStep, displace: Bool = true, _ body: @escaping @Sendable () -> Void) -> @Sendable (NativeReplySocketStep) -> Void {
        let bound = path, moved = aside
        return { current in
            guard current == step else { return }
            if displace { XCTAssertEqual(rename(bound, moved), 0) }
            body()
        }
    }
    private func swapIn(_ source: String, _ target: String) -> @Sendable () -> Void {
        { XCTAssertEqual(rename(source, target), 0) }
    }
    private func assertUnproved(_ error: Error, line: UInt = #line) {
        XCTAssertTrue(error.localizedDescription.contains("no proof of ownership"), error.localizedDescription, line: line)
    }

    // MARK: - Start

    /// Swap after bind, before the capture: the old code recorded this file as its own, and removed it.
    func testRegularFileSwappedInAfterBindStaysWithItsModeAndContents() throws {
        let original = try makeForeignFile(foreign, mode: 0o644)
        for step in [NativeReplySocketStep.afterBind, .beforeIdentityCapture] {
            XCTAssertThrowsError(try NativeReplyListener(path: path, observer: at(step, swapIn(foreign, path)))) { assertUnproved($0) }
            XCTAssertEqual(inode(path), original)
            XCTAssertEqual(contents(path), Data("keep".utf8))
            XCTAssertEqual(try XCTUnwrap(attributes(path)).st_mode & 0o777, 0o644)
            // Put the foreign file back, and the listener's own file stays aside, as a folder bound counts it.
            XCTAssertEqual(rename(path, foreign), 0)
            XCTAssertEqual(try XCTUnwrap(attributes(aside)).st_mode & S_IFMT, S_IFSOCK)
            XCTAssertEqual(rename(aside, aside + "-\(step)"), 0)
        }
    }

    /// Swap to a symlink: the old `chmod` followed it out of the folder and changed the target.
    func testSymlinkSwappedInAfterBindStaysAndItsExternalTargetKeepsItsMode() throws {
        let replies = directory + "/replies"
        try FileManager.default.createDirectory(atPath: replies, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let target = directory + "/external-target"
        let targetInode = try makeForeignFile(target, mode: 0o644)
        for (index, step) in [NativeReplySocketStep.afterBind, .beforeIdentityCapture].enumerated() {
            let bound = replies + "/reply-\(index).sock", displaced = directory + "/aside-\(index)"
            let link = directory + "/link-\(index)"
            XCTAssertEqual(symlink(target, link), 0)
            let linkInode = try XCTUnwrap(inode(link))
            let observer: @Sendable (NativeReplySocketStep) -> Void = { current in
                guard current == step else { return }
                XCTAssertEqual(rename(bound, displaced), 0)
                XCTAssertEqual(rename(link, bound), 0)
            }
            XCTAssertThrowsError(try NativeReplyListener(path: bound, observer: observer)) { assertUnproved($0) }
            XCTAssertEqual(inode(bound), linkInode)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: bound), target)
            XCTAssertEqual(inode(target), targetInode)
            XCTAssertEqual(try XCTUnwrap(attributes(target)).st_mode & 0o777, 0o644)
            XCTAssertEqual(contents(target), Data("keep".utf8))
        }
    }

    /// A foreign socket with an open mode: no `chmod` runs, and the start reports a failure.
    func testForeignSocketWithAWrongModeKeepsItsMode() throws {
        Darwin.close(try makeForeignSocket(foreign, listening: false, mode: 0o666))
        let original = try XCTUnwrap(inode(foreign))
        XCTAssertThrowsError(try NativeReplyListener(path: path, observer: at(.afterBind, swapIn(foreign, path)))) { assertUnproved($0) }
        XCTAssertEqual(inode(path), original)
        XCTAssertEqual(try XCTUnwrap(attributes(path)).st_mode & 0o777, 0o666)
    }

    /// A dead foreign socket refuses the self-connection, so no proof exists.
    func testDeadForeignSocketSwappedInStays() throws {
        Darwin.close(try makeForeignSocket(foreign, listening: false))
        let original = try XCTUnwrap(inode(foreign))
        XCTAssertThrowsError(try NativeReplyListener(path: path, observer: at(.beforeIdentityCapture, swapIn(foreign, path)))) { assertUnproved($0) }
        XCTAssertEqual(inode(path), original)
    }

    /// A live foreign listener takes the self-connection, and this listener's accept reaches its bound.
    func testLiveForeignListenerSwappedInStaysAndNoProofExists() throws {
        let holder = try makeForeignSocket(foreign, listening: true)
        defer { Darwin.close(holder) }
        let original = try XCTUnwrap(inode(foreign))
        let began = Date()
        XCTAssertThrowsError(try NativeReplyListener(path: path, observer: at(.beforeIdentityCapture, swapIn(foreign, path)))) { assertUnproved($0) }
        XCTAssertLessThan(Date().timeIntervalSince(began), NativeReplyListener.selfConnectionSeconds + 1)
        XCTAssertEqual(inode(path), original)
        XCTAssertEqual(fcntl(holder, F_SETFL, O_NONBLOCK), 0)
        let accepted = accept(holder, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0, "The foreign listener still works.")
        Darwin.close(accepted)
    }

    /// A failed start with the listener's own file at the path: no removal, and the folder bound counts it.
    func testFailedStartAfterBindRemovesNothing() throws {
        let observer: @Sendable (NativeReplySocketStep) -> Void = { [path] step in
            guard step == .afterBind else { return }
            XCTAssertEqual(chmod(path, 0o666), 0) // The only failure that a test can force after a real bind.
        }
        XCTAssertThrowsError(try NativeReplyListener(path: path, observer: observer)) { assertUnproved($0) }
        XCTAssertEqual(try XCTUnwrap(attributes(path)).st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(try XCTUnwrap(attributes(path)).st_mode & 0o777, 0o666)
        XCTAssertEqual(names(), [URL(fileURLWithPath: path).lastPathComponent])
    }

    /// The folder descriptor uses O_NOFOLLOW, so a link at the folder's own name stops the start.
    func testAFolderThatIsASymlinkIsRefusedAndChangesNothing() throws {
        let link = directory + "/link"
        XCTAssertEqual(symlink(directory, link), 0)
        XCTAssertThrowsError(try NativeReplyListener(path: link + "/x.sock")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Reply directory"), error.localizedDescription)
        }
        XCTAssertEqual(names(), ["link"])
    }

    func testStartMakesAPrivateModeAndKeepsTheProcessStateAsItWas() throws {
        let earlierMask = umask(0o022)
        defer { umask(earlierMask) }
        let earlierFolder = FileManager.default.currentDirectoryPath
        let listener = try NativeReplyListener(path: path)
        XCTAssertEqual(try XCTUnwrap(attributes(path)).st_mode & 0o077, 0)
        XCTAssertEqual(umask(0o022), 0o022)
        XCTAssertEqual(FileManager.default.currentDirectoryPath, earlierFolder)
        XCTAssertNotEqual(earlierFolder, directory)
        withExtendedLifetime(listener) {}
    }

    /// The reply loop must not see the proof: no connection waits after start, and the first frame is real.
    func testSelfConnectionDoesNotReachTheFrameHandler() throws {
        let listener = try NativeReplyListener(path: path)
        XCTAssertThrowsError(try listener.receiveFrame(timeout: 0.1)) { error in
            guard case NativeBridgeError.timedOut = error else { return XCTFail("\(error)") }
        }
        let sender = ClaudePeerSender(replyAddress: listener.address, displayName: "Synthetic", permissionClass: .prompting)
        _ = try ClaudeLocalBridge.send(content: "synthetic", messageID: "first-frame", sender: sender, endpoint: listener.path)
        let frame = try listener.receiveFrame(timeout: 2)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: frame.data) as? [String: Any])
        XCTAssertEqual(object["msg_id"] as? String, "first-frame")
        XCTAssertThrowsError(try listener.receiveFrame(timeout: 0.1))
    }

    /// Another connection reaches the queue first with other bytes: it ends in the start, and the proof still holds.
    func testAnotherConnectionBeforeTheProofDoesNotCountAsProof() throws {
        let path = self.path
        let observer: @Sendable (NativeReplySocketStep) -> Void = { step in
            guard step == .beforeIdentityCapture else { return }
            let client = socket(AF_UNIX, SOCK_STREAM, 0)
            guard var address = try? NativeSocketIO.socketAddress(path) else { return XCTFail("address") }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            XCTAssertEqual(connected, 0)
            let other = [UInt8](repeating: 0, count: 16)
            XCTAssertEqual(send(client, other, other.count, 0), other.count)
            Darwin.close(client)
        }
        let listener = try NativeReplyListener(path: path, observer: observer)
        XCTAssertThrowsError(try listener.receiveFrame(timeout: 0.1))
        listener.removeSocketFile()
        XCTAssertEqual(names(), [URL(fileURLWithPath: path).lastPathComponent], "A start observation never authorizes pathname removal.")
    }

    // MARK: - Stop

    func testNormalStopRetainsOneSocketWithoutAddingAPrivateFolder() throws {
        let listener = try NativeReplyListener(path: path)
        let original = try XCTUnwrap(inode(path))
        let boundNames = names()
        listener.removeSocketFile()
        XCTAssertEqual(inode(path), original)
        XCTAssertEqual(names(), boundNames)
        listener.removeSocketFile()
        XCTAssertEqual(names(), boundNames, "Repeated cleanup adds no files or folders.")
    }

    func testFileSwappedInBeforeTheStopCheckIsNotMoved() throws {
        let original = try makeForeignFile(foreign)
        let listener = try NativeReplyListener(path: path, observer: at(.beforeStopCheck, swapIn(foreign, path)))
        listener.removeSocketFile()
        XCTAssertEqual(inode(path), original)
        XCTAssertEqual(contents(path), Data("keep".utf8))
        XCTAssertEqual(names(), ["aside", URL(fileURLWithPath: path).lastPathComponent].sorted())
    }

    /// Regression at the actual removal name, including the old private-folder implementation.
    /// The old code passed a swap at the public name but deleted a replacement at this name.
    func testReplacementAfterTheFinalCleanupCheckStaysUnchanged() throws {
        let original = try makeForeignFile(foreign)
        let directory = self.directory!, path = self.path, aside = self.aside, foreign = self.foreign
        let name = URL(fileURLWithPath: path).lastPathComponent
        let observer: @Sendable (NativeReplySocketStep) -> Void = { step in
            guard step == .beforeRemoval else { return }
            let stopFolder = try? FileManager.default.contentsOfDirectory(atPath: directory).first { $0.hasPrefix(".\(getpid())-stop-") }
            let removalPath = stopFolder.map { directory + "/" + $0 + "/" + name } ?? path
            XCTAssertEqual(rename(removalPath, aside), 0)
            XCTAssertEqual(rename(foreign, removalPath), 0)
        }
        let listener = try NativeReplyListener(path: path, observer: observer)
        listener.removeSocketFile()
        XCTAssertEqual(inode(path), original)
        XCTAssertEqual(contents(path), Data("keep".utf8))
        XCTAssertEqual(try XCTUnwrap(attributes(path)).st_mode & 0o777, 0o644)
        XCTAssertEqual(names(), ["aside", name].sorted(), "Cleanup neither moves nor removes a replacement.")
    }

    func testSymlinkAfterTheFinalCleanupCheckAndItsExternalTargetStayUnchanged() throws {
        let replies = directory + "/replies"
        try FileManager.default.createDirectory(atPath: replies, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let bound = replies + "/reply.sock", target = directory + "/external-target"
        let targetInode = try makeForeignFile(target)
        XCTAssertEqual(symlink(target, foreign), 0)
        let linkInode = try XCTUnwrap(inode(foreign))
        let foreign = self.foreign, aside = self.aside
        let observer: @Sendable (NativeReplySocketStep) -> Void = { step in
            guard step == .beforeRemoval else { return }
            XCTAssertEqual(rename(bound, aside), 0)
            XCTAssertEqual(rename(foreign, bound), 0)
        }
        let listener = try NativeReplyListener(path: bound, observer: observer)
        listener.removeSocketFile()
        XCTAssertEqual(inode(bound), linkInode)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: bound), target)
        XCTAssertEqual(inode(target), targetInode)
        XCTAssertEqual(try XCTUnwrap(attributes(target)).st_mode & 0o777, 0o644)
        XCTAssertEqual(contents(target), Data("keep".utf8))
    }

    func testForeignSocketAfterTheFinalCleanupCheckStaysUnchanged() throws {
        let holder = try makeForeignSocket(foreign, listening: true)
        defer { Darwin.close(holder) }
        let original = try XCTUnwrap(inode(foreign))
        let listener = try NativeReplyListener(path: path, observer: at(.beforeRemoval, swapIn(foreign, path)))
        listener.removeSocketFile()
        XCTAssertEqual(inode(path), original)
        XCTAssertEqual(try XCTUnwrap(attributes(path)).st_mode & 0o777, 0o600)
    }

    func testEverySuccessfulBindCountsIncludingNormalStopAndUncertainStart() throws {
        var first: NativeReplyListener? = try NativeReplyListener(path: path)
        let original = try XCTUnwrap(inode(path))
        first = nil
        XCTAssertNil(first)
        XCTAssertEqual(inode(path), original, "Deinit leaves one socket from the successful bind.")
        XCTAssertThrowsError(try NativeReplyListener(path: path))
        XCTAssertEqual(names().count, 1, "A bind collision adds nothing.")
        var fallback: NativeReplyListener? = try NativeReplyListener.start(directory: directory, fallbackTag: { "abcdef01" })
        XCTAssertFalse(try XCTUnwrap(fallback).hasProcessIDName)
        fallback?.removeSocketFile()
        fallback = nil
        XCTAssertEqual(names().count, 2, "A normal fallback stop counts as one more successful bind.")
        let failedPath = directory + "/failed.sock"
        XCTAssertThrowsError(try NativeReplyListener(path: failedPath, observer: { step in
            if step == .afterBind { XCTAssertEqual(chmod(failedPath, 0o666), 0) }
        })) { assertUnproved($0) }
        XCTAssertEqual(names().count, 3, "An uncertain start after bind counts too.")
        XCTAssertFalse(names().contains { $0.contains("-stop-") })
    }

    /// The signal route still finishes, and leaves the same single socket.
    func testStopSignalRetainsTheSocketThenFinishes() throws {
        let listener = try NativeReplyListener(path: path)
        let original = try XCTUnwrap(inode(path))
        let finished = expectation(description: "finish")
        let handler = NativeReplyStopHandler(listener: listener, signals: [SIGUSR2]) { _ in finished.fulfill() }
        usleep(100_000) // Allow the dispatch source to register before the one bounded signal.
        kill(getpid(), SIGUSR2)
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(inode(path), original)
        XCTAssertEqual(names(), [URL(fileURLWithPath: path).lastPathComponent])
        withExtendedLifetime(handler) {}
    }
}
