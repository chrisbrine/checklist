import SwiftUI

/// CL-126: one combined, paged list of Triage notes and member ticket notes.
struct TriageMessagesSection: View {
    @ObservedObject var feed: TriageMessageFeed
    let reload: () -> Void
    let loadMore: () -> Void
    var body: some View {
        DetailSection(title: "Messages") {
            Text("Triage notes and the notes of this Triage's tickets, oldest first.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            if let error = feed.error {
                Text(error).checklistFont(.micro).foregroundStyle(.orange)
                Button("Retry messages", action: reload).checklistFont(.micro)
            } else if feed.messages.isEmpty && !feed.loading && !feed.hasMore {
                Text("No messages yet.").checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText)
            }
            ForEach(feed.messages) { message in TriageMessageRow(message: message, ticketKey: feed.ticketKey(message)) }
            if feed.loading { ProgressView("Loading messages…").controlSize(.small) }
            if feed.hasMore {
                Button("Load more messages", action: loadMore).checklistFont(.micro)
                    .checklistDisabled([(feed.loading, "Messages are still loading.")])
            }
        }
    }
}

struct TriageMessageRow: View {
    let message: Record
    let ticketKey: String
    /// CL-126 (R42A D3): a ticket note names its ticket; "Triage note" only without a task.
    var subject: String { !ticketKey.isEmpty ? ticketKey : message.string("task_id").isEmpty ? "Triage note" : "Ticket note" }
    var author: String {
        let display = message.string("author_display")
        if !display.isEmpty { return display }
        return ["human", "human_ui"].contains(message.string("origin")) ? "You" : "Agent"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            AccessibleHStack {
                Text(subject).checklistFont(.captionStrong)
                Text(author).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                Spacer()
                Text(relativeTime(message.string("created_at"))).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }.accessibilityElement(children: .combine)
            RichTextView(text: message.string("body"), content: message.values["content"], capability: .note, contentDigest: message.string("content_digest"))
            if let copy = TriageCopyLabel.text(message, ticketKey: ticketKey) {
                Text(copy).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText).fixedSize(horizontal: false, vertical: true)
            }
            let deliveries = message.records("deliveries")
            if let receipt = Self.noteReceipt(message) {
                Text(receipt).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }
            ForEach(deliveries) { delivery in
                Text("\(Self.recipient(delivery)): \(DeliveryLabels.receipt(delivery: delivery))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).checklistCard(padding: Card.padding)
    }
    /// The note-level receipt when it has no delivery rows: nil while its receipts load,
    /// "Delivery status unavailable" after a failed read, else the service `delivery_status`.
    static func noteReceipt(_ message: Record) -> String? {
        guard message.records("deliveries").isEmpty else { return nil }
        if message.bool("receipt_unavailable") { return DeliveryLabels.receipt("") }
        guard message.values["deliveries"] != nil else { return nil }
        return DeliveryLabels.receipt(message.string("delivery_status").isEmpty ? "saved_for_pickup" : message.string("delivery_status"))
    }
    static func recipient(_ delivery: Record) -> String {
        let role = delivery.string("recipient_role")
        let display = delivery.string("recipient_display").isEmpty ? delivery.string("recipient_label") : delivery.string("recipient_display")
        let name = TriageOrchestratorDisplay.conversationLabel(provider: delivery.string("recipient_provider"), display: display, sessionID: delivery.string("recipient_session_id"))
        if role == "triage_orchestrator" { return "Orchestrator · " + name }
        if ["handler", "registered_child"].contains(role) { return "Holder · " + name }
        return name
    }
}

/// CL-126: a Triage note to the orchestrator. The draft stays bound to this
/// Triage, its store and its orchestrator across switching, close and reopen
/// and a service reconnect; a changed orchestrator asks to confirm first.
struct TriageNoteComposer: View {
    @EnvironmentObject var store: ChecklistStore
    let triage: Record
    let display: TriageOrchestratorDisplay
    let sent: () -> Void
    @State private var text = ""
    var projectID: String { triage.string("project_id") }
    var drafts: TriageNoteDrafts { TriageNoteDrafts(preferences: store.windowPreferences) }
    var destinationChanged: Bool {
        drafts.needsConfirmation(triage.id, storeIncarnation: store.storeIncarnation, projectID: projectID, orchestrator: display.sessionID)
    }
    var body: some View {
        DetailSection(title: "Note to the orchestrator") {
            AccessibleHStack(spacing: Spacing.compact) {
                Text("\(store.projectName(projectID)) · \(ProductionGroups.label(triage))").lineLimit(1)
                Image(systemName: "arrow.right").accessibilityHidden(true)
                Text(display.orchestrator ?? "Saved for pickup, no orchestrator")
                Spacer()
            }.checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText).accessibilityElement(children: .combine)
            if destinationChanged {
                AccessibleHStack {
                    Text("The orchestrator changed. Confirm the new destination before sending.").checklistFont(.micro).foregroundStyle(.orange)
                    Spacer()
                    Button("Confirm new destination") {
                        drafts.confirm(triage.id, storeIncarnation: store.storeIncarnation, projectID: projectID, orchestrator: display.sessionID)
                        text = drafts.draft(triage.id)?.body ?? text
                    }.checklistFont(.micro)
                }
            }
            TextEditor(text: Binding(get: { text }, set: { value in
                text = value
                drafts.save(triage.id, body: value, storeIncarnation: store.storeIncarnation, projectID: projectID, orchestrator: display.sessionID)
            })).checklistFont(.callout).frame(minHeight: 55).padding(Spacing.compact)
                .overlay(RoundedRectangle(cornerRadius: Radius.small).stroke(.quaternary)).accessibilityLabel("Note to the orchestrator")
            AccessibleHStack {
                if !text.isEmpty { Text(store.connected ? "Draft saved on this Mac" : "Saved on this Mac, not sent").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
                Spacer()
                Button("Send Triage note") { send() }.buttonStyle(.checklistProminent).keyboardShortcut(.return, modifiers: .command)
                    .help("Send Triage note (⌘Return)").accessibilityLabel("Send Triage note")
                    .checklistDisabled([(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Write a note first."), (destinationChanged, "The orchestrator changed. Confirm the new destination first."), (!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
            }
        }.onAppear { text = drafts.draft(triage.id)?.body ?? "" }
    }
    func send() {
        guard store.allowWrite(), store.connected, !store.busy, !destinationChanged else { return }
        let body = text
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.run("message_send", ["project_id": projectID, "triage_id": triage.id, "body": body],
                  success: display.orchestrator == nil ? "Triage note saved for pickup" : "Triage note queued for the orchestrator", completion: { _ in
            if text == body { text = ""; drafts.clear(triage.id) } else { store.notice = "Triage note sent; newer local draft text was retained." }
            sent()
        })
    }
}

/// CL-126: the ticket note audience. Both is the default; the footnote says
/// why owner directions and notices always go to both.
struct NoteAudiencePicker: View {
    @Binding var selection: NoteAudience
    let orchestrator: String
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Picker("Send to", selection: $selection) {
                ForEach(NoteAudience.allCases) { audience in Text(audience.label).tag(audience) }
            }.pickerStyle(.segmented).accessibilityLabel("Send note to").help("Both sends to the holder and to \(orchestrator). " + NoteAudience.alwaysBothReason)
            Text(NoteAudience.alwaysBothReason + " " + NoteAudience.taggedNoteReason).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }
}
