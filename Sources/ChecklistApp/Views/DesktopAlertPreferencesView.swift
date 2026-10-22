import SwiftUI

struct DesktopAlertPreferencesView: View {
    @AppStorage(DesktopAlertPreferences.enabledKey,store:.standard) private var enabled = false
    @AppStorage(DesktopAlertPreferences.defaultModeKey,store:.standard) private var defaultMode = "needs_you"
    @ObservedObject private var alerts = DesktopAlertCoordinator.shared
    @State private var authorization: DesktopAlertAuthorization = .notRequested
    @State private var setupError = ""
    var body: some View {
        VStack(alignment:.leading,spacing: Spacing.small) {
            Toggle("Enable desktop alerts on this Mac",isOn:$enabled).toggleStyle(.checkbox)
            Picker("App default on this Mac",selection:$defaultMode) { Text("Actionable Needs You").tag("needs_you"); Text("Needs You and delivery issues").tag("all") }
            Text(status).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            if authorization == .notRequested {
                Button("Allow desktop alerts in macOS…") {
                    Task {
                        do { let granted = try await alerts.requestAuthorizationFromOwnerAction(); if granted { enabled = true }; authorization = await alerts.authorization() }
                        catch { setupError = PlainError.text(error) }
                    }
                }
            }
            Text("Only new items while Checklist is open produce alerts. Project Quiet suppresses them; Needs You and delivery receipts stay in the app.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            if let failure = alerts.lastFailure { Text(failure).checklistFont(.micro).foregroundStyle(.orange) }
            if !setupError.isEmpty { Text(setupError).checklistFont(.micro).foregroundStyle(.orange) }
        }
        .task { authorization = await alerts.authorization() }
        .onChange(of:enabled) { _,_ in Task { await alerts.preferencesChanged() } }
        .onChange(of:defaultMode) { _,_ in Task { await alerts.preferencesChanged() } }
    }
    var status: String {
        if !enabled { return "Desktop alerts are off on this Mac. Project preferences remain saved." }
        switch authorization {
        case .allowed: return "macOS permits alerts. Project preferences apply to new items."
        case .denied: return "macOS blocks Checklist notifications. Change its notification permission in System Settings to receive alerts."
        case .notRequested: return "macOS permission has not been requested. No desktop alerts can appear yet."
        }
    }
}
