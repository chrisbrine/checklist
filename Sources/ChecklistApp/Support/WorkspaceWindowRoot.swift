import SwiftUI
import ChecklistIPC

/// Primary keeps the existing owner's journal and preferences. A restored
/// WindowGroup value gives every additional window a stable, separate namespace.
enum WorkspaceWindowIdentity: Hashable, Codable {
    case primary
    case workspace(UUID)

    var frameAutosaveName: String {
        switch self {
        case .primary: return "ChecklistWorkspace"
        case .workspace(let id): return "ChecklistWorkspace." + id.uuidString.lowercased()
        }
    }
    var pendingCommandKey: String {
        switch self {
        case .primary: return "pending-command"
        case .workspace(let id): return "pending-command-window-" + id.uuidString.lowercased()
        }
    }
}

struct WorkspaceWindowStorage {
    static let lastWorkspaceKey = "lastWorkspaceWindowID"
    var journalBaseDirectory: URL
    var primaryPreferences: UserDefaults
    var preferencesSuitePrefix: String
    // Tests can supply process-local defaults for secondary windows too.
    var workspacePreferences: ((UUID) -> UserDefaults)? = nil

    static var application: WorkspaceWindowStorage {
        application(for: ChecklistInstance.current)
    }
    static func application(for instance: ChecklistInstance) -> WorkspaceWindowStorage {
        .init(journalBaseDirectory: LocalDraftJournal.directory(for: instance),
              primaryPreferences: .standard, preferencesSuitePrefix: instance.workspacePreferencesSuitePrefix)
    }
    func suiteName(for id: UUID) -> String { preferencesSuitePrefix + "." + id.uuidString.lowercased() }
    var lastWorkspaceID: UUID? {
        primaryPreferences.string(forKey: Self.lastWorkspaceKey).flatMap(UUID.init(uuidString:))
    }
}

@MainActor
final class WorkspaceWindowState: ObservableObject {
    typealias StoreFactory = @MainActor (LocalDraftJournal, UserDefaults, DetailItemNavigationMemory) -> ChecklistStore
    let identity: WorkspaceWindowIdentity
    let journal: LocalDraftJournal
    let preferences: UserDefaults
    let navigationMemory: DetailItemNavigationMemory
    let store: ChecklistStore

    init(identity: WorkspaceWindowIdentity, storage: WorkspaceWindowStorage = .application,
         storeFactory: StoreFactory? = nil) {
        self.identity = identity
        switch identity {
        case .primary:
            journal = LocalDraftJournal(directory: storage.journalBaseDirectory)
            preferences = storage.primaryPreferences
        case .workspace(let id):
            journal = .windowJournal(id: id, baseDirectory: storage.journalBaseDirectory)
            // The suite is an app-owned constant prefix plus a valid UUID. Never
            // fall back to the primary domain if a window suite cannot be made.
            preferences = storage.workspacePreferences?(id) ?? UserDefaults(suiteName: storage.suiteName(for: id))!
            storage.primaryPreferences.set(id.uuidString.lowercased(), forKey: WorkspaceWindowStorage.lastWorkspaceKey)
        }
        navigationMemory = DetailItemNavigationMemory()
        store = storeFactory?(journal, preferences, navigationMemory)
            ?? ChecklistStore(draftJournal: journal, preferences: preferences,
                              navigationMemory: navigationMemory, pendingCommandKey: identity.pendingCommandKey)
    }
}

struct WorkspaceWindowRoot: View {
    @StateObject private var state: WorkspaceWindowState

    init(identity: WorkspaceWindowIdentity, storage: WorkspaceWindowStorage = .application,
         storeFactory: WorkspaceWindowState.StoreFactory? = nil) {
        _state = StateObject(wrappedValue: WorkspaceWindowState(identity: identity, storage: storage, storeFactory: storeFactory))
    }
    var body: some View {
        ContentView(frameAutosaveName: state.identity.frameAutosaveName)
            .environmentObject(state.store)
            .environment(\.detailNavigationMemory, state.navigationMemory)
            .defaultAppStorage(state.preferences)
            .focusedSceneValue(\.checklistStore, state.store)
            .frame(minWidth: 900, minHeight: 650)
            // AppKit draws menu, pop-up and link titles in this tint; the fill accent measures 2.6-2.8:1 there in dark.
            // Controls that draw white text on the tint fill pin the fill accent (prominent buttons, segmented pickers).
            .tint(.checklistAccentText)
            .checklistTextScaleRoot()
    }
}
