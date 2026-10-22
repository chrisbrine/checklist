import Foundation
import CryptoKit

/// Stable before and after the atomic project/session commit, including a lost
/// reply. The service supplies verified native identity and canonical workspace.
public enum NativeWorkspaceCreation {
    public static func installation(provider: String, session: String, workspace: String) -> String {
        "auto-\(provider)-\(digest("\(provider)|\(session)|workspace|\(workspace)").prefix(40))"
    }

    public static func generation(provider: String, session: String, workspace: String, executionDomain: String) -> String {
        String(digest("\(provider)|\(session)|workspace|\(workspace)|\(executionDomain)").prefix(40))
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
