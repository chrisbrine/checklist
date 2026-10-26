import Foundation
import ChecklistProviders
import GRDB

extension CommandRouter {
    static let hostDeliveryStates = ["held":"held_for_approval","refused":"refused","expired":"unavailable"]

    private func nativeDeliveryHostReason(_ db: Database, delivery: JSON, status: String) throws -> String {
        let projectID = try StoredRecord(delivery, family: "delivery").string("project_id")
        let session = try scoped(db, delivery["recipient_session_id"] as? String ?? "", projectID, type: "session")
        return providerPlugins.plugin(session["provider"] as? String ?? "", requiring: .nativePeer)?.hostStatusReason(status)
            ?? "The native host reported \(status). The note remains available through Checklist pickup."
    }

    /// Records the recipient host's own notice about a native delivery. A host status is
    /// never acknowledgment, never starts a retry and is kept apart from the write receipt.
    func deliveryHostStatus(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try owner(c); guard c.installation == "native-bridge" else { throw CoreError("FORBIDDEN","This command is reserved for the bundled delivery service.") }
        var d = try record(db,try text(p,"delivery_id"),type:"delivery")
        let status = try text(p,"status")
        guard let state = Self.hostDeliveryStates[status] else { throw CoreError("INVALID_INPUT","This native host status is not qualified.") }
        // An exact recipient acknowledgment outranks a late host notice.
        if ["acknowledged","addressed"].contains(d["state"] as? String ?? "") { return d }
        d["host_status"] = status; d["host_status_receipt"] = p["receipt"] ?? [:]; d["host_status_at"] = now()
        d["state"] = state
        d["reason"] = try nativeDeliveryHostReason(db, delivery: d, status: status)
        d = revised(d); try save(db,d,type:"delivery")
        try event(db,caller:c,project:d["project_id"] as? String,entity:d["message_id"] as? String,kind:"delivery_host_status",data:["status":status])
        return d
    }
}
