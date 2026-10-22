import XCTest
import MCP
@testable import ChecklistBridges
import ChecklistIPC
import ChecklistMCPServer
@testable import ChecklistCLI

final class WorkspaceProjectCreationTests: XCTestCase {
    private final class Client: BridgeClient, @unchecked Sendable {
        let context: NativeSessionContext
        var created = false
        var bootstraps = 0
        var configurations: [BridgeClientConfiguration] = []
        var requests: [(String, [String: Any])] = []

        init() throws {
            context = try XCTUnwrap(NativeSessionContext.observed(provider:"codex",environment:["CODEX_THREAD_ID":UUID().uuidString],currentDirectory:FileManager.default.currentDirectoryPath))
        }

        func bootstrap(_ nativeContext: [String: Any], timeBudget: TimeInterval?) throws -> [String: Any] {
            bootstraps += 1
            XCTAssertEqual(nativeContext["native_session_id"] as? String,context.nativeSessionID)
            if !created { return ["data":["state":"project_setup_required","connected":false,"native_context_verified":true]] }
            return ["data":["installation":"synthetic-creation","project_id":"synthetic-project","session_id":context.nativeSessionID,"connected":true]]
        }

        func call(_ method: String, _ params: [String: Any], replyTimeout: TimeInterval?) throws -> [String: Any] {
            requests.append((method,params))
            if method == "tool_catalog" {
                return ["data":["tools":["service_info","project_create","task_list"].map{
                    ["name":$0,"description":"Synthetic "+$0,"inputSchema":["type":"object","properties":[:],"additionalProperties":false]] as [String:Any]
                }]]
            }
            if method == "project_create" {
                let replayed=created;created=true
                return ["data":["id":"synthetic-project","root_path":context.workspacePath],"command_id":params["command_id"]!,"replayed":replayed]
            }
            return ["data":["tasks":[]]]
        }

        var environment: BridgeEnvironment {
            .init(makeClient:{ config in self.configurations.append(config);return self },discover:{ _ in .available(self.context) },stderr:{ _ in })
        }
    }

    func testCallCreatesOwnWorkspaceThenLaterCLIAndReplayUseBoundConnection() async throws {
        let client=try Client()
        let command=UUID().uuidString.lowercased()
        let json="{\"command_id\":\"\(command)\",\"name\":\"Synthetic\",\"key_prefix\":\"SYN\"}"
        let args=try Arguments(["call","project_create",json])
        let bridge=Bridge(configuration:.init(workspace:args.workspace,command:args.command[0]),environment:client.environment)
        let created=try await ChecklistCommand.call(arguments:args,bridge:bridge)
        let result=try JSONSerialization.jsonObject(with:JSONEncoder().encode(created)) as! [String:Any]
        XCTAssertEqual((result["data"] as? [String:Any])?["id"] as? String,"synthetic-project")
        XCTAssertEqual(result["command_id"] as? String,command)
        XCTAssertEqual(client.bootstraps,2)
        let pending=try XCTUnwrap(client.configurations.first{!$0.usesStoredCredential && $0.nativeContext != nil})
        XCTAssertEqual(pending.workspace,client.context.workspacePath)
        XCTAssertEqual(pending.nativeContext?["native_session_id"] as? String,client.context.nativeSessionID)
        XCTAssertEqual(client.requests.first{$0.0 == "project_create"}?.1["command_id"] as? String,command)

        let later=try Arguments(["call","task_list","{}"])
        let laterBridge=Bridge(configuration:.init(workspace:later.workspace,command:"call"),environment:client.environment)
        _ = try await ChecklistCommand.call(arguments:later,bridge:laterBridge)
        XCTAssertEqual(client.configurations.last?.installation,"synthetic-creation")
        XCTAssertTrue(client.configurations.last?.usesStoredCredential == true)

        let replayBridge=Bridge(configuration:.init(workspace:args.workspace,command:"call"),environment:client.environment)
        let replay=try await ChecklistCommand.call(arguments:args,bridge:replayBridge)
        let replayResult=try JSONSerialization.jsonObject(with:JSONEncoder().encode(replay)) as! [String:Any]
        XCTAssertEqual(replayResult["replayed"] as? Bool,true)
        XCTAssertEqual(replayResult["command_id"] as? String,command)
        XCTAssertEqual(client.requests.filter{$0.0 == "project_create"}.count,2)
    }
}
