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
    /// Seconds for `checklist call --wait[=SECONDS]`.
    var wait: TimeInterval?

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
            case "--wait":
                guard wait == nil else { throw CLIError("Specify --wait only once.") }
                wait = OperationWait.defaultCommandLineWait
            case _ where argument.hasPrefix("--wait="):
                guard wait == nil else { throw CLIError("Specify --wait only once.") }
                guard let seconds = TimeInterval(argument.dropFirst("--wait=".count)), seconds.isFinite, seconds > 0, seconds <= OperationWait.longestCommandLineWait else {
                    throw CLIError("--wait=SECONDS requires a number above 0 and at most \(Int(OperationWait.longestCommandLineWait)).")
                }
                wait = seconds
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
        if wait != nil, command.first != "call" { throw CLIError("--wait is supported only by checklist call.") }
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
    static func main() {
        let started = ProcessInfo.processInfo.systemUptime
        let rawArguments = Array(CommandLine.arguments.dropFirst())
        // Hooks exit successfully and keep stdout empty even on startup errors.
        if rawArguments.first == CodexPostToolHook.command {
            runAsync {
                await CodexPostToolHook.main(rawArguments)
                return 0
            }
        }
        var commandName: String?
        do {
            try DelegateInstanceExpectation.verifyIfPresent(instance: ChecklistInstance.current)
            let instanceReady = ProcessInfo.processInfo.systemUptime
            let arguments = try Arguments(rawArguments)
            let parsed = ProcessInfo.processInfo.systemUptime
            let command = arguments.command.first ?? "help"
            commandName = command
            switch command {
            case "service":
                logSetup(started: started, instanceReady: instanceReady, parsed: parsed, captured: parsed)
                guard arguments.command.count == 2, ["start", "status"].contains(arguments.command[1]) else {
                    throw CLIError("Usage: checklist service start|status [--installation NAME]")
                }
                // The standalone main thread can wait for XPC without an executor hop.
                try printJSON(serviceStatus(installation: arguments.installation, workspace: arguments.workspace))
            case "help", "--help", "-h":
                logSetup(started: started, instanceReady: instanceReady, parsed: parsed, captured: parsed)
                printHelp()
            case "version", "--version":
                logSetup(started: started, instanceReady: instanceReady, parsed: parsed, captured: parsed)
                let build = ChecklistBuildVersion.current
                print("Checklist \(build.version) · build \(build.buildID) (\(build.buildNumber)) · MCP Swift SDK 0.12.1")
            case "connect", "mcp", "tools", "call":
                let update = CLIStartup.shimUpdate(for: command)
                let captured = ProcessInfo.processInfo.systemUptime
                let bridge = makeBridge(arguments: arguments, command: command, update: update)
                logSetup(started: started, instanceReady: instanceReady, parsed: parsed, captured: captured)
                runAsync {
                    do {
                        let status = try await perform(arguments: arguments, command: command, bridge: bridge)
                        if status == 0 { logFinish(started: started) }
                        return status
                    } catch {
                        reportFailure(error, command: command)
                        return 1
                    }
                }
            default:
                logSetup(started: started, instanceReady: instanceReady, parsed: parsed, captured: parsed)
                throw CLIError("Unknown command. Run checklist help.")
            }
            logFinish(started: started)
        } catch {
            reportFailure(error, command: commandName)
            exit(1)
        }
    }

    private static func runAsync(_ body: @escaping @Sendable () async -> Int32) -> Never {
        Task { exit(await body()) }
        dispatchMain()
    }

    private static func makeBridge(arguments: Arguments, command: String, update: ShimUpdateEnvironment?) -> Bridge {
        let environment: BridgeEnvironment
        if command == "call", arguments.command.dropFirst().first == "service_info" {
            // Bootstrap and the authenticated read use the same admitted peer.
            let platform = LocalPlatformServices.macOS(reusingConnection: true)
            environment = .init(makeClient: { configuration in
                ChecklistClient(installation: configuration.installation, workspace: configuration.workspace,
                                nativeContext: configuration.nativeContext, usesStoredCredential: configuration.usesStoredCredential,
                                platformServices: platform)
            })
        } else {
            environment = .init(shimUpdate: update)
        }
        return Bridge(configuration: .init(installation: arguments.installation, workspace: arguments.workspace,
                      expectedSession: arguments.session, automatic: !arguments.installationExplicit,
                      assistantProject: arguments.assistant ? arguments.project : nil, command: command),
                      environment: environment)
    }

    private static func perform(arguments: Arguments, command: String, bridge: Bridge) async throws -> Int32 {
        switch command {
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
        case "call":
            let reply = try await call(arguments: arguments, bridge: bridge)
            try printJSON(reply)
            if arguments.wait != nil, OperationWait.isUnfinished(reply) { return OperationWait.unfinishedExitCode }
        default:
            preconditionFailure("Only the asynchronous commands enter this route.")
        }
        return 0
    }

    private static func logSetup(started: TimeInterval, instanceReady: TimeInterval, parsed: TimeInterval, captured: TimeInterval) {
        guard CallTimingLog.enabled else { return }
        let finished = ProcessInfo.processInfo.systemUptime
        CallTimingLog.write(["scope": "cli_setup", "main_entered_uptime_s": started,
            "instance_ms": (instanceReady - started) * 1000, "arguments_ms": (parsed - instanceReady) * 1000,
            "shim_capture_ms": (captured - parsed) * 1000, "bridge_ms": (finished - captured) * 1000,
            "total_ms": (finished - started) * 1000])
    }

    private static func logFinish(started: TimeInterval) {
        if CallTimingLog.enabled {
            CallTimingLog.write(["scope": "cli", "total_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000])
        }
    }

    private static func reportFailure(_ error: Error, command: String?) {
        if let status = upgradeErrorOutput(error, command: command) {
            FileHandle.standardOutput.write(status)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        FileHandle.standardError.write(Data("Checklist: \(error.localizedDescription)\n".utf8))
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
    static func serviceStatus(installation: String, workspace: String, platformServices: LocalPlatformServices = .macOS) throws -> Value {
        let client = ChecklistClient(installation: installation, workspace: workspace, usesStoredCredential: false, platformServices: platformServices)
        return try mcpValue(client.call("service_info", replyTimeout: 10))
    }

    static func call(arguments: Arguments, bridge: Bridge) async throws -> Value {
        guard arguments.command.count == 2 || arguments.command.count == 3 else { throw CLIError("Usage: checklist call [--wait[=SECONDS]] METHOD '{JSON}' [--workspace PATH]") }
        let started = ProcessInfo.processInfo.systemUptime
        let data = try CallArgumentInput.read(arguments.command.count == 3 ? arguments.command[2] : "{}")
        let value = try JSONDecoder().decode(Value.self, from: data)
        let decoded = ProcessInfo.processInfo.systemUptime
        try await bridge.prepareDirectCall()
        let bound = ProcessInfo.processInfo.systemUptime
        defer {if CallTimingLog.enabled {CallTimingLog.write(["scope":"cli_call","argument_decode_ms":(decoded-started)*1000,"bootstrap_session_ms":(bound-decoded)*1000,"command_ms":(ProcessInfo.processInfo.systemUptime-bound)*1000])}}
        // operation_wait runs in this adapter, as it does for MCP.
        let name = arguments.command[1]
        let reply = name == OperationWait.toolName ? try await bridge.concurrentCall(name, value) : try await bridge.call(name, value)
        guard let limit = arguments.wait else { return reply }
        return try await bridge.finalReply(to: reply, arguments: value, limit: limit)
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
          checklist call --wait[=SECONDS] METHOD '{"parameter":"value"}'
          checklist codex-post-tool    (Codex PostToolUse hook; reads hook JSON from stdin)
          checklist version

        Run connect from a Codex or Claude conversation in its project directory.
        --task attaches this session to a ticket in that project without claiming or assigning work.
        A Dot-owned local Codex helper can use --assistant --project with connect, mcp, tools or call.
        This requires owner-enabled assistant grants for that project; it never grants worker access.
        The helper remains a local assistant relay, without claiming the cloud Dot's identity or delivery.
        MCP and call connect automatically when native context is available; no IDs or Settings form.
        In an unregistered folder, call project_create to create this conversation's own project and connect.
        --wait (default 120 s) reads an accepted long command until its final reply, and prints that reply as
        a plain call would. A failed command exits 1. After the wait it prints the operation with its state
        and wait.finished=false and exits 124; the command can still be running, so read operation_get.
        Explicit --installation selects a previously configured nonautomatic integration.
        The MCP shim uses the official Swift MCP SDK over stdio; stdout contains only protocol frames.
        Existing checklists are never imported automatically. No model is launched.
        """)
    }
}
