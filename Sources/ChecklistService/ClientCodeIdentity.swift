import Foundation
import ChecklistIPC

/// Missing or invalid bundled signatures refuse every client.
enum ClientCodeIdentity {
    static func bundledAdmission() -> ClientConnectionAdmission {
        let directory = ChecklistPaths.serviceExecutable.deletingLastPathComponent()
        let clients = ["ChecklistApp", "checklist"].compactMap {
            ClientBuildIdentity.executable(directory.appendingPathComponent($0))
        }
        let identifiers = Set(clients.map(\.identifier)).union(["org.checklist.checklist", "org.checklist.app", ChecklistInstance.current.bundleIdentifier])
        return ClientConnectionAdmission(currentClients: clients.count == 2 ? clients : [], checklistIdentifiers: identifiers)
    }
}
