import SwiftUI
import ChecklistIPC

struct ProviderMessageReadinessView: View {
    @EnvironmentObject var store: ChecklistStore
    @StateObject private var model = ProviderReadinessModel()
    private var context: ProviderReadinessContext? { store.providerReadinessContext }

    var body: some View {
        Section("Message readiness") {
            Picker("Project", selection: Binding(get: { store.projectID ?? "" }, set: { store.projectID = $0.isEmpty ? nil : $0 })) {
                Text("Choose a project").tag("")
                ForEach(store.projects) { project in Text(project.string("name")).tag(project.id) }
            }
            if let context {
                Text(context.recipientLabel).checklistFont(.micro).foregroundStyle(.secondary)
                if let observation = model.observation(for: context) {
                    claudeCard(observation)
                    codexCard(observation)
                    Text("Observed \(observation.observedAt.formatted(date: .abbreviated, time: .standard)). Refresh after changing provider settings.").checklistFont(.micro).foregroundStyle(.secondary)
                } else {
                    Text(model.context == context && model.loading ? "Reading bounded local settings…" : "No current observation. Refresh for this project and recipient.").checklistFont(.callout)
                }
                Button("Refresh message readiness") { Task { await model.refresh(context) } }
                    .checklistDisabled([(model.context == context && model.loading, "A message readiness read is already in progress.")])
            }
            Text("Settings readiness, note transport, host hold/refusal and recipient acknowledgment are separate. A readiness observation never means that a note was sent or read.").checklistFont(.micro).foregroundStyle(.secondary)
        }.onChange(of: context, initial: true) { _, value in model.invalidate(for: value) }
            .onDisappear { model.invalidate(for: nil) }
    }

    private func claudeCard(_ observation: ProviderReadinessObservation) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Claude · version unknown").checklistFont(.calloutStrong)
            Text(observation.claude.title).checklistFont(.callout)
            Text(ProviderReadinessObservation.versionLimitation).checklistFont(.micro).foregroundStyle(.secondary)
            if let decision = observation.claude.observedDecision {
                Text("Known-source result: \(decision.rawValue) · \(observation.claude.decidingSource)").checklistFont(.micro).textSelection(.enabled)
            }
            ForEach(Array(observation.sources.enumerated()), id: \.offset) { _, source in
                Text("\(source.scope.rawValue.capitalized): \(source.reading.label) · \(source.path)").checklistFont(.micro).textSelection(.enabled)
            }
            DisclosureGroup("Missing live inputs") {
                ForEach(observation.claude.missingInputs, id: \.self) { Text($0).checklistFont(.micro).textSelection(.enabled) }
            }.checklistFont(.micro)
            DisclosureGroup("Claude setup guidance") {
                Text("In your supported terminal Claude Code /config menu, use the cross-session inbound messages row if your version offers it. Claude Desktop does not open that terminal menu. Otherwise edit your user settings at the candidate path below, after confirming your live CLAUDE_CONFIG_DIR.")
                Text(observation.userPath).textSelection(.enabled)
                Text("Top-level JSON key: \"crossSessionInbound\": \"accept\"").textSelection(.enabled)
                Text("Accept releases held messages from all local senders, not only Checklist. Project/local settings can tighten it to hold or refuse; ask the project owner about the displayed path. Managed holds/refusals require the administrator responsible for that policy source. Repair invalid JSON or invalid values in the named file. Do not disable project settings to bypass a hold. Use Claude's /status to inspect setting sources; unobserved policy still needs confirmation in the actual host.")
                Text("Checklist only reads these candidates. Opening this guidance and Refresh change no provider file, permission, grant or model runtime. Automatic durable settings updates remain deferred.")
            }.checklistFont(.micro)
        }.frame(maxWidth: .infinity, alignment: .leading).checklistCard(padding: Card.padding)
    }

    private func codexCard(_ observation: ProviderReadinessObservation) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Codex · version unknown").checklistFont(.calloutStrong)
            Text(ProviderReadinessObservation.codexTitle).checklistFont(.callout)
            Text("Source: this Checklist build's MCP pickup capability; no live recipient engine version observed.").checklistFont(.micro)
            Text(ProviderReadinessObservation.codexExplanation).checklistFont(.micro).foregroundStyle(.secondary)
            Text("No automatic send or success receipt is created by this card. An actual MCP acknowledgment keeps its existing exact-recipient meaning.").checklistFont(.micro).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).checklistCard(padding: Card.padding)
    }
}
