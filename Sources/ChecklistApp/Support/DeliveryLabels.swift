import Foundation

/// Plain labels for note delivery receipts (CL-55). The app never shows a raw state name;
/// the raw value stays in the note's Technical details.
enum DeliveryLabels {
    /// A delivery shows Replied only with an actual correlated reply; a missing
    /// reply keeps the delivery's own state and never reads as failure,
    /// acknowledgment or completion (CL-126).
    static func receipt(delivery: Record) -> String {
        if !delivery.string("reply_message_id").isEmpty || !delivery.string("replied_at").isEmpty { return receipt("replied") }
        return receipt(delivery.string("state"))
    }
    /// The service keeps no reply field on a delivery (CL-248 correlates a reply by
    /// `reply_to`). A delivery reads Replied only when a loaded note answers this note
    /// and its author is that delivery's recipient session; the app then sets
    /// `reply_message_id` on its in-memory copy. Notes without loaded receipts are unchanged.
    static func correlateReplies(_ messages: [Record]) -> [Record] {
        var replies: [Data: [Data: String]] = [:]
        for message in messages where !message.string("reply_to").isEmpty && !message.string("author_session_id").isEmpty {
            let original = Data(message.string("reply_to").utf8), author = Data(message.string("author_session_id").utf8)
            if replies[original]?[author] == nil { replies[original, default: [:]][author] = message.id }
        }
        guard !replies.isEmpty else { return messages }
        return messages.map { message in
            guard let authors = replies[Data(message.id.utf8)], message.values["deliveries"] != nil else { return message }
            var values = message.values
            values["deliveries"] = message.records("deliveries").map { delivery -> [String: Any] in
                var item = delivery.values
                if delivery.string("reply_message_id").isEmpty, let reply = authors[Data(delivery.string("recipient_session_id").utf8)] { item["reply_message_id"] = reply }
                return item
            }
            return Record(values: values)
        }
    }
    static func receipt(_ state: String) -> String {
        switch Canceled.normalized(state) {
        case "queued", "pending": return "Queued for agent pickup"
        case "saved", "saved_for_pickup": return "Saved for pickup"
        case "fenced": return "Not delivered: this conversation was disconnected"
        case "transport_written", "transport_accepted", "transport_receipt": return "Transport accepted"
        case "provider_accepted": return "Provider accepted"
        case "acknowledged": return "Acknowledged"
        case "replied": return "Replied"
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
