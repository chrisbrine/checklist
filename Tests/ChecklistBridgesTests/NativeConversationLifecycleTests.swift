import XCTest
import Darwin
@testable import ChecklistBridges

final class NativeConversationLifecycleTests: XCTestCase {
    private var directory: URL!
    private let session = UUID().uuidString
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private var registry: URL { directory.appendingPathComponent("\(getpid()).json") }
    private func registration(provider: String = "claude", path: String? = nil) throws -> NativeLifecycleRegistration {
        var info = proc_bsdinfo()
        XCTAssertEqual(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))),
                       Int32(MemoryLayout.size(ofValue: info)))
        return try XCTUnwrap(NativeLifecycleRegistration(provider: provider, sessionID: session,
            executionDomain: "\(provider):\(getpid()):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)",
            registryPath: path ?? registry.path))
    }
    private func writeRegistry(session: String? = nil, permissions: Int = 0o600) throws {
        let data = try JSONSerialization.data(withJSONObject: ["pid": getpid(), "sessionId": session ?? self.session, "cwd": directory.path])
        try data.write(to: registry)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: registry.path)
    }
    func testOnlyPositiveProcessAndRegistryPairProvesClosure() {
        for process in [NativeLifecycleObservation.ProcessState.running, .gone, .replaced, .unknown] {
            for registry in [NativeLifecycleObservation.RegistryState.matching, .absent, .replaced, .unsupported, .unknown] {
                let value = NativeLifecycleObservation(process: process, registry: registry, detail: "component fixture")
                XCTAssertEqual(value.provesClosure, [.gone, .replaced].contains(process) && [.absent, .replaced].contains(registry))
            }
        }
    }
    func testInvalidHostRegistrationCannotBeObserved() {
        for domain in ["claude:1:5:0", "claude:123:0:0", "claude:123:5:1000000", "codex:123:5:0", "claude:123:5:0:extra"] {
            XCTAssertNil(NativeLifecycleRegistration(provider: "claude", sessionID: session, executionDomain: domain, registryPath: registry.path))
        }
        XCTAssertNil(NativeLifecycleRegistration(provider: "claude", sessionID: "unknown", executionDomain: "claude:123:5:0", registryPath: registry.path))
    }
    func testActualTestProcessAndMatchingFixtureRemainLive() throws {
        try writeRegistry()
        let result = NativeLifecycleInspector.inspect(try registration())
        XCTAssertEqual(result.process, .running); XCTAssertEqual(result.registry, .matching)
        XCTAssertNotNil(result.registryDigest); XCTAssertFalse(result.provesClosure)
    }
    func testAbsentEntryIsDistinctFromUnverifiableDirectory() throws {
        XCTAssertEqual(NativeLifecycleInspector.inspect(try registration()).registry, .absent)
        let missing = directory.appendingPathComponent("missing/registry.json").path
        XCTAssertEqual(NativeLifecycleInspector.inspect(try registration(path: missing)).registry, .unknown)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        XCTAssertEqual(NativeLifecycleInspector.inspect(try registration()).registry, .unknown)
    }
    func testValidReplacementFixtureDoesNotCloseRunningOriginal() throws {
        try writeRegistry(session: UUID().uuidString)
        let result = NativeLifecycleInspector.inspect(try registration())
        XCTAssertEqual(result.registry, .replaced); XCTAssertEqual(result.process, .running); XCTAssertFalse(result.provesClosure)
    }
    func testUnsafeMalformedAndSymlinkRegistriesStayUnknown() throws {
        try writeRegistry(permissions: 0o666)
        XCTAssertEqual(NativeLifecycleInspector.inspect(try registration()).registry, .unknown)
        try Data("{}".utf8).write(to: registry)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registry.path)
        XCTAssertEqual(NativeLifecycleInspector.inspect(try registration()).registry, .unknown)
        try FileManager.default.removeItem(at: registry)
        try FileManager.default.createSymbolicLink(at: registry, withDestinationURL: directory.appendingPathComponent("missing"))
        XCTAssertEqual(NativeLifecycleInspector.inspect(try registration()).registry, .unknown)
    }
    func testCodexHasNoInventedRegistryQualification() throws {
        try writeRegistry()
        let result = NativeLifecycleInspector.inspect(try registration(provider: "codex"))
        XCTAssertEqual(result.registry, .unsupported); XCTAssertFalse(result.provesClosure)
    }
    func testFIFORegistryWithoutWriterPromptlyStaysUnknown() throws {
        XCTAssertEqual(mkfifo(registry.path, 0o600), 0)
        let registration = try registration()
        let finished = expectation(description: "Nonblocking open rejects FIFO before any read")
        DispatchQueue.global().async {
            XCTAssertEqual(NativeLifecycleInspector.inspect(registration).registry, .unknown)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 1)
    }
    func testConnectedPeerRegistrationRefusesChangedIdentityBeforeAnyBytes() throws {
        // Real same-user socket/current test PID; synthetic registration files.
        // This is a connected-peer guard control, not native conversation reuse.
        let peerDirectory = URL(fileURLWithPath: "/tmp/cl38-peer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: peerDirectory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: peerDirectory) }
        let endpoint = peerDirectory.appendingPathComponent("peer.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0); guard listener >= 0 else { return }
        defer { Darwin.close(listener) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(endpoint.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0); XCTAssertEqual(chmod(endpoint, 0o600), 0); XCTAssertEqual(listen(listener, 8), 0)
        func receivedByteCount() -> Int {
            var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 1_000) > 0 else { XCTFail("Expected bounded connected peer"); return -1 }
            let peer = accept(listener, nil, nil)
            guard peer >= 0 else { XCTFail("Expected accepted peer"); return -1 }
            defer { Darwin.close(peer) }
            var readable = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
            guard poll(&readable, 1, 1_000) > 0 else { XCTFail("Expected bytes or explicit closed stream"); return -1 }
            var bytes = [UInt8](repeating: 0, count: 4_096)
            return recv(peer, &bytes, bytes.count, 0)
        }
        func send(_ registration: NativeLifecycleRegistration) throws -> NativeWriteReceipt {
            try ClaudeLocalBridge.send(content: "Synthetic connected-peer guard", messageID: "cl38-guard",
                sender: .init(replyAddress: "uds:/tmp/cl38-reply.sock", displayName: "CL38 component", permissionClass: .prompting),
                endpoint: endpoint, expectedPeerPID: getpid(), expectedRegistration: registration, timeout: 1)
        }
        try writeRegistry()
        let original = try registration()
        let replacedStart = try XCTUnwrap(NativeLifecycleRegistration(provider: "claude", sessionID: session,
            executionDomain: "claude:\(getpid()):\(original.startSeconds + 1):\(original.startMicroseconds)", registryPath: registry.path))
        XCTAssertThrowsError(try send(replacedStart)); XCTAssertEqual(receivedByteCount(), 0)
        try writeRegistry(session: UUID().uuidString)
        XCTAssertThrowsError(try send(original)); XCTAssertEqual(receivedByteCount(), 0)
        try FileManager.default.removeItem(at: registry)
        XCTAssertThrowsError(try send(original)); XCTAssertEqual(receivedByteCount(), 0)
        try writeRegistry()
        XCTAssertEqual(try send(original).status, "transport_written")
        XCTAssertGreaterThan(receivedByteCount(), 0)
    }
}
