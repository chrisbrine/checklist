import ChecklistMCPServer

/// Capture replacement monitoring before native discovery for the persistent MCP shim.
enum CLIStartup {
    static func shimUpdate(for command: String?, capture: () -> ShimUpdateEnvironment = ShimUpdateEnvironment.capture) -> ShimUpdateEnvironment? {
        guard command == "mcp" else { return nil }
        return capture()
    }
}
