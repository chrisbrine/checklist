import Foundation
import GRDB

extension CommandRouter {
    static let hostDeliveryStates = ["held":"held_for_approval","refused":"refused","expired":"unavailable"]
    static let hostStatusReasons = [
        "held":"Claude is holding this note because the conversation's permission setting differs from Checklist's. Claude Desktop may show no approval control. To let Checklist notes through automatically, set Claude Code's crossSessionInbound setting to accept. The note stays available at the agent's next Checklist check.",
        "refused":"Claude refused this native delivery. The note stays available at the agent's next Checklist check.",
        "expired":"Claude's approval hold expired without delivery. The note stays available at the agent's next Checklist check."
    ]

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
        d["state"] = state; d["reason"] = Self.hostStatusReasons[status]
        d = revised(d); try save(db,d,type:"delivery")
        try event(db,caller:c,project:d["project_id"] as? String,entity:d["message_id"] as? String,kind:"delivery_host_status",data:["status":status])
        return d
    }
}
