import Foundation
import CoreServices

/// The app writes and shows one spelling, "canceled". Records from older stores or imports may still
/// carry the British spelling as a data value; this is the only place that names it.
enum Canceled {
    static let value = "canceled"
    static func normalized(_ value: String) -> String { value == "cancelled" ? Self.value : value }
    static func matches(_ value: String) -> Bool { normalized(value) == Self.value }
    /// Keep macOS's native error spelling at this boundary too, and do not
    /// mistake the same numeric code from an unrelated domain for cancellation.
    static func isUserCancellation(_ error: Error) -> Bool {
        let value = error as NSError
        return (value.domain == NSCocoaErrorDomain && value.code == NSUserCancelledError)
            || (value.domain == NSOSStatusErrorDomain && value.code == Int(userCanceledErr))
    }
}

/// Service identifiers shown as text (event types, record types, states) use the glossary words (CL-56).
enum GlossaryText {
    static func humanize(_ identifier: String) -> String {
        var words = identifier.replacingOccurrences(of: "_", with: " ").split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let map = ["task": "ticket", "tasks": "tickets", "Task": "Ticket", "Tasks": "Tickets", "subproject": "Epic", "subprojects": "Epics",
                   "cancelled": Canceled.value, "Cancelled": "Canceled"]
        words = words.map { map[$0] ?? $0 }
        return words.joined(separator: " ")
    }
    /// A stored state as a label: glossary words, first letter capitalized ("cancelled" -> "Canceled").
    static func title(_ identifier: String) -> String {
        let text = humanize(identifier)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
