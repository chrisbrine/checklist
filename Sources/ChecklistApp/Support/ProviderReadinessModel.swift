import Foundation
import Combine
import ChecklistIPC

struct ProviderReadinessContext: Equatable {
    let projectID: String
    let root: String
    let taskID: String
    let recipient: String
    let recipientLabel: String
    let serviceEpoch: UUID
    let storeIncarnation: String
    let connected: Bool
}

/// Window-local, explicit observations. An event (including a later host hold)
/// retires the observation rather than promoting it to a delivery receipt.
@MainActor final class ProviderReadinessModel: ObservableObject {
    @Published private(set) var observation: ProviderReadinessObservation?
    @Published private(set) var loading = false
    private(set) var context: ProviderReadinessContext?
    private var generation = UUID()

    func invalidate(for context: ProviderReadinessContext?) {
        guard self.context != context else { return }
        self.context = context; generation = UUID(); observation = nil; loading = false
    }

    func refresh(_ context: ProviderReadinessContext,
                 load: (String) async -> ProviderReadinessObservation = { root in
                     await Task.detached { ProviderSettingsObservation.observe(projectRoot: root) }.value
                 }) async {
        invalidate(for: context)
        let read = UUID(); generation = read; observation = nil; loading = true
        let result = await load(context.root)
        guard generation == read, self.context == context else { return }
        guard !Task.isCancelled else { loading = false; return }
        observation = result; loading = false
    }

    func observation(for context: ProviderReadinessContext?) -> ProviderReadinessObservation? {
        self.context == context ? observation : nil
    }
}

extension ChecklistStore {
    var providerReadinessContext: ProviderReadinessContext? {
        guard let project = currentProject else { return nil }
        var taskID = "", recipient = "", label = "Project context · no current ticket recipient observed"
        if case .task(let id) = detail, let task = selectedTask(id) ?? self.task(id), task.string("project_id") == project.id {
            taskID = task.id
            let attempts = hasSelectedTicketDisplay(id) ? detailRecords("attempts", task: task) : records("attempts")
            let sessions = hasSelectedTicketDisplay(id) ? detailRecords("sessions", task: task) : records("sessions")
            if let attempt = attempts.first(where: { $0.id == task.string("active_attempt_id") && $0.string("task_id") == task.id && $0.string("state") == "active" }),
               let session = sessions.first(where: { $0.id == attempt.string("session_id") && $0.string("role") == "worker" }) {
                // The actual generation/state matters even when a host reuses its session ID.
                recipient = [session.id, session.string("installation"), session.string("state"), String(session.integer("revision"))].joined(separator: "|")
                label = "\(task.string("key")) · current handler: \(session.string("name", fallback: session.string("provider")))"
            }
        }
        return .init(projectID: project.id, root: project.string("root_path"), taskID: taskID, recipient: recipient,
                     recipientLabel: label, serviceEpoch: archivePreviewEpoch, storeIncarnation: service.string("store_incarnation"), connected: connected)
    }
}
