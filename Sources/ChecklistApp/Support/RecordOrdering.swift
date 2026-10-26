import Foundation

/// Presentation ordering only. Service context/history preserves its own chronological contract.
enum RecordOrdering {
    /// Only immutable timestamp parsing is cached, never relative ages, records,
    /// project state or authority. Bound retained key bytes and formatter access.
    private final class TimestampCache: @unchecked Sendable {
        private let lock = NSLock()
        private let fractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        private let standard = ISO8601DateFormatter()
        private var values: [String:Date] = [:]
        func date(_ value: String) -> Date {
            lock.lock();defer {lock.unlock()}
            if let date = values[value] {return date}
            let date: Date
            if value.contains(".") {date = fractional.date(from:value) ?? standard.date(from:value) ?? .distantPast}
            else {date = standard.date(from:value) ?? fractional.date(from:value) ?? .distantPast}
            if value.utf8.count <= 128 {
                if values.count >= 1_024 {values.removeAll(keepingCapacity:true)}
                values[value] = date
            }
            return date
        }
    }
    private static let timestamps = TimestampCache()

    static func newestFirst(_ records: [Record], timestamp: String = "created_at", chronologicalInput: Bool = false) -> [Record] {
        // Decorate once. Parsing from the comparator repeats ICU work for every
        // comparison, especially for a page of equal coarse timestamps.
        records.enumerated().map { (offset:$0.offset, record:$0.element, date:timestamps.date($0.element.string(timestamp))) }.sorted { left, right in
            if left.date != right.date { return left.date > right.date }
            // Message snapshots preserve creation order. Their input position resolves
            // coarse timestamps without exposing the service's private sequence.
            if chronologicalInput { return left.offset > right.offset }
            return left.record.id > right.record.id
        }.map(\.record)
    }
}
