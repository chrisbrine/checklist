/// Plain labels for note delivery receipts (CL-55). The app never shows a raw state name;
/// the raw value stays in the note's Technical details.
enum DeliveryLabels {
    static func receipt(_ state: String) -> String {
        switch Canceled.normalized(state) {
        case "queued", "pending": return "Queued for agent pickup"
        case "saved", "saved_for_pickup": return "Saved for pickup"
        case "fenced": return "Not delivered: this conversation was disconnected"
        case "transport_written", "transport_accepted", "transport_receipt": return "Transport accepted"
        case "provider_accepted": return "Provider accepted"
        case "acknowledged": return "Acknowledged"
        case "addressed": return "Addressed"
        case "held", "held_for_approval": return "Waiting for approval"
        case "refused": return "Provider refused delivery"
        case "failed": return "Delivery failed"
        case "uncertain", "delivery_uncertain": return "Delivery outcome uncertain"
        case "expired", "unavailable", "ended": return "Delivery unavailable"
        case "canceled", "revoked": return "Delivery stopped"
        default: return "Delivery status unavailable"
        }
    }
}
