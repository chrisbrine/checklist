import SwiftUI

struct RelatedTicketsView: View {
    @EnvironmentObject var store: ChecklistStore
    let task: Record
    @State private var adding = false
    @State private var relation = "related_to"
    @State private var targetID = ""
    @State private var required = true
    @State private var candidateSearch = ""
    @State private var candidateRows: [Record] = []
    @State private var candidateCount = 0
    @State private var candidateLoading = false
    @State private var candidateError: String?

    private var links: [Record] {
        store.detailRecords("relations",task:task).filter {
            $0.string("project_id") == task.string("project_id") && $0.string("state") != "removed" &&
            ($0.string("source_task_id") == task.id || $0.string("target_task_id") == task.id)
        }
    }
    private var candidates: [Record] {candidateRows}
    private var aliases: [Record] {
        store.detailRecords("task_aliases",task:task).filter { $0.string("task_id") == task.id && $0.string("namespace") != "duplicate_redirect" }
    }
    private var prerequisites: [Record] { task.records("prerequisites") }

    @State private var confirmation: PendingConfirmation?
    var body: some View { confirmableBody.checklistConfirmation($confirmation) }
    @ViewBuilder var confirmableBody: some View {
        DetailSection(title: "Related tickets") {
            VStack(alignment: .leading, spacing: Spacing.row) {
                if !prerequisites.isEmpty {
                    let requiredCount = prerequisites.filter {$0.bool("required")}.count
                    let blockers = prerequisites.filter {$0.bool("required") && !$0.bool("satisfied")}.count
                    Text("Prerequisites · \(requiredCount) required · \(blockers) blocking").checklistFont(.microEmphasis)
                    Text("Required prerequisites must be Done before pickup, claim or completion. They never block Ready or queueing. Optional links keep context without blocking work.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                }
                if task.string("disposition") == "superseded", let canonical = store.selectedRelatedTask(task.string("canonical_task_id"),task:task), canonical.id != task.id {
                    Text("Preserved duplicate. Its notes, findings and history remain on this ticket.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    Button("Open canonical ticket · \(canonical.string("key"))") { store.open(.task(canonical.id)) }.buttonStyle(.link)
                    Button("Reopen this ticket") {
                        store.run("task_transition", ["project_id": task.string("project_id"), "task_id": task.id, "expected_revision": task.integer("revision"), "action": "reopen"], success: "Ticket reopened; duplicate history retained")
                    }.buttonStyle(.link).checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
                }
                ForEach(links) { edge in relationRow(edge) }
                ForEach(aliases) { alias in
                    Text("Source alias: \(alias.string("namespace")) · \(alias.string("alias"))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText).textSelection(.enabled)
                }
                if links.isEmpty && aliases.isEmpty { Text("Link prerequisites, duplicates or follow-up work.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
                Button(adding ? "Cancel adding link" : "Add related ticket…") { adding.toggle() }.buttonStyle(.link)
                    .checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
                if adding { addForm }
            }
        }
    }

    private func relationRow(_ edge: Record) -> some View {
        let outgoing = edge.string("source_task_id") == task.id
        let otherID = edge.string(outgoing ? "target_task_id" : "source_task_id")
        let other = store.selectedRelatedTask(otherID,task:task)
        return AccessibleHStack(alignment: .top, spacing: Spacing.small) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(label(edge.string("relation"), outgoing: outgoing) + (edge.string("relation") == "depends_on" && edge.values["required"] as? Bool == false ? " · optional" : ""))
                    .checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                if let other {
                    Button("\(other.string("key")) · \(other.string("title"))") { store.open(.task(other.id)) }
                        .buttonStyle(.link).multilineTextAlignment(.leading)
                } else {
                    Text("Unresolved reference · \(edge.string("target_legacy_ref", fallback: edge.string("original_target_task_id", fallback: "Unavailable ticket")))")
                        .checklistFont(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                if outgoing,edge.string("relation") == "depends_on",let prerequisite = prerequisites.first(where: {$0.string("relation_id") == edge.id}) {
                    Text(prerequisite.bool("satisfied") ? "Satisfied · \(prerequisite.string("status_name",fallback:"Done"))" : prerequisite.string("reason",fallback:"Prerequisite remains unresolved"))
                        .checklistFont(.micro).foregroundStyle(prerequisite.bool("satisfied") || !prerequisite.bool("required") ? Color.checklistSecondaryText : Color.orange)
                }
            }
            Spacer(minLength: 4)
            Button { confirmation = Confirmations.removeLink { remove(edge) } } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.checklistIcon).foregroundStyle(Color.checklistSecondaryText).help("Remove this relation; preserve its history").accessibilityLabel("Remove ticket relation")
                .checklistDisabled([(!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving), (store.selectedRelatedTask(edge.string("source_task_id"),task:task) == nil, "The linked ticket is not loaded.")])
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            TextField("Search project ticket title, brief or key",text:$candidateSearch).textFieldStyle(.roundedBorder)
            if candidateLoading {ProgressView("Finding tickets…")}
            if let candidateError {Text(candidateError).checklistFont(.micro).foregroundStyle(.orange)}
            Text("Showing \(candidateRows.count) of \(candidateCount) matching project tickets. Refine the search to find another ticket.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            Picker("Relation", selection: $relation) {
                Text("Depends on").tag("depends_on")
                Text("Related to").tag("related_to")
                Text("Parent of").tag("parent_child")
                Text("Duplicate of").tag("duplicate_of")
                Text("Follow-up to").tag("follow_up_of")
            }
            Picker("Ticket", selection: $targetID) {
                Text("Choose a ticket").tag("")
                ForEach(candidates) { candidate in Text("\(candidate.string("key")) · \(candidate.string("title"))").tag(candidate.id) }
            }
            if relation == "depends_on" {
                Toggle("Required before pickup, claim and completion", isOn: $required).toggleStyle(.checkbox).checklistFont(.micro)
            }
            if relation == "duplicate_of" {
                Text("This preserves this ticket as a duplicate. Active work must be released first. Reopen explicitly to resume it.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            }
            Button("Add link") {
                store.run("task_link", ["project_id": task.string("project_id"), "task_id": task.id, "expected_revision": task.integer("revision"), "relation": relation, "target_task_id": targetID, "action": "add", "required": required], success: "Ticket linked") { _ in adding = false; targetID = "" }
            }.buttonStyle(.checklistBordered).checklistDisabled([(targetID.isEmpty, "Choose a ticket to link first."), (!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)])
        }.checklistCard(padding: Spacing.row)
            .task(id:candidateSearch) {await loadCandidates(candidateSearch)}
    }

    @MainActor private func loadCandidates(_ text: String) async {
        candidateLoading = true;candidateError = nil
        do {
            let open = try await store.request("task_list",["project_id":task.string("project_id"),"text":text,"archived":false,"limit":100])
            let archived = try await store.request("task_list",["project_id":task.string("project_id"),"text":text,"archived":true,"limit":100])
            guard !Task.isCancelled,adding,candidateSearch == text else {return}
            let all = ((open["tasks"] as? [[String:Any]]) ?? []) + ((archived["tasks"] as? [[String:Any]]) ?? [])
            candidateRows = all.map(Record.init).filter {RecordIdentity($0.id) != RecordIdentity(task.id)}.sorted {$0.string("key").localizedStandardCompare($1.string("key")) == .orderedAscending}
            candidateCount = (open["total"] as? Int ?? 0)+(archived["total"] as? Int ?? 0)
            candidateLoading = false
        } catch {
            guard !Task.isCancelled,adding,candidateSearch == text else {return}
            candidateLoading = false;candidateError = "Could not search project tickets. No link was changed."
        }
    }

    private func remove(_ edge: Record) {
        guard let source = store.selectedRelatedTask(edge.string("source_task_id"),task:task) else { return }
        store.run("task_link", ["project_id": task.string("project_id"), "task_id": source.id, "expected_revision": source.integer("revision"), "action": "remove", "relation_id": edge.id], success: "Relation removed; history preserved")
    }

    private func label(_ kind: String, outgoing: Bool) -> String {
        switch kind {
        case "depends_on": return outgoing ? "Depends on" : "Required by"
        case "related_to": return "Related to"
        case "parent_child": return outgoing ? "Parent of" : "Child of"
        case "duplicate_of": return outgoing ? "Duplicate of" : "Duplicate ticket"
        case "follow_up_of": return outgoing ? "Follow-up to" : "Follow-up ticket"
        default: return kind
        }
    }
}
