import XCTest
import Foundation
import MCP
import ChecklistIPC
@testable import ChecklistCore
@testable import ChecklistBridges
@testable import ChecklistMCPServer

/// CL-364: actual SDK tools/call frames, production MCP server and bridge, and real
/// operations on an owned router store and operation queue.
final class OperationWaitMCPTests: XCTestCase {
    private final class RouterClient: BridgeClient, @unchecked Sendable {
        let router: CommandRouter, session: String
        let caller = Caller(role: "owner", installation: "cl-364-mcp-owner", projectIDs: [])
        init(router: CommandRouter, session: String) { self.router = router; self.session = session }
        func bootstrap(_ nativeContext: [String: Any], timeBudget: TimeInterval?) throws -> [String: Any] {
            ["data": ["installation": "cl-364-fixture", "project_id": "none", "session_id": session, "connected": true]]
        }
        func call(_ method: String, _ params: [String: Any], replyTimeout: TimeInterval?) throws -> [String: Any] {
            do { return try router.handle(method: method, params: params, caller: caller) }
            catch let error as CoreError { throw ChecklistError(error.code, error.message, details: error.details) }
        }
    }

    private var root: URL!
    private var lane: DispatchQueue!
    private var client: Client!
    private var router: CommandRouter!

    override func setUp() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("operation-wait-mcp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = folder
        let context = try XCTUnwrap(NativeSessionContext.observed(provider: "codex", environment: ["CODEX_THREAD_ID": UUID().uuidString], currentDirectory: folder.path))
        let router = try CommandRouter(root: folder.appendingPathComponent("store")), lane = DispatchQueue(label: "cl-364-mcp-lane")
        router.configureCommandOperations(on: lane)
        self.router = router; self.lane = lane
        let routerClient = RouterClient(router: router, session: context.nativeSessionID)
        let bridge = Bridge(configuration: .init(workspace: folder.path), environment: .init(makeClient: { _ in routerClient }, discover: { _ in .available(context) }, stderr: { _ in }))
        let pair = await InMemoryTransport.createConnectedPair()
        let server = try await ChecklistMCPServer.start(bridge: bridge, transport: pair.server)
        let client = Client(name: "CL-364", version: "1")
        _ = try await client.connect(transport: pair.client)
        self.client = client
        addTeardownBlock { await client.disconnect(); await server.stop(); lane.sync {}; try? router.closeStore(); try? FileManager.default.removeItem(at: folder) }
    }

    private func text(_ reply: (content: [Tool.Content], isError: Bool?)) -> String {
        reply.content.compactMap { if case .text(let text, _, _) = $0 { return text }; return nil }.joined(separator: "\n")
    }

