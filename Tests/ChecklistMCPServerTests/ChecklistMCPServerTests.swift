import XCTest
import Darwin
import MCP
import Logging
import ChecklistIPC
@testable import ChecklistBridges
@testable import ChecklistMCPServer

final class ChecklistMCPServerTests: XCTestCase {
    private final class Fixture: @unchecked Sendable {
        let context: NativeSessionContext
        private let lock = NSRecursiveLock()
        private var discoveries: [NativeSessionDiscovery] = [.claudeRegistryNotReady(.absent)]
        private var elapsed: TimeInterval = 0
        private var clients: [BridgeClientConfiguration] = []
        private var requests: [(String, Int)] = []
        private var bootstraps: [(TimeInterval, TimeInterval?)] = []
        private var stderrLines: [String] = []
        var bootstrapHandler: ((TimeInterval?) throws -> Void)?

        init(provider: String = "claude") throws {
            let session = "a85c9a24-fce8-49ba-a738-67594bb90a67"
            let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.resolvingSymlinksInPath().path
            context = try XCTUnwrap(NativeSessionContext.observed(provider: provider,
                environment: ["CLAUDE_SESSION_ID": session, "CODEX_THREAD_ID": session], currentDirectory: workspace))
        }

        private func locked<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock(); defer { lock.unlock() }; return try body()
        }
        func setDiscoveries(_ values: [NativeSessionDiscovery]) { locked { discoveries = values } }
        func advance(_ value: TimeInterval) { locked { elapsed += value } }
        var time: TimeInterval { locked { elapsed } }
        var attempts: [(TimeInterval, TimeInterval?)] { locked { bootstraps } }
        var stderr: [String] { locked { stderrLines } }
        var calls: [(String, BridgeClientConfiguration)] { locked { requests.map { ($0.0, clients[$0.1]) } } }

        var environment: BridgeEnvironment {
            .init(makeClient: { configuration in
                self.locked {
                    let index = self.clients.count; self.clients.append(configuration)
                    return FakeClient(fixture: self, index: index)
                }
            }, discover: { _ in
                self.locked {
                    if self.discoveries.count > 1 { return self.discoveries.removeFirst() }
                    return self.discoveries[0]
                }
            }, now: { self.time }, sleep: { self.advance($0) }, stderr: { line in
                self.locked { self.stderrLines.append(line) }
            })
        }

        func bootstrap(_ budget: TimeInterval?) throws -> [String: Any] {
            try locked {
                bootstraps.append((elapsed, budget))
                try bootstrapHandler?(budget)
                return ["data": ["installation": "synthetic-thread", "project_id": "synthetic-project",
                                 "session_id": context.nativeSessionID, "connected": true]]
            }
        }

        func call(_ name: String, client: Int) throws -> [String: Any] {
            locked {
                requests.append((name, client))
                if name == "tool_catalog" {
                    return ["data": ["tools": ["service_info", "task_list", "project_list"].map {
                        ["name": $0, "description": "Synthetic " + $0,
                         "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]] as [String: Any]
                    }]]
                }
                if name == "service_info" { return ["data": ["service": "synthetic", "session_id": context.nativeSessionID]] }
                if name == "project_list" { return ["data": ["projects": [["id": "synthetic-project"]]]] }
                return ["data": ["tasks": [], "executed": name]]
            }
        }
    }

    private final class FakeClient: BridgeClient, @unchecked Sendable {
        let fixture: Fixture
        let index: Int
        init(fixture: Fixture, index: Int) { self.fixture = fixture; self.index = index }
        func bootstrap(_ nativeContext: [String: Any], timeBudget: TimeInterval?) throws -> [String: Any] {
            XCTAssertNil(nativeContext["credential"])
            return try fixture.bootstrap(timeBudget)
        }
        func call(_ method: String, _ params: [String: Any], replyTimeout: TimeInterval?) throws -> [String: Any] {
            try fixture.call(method, client: index)
        }
    }

