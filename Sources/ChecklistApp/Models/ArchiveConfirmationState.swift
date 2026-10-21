import Foundation
import Combine
import ChecklistIPC

/// A dialog-bound preview, never a cached reference graph. The service still
/// revalidates the preview and current holds when archive/cleanup is confirmed.
@MainActor final class ArchiveConfirmationState: ObservableObject {
    struct Selection: Equatable {
        let store: RecordIdentity
        let project: RecordIdentity
        let ticket: RecordIdentity
        let revision: Int
        let settingsRevision: Int
        let readable: Bool
    }
    struct LoadKey: Equatable {
        let scope: Scope
        let presented: Bool
        let retry: UUID
    }
    struct Scope: Equatable {
        let selection: Selection
        let epoch: UUID

        init(task: Record, store: String, settingsRevision: Int, epoch: UUID, readable: Bool) {
            selection = Selection(store: RecordIdentity(store), project: RecordIdentity(task.string("project_id")),
                                  ticket: RecordIdentity(task.id), revision: task.integer("revision"),
                                  settingsRevision: settingsRevision, readable: readable)
            self.epoch = epoch
        }
    }

    @Published var presented = false
    @Published private(set) var failure: String?
    @Published private var preview: [String: Any]?
    private var scope: Scope?
    private var requestID = UUID()

    func preview(for current: Scope) -> [String: Any]? {
        current.selection.readable && scope == current ? preview : nil
    }
    func failure(for current: Scope) -> String? { scope == current ? failure : nil }

    /// Every opening starts with loading content and a fresh observation. Merely
    /// selecting a ticket must never initiate the retention read.
    func present() { invalidate(); presented = true }

    func invalidate() {
        requestID = UUID(); scope = nil; preview = nil; failure = nil
    }

    func load(_ current: Scope, request: () async throws -> [String: Any]) async {
        guard presented else { return }
        let id = UUID()
        requestID = id; scope = current; preview = nil; failure = nil
        guard current.selection.readable else { return }
        do {
            let reply = try await request()
            guard requestID == id, presented, !Task.isCancelled else { return }
            guard let project = reply["project_id"] as? String, RecordIdentity(project) == current.selection.project,
                  let task = reply["task_id"] as? String, RecordIdentity(task) == current.selection.ticket,
                  (reply["task_revision"] as? NSNumber)?.intValue == current.selection.revision,
                  (reply["settings_revision"] as? NSNumber)?.intValue == current.selection.settingsRevision else {
                throw ChecklistError("REVISION_CONFLICT", "The ticket or archive settings changed. Refresh the ticket before archiving.")
            }
            preview = reply
        } catch {
            guard requestID == id, presented, !Task.isCancelled else { return }
            failure = PlainError.text(error)
        }
    }

    func cancel() {
        invalidate(); presented = false
    }

    static func description(_ preview: [String: Any]) -> String {
        let clean = (preview["clean_bytes"] as? NSNumber)?.int64Value ?? 0
        let retained = (preview["retained_bytes"] as? NSNumber)?.int64Value ?? 0
        let reasons = Set((preview["holds"] as? [[String: Any]] ?? []).flatMap { $0["reasons"] as? [String] ?? [] }).sorted().map(ArchiveStorageDraft.holdLabel)
        let excess = (preview["budget_excess_bytes"] as? NSNumber)?.int64Value ?? 0
        let holds = reasons.isEmpty ? "" : " Retained because: " + reasons.joined(separator: ", ") + "."
        let budget = excess > 0 ? " Protected originals exceed the retained budget by " + ByteCountFormatter.string(fromByteCount: excess, countStyle: .file) + "." : ""
        return "Eligible managed copies: \(ByteCountFormatter.string(fromByteCount: clean, countStyle: .file)). Protected or kept: \(ByteCountFormatter.string(fromByteCount: retained, countStyle: .file))." + holds + budget + " History and thumbnails remain. External originals are never removed. Cleaned original bytes cannot be restored by unarchiving."
    }
}
