import Foundation

/// CL-68: optional starter fields for Bug and Playtest tickets. They are structured ticket data
/// (docs/ticket-fields.md), never required, and they appear in task_get and task_context.
extension CommandRouter {
    static let starterFieldLimits: [String: [String: Int]] = [
        "bug": ["reproduction": 16_000, "expected": 4000, "actual": 4000],
        "playtest": ["build": 500, "platform": 200, "clip": 2000],
    ]

    /// Returns the fields to store for this kind, or nil when every field is empty.
    func validatedStarterFields(_ value: Any?, kind: String) throws -> JSON? {
        guard let value, !(value is NSNull) else { return nil }
        guard let fields = value as? JSON else { throw CoreError("INVALID_INPUT", "starter_fields must be an object of text fields.") }
        let allowed = Self.starterFieldLimits[kind] ?? [:]
        var result: JSON = [:]
        for (key, raw) in fields {
            guard let limit = allowed[key] else {
                throw CoreError("INVALID_INPUT", "A \(kind) ticket has no starter field \(key). Bug tickets take reproduction, expected and actual; Playtest tickets take build, platform and clip.")
            }
            guard let text = raw as? String else { throw CoreError("INVALID_INPUT", "The starter field \(key) must be text.") }
            guard text.utf8.count <= limit else { throw CoreError("INVALID_INPUT", "The starter field \(key) exceeds its text limit.") }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result[key] = text }
        }
        return result.isEmpty ? nil : result
    }

    /// A kind change keeps only the fields the new kind uses. The removed text stays in the edit's history event.
    func starterFieldsForKindChange(_ task: inout JSON, newKind: String) -> JSON {
        guard let current = task["starter_fields"] as? JSON else { return [:] }
        let allowed = Self.starterFieldLimits[newKind] ?? [:]
        let removed = current.filter { allowed[$0.key] == nil }
        let kept = current.filter { allowed[$0.key] != nil }
        if kept.isEmpty { task.removeValue(forKey: "starter_fields") } else { task["starter_fields"] = kept }
        return removed
    }
}