    private func envelope(_ reply: (content: [Tool.Content], isError: Bool?)) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(reply).utf8)) as? [String: Any], text(reply))
    }

    private func startBackup() async throws -> (operation: String, command: String) {
        let command = UUID().uuidString
        let reply = try await client.callTool(name: "backup_create", arguments: ["command_id": .string(command), "path": .string(root.appendingPathComponent("backup-" + command).path)])
        let object = try envelope(reply)
        XCTAssertEqual(object["command_outcome"] as? String, "accepted", text(reply))
        return (try XCTUnwrap((object["data"] as? [String: Any])?["operation_id"] as? String), command)
    }

    func testCatalogOffersTheWaitAndTheDescriptionsNameEveryOperationCommand() async throws {
        let tools = try await client.listTools().tools
        let wait = try XCTUnwrap(tools.first { $0.name == OperationWait.toolName })
        XCTAssertEqual(wait.annotations.readOnlyHint, true)
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(wait.inputSchema)) as? [String: Any])
        let seconds = try XCTUnwrap((schema["properties"] as? [String: Any])?["wait_seconds"] as? [String: Any])
        XCTAssertEqual(seconds["maximum"] as? Int, 45)
        let longCommands = CommandRouter.alwaysOperationMethods.union(CommandRouter.conditionalOperationMethods)
        var checked = 0
        for tool in tools where tool.name != OperationWait.toolName {
            let mentions = (tool.description ?? "").contains("call operation_wait with that ID")
            XCTAssertEqual(mentions, longCommands.contains(tool.name), tool.name)
            if mentions { checked += 1 }
        }
        XCTAssertGreaterThan(checked, 20)
        print("CL-364 catalog: \(checked) tool descriptions say the command can return an operation; \(tools.count) tools")
    }

    func testWaitBoundsReturnsStateThenFinalReplyAndOtherCallsContinue() async throws {
        lane.suspend()
        var held = true
        defer { if held { lane.resume() } }
        let backup = try await startBackup()
        let arguments: [String: Value] = ["operation_id": .string(backup.operation), "wait_seconds": .double(0.3)]

        let started = ProcessInfo.processInfo.systemUptime
        let unfinished = try await client.callTool(name: OperationWait.toolName, arguments: arguments)
        let bound = ProcessInfo.processInfo.systemUptime - started
        XCTAssertNotEqual(unfinished.isError, true, text(unfinished))
        let object = try envelope(unfinished), wait = try XCTUnwrap(object["wait"] as? [String: Any])
        XCTAssertEqual(wait["finished"] as? Bool, false)
        XCTAssertEqual(wait["state"] as? String, "queued")
        XCTAssertEqual((object["data"] as? [String: Any])?["operation_id"] as? String, backup.operation)
        XCTAssertLessThan(bound, 1.5)

        // A long wait does not hold other calls of this one shim.
        let long = Task { [client] in try await client!.callTool(name: OperationWait.toolName, arguments: ["operation_id": .string(backup.operation), "wait_seconds": .int(2)]) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let otherStarted = ProcessInfo.processInfo.systemUptime
        var slowest: TimeInterval = 0
        for _ in 0..<5 {
            let once = ProcessInfo.processInfo.systemUptime
            let info = try await client.callTool(name: "service_info", arguments: [:])
            XCTAssertNotEqual(info.isError, true, text(info))
            slowest = max(slowest, ProcessInfo.processInfo.systemUptime - once)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - otherStarted, 1.5, "Five service_info calls finish well inside the 2 s wait")
        let longReply = try await long.value
        XCTAssertEqual((try envelope(longReply)["wait"] as? [String: Any])?["finished"] as? Bool, false)
        print("CL-364 other calls during a 2 s wait: slowest service_info \(Int(slowest * 1000)) ms")

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [lane] in lane!.resume() }
        held = false
        let final = try await client.callTool(name: OperationWait.toolName, arguments: ["operation_id": .string(backup.operation)])
        XCTAssertNotEqual(final.isError, true, text(final))
        let finished = try envelope(final)
        XCTAssertNil(finished["wait"])
        XCTAssertEqual(finished["command_id"] as? String, backup.command)
        XCTAssertEqual((finished["data"] as? [String: Any])?["status"] as? String, "complete", text(final))
    }

    func testFailedOperationIsAToolErrorWithItsOwnCode() async throws {
        let project = try router.handle(method: "project_create", params: ["command_id": UUID().uuidString, "name": "CL-364 MCP fixture", "key_prefix": "WAIT", "root_path": root.path], caller: Caller(role: "owner", installation: "cl-364-mcp-owner", projectIDs: []))
        let projectID = try XCTUnwrap((project["data"] as? [String: Any])?["id"] as? String)
        // Acceptance runs no domain check, so the missing ticket fails on the operation queue.
        let accepted = try await client.callTool(name: "task_purge_preview", arguments: ["command_id": .string(UUID().uuidString), "project_id": .string(projectID), "task_id": .string(UUID().uuidString)])
        let receipt = try envelope(accepted)
        XCTAssertEqual(receipt["command_outcome"] as? String, "accepted", text(accepted))
        let id = try XCTUnwrap((receipt["data"] as? [String: Any])?["operation_id"] as? String, text(accepted))
        let reply = try await client.callTool(name: OperationWait.toolName, arguments: ["operation_id": .string(id), "project_id": .string(projectID)])
        XCTAssertEqual(reply.isError, true, text(reply))
        XCTAssertTrue(text(reply).contains("NOT_FOUND"), text(reply))
        print("CL-364 failed operation over MCP: \(text(reply))")
    }

    func testInvalidInputAndUnknownOperationAreRefusedAtOnce() async throws {
        for (arguments, expected) in [(["operation_id": Value.string("nope")], "INVALID_INPUT"),
                                      (["operation_id": .string(UUID().uuidString), "extra": .bool(true)], "INVALID_INPUT"),
                                      (["operation_id": .string(UUID().uuidString), "wait_seconds": .int(-1)], "INVALID_INPUT"),
                                      (["operation_id": .string(UUID().uuidString)], "NOT_FOUND")] as [([String: Value], String)] {
            let started = ProcessInfo.processInfo.systemUptime
            let reply = try await client.callTool(name: OperationWait.toolName, arguments: arguments)
            XCTAssertEqual(reply.isError, true, text(reply))
            XCTAssertTrue(text(reply).contains(expected), text(reply))
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        }
    }

    func testToolLimitsStayBelowTheClientLimitWithAVirtualClock() async throws {
        func refuse(_ message: String) -> ChecklistError { ChecklistError("INVALID_INPUT", message) }
        XCTAssertEqual(try OperationWait.toolSeconds(nil, refuse), 45)
        XCTAssertEqual(try OperationWait.toolSeconds(.int(999), refuse), 45)
        XCTAssertEqual(try OperationWait.toolSeconds(.double(1.5), refuse), 1.5)
        XCTAssertLessThan(OperationWait.toolCallLimit, 60)

        final class Time: @unchecked Sendable {
            let lock = NSLock(); var now: TimeInterval = 0; var reads = 0
            func advance(_ by: TimeInterval) { lock.lock(); now += by; lock.unlock() }
            func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return now }
            func countRead() { lock.lock(); reads += 1; lock.unlock() }
        }
        let time = Time()
        let id = UUID().uuidString
        let reply = try await OperationWait.read(statusMethod: "operation_get", known: nil, identity: ["operation_id": id], limit: 45,
            clock: .init(now: { time.read() }, sleep: { time.advance($0) })) { budget in
                XCTAssertLessThanOrEqual(budget, 45)
                time.countRead()
                return .object(["data": .object(["operation_id": .string(id), "state": .string("running")])])
            }
        XCTAssertTrue(OperationWait.isUnfinished(reply))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any])
        let wait = try XCTUnwrap(object["wait"] as? [String: Any])
        XCTAssertEqual(wait["waited_ms"] as? Int, 45_000)
        XCTAssertEqual(wait["limit_seconds"] as? Double ?? Double(wait["limit_seconds"] as? Int ?? 0), 45)
        // 0.1 s doubling to 2 s between reads: 27 reads measured, not one per millisecond.
        XCTAssertLessThan(time.reads, 30)
        print("CL-364 45 s virtual wait: \(time.reads) reads")
    }

    // A replaced shim reads through the installed CLI child, one call per read.
    func testReplacedShimWaitsThroughTheInstalledCLI() async throws {
        final class Runs: @unchecked Sendable {
            let lock = NSLock(); var routes: [[String]] = []
            func add(_ route: [String]) -> Int { lock.lock(); defer { lock.unlock() }; routes.append(route); return routes.filter { $0.first == "call" }.count }
        }
        let runs = Runs(), id = UUID().uuidString
        let update = ShimUpdateEnvironment(launchPath: "/synthetic/checklist", check: { _ in .replaced }, run: { arguments, _ in
            if arguments.first == "tools" {
                _ = runs.add(arguments)
                return .init(status: 0, stdout: Data(#"{"tools":[{"name":"operation_get","description":"d","inputSchema":{"type":"object"}}]}"#.utf8))
            }
            let count = runs.add(arguments)
            let state = count < 3 ? #"{"data":{"state":"running"}}"# : #"{"data":{"state":"succeeded","result":{"data":{"delegated":true}}}}"#
            return .init(status: 0, stdout: Data(state.utf8))
        })
        let bridge = Bridge(configuration: .init(workspace: root.path), environment: .init(shimUpdate: update, makeClient: { [router] _ in RouterClient(router: router!, session: "unused") }, discover: { _ in .unavailable }, stderr: { _ in }))
        _ = try await bridge.connect()
        let reply = try await bridge.concurrentCall(OperationWait.toolName, .object(["operation_id": .string(id), "project_id": .string("p")]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any])
        XCTAssertEqual((object["data"] as? [String: Any])?["delegated"] as? Bool, true)
        XCTAssertEqual(runs.routes.filter { $0.prefix(2) == ["call", "operation_get"] }.count, 3)
        XCTAssertFalse(runs.routes.contains { $0.contains(OperationWait.toolName) })
        let tools = try await bridge.tools()
        XCTAssertEqual(tools.map(\.name), ["operation_get", OperationWait.toolName])
    }

    func testBoundedReturnsAtItsLimitWhileTheWorkStillRuns() async throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let _: Value = try await OperationWait.bounded(0.2) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async { release.wait(); continuation.resume() }
                }
                return .null
            }
            XCTFail("The limit ends the wait")
        } catch is OperationWait.LimitExpired {}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
    }
}
