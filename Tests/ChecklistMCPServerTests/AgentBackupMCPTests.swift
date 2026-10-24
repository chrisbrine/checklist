import XCTest
import Foundation
import GRDB
import MCP
import ChecklistIPC
@testable import ChecklistCore
@testable import ChecklistBridges
@testable import ChecklistMCPServer

/// Actual SDK tools/call frames, production MCP server and bridge, and an owned
/// router store. Only the IPC transport/native bootstrap are fixture substitutes.
final class AgentBackupMCPTests: XCTestCase {
    private final class Fixture: @unchecked Sendable {
        let base: URL
        let root: URL
        let workspace: URL
        let router: CommandRouter
        let context: NativeSessionContext
        let owner = Caller(role:"owner",installation:"mcp-backup-owner",projectIDs:[])
        let projectID: String
        let taskID: String
        let caller: Caller
        private let lock = NSLock()
        private var backupCalls = 0
        private var backupFinished = false

        init(role: String = "worker") throws {
            let caches = try FileManager.default.url(for:.cachesDirectory,in:.userDomainMask,appropriateFor:nil,create:true).resolvingSymlinksInPath()
            base = caches.appendingPathComponent("ChecklistQualification/CL-258-MCP-" + UUID().uuidString)
            root = base.appendingPathComponent("store");workspace = base.appendingPathComponent("workspace")
            try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
            context = try XCTUnwrap(NativeSessionContext.observed(provider:"codex",environment:["CODEX_THREAD_ID":UUID().uuidString],currentDirectory:workspace.path))
            let router = try CommandRouter(root:root);self.router = router
            let owner = Caller(role:"owner",installation:"mcp-backup-owner",projectIDs:[])
            func ownerCall(_ method: String,_ input: [String:Any]) throws -> [String:Any] {
                var params = input;params["command_id"] = UUID().uuidString
                return try router.handle(method:method,params:params,caller:owner)["data"] as! [String:Any]
            }
            let project = try ownerCall("project_create",["name":"Agent backup MCP fixture","key_prefix":"BKP","root_path":workspace.path])
            projectID = project["id"] as! String
            let epic = try ownerCall("epic_create",["project_id":projectID,"name":"Backup route tests"])
            let task = try ownerCall("task_create",["project_id":projectID,"title":"Snapshot generation","epic_id":epic["id"]!])
            taskID = task["id"] as! String
            if role == "worker" {_ = try ownerCall("session_register",["project_id":projectID,"session_id":context.nativeSessionID,"provider":"codex","role":"worker","installation":"mcp-backup-worker","workspace":workspace.path])}
            caller = Caller(role:role,installation:"mcp-backup-" + role,projectIDs:[projectID],sessionID:role == "worker" ? context.nativeSessionID : nil,workspace:workspace.path)
        }

        func close() {try? router.closeStore();try? FileManager.default.removeItem(at:base)}
        var numberOfBackupCalls: Int {lock.lock();defer {lock.unlock()};return backupCalls}
        var backupHasFinished: Bool {lock.lock();defer {lock.unlock()};return backupFinished}

        func call(_ method: String,_ params: [String:Any]) throws -> [String:Any] {
            do {
                if method == "backup_create" {
                    lock.lock();backupCalls += 1;lock.unlock()
                }
                defer {
                    if method == "backup_create" {lock.lock();backupFinished = true;lock.unlock()}
                }
                return try router.handle(method:method,params:params,caller:caller)
            } catch let error as CoreError {throw ChecklistError(error.code,error.message,details:error.details)}
        }

        var environment: BridgeEnvironment {
            .init(makeClient:{_ in RouterClient(self)},discover:{_ in .available(self.context)},stderr:{_ in})
        }

        func refuseAgentRuleChanges() throws {
            try router.dbQueue.write {db in
                var project = try router.record(db,projectID,type:"project"),policy = project["policy"] as! [String:Any]
                policy["agent_rule_changes"] = "owner_only";project["policy"] = policy;try router.save(db,project,type:"project")
            }
        }

        func note(_ body: String) throws {
            _ = try router.handle(method:"message_send",params:["command_id":UUID().uuidString,"project_id":projectID,"task_id":taskID,"body":body,"kind":"note"],caller:caller)
        }

        func messageCount() throws -> Int {
            try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM records WHERE type='message'") ?? -1}
        }
    }

