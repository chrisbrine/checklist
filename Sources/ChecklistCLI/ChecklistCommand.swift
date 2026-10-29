import Foundation
import ChecklistProviders
import MCP
import ChecklistIPC
import ChecklistMCPServer

// This process is a protocol adapter. The service owns authorization, storage,
// idempotency, project binding and delivery. In particular, there is no owner mode.
struct Arguments: Sendable {
    var installation = "default"
    var workspace: String = FileManager.default.currentDirectoryPath
    var session: String?
    var task: String?
    var assistant = false
    var project: String?
    var installationExplicit = false
    var command: [String] = []

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--assistant":
                guard !assistant else { throw CLIError("Specify --assistant only once.") }
                assistant = true
            case "--installation", "--workspace", "--session", "--task", "--project":
                guard index + 1 < arguments.count else { throw CLIError("Missing value for \(argument)") }
                index += 1
                switch argument {
                case "--installation": installation = arguments[index]; installationExplicit = true
                case "--workspace": workspace = arguments[index]
                case "--session": session = arguments[index]
                case "--task":
                    guard task == nil else { throw CLIError("Specify --task only once.") }
                    task = arguments[index]
                default:
                    guard project == nil else { throw CLIError("Specify --project only once.") }
                    project = arguments[index]
                }
            case "--owner", "--token", "--role":
                throw CLIError("\(argument) is not supported. Native conversations connect automatically; owner actions require the actual Checklist app.")
            default: command.append(argument)
            }
            index += 1
        }
        guard !installation.isEmpty, installation.count <= 80,
              installation.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) })
        else { throw CLIError("Installation must contain 1–80 ASCII letters, numbers, dots, underscores or hyphens.") }
        guard workspace.hasPrefix("/") else { throw CLIError("Workspace must be an absolute directory path.") }
        workspace = URL(fileURLWithPath: workspace).standardizedFileURL.resolvingSymlinksInPath().path
        if let task {
            guard command == ["connect"] else { throw CLIError("--task is supported only by checklist connect.") }
            guard !task.isEmpty, task.count <= 160, !task.contains(where: { $0.isWhitespace }), !task.hasPrefix("-") else {
                throw CLIError("--task requires a ticket key or task UUID.")
            }
        }
        if assistant {
            guard let project, !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, project.count <= 200,
                  !project.hasPrefix("-"), !project.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw CLIError("--assistant requires --project with a project UUID or exact name.")
            }
            guard !installationExplicit else { throw CLIError("Assistant relay connections use native bootstrap; omit --installation.") }
            guard task == nil else { throw CLIError("--assistant cannot use --task. Assistant relays cannot attach as workers or claim work.") }
            guard ["connect", "mcp", "call", "tools"].contains(command.first ?? "") else {
                throw CLIError("--assistant is supported by connect, mcp, call and tools.")
            }
        } else if project != nil {
            throw CLIError("--project requires --assistant; worker connections use their actual workspace project.")
        }
    }
}

