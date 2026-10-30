import SwiftUI
import ChecklistIPC

extension Confirmations {
    static func mediaBulkDecision(_ plan: MediaBulkPlan, perform: @escaping () -> Void) -> PendingConfirmation {
        PendingConfirmation(title: plan.title, effect: plan.effect, confirmLabel: plan.confirmLabel, keepLabel: "Keep items undecided", perform: perform)
    }
}

/// One group of the list: the exact metadata of its header.
struct MediaBulkGroup {
    let title: String
    let metadata: MediaValues
    /// A group with no value has no metadata equality; tick its items instead.
    init?(title: String,path: [MediaValues]) {
        var values: MediaValues = [:]
        for level in path {
            guard let id = level["field_id"] as? String,let value = level["value"],!(value is NSNull) else {return nil}
            values[id] = value
        }
        guard !values.isEmpty else {return nil}
        self.title = title;metadata = values
    }
}

/// Local selection and progress. The frozen operation in the service stays the durable record.
struct MediaBulkState {
    var selecting = false
    var ticks = Set<String>()
    var group: MediaBulkGroup?
    var wholeFilter = false
    var disposition = "accepted"
    var note = ""
    /// any, has, none or no_changes (no agent Changes-requested suggestion).
    var suggestionFilter = "any"
    var noteFilter = false
    var resolving = false
    var running = false
    var operation = Record(values: [:])
    var error: String?
    var hasSelection: Bool { !ticks.isEmpty || group != nil || wholeFilter }
    var selectionText: String {
        if wholeFilter {return "Every item in this filter"}
        if let group {return "Group "+group.title}
        return "\(ticks.count) ticked"
    }
    static let decisions: [(id: String,label: String)] = [("accepted","Accept"),("needs_look","Needs look"),("changes_requested","Changes requested"),("excluded","Exclude")]
    var requiresNote: Bool { MediaReviewModel.decisionRequiresNote(disposition) }
    var noteMissing: Bool { requiresNote && note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
}

/// The exact entries one confirmation sends. Nothing is sent for the items it leaves out.
struct MediaBulkPlan {
    let disposition: String
    let note: String
    var entries: [MediaValues] = []
    var alreadyDecided = 0, otherDecision = 0, unsentNote = 0, needsTake = 0, unpublished = 0, gone = 0, agentChanges = 0
    var observation: MediaValues = [:]
    /// A list with no disposition filter selects undecided work only, so one press
    /// never reverses an earlier owner decision that the owner did not ask to change.
    static func make(selection: Record,disposition: String,note: String,listFilter: String,ticked: Set<String>?,drafts: [String:MediaOwnerDraft]) -> MediaBulkPlan {
        var plan = MediaBulkPlan(disposition:disposition,note:note)
        plan.unpublished = selection.integer("unpublished",fallback:0)
        for key in ["round_id","expected_revision","observed_context_token","manifest_id","manifest_digest"] {plan.observation[key] = selection.values[key]}
        let rows = selection.records("entries")
        if let ticked {plan.gone = max(0,ticked.count-rows.count-plan.unpublished)}
        for row in rows {
            let current = row.string("disposition"),draft = drafts[row.string("item_id")]
            if current == disposition {plan.alreadyDecided += 1;continue}
            if ticked == nil,listFilter == "all",!["pending","stale"].contains(current) {plan.otherDecision += 1;continue}
            // A note still typed on this Mac would be lost in a common decision.
            if draft?.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false {plan.unsentNote += 1;continue}
            var entry: MediaValues = ["item_id":row.string("item_id"),"expected_revision":row.values["expected_revision"] ?? NSNull(),
                "target_id":row.string("target_id"),"review_basis_signature":row.string("review_basis_signature")]
            let candidates = row.strings("candidate_ids")
            if disposition == "accepted" {
                let chosen = draft?.winnerID ?? ""
                if candidates.count == 1 {entry["winner_id"] = candidates[0]}
                else if candidates.contains(chosen) {entry["winner_id"] = chosen}
                else {plan.needsTake += 1;continue}
            }
            if disposition == "changes_requested",candidates.count > 1 {entry["none_fit"] = true}
            if row.strings("agent_suggestions").contains("changes_requested"),disposition != "changes_requested" {plan.agentChanges += 1}
            plan.entries.append(entry)
        }
        return plan
    }
    var label: String { MediaBulkState.decisions.first {$0.id == disposition}?.label ?? MediaReviewModel.dispositionLabel(disposition) }
    var chunkCount: Int { (entries.count+199)/200 }
    var title: String { "\(label) \(entries.count) items?" }
    var confirmLabel: String { "\(label) \(entries.count) items" }
    var leftOut: [String] {
        var text: [String] = []
        if alreadyDecided > 0 {text.append("\(alreadyDecided) already have this decision")}
        if otherDecision > 0 {text.append("\(otherDecision) already have another decision; filter by that decision to change them")}
        if unsentNote > 0 {text.append("\(unsentNote) have a typed note that was not sent; decide them one at a time")}
        if needsTake > 0 {text.append("\(needsTake) have several takes and no chosen take")}
        if unpublished > 0 {text.append("\(unpublished) are not published")}
        if gone > 0 {text.append("\(gone) ticked items are no longer in this round")}
        return text
    }
    var effect: String {
        var text = "Checklist records one owner decision for each of these \(entries.count) items, in \(chunkCount) \(chunkCount == 1 ? "part" : "parts"). Each decision stays in the item's history, and you can change it later."
        if agentChanges > 0 {text += " \(agentChanges) of these items have an agent suggestion of Changes requested."}
        if !leftOut.isEmpty {text += " Left out: "+leftOut.joined(separator:"; ")+"."}
        return text
    }
    var emptyText: String {
        leftOut.isEmpty ? "No item matches this selection." : "No item can take this decision. "+leftOut.joined(separator:"; ")+"."
    }
    func prepareParams() -> MediaValues {
        var p = observation
        p["items"] = entries;p["disposition"] = disposition
        let trimmed = note.trimmingCharacters(in:.whitespacesAndNewlines)
        if !trimmed.isEmpty {p["note"] = trimmed}
        return p
    }
}

extension MediaReviewModel {
    var bulkAvailable: Bool { !historyOnly && header.id == roundID && header.string("state") == "open" && header.records("attention").isEmpty }
    /// The new filters and the disposition filter, as the service list reads them.
    static func listFilter(disposition: String,suggestion: String,note: Bool,localNotes: [String]) -> MediaValues {
        var value: MediaValues = [:]
        if disposition != "all" {value["dispositions"] = [disposition]}
        switch suggestion {
        case "has": value["has_agent_suggestion"] = true
        case "none": value["has_agent_suggestion"] = false
        case "no_changes": value["agent_suggestion_excludes"] = ["changes_requested"]
        default: break
        }
        if note {value["has_note"] = true;if !localNotes.isEmpty {value["note_item_ids"] = localNotes}}
        return value
    }
    var currentListFilter: MediaValues {
        Self.listFilter(disposition:filter,suggestion:bulk.suggestionFilter,note:bulk.noteFilter,localNotes:bulk.noteFilter ? Array(localDrafts().filter {!$0.value.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}.keys).sorted() : [])
    }
    /// Notes and chosen takes that are still local to this window (autosaved per item).
    func localDrafts() -> [String:MediaOwnerDraft] {
        guard let store,!projectID.isEmpty else {return [:]}
        let prefix = "mediaDraft:"+projectID+":"
        var drafts: [String:MediaOwnerDraft] = [:]
        for (key,value) in store.windowPreferences.dictionaryRepresentation() where key.hasPrefix(prefix) {
            if let data = value as? Data,let draft = try? JSONDecoder().decode(MediaOwnerDraft.self,from:data) {drafts[String(key.dropFirst(prefix.count))] = draft}
        }
        if selectedID != "" {drafts[selectedID] = draft}
        return drafts
    }
    func showUndecidedWithoutAgentChanges() {
        filter = "pending";bulk.suggestionFilter = "no_changes";bulk.selecting = true
        bulk.ticks = [];bulk.group = nil;bulk.wholeFilter = true
        Task {await reloadRows()}
    }
    func toggleBulkTick(_ id: String) {
        bulk.group = nil;bulk.wholeFilter = false
        if bulk.ticks.contains(id) {bulk.ticks.remove(id)} else {bulk.ticks.insert(id)}
    }
    func selectBulkGroup(_ group: MediaBulkGroup) { bulk.ticks = [];bulk.wholeFilter = false;bulk.group = group }
    func selectWholeFilter() { bulk.ticks = [];bulk.group = nil;bulk.wholeFilter = true }
    func clearBulkSelection() { bulk.ticks = [];bulk.group = nil;bulk.wholeFilter = false }