    private final class RouterClient: BridgeClient, @unchecked Sendable {
        let fixture: Fixture
        init(_ fixture: Fixture) {self.fixture = fixture}
        func bootstrap(_ nativeContext: [String:Any],timeBudget: TimeInterval?) throws -> [String:Any] {
            ["data":["installation":"mcp-backup-fixture","project_id":fixture.projectID,"session_id":fixture.context.nativeSessionID,"connected":true]]
        }
        func call(_ method: String,_ params: [String:Any],replyTimeout: TimeInterval?) throws -> [String:Any] {try fixture.call(method,params)}
    }

    private func start(_ fixture: Fixture) async throws -> Client {
        let pair = await InMemoryTransport.createConnectedPair()
        let bridge = Bridge(configuration:.init(workspace:fixture.workspace.path),environment:fixture.environment)
        let server = try await ChecklistMCPServer.start(bridge:bridge,transport:pair.server)
        let client = Client(name:"CL-258 route regression",version:"1")
        addTeardownBlock {await client.disconnect();await server.stop();fixture.close()}
        _ = try await client.connect(transport:pair.client)
        return client
    }

    private func text(_ reply: (content: [Tool.Content],isError: Bool?)) -> String {
        reply.content.compactMap {if case .text(let text,_,_) = $0 {return text};return nil}.joined(separator:"\n")
    }

    private func arguments(_ fixture: Fixture) -> [String:MCP.Value] {
        ["project_id":.string(fixture.projectID),"command_id":.string(UUID().uuidString),"qualification_name":.string("mcp-route")]
    }

