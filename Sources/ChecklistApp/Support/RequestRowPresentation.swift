import Foundation
import os

enum RequestRowCapability: String, CaseIterable, Identifiable {
    case choice = "Choice", text = "Text", file = "File", check = "Check", approval = "Approval"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .choice: return "list.bullet.circle"
        case .text: return "text.alignleft"
        case .file: return "doc"
        case .check: return "checkmark.circle"
        case .approval: return "hand.thumbsup"
        }
    }
}

/// Read-only presentation. It never turns a nonblocking request into a task dependency.
enum RequestRowPresentation {
    // Parser instances never leave the lock. Only immutable dates are shared.
    private static let parsers = OSAllocatedUnfairLock(uncheckedState: (fractional: makeFractional(), standard: ISO8601DateFormatter()))
    private static func makeFractional() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return formatter
    }

    static func createdAt(_ request: Record) -> Date? {
        let value = request.string("created_at")
        return parsers.withLock { $0.fractional.date(from:value) ?? $0.standard.date(from:value) }
    }

    static func ordered(_ requests: [Record]) -> [Record] {
        // Parse once per publication, rather than constructing formatters inside comparisons.
        requests.map { (request:$0,created:createdAt($0)) }.sorted { left,right in
            if left.request.bool("blocking") != right.request.bool("blocking") { return left.request.bool("blocking") }
            switch (left.created,right.created) {
            case let (lhs?,rhs?) where lhs != rhs: return lhs < rhs
            case (_?,nil): return true
            case (nil,_?): return false
            default: return left.request.id < right.request.id
            }
        }.map(\.request)
    }

    static func age(_ request: Record,now: Date = Date()) -> String {
        guard let date = createdAt(request) else { return "Age unavailable" }
        let elapsed = max(0,now.timeIntervalSince(date))
        if elapsed < 60 { return "Age: <1m" }
        if elapsed < 3600 { return "Age: \(Int(elapsed / 60))m" }
        if elapsed < 86400 { return "Age: \(Int(elapsed / 3600))h" }
        return "Age: \(Int(elapsed / 86400))d"
    }

    static func ticketLabel(_ request: Record,task: Record?) -> String {
        let prefix = request.bool("blocking") ? "Blocks" : "Related"
        guard let task,task.id == request.string("task_id"),task.string("project_id") == request.string("project_id"),!task.string("key").isEmpty else { return "\(prefix): ticket unavailable" }
        return "\(prefix): \(task.string("key"))"
    }

    static func capabilities(_ request: Record) -> [RequestRowCapability] {
        var result = Set<RequestRowCapability>()
        for question in request.records("questions") {
            switch question.string("type",fallback:"text") {
            case "choice","single_choice","multiple_choice":
                result.insert(.choice)
                if question.bool("allow_custom") { result.insert(.text) }
            case "text": result.insert(.text)
            case "check": result.insert(.check)
            case "approval": result.insert(.approval)
            default: break
            }
            if hasCommand(question.object("command")) { result.insert(.check) }
        }
        if !request.records("file_requests").isEmpty { result.insert(.file) }
        if hasCommand(request.object("command")) { result.insert(.check) }
        return RequestRowCapability.allCases.filter { result.contains($0) }
    }
    private static func hasCommand(_ command: [String:Any]) -> Bool {
        !(command["text"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
    }
}
