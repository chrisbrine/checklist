import Foundation
import Combine

/// Preparing and opening a draft never supplies a session identity or work authority.
@MainActor final class TaskHandoffModel: ObservableObject {
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

    func prepare(task: Record, provider: HandoffProvider, transport: Transport) async {
        guard !opening else { return }
        loading = true; instruction = ""; limitation = ""; preparationFailure = ""; openingFailure = ""; composeURL = nil; openedComposer = false
        defer { loading = false }
        if let reason = provider.unavailabilityReason { preparationFailure = reason; return }
        do {
            let response = try await transport("task_handoff_prepare", ["command_id": commandID, "project_id": task.string("project_id"), "task_id": task.id, "provider": provider.id])
            guard let returned = response["instruction"] as? String, !returned.isEmpty else {
                preparationFailure = "The service did not return a ticket instruction. No chat was opened."
                return
            }
            instruction = returned
            limitation = response["limitation"] as? String ?? ""
            if let raw = response["compose_url"] as? String {
                guard let validated = provider.validatedComposeURL(raw) else {
                    preparationFailure = "The service returned an unsupported compose link. No chat was opened. The instruction is available to copy."
                    return
                }
                composeURL = validated
            }
        } catch { preparationFailure = PlainError.text(error) }
    }

    func openPreparedChat(applicationURL: URL?, opener: Opener) async {
        guard !loading, !opening, let composeURL else { return }
        openedComposer = false; openingFailure = ""
        guard let applicationURL else {
            openingFailure = "Codex could not be located. The instruction is available to copy."
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
