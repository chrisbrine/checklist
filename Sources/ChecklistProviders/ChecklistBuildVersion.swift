import Foundation

/// All shipping executables read the same immutable bundle metadata.
public struct ChecklistBuildVersion: Equatable, Sendable {
    public let version: String
    public let buildID: String
    public let buildNumber: Int

    public init(metadata: [String: Any]) {
        let value = metadata["version"] as? String ?? ""
        version = value.range(of: "^[0-9]+(?:\\.[0-9]+){3}$", options: .regularExpression) != nil ? value : "development"
        let id = metadata["build_id"] as? String ?? ""
        buildID = id.range(of: "^[a-f0-9]{16,64}$", options: .regularExpression) != nil ? id : "development"
        buildNumber = metadata["build_number"] as? Int ?? 0
    }

    public static func read(executable: URL?) -> Self {
        guard let executable,
              let bytes = try? Data(contentsOf: executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/build-info.json")),
              let metadata = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return Self(metadata: [:]) }
        return Self(metadata: metadata)
    }

    public static let current = read(executable: Bundle.main.executableURL)
}