struct CLIError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@main
struct ChecklistCommand {
    static func main() async {
        let started = ProcessInfo.processInfo.systemUptime
        defer { if CallTimingLog.enabled { CallTimingLog.write(["scope":"cli", "total_ms":(ProcessInfo.processInfo.systemUptime-started)*1000]) } }
        let instance = ChecklistInstance.current
        var commandName: String?
        do {
            try DelegateInstanceExpectation.verifyIfPresent(instance: instance)
            let shimUpdate = ShimUpdateEnvironment.capture()
            let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
            commandName = arguments.command.first
            let bridge = Bridge(configuration: .init(installation: arguments.installation, workspace: arguments.workspace,
                expectedSession: arguments.session, automatic: !arguments.installationExplicit,
                assistantProject: arguments.assistant ? arguments.project : nil, command: arguments.command.first ?? ""),
                environment: .init(shimUpdate: arguments.command.first == "mcp" ? shimUpdate : nil))
            if CallTimingLog.enabled {CallTimingLog.write(["scope":"cli_setup","total_ms":(ProcessInfo.processInfo.systemUptime-started)*1000])}
            switch arguments.command.first ?? "help" {
            case "connect":
                guard arguments.command.count == 1 else { throw CLIError("Usage: checklist connect [--task KEY_OR_UUID] or checklist connect --assistant --project UUID_OR_EXACT_NAME") }
                if let response = try await bridge.connect(required: true) {
                    try await bridge.verifySession()
                    if let task = arguments.task { try printJSON(await bridge.attachTask(task)) }
                    else { try printJSON(response) }
                }
            case "mcp":
                guard arguments.command.count == 1 else { throw CLIError("Usage: checklist mcp [--installation NAME] [--workspace PATH] [--session PAIRED_ID]") }
                let server = try await ChecklistMCPServer.start(bridge: bridge)
                await server.waitUntilCompleted()
            case "tools":
                guard arguments.command.count == 1 else { throw CLIError("Usage: checklist tools — list the current connection's permitted tool schemas.") }
                _ = try await bridge.connect()
                try await bridge.verifySession()
                await bridge.reportStartupNotice()
                try printJSON(await bridge.toolsResult())
            case "service":
                guard arguments.command.count == 2, ["start", "status"].contains(arguments.command[1]) else {
                    throw CLIError("Usage: checklist service start|status [--installation NAME]")
                }
                // IPC cold-starts the same bundled singleton. There is no model/runtime launch.
                try printJSON(await serviceStatus(installation: arguments.installation, workspace: arguments.workspace))
            case "call":
                try printJSON(await call(arguments:arguments,bridge:bridge))
            case "help", "--help", "-h": printHelp()
            case "version", "--version": print("Checklist \(ChecklistBuildVersion.current.version) · build \(ChecklistBuildVersion.current.buildID) (\(ChecklistBuildVersion.current.buildNumber)) · MCP Swift SDK 0.12.1")
            default: throw CLIError("Unknown command. Run checklist help.")
            }
        } catch {
            if let status = upgradeErrorOutput(error, command: commandName) { FileHandle.standardOutput.write(status); FileHandle.standardOutput.write(Data("\n".utf8)) }
            FileHandle.standardError.write(Data("Checklist: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// Install probes need the same stage/estimate as the human diagnostic.
    /// MCP stdout remains exclusively protocol frames, including startup failure.
    static func upgradeErrorOutput(_ error: Error, command: String?) -> Data? {
        guard command != "mcp", StorageUpgradeStatus(error: error) != nil, let error = error as? ChecklistError,
              let bytes = try? JSONSerialization.data(withJSONObject: ["error": ["code": error.code, "message": error.message, "details": error.details]], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return JSONOutput.escapingStringControls(bytes)
    }

    /// Startup readiness is the existing unenrolled service_info projection.
    /// It neither bootstraps a session nor reads an installation credential.
    static func serviceStatus(installation: String, workspace: String, platformServices: LocalPlatformServices = .macOS) async throws -> Value {
        let client = ChecklistClient(installation: installation, workspace: workspace, usesStoredCredential: false, platformServices: platformServices)
        let bytes = try await client.callAsyncData("service_info", Data("{}".utf8), replyTimeout: 10)
        return try JSONDecoder().decode(Value.self, from: bytes)
    }

    static func call(arguments: Arguments, bridge: Bridge) async throws -> Value {
        guard arguments.command.count == 2 || arguments.command.count == 3 else { throw CLIError("Usage: checklist call METHOD '{JSON}' [--workspace PATH]") }
        let started = ProcessInfo.processInfo.systemUptime
        let data = try CallArgumentInput.read(arguments.command.count == 3 ? arguments.command[2] : "{}")
        let value = try JSONDecoder().decode(Value.self, from: data)
        let decoded = ProcessInfo.processInfo.systemUptime
        _ = try await bridge.connect()
        try await bridge.verifySession()
        let bound = ProcessInfo.processInfo.systemUptime
        defer {if CallTimingLog.enabled {CallTimingLog.write(["scope":"cli_call","argument_decode_ms":(decoded-started)*1000,"bootstrap_session_ms":(bound-decoded)*1000,"command_ms":(ProcessInfo.processInfo.systemUptime-bound)*1000])}}
        return try await bridge.call(arguments.command[1], value)
    }

    static func printJSON(_ value: Value, to output: FileHandle = .standardOutput) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        output.write(JSONOutput.escapingStringControls(try encoder.encode(value)))
        output.write(Data("\n".utf8))
    }

    private static func printHelp() {
        print("""
        Checklist — bundled coordination service and MCP adapter

          checklist mcp [--workspace /absolute/project] [--session PAIRED_ID]
          checklist connect [--task KEY_OR_UUID]
          checklist connect --assistant --project UUID_OR_EXACT_NAME
          checklist tools
          checklist service start|status
          checklist call METHOD '{"parameter":"value"}' [--workspace /absolute/project]
          checklist call METHOD -    (read at most 1 MiB of JSON from stdin)
          checklist version

        Run connect from a Codex or Claude conversation in its project directory.
        --task attaches this session to a ticket in that project without claiming or assigning work.
        A Dot-owned local Codex helper can use --assistant --project with connect, mcp, tools or call.
        This requires owner-enabled assistant grants for that project; it never grants worker access.
        The helper remains a local assistant relay, without claiming the cloud Dot's identity or delivery.
        MCP and call connect automatically when native context is available; no IDs or Settings form.
        In an unregistered folder, call project_create to create this conversation's own project and connect.
        Explicit --installation selects a previously configured nonautomatic integration.
        The MCP shim uses the official Swift MCP SDK over stdio; stdout contains only protocol frames.
        Existing checklists are never imported automatically. No model is launched.
        """)
    }
}
