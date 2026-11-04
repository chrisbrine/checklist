import Foundation
import ChecklistIPC

/// Slot consent never makes a copied registration local. Only the first native
/// registration can acquire this store's marker; reconnects retain the old one.
struct SlotNativeRelayPolicy: Sendable {
    let slot: Int?
    let enabled: Bool
    let registrationStore: String?

    init(instance: ChecklistInstance, storeRoot: URL, incarnation: String, environment: [String:String]) {
        slot = instance.slot
        enabled = slot == nil || environment["CHECKLIST_SLOT_RELAYS"] == "synthetic"
        registrationStore = slot.map { "slot:\($0):\(storeRoot.resolvingSymlinksInPath().standardizedFileURL.path):\(incarnation)" }
    }

    func allows(_ enrollment: Enrollment) -> Bool {
        guard enabled else { return false }
        guard let registrationStore else { return true }
        return enrollment.nativeRelayRegistrationStore == registrationStore
    }

    var message: String? {
        guard let slot else { return nil }
        return enabled
            ? "Native relays in test slot \(slot) are restricted to sessions first registered in this slot store. Copied sessions stay on Checklist pickup."
            : "All native relays are off in test slot \(slot), including Claude peer messages, the Codex queue and thread opening. Notes wait for Checklist pickup."
    }
}
