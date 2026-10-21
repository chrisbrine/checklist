import Foundation
import MCP
import ChecklistBridges
import ChecklistIPC

public enum ChecklistMCPServer {
    private static func request<T>(server: Server, bridge: Bridge, body: () async throws -> T) async throws -> T {
        if await bridge.retryConnection() { try await server.notify(ToolListChangedNotification.message()) }
        do {
            let result = try await body()
            if await bridge.takeUpdateNotice() { try await server.notify(ToolListChangedNotification.message()) }
            return result
        } catch {
            if await bridge.takeUpdateNotice() { try? await server.notify(ToolListChangedNotification.message()) }
            throw error
        }
    }

    public static func start(bridge: Bridge, transport: any Transport = StdioTransport()) async throws -> Server {
        _ = try await bridge.connect()
        try await bridge.verifySession()
        await bridge.reportStartupNotice()
        var instructions = "Checklist coordinates project-scoped work and named agent communication. Use only discovered tools. In a supported native Codex or Claude conversation this server connects automatically to the registered project using observed native context; no session IDs or Settings form are needed. Checklist is built for AI agents: agents create, refine, plan, claim, implement, review and change project rules and settings; the owner mainly adds notes, answers requests assigned to them and handles their reviews. Agent changes are recorded as agent actions; only the trusted native app records the owner's own answers and approvals. Draft readiness means a ticket needs refinement; prerequisites order Triage work and gate claim and pickup, not readiness. Any eligible AI claims an unclaimed ticket; to replace a current holder use work_takeover with a reason, which needs no permission and notifies the earlier holder. Every verdict ends the review claim; a pass on the last open gate marks the ticket Done. For message_send, omit recipient for current handlers/pickup or supply exactly recipient={\"kind\":\"session\",\"session_id\":\"<verified scoped session>\"}. Inspect the returned deliveries for that exact recipient before claiming notification; saved/queued is not recipient acknowledgment. No model runtime, automatic assignment or MCP Events wakeup is provided by this server."
        if let notice = await bridge.setupNotice { instructions += " Not connected: " + notice }
        if let notice = await bridge.connectionNotice { instructions += " Not connected yet: " + notice }
        let server = Server(
            name: "Checklist", version: "0.1.0",
            instructions: instructions,
            capabilities: .init(resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: true))
        )
        await server.withMethodHandler(ListTools.self) { parameters in
            try await request(server: server, bridge: bridge) {
                guard parameters.cursor == nil else { throw MCPError.invalidParams("This catalog is a single page; no cursor is accepted.") }
                return .init(tools: try await bridge.tools())
            }
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            do {
                let result = try await request(server: server, bridge: bridge) {
                    try await bridge.call(parameters.name, .object(parameters.arguments ?? [:]))
                }
                let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
                var content: [Tool.Content] = []
                if let envelope = try jsonObject(result) as? [String:Any],let notice = HumanAnswerNoticePresentation.text(in:envelope) { content.append(.text(text:notice,annotations:nil,_meta:nil)) }
                content.append(.text(text:json,annotations:nil,_meta:nil))
                return CallTool.Result(content:content, structuredContent:.some(result), isError:false)
            } catch {
                var fields: [String: Value] = ["message": .string(error.localizedDescription)]
                if let failure = error as? ChecklistError {
                    fields["code"] = .string(failure.code)
                    fields["details"] = try? mcpValue(failure.details)
                }
                let errorResult: Value = .object(["error": .object(fields)])
                return CallTool.Result(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], structuredContent: .some(errorResult), isError: true)
            }
        }
        await server.withMethodHandler(ListResources.self) { parameters in
            try await request(server: server, bridge: bridge) {
                guard parameters.cursor == nil else { throw MCPError.invalidParams("This resource catalog is a single page.") }
                return .init(resources: try await bridge.resources())
            }
        }
        await server.withMethodHandler(ReadResource.self) { parameters in
            let value = try await request(server: server, bridge: bridge) {
                try await bridge.readResource(parameters.uri)
            }
            let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            return .init(contents: [.text(text, uri: parameters.uri, mimeType: "application/json")])
        }
        try await server.start(transport: transport)
        return server
    }
}
