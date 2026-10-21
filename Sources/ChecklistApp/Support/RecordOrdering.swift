import Foundation

/// Presentation ordering only. Service context/history preserves its own chronological contract.
enum RecordOrdering {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let standard = ISO8601DateFormatter()

    static func newestFirst(_ records: [Record], timestamp: String = "created_at", chronologicalInput: Bool = false) -> [Record] {
        records.enumerated().sorted { left, right in
            let leftDate = date(left.element.string(timestamp))
            let rightDate = date(right.element.string(timestamp))
            if leftDate != rightDate { return leftDate > rightDate }
            // Message snapshots preserve creation order. Their input position resolves
            // coarse timestamps without exposing the service's private sequence.
            if chronologicalInput { return left.offset > right.offset }
            return left.element.id > right.element.id
        }.map(\.element)
    }
    private static func date(_ value: String) -> Date {
        fractional.date(from: value) ?? standard.date(from: value) ?? .distantPast
    }
}
