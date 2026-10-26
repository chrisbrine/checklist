import XCTest
import Darwin
import MCP
import Logging
import ChecklistIPC
import GRDB
@testable import ChecklistCore
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
        var responseText: String?
        var responseData: [String:Any]?
        var callHandler: ((String) throws -> Void)?
        var requestHandler: ((String, [String:Any]) throws -> [String:Any])?
        var unregisteredWorkspace = false
        var projectCreationEnabled = false

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
                if unregisteredWorkspace {
                    return ["data":["connected":false,"state":"project_setup_required","native_context_verified":true,
                                    "workspace":context.workspacePath,"provider":context.provider,"session_id":context.nativeSessionID]]
                }
                return ["data": ["installation": "synthetic-thread", "project_id": "synthetic-project",
                                 "session_id": context.nativeSessionID, "connected": true]]
            }
        }

        func call(_ name: String, params: [String:Any], client: Int) throws -> [String: Any] {
            try locked {
                requests.append((name, client))
                try callHandler?(name)
                if let requestHandler { return try requestHandler(name,params) }
                if name == "project_create",projectCreationEnabled {
                    unregisteredWorkspace=false
                    return ["data":["id":"synthetic-project","root_path":context.workspacePath]]
                }
                if name == "tool_catalog" {
                    let names=["service_info","task_list","project_list"] + (projectCreationEnabled ? ["project_create"] : [])
                    return ["data": ["tools": names.map {
                        ["name": $0, "description": "Synthetic " + $0,
                         "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]] as [String: Any]
                    }]]
                }
                if let responseData { return ["data":responseData] }
                if let responseText { return ["data": ["text": responseText, responseText: responseText]] }
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
            try fixture.call(method, params: params, client: index)
        }
    }

    func testBridgeBlockingIPCUsesDedicatedDispatchExecutor() async throws {
        let fixture = try Fixture(provider: "codex")
        fixture.setDiscoveries([.available(fixture.context)])
        let bridge = Bridge(configuration: .init(workspace: fixture.context.workspacePath, command: "call"),
                            environment: fixture.environment)
        let queue = bridge.blockingExecutor.queue
        fixture.bootstrapHandler = { _ in
            dispatchPrecondition(condition: .onQueue(queue))
        }
        _ = try await bridge.connect()

        let entered = expectation(description: "synchronous client is waiting")
        let release = DispatchSemaphore(value: 0)
        fixture.callHandler = { _ in
            dispatchPrecondition(condition: .onQueue(queue))
            entered.fulfill()
            // This is only a deadlock escape, not a performance threshold.
            XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
        }
        let request = Task { try await bridge.serviceInfo() }
        await fulfillment(of: [entered], timeout: 10)
        // A separate Swift task must progress while the client's synchronous
        // operation remains blocked. It is the only successful release path.
        _ = await Task.detached { release.signal() }.value
        _ = try await request.value
    }

    func testDirectCLICommandsSkipCatalogAndPreserveServiceRefusals() async throws {
        let fixture = try Fixture(provider:"codex")
        fixture.setDiscoveries([.available(fixture.context)])
        let bridge = Bridge(configuration:.init(workspace:fixture.context.workspacePath,command:"call"),environment:fixture.environment)
        _ = try await bridge.connect()
        for method in ["message_send","task_get","unknown_method"] {
            fixture.requestHandler = { name,params in
                XCTAssertEqual(name,method)
                XCTAssertEqual(params["unexpected"] as? String,"service validates exact input")
                throw ChecklistError("FORBIDDEN","Current service grant refusal")
            }
            do { _ = try await bridge.call(method,.object(["unexpected":.string("service validates exact input")]));XCTFail("Service refusal must survive") }
            catch let error as ChecklistError {XCTAssertEqual(error.code,"FORBIDDEN")}
        }
        XCTAssertEqual(fixture.calls.map {$0.0},["message_send","task_get","unknown_method"])
        XCTAssertEqual(fixture.attempts.count,1)
        XCTAssertTrue(fixture.calls.allSatisfy {$0.1.nativeContext?["native_session_id"] as? String == fixture.context.nativeSessionID})
    }

    func testDirectCLIServiceInfoSkipsCatalogAndForwardsExactParameters() async throws {
        let fixture = try Fixture(provider:"codex")
        fixture.setDiscoveries([.available(fixture.context)])
        fixture.requestHandler = { name,params in
            XCTAssertEqual(name,"service_info","The direct CLI status read needs no catalog preflight")
            XCTAssertEqual(params["unexpected"] as? String,"preserve for service validation")
            return ["data":["build_id":"current-service"],"_checklist_timing":["total_ms":1.5]]
        }
        let bridge = Bridge(configuration:.init(workspace:fixture.context.workspacePath,command:"call"),environment:fixture.environment)
        _ = try await bridge.connect()
        try await bridge.verifySession()
        let reply = try await bridge.call("service_info",.object(["unexpected":.string("preserve for service validation")]))
        let object = try XCTUnwrap(try jsonObject(reply) as? [String:Any])
        XCTAssertEqual((object["data"] as? [String:Any])?["build_id"] as? String,"current-service")
        XCTAssertEqual((object["_checklist_timing"] as? [String:Any])?["total_ms"] as? Double,1.5)
        XCTAssertEqual(fixture.calls.map { $0.0 },["service_info"])
        XCTAssertEqual(fixture.attempts.count,1)
        XCTAssertEqual(fixture.calls.first?.1.nativeContext?["native_session_id"] as? String,fixture.context.nativeSessionID)
    }

    func testDirectCLIServiceInfoPreservesFreshServiceIdentityAndRevocationErrors() async throws {
        let fixture = try Fixture(provider:"codex")
        fixture.setDiscoveries([.available(fixture.context)])
        let bridge = Bridge(configuration:.init(workspace:fixture.context.workspacePath,command:"call"),environment:fixture.environment)
        _ = try await bridge.connect()
        _ = try await bridge.call("service_info",.object([:]))
        for code in ["CONNECTION_REVOKED","NATIVE_SESSION_REQUIRED","CONNECTION_REPAIR_REQUIRED","INVALID_INPUT","CLIENT_OUTDATED"] {
            fixture.callHandler = { name in
                XCTAssertEqual(name,"service_info")
                throw ChecklistError(code,"Synthetic current service refusal")
            }
            do { _ = try await bridge.call("service_info",.object([:])); XCTFail("Must preserve \(code)") }
            catch let error as ChecklistError { XCTAssertEqual(error.code,code) }
        }
        XCTAssertEqual(fixture.calls.map {$0.0},Array(repeating:"service_info",count:6))
    }

    func testDirectCLIServiceInfoKeepsExpectedSessionVerification() async throws {
        let fixture = try Fixture(provider:"codex")
        fixture.setDiscoveries([.available(fixture.context)])
        let bridge = Bridge(configuration:.init(workspace:fixture.context.workspacePath,expectedSession:"different-session",command:"call"),environment:fixture.environment)
        _ = try await bridge.connect()
        do { try await bridge.verifySession(); XCTFail("An expected-session mismatch must still stop the CLI") }
        catch { XCTAssertTrue(error.localizedDescription.contains("SESSION_MISMATCH")) }
        XCTAssertEqual(fixture.calls.map {$0.0},["service_info"])
    }

    func testDirectCLIServiceInfoKeepsLimitedWorkspaceNoticeAndOtherMethodGuard() async throws {
        let fixture = try Fixture(provider:"codex")
        fixture.setDiscoveries([.available(fixture.context)])
        fixture.unregisteredWorkspace = true
        let bridge = Bridge(configuration:.init(workspace:fixture.context.workspacePath,command:"call"),environment:fixture.environment)
        _ = try await bridge.connect()
        let reply = try await bridge.call("service_info",.object([:]))
        let object = try XCTUnwrap(try jsonObject(reply) as? [String:Any])
        let connection = (object["data"] as? [String:Any])?["connection"] as? [String:Any]
        XCTAssertEqual(connection?["connected"] as? Bool,false)
        XCTAssertEqual(connection?["state"] as? String,"project_setup_required")
        do { _ = try await bridge.call("task_list",.object([:])); XCTFail("Limited setup cannot expose other methods") }
        catch { XCTAssertTrue(error.localizedDescription.contains("METHOD_UNAVAILABLE")) }
        XCTAssertEqual(fixture.calls.map {$0.0},["service_info"])
    }

    func testMCPCatalogRefreshAndDirectCLIServiceValidation() async throws {
        for (command,method) in [("mcp","service_info"),("call","task_list")] {
            let fixture = try Fixture(provider:"codex")
            fixture.setDiscoveries([.available(fixture.context)])
            let bridge = Bridge(configuration:.init(workspace:fixture.context.workspacePath,command:command),environment:fixture.environment)
            _ = try await bridge.connect()
            _ = try await bridge.call(method,.object([:]))
            XCTAssertEqual(fixture.calls.map {$0.0},command == "call" ? [method] : ["tool_catalog",method])
        }
    }

    func testProjectArchiveReasonsThroughMCPHistorySelector() async throws {
        try await assertProjectArchiveReason("  MCP reason: café\nSecond line.  ")
    }
    func testProjectArchiveMissingReasonThroughMCPHistorySelector() async throws {
        try await assertProjectArchiveReason(nil)
    }
    func testProjectArchiveEmptyReasonThroughMCPHistorySelector() async throws {
        try await assertProjectArchiveReason("")
    }
    func testProjectArchiveWhitespaceReasonThroughMCPHistorySelector() async throws {
        try await assertProjectArchiveReason(" \n\t")
    }
    private func assertProjectArchiveReason(_ reason: String?) async throws {
        let fixture = try Fixture()
        fixture.setDiscoveries([.available(fixture.context)])
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("checklist-project-history-" + UUID().uuidString)
        let router = try CommandRouter(root:root)
        defer { try? router.closeStore();try? FileManager.default.removeItem(at:root) }
        let owner = Caller(role:"owner",installation:"synthetic-owner",projectIDs:[])
        func call(_ method: String,_ params: [String:Any]) throws -> [String:Any] {
            var params = params
            if !CommandRouter.readMethods.contains(method) {params["command_id"] = UUID().uuidString}
            return try router.handle(method:method,params:params,caller:owner)["data"] as! [String:Any]
        }
        let project = try call("project_create",["name":"Synthetic MCP project history","key_prefix":"HIS","root_path":fixture.context.workspacePath]),pid = project["id"] as! String
        _ = try call("session_register",["project_id":pid,"session_id":fixture.context.nativeSessionID,"provider":"claude","role":"worker"])
        let agent = Caller(role:"worker",installation:"synthetic-agent",projectIDs:[pid],sessionID:fixture.context.nativeSessionID,workspace:fixture.context.workspacePath)
        fixture.requestHandler = { method,params in
            do {return try router.handle(method:method,params:params,caller:agent)}
            catch let error as CoreError {throw ChecklistError(error.code,error.message,details:error.details)}
        }
        let session = try await start(fixture)
        let tools = try await session.client.listTools()
        let tool = try XCTUnwrap(tools.tools.first {$0.name == "history_list"})
        let schema = try JSONSerialization.jsonObject(with:JSONEncoder().encode(tool.inputSchema)) as! [String:Any]
        XCTAssertEqual(((schema["properties"] as? [String:Any])?["entity"] as? [String:Any])?["enum"] as? [String],["project","backup"])
        do {
            for archived in [true,false] {
                let current = try call("project_settings_get",["project_id":pid])
                var arguments: [String:MCP.Value] = ["project_id":.string(pid),"expected_revision":.int(current["revision"] as! Int),"archived":.bool(archived),"command_id":.string(UUID().uuidString)]
                if let reason {arguments["reason"] = .string(reason)}
                let changed = try await session.client.callTool(name:"project_archive",arguments:arguments)
                XCTAssertFalse(changed.isError ?? false)
                let reply = try await session.client.callTool(name:"history_list",arguments:["project_id":.string(pid),"entity":.string("project")])
                XCTAssertFalse(reply.isError ?? false)
                let envelope = try JSONSerialization.jsonObject(with:Data(text(reply.content).utf8)) as! [String:Any]
                let events = (envelope["data"] as! [String:Any])["events"] as! [[String:Any]]
                let event = try XCTUnwrap(events.last {$0["kind"] as? String == "project_updated"})
                let data = try XCTUnwrap(event["data"] as? [String:Any])
                XCTAssertEqual(data["reason"] as? String,reason.flatMap {$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil : $0})
                XCTAssertEqual(data["origin"] as? String,"agent")
                XCTAssertEqual(event["actor"] as? String,agent.principal)
                XCTAssertEqual((event["subject"] as? [String:Any])?["id"] as? String,pid)
            }
        }
        for selectors: [String:MCP.Value] in [[:],["entity":.string("task")],["entity":.string("project"),"task_id":.string("unused")]] {
            var arguments = selectors;arguments["project_id"] = .string(pid)
            let reply = try await session.client.callTool(name:"history_list",arguments:arguments)
            XCTAssertTrue(reply.isError ?? false)
        }
        try await assertProtocolOnly(session)
    }

    func testEpicDeleteThroughMCPActiveArchivedMembershipRefusalsAndRetainedRows() async throws {
        let fixture = try Fixture()
        fixture.setDiscoveries([.available(fixture.context)])
        let root = try FileManager.default.url(for:.cachesDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            .appendingPathComponent("ChecklistQualification/CL-245-MCP-" + UUID().uuidString)
        let router = try CommandRouter(root:root)
        defer { try? router.closeStore();try? FileManager.default.removeItem(at:root) }
        let owner = Caller(role:"owner",installation:"synthetic-owner",projectIDs:[])
        func call(_ method: String,_ params: [String:Any]) throws -> [String:Any] {
            var params = params
            if !CommandRouter.readMethods.contains(method) {params["command_id"] = UUID().uuidString}
            return try router.handle(method:method,params:params,caller:owner)["data"] as! [String:Any]
        }
        let project = try call("project_create",["name":"Synthetic MCP delete","key_prefix":"DEL","root_path":fixture.context.workspacePath]),pid = project["id"] as! String
        _ = try call("session_register",["project_id":pid,"session_id":fixture.context.nativeSessionID,"provider":"claude","role":"worker"])
        let agent = Caller(role:"worker",installation:"synthetic-agent",projectIDs:[pid],sessionID:fixture.context.nativeSessionID,workspace:fixture.context.workspacePath)
        fixture.requestHandler = { method,params in
            do {return try router.handle(method:method,params:params,caller:agent)}
            catch let error as CoreError {throw ChecklistError(error.code,error.message,details:error.details)}
        }
        let session = try await start(fixture)
        let tools = try await session.client.listTools()
        let tool = try XCTUnwrap(tools.tools.first {$0.name == "epic_delete"})
        let schema = try JSONSerialization.jsonObject(with:JSONEncoder().encode(tool.inputSchema)) as! [String:Any]
        XCTAssertTrue(Set(schema["required"] as! [String]).isSuperset(of:["epic_id","expected_revision","project_id","command_id"]))
        for archived in [false,true] {
            var epic = try call("epic_create",["project_id":pid,"name":"Mistake"])
            if archived {epic = try call("epic_edit",["project_id":pid,"epic_id":epic["id"]!,"expected_revision":epic["revision"]!,"archived":true])}
            let gid = epic["id"] as! String
            func retainedRows() throws -> [String] {
                try router.dbQueue.read { db in
                    try Row.fetchAll(db,sql:"SELECT rowid,hex(CAST(data AS BLOB)) AS bytes FROM records WHERE id != ? ORDER BY rowid",arguments:[gid]).map {String($0["rowid"] as Int64) + ":" + ($0["bytes"] as String)}
                }
            }
            let before = try retainedRows()
            let result = try await session.client.callTool(name:"epic_delete",arguments:["project_id":.string(pid),"epic_id":.string(gid),"expected_revision":.int(epic["revision"] as! Int),"command_id":.string(UUID().uuidString)])
            XCTAssertFalse(result.isError ?? false)
            let envelope = try JSONSerialization.jsonObject(with:Data(text(result.content).utf8)) as! [String:Any]
            let data = envelope["data"] as! [String:Any]
            XCTAssertEqual(data["deleted"] as? Bool,true);XCTAssertEqual(data["origin"] as? String,"agent")
            XCTAssertEqual(try retainedRows(),before)
        }
        let epic = try call("epic_create",["project_id":pid,"name":"Used"]),gid = epic["id"] as! String
        let destination = try call("epic_create",["project_id":pid,"name":"Destination"])
        let task = try call("task_create",["project_id":pid,"title":"Member","epic_id":gid])
        for historical in [false,true] {
            if historical {_ = try call("task_bulk_edit",["project_id":pid,"tasks":[["task_id":task["id"]!,"expected_revision":task["revision"]!]],"changes":["kind":"epic","epic_id":destination["id"]!],"preview":false])}
            let group = (try call("epic_list",["project_id":pid,"key":epic["key"]!])["groups"] as! [[String:Any]])[0]
            let before = try await router.dbQueue.read {try SchemaMigrations.contentFingerprint($0)}
            let result = try await session.client.callTool(name:"epic_delete",arguments:["project_id":.string(pid),"epic_id":.string(gid),"expected_revision":.int(group["revision"] as! Int),"command_id":.string(UUID().uuidString)])
            XCTAssertTrue(result.isError ?? false)
            let frames = try await session.transport.frames().map {try JSONSerialization.jsonObject(with:$0) as! [String:Any]}
            let error = try XCTUnwrap((frames.last?["result"] as? [String:Any])?["structuredContent"] as? [String:Any])
            XCTAssertEqual((error["error"] as! [String:Any])["code"] as? String,historical ? "EPIC_HELD_TICKETS":"EPIC_HAS_TICKETS")
            let after = try await router.dbQueue.read {try SchemaMigrations.contentFingerprint($0)}
            XCTAssertEqual(after,before)
        }
        try await assertProtocolOnly(session)
    }

    func testNativeSessionRequiredNamesExactReconnectAndDoesNotReplay() async throws {
        let fixture = try Fixture(provider:"codex")
        fixture.setDiscoveries([.available(fixture.context)])
        let bridge = Bridge(configuration:.init(workspace:fixture.context.workspacePath),environment:fixture.environment)
        _ = try await bridge.connect(required:true)
        fixture.callHandler = { name in if name == "task_list" {throw ChecklistError("NATIVE_SESSION_REQUIRED","old native binding")} }
        do {
            _ = try await bridge.call("task_list",.object(["project_id":.string("synthetic-project")]))
            XCTFail("Expected reconnect guidance")
        } catch let error as ChecklistError {
            XCTAssertEqual(error.code,"NATIVE_SESSION_REQUIRED")
            XCTAssertTrue(error.message.contains("/Applications/Checklist.app/Contents/MacOS/checklist mcp"))
            XCTAssertTrue(error.message.contains("original command_id"))
        }
        XCTAssertEqual(fixture.calls.filter {$0.0 == "task_list"}.count,1)
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

    private func start(_ fixture: Fixture, update: ShimUpdateEnvironment? = nil, configuration: BridgeConfiguration? = nil) async throws -> Session {
        let pair = await InMemoryTransport.createConnectedPair()
        let transport = ProtocolTransport(pair.server)
        var environment = fixture.environment
        environment.shimUpdate = update
        let bridge = Bridge(configuration: configuration ?? .init(workspace: fixture.context.workspacePath), environment: environment)
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

    func testStatusReasonShapeSurvivesMCPToolAndResourceAndClears() async throws {
        let fixture = try Fixture()
        fixture.setDiscoveries([.available(fixture.context)])
        let session = try await start(fixture)
        for reason: [String:Any]? in [["text":"Waiting for the build.\nFull reason", "actor":"verified:worker", "actor_display":"Reviewer", "at":"2026-10-22T21:00:00Z"], nil] {
            var ticket: [String:Any] = ["id":"ticket", "status_category":reason == nil ? "queued":"blocked"]
            ticket["status_reason"] = reason
            fixture.responseData = ["tasks":[ticket]]
            let tool = try await session.client.callTool(name:"task_list")
            let resource = try await session.client.readResource(uri:"checklist://service/status")
            for json in [text(tool.content), try XCTUnwrap(resource.first?.text)] {
                let envelope = try JSONSerialization.jsonObject(with:Data(json.utf8)) as! [String:Any]
                let received = ((envelope["data"] as! [String:Any])["tasks"] as! [[String:Any]])[0]
                XCTAssertEqual((received["status_reason"] as? NSDictionary),reason.map { $0 as NSDictionary })
            }
        }
    }

    func testControlCharactersRemainStrictJSONInToolResourceAndProtocolOutput() async throws {
        let fixture = try Fixture()
        fixture.setDiscoveries([.available(fixture.context)])
        let session = try await start(fixture)
        let controls = String(String.UnicodeScalarView((0...31).map { UnicodeScalar($0)! }))
        fixture.responseText = controls + "quote \" slash / backslash \\ é🧪"
        let tool = try await session.client.callTool(name: "task_list")
        XCTAssertEqual(tool.isError, false)
        let toolJSON = text(tool.content)
        let resource = try await session.client.readResource(uri: "checklist://service/status")
        let resourceJSON = try XCTUnwrap(resource.first?.text)
        for json in [toolJSON, resourceJSON] {
            let result = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            XCTAssertEqual((result["data"] as? [String: String])?["text"], fixture.responseText)
        }
        let frames = await session.transport.frames().map { String(decoding: $0, as: UTF8.self) }
        let process = Process(), input = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import json,sys; [json.loads(frame) for frame in json.load(sys.stdin)]"]
        process.standardInput = input; process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: frames + [toolJSON, resourceJSON]))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
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

    func testVerifiedUnregisteredWorkspaceCreatesAndRefreshesSameMCPConnectionOnce() async throws {
        for provider in ["codex","claude"] {
            let fixture=try Fixture(provider:provider)
            fixture.setDiscoveries([.available(fixture.context)])
            fixture.unregisteredWorkspace=true;fixture.projectCreationEnabled=true
            let session=try await start(fixture)
            let limited=try await session.client.listTools()
            XCTAssertEqual(limited.tools.map(\.name),["service_info","project_create"])
            XCTAssertTrue(limited.tools[1].description?.contains("own folder") == true)
            let unavailable=try await session.client.callTool(name:"task_list")
            XCTAssertEqual(unavailable.isError,true)
            XCTAssertFalse(fixture.calls.contains{$0.0 == "tool_catalog"})
            let created=try await session.client.callTool(name:"project_create",arguments:[
                "command_id":.string(UUID().uuidString),"name":.string("Synthetic"),"key_prefix":.string("SYN")])
            XCTAssertEqual(created.isError,false)
            XCTAssertTrue(text(created.content).contains("synthetic-project"))
            XCTAssertEqual(fixture.attempts.count,2)
            let createClient=try XCTUnwrap(fixture.calls.first{$0.0 == "project_create"}?.1)
            XCTAssertFalse(createClient.usesStoredCredential)
            XCTAssertEqual(createClient.nativeContext?["native_session_id"] as? String,fixture.context.nativeSessionID)
            XCTAssertEqual(createClient.workspace,fixture.context.workspacePath)
            let full=try await session.client.listTools()
            XCTAssertTrue(full.tools.contains{$0.name == "task_list"})
            let task=try await session.client.callTool(name:"task_list")
            XCTAssertEqual(task.isError,false)
            let taskClient=try XCTUnwrap(fixture.calls.last{$0.0 == "task_list"}?.1)
            XCTAssertTrue(taskClient.usesStoredCredential)
            XCTAssertEqual(taskClient.installation,"synthetic-thread")
            let frames=try await session.transport.frames().map{try JSONSerialization.jsonObject(with:$0) as! [String:Any]}
            XCTAssertEqual(frames.filter{$0["method"] as? String == "notifications/tools/list_changed"}.count,1)
        }
    }

    func testClaudeRegistryRecoveryInUnregisteredWorkspaceAdvertisesCreationOnce() async throws {
        let fixture=try Fixture(provider:"claude")
        fixture.unregisteredWorkspace=true;fixture.projectCreationEnabled=true
        let session=try await start(fixture)
        let initial=try await session.client.listTools()
        XCTAssertEqual(initial.tools.map(\.name),["service_info"])
        fixture.setDiscoveries([.available(fixture.context)])
        // Recover through a status call so a cached client receives notification
        // without first asking for another catalog.
        let status=try await session.client.callTool(name:"service_info")
        XCTAssertEqual(status.isError,false)
        XCTAssertTrue(text(status.content).contains("project_setup_required"))
        let tools=try await session.client.listTools()
        XCTAssertEqual(tools.tools.map(\.name),["service_info","project_create"])
        _ = try await session.client.listTools()
        XCTAssertEqual(fixture.attempts.count,1)
        XCTAssertFalse(fixture.calls.contains {$0.0 == "project_create" || $0.0 == "tool_catalog"})
        let frames=try await session.transport.frames().map {try JSONSerialization.jsonObject(with:$0) as! [String:Any]}
        XCTAssertEqual(frames.filter {$0["method"] as? String == "notifications/tools/list_changed"}.count,1)
    }

    func testFailedWorkspaceCreationKeepsLimitedCatalogWithoutNotification() async throws {
        let fixture=try Fixture(provider:"codex")
        fixture.setDiscoveries([.available(fixture.context)])
        fixture.unregisteredWorkspace=true;fixture.projectCreationEnabled=true
        fixture.callHandler={ name in if name == "project_create" {throw ChecklistError("ROOT_MISMATCH","Use the actual folder")} }
        let session=try await start(fixture)
        let result=try await session.client.callTool(name:"project_create",arguments:["command_id":.string(UUID().uuidString),"name":.string("Synthetic"),"key_prefix":.string("SYN"),"root_path":.string("/other")])
        XCTAssertEqual(result.isError,true)
        XCTAssertEqual(fixture.attempts.count,1)
        let tools=try await session.client.listTools()
        XCTAssertEqual(tools.tools.map(\.name),["service_info","project_create"])
        let frames=try await session.transport.frames().map{try JSONSerialization.jsonObject(with:$0) as! [String:Any]}
        XCTAssertEqual(frames.filter{$0["method"] as? String == "notifications/tools/list_changed"}.count,0)
    }

    func testCommittedCreationRetainsReceiptAndCompletesBootstrapOnNextRequest() async throws {
        let fixture=try Fixture(provider:"codex")
        fixture.setDiscoveries([.available(fixture.context)])
        fixture.unregisteredWorkspace=true;fixture.projectCreationEnabled=true
        fixture.bootstrapHandler={ _ in if fixture.attempts.count == 2 { throw ChecklistError("SERVICE_UNAVAILABLE","synthetic postcommit connection failure") } }
        let session=try await start(fixture)
        let created=try await session.client.callTool(name:"project_create",arguments:["command_id":.string(UUID().uuidString),"name":.string("Synthetic")])
        XCTAssertEqual(created.isError,false)
        XCTAssertTrue(text(created.content).contains("synthetic-project"))
        XCTAssertTrue(text(created.content).contains("project_connection_pending"))
        let full=try await session.client.listTools()
        XCTAssertTrue(full.tools.contains{$0.name == "task_list"})
        _ = try await session.client.listTools()
        XCTAssertEqual(fixture.attempts.count,3)
        XCTAssertEqual(fixture.calls.filter{$0.0 == "project_create"}.count,1)
        let frames=try await session.transport.frames().map{try JSONSerialization.jsonObject(with:$0) as! [String:Any]}
        XCTAssertEqual(frames.filter{$0["method"] as? String == "notifications/tools/list_changed"}.count,1)
    }

    private final class UpdateFixture: @unchecked Sendable {
        private let lock = NSLock()
        private var state = ShimLaunchState.current
        private var runs: [[String]] = []
        private var inputs: [Data?] = []
        private var checks: [Bool] = []
        var result = ShimChildResult(status: 0, stdout: Data("{\"data\":{\"delegate\":true}}".utf8))
        var failure: Error?
        let path = "/synthetic/Checklist Test 2.app/Contents/MacOS/checklist"

        private func locked<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock(); defer { lock.unlock() }; return try body()
        }
        func set(_ value: ShimLaunchState) { locked { state = value } }
        var calls: [[String]] { locked { runs } }
        var payloads: [Data?] { locked { inputs } }
        var forcedChecks: Int { locked { checks.filter { $0 }.count } }
        var environment: ShimUpdateEnvironment {
            .init(launchPath: path, check: { force in
                self.locked { self.checks.append(force); return self.state }
            }, run: { arguments, input in
                try self.locked {
                    self.runs.append(arguments); self.inputs.append(input)
                    if let failure = self.failure { throw failure }
                    if arguments.first == "tools" {
                        return .init(status: 0, stdout: Data("{\"tools\":[{\"name\":\"project_list\",\"inputSchema\":{\"type\":\"object\"}}]}".utf8))
                    }
                    return self.result
                }
            })
        }
    }

    func testReplacedShimNativeRefusalAlsoNamesReconnectWithoutReplay() async throws {
        let fixture = try Fixture(provider:"codex"),update = UpdateFixture()
        update.set(.replaced)
        update.result = .init(status:1,stdout:Data(),stderr:"Checklist: NATIVE_SESSION_REQUIRED: old native binding\n")
        var environment = fixture.environment;environment.shimUpdate = update.environment
        let bridge = Bridge(configuration:.init(workspace:fixture.context.workspacePath),environment:environment)
        _ = try await bridge.connect(required:true)
        do {
            _ = try await bridge.serviceInfo()
            XCTFail("Expected native reconnect guidance")
        } catch let error as ChecklistError {
            XCTAssertEqual(error.code,"NATIVE_SESSION_REQUIRED")
            XCTAssertTrue(error.message.contains(ChecklistInstance.current.cliCommand + " mcp"))
        }
        XCTAssertEqual(update.calls.count,1)
    }

    private func noticeCount(_ session: Session) async throws -> Int {
        try await session.client.ping()
        return try await session.transport.frames().filter {
            (try JSONSerialization.jsonObject(with: $0) as? [String: Any])?["method"] as? String == "notifications/tools/list_changed"
        }.count
    }

    func testLaunchPathChangeDelegatesCurrentAndQueuedCallsAndNotifiesOnce() async throws {
        let fixture = try Fixture(), update = UpdateFixture()
        fixture.setDiscoveries([.available(fixture.context)])
        let config = BridgeConfiguration(installation: "test-slot-binding", workspace: fixture.context.workspacePath,
            expectedSession: fixture.context.nativeSessionID, automatic: false)
        let session = try await start(fixture, update: update.environment, configuration: config)
        let oldCalls = fixture.calls.count
        update.set(.replaced)
        let arguments: [String: Value] = ["command_id": .string("same-command-id"), "body": .string("quote \" and newline\nUnicode å")]
        async let first = session.client.callTool(name: "task_edit", arguments: arguments)
        async let second = session.client.callTool(name: "task_list")
        for result in try await [first, second] {
            XCTAssertEqual(result.isError, false)
            XCTAssertEqual(try JSONDecoder().decode(Value.self, from: Data(text(result.content).utf8)), .object(["data": .object(["delegate": .bool(true)])]))
        }
        let third = try await session.client.callTool(name: "task_edit", arguments: arguments)
        XCTAssertEqual(third.isError, false)
        XCTAssertEqual(update.calls.count, 3)
        XCTAssertEqual(fixture.calls.count, oldCalls)
        XCTAssertTrue(fixture.attempts.isEmpty)
        for (index, call) in update.calls.enumerated() {
            XCTAssertEqual(Array(call.suffix(6)), ["--workspace", fixture.context.workspacePath, "--session", fixture.context.nativeSessionID, "--installation", "test-slot-binding"])
            if call[1] == "task_edit" {
                XCTAssertEqual(call[2], "-")
                XCTAssertEqual(try JSONDecoder().decode(Value.self, from: XCTUnwrap(update.payloads[index])), .object(arguments))
            }
        }
        let count = try await noticeCount(session)
        XCTAssertEqual(count, 1)
        try await assertProtocolOnly(session)
    }

    func testOutdatedReplyForCatalogOrCommandForcesCheckAndDelegatesOnce() async throws {
        for refusal in ["tool_catalog", "task_list"] {
            let fixture = try Fixture(), update = UpdateFixture()
            fixture.setDiscoveries([.available(fixture.context)])
            let session = try await start(fixture, update: update.environment)
            fixture.callHandler = { name in if name == refusal { throw ClientUpdateRequired.error } }
            let first = try await session.client.callTool(name: "task_list")
            XCTAssertEqual(first.isError, false)
            XCTAssertTrue(text(first.content).contains("delegate"))
            let oldCalls = fixture.calls.count
            _ = try await session.client.callTool(name: "task_list")
            XCTAssertEqual(fixture.calls.count, oldCalls)
            XCTAssertEqual(fixture.attempts.count, 1)
            XCTAssertEqual(update.forcedChecks, 1)
            XCTAssertEqual(update.calls.count, 2)
            let count = try await noticeCount(session)
            XCTAssertEqual(count, 1)
        }
    }

    func testDelegateRoutesToolsAndResourcesThroughInstalledCLI() async throws {
        let fixture = try Fixture(), update = UpdateFixture()
        fixture.setDiscoveries([.available(fixture.context)])
        let session = try await start(fixture, update: update.environment)
        update.set(.replaced)
        let catalog = try await session.client.listTools()
        XCTAssertEqual(catalog.tools.map(\.name), ["project_list"])
        let resources = try await session.client.listResources()
        XCTAssertEqual(resources.resources.map(\.uri), ["checklist://service/status", "checklist://projects"])
        for uri in resources.resources.map(\.uri) {
            let result = try await session.client.readResource(uri: uri)
            XCTAssertEqual(result.count, 1)
        }
        XCTAssertEqual(update.calls.map { Array($0.prefix(1)) }, [["tools"], ["tools"], ["call"], ["call"]])
        XCTAssertEqual(update.calls[2][1], "service_info")
        XCTAssertEqual(update.calls[3][1], "project_list")
        XCTAssertTrue(update.calls.allSatisfy { !$0.contains("--installation") })
        let count = try await noticeCount(session)
        XCTAssertEqual(count, 1)
    }

    func testMissingOrInvalidLaunchPathReturnsClearErrorAndKeepsTransportAlive() async throws {
        let fixture = try Fixture(), update = UpdateFixture()
        fixture.setDiscoveries([.available(fixture.context)])
        let session = try await start(fixture, update: update.environment)
        let oldCalls = fixture.calls.count
        update.set(.unavailable)
        for _ in 0..<2 {
            let reply = try await session.client.callTool(name: "task_edit")
            XCTAssertEqual(reply.isError, true)
            XCTAssertTrue(text(reply.content).contains("CLIENT_OUTDATED"))
            XCTAssertTrue(text(reply.content).contains("no command ran"))
            XCTAssertTrue(text(reply.content).contains("restart or reconnect the checklist MCP server"))
            XCTAssertFalse(text(reply.content).contains("OUTCOME_UNKNOWN"))
            try await session.client.ping()
        }
        XCTAssertTrue(update.calls.isEmpty)
        XCTAssertEqual(fixture.calls.count, oldCalls)
        update.set(.replaced)
        let recovered = try await session.client.callTool(name: "task_edit")
        XCTAssertEqual(recovered.isError, false)
        let count = try await noticeCount(session)
        XCTAssertEqual(count, 1)
    }

    func testOutdatedInstalledDelegateGivesHostRestartSignalWithoutUnknownOutcome() async throws {
        let fixture = try Fixture(), update = UpdateFixture()
        fixture.setDiscoveries([.available(fixture.context)])
        let session = try await start(fixture, update: update.environment)
        update.set(.replaced)
        update.result = .init(status: 1, stdout: Data(), stderr: "Checklist: " + ClientUpdateRequired.error.localizedDescription + "\n")
        let id = UUID().uuidString
        let reply = try await session.client.callTool(name: "task_edit", arguments: ["command_id": .string(id)])
        XCTAssertEqual(reply.isError, true)
        let message = text(reply.content)
        XCTAssertTrue(message.contains("CLIENT_OUTDATED"))
        XCTAssertTrue(message.contains("Codex or Claude host's MCP controls"))
        XCTAssertTrue(message.contains("restart or reconnect the checklist MCP server"))
        XCTAssertFalse(message.contains("OUTCOME_UNKNOWN"))
        let frames = try await session.transport.frames().map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        let result = try XCTUnwrap(frames.last?["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let error = try XCTUnwrap(structured["error"] as? [String: Any])
        let details = try XCTUnwrap(error["details"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "CLIENT_OUTDATED")
        XCTAssertEqual(details["recovery_action"] as? String, "restart_mcp_server")
        XCTAssertEqual(details["command_executed"] as? Bool, false)
        XCTAssertEqual(details["command_id"] as? String, id)
        try await session.client.ping()
        XCTAssertEqual(update.calls.count, 1)
    }

    func testCurrentShimNeverDelegatesAndKeepsLazyBootstrap() async throws {
        let fixture = try Fixture(), update = UpdateFixture()
        let session = try await start(fixture, update: update.environment)
        fixture.setDiscoveries([.available(fixture.context)])
        _ = try await session.client.listTools()
        _ = try await session.client.callTool(name: "task_list")
        _ = try await session.client.readResource(uri: "checklist://service/status")
        XCTAssertEqual(fixture.attempts.count, 1)
        XCTAssertTrue(update.calls.isEmpty)
        XCTAssertEqual(update.forcedChecks, 0)
        let count = try await noticeCount(session)
        XCTAssertEqual(count, 1) // The existing CL-168 connection notice only.
    }

    func testUpdateSkipsOldLazyBootstrapAndStartupOutdatedReplyCanRecover() async throws {
        for startupRefusal in [false, true] {
            let fixture = try Fixture(), update = UpdateFixture()
            if startupRefusal {
                fixture.setDiscoveries([.available(fixture.context)])
                fixture.bootstrapHandler = { _ in throw ClientUpdateRequired.error }
            }
            let session = try await start(fixture, update: update.environment)
            if !startupRefusal { update.set(.replaced); fixture.setDiscoveries([.available(fixture.context)]) }
            let reply = try await session.client.callTool(name: "task_list")
            XCTAssertEqual(reply.isError, false)
            XCTAssertEqual(fixture.attempts.count, startupRefusal ? 1 : 0)
            XCTAssertEqual(update.calls.count, 1)
            let count = try await noticeCount(session)
            XCTAssertEqual(count, 1)
        }
    }

    func testDelegateChildErrorUsesStderrAndArgumentLimitPreventsLaunch() async throws {
        let fixture = try Fixture(), update = UpdateFixture()
        fixture.setDiscoveries([.available(fixture.context)])
        let session = try await start(fixture, update: update.environment)
        update.set(.replaced)
        update.result = .init(status: 1, stdout: Data("not a result".utf8), stderr: "Checklist: connected after 3 attempts in 500 ms\nChecklist: EXACT_DELEGATE_ERROR: synthetic refusal\n")
        let refused = try await session.client.callTool(name: "task_edit")
        XCTAssertEqual(refused.isError, true)
        XCTAssertEqual(text(refused.content), "EXACT_DELEGATE_ERROR: synthetic refusal")
        update.result = .init(status: 9, stdout: Data())
        let interruptedChild = try await session.client.callTool(name: "task_edit")
        XCTAssertEqual(interruptedChild.isError, true)
        XCTAssertTrue(text(interruptedChild.content).contains("OUTCOME_UNKNOWN"))
        XCTAssertFalse(text(interruptedChild.content).contains("no command ran"))
        update.failure = ShimChildLaunchError(underlying: CocoaError(.fileNoSuchFile))
        let cannotLaunch = try await session.client.callTool(name: "task_edit")
        XCTAssertEqual(cannotLaunch.isError, true)
        XCTAssertTrue(text(cannotLaunch.content).contains("DELEGATE_LAUNCH_FAILED"))
        XCTAssertFalse(text(cannotLaunch.content).contains("CLIENT_OUTDATED"))
        let before = update.calls.count
        let tooLarge = try await session.client.callTool(name: "task_edit", arguments: ["body": .string(String(repeating: "a", count: 1_048_577))])
        XCTAssertEqual(tooLarge.isError, true)
        XCTAssertTrue(text(tooLarge.content).contains("Input exceeds 1 MiB"))
        XCTAssertEqual(update.calls.count, before)
        try await session.client.ping()
    }

    func testUnverifiedDelegateResultsKeepUnknownOutcomeAndOriginalCommandID() async throws {
        for commandID in [nil, "original-delegated-command"] as [String?] {
            for result in [
                ShimChildResult(status: 9, stdout: Data(), stderr: "Checklist: connected after 3 attempts in 500 ms\n", termination: .signalled),
                ShimChildResult(status: 0, stdout: Data("{}".utf8), termination: .notAwaited),
                ShimChildResult(status: 2, stdout: Data(), stderr: "Checklist: INVALID_INPUT: ignored status\n"),
                ShimChildResult(status: 1, stdout: Data(), stderr: "Checklist: connected after 3 attempts in 500 ms\n"),
                ShimChildResult(status: 1, stdout: Data(), stderr: "Checklist: INVALID_INPUT: not the final line\nChecklist: connected after 3 attempts in 500 ms\n"),
                ShimChildResult(status: 0, stdout: Data("not JSON".utf8))
            ] {
                let fixture = try Fixture(), update = UpdateFixture()
                fixture.setDiscoveries([.available(fixture.context)])
                let session = try await start(fixture, update: update.environment)
                update.set(.replaced); update.result = result
                let arguments = commandID.map { ["command_id": Value.string($0)] } ?? [:]
                let reply = try await session.client.callTool(name: "task_edit", arguments: arguments)
                XCTAssertEqual(reply.isError, true)
                let message = text(reply.content)
                XCTAssertTrue(message.hasPrefix("OUTCOME_UNKNOWN:"), message)
                XCTAssertFalse(message.contains("connected after"), message)
                if let commandID { XCTAssertTrue(message.contains(commandID), message) }
                let frames = try await session.transport.frames().map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
                let result = try XCTUnwrap(frames.last { $0["result"] is [String: Any] }?["result"] as? [String: Any])
                let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
                let error = try XCTUnwrap(structured["error"] as? [String: Any])
                let details = try XCTUnwrap(error["details"] as? [String: Any])
                XCTAssertEqual(error["code"] as? String, "OUTCOME_UNKNOWN")
                XCTAssertEqual(details["reason"] as? String, "delegate_ended")
                XCTAssertEqual(details["command_id"] as? String, commandID)
            }
        }
    }

    func testDelegateSpawnAndWaitErrorsKeepDistinctOutcomes() async throws {
        for commandID in [nil, "original-spawn-command"] as [String?] {
            let fixture = try Fixture(), update = UpdateFixture()
            fixture.setDiscoveries([.available(fixture.context)])
            let session = try await start(fixture, update: update.environment)
            update.set(.replaced)
            let arguments = commandID.map { ["command_id": Value.string($0)] } ?? [:]
            update.failure = ShimChildLaunchError(underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(E2BIG)))
            let spawn = try await session.client.callTool(name: "task_edit", arguments: arguments)
            XCTAssertEqual(spawn.isError, true)
            XCTAssertTrue(text(spawn.content).hasPrefix("DELEGATE_LAUNCH_FAILED:"))
            XCTAssertTrue(text(spawn.content).contains("No command ran"))
            XCTAssertFalse(text(spawn.content).contains("CLIENT_OUTDATED"))
            if let commandID { XCTAssertTrue(text(spawn.content).contains(commandID)) }
            update.failure = CocoaError(.fileReadUnknown)
            let wait = try await session.client.callTool(name: "task_edit", arguments: arguments)
            XCTAssertEqual(wait.isError, true)
            XCTAssertTrue(text(wait.content).hasPrefix("OUTCOME_UNKNOWN:"))
            if let commandID { XCTAssertTrue(text(wait.content).contains(commandID)) }
        }
    }

    func testParentAndChildInstanceMismatchesKeepNotSentAndCommandID() async throws {
        for commandID in [nil, "original-instance-command"] as [String?] {
            for parentRefusal in [false, true] {
                let fixture = try Fixture(), update = UpdateFixture()
                fixture.setDiscoveries([.available(fixture.context)])
                let session = try await start(fixture, update: update.environment)
                update.set(.replaced)
                if parentRefusal {
                    update.failure = ShimChildInstanceMismatch(processID: 0, observedHash: nil, stdout: Data(), stderr: "")
                } else {
                    update.result = .init(status: 1, stdout: Data(), stderr: "Checklist: DELEGATE_INSTANCE_MISMATCH: no command ran; reconnect.\n")
                }
                let arguments = commandID.map { ["command_id": Value.string($0)] } ?? [:]
                let reply = try await session.client.callTool(name: "task_edit", arguments: arguments)
                XCTAssertEqual(reply.isError, true)
                XCTAssertTrue(text(reply.content).hasPrefix("DELEGATE_INSTANCE_MISMATCH:"))
                if let commandID { XCTAssertTrue(text(reply.content).contains(commandID)) }
                let frames = try await session.transport.frames().map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
                let result = try XCTUnwrap(frames.last { $0["result"] is [String: Any] }?["result"] as? [String: Any])
                let fields = try XCTUnwrap((result["structuredContent"] as? [String: Any])?["error"] as? [String: Any])
                let details = try XCTUnwrap(fields["details"] as? [String: Any])
                XCTAssertEqual(details["command_outcome"] as? String, "not_sent")
                XCTAssertEqual(details["command_executed"] as? Bool, false)
                XCTAssertEqual(details["command_id"] as? String, commandID)
            }
        }
    }
}
