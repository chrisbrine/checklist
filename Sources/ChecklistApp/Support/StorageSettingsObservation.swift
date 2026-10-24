import Foundation
import Combine

/// Keep accepted storage facts while an independent read refreshes them. Each
/// read owns a generation, so a late or canceled reply cannot replace newer UI.
@MainActor final class StorageSettingsObservation: ObservableObject {
    @Published private(set) var info: [String:Any] = [:]
    @Published private(set) var statusError = ""
    @Published var result = ""
    @Published private(set) var backingUp = false
    @Published var restoring = false
    @Published private(set) var restorePreview: [String:Any] = [:]
    @Published var showingRestorePreview = false
    private(set) var scope = ""
    private var statusGeneration = UUID()
    private var operationGeneration = UUID()

    func changeScope(_ scope: String) {
        guard self.scope != scope else {return}
        self.scope = scope;statusGeneration = UUID();operationGeneration = UUID()
        info = [:];statusError = "";result = "";restorePreview = [:]
        backingUp = false;restoring = false;showingRestorePreview = false
    }

    func refreshStatus(fetch: () async throws -> [String:Any]) async {
        guard !Task.isCancelled else {return}
        let token = UUID();statusGeneration = token;statusError = ""
        do {
            let reply = try await fetch()
            guard statusGeneration == token,!Task.isCancelled else {return}
            info = reply
        } catch {
            guard statusGeneration == token,!Task.isCancelled,!(error is CancellationError) else {return}
            statusError = PlainError.text(error)
        }
    }

    func previewRestore(fetch: () async throws -> [String:Any]) async {
        guard !Task.isCancelled else {return}
        let token = UUID();operationGeneration = token
        restoring = true;result = "";showingRestorePreview = false
        defer {if operationGeneration == token {restoring = false}}
        do {
            let reply = try await fetch()
            guard operationGeneration == token,!Task.isCancelled else {return}
            restorePreview = reply;showingRestorePreview = true
        } catch {
            guard operationGeneration == token,!Task.isCancelled,!(error is CancellationError) else {return}
            result = PlainError.text(error)
        }
    }

    func backup(path: String,fetch: () async throws -> [String:Any],status: () async throws -> [String:Any]) async {
        guard !Task.isCancelled else {return}
        let token = UUID();operationGeneration = token;backingUp = true;result = ""
        defer {if operationGeneration == token {backingUp = false}}
        do {
            let reply = try await fetch()
            guard operationGeneration == token,!Task.isCancelled else {return}
            storageDidChange()
            result = "Backup saved to \(reply["path"] as? String ?? path)."
            await refreshStatus(fetch:status)
        } catch {
            guard operationGeneration == token,!Task.isCancelled,!(error is CancellationError) else {return}
            result = PlainError.text(error)
        }
    }

    /// Called synchronously when a committed backup or restore becomes known,
    /// before scheduling its status refresh. Older status reads are then fenced.
    func storageDidChange() {statusGeneration = UUID();statusError = ""}
}
