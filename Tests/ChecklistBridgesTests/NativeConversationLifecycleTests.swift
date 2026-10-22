import XCTest
import Darwin
import ChecklistProviders
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
    // An owned non-host process exercises the real kernel observation. These
    // private registry fixtures do not qualify Claude/Codex conversation closure.
    private func withOwnedProcess(_ body: (Process, NativeLifecycleRegistration) throws -> Void) throws {
        let process = Process(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = input; process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? input.fileHandleForWriting.close()
        }
        var info = proc_bsdinfo()
        let count = proc_pidinfo(process.processIdentifier, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
        XCTAssertEqual(count, Int32(MemoryLayout.size(ofValue: info)))
        let registration = try XCTUnwrap(NativeLifecycleRegistration(provider: "claude", sessionID: session,
            executionDomain: "claude:\(process.processIdentifier):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)",
            registryPath: registry.path))
        try body(process, registration)
    }
    private func writeOwnedRegistry(_ registration: NativeLifecycleRegistration, session: String? = nil) throws {
        let data = try JSONSerialization.data(withJSONObject: ["pid": registration.processID,
            "sessionId": session ?? self.session, "cwd": directory.path])
        try data.write(to: registry)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registry.path)
    }
    func testActualOwnedProcessExitRequiresRegistryClosureToo() throws {
        try withOwnedProcess { process, registration in
            try writeOwnedRegistry(registration)
            let live = NativeLifecycleInspector.inspect(registration)
            XCTAssertEqual(live.process, .running); XCTAssertEqual(live.registry, .matching)
            XCTAssertFalse(live.provesClosure)
            process.terminate(); process.waitUntilExit()
            let staleRegistry = NativeLifecycleInspector.inspect(registration)
            XCTAssertEqual(staleRegistry.process, .gone); XCTAssertEqual(staleRegistry.registry, .matching)
            XCTAssertFalse(staleRegistry.provesClosure)
            try FileManager.default.removeItem(at: registry)
            let closed = NativeLifecycleInspector.inspect(registration)
            XCTAssertEqual(closed.process, .gone); XCTAssertEqual(closed.registry, .absent)
            XCTAssertTrue(closed.provesClosure)
        }
    }
    func testActualOwnedProcessExitStillRejectsUnverifiableReplacement() throws {
        try withOwnedProcess { process, registration in
            process.terminate(); process.waitUntilExit()
            try writeOwnedRegistry(registration, session: UUID().uuidString)
            let replaced = NativeLifecycleInspector.inspect(registration)
            XCTAssertEqual(replaced.process, .gone); XCTAssertEqual(replaced.registry, .replaced)
            XCTAssertNotNil(replaced.registryDigest); XCTAssertTrue(replaced.provesClosure)
            try Data("{}".utf8).write(to: registry)
            let malformed = NativeLifecycleInspector.inspect(registration)
            XCTAssertEqual(malformed.process, .gone); XCTAssertEqual(malformed.registry, .unknown)
            XCTAssertFalse(malformed.provesClosure)
            try writeOwnedRegistry(registration, session: UUID().uuidString)
            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: registry.path)
            XCTAssertFalse(NativeLifecycleInspector.inspect(registration).provesClosure)
            try FileManager.default.removeItem(at: registry)
            try FileManager.default.removeItem(at: directory)
            let missingDirectory = NativeLifecycleInspector.inspect(registration)
            XCTAssertEqual(missingDirectory.registry, .unknown); XCTAssertFalse(missingDirectory.provesClosure)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
        }
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
    func testRegistrationUsesQualifiedWorkProviderInsteadOfFixedProviderNames() throws {
        let plugin = BridgeFixtureProviderPlugin()
        let enabled = try ProviderPluginRegistry([.init(plugin: plugin, enabled: true, qualifiedCapabilities: plugin.manifest.capabilities)])
        XCTAssertNotNil(NativeLifecycleRegistration(provider: "fixture", sessionID: session, executionDomain: "fixture:24680:5:0",
            registryPath: nil, providerRegistry: enabled))
        XCTAssertNil(NativeLifecycleRegistration(provider: "fixture", sessionID: session, executionDomain: "fixture:24680:5:0", registryPath: nil))
        for entry in [ProviderPluginRegistration(plugin: plugin, enabled: false, qualifiedCapabilities: plugin.manifest.capabilities),
                      ProviderPluginRegistration(plugin: plugin, enabled: true)] {
            XCTAssertNil(NativeLifecycleRegistration(provider: "fixture", sessionID: session, executionDomain: "fixture:24680:5:0",
                registryPath: nil, providerRegistry: try ProviderPluginRegistry([entry])))
        }
    }
    func testRegistryIdentityInspectionRemainsAvailableWithoutAutomaticClosureCapability() throws {
        try writeRegistry()
        let plugin = ClaudeProviderPlugin()
        let workOnly: Set<ProviderCapability> = [.workSession, .pickup, .correlatedReply]
        let registry = try ProviderPluginRegistry([.init(plugin: plugin, enabled: true, qualifiedCapabilities: workOnly)])
        let result = NativeLifecycleInspector.inspect(try registration(), providerRegistry: registry)
        XCTAssertEqual(result.process, .running)
        XCTAssertEqual(result.registry, .matching)
        XCTAssertFalse(result.provesClosure)
        let fixture = BridgeFixtureProviderPlugin(capabilities: [.workSession, .pickup, .correlatedReply, .registryClosure])
        let fixtureRegistry = try ProviderPluginRegistry([.init(plugin: fixture, enabled: true, qualifiedCapabilities: fixture.manifest.capabilities)])
        let fixtureRegistration = try XCTUnwrap(NativeLifecycleRegistration(provider: "fixture", sessionID: session,
            executionDomain: "fixture:24680:5:0", registryPath: self.registry.path, providerRegistry: fixtureRegistry))
        XCTAssertEqual(NativeLifecycleInspector.inspect(fixtureRegistration, providerRegistry: fixtureRegistry).registry, .unsupported)
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
        let peerOnly = try ProviderPluginRegistry([.init(plugin:ClaudeProviderPlugin(),enabled:true,
            qualifiedCapabilities:[.workSession,.pickup,.correlatedReply,.nativePeer])])
        _ = try NativeProviderTransport.send(provider:"claude",content:"Synthetic peer identity with closure disabled",messageID:"cl128-peer",
            replyAddress:"uds:/tmp/cl128-reply.sock",displayName:"Component fixture",endpoint:endpoint,
            expectedPeerPID:getpid(),expectedRegistration:original,timeout:1,registry:peerOnly)
        XCTAssertGreaterThan(receivedByteCount(),0)

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
