import Foundation
import CoreFoundation

/// Display-only interpretation of the existing authorized owner snapshot.
/// Send-time snapshots supply identity anchors, never current receipt state.
struct RequestAnswerDeliveryProjection {
    struct Recipient: Identifiable {
        let id: String
        let label: String
        let receipt: String
    }
    let recipients: [Recipient]
    let summary: String

    static func make(request: Record, response: Record, messages: [Record], sessions: [Record], snapshotCurrent: Bool) -> Self {
        func unavailable() -> Self {
            .init(recipients: [], summary: (snapshotCurrent ? "Current delivery status is unavailable." : "Last known delivery status is unavailable.") + " The saved answer is unchanged.")
        }
        let project = request.string("project_id"), task = request.string("task_id")
        let form = revision(response, "form_revision"), identity = response.string("form_identity")
        guard present(project), present(task), present(request.id), present(response.id), present(identity),
              form != nil, response.string("origin") == "human_ui",
              request.records("responses").filter({ $0.id == response.id }).count == 1 else { return unavailable() }
        let forms = [request] + request.records("form_history")
        guard forms.filter({ revision($0, "form_revision") == form && $0.string("form_identity") == identity }).count == 1 else { return unavailable() }
        let latest = request.records("responses").last?.id == response.id
        let continuationID = request.string("continuation_message_id")
        if latest && !present(continuationID) { return unavailable() }
        let matching = messages.filter {
            present($0.id) && $0.string("project_id") == project && $0.string("task_id") == task &&
            $0.string("human_request_id") == request.id && $0.string("human_response_id") == response.id &&
            revision($0, "form_revision") == form && $0.string("origin") == "human_ui" &&
            (!latest || $0.id == continuationID)
        }
        guard matching.count == 1, let message = matching.first else { return unavailable() }
        let deliveries = message.records("deliveries")
        let anchors = latest ? request.records("continuation_deliveries") : []
        if deliveries.isEmpty && anchors.isEmpty && message.string("delivery_status") == "saved_for_pickup" {
            return .init(recipients: [], summary: snapshotCurrent ? "Saved on the ticket; no recipient delivery is observed." : "Last known delivery status: saved on the ticket with no recipient delivery.")
        }
        let currentPrefix = snapshotCurrent ? "" : "Last known · "
        var rows: [Recipient] = []
        for (index, delivery) in deliveries.enumerated() {
            let sid = delivery.string("recipient_session_id"), generation = delivery.string("recipient_authorization_generation")
            let fallbackLabel = historicalLabel(delivery)
            let uniqueDeliveryID = present(delivery.id) && deliveries.filter({ $0.id == delivery.id }).count == 1
            let rowID = uniqueDeliveryID ? "delivery:" + delivery.id : "unavailable-delivery:\(index)"
            guard uniqueDeliveryID, present(sid), present(generation),
                  delivery.string("project_id") == project, delivery.string("message_id") == message.id else {
                rows.append(.init(id: rowID, label: fallbackLabel, receipt: "Delivery status unavailable")); continue
            }
            let expected = anchors.filter { $0.id == delivery.id }
            if expected.count > 1 || expected.first.map({
                $0.string("project_id") != project || $0.string("message_id") != message.id ||
                $0.string("recipient_session_id") != sid || $0.string("recipient_authorization_generation") != generation
            }) == true {
                rows.append(.init(id: rowID, label: fallbackLabel, receipt: "Delivery status unavailable")); continue
            }
            // Current-handler routing mints its own generation-bound delivery.
            // The requester's historical generation fences only the extra
            // requester fallback, even when that requester later handles work.
            let handlerDelivery = ["handler", "registered_child", "coordinator"].contains(delivery.string("recipient_role"))
            if sid == request.string("requester_session_id"),
               request.string("requester_authorization_generation") != generation, !handlerDelivery {
                rows.append(.init(id: rowID, label: fallbackLabel, receipt: "Requester connection changed; delivery status unavailable")); continue
            }
            let availability = recipientAvailability(sessionID: sid, generation: generation, project: project, sessions: sessions)
            let label = availability.currentLabel ?? fallbackLabel
            let state = delivery.string("state")
            let receipt: String
            if state == "acknowledged" || state == "addressed" {
                // A later ended/revoked/replaced session does not erase this exact
                // generation's recorded ACK or attribute it to its replacement.
                receipt = currentPrefix + (state == "acknowledged" ? "Acknowledged" : "Addressed") + availability.historyQualifier
            } else if !availability.current {
                receipt = currentPrefix + "Unavailable · " + availability.reason
            } else {
                receipt = currentPrefix + stateLabel(state)
            }
            rows.append(.init(id: rowID, label: label, receipt: receipt))
        }
        for (index, anchor) in anchors.enumerated() where !deliveries.contains(where: { $0.id == anchor.id }) {
            rows.append(.init(id: "unavailable-anchor:\(index)", label: historicalLabel(anchor), receipt: "Delivery status unavailable"))
        }
        guard !rows.isEmpty else { return unavailable() }
        return .init(recipients: rows, summary: snapshotCurrent ? "Delivery status for this saved response." : "Last known delivery status. Checklist is disconnected; the saved answer is unchanged.")
    }

