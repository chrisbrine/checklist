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
    init?(saved: String) {
        guard let record = (try? JSONSerialization.jsonObject(with: Data(saved.utf8))) as? [String: Any],
              let method = record["method"] as? String, !method.isEmpty,
              let params = record["params"] as? [String: Any],
              let commandID = params["command_id"] as? String, UUID(uuidString: commandID) != nil,
              let incarnation = record["store_incarnation"] as? String, !incarnation.isEmpty,
              let identity = record["service_identity"] as? String, !identity.isEmpty else { return nil }
        self.init(method: method, params: params, storeIncarnation: incarnation, serviceIdentity: identity)
    }
    func matches(storeIncarnation: String, serviceIdentity: String) -> Bool {
        self.storeIncarnation.utf8.elementsEqual(storeIncarnation.utf8) && self.serviceIdentity.utf8.elementsEqual(serviceIdentity.utf8)
    }
    func encoded() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["method": method, "params": params,
            "store_incarnation": storeIncarnation, "service_identity": serviceIdentity], options: .sortedKeys)
        return String(decoding: data, as: UTF8.self)
    }
    static func marker(_ saved: String) -> String {
        SHA256.hash(data: Data(saved.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var marker: String { Self.marker((try? encoded()) ?? "") }
}
