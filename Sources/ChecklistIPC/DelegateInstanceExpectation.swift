import Foundation

/// This value restricts a delegated CLI. It grants no service or host authority.
public struct DelegateInstanceExpectation: Codable, Sendable {
    public static let environmentKey = "CHECKLIST_DELEGATE_INSTANCE"
    public let slot: Int?
    public let bundleIdentifier: String
    public let machServiceName: String
    public let bundleRoot: String

    public init(instance: ChecklistInstance, bundleRoot: URL) {
        slot = instance.slot; bundleIdentifier = instance.bundleIdentifier
        machServiceName = instance.machServiceName; self.bundleRoot = bundleRoot.path
    }

    public func encoded() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    public static var mismatch: ChecklistError {
        ChecklistError("DELEGATE_INSTANCE_MISMATCH", "The delegated CLI does not match the expected Checklist instance; no command ran. Reconnect the checklist MCP server.",
                       details: ["command_outcome": "not_sent", "command_executed": false])
    }

    /// Call immediately after resolving the current instance, before any IPC, Keychain or bootstrap.
    public static func verifyIfPresent(instance: ChecklistInstance,
                                      executable: URL = ChecklistInstance.executableURL,
                                      environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let raw = environment[environmentKey] else { return }
        guard raw.utf8.count <= 16_384,
              let expected = try? JSONDecoder().decode(Self.self, from: Data(raw.utf8)),
              let bundle = instance.bundleURL?.resolvingSymlinksInPath(), bundle.path == expected.bundleRoot,
              instance.slot == expected.slot, instance.bundleIdentifier == expected.bundleIdentifier,
              instance.machServiceName == expected.machServiceName else { throw mismatch }
        let resolved = executable.resolvingSymlinksInPath()
        let macOS = resolved.deletingLastPathComponent(), contents = macOS.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              contents.deletingLastPathComponent() == bundle,
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == expected.bundleIdentifier else { throw mismatch }
    }
}