    /// Reads the exact selection first, so the confirmation names what the press will send.
    func bulkConfirmation() async -> PendingConfirmation? {
        guard bulkAvailable,!bulk.running,!bulk.resolving,bulk.hasSelection,!bulk.noteMissing else {return nil}
        let round = roundID,project = projectID,choice = bulk.disposition,note = bulk.requiresNote ? bulk.note : "",ticked = bulk.ticks,listChoice = filter,group = bulk.group
        bulk.resolving = true;bulk.error = nil
        defer {bulk.resolving = false}
        var p: MediaValues = ["round_id":round,"list":list]
        if ticked.isEmpty {
            var selection = currentListFilter
            if let group {
                var metadata = selection["metadata"] as? MediaValues ?? [:]
                for (key,value) in group.metadata {metadata[key] = value}
                selection["metadata"] = metadata
            }
            if !selection.isEmpty {p["filter"] = selection}
        } else {p["item_ids"] = ticked.sorted()}
        do {
            let reply = try await read("media_bulk_selection",p)
            guard roundID == round,projectID == project else {return nil}
            let plan = MediaBulkPlan.make(selection:Record(values:reply),disposition:choice,note:note,listFilter:listChoice,ticked:ticked.isEmpty ? nil : ticked,drafts:localDrafts())
            guard !plan.entries.isEmpty else {bulk.error = plan.emptyText;return nil}
            return Confirmations.mediaBulkDecision(plan) { [weak self] in
                Task {await self?.runBulk(plan)}
            }
        } catch {bulk.error = PlainError.text(error);return nil}
    }
    /// Freezes the selection in one operation, then sends each chunk with its own stored
    /// command ID. The operation is the recovery record, so a reply lost here is read back
    /// with `media_bulk_get`, and the app cannot apply a chunk twice.
    func runBulk(_ plan: MediaBulkPlan) async {
        guard !bulk.running else {return}
        if let reason = store?.writeBlockReason {bulk.error = reason;return}
        bulk.running = true;bulk.error = nil
        var p = plan.prepareParams();p["command_id"] = UUID().uuidString
        await prepareAndApply(p)
    }
    /// Only the failed or unsent chunks of the frozen operation, on the current observation.
    /// Their takes and the common action stay those of the original confirmation.
    func retryFailedBulk() async {
        guard !bulk.running,!bulk.operation.id.isEmpty else {return}
        if let reason = store?.writeBlockReason {bulk.error = reason;return}
        let prior = bulk.operation,round = roundID
        let unresolved = prior.strings("failed_item_ids")+prior.strings("uncommitted_item_ids")
        guard !unresolved.isEmpty else {return}
        bulk.running = true;bulk.error = nil
        do {
            let reply = Record(values:try await read("media_bulk_selection",["round_id":round,"list":list,"item_ids":unresolved]))
            guard roundID == round else {bulk.running = false;return}
            let original = Dictionary(prior.records("selection").map {($0.string("item_id"),$0)},uniquingKeysWith:{first,_ in first})
            // A decision after the selection is the owner's later word: a retry never replaces it.
            // The service refreshes complete chunks only, so a retry that leaves an item out
            // is a new operation. Retry appears only with no unsent chunk, so the old one can do nothing more.
            let later = reply.records("entries").filter {Self.bulkDecidedLater($0,original:original[$0.string("item_id")])}
            let remaining = reply.records("entries").filter {row in !later.contains {$0.string("item_id") == row.string("item_id")}}
            let notice = later.isEmpty ? nil : "\(later.count) items stay out of this retry because they have a newer decision."
            guard !remaining.isEmpty else {
                bulk.running = false;dismissBulkResult();bulk.error = notice;await refresh();return
            }
            let entries = remaining.map { row -> MediaValues in
                var entry: MediaValues = ["item_id":row.string("item_id"),"expected_revision":row.values["expected_revision"] ?? NSNull(),"target_id":row.string("target_id"),"review_basis_signature":row.string("review_basis_signature")]
                for key in ["winner_id","none_fit"] {if let value = original[row.string("item_id")]?.values[key] {entry[key] = value}}
                return entry
            }
            var p = prior.object("action")
            for key in ["round_id","expected_revision","observed_context_token","manifest_id","manifest_digest"] {p[key] = reply.values[key]}
            p["items"] = entries;p["command_id"] = UUID().uuidString
            if later.isEmpty {p["supersedes_operation_id"] = prior.id}
            bulk.error = notice
            await prepareAndApply(p)
        } catch {bulk.running = false;bulk.error = PlainError.text(error)}
    }
    private func prepareAndApply(_ params: MediaValues) async {
        let round = roundID
        do {
            let operation = Record(values:try await read("media_bulk_prepare",params))
            rememberBulk(operation.id,round:round)
            bulk.operation = operation
            await applyUnsentChunks(round:round)
        } catch {bulk.running = false;bulk.error = PlainError.text(error);await refresh()}
    }
    /// Resumes an operation whose chunks were not all sent. Never makes a new selection.
    func continueBulk() async {
        guard !bulk.running,!bulk.operation.id.isEmpty else {return}
        if let reason = store?.writeBlockReason {bulk.error = reason;return}
        bulk.running = true;bulk.error = nil
        await applyUnsentChunks(round:roundID)
    }
    private func applyUnsentChunks(round: String) async {
        let id = bulk.operation.id,project = projectID
        defer {bulk.running = false}
        do {
            bulk.operation = Record(values:try await read("media_bulk_get",["operation_id":id]))
            for chunk in bulk.operation.records("chunk_results") where chunk.string("state") == "uncommitted" {
                guard projectID == project,roundID == round else {return}
                do {
                    _ = try await read("media_bulk_apply",["operation_id":id,"chunk_id":chunk.id,"command_id":chunk.string("command_id")])
                } catch {
                    // The outcome may be unknown: read the receipts before saying anything.
                    bulk.error = PlainError.text(error)
                    bulk.operation = Record(values:try await read("media_bulk_get",["operation_id":id]))
                    await refresh()
                    return
                }
                bulk.operation = Record(values:try await read("media_bulk_get",["operation_id":id]))
            }
            if Self.bulkFinished(bulk.operation) {clearBulkSelection()}
        } catch {bulk.error = PlainError.text(error)}
        await refresh()
    }
    /// A decision moves the item's revision. An unchanged revision means a decision the selection already saw.
    static func bulkDecidedLater(_ row: Record,original: Record?) -> Bool {
        guard let original,!["pending","stale"].contains(row.string("disposition")) else {return false}
        return row.integer("expected_revision") != original.integer("expected_revision")
    }
    static func bulkFinished(_ operation: Record) -> Bool {
        operation.strings("failed_item_ids").isEmpty && operation.strings("uncommitted_item_ids").isEmpty
    }
    private func bulkKey(_ round: String) -> String { "mediaBulkOperation:"+projectID+":"+round }
    private func rememberBulk(_ id: String,round: String) {
        if id.isEmpty {store?.windowPreferences.removeObject(forKey:bulkKey(round))}
        else {store?.windowPreferences.set(id,forKey:bulkKey(round))}
    }
    /// After a restart or a round change, an unfinished operation shows again with its receipts.
    func resumeBulkIfNeeded(round: String) async {
        guard !bulk.running,bulk.operation.id.isEmpty,let id = store?.windowPreferences.string(forKey:bulkKey(round)) else {return}
        guard let reply = try? await read("media_bulk_get",["operation_id":id]),roundID == round else {return}
        let operation = Record(values:reply)
        if Self.bulkFinished(operation) {rememberBulk("",round:round)} else {bulk.operation = operation}
    }
    func dismissBulkResult() { rememberBulk("",round:roundID);bulk.operation = Record(values:[:]);bulk.error = nil }
    /// One owner press. Adoption copies the agent's exact choice into a new owner decision.
    func adoptSuggestion(_ suggestionID: String) {
        guard decisionEnabled else {return}
        var p = observation()
        p["observed_context_token"] = draft.contextToken
        p["manifest_id"] = draft.manifestID;p["manifest_digest"] = draft.manifestDigest
        p["items"] = [["item_id":selectedID,"expected_revision":item.integer("revision"),"target_id":draft.targetID,"review_basis_signature":draft.basis]]
        p["suggestion_id"] = suggestionID
        mutate("media_adopt_suggestion",p)
    }
    static func bulkFailureReason(_ code: String) -> String {
        switch code {
        case "REVISION_CONFLICT": return "an item changed after you selected it"
        case "MEDIA_BASIS_CHANGED": return "an item's material changed after you selected it"
        case "MEDIA_CONTEXT_CHANGED","MEDIA_CONTEXT_ATTENTION": return "the approved review context changed"
        case "MEDIA_MANIFEST_CHANGED": return "the published round changed"
        case "MEDIA_UNRESOLVED": return "required material is missing"
        default: return code
        }
    }
    /// One line for each chunk with a failed receipt; these lists come from the receipts.
    static func bulkFailures(_ operation: Record) -> [String] {
        let chunks = operation.records("chunk_results")
        return chunks.enumerated().compactMap { index,chunk in
            guard chunk.string("state") == "failed" else {return nil}
            let receipt = Record(values:chunk.object("receipt"))
            let code = (receipt.object("error")["code"] as? String) ?? ""
            return "Part \(index+1) of \(chunks.count): \(chunk.records("items").count) items not decided because "+bulkFailureReason(code)+"."
        }
    }
}

/// CL-318/CL-349: selection mode, one confirmed bulk decision, per-part progress and failed-only retry.
struct MediaBulkBar: View {
    @EnvironmentObject var store: ChecklistStore
    @ObservedObject var model: MediaReviewModel
    @Binding var confirmation: PendingConfirmation?
    private var writeBlock: (Bool,String) {(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)}
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            Picker("Agent suggestion",selection:Binding(get:{model.bulk.suggestionFilter},set:{model.bulk.suggestionFilter=$0;Task {await model.reloadRows()}})) {
                Text("Any").tag("any")
                Text("Has agent suggestion").tag("has")
                Text("No agent suggestion").tag("none")
                Text("No Changes-requested suggestion").tag("no_changes")
            }.accessibilityLabel("Agent suggestion filter")
            Toggle("Has note",isOn:Binding(get:{model.bulk.noteFilter},set:{model.bulk.noteFilter=$0;Task {await model.reloadRows()}}))
                .accessibilityLabel("Show only items with a note")
            if model.bulkAvailable {
                Toggle("Select items",isOn:Binding(get:{model.bulk.selecting},set:{model.bulk.selecting=$0;if !$0 {model.clearBulkSelection()}}))
                    .accessibilityIdentifier("mediaBulkSelect")
                if model.bulk.selecting {selectionControls}
            }
            progress
        }.font(.caption)
    }
    @ViewBuilder private var selectionControls: some View {
        Button("Pending with no Changes-requested suggestion") {model.showUndecidedWithoutAgentChanges()}
        HStack {
            Button("Select this filter") {model.selectWholeFilter()}
            Button("Clear") {model.clearBulkSelection()}.checklistDisabled([(!model.bulk.hasSelection,"Nothing is selected.")])
        }
        if model.bulk.hasSelection {Text(model.bulk.selectionText).accessibilityLabel("Selection: "+model.bulk.selectionText)}
        Picker("Decision",selection:$model.bulk.disposition) {ForEach(MediaBulkState.decisions,id:\.id) {Text($0.label).tag($0.id)}}
            .accessibilityLabel("Decision for the selected items")
        if model.bulk.requiresNote {TextField("Note for every selected item",text:$model.bulk.note).accessibilityLabel("Note for every selected item")}
        Button((MediaBulkState.decisions.first {$0.id == model.bulk.disposition}?.label ?? "Decide")+" selected…") {
            Task {if let pending = await model.bulkConfirmation() {confirmation = pending}}
        }.accessibilityIdentifier("mediaBulkDecide")
        .checklistDisabled([(!model.bulk.hasSelection,"Select items, a group or this filter."),(model.bulk.noteMissing,"Enter a note for this decision."),(model.bulk.resolving,"Reading the selected items."),(model.bulk.running,"A bulk decision is running."),writeBlock])
    }
    @ViewBuilder private var progress: some View {
        let operation = model.bulk.operation
        if let error = model.bulk.error {Text(error).foregroundStyle(.orange).textSelection(.enabled)}
        if !operation.id.isEmpty {
            let chunks = operation.records("chunk_results")
            let done = chunks.filter {$0.string("state") != "uncommitted"}.count
            let committed = operation.strings("committed_item_ids").count,total = operation.strings("selected_item_ids").count
            ProgressView(value:Double(done),total:Double(max(chunks.count,1))) {
                Text("Part \(done) of \(chunks.count) · \(committed) of \(total) decided")
            }.accessibilityLabel("Bulk decision progress: part \(done) of \(chunks.count), \(committed) of \(total) items decided")
            ForEach(MediaReviewModel.bulkFailures(operation),id:\.self) {Text($0).foregroundStyle(.orange).textSelection(.enabled)}
            if !model.bulk.running {
                let failed = operation.strings("failed_item_ids").count,unsent = operation.strings("uncommitted_item_ids").count
                HStack {
                    if unsent > 0 {
                        Button("Continue \(unsent) unsent items") {Task {await model.continueBulk()}}.checklistDisabled([writeBlock])
                    } else if failed > 0 {
                        Button("Retry \(failed) failed items") {Task {await model.retryFailedBulk()}}.checklistDisabled([writeBlock])
                    }
                    Button("Dismiss") {model.dismissBulkResult()}
                }
            }
            TechnicalDetails(raw:[("Bulk operation",operation.values)]).id(operation.id)
        }
    }
}