    private func verifiedBackup(_ reply: (content: [Tool.Content],isError: Bool?),_ fixture: Fixture) throws -> (URL,StorageSnapshotManifest) {
        XCTAssertFalse(reply.isError ?? false,text(reply))
        let envelope = try JSONSerialization.jsonObject(with:Data(text(reply).utf8)) as! [String:Any]
        let data = try XCTUnwrap(envelope["data"] as? [String:Any]),destination = URL(fileURLWithPath:try XCTUnwrap(data["path"] as? String))
        XCTAssertTrue(destination.path.hasPrefix(fixture.root.appendingPathComponent("backups/qualification-mcp-route").path + "/"))
        let files = try StorageObjectFiles(root:destination)
        let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:files.read("manifest.json",maximum:StorageSnapshotBudget.manifestByteLimit))
        let receipt = try StorageSnapshot.verify(files,operation:UUID(uuidString:manifest.operationID)!,budget:.production())
        XCTAssertEqual(receipt,data["manifest_sha256"] as? String)
        return (destination,manifest)
    }

    func testMCPAgentBackupAllowedRouteCreatesVerifiedSnapshotAndAgentEvent() async throws {
        let f = try Fixture(),client = try await start(f),tools = try await client.listTools()
        let backup = try XCTUnwrap(tools.tools.first {$0.name == "backup_create"})
        let schema = try JSONSerialization.jsonObject(with:JSONEncoder().encode(backup.inputSchema)) as! [String:Any]
        XCTAssertNil((schema["properties"] as? [String:Any])?["path"])
        _ = try verifiedBackup(try await client.callTool(name:"backup_create",arguments:arguments(f)),f)
        XCTAssertEqual(f.numberOfBackupCalls,1)
        try await f.router.dbQueue.read {db in
            let row = try XCTUnwrap(Row.fetchOne(db,sql:"SELECT actor,data FROM events WHERE kind='backup_created'"))
            XCTAssertEqual(row["actor"] as String,f.caller.principal)
            XCTAssertEqual(jsonObject(row["data"])["origin"] as? String,"agent")
        }
        try await client.ping()
    }

    func testMCPAgentBackupRefusesOwnerOnlyProjectPolicy() async throws {
        let f = try Fixture();try f.refuseAgentRuleChanges()
        let client = try await start(f),reply = try await client.callTool(name:"backup_create",arguments:arguments(f))
        XCTAssertTrue(reply.isError ?? false);XCTAssertTrue(text(reply).contains("HUMAN_CHANNEL_REQUIRED"),text(reply))
        XCTAssertEqual(f.numberOfBackupCalls,1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("backups").path))
        try await client.ping()
    }

    func testMCPAgentBackupRefusesAssistantWithoutDispatchingBackup() async throws {
        let f = try Fixture(role:"assistant"),client = try await start(f),tools = try await client.listTools()
        XCTAssertFalse(tools.tools.contains {$0.name == "backup_create"})
        let reply = try await client.callTool(name:"backup_create",arguments:arguments(f))
        XCTAssertTrue(reply.isError ?? false);XCTAssertTrue(text(reply).contains("METHOD_UNAVAILABLE"),text(reply))
        XCTAssertEqual(f.numberOfBackupCalls,0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("backups").path))
        try await client.ping()
    }

    func testMCPAgentBackupRefusesArbitraryAndEscapingDestinations() async throws {
        let f = try Fixture(),client = try await start(f)
        for forbidden: [String:MCP.Value] in [["path":.string(f.base.appendingPathComponent("outside").path)],["qualification_name":.string("../outside")]] {
            var params = arguments(f);params.merge(forbidden) {_,new in new}
            let reply = try await client.callTool(name:"backup_create",arguments:params)
            XCTAssertTrue(reply.isError ?? false);XCTAssertTrue(text(reply).contains("INVALID_INPUT"),text(reply))
        }
        XCTAssertEqual(f.numberOfBackupCalls,2)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.base.appendingPathComponent("outside").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("backups").path))
        try await client.ping()
    }

    func testMCPAgentBackupAllowsConcurrentWorkerNoteDuringActualRoute() async throws {
        let f = try Fixture(),client = try await start(f)
        // A real 64 MiB managed original supplies a useful copy/hash interval;
        // no private budget callback or alternate router entry point is used.
        let original = f.workspace.appendingPathComponent("original.bin"),bytes = Data(repeating:47,count:64 * 1024 * 1024)
        try bytes.write(to:original)
        let added = try f.call("attachment_add",["command_id":UUID().uuidString,"project_id":f.projectID,"task_id":f.taskID,"path":original.path])["data"] as! [String:Any]
        let noteFinished = expectation(description:"Worker note commits while MCP backup runs")
        DispatchQueue.global().async {
            defer {noteFinished.fulfill()}
            do {
                let parent = f.root.appendingPathComponent("backups/qualification-mcp-route"),deadline = ProcessInfo.processInfo.systemUptime + 10
                var sawCapturedDatabase = false
                while ProcessInfo.processInfo.systemUptime < deadline {
                    if f.backupHasFinished {break}
                    let stages = (try? FileManager.default.contentsOfDirectory(at:parent,includingPropertiesForKeys:nil)) ?? []
                    if stages.contains(where: {$0.lastPathComponent.hasPrefix(".snapshot-staging-") && FileManager.default.fileExists(atPath:$0.appendingPathComponent("database.sqlite").path)}),try StorageSnapshotRetention.isActive(root:f.root) {
                        sawCapturedDatabase = true;break
                    }
                    Thread.sleep(forTimeInterval:0.001)
                }
                guard sawCapturedDatabase else {
                    XCTFail("Did not observe this backup's staged database with active retention within 10 seconds; concurrent overlap is unqualified")
                    return
                }
                // The staging DB is created under capture's writer/object gate.
                // This normal worker command must commit after that capture and
                // before the actual backup route returns to the MCP bridge.
                let noteStarted = ProcessInfo.processInfo.systemUptime
                try f.note("MCP concurrent actual-route note")
                let overlapped = !f.backupHasFinished
                XCTAssertTrue(overlapped,"Worker note did not finish before the actual backup route returned")
                print("CL258 MCP actual-route concurrent_note_seconds=\(ProcessInfo.processInfo.systemUptime - noteStarted) committed_before_backup_return=\(overlapped)")
            } catch {XCTFail("Concurrent note: \(error)")}
        }
        let backupStarted = ProcessInfo.processInfo.systemUptime
        let reply = try await client.callTool(name:"backup_create",arguments:arguments(f))
        print("CL258 MCP actual-route backup_seconds=\(ProcessInfo.processInfo.systemUptime - backupStarted) original_bytes=\(bytes.count)")
        await fulfillment(of:[noteFinished],timeout:15)
        let (destination,manifest) = try verifiedBackup(reply,f)
        XCTAssertEqual(f.numberOfBackupCalls,1);XCTAssertEqual(try f.messageCount(),1)
        let object = try XCTUnwrap(manifest.objects.first {$0.descriptor.authorities.contains("attachment:" + (added["id"] as! String) + ":original")})
        XCTAssertEqual(object.sha256,ChecklistCore.hash(bytes));XCTAssertEqual(object.size,Int64(bytes.count))
        var config = Configuration();config.readonly = true;config.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let copy = try DatabaseQueue(path:destination.appendingPathComponent("database.sqlite").path,configuration:config);defer {try? copy.close()}
        let capturedCount = try await copy.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM records WHERE type='message'")}
        XCTAssertEqual(capturedCount,0);XCTAssertEqual(manifest.recordFamilies?["message"],0)
        XCTAssertFalse(try StorageSnapshotRetention.isActive(root:f.root))
        try await client.ping()
    }
}
