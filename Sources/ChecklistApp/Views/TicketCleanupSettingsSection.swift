import SwiftUI

struct TicketCleanupSettingsSection: View {
    @EnvironmentObject var store: ChecklistStore
    let project: Record
    @State private var done = true
    @State private var purge = true
    @State private var days = 15
    @State private var refreshID = UUID()
    var settings: [String:Any] {["done_evidence_enabled":done,"closed_purge_enabled":purge,"closed_days":days]}
    var body: some View {
        DetailSection(title:"Closed ticket cleanup") {
            Toggle("Delete managed evidence after Done",isOn:$done).toggleStyle(.checkbox)
            Toggle("Purge unchanged Done and Canceled tickets",isOn:$purge).toggleStyle(.checkbox)
            Stepper("Keep closed tickets for \(days) days",value:$days,in:1...36500)
            Text("Cleanup runs automatically in the background. Evidence cleanup keeps ticket history and file names, sizes and SHA-256. Purge removes private records and leaves a minimal ticket reference. Shared files, Keep original, readers and backups remain protected. Reopening cannot restore removed files.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            Button("Save cleanup settings") { save() }
                .checklistDisabled([(!store.connected,DisabledReasons.offline),(store.busy,DisabledReasons.saving)])
            TicketCleanupReceiptRows(observation:store.ticketCleanupReceipts,scope:receiptScope)
            Button("Refresh cleanup receipts") { loadReceipts() }
        }.onAppear {load()}
        .task(id:receiptScope + refreshID.uuidString + (showsCurrentSettings ? "" : ":inactive")) {
            // A closing panel (or one whose settings record is not installed) has
            // only a generation scope; it must not take over the receipt
            // observation or evict the retained receipts (CL-260).
            guard showsCurrentSettings else {return}
            await store.ticketCleanupReceipts.load(scope:receiptScope) {
                try await store.request("ticket_cleanup_receipts",["project_id":project.id,"limit":50])
            }
        }
        .onChange(of:project.integer("revision")) { _,_ in load() }
    }
    private func load() {
        let value = project.object("ticket_cleanup")
        done = value["done_evidence_enabled"] as? Bool ?? true;purge = value["closed_purge_enabled"] as? Bool ?? true;days = value["closed_days"] as? Int ?? 15
    }
    private var receiptScope: String {store.cleanupReceiptScope(project.id)}
    private var showsCurrentSettings: Bool {
        store.detail == .project(project.id) && store.selectedOther.map {RecordIdentity($0.id) == RecordIdentity(project.id)} == true
    }
    private func loadReceipts() {
        store.ticketCleanupReceipts.invalidate(scope:receiptScope)
        refreshID = UUID()
    }
    private func save() {
        let params: [String:Any] = ["project_id":project.id,"expected_revision":project.integer("revision"),"ticket_cleanup":settings]
        store.run("project_settings_save",params,success:"Ticket cleanup settings saved") { _ in loadReceipts() }
    }
}


@MainActor final class TicketCleanupReceiptObservation: ObservableObject {
    @Published private(set) var loaded = false
    @Published private(set) var receipts: [Record] = []
    @Published private(set) var scope = ""
    @Published private(set) var error = ""
    private var cache: [String:[Record]] = [:]
    private var generation = UUID()
    func isCached(scope: String) -> Bool {cache[scope] != nil}
    /// Navigation installs the retained receipts of this exact scope before the
    /// first display pass; the section's background read then refreshes them.
    @discardableResult func install(scope: String) -> Bool {
        guard let cached = cache[scope] else {return false}
        if self.scope != scope || !loaded {
            // Fence a read started for another scope; it cannot replace these rows.
            generation = UUID();self.scope = scope;loaded = true
        }
        if !error.isEmpty {error = ""}
        if !DisplayValueEquality.records(receipts,cached) {receipts = cached}
        return true
    }
    func invalidate(scope: String) {
        cache.removeValue(forKey:scope)
        if self.scope == scope {generation = UUID()}
    }
    func load(scope: String,fetch: () async throws -> [String:Any]) async {
        guard !Task.isCancelled else {return}
        // Retained rows stay displayed while the background read runs.
        let cached = install(scope:scope)
        let token = UUID();generation = token
        if !cached {
            if self.scope != scope {receipts = [];loaded = false}
            self.scope = scope;error = ""
        }
        do {
            let reply = try await fetch()
            guard generation == token,!Task.isCancelled else {return}
            let fresh = (reply["receipts"] as? [[String:Any]] ?? []).map(Record.init)
            if !DisplayValueEquality.records(receipts,fresh) {receipts = fresh}
            if cache[scope] == nil,cache.count >= 5 {cache.removeAll()}
            cache[scope] = fresh;loaded = true
        } catch {
            // A failed background read keeps the retained rows of this exact scope.
            guard generation == token,!Task.isCancelled,!(error is CancellationError),!cached else {return}
            self.error = PlainError.text(error)
        }
    }
}

private struct TicketCleanupReceiptRows: View {
    @ObservedObject var observation: TicketCleanupReceiptObservation
    let scope: String
    var body: some View {
        if observation.scope == scope {
            ForEach(observation.receipts) { receipt in
                let summary = receipt.object("summary")
                Text("\(receipt.string("created_at")): \(summary["removed_bytes"] as? Int ?? 0) bytes removed · \(summary["retained_count"] as? Int ?? 0) files kept · \(receipt.string("bytes_state"))").checklistFont(.micro)
            }
            if !observation.error.isEmpty {Text(observation.error).checklistFont(.micro).foregroundStyle(Color.red)}
        }
    }
}

/// Observe receipt readiness independently of the large settings form. The
/// panel's display pass commits the receipt rows even when they are below its
/// viewport; measuring the rows' own draw would wait for a manual scroll.
struct TicketCleanupContentFrame: View {
    @EnvironmentObject var store: ChecklistStore
    @ObservedObject var observation: TicketCleanupReceiptObservation
    let projectID: String
    var body: some View {
        Color.clear.screenContentFrame(store.screenTiming,.cleanup,
            ready:store.detail == .project(projectID) && store.selectedOther?.id == projectID && observation.scope == store.cleanupReceiptScope(projectID) && observation.loaded)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
