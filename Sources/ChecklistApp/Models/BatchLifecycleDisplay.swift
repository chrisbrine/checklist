import Foundation

struct BatchLifecycleDisplay {
    let label: String
    let date: String
    let reason: String
    init(_ batch: Record) {
        switch batch.string("lifecycle",fallback:"prepared") {
        case "discarded":
            label = "Discarded";date = batch.object("disposition")["created_at"] as? String ?? ""
            reason = batch.object("disposition")["reason"] as? String ?? ""
        case "claimed":
            label = "Claimed";date = batch.object("dispatch")["created_at"] as? String ?? "";reason = ""
        default:
            label = "Prepared";date = batch.string("created_at");reason = ""
        }
    }
}
