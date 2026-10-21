import SwiftUI

// This is the displayed order, including held list positions and expanded members.
enum TicketKeyboardNavigation {
    static func destination(in ids: [String], current: String?, forward: Bool) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(where: { RecordIdentity($0) == RecordIdentity(current) }) else {
            return forward ? ids.first : ids.last
        }
        let next = index + (forward ? 1 : -1)
        return ids.indices.contains(next) ? ids[next] : nil
    }
    static func order(_ rows: [TicketListRow]) -> [String] {
        var seen = Set<RecordIdentity>()
        return rows.compactMap { row in
            let task: Record
            switch row.content {
            case .ticket(let value), .triageMember(let value): task = value
            default: return nil
            }
            return seen.insert(RecordIdentity(task.id)).inserted ? task.id : nil
        }
    }
}

private struct TicketOrderKey: FocusedValueKey { typealias Value = [String] }
extension FocusedValues {
    var checklistTicketOrder: [String]? {
        get { self[TicketOrderKey.self] }
        set { self[TicketOrderKey.self] = newValue }
    }
}
