import Foundation
import ChecklistDomain

/// Shared presentation vocabulary; Epics and Triages have separate views and commands.
enum ProductionGroups {
    static func label(_ group: Record) -> String {
        let key = group.string("key"), name = group.string("name")
        return key.isEmpty ? name : key + " " + name
    }
    static let taskKinds = TicketKind.wireValues
    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "bug": return "Bugs"
        case "asset": return "Assets"
        case "playtest": return "Playtests"
        case "question": return "Questions"
        default: return "Work"
        }
    }
    static func typeSummary(_ tasks: [Record]) -> String {
        taskKinds.compactMap { kind in
            let count = tasks.filter { $0.string("kind", fallback: "work") == kind }.count
            return count == 0 ? nil : "\(count) \(kindLabel(kind).lowercased())"
        }.joined(separator: " · ")
    }
    static func isDone(_ task: Record) -> Bool { ["done", "completed"].contains(task.string("status_category")) }
    static func isCanceled(_ task: Record) -> Bool { Canceled.matches(task.string("status_category")) }
    static func exitLabel(_ value: String) -> String {
        switch value {
        case "review_accepted": return "All required reviews accepted"
        case "implementation_submitted": return "Implementation submitted"
        default: return "Manually removed"
        }
    }
}
