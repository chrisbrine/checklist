import Foundation

/// A user-scope MCP registration also starts in native conversations whose folder
/// is not a Checklist project. Only `checklist mcp` and `checklist tools` then
/// continue without an enrollment: no project is selected, no stored credential is
/// used and only `service_info` is advertised. `checklist connect`, `call`,
/// assistant relays and permanent bootstrap failures still stop with the error.
/// ClaudeRegistryStart handles the separate spare-process registry race.
public enum UnregisteredWorkspaceStart {
    public static let errorCode = "PROJECT_SETUP_REQUIRED"
    static let commands: Set<String> = ["mcp", "tools"]

    public static func applies(errorCode code: String, command: String, assistantRelay: Bool) -> Bool {
        code == errorCode && commands.contains(command) && !assistantRelay
    }

    public static func notice(workspace: String) -> String {
        "\(errorCode): This conversation's folder is not an active Checklist project: \(workspace). Only service_info is available. To use Checklist here, add this folder as a project in the Checklist app, then restart this MCP connection. Existing checklists are never imported automatically."
    }
}
