import SwiftUI
import ChecklistDomain
import ChecklistIPC

struct CaptureTaskView: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) private var dismiss
    @State private var projectID = ""
    @State private var title = ""
    @State private var brief = ""
    @State private var kind = "work"
    @State private var starterFields: [String: String] = [:]
    @State private var epicID = ""
    @State private var draftStoreIncarnation = ""
    @State private var pendingAttachments:[CaptureAttachment]=[]
    @State private var createCommandID:String?
    @State private var createdTaskID:String?
    @State private var epicPage:[Record]=[]
    @State private var epicTotal:Int?
    @State private var epicNext:String?
    @State private var epicPrevious:String?
    @State private var epicLoading=false
    @State private var epicError:String?
    @State private var epicRead=UUID()
    @FocusState private var titleFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            AccessibleHStack { Text("New ticket").checklistFont(.sheetTitle); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.checklistIcon).accessibilityLabel("Close ticket capture").help("Close ticket capture") }
            Picker("Project", selection: Binding(get: { projectID }, set: { switchProject($0) })) { Text("Choose a project").tag(""); ForEach(store.activeProjects) { Text($0.string("name")).tag($0.id) } }.checklistDisabled([(createCommandID != nil, "This ticket is being created."), (createdTaskID != nil, "This ticket is being created."), (store.busy, DisabledReasons.saving)])
            if let createdTaskID {Text("Ticket captured · "+String(createdTaskID.prefix(8))+". Finish its selected files before starting another ticket.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)}
            if !projectID.isEmpty {
                Picker("Epic", selection: Binding(get: { epicID }, set: { epicID = $0; persistCapture() })) {
                    Text("Choose an Epic").tag("")
                    if !epicID.isEmpty,!availableEpics.contains(where:{RecordIdentity($0.id)==RecordIdentity(epicID)}) {Text("Saved Epic · "+String(epicID.prefix(8))).tag(epicID)}
                    ForEach(availableEpics) {Text($0.string("name")).tag($0.id)}
                }.checklistDisabled([(createCommandID != nil, "This ticket is being created."), (createdTaskID != nil, "This ticket is being created."), (store.busy, DisabledReasons.saving), (epicLoading, "Epics are still loading.")])
                AccessibleHStack {if epicLoading {ProgressView().controlSize(.small)};if let token=epicPrevious {Button("Previous Epics") {Task {await loadEpics(cursor:token)}}};if let token=epicNext {Button("More Epics") {Task {await loadEpics(cursor:token)}}}}.checklistFont(.micro).checklistDisabled([(epicLoading, "Epics are still loading.")])
                if epicTotal == 0,!epicLoading {CaptureEpicCreator(projectID:projectID,request: {try await store.request($0,$1)}) {epic in guard RecordIdentity(epic.string("project_id"))==RecordIdentity(projectID) else {return};epicID=epic.id;epicPage=[epic];epicTotal=1;persistCapture()}}
                if let epicError {Text(epicError).checklistFont(.micro).foregroundStyle(.orange)}
            }
            TextField("What needs doing?", text: Binding(get: { title }, set: { title = $0; persistCapture() })).checklistFont(.subheading).textFieldStyle(.roundedBorder).focused($titleFocused).accessibilityIdentifier("captureTitle").checklistDisabled([(createCommandID != nil, "This ticket is being created."), (createdTaskID != nil, "This ticket is being created."), (store.busy, DisabledReasons.saving)])
            AccessibleHStack { Picker("Starter", selection: Binding(get: { kind }, set: { kind = $0; persistCapture() })) { ForEach(enabledKinds, id: \.self) { Text($0.capitalized).tag($0) } }.frame(maxWidth: .infinity, alignment: .leading).checklistDisabled([(createCommandID != nil, "This ticket is being created."), (createdTaskID != nil, "This ticket is being created."), (store.busy, DisabledReasons.saving)]); Spacer(); Text("Saves as Draft").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
            if !starterHint.isEmpty { Text(starterHint).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
            if !StarterFields.fields(for: kind).isEmpty {
                StarterFieldsEditor(kind: kind, values: Binding(get: { starterFields }, set: { starterFields = $0; persistCapture() }))
                    .checklistDisabled([(createCommandID != nil, "This ticket is being created."), (createdTaskID != nil, "This ticket is being created."), (store.busy, DisabledReasons.saving)])
            }
            TextEditor(text: Binding(get: { brief }, set: { brief = $0; persistCapture() })).checklistFont(.body).frame(height: 110).padding(Spacing.compact).overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(.quaternary)).accessibilityLabel("Optional brief").checklistDisabled([(createCommandID != nil, "This ticket is being created."), (createdTaskID != nil, "This ticket is being created."), (store.busy, DisabledReasons.saving)])
            AttachmentCaptureSection(pending:$pendingAttachments,destination:Binding(get:{CaptureAttachmentDestination(storeIncarnation:store.storeIncarnation,projectID:projectID,taskID:nil)},set:{_ in}),disabled:store.busy || captureNeedsReconciliation)
            Text("Choose a project and Epic and add a title to capture it. Add the outcome and make it ready when you're set.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            if !title.isEmpty || !brief.isEmpty {
                DraftSaveStatusView(kind: "capture", draftID: projectID)
                if captureNeedsReconciliation {
                    Text("This draft belongs to an earlier store. Confirm its destination before creating it.").checklistFont(.micro).foregroundStyle(.orange)
                    Button("Use this draft in the selected project") { draftStoreIncarnation = store.storeIncarnation;createdTaskID=nil;createCommandID=nil; persistCapture() }.buttonStyle(.link).checklistDisabled([(!store.connected, DisabledReasons.offline)])
                }
            }
            AccessibleHStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(createdTaskID != nil ? "Finish attachments" : createCommandID != nil ? "Finish creating this ticket" : "Create Draft") { createDraft() }.buttonStyle(.checklistProminent).keyboardShortcut(.return, modifiers: .command)
                    .checklistDisabled([(projectID.isEmpty, "Choose a project first."), (createdTaskID == nil && createCommandID == nil && epicID.isEmpty, "Choose an Epic first."), (title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Enter a title first."), (store.busy, DisabledReasons.saving), (!store.connected, DisabledReasons.offline), (captureNeedsReconciliation, "This draft belongs to an earlier store. Confirm its destination first."), (createCommandID == nil && epicLoading, "Epics are still loading.")])
            }
        }.padding(Spacing.page).checklistSheet(width: 510).modifier(CaptureAllowsQuit()).onAppear {
            if let epic = store.groups.first(where: { $0.id == store.captureEpicID && $0.string("kind") == "epic" }) { switchProject(epic.string("project_id")); epicID = epic.id }
            else { switchProject(store.captureInitialProjectID) }
            titleFocused = true
        }.task(id:projectID) {await loadEpics()}
            // Editable bindings save before returning, including the final edit before Quit.
            .onDisappear {epicRead=UUID();persistCapture(); store.captureEpicID = nil }
    }
    var captureDefaults: [String: Any] { store.project(projectID)?.object("capture_defaults") ?? [:] }
    var captureNeedsReconciliation: Bool { (!title.isEmpty || !brief.isEmpty) && draftStoreIncarnation != store.storeIncarnation }
    var enabledKinds: [String] { captureDefaults["enabled_kinds"] as? [String] ?? TicketKind.wireValues }
    var starterHint: String {
        let hint = (captureDefaults["starter_overrides"] as? [[String: Any]] ?? []).first { $0["kind"] as? String == kind } ?? [:]
        return [hint["brief_hint"] as? String,hint["outcome_hint"] as? String].compactMap {$0}.joined(separator: " · ")
    }
    func applyCaptureDefaults() { kind = captureDefaults["default_kind"] as? String ?? "work" }
    func switchProject(_ next: String) {
        if !title.isEmpty || !brief.isEmpty { persistCapture() }
        epicRead=UUID();epicPage=[];epicNext=nil;epicPrevious=nil;epicTotal=nil;epicError=nil;epicLoading = !next.isEmpty
        projectID = next
        if let draft = store.captureDrafts[next] {
            title = draft.title; brief = draft.brief; kind = draft.kind; epicID = draft.epicID.isEmpty ? CaptureEpicDefaults.last(next,preferences:store.windowPreferences) : draft.epicID; starterFields = draft.starterFields ?? [:]; draftStoreIncarnation = draft.storeIncarnation;createdTaskID=draft.createdTaskID;createCommandID=draft.createCommandID
        } else {
            title = ""; brief = ""; epicID = CaptureEpicDefaults.last(next,preferences:store.windowPreferences); starterFields = [:];createdTaskID=nil;createCommandID=nil; draftStoreIncarnation = store.storeIncarnation; applyCaptureDefaults()
        }
    }
    func persistCapture() { store.saveCapture(CaptureDraft(projectID: projectID, title: title, brief: brief, kind: kind, epicID: epicID, storeIncarnation: draftStoreIncarnation,createdTaskID:createdTaskID,createCommandID:createCommandID,starterFields:starterFields.isEmpty ? nil : starterFields)) }
    func createDraft() {
        let submittedTitle=title,submittedBrief=brief,submittedProject=projectID,submittedStore=store.storeIncarnation
        let destination=CaptureAttachmentDestination(storeIncarnation:submittedStore,projectID:submittedProject,taskID:nil)
        let files=pendingAttachments.filter {$0.destination==destination}
        func finish(_ id:String) {
            CaptureAttachmentUpload.send(files,projectID:submittedProject,taskID:id,store:store,accepted:{accepted in pendingAttachments.removeAll {$0.id==accepted}}) {
                guard Data(store.storeIncarnation.utf8)==Data(submittedStore.utf8) else {return}
                if Data(title.utf8)==Data(submittedTitle.utf8),Data(brief.utf8)==Data(submittedBrief.utf8),Data(projectID.utf8)==Data(submittedProject.utf8) {title="";brief="";starterFields=[:];createdTaskID=nil;createCommandID=nil;persistCapture()}
                store.open(.task(id));dismiss()
            }
        }
        if let createdTaskID {finish(createdTaskID);return}
        persistCapture()
        let params:[String:Any]
        do {params=try store.captureCreateParameters(projectID:submittedProject);createCommandID=params["command_id"] as? String}
        catch {store.error=PlainError.text(error);return}
        guard let command=createCommandID else {return}
        store.run("task_create",params,success:"Draft captured; attaching selected files",failure:{error in
            if (error as? ChecklistError)?.code == "EPIC_REQUIRED" {createCommandID=nil;persistCapture()}
        }) {result in
            guard let id=store.recordCapturedTask(result,projectID:submittedProject,commandID:command,store:submittedStore) else {store.error="The ticket may already be created. Check it again; your draft and files are kept.";return}
            createdTaskID=id;persistCapture();finish(id)
        }
    }

    var availableEpics:[Record] {epicPage.filter {RecordIdentity($0.string("project_id"))==RecordIdentity(projectID)}}
    func loadEpics(cursor:String? = nil)async {
        let project=projectID,read=UUID();epicRead=read
        guard !project.isEmpty else {epicPage=[];epicNext=nil;epicPrevious=nil;return}
        epicLoading=true;epicError=nil
        do {
            let query=WorkspacePageQuery(surface:"epics",project:project)
            // CL-288: a retired (superseded) read is read again, never shown as an error.
            guard let response=try await store.supersedableRead("workspace_page",query.parameters(cursor:cursor),isCurrent:{epicRead==read && RecordIdentity(projectID)==RecordIdentity(project)}) else {if epicRead==read {epicLoading=false};return}
            guard !Task.isCancelled,epicRead==read,RecordIdentity(projectID)==RecordIdentity(project) else{return}
            let page=try WorkspacePage(response,query:query)
            epicPage=page.rows;epicTotal=page.total;epicNext=page.next;epicPrevious=page.previous;epicLoading=false
            // Omission from this page never invalidates a durable draft's Epic.
        } catch {if epicRead==read {epicLoading=false;if !(error is CancellationError) {epicError="Could not load Epic choices. The saved Epic is preserved; retry by reopening capture."}}}
    }
}

struct NewProjectView: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var prefix = ""
    @State private var root = ""
    @State private var symbol = "folder"
    @State private var accent = "teal"
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            Text("New project").checklistFont(.sheetTitle)
            TextField("Project name", text: $name).textFieldStyle(.roundedBorder)
            AccessibleHStack { TextField("Key prefix (e.g. GAME)", text: $prefix).textFieldStyle(.roundedBorder); Picker("Icon", selection: $symbol) { ForEach(["folder", "gamecontroller", "app", "leaf", "tram", "checklist", "sparkles", "hammer"], id: \.self) { Label($0, systemImage: $0).tag($0) } }.labelsHidden() }
            AccessibleHStack { Text(root.isEmpty ? "No workspace selected" : root).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText).lineLimit(2); Spacer(); Button("Choose folder…") { if let path = chooseFiles(directories: true, files: false, multiple: false).first { root = path.path } } }
            Text("Workspace binding lets agents resolve this project safely. You can add it later. No existing checklists are imported.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            AccessibleHStack { Text("Accent"); Picker("Accent", selection: $accent) { ForEach(["teal", "blue", "purple", "orange", "green", "pink"], id: \.self) { Text($0.capitalized).tag($0) } }.labelsHidden(); Spacer() }
            AccessibleHStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Create project") { var params: [String: Any] = ["name": name, "key_prefix": prefix.uppercased(), "icon": symbol, "accent": accent]; if !root.isEmpty { params["root_path"] = root }; store.run("project_create", params, success: "Project created", completion: { result in if let project = result["project"] as? [String: Any], let id = project["id"] as? String { store.select(.tasks, project: id) } else if let id = result["id"] as? String { store.select(.tasks, project: id) }; dismiss() }) }.buttonStyle(.checklistProminent).checklistDisabled([(name.isEmpty, "Enter a name first."), (prefix.isEmpty, "Enter a key prefix first."), (store.busy, DisabledReasons.saving), (!store.connected, DisabledReasons.offline)]) }
        }.padding(Spacing.page).checklistSheet(width: 500)
    }
}


