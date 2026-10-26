import Foundation
import ChecklistIPC

struct Record: Identifiable {
    let values: [String: Any]
    var id: String { string("id") }
    func string(_ key: String, fallback: String = "") -> String {
        if let value = values[key] as? String { return value }
        return fallback
    }
    func integer(_ key: String, fallback: Int = 1) -> Int { (values[key] as? NSNumber)?.intValue ?? fallback }
    func bool(_ key: String) -> Bool { (values[key] as? Bool) ?? false }
    func records(_ key: String) -> [Record] { (values[key] as? [[String: Any]] ?? []).map(Record.init) }
    func strings(_ key: String) -> [String] { values[key] as? [String] ?? [] }
    func object(_ key: String) -> [String: Any] { values[key] as? [String: Any] ?? [:] }
}

/// Required identity at a command reply boundary. Other fields remain open JSON;
/// display records may still use their existing missing-field fallbacks.
struct TypedReplyRecord {
    let id: String
    let record: Record

    init(_ values: [String: Any]) throws {
        guard let id = values["id"] as? String, !id.isEmpty else {
            throw ChecklistError("INVALID_RESPONSE", "The saved record reply has an invalid id. Refresh the current view.")
        }
        self.id = id
        record = Record(values: values)
    }
}

enum Page: String, CaseIterable, Identifiable {
    case overview, needsYou, tasks, epics, media, activity, archived
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .needsYou: return "Needs You"
        case .tasks: return "Tickets"
        case .media: return "Media review"
        case .epics: return "Epics"
        case .activity: return "Activity"
        case .archived: return "Archived"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .needsYou: return "flag"
        case .tasks: return "checklist"
        case .media: return "photo.on.rectangle"
        case .epics: return "folder"
        case .activity: return "clock.arrow.circlepath"
        case .archived: return "archivebox"
        }
    }
}

enum Detail: Equatable, Codable {
    case task(String), request(String), project(String), group(String)
}

struct AnswerDraft: Codable {
    var inspectedImages: [[String: String]] = []
    var values: [String: String] = [:]
    var customValues: [String: String] = [:]
    var paths: [String: [String]] = [:]
    var fileModes: [String: String] = [:]
    var pathHashes: [String: String] = [:]
    var explanations: [String: String] = [:]
    var explanation: String = ""
    var revision: Int = 0
    var targetIdentity: String = ""
    var formRevision: Int = 0

    init(revision: Int = 0) { self.revision = revision }
    private enum CodingKeys: String, CodingKey { case inspectedImages, values, customValues, paths, fileModes, pathHashes, explanations, explanation, revision, targetIdentity, formRevision }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inspectedImages = try c.decodeIfPresent([[String: String]].self, forKey: .inspectedImages) ?? []
        values = try c.decodeIfPresent([String: String].self, forKey: .values) ?? [:]
        customValues = try c.decodeIfPresent([String: String].self, forKey: .customValues) ?? [:]
        paths = try c.decodeIfPresent([String: [String]].self, forKey: .paths) ?? [:]
        fileModes = try c.decodeIfPresent([String: String].self, forKey: .fileModes) ?? [:]
        pathHashes = try c.decodeIfPresent([String: String].self, forKey: .pathHashes) ?? [:]
        explanations = try c.decodeIfPresent([String: String].self, forKey: .explanations) ?? [:]
        explanation = try c.decodeIfPresent(String.self, forKey: .explanation) ?? ""
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        targetIdentity = try c.decodeIfPresent(String.self, forKey: .targetIdentity) ?? ""
        formRevision = try c.decodeIfPresent(Int.self, forKey: .formRevision) ?? 0
    }
}
