import SwiftUI

struct TicketCleanupSettingsSection: View {
    @EnvironmentObject var store: ChecklistStore
    let project: Record
    @State private var done = true
    @State private var purge = true
    @State private var days = 15
    @State private var receipts: [Record] = []
    @State private var error = ""
    var settings: [String:Any] {["done_evidence_enabled":done,"closed_purge_enabled":purge,"closed_days":days]}
    var body: some View {
        DetailSection(title:"Closed ticket cleanup") {
            Toggle("Delete managed evidence after Done",isOn:$done).toggleStyle(.checkbox)
            Toggle("Purge unchanged Done and Canceled tickets",isOn:$purge).toggleStyle(.checkbox)
            Stepper("Keep closed tickets for \(days) days",value:$days,in:1...36500)
            Text("Cleanup runs automatically in the background. Evidence cleanup keeps ticket history and file names, sizes and SHA-256. Purge removes private records and leaves a minimal ticket reference. Shared files, Keep original, readers and backups remain protected. Reopening cannot restore removed files.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            if !error.isEmpty {Text(error).checklistFont(.micro).foregroundStyle(Color.red)}
            Button("Save cleanup settings") { save() }
                .checklistDisabled([(!store.connected,DisabledReasons.offline),(store.busy,DisabledReasons.saving)])
            ForEach(receipts) { receipt in
                let summary = receipt.object("summary")
                Text("\(receipt.string("created_at")): \(summary["removed_bytes"] as? Int ?? 0) bytes removed · \(summary["retained_count"] as? Int ?? 0) files kept · \(receipt.string("bytes_state"))").checklistFont(.micro)
            }
            Button("Refresh cleanup receipts") { loadReceipts() }
        }.onAppear {load();loadReceipts()}
        .onChange(of:project.integer("revision")) { _,_ in load() }
    }
    private func load() {
        let value = project.object("ticket_cleanup")
        done = value["done_evidence_enabled"] as? Bool ?? true;purge = value["closed_purge_enabled"] as? Bool ?? true;days = value["closed_days"] as? Int ?? 15
    }
    private func loadReceipts() {
        Task {do {let reply = try await store.request("ticket_cleanup_receipts",["project_id":project.id]);receipts = (reply["receipts"] as? [[String:Any]] ?? []).map(Record.init)} catch {self.error = PlainError.text(error)}}
    }
    private func save() {
        let params: [String:Any] = ["project_id":project.id,"expected_revision":project.integer("revision"),"ticket_cleanup":settings]
        store.run("project_settings_save",params,success:"Ticket cleanup settings saved") { _ in loadReceipts() }
    }
}
