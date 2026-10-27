import SwiftUI

struct CreateTriageSheet: View {
    var onCreated: ((String) -> Void)? = nil
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) private var dismiss
    @State private var projectID = ""
    @State private var name = ""
    @State private var purpose = ""
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            Text("New Triage").checklistFont(.sheetTitle)
            Text("A Triage is the work list of one orchestrator conversation and has no phase. Until an orchestrator starts it, it is a plan: write the member order in the purpose, prerequisites first.").checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText)
            Picker("Project", selection: $projectID) { Text("Choose project").tag(""); ForEach(store.activeProjects) { Text($0.string("name")).tag($0.id) } }
            TextField("Name of this Triage", text: $name).textFieldStyle(.roundedBorder)
            Text("What should be handled together?").checklistFont(.bodyStrong)
            TextEditor(text: $purpose).checklistFont(.body).frame(height: 105).padding(Spacing.compact).overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(.quaternary))
            AccessibleHStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Create Triage") { store.run("triage_create", ["project_id": projectID, "name": name, "purpose": purpose], success: "Triage created", completion: { triage in if let id = triage["id"] as? String { onCreated?(id); store.open(.group(id)) }; dismiss() }) }.buttonStyle(.checklistProminent).checklistDisabled([(projectID.isEmpty, "Choose a project first."), (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Enter a name first."), (!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)]) }
        }.padding(Spacing.page).checklistSheet(width: 530).onAppear { projectID = store.projectID ?? (store.activeProjects.count == 1 ? store.activeProjects.first?.id ?? "" : "") }
    }
}
