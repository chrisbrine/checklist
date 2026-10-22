import SwiftUI

struct CreateTriageSheet: View {
    var onCreated: ((String) -> Void)? = nil
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) private var dismiss
    @State private var projectID = ""
    @State private var name = ""
    @State private var purpose = ""
    @State private var phase = "implementation"
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            Text("New Triage").checklistFont(.sheetTitle)
            Text("Group one phase of work. Implementation submission leaves its Triage; put submitted tickets into a separate review Triage. Only failed tickets need another implementation pass.").checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText)
            Picker("Project", selection: $projectID) { Text("Choose project").tag(""); ForEach(store.activeProjects) { Text($0.string("name")).tag($0.id) } }
            TextField("Name of this Triage", text: $name).textFieldStyle(.roundedBorder)
            Picker("Phase",selection:$phase) { Text("Implementation").tag("implementation");Text("Review").tag("review") }.pickerStyle(.segmented).tint(.checklistAccent)
            Text("What should be handled together?").checklistFont(.bodyStrong)
            TextEditor(text: $purpose).checklistFont(.body).frame(height: 105).padding(Spacing.compact).overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(.quaternary))
            AccessibleHStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Create Triage") { store.run("triage_create", ["project_id": projectID, "name": name, "purpose": purpose,"phase":phase], success: "Triage created") { triage in if let id = triage["id"] as? String { onCreated?(id); store.open(.group(id)) }; dismiss() } }.buttonStyle(.checklistProminent).checklistDisabled([(projectID.isEmpty, "Choose a project first."), (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Enter a name first."), (!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)]) }
        }.padding(Spacing.page).checklistSheet(width: 530).onAppear { projectID = store.projectID ?? (store.activeProjects.count == 1 ? store.activeProjects.first?.id ?? "" : "") }
    }
}
