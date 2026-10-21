import SwiftUI

/// One confirmation pattern for actions that remove, cancel, retire or release something (CL-57).
/// The title names the action and its object, the message names the effect, and the confirm button
/// repeats the action. It is a native dialog: Return confirms, Escape cancels, VoiceOver reads all parts.
struct PendingConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let effect: String
    let confirmLabel: String
    var keepLabel = "Cancel"
    let perform: () -> Void
}

/// The same action has the same confirmation wherever it appears.
enum Confirmations {
    static let archiveTitle = "Archive this ticket?"
    static let archiveEffect = "The ticket moves to Done / Archived. Its notes, files and history stay, and you can unarchive it."
    static let archiveKeepFiles = "Archive; keep files"

    static func archiveTicket(perform: @escaping () -> Void) -> PendingConfirmation {
        PendingConfirmation(title: archiveTitle, effect: archiveEffect, confirmLabel: archiveKeepFiles, perform: perform)
    }
    static func archiveProject(_ name: String, perform: @escaping () -> Void) -> PendingConfirmation {
        PendingConfirmation(title: "Archive the project \(name)?",
                            effect: "The project leaves the sidebar and the Overview, and agents cannot start or change its work. Its tickets, notes, files, history and workspace folder stay unchanged. You can restore it from Archived projects in the sidebar.",
                            confirmLabel: "Archive project", perform: perform)
    }
    static func cancelRequest(perform: @escaping () -> Void) -> PendingConfirmation {
        PendingConfirmation(title: "Cancel this request?", effect: "The agent stops waiting for your answer. The request and your draft stay in the ticket history.",
                            confirmLabel: "Cancel request", keepLabel: "Keep request", perform: perform)
    }
    static func retireTag(_ name: String, perform: @escaping () -> Void) -> PendingConfirmation {
        PendingConfirmation(title: "Retire the tag \(name)?", effect: "Tickets keep this tag in their history, but nobody can add it to a ticket again.",
                            confirmLabel: "Retire tag", perform: perform)
    }
    static func removeDecision(perform: @escaping () -> Void) -> PendingConfirmation {
        PendingConfirmation(title: "Remove this decision?", effect: "Agents no longer get this decision in their project context after you save the settings. Earlier notes that quote it stay.",
                            confirmLabel: "Remove decision", perform: perform)
    }
    static func removeLink(perform: @escaping () -> Void) -> PendingConfirmation {
        PendingConfirmation(title: "Remove this link?", effect: "Both tickets stay. Only the link between them ends; its history stays.",
                            confirmLabel: "Remove link", perform: perform)
    }
    static func releaseWork(_ key: String, perform: @escaping () -> Void) -> PendingConfirmation {
        PendingConfirmation(title: "Release your work on \(key)?", effect: "You stop working on this ticket. Saved progress and files stay, and anyone eligible can start it again.",
                            confirmLabel: "Release", perform: perform)
    }
    static func removeFromTriage(_ key: String, perform: @escaping () -> Void) -> PendingConfirmation {
        PendingConfirmation(title: "Remove \(key) from this Triage?", effect: "The ticket keeps its status, Epic and history. It only leaves this Triage.",
                            confirmLabel: "Remove from Triage", perform: perform)
    }
    static func archiveTriage(_ name: String, perform: @escaping () -> Void) -> PendingConfirmation {
        PendingConfirmation(title: "Archive the Triage \(name)?", effect: "The Triage moves to Past Triages. Its tickets keep their status, Epic and history, and you can restore the Triage.",
                            confirmLabel: "Archive Triage", perform: perform)
    }
    /// A status of the canceled category closes the ticket without completing it.
    static func cancelTicket(_ key: String, status: String, perform: @escaping () -> Void) -> PendingConfirmation {
        PendingConfirmation(title: "Set \(key) to \(status)?", effect: "\(status) closes the ticket without completing it. It leaves any Triage; its notes, files and history stay, and you can change its status again.",
                            confirmLabel: "Set \(status)", keepLabel: "Keep current status", perform: perform)
    }
    static func removeFromEpic(_ key: String, perform: @escaping () -> Void) -> PendingConfirmation {
        PendingConfirmation(title: "Remove \(key) from this Epic?", effect: "The ticket keeps its status, Triages and history. It then has no Epic.",
                            confirmLabel: "Remove from Epic", perform: perform)
    }
}

extension View {
    func checklistConfirmation(_ pending: Binding<PendingConfirmation?>) -> some View {
        confirmationDialog(pending.wrappedValue?.title ?? "", isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: pending.wrappedValue) { item in
            Button(item.confirmLabel, role: .destructive) { item.perform() }
            Button(item.keepLabel, role: .cancel) {}
        } message: { item in Text(item.effect) }
    }
}
