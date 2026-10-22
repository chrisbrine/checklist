import Foundation
import Darwin

/// Owner-app local inspection only. No process, SDK installation, settings writer,
/// authentication file, model launch or provider request exists in this adapter.
public enum ProviderSettingsObservation {
    public static let maximumBytes = 256 * 1024

    public static func read(_ scope: ProviderSettingSource.Scope, path: String) -> ProviderSettingSource {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .init(scope, path, errno == ENOENT ? .missing : .unreadable) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= maximumBytes else { return .init(scope, path, .unsupported) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while data.count <= maximumBytes {
            let count = Darwin.read(fd, &buffer, min(buffer.count, maximumBytes + 1 - data.count))
            if count < 0 { return .init(scope, path, .unreadable) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximumBytes else { return .init(scope, path, .unsupported) }
        guard let object = try? JSONSerialization.jsonObject(with: data), let json = object as? [String: Any] else {
            return .init(scope, path, .invalid)
        }
        guard let raw = json["crossSessionInbound"] else { return .init(scope, path, .unset) }
        guard let text = raw as? String, let value = InboundSetting(rawValue: text) else { return .init(scope, path, .invalid) }
        return .init(scope, path, .value(value))
    }

    public static func observe(projectRoot: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               managedPath: String = "/Library/Application Support/ClaudeCode/managed-settings.json",
                               now: Date = Date()) -> ProviderReadinessObservation {
        let configured = environment["CLAUDE_CONFIG_DIR"]
        let config = configured.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil } ?? home.appendingPathComponent(".claude")
        let userPath = config.appendingPathComponent("settings.json").path
        var sources = [read(.user, path: userPath), read(.managed, path: managedPath)]
        var missing = ["MDM, server-managed policy, policyHelper and embedding-host policy",
                       "Session/flag settings and enabled setting sources",
                       "Recipient's live primary directory and CLAUDE_CONFIG_DIR (app environment is only a candidate)"]
        if configured != nil && configured?.hasPrefix("/") != true { missing.append("App CLAUDE_CONFIG_DIR is relative or invalid; showing default user path") }
        if projectRoot.hasPrefix("/") {
            let root = URL(fileURLWithPath: projectRoot).standardizedFileURL
            sources.append(read(.project, path: root.appendingPathComponent(".claude/settings.json").path))
            let local = root.appendingPathComponent(".claude/settings.local.json").path
            sources.append(read(.local, path: local))
            // The local file may be at a main repository root, including a
            // different checkout for worktrees. Do not guess or run Git/Claude.
            missing.append("Repository/main-worktree local settings root and legacy local-file precedence")
        } else { missing.append("Selected project's absolute workspace root") }
        let result = ClaudeMessageReadiness.resolve(.init(sources: sources, missingInputs: missing, senderClass: "prompting"))
        return .init(observedAt: now, userPath: userPath, sources: sources, claude: result)
    }
}
