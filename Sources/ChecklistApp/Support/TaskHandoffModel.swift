import Foundation
import Combine

/// Preparing and opening a draft never supplies a session identity or work authority.
@MainActor final class TaskHandoffModel: ObservableObject {
    struct Scope: Hashable {
        let projectID: String
        let taskID: String
        let providerID: String

        init(task: Record, provider: HandoffProvider) {
            projectID = task.string("project_id")
            taskID = task.id
            providerID = provider.id
        }
    }

    typealias Transport = (String, [String: Any]) async throws -> [String: Any]
    typealias Opener = (URL, URL) async throws -> Void
    @Published private(set) var loading = true
    @Published private(set) var instruction = ""
    @Published private(set) var limitation = ""
    @Published private(set) var preparationFailure = ""
    @Published private(set) var openingFailure = ""
    @Published private(set) var composeURL: URL?
    @Published private(set) var opening = false
    @Published private(set) var openedComposer = false
    private let commandID = UUID().uuidString
    private var preparationID: UUID?
    private var preparationScope: Scope?
    private var preparedScope: Scope?

    func prepare(task: Record, provider: HandoffProvider, transport: Transport) async {
        guard !opening, !Task.isCancelled else { return }
        let scope = Scope(task: task, provider: provider), requestID = UUID()
        preparationID = requestID; preparationScope = scope; preparedScope = nil
        loading = true; instruction = ""; limitation = ""; preparationFailure = ""; openingFailure = ""; composeURL = nil; openedComposer = false
        // A retired request must not clear a newer request's loading state either.
        defer { if preparationID == requestID { loading = false } }
        if let reason = provider.unavailabilityReason { preparationFailure = reason; return }
        do {
            let response = try await transport("task_handoff_prepare", ["command_id": commandID, "project_id": task.string("project_id"), "task_id": task.id, "provider": provider.id])
            guard preparationID == requestID, preparationScope == scope, !Task.isCancelled else { return }
            guard let returned = response["instruction"] as? String, !returned.isEmpty else {
                preparationFailure = "The service did not return a ticket instruction. No chat was opened."
                return
            }
            preparedScope = scope
            instruction = returned
            limitation = response["limitation"] as? String ?? ""
            if let raw = response["compose_url"] as? String {
                guard let validated = provider.validatedComposeURL(raw) else {
                    preparationFailure = "The service returned an unsupported compose link. No chat was opened. The instruction is available to copy."
                    return
                }
                composeURL = validated
            }
        } catch {
            guard preparationID == requestID, preparationScope == scope, !Task.isCancelled, !(error is CancellationError) else { return }
            preparationFailure = PlainError.text(error)
        }
    }

    func validatedComposeURL(task: Record, provider: HandoffProvider) -> URL? {
        guard !loading, preparedScope == Scope(task: task, provider: provider), let composeURL else { return nil }
        return provider.validatedComposeURL(composeURL.absoluteString)
    }

    func openPreparedChat(task: Record, provider: HandoffProvider, applicationURL: URL?, opener: Opener) async {
        guard !loading, !opening, !Task.isCancelled, composeURL != nil else { return }
        openedComposer = false; openingFailure = ""
        guard let composeURL = validatedComposeURL(task: task, provider: provider) else {
            openingFailure = "The prepared chat does not match this ticket or available provider. Prepare it again."
            return
        }
        guard let applicationURL else {
            openingFailure = "\(provider.name) could not be located. The instruction is available to copy."
            return
        }
        opening = true
        defer { opening = false }
        do {
            try await opener(composeURL, applicationURL)
            openedComposer = true
        } catch { openingFailure = PlainError.text(error) }
    }

    func openApplication(_ applicationURL: URL, opener: (URL) async throws -> Void) async {
        guard !loading, !opening else { return }
        openingFailure = ""; opening = true
        defer { opening = false }
        do { try await opener(applicationURL) }
        catch { openingFailure = PlainError.text(error) }
    }
}
