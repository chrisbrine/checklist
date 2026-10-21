import Foundation

/// A selected-read receipt is separate from snapshot rows and command authority.
/// Its generation is invalidated for every installed snapshot or observed change,
/// including changes which leave a ticket's revision and manifest unchanged.
struct SelectedCompletionEligibility {
    struct Request: Equatable {
        let id: UUID
        let generation: UInt64
        let store: String
        let project: String
        let task: String
        let revision: Int
        let manifest: String
        static func == (left: Self, right: Self) -> Bool {
            left.id == right.id && left.generation == right.generation && left.revision == right.revision &&
            RecordIdentity(left.store) == RecordIdentity(right.store) && RecordIdentity(left.project) == RecordIdentity(right.project) &&
            RecordIdentity(left.task) == RecordIdentity(right.task) && RecordIdentity(left.manifest) == RecordIdentity(right.manifest)
        }
    }
    private struct Receipt { let request: Request; let eligibility: [String: Any] }
    private(set) var generation: UInt64 = 0
    private(set) var pending: Request?
    private var receipt: Receipt?

    mutating func invalidate() {
        generation &+= 1
        pending = nil; receipt = nil
    }
    mutating func begin(task: Record, store: String) -> Request? {
        invalidate()
        guard !store.isEmpty, !task.id.isEmpty, !task.string("project_id").isEmpty, task.integer("revision", fallback: 0) > 0 else { return nil }
        let request = Request(id: UUID(), generation: generation, store: store,
            project: task.string("project_id"), task: task.id, revision: task.integer("revision"), manifest: task.string("current_manifest_id"))
        pending = request
        return request
    }
    mutating func receive(_ result: Record, for request: Request, currentTask: Record?, store: String) {
        guard pending == request else { return }
        receipt = nil
        guard let currentTask, matches(request, task: currentTask, store: store),
              matches(request, task: result, store: store) else { return }
        let eligibility = result.object("completion_eligibility")
        guard let eligible = eligibility["eligible"] as? NSNumber, CFGetTypeID(eligible) == CFBooleanGetTypeID(),
              let revision = eligibility["task_revision"] as? NSNumber, CFGetTypeID(revision) != CFBooleanGetTypeID(),
              revision.doubleValue == Double(request.revision), eligibility["blockers"] is [[String: Any]],
              RecordIdentity(eligibility["manifest_id"] as? String ?? "") == RecordIdentity(request.manifest),
              eligibility["manifest_id"] is String || eligibility["manifest_id"] is NSNull else { return }
        receipt = Receipt(request: request, eligibility: eligibility)
    }
    mutating func fail(_ request: Request) {
        guard pending == request else { return }
        pending = nil; receipt = nil
    }
    func overlay(on task: Record, store: String) -> Record {
        var values = task.values
        // Old snapshot metadata cannot establish a fresh selected-read receipt.
        values.removeValue(forKey: "completion_eligibility")
        if let receipt, pending == receipt.request, matches(receipt.request, task: task, store: store) {
            values["completion_eligibility"] = receipt.eligibility
        }
        return Record(values: values)
    }
    private func matches(_ request: Request, task: Record, store: String) -> Bool {
        request.generation == generation && RecordIdentity(request.store) == RecordIdentity(store) && RecordIdentity(request.project) == RecordIdentity(task.string("project_id")) &&
            RecordIdentity(request.task) == RecordIdentity(task.id) && request.revision == task.integer("revision", fallback: 0) && RecordIdentity(request.manifest) == RecordIdentity(task.string("current_manifest_id"))
    }
}
