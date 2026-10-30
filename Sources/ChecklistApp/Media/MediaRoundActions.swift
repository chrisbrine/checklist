import SwiftUI

/// CL-300 owner screens for CL-118: rework Drafts from selected Changes-requested items,
/// round closure with its own blocking text, live rework status and explicit successor inclusion.
/// Every call goes through the native owner channel; nothing here assigns, readies or triages work.
struct MediaRoundActions: View {
    @EnvironmentObject var store: ChecklistStore
    @ObservedObject var model: MediaReviewModel
    @State private var successorTitle = ""
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            reworkStatus
            if model.reworkAvailable {
                reworkSection
                closureSection
            }
            if model.successorAvailable {successorSection}
        }
    }
    private var writeBlock: (Bool, String) {(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)}
    @ViewBuilder private var reworkStatus: some View {
        let rework=Record(values:model.header.object("rework"))
        if !rework.records("tickets").isEmpty {
            let counts=rework.object("ticket_counts")
            Text("Follow-up tickets · \(counts["open"] as? Int ?? 0) open · \(counts["closed"] as? Int ?? 0) closed · \(counts["unavailable"] as? Int ?? 0) unavailable").font(.caption)
            ForEach(Array(rework.records("tickets").enumerated()),id:\.offset) {_,ticket in
                Text(Self.reworkLinkLabel(ticket)).font(.caption2).textSelection(.enabled)
            }
        }
        ForEach(Array(rework.records("worker_reasons").enumerated()),id:\.offset) {_,reason in
            Text(Self.workerReasonLabel(reason)).font(.caption2).textSelection(.enabled)
        }
        if let counts=(model.header.values["closure"] as? MediaValues)?["counts"] as? [String:Int] {
            Text("Closed record · "+MediaReviewModel.countsText(counts)).font(.caption)
        }
    }
    static func reworkLinkLabel(_ link: Record) -> String {
        let status=link.string("task_status_category")=="unavailable" ? "Unavailable" : (link.bool("task_open") ? "Open" : "Closed")
        return link.string("task_key")+" "+link.string("task_title")+" · "+status+" · \(link.integer("decision_count")) decision(s)"
    }
    /// A worker reason keeps its worker attribution; it is never the owner's own reason.
    static func workerReasonLabel(_ reason: Record) -> String {
        "Worker follow-up · "+reason.string("source_label",fallback:"Recorded worker")+" · \(reason.integer("decision_count")) decision(s): "+reason.string("reason")
    }
    static func reworkPreviewLabel(_ row: Record) -> String {
        row.string("title")+" · "+(row.string("action")=="reuse" ? "Reuses its existing rework ticket" : "Creates a Draft ticket")
    }
    private var reworkSection: some View {
        DisclosureGroup("Create rework Drafts") {
            Text("Choose Changes-requested items. Each one creates one Draft ticket in the Epic you choose, or reuses the ticket already linked to the same decision. Nothing is assigned, made Ready or added to a Triage.").font(.caption)
            if model.reworkCandidates.isEmpty {
                Text("No Changes-requested items are listed. Set the filter to Changes requested to list them.").font(.caption).foregroundStyle(Color.checklistSecondaryText)
            }
            ForEach(model.reworkCandidates) {row in
                Toggle(row.string("title"),isOn:Binding(get:{model.reworkSelection.contains(row.id)},set:{_ in model.toggleRework(row)}))
                    .accessibilityLabel("Create rework for "+row.string("title"))
            }
            Picker("Epic",selection:$model.reworkEpicID) {
                Text("Choose Epic").tag("")
                ForEach(model.epics) {Text($0.string("name",fallback:$0.string("title"))).tag($0.id)}
            }.accessibilityLabel("Epic for rework tickets")
            .task(id:model.projectID) {await model.loadEpics()}
            Button("Preview rework") {Task {await model.previewRework()}}
                .checklistDisabled([(model.reworkSelection.isEmpty,"Select at least one Changes-requested item."),(model.reworkEpicID.isEmpty,"Choose an Epic.")])
            let rows=model.reworkPreview.records("items")
            if !rows.isEmpty {
                ForEach(Array(rows.enumerated()),id:\.offset) {_,row in Text(Self.reworkPreviewLabel(row)).font(.caption).textSelection(.enabled)}
                Button("Create or reuse \(rows.count) rework tickets") {model.createRework()}.checklistDisabled([writeBlock])
                TechnicalDetails(raw:[("Rework preview",model.reworkPreview.values)]).id(model.reworkPreview.string("preview_digest"))
            }
        }
    }
    private var closureSection: some View {
        let counts=model.closureCounts,blockers=MediaReviewModel.closureBlockers(counts),look=counts["needs_look"] ?? 0
        return VStack(alignment:.leading,spacing:4) {
            ForEach(Array(blockers.filter {$0.0}.enumerated()),id:\.offset) {_,blocker in Text(blocker.1).font(.caption).foregroundStyle(.orange)}
            if look>0 {Text("\(look) Needs look item(s) stay listed for the worker after you close this round.").font(.caption)}
            Button("Close round") {model.finishRound()}.checklistDisabled(blockers+[writeBlock])
        }
    }
    private var successorSection: some View {
        DisclosureGroup("Start successor round") {
            Text("Include items explicitly. A carried decision applies only when the new material has the identical complete review basis; a changed item starts Stale and an item without a carry starts Pending.").font(.caption)
            ForEach(model.rows) {row in
                HStack {
                    Toggle(row.string("title"),isOn:Binding(get:{model.successorItems[row.id] != nil},set:{model.includeInSuccessor(row,include:$0,carry:false)}))
                        .accessibilityLabel("Include "+row.string("title")+" in the successor round")
                    if MediaReviewModel.canCarry(row) {
                        Toggle("Carry "+MediaReviewModel.dispositionLabel(row.string("disposition")),isOn:Binding(get:{model.successorItems[row.id]?["carry_decision_id"] != nil},set:{model.includeInSuccessor(row,include:true,carry:$0)}))
                            .accessibilityLabel("Carry the current decision for "+row.string("title"))
                    }
                }
            }
            if model.next != nil {Text("More items are not loaded yet. Load more items to include them.").font(.caption)}
            TextField("Successor round title",text:$successorTitle)
            Button("Create successor round with \(model.successorItems.count) items") {model.createSuccessor(title:successorTitle) {successorTitle=""}}
                .checklistDisabled([(model.successorItems.isEmpty,"Include at least one item."),(successorTitle.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,"Enter a round title."),writeBlock])
        }
    }
}
