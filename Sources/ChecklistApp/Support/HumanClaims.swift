import Foundation
import ChecklistIPC

/// Claim credentials are local authority and never part of task exports or preferences.
/// They live in the instance's private owner folder. A credential that this folder does not
/// hold is unavailable, and callers take their existing recovery route.
enum HumanClaims {
    static var store: OwnerPrivateFileStore { store(for: ChecklistInstance.current) }
    static func store(for instance: ChecklistInstance) -> OwnerPrivateFileStore {
        OwnerPrivateFileStore(directory: OwnerPrivateFileStore.directory(for: instance), kind: OwnerPrivateFileStore.claimKind)
    }
    static func save(_ token: String, attempt: String) throws { try store.save(token, key: attempt) }
    static func read(_ attempt: String) -> String? { try? store.read(attempt) }
    static func remove(_ attempt: String) { store.remove(attempt) }
}
