import ChecklistIPC
import SwiftUI
import AppKit

struct AppSettingsView: View {
    @EnvironmentObject var store: ChecklistStore
    @AppStorage("settingsSection") private var selectedSection = "general"
    var body: some View {
        TabView(selection: Binding(get: { ["general", "storage"].contains(selectedSection) ? selectedSection : "general" }, set: { selectedSection = $0 })) {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            StorageSettingsView().tabItem { Label("Storage", systemImage: "externaldrive") }.tag("storage")
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(Spacing.control).onAppear { if !["general", "storage"].contains(selectedSection) { selectedSection = "general" } }
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
                LabeledContent("Installed build", value: store.buildLabel)
                LabeledContent("Service", value: store.connected ? "Connected" : "Disconnected")
                Text("Local macOS production checklist. Existing checklists have not been migrated.").checklistFont(.callout).foregroundStyle(.secondary)
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
                    Text("macOS does not show Checklist's badge now. You can allow it in System Settings > Notifications > Checklist.").checklistFont(.micro).foregroundStyle(.secondary)
                    Button("Open Notifications settings") { NSWorkspace.shared.open(DockBadge.notificationSettingsURL) }
                }
                Picker("Text size", selection: Binding(get: { TextScale.normalized(textScale) }, set: { textScale = $0 })) {
                    ForEach(TextScale.steps, id: \.self) { scale in Text("\(Int(scale * 100))%").tag(scale) }
                }.accessibilityLabel("Text size")
                Button("Refresh current state") { Task { await store.refresh() } }
            }
            QuickCaptureSettingsSection()
            Section("Agent sessions") {
                Text("The bundled MCP bridge can start the local service with the app closed. Use a ticket in Codex or Claude; the actual thread connects itself when it uses Checklist.").checklistFont(.callout).foregroundStyle(.secondary)
                Text("No hidden model runtime or scheduled ticket pickup is enabled.").checklistFont(.micro).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(.top, Spacing.small)
    }
}

struct StorageSettingsView: View {
    @EnvironmentObject var store: ChecklistStore
    @State private var info: [String: Any] = [:]
    @State private var result = ""
    var body: some View {
        Form {
            Section("Local store") {
                Text("Checklist keeps one local database and managed attachment storage. External references stay in their original location.").checklistFont(.callout).foregroundStyle(.secondary)
                ForEach(info.keys.sorted(), id: \.self) { key in if let text = info[key] as? String { LabeledContent(GlossaryText.humanize(key).capitalized, value: text) } else if let number = info[key] as? NSNumber { LabeledContent(GlossaryText.humanize(key).capitalized, value: number.stringValue) } }
                Button("Show app data in Finder") { NSWorkspace.shared.open(ChecklistInstance.current.ownerDataRoot) }
            }
            Section("Export & backup") {
                Button("Back up all projects…") { backup() }
                Text("Backups include records and managed objects. Restore is not available in this build. Credentials are never portable authority.").checklistFont(.micro).foregroundStyle(.secondary)
                if !result.isEmpty { Text(result).checklistFont(.micro).textSelection(.enabled) }
            }
        }.formStyle(.grouped).task { do { info = try await store.request("storage_status") } catch { result = PlainError.text(error) } }
    }
    func backup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Checklist-backup"; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do { let reply = try await store.request("backup_create", ["command_id": UUID().uuidString, "path": url.path]); result = "Backup saved to \(reply["path"] as? String ?? url.path). Restore is not yet available." } catch { result = PlainError.text(error) } }
    }
}

