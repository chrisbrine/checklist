import SwiftUI

/// One confirmation pattern for actions that remove, cancel, retire or release something (CL-57).
/// The title names the action and its object, the message names the effect, and the confirm button
/// repeats the action. It is a native dialog: Return uses the configured default, Escape cancels, VoiceOver reads all parts.
struct PendingConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let effect: String
    let confirmLabel: String
    var keepLabel = "Cancel"
    let perform: () -> Void
    var cancelIsDefault = false

    func respond(confirmed: Bool) { if confirmed { perform() } }

    static func resolve(_ pending: Binding<PendingConfirmation?>, confirmed: Bool) {
        let item = pending.wrappedValue
        pending.wrappedValue = nil
        item?.respond(confirmed: confirmed)
    }
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
    static func retireMediaType(_ name: String, perform: @escaping () -> Void) -> PendingConfirmation {
        PendingConfirmation(title: "Retire the review type \(name)?",
                            effect: "This permanently disables the type. It cannot be enabled again or receive new rounds. Existing rounds, originals and history stay. Draft and Open rounds must be finished or canceled first.",
                            confirmLabel: "Retire type", perform: perform, cancelIsDefault: true)
    }
    static func cancelMediaRound(_ name: String, perform: @escaping () -> Void) -> PendingConfirmation {
        PendingConfirmation(title: "Cancel the round \(name)?",
                            effect: "This ends review without completing the round. The cancellation reason, originals and history stay.",
                            confirmLabel: "Cancel round", keepLabel: "Keep round", perform: perform, cancelIsDefault: true)
    }
    static func archiveMediaRound(_ name: String, perform: @escaping () -> Void) -> PendingConfirmation {
        PendingConfirmation(title: "Archive the round \(name)?",
                            effect: "The round moves to Archived rounds. Its originals and history stay; no files are deleted.",
                            confirmLabel: "Archive round", perform: perform, cancelIsDefault: true)
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
        let dialog = Binding<PendingConfirmation?>(get: { pending.wrappedValue?.cancelIsDefault == false ? pending.wrappedValue : nil },
                                                   set: { pending.wrappedValue = $0 })
        let safeDefault = Binding<PendingConfirmation?>(get: { pending.wrappedValue?.cancelIsDefault == true ? pending.wrappedValue : nil },
                                                        set: { pending.wrappedValue = $0 })
        return confirmationDialog(dialog.wrappedValue?.title ?? "", isPresented: Binding(get: { dialog.wrappedValue != nil }, set: { if !$0 { dialog.wrappedValue = nil } }),
                                  titleVisibility: .visible, presenting: dialog.wrappedValue) { item in
            Button(item.confirmLabel, role: .destructive) { item.respond(confirmed: true) }
            Button(item.keepLabel, role: .cancel) { item.respond(confirmed: false) }
        } message: { item in Text(item.effect) }
        .sheet(item: safeDefault) { item in
            VStack(alignment: .leading, spacing: Spacing.group) {
                Text(item.title).checklistFont(.sheetTitle)
                Text(item.effect).checklistFont(.callout)
                AccessibleHStack {
                    Button(item.keepLabel) { PendingConfirmation.resolve(pending, confirmed: false) }.keyboardShortcut(.defaultAction)
                    Spacer()
                    Button(item.confirmLabel, role: .destructive) { PendingConfirmation.resolve(pending, confirmed: true) }
                }.buttonStyle(.checklistBordered)
            }.padding(Spacing.page).checklistSheet(width: 520)
            // A native dialog button can have only one shortcut. Keep Return safe
            // and handle Escape separately, through the same cancellation path.
            .onExitCommand { PendingConfirmation.resolve(pending, confirmed: false) }
        }
    }
}
