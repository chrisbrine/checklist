import ChecklistIPC
import ChecklistProviders
import SwiftUI
import AppKit

struct AppSettingsView: View {
    @EnvironmentObject var store: ChecklistStore
    @AppStorage("settingsSection") private var selectedSection = "general"
    var body: some View {
        TabView(selection: Binding(get: { ["general", "storage"].contains(selectedSection) ? selectedSection : "general" }, set: { selectedSection = $0 })) {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            StorageSettingsView().tabItem { Label("Storage", systemImage: "externaldrive") }.tag("storage")
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(Spacing.control).environment(\.checklistStorageUpgradeStatus, store.storageUpgradeStatus).onAppear { if !["general", "storage"].contains(selectedSection) { selectedSection = "general" } }
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var store: ChecklistStore
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage(TextScale.key, store: .standard) private var textScale = 1.0
    @AppStorage(DockBadge.key) private var showDockBadge = true
    @State private var badgeAllowed: Bool?
    var body: some View {
        Form {
            Section("Checklist") {
                LabeledContent("Version", value: ChecklistBuildVersion.current.version).accessibilityIdentifier("checklistVersion")
                LabeledContent("Installed build", value: store.buildLabel)
                LabeledContent("Service", value: store.serviceConnectionLabel)
                Text("Local macOS production checklist. Existing checklists have not been migrated.").checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText)
            }
            DiagnosticsExportSection()
            Section("Workspace") {
                Toggle("Show sidebar", isOn: $sidebarVisible)
                Toggle("Show the Needs You count on the Dock icon", isOn: $showDockBadge)
                    .onChange(of: showDockBadge) { _, _ in
                        DockBadge.apply(count: store.needsCount)
                        Task { await DockBadge.requestPermissionIfNeeded(); badgeAllowed = await DockBadge.macOSAllowsBadge() }
                    }
                    .task { badgeAllowed = await DockBadge.macOSAllowsBadge() }
                if showDockBadge && badgeAllowed == false {
                    Text("macOS does not show Checklist's badge now. You can allow it in System Settings > Notifications > Checklist.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    Button("Open Notifications settings") { NSWorkspace.shared.open(DockBadge.notificationSettingsURL) }
                }
                Picker("Text size", selection: Binding(get: { TextScale.normalized(textScale) }, set: { textScale = $0 })) {
                    ForEach(TextScale.steps, id: \.self) { scale in Text("\(Int(scale * 100))%").tag(scale) }
                }.accessibilityLabel("Text size")
                Button("Refresh current state") { Task { await store.refresh() } }
            }
            QuickCaptureSettingsSection()
            Section("Agent sessions") {
                Text("The bundled MCP bridge can start the local service with the app closed. Use a ticket in Codex or Claude; the actual thread connects itself when it uses Checklist.").checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText)
                Text("No hidden model runtime or scheduled ticket pickup is enabled.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }
            ProviderMessageReadinessView()
        }.formStyle(.grouped).padding(.top, Spacing.small)
    }
}

struct StorageSettingsView: View {
    @EnvironmentObject var store: ChecklistStore
    @StateObject private var observation = StorageSettingsObservation()
    /// The folder choice. Tests supply a synthetic backup; the app uses the open panel.
    var chooseBackup: (@MainActor (@escaping @MainActor (URL) -> Void) -> Void)? = nil
    private var info: [String:Any] {observation.info}
    private var restorePreview: [String:Any] {observation.restorePreview}
    var body: some View {
        Form {
            Section("Local store") {
                Text("Checklist keeps one local database and managed attachment storage. External references stay in their original location.").checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText)
                LabeledContent("Database", value:info["database_path"] as? String ?? "Loading…")
                LabeledContent("Available managed originals", value:StorageSettingsSummary.bytes(info["managed_bytes"]))
                Text("Original sizes are logical lengths from attachment records; they exclude previews, source captures and database files.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                Button("Show app data in Finder") { NSWorkspace.shared.open(ChecklistInstance.current.ownerDataRoot) }
            }
            Section("Last verified backup") {
                ForEach(StorageSettingsSummary.observation(info["last_verified_backup"])) {row in LabeledContent(row.label,value:row.value)}
            }
            Section("Last verified rehearsal") {
                ForEach(StorageSettingsSummary.observation(info["last_verified_rehearsal"])) {row in LabeledContent(row.label,value:row.value)}
                Text("Restore-copy checks and pre-upgrade database rehearsals do not qualify native startup or session reconnection.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }
            Section("Retained storage at verification") {
                ForEach(StorageSettingsSummary.retained(info["retained_usage"])) {row in LabeledContent(row.label,value:row.value)}
                Text("Recorded backup and restore copies only. Measurements exclude staging, directories and unrecorded copies, and are not rechecked for moved or deleted folders. Allocated blocks count each inode once within a copy; hard links between copies and shared APFS extents may count the same physical storage again. These figures do not measure space freed by deletion.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                Button("Refresh storage status") {Task {await refreshStorageStatus()}}
                if !observation.statusError.isEmpty {Text(observation.statusError).checklistFont(.micro).textSelection(.enabled)}
            }
            BackupRetentionSettingsView()
            Section("Export & backup") {
                Button("Back up all projects…") { backup() }.checklistDisabled([(observation.backingUp || observation.restoring, "Wait for storage verification to finish.")])
                if observation.backingUp {
                    ProgressView("Copying and verifying backup…").controlSize(.small)
                }
                Text("Large stores can take about 10 minutes; Checklist allows up to 30 minutes. You can keep adding notes and editing tickets while files copy. Cleanup waits until backup finishes.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                Button("Preview backup restore…") { previewRestore() }.checklistDisabled([(observation.backingUp || observation.restoring, "Wait for storage verification to finish."), (store.busy, "Wait for the current change to finish."), (store.hasPendingMutation, "Use Check the last change before starting another change.")])
                if observation.restoring { ProgressView("Verifying and preparing restored copy…").controlSize(.small) }
                Text("Restore prepares a separate data root and keeps this installation intact. Prior sessions need fresh connections, active work needs recovery and unresolved deliveries stay quarantined.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                if !restorePreview.isEmpty && !observation.restoring {
                    Text("Backup verified. Review it to prepare a restored copy.").checklistFont(.callout)
                    Button("Review verified backup…") {observation.showingRestorePreview = true}
                }
                if !observation.result.isEmpty { Text(observation.result).checklistFont(.micro).textSelection(.enabled) }
                LongOperationRows(log:store.longOperations)
            }
        }.formStyle(.grouped).sheet(isPresented:$observation.showingRestorePreview) {
            RestorePreviewSheet(preview:restorePreview,cancel:{observation.showingRestorePreview = false},confirm:{restoreCopy()})
        }.task(id:store.storeIncarnation) {await refreshStorageStatus()}
        .onChange(of:store.storeIncarnation) {_,scope in observation.changeScope(scope)}
    }
    func refreshStorageStatus() async {
        let scope = store.storeIncarnation;observation.changeScope(scope)
        await observation.refreshStatus {try await store.request("storage_status",ifCurrent:{StorageSettingsObservation.sameStore(store.storeIncarnation,scope)})}
    }
    func previewRestore() {
        if let chooseBackup {chooseBackup {previewRestore(url:$0)};return}
        let panel = NSOpenPanel();panel.canChooseDirectories = true;panel.canChooseFiles = false;panel.allowsMultipleSelection = false
        panel.message = "Choose a completed Checklist backup folder to verify."
        panel.begin { response in
            guard response == .OK,let url = panel.url else {return}
            previewRestore(url:url)
        }
    }
    private func previewRestore(url: URL) {
        let scope = store.storeIncarnation;observation.changeScope(scope)
        Task {
            guard StorageSettingsObservation.sameStore(store.storeIncarnation,scope) else {return}
            await observation.previewRestore {try await store.request("restore_preview",["path":url.path],ifCurrent:{StorageSettingsObservation.sameStore(store.storeIncarnation,scope)})}
        }
    }
    func restoreCopy() {
        let scope = observation.scope
        let params: [String:Any] = ["command_id":UUID().uuidString,"path":restorePreview["path"] ?? "","manifest_sha256":restorePreview["manifest_sha256"] ?? ""]
        observation.clearRestorePreview();observation.result = ""
        // Preserve the exact original command in the app's incarnation-bound
        // recovery journal if publication succeeds but its reply is lost.
        store.run("restore_create",params,failure:{error in
            guard observation.scope == scope else {return}
            observation.restoring = false
            if !(error is CancellationError) {observation.result = PlainError.text(error)}
        },completion:{reply in
            guard observation.scope == scope else {return}
            observation.restoring = false;observation.storageDidChange()
            observation.result = "Restored copy prepared at \(reply["path"] as? String ?? ""). This installation is preserved."
            Task {await refreshStorageStatus()}
        })
        observation.restoring = store.busy
    }
    func backup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Checklist-backup"; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scope = store.storeIncarnation;observation.changeScope(scope)
        Task {
            guard StorageSettingsObservation.sameStore(store.storeIncarnation,scope) else {return}
            await observation.backup(path:url.path,fetch:{
                try await store.request("backup_create",["command_id":UUID().uuidString,"path":url.path],ifCurrent:{StorageSettingsObservation.sameStore(store.storeIncarnation,scope)})
            },status:{try await store.request("storage_status",ifCurrent:{StorageSettingsObservation.sameStore(store.storeIncarnation,scope)})})
        }
    }
}

/// The verified restore preview. Cancel and Prepare restored copy only report
/// the owner's choice; StorageSettingsView owns the restore command.
///
/// CL-273: the decision stays outside the scrolling content, so it is visible
/// for any backup size. CL-272: the content is a plain stack of bounded rows
/// (at most `StorageSettingsSummary.unavailableShown` unavailable entries, with
/// exact totals), so no lazy list can change under an accessibility action.
struct RestorePreviewSheet: View {
    let preview: [String:Any]
    let cancel: () -> Void
    let confirm: () -> Void
    var body: some View {
        let unavailable = StorageSettingsSummary.unavailable(preview)
        VStack(alignment:.leading,spacing:Spacing.control) {
            Text("Restore backup to a separate data root").font(.headline)
            Text("The complete database and managed files passed verification. This installation stays available. Credentials and native connections are not restored.")
            ScrollView { VStack(alignment:.leading,spacing:Spacing.control) {
                ForEach(StorageSettingsSummary.preview(preview)) {row in LabeledContent(row.label,value:row.value)}
                Text("Projects: \(preview["project_count"] as? Int ?? 0). " + ((preview["projects"] as? [[String:Any]] ?? []).prefix(10).compactMap {$0["name"] as? String}.joined(separator:", ")))
                Text("Managed files: \(preview["managed_files"] as? Int ?? 0). Unavailable managed content: \(unavailable.total). External references: \((preview["external_references"] as? [String])?.count ?? 0).")
                ForEach(StorageSettingsSummary.recordFamilies(preview)) {row in LabeledContent(row.label,value:row.value)}
                if unavailable.total > 0 {
                    Text("Unavailable content").font(.headline)
                    ForEach(unavailable.reasons) {row in LabeledContent(row.label,value:row.value)}
                    Text(unavailable.shown.count < unavailable.total ? "The first \(unavailable.shown.count) of \(unavailable.total) unavailable entries:" : "All \(unavailable.total) unavailable entries:").checklistFont(.micro)
                    ForEach(unavailable.shown) {row in Text("\(row.label): \(row.value)").checklistFont(.micro)}
                }
            }.frame(maxWidth:.infinity,alignment:.leading) }
            Divider()
            Text("Active work requires explicit recovery. Pending or uncertain messages will not be resent.")
            HStack { Button("Cancel") {cancel()}; Spacer(); Button("Prepare restored copy") {confirm()} }
        }.padding().frame(width:560,height:620)
    }
}