    private struct Availability {
        let current: Bool
        let currentLabel: String?
        let reason: String
        var historyQualifier: String { current ? "" : " · " + reason }
    }

    private static func recipientAvailability(sessionID: String, generation: String, project: String, sessions: [Record]) -> Availability {
        let matching = sessions.filter {
            $0.id == sessionID && ($0.string("project_id") == project || $0.strings("project_ids").contains(project))
        }
        guard matching.count == 1, let session = matching.first else {
            return .init(current: false, currentLabel: nil, reason: "previous session unavailable")
        }
        guard present(session.string("authorization_generation")), session.string("authorization_generation") == generation else {
            return .init(current: false, currentLabel: nil, reason: "previous connection")
        }
        if ["ended", "revoked"].contains(session.string("state")) {
            return .init(current: false, currentLabel: nil, reason: "session " + session.string("state"))
        }
        var allowed = session.string("role") == "worker"
        if session.string("role") == "assistant", let grants = session.object("assistant_grants")[project] as? [String: Bool] {
            allowed = grants["read"] == true && grants["receive_messages"] == true
        }
        guard allowed else { return .init(current: false, currentLabel: nil, reason: "message receipt unavailable") }
        let name = session.string("native_conversation_title", fallback: session.string("label"))
        return .init(current: true, currentLabel: present(name) && UUID(uuidString: name) == nil ? name : nil, reason: "")
    }

    private static func historicalLabel(_ delivery: Record) -> String {
        let label = delivery.string("recipient_display", fallback: delivery.string("recipient_label"))
        if present(label), UUID(uuidString: label) == nil { return label }
        let sid = delivery.string("recipient_session_id")
        return present(sid) ? "Agent · " + String(sid.prefix(8)) : "Recipient unavailable"
    }

    static func stateLabel(_ state: String) -> String {
        switch Canceled.normalized(state) {
        case "queued", "pending": return "Queued for agent pickup"
        case "saved", "saved_for_pickup": return "Saved for pickup"
        case "transport_written", "transport_accepted": return "Transport written; acknowledgment pending"
        case "provider_accepted": return "Provider accepted; acknowledgment pending"
        case "held", "held_for_approval": return "Waiting for provider approval"
        case "refused": return "Provider refused delivery"
        case "expired", "unavailable", "revoked", "ended", "canceled": return "Delivery unavailable"
        case "failed": return "Delivery failed"
        case "uncertain", "delivery_uncertain": return "Delivery outcome uncertain"
        default: return "Delivery status unavailable"
        }
    }

    private static func present(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private static func revision(_ record: Record, _ key: String) -> Int? {
        guard let number = record.values[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        var exact = number.decimalValue
        var integral = Decimal()
        NSDecimalRound(&integral, &exact, 0, .plain)
        guard !exact.isNaN, exact > 0, exact == integral, exact <= Decimal(Int.max) else { return nil }
        return NSDecimalNumber(decimal: exact).intValue
    }
}
