import SwiftUI
import ChecklistIPC
import AppKit
import UniformTypeIdentifiers

struct DiagnosticsExportSection: View {
    @EnvironmentObject var store: ChecklistStore
    @State private var exporting = false
    @State private var result = ""

    var body: some View {
        Section("Diagnostics") {
            Button("Save diagnostics…") { save() }.checklistDisabled([(exporting, "Diagnostics are being saved.")])
            Text("Save versions, build ID, service state, record counts and recent error codes. Notes, file contents, paths and connection secrets are excluded. Nothing is uploaded.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            if !result.isEmpty { Text(result).checklistFont(.micro).accessibilityIdentifier("diagnosticsExportResult") }
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Checklist-diagnostics.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.prompt = "Save diagnostics"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exporting = true; result = ""
        Task { @MainActor in
            defer { exporting = false }
            var summary: [String: Any]?
            var upgrade = store.storageUpgradeStatus
            do { summary = try await store.request("diagnostics_summary") }
            catch { upgrade = StorageUpgradeStatus(error: error) ?? upgrade; DiagnosticsRecorder.shared.record(error.localizedDescription) }
            do {
                try DiagnosticsExport.write(DiagnosticsExport.currentReport(serviceSummary: summary), to: destination)
                if summary == nil, let upgrade {
                    result = "Diagnostics saved. Checklist is upgrading. " + upgrade.summary + " Record counts are omitted."
                } else { result = summary == nil ? "Diagnostics saved. The service was unavailable, so record counts are omitted." : "Diagnostics saved on this Mac." }
            } catch { store.error = "Diagnostics could not be saved: \(PlainError.text(error))" }
        }
    }
}
