import Foundation

/// Only bounded display arrays that have no independent record envelope use
/// derived keys. Scope and semantic identity stay separate and byte-exact.
struct StableListRow<Value>: Identifiable {
    struct ID: Hashable {
        let scope: [RecordIdentity]
        let key: [RecordIdentity]
        let occurrence: Int
    }
    let id: ID
    let value: Value
    let number: Int // Presentation ordinal, never the SwiftUI identity.
}

enum StableListRows {
    static func values<Value>(_ values: [Value], scope: [String], key: (Value) -> [String]) -> [StableListRow<Value>] {
        let scope = scope.map(RecordIdentity.init)
        var occurrences: [[RecordIdentity]: Int] = [:]
        return values.enumerated().map { offset, value in
            let identity = key(value).map(RecordIdentity.init)
            let occurrence = occurrences[identity, default: 0]
            occurrences[identity] = occurrence + 1
            // Equal duplicate values have no further domain identity. Their
            // occurrence is local to that semantic key, not the array position.
            return StableListRow(id: .init(scope: scope, key: identity, occurrence: occurrence), value: value, number: offset + 1)
        }
    }

    static func acceptance(_ values: [String], task: Record) -> [StableListRow<String>] {
        self.values(values, scope: [task.string("project_id"), task.id, "acceptance", String(task.integer("acceptance_revision"))], key: { [$0] })
    }
    static func artifacts(_ values: [Record], manifest: Record) -> [StableListRow<Record>] {
        self.values(values, scope: [manifest.string("project_id"), manifest.id, "artifacts"], key: { [$0.string("artifact_id"), $0.string("sha256")] })
    }
    static func checks(_ values: [Record], review: Record) -> [StableListRow<Record>] {
        self.values(values, scope: [review.string("project_id"), review.id, "checks"]) {
            !$0.id.isEmpty ? ["record", $0.id] : ["label", $0.string("label", fallback: $0.string("name", fallback: "Recorded check"))]
        }
    }
    static func assessments(_ values: [Record], review: Record) -> [StableListRow<Record>] {
        self.values(values, scope: [review.string("project_id"), review.id, "assessment"]) {
            !$0.string("requirement_id").isEmpty ? ["requirement", $0.string("section"), $0.string("requirement_id")] : ["additional", $0.string("source"), $0.string("requirement")]
        }
    }
    static func policyPreview(_ values: [[String: Any]], projectID: String) -> [StableListRow<Record>] {
        self.values(values.map(Record.init), scope: [projectID, "policy-preview"], key: { [$0.string("task_id")] })
    }
}

/// Local editor identities are retained for the lifetime of the draft. A new
/// row's UUID is never serialized as a server-owned pinned-decision ID.
struct PinnedDecisionDrafts {
    struct Row: Identifiable {
        enum ID: Hashable { case record(RecordIdentity), draft(UUID) }
        let id: ID
        var value: [String: Any]
        init(_ value: [String: Any]) {
            if let id = value["id"] as? String, !id.isEmpty { self.id = .record(RecordIdentity(id)) }
            else { self.id = .draft(UUID()) }
            self.value = value
        }
    }
    private(set) var rows: [Row] = []
    init(_ entries: [Any] = []) {
        rows = entries.compactMap { entry in
            let value = (entry as? String).map { ["body": $0, "task_kinds": [], "tag_ids": []] as [String: Any] } ?? entry as? [String: Any]
            return value.map(Row.init)
        }
    }
    var count: Int { rows.count }
    var payload: [[String: Any]] { rows.map(\.value) }
    mutating func appendEmpty() { rows.append(Row(["body": "", "task_kinds": [String](), "tag_ids": [String]()])) }
    mutating func remove(_ id: Row.ID) { rows.removeAll { $0.id == id } }
    func text(_ id: Row.ID, _ key: String) -> String { rows.first { $0.id == id }?.value[key] as? String ?? "" }
    mutating func setText(_ text: String, for id: Row.ID, key: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        if key == "title" && text.isEmpty { rows[index].value.removeValue(forKey: key) }
        else { rows[index].value[key] = text }
    }
    func hasKind(_ id: Row.ID, _ kind: String) -> Bool { (rows.first { $0.id == id }?.value["task_kinds"] as? [String] ?? []).contains(kind) }
    mutating func setKind(_ selected: Bool, for id: Row.ID, kind: String, orderedKinds: [String]) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        var kinds = Set(rows[index].value["task_kinds"] as? [String] ?? [])
        if selected { kinds.insert(kind) } else { kinds.remove(kind) }
        rows[index].value["task_kinds"] = orderedKinds.filter { kinds.contains($0) }
    }
}