    private actor ProtocolTransport: Transport {
        nonisolated let logger: Logger
        let base: InMemoryTransport
        private var sent: [Data] = []
        init(_ base: InMemoryTransport) { self.base = base; logger = base.logger }
        func connect() async throws { try await base.connect() }
        func disconnect() async { await base.disconnect() }
        func send(_ data: Data) async throws { sent.append(data); try await base.send(data) }
        func receive() -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await data in await base.receive() { continuation.yield(data) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        func frames() -> [Data] { sent }
    }

    private actor Notifications {
        var count = 0
        func record() { count += 1 }
    }

    private struct Session {
        let client: Client
        let transport: ProtocolTransport
        let initialization: Initialize.Result
        let notifications: Notifications
    }

    private func start(_ fixture: Fixture) async throws -> Session {
        let pair = await InMemoryTransport.createConnectedPair()
        let transport = ProtocolTransport(pair.server)
        let bridge = Bridge(configuration: .init(workspace: fixture.context.workspacePath), environment: fixture.environment)
        let server = try await ChecklistMCPServer.start(bridge: bridge, transport: transport)
        let client = Client(name: "CL-168 synthetic client", version: "1")
        let notifications = Notifications()
        await client.onNotification(ToolListChangedNotification.self) { _ in await notifications.record() }
        addTeardownBlock { await client.disconnect(); await server.stop() }
        let initialization = try await client.connect(transport: pair.client)
        return Session(client: client, transport: transport, initialization: initialization, notifications: notifications)
    }

    private func text(_ content: [Tool.Content]) -> String {
        content.compactMap { if case .text(let value, _, _) = $0 { return value }; return nil }.joined(separator: "\n")
    }

    private func assertProtocolOnly(_ session: Session, file: StaticString = #filePath, line: UInt = #line) async throws {
        for data in await session.transport.frames() {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
            XCTAssertEqual(object["jsonrpc"] as? String, "2.0", file: file, line: line)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("connected after"), file: file, line: line)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Startup wait ended after"), file: file, line: line)
        }
    }

    func testRegistryRaceStartsRealServerWithFullCatalogAndProtocolOnlyOutput() async throws {
        let fixture = try Fixture()
        fixture.setDiscoveries([.claudeRegistryNotReady(.absent), .claudeRegistryNotReady(.otherSession), .available(fixture.context)])
        let session = try await start(fixture)
        XCTAssertEqual(session.initialization.capabilities.tools?.listChanged, true)
        XCTAssertEqual(session.initialization.capabilities.resources?.listChanged, false)
        let tools = try await session.client.listTools()
        XCTAssertEqual(tools.tools.map(\.name), ["service_info", "task_list", "project_list"])
        try await session.client.ping()
        XCTAssertEqual(fixture.time, 0.5)
        XCTAssertEqual(fixture.attempts.count, 1)
        XCTAssertEqual(fixture.attempts[0].1, 15)
        XCTAssertEqual(fixture.stderr, ["Checklist: connected after 3 attempts in 500 ms; Claude's session registry was not ready at first (registry absent). Last reason: registry names another session.\n"])
        let count = await session.notifications.count
        XCTAssertEqual(count, 0)
        try await assertProtocolOnly(session)
    }

    func testDiagnosticsGoOnlyToInjectedStderrNotProcessStdout() async throws {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0 else {
            close(descriptors[0]); close(descriptors[1])
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var redirected = false
        defer {
            if redirected { fflush(stdout); dup2(saved, STDOUT_FILENO) }
            close(saved); close(descriptors[0])
            if descriptors[1] >= 0 { close(descriptors[1]) }
        }
        fflush(stdout)
        guard dup2(descriptors[1], STDOUT_FILENO) >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        redirected = true
        let fixture = try Fixture()
        fixture.setDiscoveries([.claudeRegistryNotReady(.absent), .available(fixture.context)])
        let session = try await start(fixture)
        _ = try await session.client.listTools()
        try await session.client.ping()
        fflush(stdout); dup2(saved, STDOUT_FILENO); redirected = false
        close(descriptors[1]); descriptors[1] = -1
        let bytes = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: false).readDataToEndOfFile()
        XCTAssertEqual(bytes, Data())
        XCTAssertEqual(fixture.stderr.count, 1)
        XCTAssertTrue(fixture.stderr[0].hasPrefix("Checklist: connected after 2 attempts"))
        try await assertProtocolOnly(session)
    }

