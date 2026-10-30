import SwiftUI

/// Native owner controls use the app's authenticated channel and existing
/// mutation recovery journal. A preview never performs a Trash move.
struct BackupRetentionSettingsView: View {
    @EnvironmentObject var store: ChecklistStore
    @StateObject private var observation = BackupRetentionObservation()
    @State private var confirmSave = false
    @State private var confirmPrune = false
    private var unavailable: Bool {observation.loading || store.busy || store.hasPendingMutation || !store.connected}
    var body: some View {
        Section("Backup retention") {
            Text(observation.automaticPrune ? "Your confirmed rule applies automatically after each completed backup. Older eligible backups move to Trash; the history records the result." : "Confirm a retention rule to have older eligible backups move to Trash automatically after each completed backup.")
                .checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText)
            Stepper("Newest backups: \(observation.newestCount)",value:Binding(get:{observation.newestCount},set:{observation.newestCount = $0;observation.invalidatePreview()}),in:1...1000)
                .accessibilityIdentifier("backupRetentionNewestCount").disabled(unavailable || !observation.loaded)
            Stepper("Daily backups: \(observation.dailyDays) days",value:Binding(get:{observation.dailyDays},set:{observation.dailyDays = $0;observation.invalidatePreview()}),in:0...366)
                .accessibilityIdentifier("backupRetentionDailyDays").disabled(unavailable || !observation.loaded)
            Text("Daily retention uses UTC calendar dates, including today. Your pins and protected upgrade backups stay. Incomplete and unrecorded folders need a separate reviewed Trash move.")
                .checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            HStack {
                Button("Save retention rule…") {confirmSave = true}
                    .accessibilityIdentifier("saveBackupRetention").disabled(unavailable || !observation.loaded || observation.ownerConfirmed && observation.automaticPrune && !observation.dirty)
                Button("Reload rule") {Task {await reload()}}.disabled(unavailable)
            }
            if !observation.automaticStatusText.isEmpty {Text(observation.automaticStatusText).checklistFont(.micro).textSelection(.enabled)}
            if !observation.automaticHistory.isEmpty {
                DisclosureGroup("Automatic retention history") {
                    ForEach(observation.automaticHistory) {entry in
                        Text(entry.occurredAt + " · " + entry.summary).checklistFont(.micro).textSelection(.enabled)
                    }
                }
            }
            Toggle("Include incomplete and unrecorded backup folders in this preview",isOn:Binding(get:{observation.includeUnrecorded},set:{observation.includeUnrecorded = $0;observation.invalidatePreview()}))
                .checklistFont(.micro).disabled(unavailable)
            Button("Preview backups") {Task {await preview()}}
                .accessibilityIdentifier("previewBackupRetention").disabled(unavailable || !observation.loaded || observation.dirty)
            if observation.dirty {Text("Save your rule before previewing the backups it keeps.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)}
            if observation.loading {ProgressView("Reading backups…").controlSize(.small)}
            if !observation.previewDigest.isEmpty {previewContent}
            if store.hasPendingMutation {
                Text("The last change needs checking before another change can start.").checklistFont(.micro)
                Button("Check the last change") {store.retryPendingMutation()}.disabled(store.busy || !store.connected)
            }
            if !observation.message.isEmpty {Text(observation.message).checklistFont(.micro).textSelection(.enabled)}
        }
        .task(id:store.storeIncarnation) {observation.changeScope(store.storeIncarnation);await reload()}
        .onChange(of:store.storeIncarnation) {_,_ in confirmSave = false;confirmPrune = false}
        .onDisappear {observation.cancelReads()}
        .alert("Save this backup retention rule?",isPresented:$confirmSave) {
            Button("Cancel",role:.cancel) {}
            Button("Save rule") {save()}
        } message: {
            Text("Keep the newest \(observation.newestCount) backups and the newest backup per UTC day for \(observation.dailyDays) days, plus your pins and protected upgrade backups. After each completed backup, Checklist automatically moves older eligible backups to Trash and records the result in history. Saving moves no files; Trash is never emptied automatically.")
        }
        .sheet(isPresented:$confirmPrune) {
            BackupPruneConfirmation(snapshots:observation.snapshots,confirm:{confirmPrune = false;prune()},cancel:{confirmPrune = false})
        }
    }
    private var previewContent: some View {
        VStack(alignment:.leading,spacing:Spacing.control) {
            Text("\(observation.snapshots.count) folders · \(observation.pruneCount) selected for Trash").checklistFont(.calloutEmphasis)
            ScrollView {
                VStack(alignment:.leading,spacing:Spacing.control) {
                    ForEach(observation.snapshots) {snapshot in
                        BackupRetentionSnapshotRow(snapshot:snapshot,disabled:unavailable,pin:{value in pin(snapshot,value)},retire:{pin(snapshot,false,retire:true)})
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.frame(maxHeight:280)
            Text("Incomplete or unrecorded folders are never shown as completed backups. Moving folders to Trash does not free disk space until you empty Trash.")
                .checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            Button("Move old backups to Trash…") {confirmPrune = true}
                .accessibilityIdentifier("pruneOldBackups").disabled(unavailable || !observation.canPrune)
        }
    }
    private func reload() async {
        let scope = store.storeIncarnation
        await observation.loadSettings {try await store.request("backup_retention_get",ifCurrent:{store.storeIncarnation == scope})}
    }
    private func preview() async {
        let scope = store.storeIncarnation,include = observation.includeUnrecorded
        await observation.loadPreview {try await store.request("backup_prune_preview",["include_unrecorded":include],ifCurrent:{store.storeIncarnation == scope})}
    }
    private func save() {
        let scope = store.storeIncarnation
        store.run("backup_retention_set",["newest_count":observation.newestCount,"daily_days":observation.dailyDays],failure:{error in
            guard observation.scope == scope else {return};observation.message = PlainError.text(error)
        },completion:{reply in
            guard observation.scope == scope else {return}
            observation.acceptSettings(reply);observation.message = "Retention rule saved. Older eligible backups will move to Trash automatically after each completed backup."
        })
    }
    private func pin(_ snapshot: BackupRetentionSnapshot,_ value: Bool,retire: Bool = false) {
        let scope = store.storeIncarnation
        observation.invalidatePreview()
        store.run("backup_pin",["path":snapshot.path,"pinned":value,"retire_upgrade_protection":retire],failure:{error in
            guard observation.scope == scope else {return};observation.message = PlainError.text(error)
        },completion:{_ in
            guard observation.scope == scope else {return};Task {await preview()}
        })
    }
    private func prune() {
        guard observation.canPrune else {return}
        let scope = store.storeIncarnation,params: [String:Any] = ["preview_sha256":observation.previewDigest,"include_unrecorded":observation.includeUnrecorded]
        observation.invalidatePreview()
        store.run("backup_prune",params,failure:{error in
            guard observation.scope == scope else {return};observation.message = PlainError.text(error)
        },completion:{reply in
            guard observation.scope == scope else {return}
            let moved = (reply["moved_count"] as? NSNumber)?.intValue ?? 0,retained = (reply["retained_snapshots"] as? [[String:Any]])?.count ?? 0
            observation.message = "Moved \(moved) backup folders to Trash. Retained \(retained) selected folders because they are protected or in use. Disk space is freed only when you empty Trash."
        })
    }
}

private struct BackupRetentionSnapshotRow: View {
    let snapshot: BackupRetentionSnapshot
    let disabled: Bool
    let pin: (Bool) -> Void
    let retire: () -> Void
    @State private var confirmRetire = false
    var body: some View {
        VStack(alignment:.leading,spacing:Spacing.compact) {
            Text(snapshot.name).checklistFont(.calloutEmphasis)
            Text(snapshot.complete ? "Completed backup" : "Unrecorded or incomplete folder").checklistFont(.micro)
            Text(snapshot.reasonText).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            Text(snapshot.path).checklistFont(.micro).textSelection(.enabled)
            if snapshot.protectedUpgrade {Text("Upgrade protection stays in effect independently of your pin.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)}
            Toggle("Keep this backup",isOn:Binding(get:{snapshot.pinned},set:pin)).disabled(disabled)
                .accessibilityLabel("Keep \(snapshot.name)")
            if snapshot.historicalUpgrade {
                Button("Retire historical upgrade protection…") {confirmRetire = true}.disabled(disabled)
            }
        }.padding(.vertical,Spacing.compact)
        .alert("Retire this historical upgrade protection?",isPresented:$confirmRetire) {
            Button("Cancel",role:.cancel) {}
            Button("Retire historical protection",role:.destructive,action:retire)
        } message: {
            Text("This also removes your pin for \(snapshot.name). Current and prepared upgrade backups stay protected. Review a new preview before moving any folder to Trash.")
        }
    }
}

private struct BackupPruneConfirmation: View {
    let snapshots: [BackupRetentionSnapshot]
    let confirm: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:Spacing.control) {
            Text("Move \(snapshots.filter(\.selected).count) backup folders to Trash?").font(.headline)
            Text("Review the exact folders below. Pinned, protected and in-use backups stay. You can recover moved folders from Trash; this action does not empty it.")
            ScrollView {
                VStack(alignment:.leading,spacing:Spacing.control) {
                    ForEach(snapshots.filter(\.selected)) {snapshot in Text(snapshot.path).checklistFont(.micro).textSelection(.enabled)}
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            Divider()
            HStack {Button("Cancel",role:.cancel,action:cancel);Spacer();Button("Move to Trash",role:.destructive,action:confirm).accessibilityIdentifier("confirmBackupPrune")}
        }.padding().frame(width:580,height:420)
    }
}
