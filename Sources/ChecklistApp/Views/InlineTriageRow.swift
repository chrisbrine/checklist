import SwiftUI
import ChecklistIPC

struct InlineTriageRow: View {
    @EnvironmentObject var store: ChecklistStore
    let section: InlineTriageSection
    @Binding var expanded: Bool
    let filtered: Bool
    @State private var pendingStatus: PendingTriageStatus?
    @State private var preparingStatus = false
    var completeSnapshot: Bool { section.triage.values["members_complete"] as? Bool != false && RecordIdentitySet(section.allMembers.map(\.id)) == RecordIdentitySet(section.triage.strings("task_ids")) }
    var uniformStatus: Record? {
        guard let first = section.allMembers.first, Set(section.allMembers.map { $0.string("status_id") }).count == 1 else { return nil }
        return first
    }
    var statusName: String { section.totalCount == 0 ? "Empty" : section.triage.values["members_complete"] as? Bool == false ? section.triage.string("status_name", fallback: "Mixed") : !completeSnapshot ? "Refresh needed" : uniformStatus?.string("status_name", fallback: "Queued") ?? "Mixed" }
    var rowFacts: [String] {
        var facts: [String] = []
        if store.projectID == nil { facts.append(store.projectName(section.triage.string("project_id"))) }
        facts.append(TriageOrchestratorDisplay(section.triage).summary)
        facts.append(section.visibleMembers.count == section.totalCount ? "\(section.totalCount) tickets" : "\(section.visibleMembers.count) of \(section.totalCount) tickets shown")
        let counts = TriageOrchestratorDisplay.statusCountsText(section.triage)
        if !counts.isEmpty { facts.append(counts) }
        return facts
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.none) {
            AccessibleHStack(spacing: Spacing.row) {
                Button { expanded.toggle() } label: {
                    HStack(alignment: .center, spacing: Spacing.row) {
                        // The disclosure glyph fits its fixed twelve-point column independently of text scale.
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.checklistSecondaryText).frame(width: 12)
                        Image(systemName: "tray.2").foregroundStyle(Color.checklistAccentText)
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text(ProductionGroups.label(section.triage)).checklistFont(.bodyStrong).frame(maxWidth: .infinity, alignment: .leading)
                            // CL-126: orchestrator and its state (or Planned), then ticket counts by status.
                            Text(rowFacts.joined(separator: " · ")).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.leading, Spacing.small).padding(.vertical, Spacing.small)
                }.buttonStyle(.checklistRow).accessibilityIdentifier("triageRow-\(section.id)").accessibilityLabel("\(ProductionGroups.label(section.triage)), \(expanded ? "expanded" : "collapsed") Triage, \(rowFacts.joined(separator: ", "))")
                Menu {
                    Text("Apply to all \(section.totalCount) current tickets")
                    if filtered && section.visibleMembers.count != section.totalCount { Text("Includes tickets hidden by filters") }
                    Divider()
                    ForEach(store.statuses(section.triage.string("project_id"))) { status in
                        Button(status.string("name")) { prepareStatus(status) }
                    }
                } label: {
                    // The disclosure glyph stays small beside the status pill.
                    HStack(spacing: Spacing.tight) { StatusPill(name: statusName, category: section.totalCount == 0 ? "draft" : section.triage.values["members_complete"] as? Bool == false ? section.triage.string("status_category", fallback: "mixed") : uniformStatus?.string("status_category") ?? "mixed"); Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(Color.checklistSecondaryText) }.accessibilityElement(children: .ignore)
                }.menuStyle(.button).buttonStyle(.checklistPlain).menuIndicator(.hidden).fixedSize().checklistDisabled([(preparingStatus, "The status change is being prepared."), (section.totalCount == 0, "This Triage has no tickets."), (!store.connected, DisabledReasons.offline), (store.busy, DisabledReasons.saving)]).help("Change the status of every current ticket in this Triage").accessibilityLabel("Triage status: \(statusName)")
                Menu {
                    Button("Edit Triage / add or remove tickets…") { store.open(.group(section.id)) }
                    Button(expanded ? "Collapse tickets" : "Expand tickets") { expanded.toggle() }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.button).buttonStyle(.checklistIcon).menuIndicator(.hidden).frame(width: 22).help("Triage actions").accessibilityLabel("Triage actions")
            // Leading and vertical insets total Spacing.control with the toggle label's own padding.
            }.padding(.leading, Spacing.tight).padding(.trailing, Spacing.control).padding(.vertical, Spacing.tight).checklistCard()
        }.confirmationDialog("Change every current ticket's status?", isPresented: Binding(get: { pendingStatus != nil }, set: { if !$0 { pendingStatus = nil } }), titleVisibility: .visible) {
            if let pendingStatus { Button("Apply \(pendingStatus.name) to all \(pendingStatus.memberRevisions.count) tickets") { applyStatus(pendingStatus); self.pendingStatus = nil } }
            Button("Cancel", role: .cancel) { pendingStatus = nil }
        } message: {
            Text("Change this status for all current tickets, including tickets hidden by filters. Change a ticket individually to take it out. Every ticket keeps its workflow checks; if one is blocked, none change. Done removes completed tickets from Triages.")
        }
    }
    func prepareStatus(_ status: Record) {
        guard !preparingStatus else { return }
        preparingStatus = true
        Task {
            defer { preparingStatus = false }
            do {
                var group = section.triage
                var members = section.allMembers
                if !completeSnapshot {
                    // A page header carries display summaries, never revisions for
                    // unseen members. Fetch the real set only for this explicit action.
                    let listed = try await store.request("triage_list", ["project_id": group.string("project_id")])
                    guard let fresh = (listed["groups"] as? [[String:Any]])?.first(where: { RecordIdentity($0["id"] as? String ?? "") == RecordIdentity(group.id) }) else {
                        throw ChecklistError("REVISION_CONFLICT", "This Triage changed. Refresh before applying a group status.")
                    }
                    group = Record(values: fresh)
                    let ids = group.strings("task_ids")
                    guard ids.count <= 1000 else { throw ChecklistError("CAPACITY_EXCEEDED", "This Triage is too large for one guarded group status change.") }
                    members = []
                    for id in ids {
                        let current = try await store.request("task_get", ["project_id": group.string("project_id"), "task_id": id])
                        members.append(Record(values: current))
                    }
                }
                guard Set(members.map(\.id)).count == members.count else {
                    throw ChecklistError("INVALID_INPUT", "These preserved member identities cannot be represented by this group command. No tickets changed.")
                }
                var observed = PendingTriageStatus(name: status.string("name"), statusID: status.id, groupRevision: group.integer("revision"), memberRevisions: Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.integer("revision")) }))
                if status.string("category") == "done" {
                    for task in members {
                        let context = try await store.request("task_context",["project_id":group.string("project_id"),"task_id":task.id])
                        guard let cursor = context["direction_cursor"] as? String else { throw ChecklistError("DIRECTION_CURSOR_REQUIRED", "Refresh this ticket's context before group completion.") }
                        observed.directionCursors[task.id] = cursor
                    }
                }
                pendingStatus = observed
            } catch { store.error = PlainError.text(error) }
        }
    }
    private func applyStatus(_ pending: PendingTriageStatus) {
        var input: [String:Any] = ["project_id": section.triage.string("project_id"), "triage_id": section.id, "expected_revision": pending.groupRevision, "expected_member_revisions": pending.memberRevisions, "target_status_id": pending.statusID]
        if !pending.directionCursors.isEmpty { input["expected_direction_cursors"] = pending.directionCursors }
        store.run("triage_transition",input, success: "Triage status applied to its current tickets")
    }
}

private struct PendingTriageStatus {
    let name: String
    let statusID: String
    let groupRevision: Int
    let memberRevisions: [String: Int]
    var directionCursors: [String:String] = [:]
}

/// A ticket in an expanded Triage is a separate top-level lazy-list child.
struct InlineTriageMemberRow: View {
    @EnvironmentObject var store: ChecklistStore
    let task: Record
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.none) {
            TaskRow(task: task)
            HStack(spacing: Spacing.small) {
                if task.string("readiness") != "draft" && !TicketVisibility.isClosed(task) { TicketStatusPills(task: task) }
                if let epic = store.groups.first(where: { $0.id == task.string("epic_id") && $0.string("kind") == "epic" }) { Text(ProductionGroups.label(epic)).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
            }.padding(.leading, 39).padding(.bottom, Spacing.small) // Align metadata with the title after its icon.
        }.padding(.leading, 19).triageMemberRule() // Indent members under the disclosure control.
    }
}

extension View {
    func triageMemberRule() -> some View {
        // Position the connector on the disclosure control centerline.
        overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 1).padding(.leading, 17) }
    }
}