    func testPersistentMismatchStartsLimitedAndNeverUsesStoredCredential() async throws {
        let fixture = try Fixture(), session = try await start(fixture)
        XCTAssertTrue(session.initialization.instructions?.contains("Not connected yet") == true)
        let tools = try await session.client.listTools()
        XCTAssertEqual(tools.tools.map(\.name), ["service_info"])
        XCTAssertTrue(tools.tools[0].description?.contains("NATIVE_SESSION_MISMATCH: " + ClaudeRegistryStart.registryMessage) == true)
        let denied = try await session.client.callTool(name: "task_list")
        XCTAssertEqual(denied.isError, true)
        XCTAssertTrue(text(denied.content).contains("NATIVE_SESSION_MISMATCH: " + ClaudeRegistryStart.registryMessage))
        let status = try await session.client.callTool(name: "service_info")
        XCTAssertEqual(status.isError, false)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(status.content).utf8)) as? [String: Any])
        let connection = (response["data"] as? [String: Any])?["connection"] as? [String: Any]
        XCTAssertEqual(connection?["connected"] as? Bool, false)
        XCTAssertEqual(connection?["state"] as? String, "claude_registry_not_ready")
        let resources = try await session.client.listResources()
        XCTAssertEqual(resources.resources.map(\.uri), ["checklist://service/status"])
        _ = try await session.client.readResource(uri: "checklist://service/status")
        try await session.client.ping()
        XCTAssertTrue(fixture.attempts.isEmpty)
        XCTAssertEqual(fixture.calls.map { $0.0 }, ["service_info", "service_info"])
        XCTAssertTrue(fixture.calls.allSatisfy { !$0.1.usesStoredCredential && $0.1.nativeContext == nil })
        XCTAssertTrue(fixture.stderr[0].contains("40 attempts in 10000 ms; last reason: registry absent"))
        try await assertProtocolOnly(session)
    }

    func testLazyRecoveryOnEachHandlerCompletesRequestAndNotifiesExactlyOnce() async throws {
        for method in ["tools/list", "tools/call", "resources/list", "resources/read"] {
            let fixture = try Fixture(), session = try await start(fixture)
            fixture.setDiscoveries([.available(fixture.context)])
            switch method {
            case "tools/list":
                let result = try await session.client.listTools()
                XCTAssertEqual(result.tools.count, 3)
            case "tools/call":
                let result = try await session.client.callTool(name: "task_list")
                XCTAssertEqual(result.isError, false)
                XCTAssertTrue(text(result.content).contains("task_list"))
            case "resources/list":
                let result = try await session.client.listResources()
                XCTAssertEqual(result.resources.count, 2)
            default:
                let result = try await session.client.readResource(uri: "checklist://projects")
                XCTAssertEqual(result.count, 1)
            }
            let tools = try await session.client.listTools()
            XCTAssertEqual(tools.tools.map(\.name), ["service_info", "task_list", "project_list"])
            try await session.client.ping()
            let count = await session.notifications.count
            XCTAssertEqual(count, 1, method)
            XCTAssertEqual(fixture.attempts.count, 1, method)
            XCTAssertNil(fixture.attempts[0].1, method)
            let frames = try await session.transport.frames().map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
            XCTAssertEqual(frames.filter { $0["method"] as? String == "notifications/tools/list_changed" }.count, 1, method)
            XCTAssertEqual(fixture.stderr.count, 2, method)
            XCTAssertTrue(fixture.stderr[1].contains("connected after 41 attempts in 10000 ms"), method)
            try await assertProtocolOnly(session)
        }
    }

    func testPermanentLazyFailureStaysVisibleWithoutAnotherBootstrapOrNotification() async throws {
        let fixture = try Fixture(), session = try await start(fixture)
        fixture.setDiscoveries([.available(fixture.context)])
        fixture.bootstrapHandler = { _ in throw ChecklistError("CONNECTION_REVOKED", "synthetic revocation") }
        let tools = try await session.client.listTools()
        XCTAssertEqual(tools.tools.map(\.name), ["service_info"])
        XCTAssertTrue(tools.tools[0].description?.contains("CONNECTION_REVOKED") == true)
        let denied = try await session.client.callTool(name: "task_list")
        XCTAssertEqual(denied.isError, true)
        XCTAssertTrue(text(denied.content).contains("CONNECTION_REVOKED"))
        try await session.client.ping()
        XCTAssertEqual(fixture.attempts.count, 1)
        let count = await session.notifications.count
        XCTAssertEqual(count, 0)
        XCTAssertTrue(fixture.calls.isEmpty)
    }

    func testSlowRetryBudgetReachesIPCSeamAndLazyAttemptKeepsDefault() async throws {
        let fixture = try Fixture()
        fixture.setDiscoveries([.available(fixture.context)])
        fixture.bootstrapHandler = { budget in
            if fixture.attempts.count <= 2 { fixture.advance(budget ?? 9) }
            throw ChecklistError(ClaudeRegistryStart.errorCode, ClaudeRegistryStart.registryMessage)
        }
        let session = try await start(fixture)
        XCTAssertEqual(fixture.time, 20)
        XCTAssertEqual(fixture.attempts.map { $0.0 }, [0, 9.25])
        XCTAssertNil(fixture.attempts[0].1)
        XCTAssertEqual(fixture.attempts[1].1, 10.75)
        let tools = try await session.client.listTools()
        XCTAssertEqual(tools.tools.map(\.name), ["service_info"])
        XCTAssertEqual(fixture.attempts.count, 3)
        XCTAssertNil(fixture.attempts[2].1)
        XCTAssertEqual(fixture.time, 20)
        XCTAssertTrue(fixture.stderr[0].contains("2 attempts in 20000 ms; last reason: service registry mismatch"))
    }

    func testStrictCommandsPropagateRegistryErrorAtWindowEnd() async throws {
        for command in ["tools", "call", "connect"] {
            let fixture = try Fixture()
            let bridge = Bridge(configuration: .init(workspace: fixture.context.workspacePath, command: command), environment: fixture.environment)
            do {
                _ = try await bridge.connect(required: command == "connect")
                XCTFail("Strict command must fail: \(command)")
            } catch {
                XCTAssertEqual(error.localizedDescription, "NATIVE_SESSION_MISMATCH: " + ClaudeRegistryStart.registryMessage)
            }
            XCTAssertEqual(fixture.time, 10)
            XCTAssertTrue(fixture.attempts.isEmpty)
            XCTAssertTrue(fixture.calls.isEmpty)
        }
    }

    func testCodexAndUnregisteredWorkspaceKeepTheirStartupRules() async throws {
        let codex = try Fixture(provider: "codex")
        codex.setDiscoveries([.available(codex.context)])
        codex.bootstrapHandler = { _ in throw ChecklistError(ClaudeRegistryStart.errorCode, ClaudeRegistryStart.registryMessage) }
        do { _ = try await start(codex); XCTFail("Codex must not retry") }
        catch { XCTAssertEqual((error as? ChecklistError)?.code, "NATIVE_SESSION_MISMATCH") }
        XCTAssertEqual(codex.attempts.count, 1); XCTAssertEqual(codex.time, 0)
        XCTAssertNil(codex.attempts[0].1)
        let unregistered = try Fixture()
        unregistered.setDiscoveries([.available(unregistered.context)])
        unregistered.bootstrapHandler = { _ in throw ChecklistError("PROJECT_SETUP_REQUIRED", "synthetic unregistered folder") }
        let session = try await start(unregistered)
        let tools = try await session.client.listTools()
        XCTAssertEqual(tools.tools.map(\.name), ["service_info"])
        XCTAssertTrue(tools.tools[0].description?.contains("PROJECT_SETUP_REQUIRED") == true)
        XCTAssertEqual(unregistered.attempts.count, 1); XCTAssertEqual(unregistered.time, 0)
        XCTAssertTrue(unregistered.stderr[0].contains("add this folder as a project"))
    }
}
