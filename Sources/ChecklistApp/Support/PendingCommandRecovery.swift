import ChecklistIPC
import Foundation
import CryptoKit

/// The service name is the native transport's bundle-derived Mach endpoint, not
/// an editable preference or a service display name. Store identity comes from
/// that endpoint's accepted service read.
struct PendingCommandRecovery {
    let method: String
    let params: [String: Any]
    let storeIncarnation: String
    let serviceIdentity: String

    init(method: String, params: [String: Any], storeIncarnation: String, serviceIdentity: String) {
        self.method = method; self.params = params
        self.storeIncarnation = storeIncarnation; self.serviceIdentity = serviceIdentity
    }
    /// A saved record never holds a claim token in plain form. It holds the attempt ID and the
    /// token's SHA-256, and recovery resolves the exact token from the private claim file.
    init?(saved: String, claimToken: (String) -> String?) {
        guard let record = (try? JSONSerialization.jsonObject(with: Data(saved.utf8))) as? [String: Any],
              let method = record["method"] as? String, !method.isEmpty,
              var params = record["params"] as? [String: Any],
              !Self.containsClaimToken(params),
              let commandID = params["command_id"] as? String, UUID(uuidString: commandID) != nil,
              let incarnation = record["store_incarnation"] as? String, !incarnation.isEmpty,
              let identity = record["service_identity"] as? String, !identity.isEmpty else { return nil }
        if let reference = params.removeValue(forKey: Self.claimReferenceKey) {
            guard let attempt = (reference as? [String: Any])?["attempt_id"] as? String, attempt == params["attempt_id"] as? String,
                  let digest = (reference as? [String: Any])?["sha256"] as? String,
                  let token = claimToken(attempt), Self.digest(token) == digest else { return nil }
            params[Self.claimTokenKey] = token
        }
        self.init(method: method, params: params, storeIncarnation: incarnation, serviceIdentity: identity)
    }
    func matches(storeIncarnation: String, serviceIdentity: String) -> Bool {
        self.storeIncarnation.utf8.elementsEqual(storeIncarnation.utf8) && self.serviceIdentity.utf8.elementsEqual(serviceIdentity.utf8)
    }
    func encoded() throws -> String {
        var stored = params
        if let token = stored.removeValue(forKey: Self.claimTokenKey) {
            guard let token = token as? String, let attempt = stored["attempt_id"] as? String, !attempt.isEmpty else { throw Self.unsafeCredential }
            stored[Self.claimReferenceKey] = ["attempt_id": attempt, "sha256": Self.digest(token)]
        }
        guard !Self.containsClaimToken(stored) else { throw Self.unsafeCredential }
        let data = try JSONSerialization.data(withJSONObject: ["method": method, "params": stored,
            "store_incarnation": storeIncarnation, "service_identity": serviceIdentity], options: .sortedKeys)
        return String(decoding: data, as: UTF8.self)
    }
    static func marker(_ saved: String) -> String { digest(saved) }
    private static let claimTokenKey = "claim_token"
    private static let claimReferenceKey = "claim_token_ref"
    private static let unsafeCredential = ChecklistError("UNSAFE_RECOVERY_RECORD", "This change holds a claim credential that cannot be saved without its plain value. Report this to the Checklist project; nothing was sent.")
    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func containsClaimToken(_ value: Any) -> Bool {
        if let values = value as? [String: Any] { return values[claimTokenKey] != nil || values.values.contains(where: containsClaimToken) }
        if let values = value as? [Any] { return values.contains(where: containsClaimToken) }
        return false
    }
    var marker: String { Self.marker((try? encoded()) ?? "") }
}
