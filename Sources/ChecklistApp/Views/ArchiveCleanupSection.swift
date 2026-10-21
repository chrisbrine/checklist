import SwiftUI

struct ArchiveStorageSettingsSection: View {
    @EnvironmentObject var store: ChecklistStore
    let project: Record
    @State private var draft = ArchiveStorageDraft()
    @State private var baseline = ArchiveStorageDraft()
    @State private var baseRevision = 0
    @State private var settingsRevision = 0
    var body: some View {
        DetailSection(title:"Archive storage") {
            Picker("Preset",selection:$draft.preset) { Text("Clean large managed files on archive").tag("clean_large_managed_on_archive");Text("Keep originals").tag("keep_originals") }
            AccessibleHStack {
                TextField("Large original threshold",text:$draft.threshold).textFieldStyle(.roundedBorder)
                TextField("Retained ticket budget",text:$draft.budget).textFieldStyle(.roundedBorder)
                Picker("Size unit",selection:$draft.unit) { Text("MiB").tag(Int64(1_048_576));Text("Bytes").tag(Int64(1)) }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("The total budget can select smaller files too. Keep-original, shared evidence, active work, review, readers and backup captures remain protected. Cleanup has a 30-second cancellation window.").checklistFont(.micro).foregroundStyle(.secondary)
            if baseRevision != project.integer("revision") || settingsRevision != project.integer("settings_revision") { Text("Project settings changed. Reload before saving; your edits are preserved.").checklistFont(.micro).foregroundStyle(.orange) }
            AccessibleHStack {
                Button("Save storage settings") { save() }.checklistDisabled([(draft.value == nil, "There are no changes to save."), (draft == baseline, "There are no changes to save."), (store.busy, DisabledReasons.saving), (!store.connected, DisabledReasons.offline), (baseRevision != project.integer("revision"), "The project changed. Reload the settings first."), (settingsRevision != project.integer("settings_revision"), "The project settings changed. Reload them first.")])
                Button("Reload storage settings") { load() }.buttonStyle(.link)
            }
        }.task(id:project.id) { load() }
    }
    private func load() { draft = .init(project.object("archive_storage"));baseline = draft;baseRevision = project.integer("revision");settingsRevision = project.integer("settings_revision") }
    private func save() {
        guard let value = draft.value else { return }
        let submitted = draft
        store.run("archive_storage_settings",["project_id":project.id,"expected_revision":baseRevision,"settings_revision":settingsRevision,"archive_storage":value],success:"Archive storage settings saved") { reply in
            baseRevision = (reply["revision"] as? NSNumber)?.intValue ?? baseRevision
            settingsRevision = (reply["settings_revision"] as? NSNumber)?.intValue ?? settingsRevision
            baseline = submitted // Edits made during the save remain dirty.
        }
    }
}

struct ArchiveCleanupSection: View {
    @EnvironmentObject var store: ChecklistStore
    let task: Record
    @State private var jobs: [Record] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var readID = UUID()
    private var current: Bool { store.connected && store.selectedTicketCurrent(task.id) }
    var body: some View {
        DetailSection(title:"Archive cleanup") {
            AccessibleHStack { Text("Observed job state").checklistFont(.micro).foregroundStyle(.secondary);Spacer();Button("Refresh cleanup") { Task { await load() } }.buttonStyle(.link).checklistDisabled([(loading, "Still loading."), (!current, "The cleanup state changed. Refresh first.")]) }
            if loading { ProgressView().controlSize(.small) }
            if let failure { Text(failure).checklistFont(.micro).foregroundStyle(.orange) }
            if jobs.isEmpty && !loading { Text("No cleanup job recorded for this ticket.").checklistFont(.micro).foregroundStyle(.secondary) }
            ForEach(jobs.prefix(4)) { job in
                VStack(alignment:.leading,spacing: Spacing.compact) {
                    Text(GlossaryText.title(job.string("state"))).checklistFont(.calloutEmphasis)
                    Text("Selected \(bytes(job,"selected_logical_original_bytes")) · removed from active store \(bytes(job,"removed_logical_original_bytes")) · already absent \(bytes(job,"already_missing_logical_original_bytes"))").checklistFont(.micro)
                    Text("Known at backup: \(job.values["known_backup_retained_logical_original_bytes"] is NSNumber ? bytes(job,"known_backup_retained_logical_original_bytes") : "unavailable"). Current external backup presence, physical disk savings and backup-retained allocation are unverified. Logical lengths are not physical reclamation.").checklistFont(.micro).foregroundStyle(.secondary)
                    let reasons = Array(Set(job.records("items").flatMap {$0.strings("holds")})).sorted()
                    if !reasons.isEmpty { Text("Retained: " + reasons.map(ArchiveStorageDraft.holdLabel).joined(separator:", ")).checklistFont(.micro).foregroundStyle(.secondary) }
                    AccessibleHStack {
                        if job.bool("can_cancel_remaining") { Button("Cancel remaining cleanup") { change(job,"cleanup_job_cancel") }.checklistDisabled([(!store.connected, DisabledReasons.offline), (!current, "The cleanup state changed. Refresh first."), (store.busy, DisabledReasons.saving), (store.hasPendingMutation, DisabledReasons.uncheckedChange)]) }
                        if job.string("state") == "suspended" { Button("Retry with a new Undo window") { change(job,"cleanup_job_retry") }.checklistDisabled([(!store.connected, DisabledReasons.offline), (!current, "The cleanup state changed. Refresh first."), (store.busy, DisabledReasons.saving), (store.hasPendingMutation, DisabledReasons.uncheckedChange)]) }
                        if task.bool("archived") { Button("Undo archive") { store.run("task_archive",["project_id":task.string("project_id"),"task_id":task.id,"expected_revision":task.integer("revision"),"action":"unarchive","cleanup":false],success:"Unarchived; any deleted originals remain unavailable") { _ in Task { await load() } } }.checklistDisabled([(!store.connected, DisabledReasons.offline), (!current, "The cleanup state changed. Refresh first."), (store.busy, DisabledReasons.saving), (store.hasPendingMutation, DisabledReasons.uncheckedChange)]) }
                    }
                    Text("Cancel affects only remaining originals. Unarchiving restores the ticket and retained previews, never deleted bytes.").checklistFont(.micro).foregroundStyle(.secondary)
                }.padding(.vertical,Spacing.compact)
            }
            if jobs.count > 4 { Text("Showing the four latest jobs. Refresh or use the service for the complete bounded history.").checklistFont(.micro).foregroundStyle(.secondary) }
        }.task(id:task.id + ":" + String(task.bool("archived"))) { await load() }
            .onDisappear { readID = UUID() }
    }
    private func bytes(_ job: Record,_ key: String) -> String { ByteCountFormatter.string(fromByteCount:(job.values[key] as? NSNumber)?.int64Value ?? 0,countStyle:.file) }
    private func load() async {
        guard current else { return };let id = UUID();readID = id;loading = true;failure = nil
        do {
            let reply = try await store.request("cleanup_job_list",["project_id":task.string("project_id"),"task_id":task.id])
            guard readID == id,current,!Task.isCancelled else { return }
            jobs = (reply["cleanup_jobs"] as? [[String:Any]] ?? []).map(Record.init);loading = false
        } catch { guard readID == id,current else { return };failure = PlainError.text(error);loading = false }
    }
    private func change(_ job: Record,_ method: String) {
        guard current else { return }
        store.run(method,["project_id":task.string("project_id"),"cleanup_job_id":job.id,"expected_revision":job.integer("revision")],success:method == "cleanup_job_retry" ? "Cleanup queued with a new cancellation window" : "Remaining cleanup canceled") { _ in Task { await load() } }
    }
}
