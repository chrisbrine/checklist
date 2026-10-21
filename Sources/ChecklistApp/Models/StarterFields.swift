import Foundation

/// CL-68: the optional starter fields that Bug and Playtest capture offers. The service stores them
/// as structured ticket data (`starter_fields`); none of them is required to save a Draft.
struct StarterField: Identifiable, Equatable {
    let key: String
    let label: String
    let prompt: String
    let multiline: Bool
    var id: String { key }
}

enum StarterFields {
    static func fields(for kind: String) -> [StarterField] {
        switch kind {
        case "bug": return [
            StarterField(key: "reproduction", label: "Steps to reproduce", prompt: "1. Open… 2. Press… 3. See…", multiline: true),
            StarterField(key: "expected", label: "Expected result", prompt: "What should happen", multiline: false),
            StarterField(key: "actual", label: "Actual result", prompt: "What happens instead", multiline: false),
        ]
        case "playtest": return [
            StarterField(key: "build", label: "Build", prompt: "Build number, version or file", multiline: false),
            StarterField(key: "platform", label: "Platform", prompt: "For example macOS, iPhone, Steam Deck", multiline: false),
            StarterField(key: "clip", label: "Clip", prompt: "Link or file name; attach the clip file below", multiline: false),
        ]
        default: return []
        }
    }

    /// The non-empty fields that belong to this kind, ready to send as `starter_fields`.
    static func parameters(_ values: [String: String], kind: String) -> [String: String] {
        let keys = Set(fields(for: kind).map(\.key))
        return values.filter { keys.contains($0.key) && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The stored fields of a ticket, in the order capture shows them, for the ticket detail.
    static func display(_ stored: [String: Any], kind: String) -> [(label: String, value: String)] {
        let known = fields(for: kind)
        var rows = known.compactMap { field in (stored[field.key] as? String).flatMap { $0.isEmpty ? nil : (field.label, $0) } }
        let other = stored.keys.filter { key in !known.contains { $0.key == key } }.sorted()
        rows += other.compactMap { key in (stored[key] as? String).map { (key.capitalized, $0) } }
        return rows
    }
}