/// CL-68: the optional Bug and Playtest fields in capture. Every field may stay empty.
struct StarterFieldsEditor: View {
    let kind: String
    @Binding var values: [String: String]
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(kind == "bug" ? "Bug details (optional)" : "Playtest details (optional)").checklistFont(.captionEmphasis).foregroundStyle(Color.checklistSecondaryText)
            ForEach(StarterFields.fields(for: kind)) { field in
                let text = Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0.isEmpty ? nil : $0 })
                if field.multiline {
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(field.label).checklistFont(.caption)
                        TextEditor(text: text).checklistFont(.body).frame(height: 64).padding(Spacing.tight)
                            .overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(.quaternary))
                            .accessibilityLabel(field.label).accessibilityIdentifier("starter-" + field.key)
                    }
                } else {
                    TextField(field.label, text: text, prompt: Text(field.prompt)).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("starter-" + field.key)
                }
            }
        }
    }
}

/// CL-68: a ticket's Bug or Playtest details, shown under its brief when any field has text.
struct StarterFieldsSection: View {
    let task: Record
    var body: some View {
        let rows = StarterFields.display(task.object("starter_fields"), kind: task.string("kind"))
        if !rows.isEmpty {
            DetailSection(title: task.string("kind") == "playtest" ? "Playtest details" : task.string("kind") == "bug" ? "Bug details" : "Details") {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        Text(row.label).checklistFont(.captionEmphasis).foregroundStyle(Color.checklistSecondaryText)
                        Text(row.value).checklistFont(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}
