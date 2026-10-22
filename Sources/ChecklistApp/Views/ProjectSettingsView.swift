import SwiftUI
import ChecklistProviders

struct ProjectSettingsView: View {
    @EnvironmentObject var store: ChecklistStore
    let project: Record
    @State private var name = ""
    @State private var prefix = ""
    @State private var icon = "folder"
    @State private var accent = "teal"
    @State private var brief = ""
    @State private var pinnedDecisions = PinnedDecisionDrafts()
    @State private var preset = "shared"
    @State private var requireReview = true
    @State private var requireHumanApproval = false
    @State private var allowHumanDecisionEvidence = false
    @State private var coordinator = "both"
    @State private var coordinatorSession = ""
    @State private var implementer = "both"
    @State private var reviewer = "both"
    @State private var allowedProviders = ProviderPluginRegistry.bundled.workProviders
    @State private var agentsChangeRules = true
    @State private var batchPolicy = "complete_passing_independently"
    @State private var applyMode = "future_attempts"
    @State private var kindDrafts = PolicyKindSettings.kinds.map { PolicyKindSettings(kind: $0) }
    @State private var preview: [String: Any]?
    @State private var previewSignature = ""
    @State private var savedWorkflowSignature = ""
    @State private var reviewRequirements = ReviewRequirementsDraft()
    @State private var enabledKinds = Set(PolicyKindSettings.kinds)
    @State private var defaultKind = "work"
    @State private var defaultGrouping = "status"
    @State private var defaultOrder = "manual"
    @State private var alerts = "inherit"
    @State private var healthEnabled = true
    @State private var healthInactivity = 20
    @State private var healthGrace = 20
    @State private var statusName = ""
    @State private var statusCategory = "parked"
    @State private var tagName = ""
    @State private var tagColor = "teal"
    @State private var editingTaxonomy: TaxonomyEdit?
    @State private var retiringStatus: Record?
    @State private var confirmation: PendingConfirmation?
    var body: some View { confirmableBody.checklistConfirmation($confirmation) }
    @ViewBuilder var confirmableBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.page) {
                Text("Project settings").checklistFont(.pageTitle)
                DetailSection(title: "Identity") {
                    AccessibleHStack(spacing: Spacing.control) {
                        ProjectIcon(project: project, size: 52)
                        VStack(alignment: .leading, spacing: Spacing.small) {
                            Button("Choose icon image…") { importIcon() }
                            if !project.string("icon_path").isEmpty { Button("Use built-in symbol") { store.run("project_icon_clear", ["project_id": project.id, "expected_revision": project.integer("revision")], success: "Project icon cleared") } }
                            Text("Small managed copy · Finder original preserved").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                        }
                    }
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    AccessibleHStack { TextField("Future key prefix", text: $prefix).textFieldStyle(.roundedBorder); Picker("Symbol", selection: $icon) { ForEach(["folder", "gamecontroller", "app", "leaf", "tram", "checklist", "sparkles", "hammer"], id: \.self) { Label($0, systemImage: $0).tag($0) } }.labelsHidden() }
                    Picker("Accent", selection: $accent) { ForEach(["teal", "blue", "purple", "orange", "green", "pink"], id: \.self) { Text($0.capitalized).tag($0) } }
                    Text("Existing keys keep their identity when the prefix changes.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                }
                DetailSection(title: "Project context") {
                    TextEditor(text: $brief).checklistFont(.body).frame(height: 100).padding(Spacing.compact).overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(.quaternary))
                    Text("Brief and decisions accompany future agent pickup.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    ForEach(pinnedDecisions.rows) { decision in
                        VStack(alignment:.leading,spacing: Spacing.small) {
                            TextField("Decision title (optional)",text:pinText(decision.id,"title")).textFieldStyle(.roundedBorder)
                            TextEditor(text:pinText(decision.id,"body")).checklistFont(.body).frame(height:65).overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(.quaternary))
                            Text("Applies to all kinds unless selected below").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                            AccessibleHStack { ForEach(PolicyKindSettings.kinds,id:\.self) { kind in Toggle(kind.capitalized,isOn:pinKind(decision.id,kind)).toggleStyle(.checkbox) } }
                            AccessibleHStack { Text("Approval and stable identity are recorded by Checklist.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText); Spacer(); Button("Remove decision…") { confirmation = Confirmations.removeDecision { pinnedDecisions.remove(decision.id) } } }
                        }.padding(.vertical,Spacing.small)
                    }
                    Button("Add pinned decision") { pinnedDecisions.appendEmpty() }.checklistDisabled([(pinnedDecisions.count >= 25, "A project can pin at most 25 decisions.")])
                }
                MediaTypeSettings(projectID:project.id, model:store.mediaReview)
                ArchiveStorageSettingsSection(project:project)
                workflowSettings
                ReviewRequirementsEditor(draft:$reviewRequirements)
                captureSettings
                DetailSection(title: "Active work health") {
                    Toggle("Check active work", isOn: $healthEnabled).toggleStyle(.checkbox)
                    Stepper("Ask after \(healthInactivity) minutes without progress", value: $healthInactivity, in: 1...10080)
                    Stepper("Response grace: \(healthGrace) minutes", value: $healthGrace, in: 1...10080)
                    Text("Pausing retains requests. Resuming gives a fresh interval or response grace. Health checks never release claims or launch an agent. Native wake is unavailable; requests wait for MCP pickup.").checklistFont(.micro).foregroundStyle(.secondary)
                }
                Button("Save project settings") { saveSettings() }.buttonStyle(.checklistProminent).checklistDisabled([(name.isEmpty, "Enter a name first."), (prefix.isEmpty, "Enter a key prefix first."), (!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving), ((workflowNeedsPreview && (!matchingWorkflowPreview || !reviewRequirements.canPreview)), "Preview the workflow change first.")])
                Text(workflowNeedsPreview ? "Preview workflow changes before saving. A conflict preserves this draft." : "Project details and defaults save directly. A conflict preserves this draft.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                Divider()
                DetailSection(title: "Statuses") {
                    ForEach(store.statuses(project.id).filter { !$0.bool("retired") }) { status in AccessibleHStack { StatusPill(name: status.string("name"), category: status.string("category")); Spacer(); Text(status.string("category")).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText); Menu { Button("Edit name, color or order…") { editingTaxonomy = TaxonomyEdit(record: status, kind: "status") }; Button("Retire and review affected tickets…") { retiringStatus = status } } label: { Image(systemName: "ellipsis") }.menuStyle(.button).buttonStyle(.checklistIcon).menuIndicator(.hidden).frame(width: 25).accessibilityLabel("Status actions: \(status.string("name"))").help("Edit or retire this status") } }
                    AccessibleHStack { TextField("New status name", text: $statusName).textFieldStyle(.roundedBorder); Picker("Behaves like", selection: $statusCategory) { ForEach(["queued", "active", "review", "blocked", "parked", "done", "canceled"], id: \.self) { Text($0.capitalized).tag($0) } }.frame(maxWidth: .infinity, alignment: .leading) }
                    Button("Add status") { store.run("status_create", ["project_id": project.id, "name": statusName, "category": statusCategory, "color": statusCategory == "parked" ? "orange" : "teal"], success: "Status added") { _ in statusName = "" } }.checklistDisabled([(!store.connected, DisabledReasons.offline), (statusName.isEmpty, "Enter a status name first."), (store.busy, DisabledReasons.saving)])
                    Text("Use multiple Parked variants for different reasons. Status labels cannot bypass work or review gates.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                }
                Divider()
                DetailSection(title: "Tags") {
                    ForEach(store.tags(project.id).filter { !$0.bool("retired") }.sorted { $0.integer("sort_order") < $1.integer("sort_order") }) { tag in AccessibleHStack { Label(tag.string("name"), systemImage: "tag").checklistFont(.callout).foregroundStyle(Color.named(tag.string("color"))); Spacer(); Menu { Button("Edit name, color or order…") { editingTaxonomy = TaxonomyEdit(record: tag, kind: "tag") }; Button("Retire…") { confirmation = Confirmations.retireTag(tag.string("name")) { store.run("tag_retire", ["project_id": project.id, "tag_id": tag.id, "expected_revision": tag.integer("revision")]) } } } label: { Image(systemName: "ellipsis") }.menuStyle(.button).buttonStyle(.checklistIcon).menuIndicator(.hidden).frame(width: 25).accessibilityLabel("Tag actions: \(tag.string("name"))").help("Edit or retire this tag") } }
                    AccessibleHStack { TextField("New tag", text: $tagName).textFieldStyle(.roundedBorder); Picker("Color", selection: $tagColor) { ForEach(["teal", "blue", "purple", "orange", "green", "pink"], id: \.self) { Text($0.capitalized).tag($0) } }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading); Button("Add") { store.run("tag_create", ["project_id": project.id, "name": tagName, "color": tagColor]) { _ in tagName = "" } }.checklistDisabled([(!store.connected, DisabledReasons.offline), (tagName.isEmpty, "Enter a tag name first."), (store.busy, DisabledReasons.saving)]) }
                }
                Divider()
                DetailSection(title: "Workspace") { Text(project.string("root_path").isEmpty ? "No workspace bound. Agent work needs an explicit project folder." : project.string("root_path")).checklistFont(.code).textSelection(.enabled); Button("Choose workspace…") { if let url = chooseFiles(directories: true, files: false, multiple: false).first { store.run("project_edit", ["project_id": project.id, "expected_revision": project.integer("revision"), "root_path": url.path], success: "Workspace updated") } } }
                Divider()
                DetailSection(title: "Archive") {
                    if project.bool("archived") {
                        Text(ProjectArchiveText.archivedNotice).checklistFont(.callout).foregroundStyle(Color.checklistSecondaryText)
                        Button("Restore project") { store.setProjectArchived(project, archived: false) }
                            .checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
                    } else {
                        Text(ProjectArchiveText.archiveHelp).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                        Button("Archive project…") { confirmation = Confirmations.archiveProject(project.string("name")) { store.setProjectArchived(project, archived: true) } }
                            .checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
                    }
                }
                AccessibleHStack { Button("Epics") { store.select(.epics, project: project.id); store.closeDetail() }; Button("Tickets") { store.select(.tasks, project: project.id); store.closeDetail() } }
            }.padding(Spacing.page)
        }.sheet(item: $editingTaxonomy) { item in TaxonomyEditor(item: item, projectID: project.id).environmentObject(store) }.sheet(item:$retiringStatus) { status in StatusRetirementView(status:status,projectID:project.id).environmentObject(store) }.onAppear { loadDraft() }
    }
    var workflowSettings: some View {
        DetailSection(title: "Workflow") {
            Picker("Routing preset", selection:Binding(get:{preset},set:applyPreset)) {
                ForEach(ProviderPolicyDefaults.presets,id:\.self) { value in
                    Text(value == "shared" ? "Shared work" : value.replacingOccurrences(of:"_",with:" ").capitalized).tag(value)
                }
            }
            AccessibleHStack {
                ForEach(HandoffProvider.workProviders()) { provider in Toggle("\(provider.name) participates",isOn:participation(provider.id)) }
            }.toggleStyle(.checkbox)
            PolicyProviderPicker(title:"Coordinator", selection:$coordinator)
            PolicyProviderPicker(title:"Implementation", selection:$implementer)
            PolicyProviderPicker(title:"Independent review", selection:$reviewer)
            Picker("Coordinator context copies",selection:$coordinatorSession) { Text("No selected session").tag(""); ForEach(store.workSessions.filter { $0.string("project_id") == project.id || $0.strings("project_ids").contains(project.id) }) { session in Text("\(session.string("label",fallback:"Worker")) · \(session.string("provider")) · \(session.id.prefix(8))").tag(session.id) } }
            Text("Select an existing eligible worker to receive relevant context copies. This does not assign work or enroll a connection.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            Toggle("Agents may change this project's rules and settings", isOn: $agentsChangeRules).toggleStyle(.checkbox).help("On by default. Agents change rules, statuses, tags and settings; each change is recorded as an agent action. Only you can switch this.")
            Toggle("Require independent review", isOn: $requireReview).toggleStyle(.checkbox)
            Toggle("Require owner approval", isOn: $requireHumanApproval).toggleStyle(.checkbox)
            Toggle("Allow recorded decisions for human-assigned work",isOn:$allowHumanDecisionEvidence).toggleStyle(.checkbox)
            Text("Questions may record their answer. Other tickets for a person need this explicit permission; their required review gates still apply.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            Picker("Passing reviews", selection:$batchPolicy) { Text("Complete passing tickets independently (default)").tag("complete_passing_independently"); Text("Hold passing tickets for the batch (project override)").tag("hold_passing_for_batch") }
            Text("After review, work continues only on failed or remaining tickets. Each passing ticket still needs all its own gates.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            DisclosureGroup("Ticket-type exceptions") {
                ForEach($kindDrafts) { $draft in
                    VStack(alignment:.leading,spacing: Spacing.small) {
                        Text(draft.kind.capitalized).checklistFont(.bodyStrong)
                        PolicyProviderPicker(title:"Coordinator",selection:$draft.coordinator,inherit:true)
                        PolicyProviderPicker(title:"Implementation",selection:$draft.implementer,inherit:true)
                        PolicyProviderPicker(title:"Review",selection:$draft.reviewer,inherit:true)
                        Toggle("Override completion gates",isOn:$draft.overrideGates).toggleStyle(.checkbox)
                        if draft.overrideGates { Toggle("Independent review",isOn:$draft.review).toggleStyle(.checkbox); Toggle("Owner approval",isOn:$draft.human).toggleStyle(.checkbox) }
                        Picker("Human decision evidence",selection:$draft.decisionEvidence) { Text("Inherit project").tag("inherit"); Text("Allow for human-assigned tickets").tag("allow"); Text("Question answers only").tag("artifact") }
                    }.padding(.vertical,Spacing.small)
                }
            }
            Picker("Apply workflow",selection:$applyMode) { Text("Future work rounds").tag("future_attempts"); Text("Active work confirms the new rules first").tag("checkpoint_active") }
            Text("Future rounds preserve completion gates and active review requirements. New review claims pin the latest requirements. Checkpoint mode requires explicit acknowledgment before further submission or verdicts. Removing service authority takes effect immediately; it cannot stop an external process.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            Button("Preview workflow effects") { let signature = policySignature; store.run("policy_propose",["project_id":project.id,"policy":policyDraft,"mode":applyMode]) { result in preview = result; previewSignature = signature } }.checklistDisabled([(store.busy, DisabledReasons.saving), (!store.connected, DisabledReasons.offline), (!reviewRequirements.canPreview, "Fix the review requirements first.")])
            if let preview, previewSignature == policySignature {
                let affected = preview["affected_tasks"] as? [[String:Any]] ?? [], active = preview["active_rounds"] as? [[String:Any]] ?? []
                Text("\(affected.count) affected tickets · \(active.count) active attempts · \(active.filter { $0["authority_revoked"] as? Bool == true }.count) authority removals").checklistFont(.microEmphasis)
                ForEach(StableListRows.policyPreview(affected, projectID: project.id)) { item in
                    let row = item.value.values, before = row["before_gates"] as? [String] ?? [], after = row["after_gates"] as? [String] ?? []
                    Text("\(row["key"] as? String ?? "Ticket"): \(before.isEmpty ? "no gates" : before.joined(separator:", ")) → \(after.isEmpty ? "no gates" : after.joined(separator:", "))").checklistFont(.micro)
                }
            }
        }
    }
    var captureSettings: some View {
        DetailSection(title:"Project defaults") {
            ForEach($kindDrafts) { $draft in
                VStack(alignment:.leading,spacing: Spacing.compact) {
                    Toggle("\(draft.kind.capitalized) capture shortcut",isOn:Binding(get:{ enabledKinds.contains(draft.kind) },set:{ enabled in if enabled { enabledKinds.insert(draft.kind) } else { enabledKinds.remove(draft.kind); if defaultKind == draft.kind { defaultKind = "work" } } })).checklistDisabled([(draft.kind == "work", "Work capture is always available.")]).toggleStyle(.checkbox)
                    TextField("Optional brief hint",text:$draft.briefHint).textFieldStyle(.roundedBorder)
                    TextField("Optional outcome hint",text:$draft.outcomeHint).textFieldStyle(.roundedBorder)
                }.padding(.vertical,Spacing.tight)
            }
            Picker("Default capture kind",selection:$defaultKind) { ForEach(PolicyKindSettings.kinds.filter { enabledKinds.contains($0) },id:\.self) { Text($0.capitalized).tag($0) } }
            Picker("Initial grouping",selection:$defaultGrouping) { Text("Status").tag("status"); Text("Epic").tag("epic"); Text("None").tag("none") }
            Picker("Initial order",selection:$defaultOrder) { Text("Manual").tag("manual"); Text("Priority").tag("priority"); Text("Recent update").tag("updated_desc") }
            Picker("Desktop alerts",selection:$alerts) { Text("Inherit app preference").tag("inherit"); Text("Actionable Needs You").tag("needs_you"); Text("Quiet").tag("quiet") }
            DesktopAlertPreferencesView()
            Text("Personal views keep their saved choices. Quiet alerts keep Needs You, failures and live updates visible.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
        }
    }
    func applyPreset(_ value: String) {
        preset = value
        coordinator = PolicyProviderChoices.defaultChoice(role:"coordinator",preset:value,allowed:allowedProviders)
        implementer = PolicyProviderChoices.defaultChoice(role:"implementer",preset:value,allowed:allowedProviders)
        reviewer = PolicyProviderChoices.defaultChoice(role:"reviewer",preset:value,allowed:allowedProviders)
    }
    func participation(_ id: String) -> Binding<Bool> {
        Binding(get:{allowedProviders.contains(id)},set:{ enabled in
            if enabled {if !allowedProviders.contains(id) {allowedProviders.append(id)}} else {allowedProviders.removeAll {$0 == id}}
        })
    }
    func role(_ choice: String, existing: Any? = nil) -> [String:Any] { PolicyProviderChoices.role(choice,existing:existing) }
    var policyDraft: [String:Any] {
        var value = project.object("policy")
        value["routing_preset"] = preset; value["allowed_providers"] = allowedProviders
        let existingRoles = value["roles"] as? [String:Any] ?? [:]
        value["roles"] = ["coordinator":role(coordinator,existing:existingRoles["coordinator"]),"implementer":role(implementer,existing:existingRoles["implementer"]),"reviewer":role(reviewer,existing:existingRoles["reviewer"])]
        value["required_gates"] = (requireReview ? ["review"] : []) + (requireHumanApproval ? ["human_approval"] : [])
        value["review_batch_policy"] = batchPolicy
        value["agent_rule_changes"] = agentsChangeRules ? "allowed" : "owner_only"
        value["allow_human_decision_evidence"] = allowHumanDecisionEvidence
        if coordinatorSession.isEmpty { value.removeValue(forKey:"coordinator_session_id") } else { value["coordinator_session_id"] = coordinatorSession }
        value["task_kind_overrides"] = kindDrafts.compactMap { draft -> [String:Any]? in
            var roles: [String:Any] = [:]
            let oldRoles = ((project.object("policy")["task_kind_overrides"] as? [[String:Any]] ?? []).first { $0["kind"] as? String == draft.kind })?["roles"] as? [String:Any] ?? [:]
            for (key,choice) in [("coordinator",draft.coordinator),("implementer",draft.implementer),("reviewer",draft.reviewer)] where choice != "inherit" { roles[key] = role(choice,existing:oldRoles[key]) }
            guard !roles.isEmpty || draft.overrideGates || draft.decisionEvidence != "inherit" else { return nil }
            var result: [String:Any] = ["kind":draft.kind]
            if !roles.isEmpty { result["roles"] = roles }
            if draft.overrideGates { result["required_gates"] = (draft.review ? ["review"] : []) + (draft.human ? ["human_approval"] : []) }
            if draft.decisionEvidence != "inherit" { result["allow_human_decision_evidence"] = draft.decisionEvidence == "allow" }
            return result
        }
        return reviewRequirements.applying(to:value)
    }
    var policySignature: String { ReviewRequirementsDraft.workflowSignature(policy:policyDraft,applyMode:applyMode) }
    var workflowNeedsPreview: Bool { policySignature != savedWorkflowSignature }
    var matchingWorkflowPreview: Bool { preview != nil && previewSignature == policySignature }
    func choice(_ rule: Any?, fallback: String) -> String { PolicyProviderChoices.choice(rule,fallback:fallback) }
    func pinText(_ id: PinnedDecisionDrafts.Row.ID, _ key: String) -> Binding<String> {
        Binding(get: { pinnedDecisions.text(id, key) }, set: { pinnedDecisions.setText($0, for: id, key: key) })
    }
    func pinKind(_ id: PinnedDecisionDrafts.Row.ID, _ kind: String) -> Binding<Bool> {
        Binding(get: { pinnedDecisions.hasKind(id, kind) }, set: { pinnedDecisions.setKind($0, for: id, kind: kind, orderedKinds: PolicyKindSettings.kinds) })
    }

    func loadDraft() {
        name = project.string("name"); prefix = project.string("key_prefix"); icon = project.string("icon",fallback:"folder"); accent = project.string("accent",fallback:"teal"); brief = project.string("brief")
        pinnedDecisions = PinnedDecisionDrafts(project.values["pinned_decisions"] as? [Any] ?? [])
        let policy = project.object("policy"), gates = policy["required_gates"] as? [String] ?? ["review"], roles = policy["roles"] as? [String:Any] ?? [:]
        reviewRequirements = ReviewRequirementsDraft(raw:policy["review_requirements"])
        preset = policy["routing_preset"] as? String ?? "shared"; requireReview = gates.contains("review"); requireHumanApproval = gates.contains("human_approval")
        coordinatorSession = policy["coordinator_session_id"] as? String ?? ""
        allowHumanDecisionEvidence = policy["allow_human_decision_evidence"] as? Bool ?? false
        agentsChangeRules = policy["agent_rule_changes"] as? String != "owner_only"
        allowedProviders = policy["allowed_providers"] as? [String] ?? ProviderPluginRegistry.bundled.workProviders
        coordinator = choice(roles["coordinator"],fallback:PolicyProviderChoices.defaultChoice(role:"coordinator",preset:preset,allowed:allowedProviders)); implementer = choice(roles["implementer"],fallback:PolicyProviderChoices.defaultChoice(role:"implementer",preset:preset,allowed:allowedProviders)); reviewer = choice(roles["reviewer"],fallback:PolicyProviderChoices.defaultChoice(role:"reviewer",preset:preset,allowed:allowedProviders))
        batchPolicy = policy["review_batch_policy"] as? String ?? "complete_passing_independently"
        let capture = project.object("capture_defaults"), hints = capture["starter_overrides"] as? [[String:Any]] ?? [], overrides = policy["task_kind_overrides"] as? [[String:Any]] ?? []
        enabledKinds = Set(capture["enabled_kinds"] as? [String] ?? PolicyKindSettings.kinds); defaultKind = capture["default_kind"] as? String ?? "work"
        kindDrafts = PolicyKindSettings.kinds.map { kind in
            var draft = PolicyKindSettings(kind:kind)
            if let override = overrides.first(where: { $0["kind"] as? String == kind }) { let roles = override["roles"] as? [String:Any] ?? [:]; draft.coordinator = choice(roles["coordinator"],fallback:"inherit"); draft.implementer = choice(roles["implementer"],fallback:"inherit"); draft.reviewer = choice(roles["reviewer"],fallback:"inherit"); if let gates = override["required_gates"] as? [String] { draft.overrideGates = true; draft.review = gates.contains("review"); draft.human = gates.contains("human_approval") }; if let decision = override["allow_human_decision_evidence"] as? Bool { draft.decisionEvidence = decision ? "allow" : "artifact" } }
            if let hint = hints.first(where: { $0["kind"] as? String == kind }) { draft.briefHint = hint["brief_hint"] as? String ?? ""; draft.outcomeHint = hint["outcome_hint"] as? String ?? "" }
            return draft
        }
        defaultGrouping = project.object("default_view")["group_by"] as? String ?? "status"; defaultOrder = project.object("default_view")["order_by"] as? String ?? "manual"; alerts = project.string("alert_override",fallback:"inherit")
        let health = project.object("work_health_settings"); healthEnabled = health["enabled"] as? Bool ?? true; healthInactivity = health["inactivity_minutes"] as? Int ?? 20; healthGrace = health["response_grace_minutes"] as? Int ?? 20
        savedWorkflowSignature = policySignature
    }
    func importIcon() {
        guard let url = chooseProjectIcon() else { return }
        store.run("project_icon_import", ["project_id": project.id, "expected_revision": project.integer("revision"), "path": url.path], success: "Project icon updated")
    }
    func saveSettings() {
        guard !workflowNeedsPreview || (matchingWorkflowPreview && reviewRequirements.canPreview) else { return }
        let submittingWorkflow = workflowNeedsPreview, submittedSignature = policySignature
        let hints = kindDrafts.compactMap { draft -> [String:Any]? in var value: [String:Any] = ["kind":draft.kind]; if !draft.briefHint.isEmpty { value["brief_hint"] = draft.briefHint }; if !draft.outcomeHint.isEmpty { value["outcome_hint"] = draft.outcomeHint }; return value.count > 1 ? value : nil }
        var params: [String:Any] = ["project_id":project.id,"expected_revision":project.integer("revision"),"name":name,"key_prefix":prefix.uppercased(),"icon":icon,"accent":accent,"brief":brief,"pinned_decisions":pinnedDecisions.payload,"capture_defaults":["enabled_kinds":PolicyKindSettings.kinds.filter { enabledKinds.contains($0) },"default_kind":defaultKind,"starter_overrides":hints],"default_view":["group_by":defaultGrouping,"order_by":defaultOrder],"alert_override":alerts]
        params["work_health_settings"] = ["enabled":healthEnabled,"inactivity_minutes":healthInactivity,"response_grace_minutes":healthGrace]
        if submittingWorkflow, let preview {
            params["policy_proposal_id"] = preview["id"] ?? ""
            params["policy_digest"] = preview["digest"] ?? ""
        }
        store.run("project_settings_save",params,success:submittingWorkflow ? "Project settings and workflow saved" : "Project settings saved") { _ in
            self.savedWorkflowSignature = submittedSignature
            self.preview = nil
            self.previewSignature = ""
        }
    }
}

struct PolicyKindSettings: Identifiable {
    static let kinds = ["work","bug","asset","playtest","question"]
    let kind: String
    var id: String { kind }
    var coordinator = "inherit"
    var implementer = "inherit"
    var reviewer = "inherit"
    var overrideGates = false
    var review = true
    var human = false
    var decisionEvidence = "inherit"
    var briefHint = ""
    var outcomeHint = ""
}

struct PolicyProviderPicker: View {
    let title: String
    @Binding var selection: String
    var inherit = false
    var providerIDs: [String] { ProviderPluginRegistry.bundled.workProviders }
    var body: some View {
        Picker(title,selection:$selection) {
            if inherit { Text("Inherit project").tag("inherit") }
            Text(PolicyProviderChoices.label("both")).tag("both")
            ForEach(HandoffProvider.workProviders()) { provider in Text(provider.name).tag(provider.id) }
            if !["both","inherit"].contains(selection), !providerIDs.contains(selection) { Text(PolicyProviderChoices.label(selection)).tag(selection) }
        }
    }
}

struct TaxonomyEdit: Identifiable {
    let record: Record
    let kind: String
    var id: String { record.id }
}

struct TaxonomyEditor: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) private var dismiss
    let item: TaxonomyEdit
    let projectID: String
    @State private var name = ""
    @State private var color = "teal"
    @State private var order = 0
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            Text("Edit \(item.kind)").checklistFont(.sheetTitle)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            Picker("Color", selection: $color) { ForEach(["teal", "blue", "purple", "orange", "green", "pink", "gray"], id: \.self) { Text($0.capitalized).tag($0) } }
            Stepper("Order: \(order)",value:$order,in:0...10000)
            if item.kind == "status" { Text("Behavior stays \(item.record.string("category")). Create a new status to change behavior.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
            AccessibleHStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save") { store.run(item.kind + "_edit", ["project_id": projectID, item.kind + "_id": item.record.id, "name": name, "color": color, "sort_order":order,"category": item.record.string("category"), "expected_revision": item.record.integer("revision")]) { _ in dismiss() } }.buttonStyle(.checklistProminent).checklistDisabled([(!store.connected, DisabledReasons.offline), (name.isEmpty, "Enter a name first."), (store.busy, DisabledReasons.saving)]) }
        }.padding(Spacing.page).checklistSheet(width: 400).onAppear { name = item.record.string("name"); color = item.record.string("color", fallback: "teal"); order = item.record.integer("sort_order",fallback:0) }
    }
}

struct StatusRetirementView: View {
    @EnvironmentObject var store: ChecklistStore
    @Environment(\.dismiss) private var dismiss
    let status: Record
    let projectID: String
    @State private var target = ""
    @State private var affected: [Record] = []
    var replacements: [Record] { store.statuses(projectID).filter { $0.id != status.id && $0.string("category") == status.string("category") } }
    var body: some View {
        VStack(alignment:.leading,spacing: Spacing.group) {
            Text("Retire \(status.string("name"))").checklistFont(.sheetTitle)
            Text("\(affected.count) tickets use this status. A replacement must keep its \(status.string("category")) behavior. Active work cannot be remapped.").checklistFont(.callout)
            if !affected.isEmpty {
                Picker("Move affected tickets to",selection:$target) { Text("Choose replacement").tag(""); ForEach(replacements) { Text($0.string("name")).tag($0.id) } }
                ScrollView { VStack(alignment:.leading,spacing: Spacing.compact) { ForEach(affected) { task in Text("\(task.string("key")) · \(task.string("title"))").checklistFont(.micro) } } }.frame(maxHeight:180)
                Text("These exact ticket revisions are checked together. A change leaves every ticket and the status unchanged. Moving a ticket removes its current Triage memberships.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }
            AccessibleHStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Retire status") { retire() }.buttonStyle(.checklistProminent).checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving), ((!affected.isEmpty && target.isEmpty), "Choose a replacement status first."), (affected.contains { !$0.string("active_attempt_id").isEmpty }, "A ticket with active work uses this status.")]) }
        }.padding(Spacing.page).checklistSheet(width: 470).onAppear { affected = store.tasks.filter { $0.string("project_id") == projectID && $0.string("status_id") == status.id } }
    }
    func retire() {
        var params: [String:Any] = ["project_id":projectID,"status_id":status.id,"expected_revision":status.integer("revision")]
        if !affected.isEmpty { params["remap_target_status_id"] = target; params["expected_task_revisions"] = Dictionary(uniqueKeysWithValues:affected.map { ($0.id,$0.integer("revision")) }) }
        store.run("status_retire",params,success:"Status retired") { _ in dismiss() }
    }
}
