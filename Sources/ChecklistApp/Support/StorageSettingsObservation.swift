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

    static let previewRetiredText = "Checklist stopped this preview before it could show the result. Nothing changed. Preview the backup again."
    static let storeChangedText = "Checklist connected to a different store while this restore step ran, so its result is not shown here. Its last known state stays under Long operations. Preview the backup again for this store."

    /// A blank identity only means the window's content was discarded (a commit or a
    /// reconnect clears it). It says nothing about which store is connected, so only
    /// a different known identity retires this store's work (CL-370).
    static func sameStore(_ current: String,_ scope: String) -> Bool {current.isEmpty || scope.isEmpty || current == scope}
    func changeScope(_ scope: String) {
        guard !scope.isEmpty,self.scope != scope else {return}
        guard !self.scope.isEmpty else {self.scope = scope;return}
        let droppedRestore = restoring
        self.scope = scope;statusGeneration = UUID();operationGeneration = UUID()
        info = [:];statusError = "";result = droppedRestore ? Self.storeChangedText : "";restorePreview = [:]
        backingUp = false;restoring = false;showingRestorePreview = false
    }
    /// The confirmed preview is spent; a restored copy needs a fresh verification.
    func clearRestorePreview() {showingRestorePreview = false;restorePreview = [:]}

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
        restoring = true;result = "";showingRestorePreview = false;restorePreview = [:]
        defer {if operationGeneration == token {restoring = false}}
        do {
            let reply = try await fetch()
            guard operationGeneration == token,!Task.isCancelled else {return}
            restorePreview = reply;showingRestorePreview = true
        } catch {
            guard operationGeneration == token,!Task.isCancelled else {return}
            // A retired read is not the owner's choice: never end the busy state silently.
            result = error is CancellationError ? Self.previewRetiredText : PlainError.text(error)
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
