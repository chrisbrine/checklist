import Foundation
import SwiftUI
import ChecklistIPC
import ChecklistCore

typealias MediaValues = [String: Any]

/// Resumes an awaited owner mutation once: when it is committed or when it is refused.
@MainActor final class MediaResumeOnce {
    private var continuation: CheckedContinuation<Void,Error>?
    init(_ continuation: CheckedContinuation<Void,Error>) {self.continuation=continuation}
    func resume(_ result: Result<Void,Error>) {continuation?.resume(with:result);continuation=nil}
}
/// Holds a committed reply on the main actor; the reply dictionary is not Sendable (CL-427).
@MainActor final class MediaReplyBox {var value: MediaValues=[:]}

/// Display state is local and nonmaterial. Every decision carries the service's
/// observed manifest/basis; refresh never retargets an unsent owner's draft.
@MainActor final class MediaReviewModel: ObservableObject {
    @Published var types: [Record] = []
    @Published var rounds: [Record] = []
    @Published var typeID = ""
    @Published var roundID = ""
    @Published var roundState = "draft"
    @Published var historyOnly = false
    @Published var header = Record(values: [:])
    @Published var rows: [Record] = []
    @Published var selectedID = ""
    @Published var item = Record(values: [:])
    @Published var filter = "all"
    @Published var list: MediaValues = [:]
    @Published var mapsAnimationNames = false
    @Published var roundOffset = 0
    @Published var roundsHaveMore = false
    @Published private(set) var imageLoads = 0
    @Published private(set) var currentImageReference = ""
    @Published private(set) var historicalImageReference = ""
    @Published var examplesShown = false
    @Published var examples: [Record] = []
    @Published var examplesNext: String?
    @Published var next: String?
    @Published var counts: [String: Int] = [:]
    @Published var intake = Record(values: [:])
    /// CL-307: one Capture press is running its chunk sequence.
    @Published var capturing = false
    @Published private(set) var publishingPrepared = false
    private var publicationObservation: MediaValues = [:]
    @Published var publication: [Record] = []
    /// CL-426: the intake publication's one plain failure line, and its press in progress.
    @Published var publicationFailure: String?
    @Published private(set) var publishingShown = false
    @Published var error: String?
    @Published var loading = false
    @Published var draft = MediaOwnerDraft() { didSet { saveDraft() } }
    @Published var contextConflict = false
    /// CL-300 owner rework, closure and successor screens. Selections are explicit and local;
    /// a changed selection or Epic drops the preview so create never sends a different preview.
    @Published var reworkSelection = Set<String>() { didSet { if reworkSelection != oldValue { reworkPreview = Record(values: [:]) } } }
    @Published var reworkEpicID = "" { didSet { if reworkEpicID != oldValue { reworkPreview = Record(values: [:]) } } }
    @Published var reworkPreview = Record(values: [:])
    @Published var epics: [Record] = []
    @Published var successorItems: [String: MediaValues] = [:]
    /// CL-318/CL-349 selection, list filters and bulk progress (MediaBulkActions.swift).
    @Published var bulk = MediaBulkState()
    /// CL-427: the round's result send (progress, receipt or one refusal line), the ticket
    /// choices for the round's ticket picker and the last ticket change refusal. All are local.
    @Published var resultSend = MediaResultSend()
    @Published var ticketChoices: [Record] = []
    @Published var ticketChoicesLoading = false
    @Published var ticketLinkLine = ""
    /// Audio/video takes: two verified copies, one preparation and one playing take at most.
    let playback = MediaPlaybackCoordinator()
    private(set) var projectID = ""
    private(set) weak var store: ChecklistStore?
    private var epoch = UUID()
    private var selectionEpoch = UUID()
    private var roundChoiceEpoch = UUID()
    private var drafts: [String: MediaOwnerDraft] = [:]
    private var currentImageReferences = Set<String>()
    private var draftScope = ""
    private var listScope = ""
    var enabledTypes: [Record] { types.filter { $0.bool("enabled") } }
    var hasMedia: Bool { !enabledTypes.isEmpty }
    var selectedOutsideFilter: Bool { !selectedID.isEmpty && !rows.contains { $0.id == selectedID } }
    var writable: Bool { !historyOnly && ["draft", "open"].contains(header.string("state")) }
    var preparedPublicationAvailable: Bool { !historyOnly && header.id == roundID && header.string("state") == "draft" && header.string("origin") == "agent" }
    var schema: MediaValues { header.object("type_revision")["schema"] as? MediaValues ?? [:] }
    var fields: [Record] { (schema["fields"] as? [MediaValues] ?? []).map(Record.init) }
    var slots: [Record] { (schema["slots"] as? [MediaValues] ?? []).map(Record.init) }
    /// The declared layout's reference role; every other compatible slot is a candidate take.
    var referenceSlotID: String { (schema["layout"] as? MediaValues)?["reference_slot_id"] as? String ?? "" }
    var decisionEnabled: Bool { !historyOnly && item.bool("published") && header.string("state") == "open" && !contextConflict && header.records("attention").isEmpty && !item.object("target").isEmpty }
    var hasDecisionNote: Bool { !draft.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }

    func connect(store: ChecklistStore) async {
        self.store = store
        let project = store.projectID ?? ""
        if project != projectID {
            saveDraft(); playback.releaseAll(); projectID = project; epoch = UUID(); selectionEpoch = UUID(); roundChoiceEpoch = UUID()
            clearImages();listScope="";list=[:];roundOffset=0
            types=[];rounds=[];rows=[];typeID="";roundID="";selectedID="";header=Record(values:[:]);item=Record(values:[:]);intake=Record(values:[:]);publication=[];examples=[]
            draftScope="";draft = MediaOwnerDraft(); contextConflict=false; clearRoundActions(); epics=[]
        }
        await refresh()
    }
    func read(_ method: String,_ params: MediaValues = [:],projectID explicitProjectID: String? = nil) async throws -> MediaValues {
        let project=explicitProjectID ?? projectID
        guard let store, !project.isEmpty else {throw ChecklistError("PROJECT_REQUIRED", "Select a project.")}
        var params=params;params["project_id"]=project
        return try await store.request(method,params)
    }
    func mutate(_ method: String,_ params: MediaValues,then: @escaping (MediaValues) throws -> Void = {_ in}) {
        mutateReportingFailure(method,params,onFailure:nil,then:then)
    }
    /// `quiet`: the caller shows a refusal itself, so neither `error` (the orange line) nor the
    /// store's global alert shows it (CL-422 rework). An unknown outcome still shows in the store.
    func mutateReportingFailure(_ method: String,_ params: MediaValues,quiet: Bool = false,onFailure: ((Error) -> Void)?,then: @escaping (MediaValues) throws -> Void) {
        guard let store else {return}
        var params=params;params["project_id"]=projectID
        let project = projectID
        store.run(method,params,failure:{ [weak self] error in
            onFailure?(error)
            guard let self,self.projectID == project else {return}
            self.capturing=false
            if !quiet {self.error=PlainError.text(error)}
            if ["MEDIA_CONTEXT_CHANGED","MEDIA_CONTEXT_ATTENTION","MEDIA_BASIS_CHANGED","REVISION_CONFLICT"].contains((error as? ChecklistError)?.code ?? "") {self.contextConflict=true}
        },alertsOnRefusal:!quiet) { [weak self] result in
            guard let self,self.projectID == project else {
                // The command was committed, but its project is no longer shown: no follow-up step runs.
                onFailure?(ChecklistError("MEDIA_PROJECT_CHANGED","The project changed. Checklist saved the change but did not continue."));return
            }
            do {
                try then(result)
                Task {await self.refresh()}
            } catch {
                self.error = PlainError.text(error)
            }
        }
    }
    // Capture the displayed object/revision/reason before the native dialog opens.
    // Live refresh must not retarget a later confirmation to a different object.
    func retireTypeConfirmation(_ type: Record) -> PendingConfirmation {
        let project = projectID
        return Confirmations.retireMediaType(type.string("title")) { [weak self] in
            guard let self, self.projectID == project else { return }
            self.mutate("media_type_retire", ["type_id":type.id,"expected_revision":type.integer("revision")])
        }
    }
    func cancelRoundConfirmation(reason: String) -> PendingConfirmation {
        let project = projectID, round = header, id = roundID
        return Confirmations.cancelMediaRound(round.string("title")) { [weak self] in
            guard let self, self.projectID == project else { return }
            self.mutate("media_round_cancel", ["round_id":id,"expected_revision":round.integer("revision"),"reason":reason])
        }
    }
    func archiveRoundConfirmation() -> PendingConfirmation {
        let project = projectID, round = header, id = roundID
        return Confirmations.archiveMediaRound(round.string("title")) { [weak self] in
            guard let self, self.projectID == project else { return }
            self.mutate("media_round_archive", ["round_id":id,"expected_revision":round.integer("revision")])
        }
    }
    /// CL-421: a live change refreshes quietly and in place. A refresh shows its loading
    /// line only for data that was never loaded; unchanged values are never reassigned,
    /// so an unchanged refresh publishes nothing and redraws nothing.
    func refresh() async {
        guard !projectID.isEmpty else {return}
        let token=UUID();epoch=token
        if types.isEmpty || (!roundID.isEmpty && header.id != roundID) {loading=true}
        defer {if epoch==token,loading {loading=false}}
        do {
            let nav=try await read("media_navigation")
            guard epoch==token else {return}
            Self.assignIfChanged(&types,(nav["types"] as? [MediaValues] ?? []).map(Record.init))
            if !historyOnly && !enabledTypes.contains(where:{$0.id == typeID}) {typeID=enabledTypes.first?.id ?? ""}
            if !hasMedia && !historyOnly {if store?.page == .media {store?.page = .tasks};return}
            if !typeID.isEmpty {
                let result=try await read("media_round_page",["type_id":typeID,"state":roundState,"offset":roundOffset])
                guard epoch==token else {return}
                let more=result["has_more"] as? Bool ?? false
                if roundsHaveMore != more {roundsHaveMore=more}
                Self.assignIfChanged(&rounds,(result["rows"] as? [MediaValues] ?? []).map(Record.init))
            }
            if !roundID.isEmpty {try await loadRound(token:token)}
            if error != nil {error=nil}
        } catch {if epoch==token {self.error=PlainError.text(error)}}
    }
    /// A live service change (any project event) asks for one quiet refresh. Changes that
    /// arrive while a refresh runs coalesce into one more refresh, never a queue of reads.
    func liveRefresh() async {
        guard !liveRefreshRunning else {liveRefreshPending=true;return}
        liveRefreshRunning=true
        defer {liveRefreshRunning=false}
        repeat {liveRefreshPending=false;await refresh()} while liveRefreshPending && !Task.isCancelled
    }
    private var liveRefreshRunning=false
    private var liveRefreshPending=false
    nonisolated static func sameRecord(_ a: Record,_ b: Record) -> Bool { NSDictionary(dictionary:a.values).isEqual(to:b.values) }
    nonisolated static func sameRecords(_ a: [Record],_ b: [Record]) -> Bool { a.count==b.count && zip(a,b).allSatisfy {sameRecord($0,$1)} }
    /// Assign only a changed list, so SwiftUI keeps every row, player and scroll anchor.
    @discardableResult static func assignIfChanged(_ target: inout [Record],_ value: [Record]) -> Bool {
        guard !sameRecords(target,value) else {return false}
        target=value;return true
    }
    func createRound(title: String, then: @escaping () -> Void = {}) {
        mutate("media_round_create", ["type_id":typeID,"title":title]) { [weak self] result in
            guard let self else { return }
            let reply = try TypedReplyRecord(result)
            then()
            self.roundState = "draft"
            self.roundOffset = 0
            self.chooseRound(reply.id)
        }
    }
    func createItem(title: String, then: @escaping () -> Void = {}) {
        mutate("media_item_create", ["round_id": roundID, "title": title]) { [weak self] result in
            let reply = try TypedReplyRecord(result)
            then()
            Task { await self?.select(reply.id) }
        }
    }
    func chooseType(_ id: String) {saveDraft();roundChoiceEpoch=UUID();clearImages();roundOffset=0;typeID=id;list=[:];roundID="";selectedID="";rows=[];header=Record(values:[:]);item=Record(values:[:]);intake=Record(values:[:]);publication=[];Task {await refresh()}}
    func chooseRound(_ id: String) {saveDraft();roundChoiceEpoch=UUID();clearImages();clearRoundActions();roundID=id;selectedID="";rows=[];item=Record(values:[:]);publication=[];intake=Record(values:[:]);contextConflict=false;Task {await refresh()}}
    private func loadRound(token: UUID) async throws {
        let id=roundID
        let result=try await read("media_round_header",["round_id":id])
        guard epoch==token,roundID==id else {return}
        let nextHeader=Record(values:result)
        if !Self.sameRecord(header,nextHeader) {header=nextHeader}
        let scope=projectID+":"+typeID
        if listScope != scope {listScope=scope;list=(store?.windowPreferences.dictionary(forKey:"mediaList:"+scope)) ?? Self.defaultList(schema)}
        if list.isEmpty {list=Self.defaultList(schema)}
        let total=try await read("media_item_counts",["round_id":roundID,"list":list])
        guard epoch==token else {return}
        let totals=total["counts"] as? [String:Int] ?? [:]
        if counts != totals {counts=totals}
        let retainedCount=rows.count
        let retainedSelection=rows.contains {$0.id==selectedID}
        // Refresh only the pages already inspected; keep their selection/scroll anchor.
        try await loadRows(append:false,token:token,keepCount:retainedCount,keepID:retainedSelection ? selectedID : "")
        if !selectedID.isEmpty {await select(selectedID)}
        await resumeBulkIfNeeded(round:id)
    }
    func reloadRows() async {store?.windowPreferences.set(list,forKey:"mediaList:"+listScope);let token=UUID();epoch=token;do {try await loadRows(append:false,token:token)} catch {self.error=PlainError.text(error)}}
    func moreRows() async {do {try await loadRows(append:true,token:epoch)} catch {self.error=PlainError.text(error)}}
    /// CL-421: every page a refresh needs is read first and the list is assigned once, only
    /// when it changed. The list never shrinks to one page and grows again (no scroll jump).
    private func loadRows(append: Bool,token: UUID,keepCount: Int = 0,keepID: String = "") async throws {
        guard !roundID.isEmpty,!append || next != nil else {return}
        let selection=currentListFilter
        func page(_ cursor: String?) async throws -> MediaValues {
            var params: MediaValues=["round_id":roundID,"list":list,"limit":100]
            if !selection.isEmpty {params["filter"]=selection}
            if let cursor {params["cursor"]=cursor}
            return try await read("media_item_page",params)
        }
        var result=try await page(append ? next : nil)
        guard epoch==token else {return}
        var collected=append ? rows : [],seen=Set(collected.map(\.id))
        func add(_ result: MediaValues) {
            for row in (result["rows"] as? [MediaValues] ?? []).map(Record.init) where seen.insert(row.id).inserted {collected.append(row)}
        }
        add(result)
        while !append,result["next_cursor"] as? String != nil,collected.count<keepCount || (!keepID.isEmpty && !seen.contains(keepID)) {
            result=try await page(result["next_cursor"] as? String)
            guard epoch==token else {return}
            add(result)
        }
        Self.assignIfChanged(&rows,collected)
        if selection.isEmpty {let totals=result["counts"] as? [String:Int] ?? [:];if counts != totals {counts=totals}}
        let cursor=result["next_cursor"] as? String
        if next != cursor {next=cursor}
    }
    func select(_ id: String) async {
        saveDraft();if selectedID != id {playback.releaseAll();clearImages();item=Record(values:[:]);contextConflict=false};selectedID=id
        let scope=projectID+":"+id
        if draftScope != scope {
            draftScope=scope
            let saved=store?.windowPreferences.data(forKey:"mediaDraft:"+scope)
            draft=drafts[scope] ?? saved.flatMap {try? JSONDecoder().decode(MediaOwnerDraft.self,from:$0)} ?? MediaOwnerDraft()
        }
        let token=UUID();selectionEpoch=token
        do {
            let result=try await read("media_item_get",["round_id":roundID,"item_id":id])
            guard selectionEpoch==token,selectedID==id else {return}
            let priorTarget=item.object("target")["id"] as? String ?? ""
            let nextTarget=(result["target"] as? MediaValues)?["id"] as? String ?? ""
            if !priorTarget.isEmpty,priorTarget != nextTarget {playback.releaseAll();clearImages()}
            let nextItem=Record(values:result)
            if !Self.sameRecord(item,nextItem) {item=nextItem}
            // A refresh may reveal new content; never silently rebase an existing draft.
            let basis=item.object("target")["review_basis_signature"] as? String ?? ""
            if draft.basis.isEmpty {draft.basis=basis;draft.targetID=item.object("target")["id"] as? String ?? "";draft.contextToken=header.string("observed_context_token");draft.manifestID=Record(values:header.object("manifest")).id;draft.manifestDigest=Record(values:header.object("manifest")).string("digest")}
            else if draft.contextToken != header.string("observed_context_token") || draft.basis != basis || draft.targetID != item.object("target")["id"] as? String {contextConflict=true}
            if examplesShown {await showExamples(true)}
        } catch {if selectionEpoch==token {self.error=PlainError.text(error)}}
    }
    func moveSelection(_ delta: Int) async {
        guard !rows.isEmpty else {return}
        let index=rows.firstIndex {$0.id==selectedID} ?? (delta > 0 ? -1 : rows.count)
        await select(rows[min(rows.count-1,max(0,index+delta))].id)
    }
    func reviewRefreshedContext() {
        draft.basis=item.object("target")["review_basis_signature"] as? String ?? ""
        draft.targetID=item.object("target")["id"] as? String ?? ""
        draft.contextToken=header.string("observed_context_token");draft.manifestID=Record(values:header.object("manifest")).id;draft.manifestDigest=Record(values:header.object("manifest")).string("digest")
        contextConflict=false // note and winner remain visible; service validates the exact winner.
    }
    func showExamples(_ show: Bool,more: Bool=false) async {
        examplesShown=show
        guard show,!selectedID.isEmpty else {playback.releaseAll(prefix:"example:");historicalImageReference="";examples=[];examplesNext=nil;return}
        let selected=selectedID,round=roundID
        do {
            let match=(list["group_by"] as? [String] ?? []) + ((list["visible_columns"] as? [String] ?? []).contains("direction") ? ["direction"] : [])
            var p: MediaValues=["round_id":round,"item_id":selected,"expanded":true,"examples":["enabled":true,"match_fields":Array(match.prefix(3)),"page_size":4]]
            if more {p["cursor"]=examplesNext}
            let result=try await read("media_approved_examples",p)
            guard examplesShown,selectedID==selected,roundID==round else {return}
            let values=(result["examples"] as? [MediaValues] ?? []).map {raw -> Record in var raw=raw;raw["id"]=raw["target_id"];return Record(values:raw)}
            if more {historicalImageReference=""}
            Self.assignIfChanged(&examples,values)
            let cursor=result["next_cursor"] as? String
            if examplesNext != cursor {examplesNext=cursor}
        } catch {self.error=PlainError.text(error)}
    }
    func beginImage(_ key:String,historical:Bool) -> Bool {
        guard imageLoads<2,historical || currentImageReferences.contains(key) || currentImageReferences.count<8 else {return false}
        imageLoads+=1
        if historical {historicalImageReference=key} else {currentImageReferences.insert(key);currentImageReference=key}
        return true
    }
    func endImage() {imageLoads=max(0,imageLoads-1)}
    func prepareForDirectionGrid() {playback.releaseAll();clearImages()}
    private func clearImages() {currentImageReferences=[];currentImageReference="";historicalImageReference=""}
    /// Each load or Open original requests a fresh exact lease: the selected target's typed
    /// reference, or a historical example's exact accepted decision and winning reference.
    func playbackLease(original: Record,example: Record?) async throws -> MediaTakeLoader.Lease {
        let (method,params)=Self.playbackLeaseRequest(roundID:roundID,selectedID:selectedID,targetID:item.object("target")["id"] as? String ?? "",original:original,example:example)
        let value=try await read(method,params)
        let attachment=Record(values:value["attachment"] as? MediaValues ?? [:])
        guard let lease=value["lease_id"] as? String,!attachment.string("path").isEmpty else {throw ChecklistError("MANAGED_ORIGINAL_UNAVAILABLE","The service did not return this exact original's reader lease.")}
        return .init(id:lease,path:attachment.string("path"),size:attachment.integer("size",fallback:0),name:attachment.string("name",fallback:"Original"),attachmentID:attachment.id)
    }
    static func playbackLeaseRequest(roundID: String,selectedID: String,targetID: String,original: Record,example: Record?) -> (String,MediaValues) {
        if let example {
            return ("media_example_read_lease",["round_id":roundID,"target_id":example.string("target_id"),"decision_id":example.string("decision_id"),"reference_id":original.string("reference_id"),"seconds":MediaPlaybackBudget.leaseSeconds])
        }
        return ("media_original_read",["round_id":roundID,"item_id":selectedID,"target_id":targetID,"reference_id":original.string("reference_id"),"representation":"lease","seconds":MediaPlaybackBudget.leaseSeconds])
    }
    func releasePlaybackLease(_ id: String,projectID: String? = nil) async {_ = try? await read("media_example_read_release",["lease_id":id],projectID:projectID)}
    func imageIsActive(_ key:String,historical:Bool) -> Bool {historical ? historicalImageReference==key : currentImageReferences.contains(key)}
    func observation() -> MediaValues {["round_id":roundID,"expected_revision":header.integer("revision"),"observed_context_token":header.string("observed_context_token")]}
    nonisolated static func decisionRequiresNote(_ disposition: String) -> Bool { ["changes_requested","excluded"].contains(disposition) }
    func decide(_ choice: MediaAnimationReviewChoice) {
        let mapped=choice.mapping(note:draft.note)
        draft.note=mapped.note
        decide(mapped.disposition)
    }
    func decide(_ disposition: String) {
        guard decisionEnabled else {return}
        guard !Self.decisionRequiresNote(disposition) || hasDecisionNote else {
            error=disposition == "changes_requested" ? "Enter a note describing the requested changes." : "Enter an exclusion reason in the owner note."
            return
        }
        let target=Record(values:item.object("target"))
        var p=observation()
        p["observed_context_token"]=draft.contextToken
        p["manifest_id"]=draft.manifestID;p["manifest_digest"]=draft.manifestDigest
        p["items"]=[["item_id":selectedID,"expected_revision":item.integer("revision"),"target_id":draft.targetID,"review_basis_signature":draft.basis]]
        p["disposition"]=disposition
        if !draft.note.isEmpty {p["note"]=draft.note}
        if !draft.noFollowUpReason.isEmpty {p["no_follow_up_reason"]=draft.noFollowUpReason}
        if disposition=="accepted" {p["winner_id"]=draft.winnerID.isEmpty && target.strings("candidate_ids").count==1 ? target.strings("candidate_ids")[0] : draft.winnerID}
        if disposition=="changes_requested",target.strings("candidate_ids").count>1 {p["none_fit"]=true}
        let scope=draftScope,sent=draft
        mutate("media_decide",p) { [weak self] _ in
            guard let self,self.draftScope==scope,self.draft==sent else {return}
            // The per-item note is autosaved as typed and remains after an owner action.
            // Only the one-decision follow-up exception is consumed by a successful send.
            self.draft.noFollowUpReason=""
        }
    }
    func reconcile(_ action: String) {
        var p=observation();p["attention_ids"]=header.strings("attention_ids");p["action"]=action;p["reason"]=draft.reconciliationReason
        mutate("media_context_reconcile",p) { [weak self] _ in self?.contextConflict=true }
    }
    func previewPublication() async {
        publicationFailure=nil
        do {let result=try await read("media_publication_preview",["round_id":roundID]);header=Record(values:result["round"] as? MediaValues ?? [:]);publicationObservation=observation();publication=(result["items"] as? [MediaValues] ?? []).map(Record.init)} catch {self.error=PlainError.text(error)}
    }
    /// The intake "Publish these N items" press (CL-426). It sends the frozen preview that the owner
    /// saw, with its observation. On `MEDIA_PROJECT_CONTEXT_REQUIRED` the CL-422 helper approves the
    /// project context; the model then reads the preview again and publishes it only if it holds the
    /// same items and targets. A refusal shows one plain line in the intake view; no global alert shows.
    func publish() {Task {await publishShownPreview()}}
    func publishShownPreview() async {
        guard !publication.isEmpty,!publishingShown,let store else {return}
        let shown=publication,observed=publicationObservation,project=projectID,round=roundID,choice=roundChoiceEpoch
        publicationFailure=nil
        if let reason=store.writeBlockReason {publicationFailure=Self.itemsNotPublished(ChecklistError("WRITE_BLOCKED",reason));return}
        publishingShown=true
        defer {publishingShown=false}
        do {
            try await approvingProjectContext({
                var p=observed
                p["items"]=shown.map {row -> MediaValues in var value=row.values;value.removeValue(forKey:"title");value.removeValue(forKey:"publication_ready");return value}
                try await self.mutateAwaiting("media_round_publish",p,quiet:true)
                if self.projectID==project,self.roundID==round,self.roundChoiceEpoch==choice {self.publication=[];self.roundState="open"}
            },again:{
                _ = try await self.publishFrozenPreviewOnce(onlyReady:false,required:nil,shown:shown)
            })
        } catch is CancellationError {}
        catch {if projectID==project,roundID==round,roundChoiceEpoch==choice {publicationFailure=Self.itemsNotPublished(error)}}
    }
    /// The intake view's one plain line for a refused publication, a failed approval included.
    /// An unknown outcome does not claim that nothing was published.
    static func itemsNotPublished(_ error: Error) -> String {
        var reason=PlainError.text(error).trimmingCharacters(in:.whitespacesAndNewlines)
        while reason.hasSuffix(".") {reason.removeLast()}
        if ["OUTCOME_UNKNOWN","COMMAND_FAILED"].contains((error as? ChecklistError)?.code ?? "") {return "Checklist does not know if these items were published: "+reason+"."}
        return "Could not publish these items: "+reason+". Nothing was published."
    }
    /// One owner press publishes an agent-prepared Draft through the existing exact
    /// publication boundary. No owner intake steps or mutable list selection are used.
    func publishPreparedRound() async {
        guard preparedPublicationAvailable,!publishingPrepared,let store else {return}
        if let reason=store.writeBlockReason {store.inform(reason);return}
        let project=projectID,round=roundID,choice=roundChoiceEpoch
        publishingPrepared=true
        defer {publishingPrepared=false}
        do {try await publishFrozenPreview(onlyReady:false)}
        catch is CancellationError {}
        catch {if projectID==project,roundID==round,roundChoiceEpoch==choice {self.error=PlainError.text(error)}}
    }
    /// The exact Draft publication: it reads the frozen publication preview and submits its item
    /// revisions, Draft targets and prospective bases through `media_round_publish`, then waits
    /// for the committed reply. Without `onlyReady` every item must be publication-ready (the
    /// Publish action). With `onlyReady` it publishes the ready items, and `required` (CL-422)
    /// must be one of them with the Draft target that the owner saw; otherwise nothing is sent.
    /// It returns the preview rows that it published.
    ///
    /// CL-422 rework (owner, 3 Nov 2026): the owner's own press in the trusted app is the project
    /// context approval. On `MEDIA_PROJECT_CONTEXT_REQUIRED` the model sends the same
    /// `media_context_approve` request as the setup button, then reads the preview again and
    /// publishes once more. There is no dialog and no setup step. Each refusal comes back to the
    /// caller, which shows it; no global alert shows it.
    @discardableResult func publishFrozenPreview(onlyReady: Bool,required: (itemID: String,targetID: String)? = nil) async throws -> [Record] {
        try await approvingProjectContext {try await self.publishFrozenPreviewOnce(onlyReady:onlyReady,required:required)}
    }
    /// The one rule of every owner publication route (CL-422, CL-426): run `attempt`; on
    /// `MEDIA_PROJECT_CONTEXT_REQUIRED` send the owner approval (`approveProjectContext`), wait until
    /// the store can write, and run `again` (or `attempt`) once more. Every other refusal comes back.
    private func approvingProjectContext<T>(_ attempt: () async throws -> T,again: (() async throws -> T)? = nil) async throws -> T {
        do {return try await attempt()}
        catch let error as ChecklistError where error.code=="MEDIA_PROJECT_CONTEXT_REQUIRED" {
            try await approveProjectContext(quiet:true)
            await waitUntilWritable()
            if let again {return try await again()}
            return try await attempt()
        }
    }
    /// `shown` (CL-426): the preview rows that the owner saw; the new preview must hold exactly
    /// the same items and targets, or nothing is sent.
    private func publishFrozenPreviewOnce(onlyReady: Bool,required: (itemID: String,targetID: String)?,shown: [Record]? = nil) async throws -> [Record] {
        let project=projectID,round=roundID,choice=roundChoiceEpoch
        let preview=try await read("media_publication_preview",["round_id":round])
        guard projectID==project,roundID==round,roundChoiceEpoch==choice,!Task.isCancelled else {throw CancellationError()}
        let frozen=Record(values:preview["round"] as? MediaValues ?? [:])
        let all=(preview["items"] as? [MediaValues] ?? []).map(Record.init)
        guard frozen.id==round,frozen.string("state")=="draft" else {throw ChecklistError("MEDIA_ROUND_CHANGED","This prepared round changed. Refresh before publishing.")}
        let items=onlyReady ? all.filter {$0.bool("publication_ready")} : all
        guard !items.isEmpty,items.allSatisfy({$0.bool("publication_ready")}) else {throw ChecklistError("MEDIA_UNRESOLVED","The agent must capture all required originals before this round can be published.")}
        if let required,!items.contains(where:{$0.string("item_id")==required.itemID && $0.string("target_id")==required.targetID}) {
            throw ChecklistError("MEDIA_UNRESOLVED","This take is not ready for publication, or it changed. Refresh and look at it again.")
        }
        func targets(_ rows: [Record]) -> Set<[String]> {Set(rows.map {[$0.string("item_id"),$0.string("target_id")]})}
        if let shown,targets(items) != targets(shown) {throw ChecklistError("MEDIA_ROUND_CHANGED","The publication items changed. Preview the publication again.")}
        let params:MediaValues=["round_id":round,"expected_revision":frozen.integer("revision"),"observed_context_token":frozen.string("observed_context_token"),
            "items":items.map {row -> MediaValues in ["item_id":row.string("item_id"),"expected_revision":row.integer("expected_revision"),"target_id":row.string("target_id"),"review_basis_signature":row.string("review_basis_signature")]}]
        try await mutateAwaiting("media_round_publish",params,quiet:true)
        if projectID==project,roundID==round,roundChoiceEpoch==choice {publication=[];roundState="open"}
        return items
    }
    /// The one-time project context approval (`media_context_approve`, kind project) for the
    /// observed project revision. A failure also shows in `error`, unless `quiet`.
    func approveProjectContext(quiet: Bool = false) async throws {
        guard let project=store?.currentProject else {throw ChecklistError("PROJECT_REQUIRED","Select a project.")}
        try await mutateAwaiting("media_context_approve",["kind":"project","expected_project_revision":project.integer("revision")],quiet:quiet)
    }
    /// Waits (at most 10 s) until the store can accept the next change of a sequence (CL-422).
    func waitUntilWritable() async {
        for _ in 0..<40 {
            guard let store,store.writeBlockReason != nil || store.hasPendingMutation,!Task.isCancelled else {return}
            try? await Task.sleep(nanoseconds:250_000_000)
        }
    }
    /// The awaited form of `mutateReportingFailure`: it returns the committed reply, or throws the refusal.
    @discardableResult func mutateAwaiting(_ method: String,_ params: MediaValues,quiet: Bool = false) async throws -> MediaValues {
        guard store != nil else {throw ChecklistError("WRITE_NOT_STARTED","Checklist is not connected.")}
        let reply=MediaReplyBox()
        try await withCheckedThrowingContinuation {continuation in
            let once=MediaResumeOnce(continuation)
            mutateReportingFailure(method,params,quiet:quiet,onFailure:{once.resume(.failure($0))}) {value in reply.value=value;once.resume(.success(()))}
        }
        return reply.value
    }
    func previewIntake(_ params: MediaValues) {var p=params;p["round_id"]=roundID
        let isFiles=params["sources"] != nil
        let assignments: [MediaValues]
        if isFiles && mapsAnimationNames {
            assignments=["character","animation_label","direction"].enumerated().filter {fields.map(\.id).contains($0.element)}.map {["field_id":$0.element,"source":["kind":"stem_token","delimiter":"__","index":$0.offset]]}
        } else if params["tsv"] != nil {assignments=fields.map {["field_id":$0.id,"source":["kind":"column","column_id":$0.id]]}}
        else {assignments=[]}
        p["mapping"]=["input":isFiles ? "selected_files" : params["tsv"] != nil ? "tsv" : "explicit_metadata","assignments":assignments]
        mutate("media_intake_preview",p) {[weak self] in self?.intake=Record(values:$0)}}
    func resolveIntake(_ row: Record,disposition: String,slotID: String?=nil,groupID:String?=nil) {
        var resolution: MediaValues=["row_id":row.id,"disposition":disposition]
        if let slotID {resolution["slot_id"]=slotID}
        if let groupID {resolution["group_id"]=groupID}
        mutate("media_intake_revise",["intake_id":intake.id,"expected_revision":intake.integer("revision"),"resolutions":[resolution]]) {[weak self] in self?.intake=Record(values:$0)}
    }
    func confirmIntake() {let plan=Record(values:intake.object("plan"));mutate("media_intake_confirm",["intake_id":intake.id,"expected_revision":intake.integer("revision"),"plan_id":plan.id,"plan_digest":plan.string("digest")]) {[weak self] in self?.intake=Record(values:$0)}}
    /// Captures every remaining row: the service takes 200 rows per command, so the model
    /// repeats capture until no row remains or a chunk makes no progress (CL-307).
    /// The next chunk starts only after the store finished the previous command and can
    /// write again: sending it from inside the completion found the store still blocked
    /// (busy, or offline after a long chunk) and stopped the sequence after one chunk.
    func captureIntake() {
        let remaining = intake.strings("remaining_row_ids")
        guard !remaining.isEmpty,let store else {capturing=false;return}
        if let reason=store.writeBlockReason {store.inform(reason);capturing=false;return}
        capturing = true
        let intakeID = intake.id
        mutate("media_intake_capture",["intake_id":intake.id,"expected_revision":intake.integer("revision"),"plan_id":intake.string("plan_id"),"row_ids":Array(remaining.prefix(200))]) {[weak self] in
            guard let self else {return}
            self.intake=Record(values:$0)
            let next = self.intake.strings("remaining_row_ids")
            guard !next.isEmpty,next != remaining else {self.capturing=false;return}
            Task {[weak self] in await self?.continueCapture(intakeID)}
        }
    }
    /// Waits (at most 10 minutes) until the store can write, then sends the next chunk.
    /// Leaving the intake or an unchecked earlier change stops the sequence.
    /// CL-315: a media write discards the pages that name the store identity without reading
    /// them again, so the identity can be unknown between chunks (writeBlockReason reports it).
    /// After 2 s the sequence asks once for a quiet refresh, then keeps waiting.
    func continueCapture(_ intakeID: String) async {
        var refreshed = false
        for step in 0..<2400 {
            guard let store,capturing,intake.id == intakeID,!store.hasPendingMutation else {capturing=false;return}
            guard let reason=store.writeBlockReason else {captureIntake();return}
            if reason == DisabledReasons.storeUnknown,!refreshed,step >= 8 {refreshed=true;await store.refresh(quiet:true);continue}
            try? await Task.sleep(nanoseconds:250_000_000)
        }
        capturing=false
        error="Capture stopped: Checklist could not accept changes for 10 minutes. Press Capture to continue."
    }
    func resumeIntake(_ id: String) async {do {intake=Record(values:try await read("media_intake_get",["intake_id":id]))} catch {self.error=PlainError.text(error)}}
    // CL-300: rework preview/create, closure and successor use the native owner channel only.
    nonisolated static func dispositionLabel(_ value: String) -> String { value.replacingOccurrences(of:"_",with:" ").capitalized }
    static func countsText(_ counts: [String: Int]) -> String { counts.keys.sorted().map { dispositionLabel($0)+": "+String(counts[$0] ?? 0) }.joined(separator:" · ") }
    var reworkAvailable: Bool { !historyOnly && header.string("state") == "open" }
    var successorAvailable: Bool { !historyOnly && ["open","closed"].contains(header.string("state")) }
    var reworkCandidates: [Record] { rows.filter { $0.string("disposition") == "changes_requested" } }
    func clearRoundActions() { reworkSelection=[];reworkPreview=Record(values:[:]);successorItems=[:];bulk=MediaBulkState();resultSend=MediaResultSend();ticketLinkLine="" }
    /// Only a listed Changes-requested item can be selected; the service checks the exact decision.
    func toggleRework(_ row: Record) {
        if reworkSelection.contains(row.id) {reworkSelection.remove(row.id)}
        else if row.string("disposition") == "changes_requested" {reworkSelection.insert(row.id)}
    }
    func loadEpics() async {
        guard let store, !projectID.isEmpty else {return}
        let project=projectID
        do {
            let query=WorkspacePageQuery(surface:"epics",project:project)
            // CL-302: a retired Epic read is read again; it never shows the CancellationError text.
            guard case .loaded(let reply)=try await store.retirableRead("workspace_page",query.parameters(cursor:nil),isCurrent:{self.projectID==project}) else {return}
            let page=try WorkspacePage(reply,query:query)
            guard projectID==project else {return}
            epics=page.rows.filter {!$0.bool("archived")}
            if !reworkEpicID.isEmpty && !epics.contains(where:{$0.id==reworkEpicID}) {reworkEpicID=""}
        } catch is CancellationError {}
        catch {self.error=PlainError.text(error)}
    }
    func previewRework() async {
        let round=roundID,selection=reworkSelection.sorted(),epic=reworkEpicID
        do {
            let result=try await read("media_rework_preview",["round_id":round,"epic_id":epic,"items":selection.map {["item_id":$0]}])
            guard roundID==round,reworkSelection.sorted()==selection,reworkEpicID==epic else {return}
            reworkPreview=Record(values:result)
        } catch {reworkPreview=Record(values:[:]);self.error=PlainError.text(error)}
    }
    /// Create repeats the exact preview: observation fence, Epic, item revisions, decisions and digest.
    static func reworkCreateParams(_ preview: Record) -> MediaValues {
        var p: MediaValues=[:]
        for key in ["round_id","expected_revision","observed_context_token","manifest_id","manifest_digest","epic_id","preview_digest"] {p[key]=preview.values[key]}
        p["items"]=preview.records("items").map {["item_id":$0.string("item_id"),"expected_revision":$0.values["expected_revision"] ?? NSNull(),"decision_id":$0.string("decision_id")] as MediaValues}
        return p
    }
    func createRework() {
        guard !reworkPreview.records("items").isEmpty else {return}
        mutate("media_rework_create",Self.reworkCreateParams(reworkPreview)) { [weak self] _ in
            self?.reworkSelection=[];self?.reworkPreview=Record(values:[:])
        }
    }
    /// CL-350: Pending, Stale and a Changes requested item with no follow-up each block closure
    /// with their own text. Needs look does not block; it stays listed for the worker.
    static func closureBlockers(_ counts: [String: Int]) -> [(Bool, String)] {
        let pending=counts["pending"] ?? 0,stale=counts["stale"] ?? 0,missing=counts["missing_follow_up"] ?? 0
        return [(pending>0,"\(pending) Pending item(s) need an owner decision before you close this round."),
                (stale>0,"\(stale) Stale item(s) changed after their decision. Decide them again on the current material."),
                (missing>0,"\(missing) Changes requested item(s) have no follow-up yet. A worker records one, or you add a no-follow-up reason.")]
    }
    /// The service's unfiltered counts; the item list counts follow the current filter.
    var closureCounts: [String: Int] { header.values["closure_readiness"] as? [String: Int] ?? counts }
    /// One press closes the round. The service rechecks the exact round and every follow-up.
    func finishRound() {
        let manifest=Record(values:header.object("manifest"))
        mutate("media_round_finish",["round_id":roundID,"expected_revision":header.integer("revision"),"observed_context_token":header.string("observed_context_token"),"manifest_id":manifest.id,"manifest_digest":manifest.string("digest")])
    }
    /// A carry names the item's current decision; Pending and Stale items have none to carry.
    static func canCarry(_ row: Record) -> Bool { ["accepted","excluded","changes_requested","needs_look"].contains(row.string("disposition")) && !row.string("decision_id").isEmpty }
    func includeInSuccessor(_ row: Record,include: Bool,carry: Bool) {
        guard include else {successorItems[row.id]=nil;return}
        var entry: MediaValues=["item_id":row.id]
        if carry,Self.canCarry(row) {entry["carry_decision_id"]=row.string("decision_id")}
        successorItems[row.id]=entry
    }
    static func successorParams(header: Record,title: String,items: [String: MediaValues]) -> MediaValues {
        let manifest=Record(values:header.object("manifest"))
        return ["source_round_id":header.id,"expected_revision":header.integer("revision"),"observed_context_token":header.string("observed_context_token"),
                "manifest_id":manifest.id,"manifest_digest":manifest.string("digest"),"title":title,"items":items.keys.sorted().compactMap {items[$0]}]
    }
    func createSuccessor(title: String,then: @escaping () -> Void = {}) {
        mutate("media_round_successor",Self.successorParams(header:header,title:title,items:successorItems)) { [weak self] result in
            guard let self,let id=result["id"] as? String,!id.isEmpty else {return}
            then();self.roundState="draft";self.roundOffset=0;self.chooseRound(id)
        }
    }
    /// Direction cards share the same local per-item note journal as single-item review.
    func ownerDraft(for item: Record, header: Record) -> MediaOwnerDraft {
        let scope=projectID+":"+item.id
        let saved=store?.windowPreferences.data(forKey:"mediaDraft:"+scope)
        var value=drafts[scope] ?? saved.flatMap {try? JSONDecoder().decode(MediaOwnerDraft.self,from:$0)} ?? MediaOwnerDraft()
        if value.basis.isEmpty {
            let target=Record(values:item.object("target")),manifest=Record(values:header.object("manifest"))
            value.basis=target.string("review_basis_signature");value.targetID=target.id
            value.contextToken=header.string("observed_context_token");value.manifestID=manifest.id;value.manifestDigest=manifest.string("digest")
        }
        return value
    }
    func saveOwnerDraft(_ value: MediaOwnerDraft, itemID: String) {
        let scope=projectID+":"+itemID
        drafts[scope]=value
        if let data=try? JSONEncoder().encode(value) {store?.windowPreferences.set(data,forKey:"mediaDraft:"+scope)}
        if draftScope==scope {draft=value}
    }
    private func saveDraft() {guard !draftScope.isEmpty else {return};drafts[draftScope]=draft;if let data=try? JSONEncoder().encode(draft) {store?.windowPreferences.set(data,forKey:"mediaDraft:"+draftScope)}}
    static func defaultList(_ schema: MediaValues) -> MediaValues {
        let ids=(schema["fields"] as? [MediaValues] ?? []).compactMap {$0["id"] as? String}
        return ["visible_columns":Array(ids.prefix(8)),"group_by":["character","animation_label"].filter(ids.contains),"sort":ids.contains("direction") ? [["field_id":"direction","order":((schema["fields"] as? [MediaValues])?.first {$0["id"] as? String == "direction"}?["kind"] as? String == "choice") ? "declared_choice_order" : "ascending"]] : [["key":"order","order":"ascending"]]]
    }
}
/// CL-427: the round names the ticket that owns its takes, and one owner press sends the
/// owner's decisions and notes to that ticket as one ordinary ticket note.
extension MediaReviewModel {
    /// The round's ticket (`task: {id, key, title, status_name}` in the round read), or an empty record.
    var linkedTask: Record { Record(values:header.object("task")) }
    /// The header line: "For HEIR-130 — Behemoth walk", or "No ticket".
    nonisolated static func ticketLine(_ header: Record) -> String {
        let task=Record(values:header.object("task"))
        guard !task.id.isEmpty else {return "No ticket"}
        let key=task.string("key"),title=task.string("title")
        let name=[key,title].filter {!$0.isEmpty}.joined(separator:" — ")
        return "For "+(name.isEmpty ? "the linked ticket" : name)
    }
    /// The owner can choose or change the ticket while the round is Draft or Open (not closed).
    var ticketChangeAvailable: Bool { writable && header.id == roundID }
    /// Open tickets of this project, searched by key or title through the existing ticket list read.
    func loadTicketChoices(_ text: String) async {
        guard let store,!projectID.isEmpty else {return}
        let project=projectID,round=roundID
        func current() -> Bool {projectID==project && roundID==round}
        ticketChoicesLoading=true
        defer {if current() {ticketChoicesLoading=false}}
        do {
            guard case .loaded(let reply)=try await store.retirableRead("task_list",["project_id":project,"text":text,"archived":false,"limit":100],isCurrent:current) else {return}
            guard current(),!Task.isCancelled else {return}
            Self.assignIfChanged(&ticketChoices,Self.openTickets((reply["tasks"] as? [MediaValues] ?? []).map(Record.init)))
        } catch is CancellationError {}
        catch {if current() {ticketLinkLine="Could not search project tickets. The round's ticket did not change."}}
    }
    /// Done and canceled tickets are not offered; the rest are sorted by key.
    nonisolated static func openTickets(_ rows: [Record]) -> [Record] {
        rows.filter {!["done","canceled","cancelled"].contains($0.string("status_category"))}
            .sorted {$0.string("key").localizedStandardCompare($1.string("key")) == .orderedAscending}
    }
    nonisolated static func linkTaskParams(header: Record,taskID: String?) -> MediaValues {
        ["round_id":header.id,"expected_revision":header.integer("revision"),"task_id":taskID.map {$0 as Any} ?? NSNull()]
    }
    /// Sends `media_round_link_task`; `nil` removes the link. A refusal shows one line beside the ticket.
    func linkTask(_ taskID: String?) {
        guard ticketChangeAvailable else {return}
        let round=roundID
        ticketLinkLine=""
        mutateReportingFailure("media_round_link_task",Self.linkTaskParams(header:header,taskID:taskID),quiet:true,onFailure:{[weak self] error in
            guard let self,self.roundID==round else {return}
            self.ticketLinkLine="Could not change the ticket: "+PlainError.text(error)
        }) {[weak self] _ in self?.ticketLinkLine=""}
    }
    nonisolated static let decidedDispositions=["accepted","changes_requested","needs_look","excluded"]
    /// The send action, or nil when it is hidden (no ticket, or no owner decision yet).
    /// After a send it offers only changes: a listed decision that the last send did not carry.
    /// While some items are not listed (a filter, or a page not loaded) the model cannot prove
    /// that nothing is new, so the action stays enabled and the service answers.
    nonisolated static func resultAction(header: Record,rows: [Record],counts: [String: Int],listComplete: Bool) -> MediaResultAction? {
        let key=Record(values:header.object("task")).string("key",fallback:"the ticket")
        guard !Record(values:header.object("task")).id.isEmpty else {return nil}
        let decided=rows.filter {decidedDispositions.contains($0.string("disposition")) && !$0.string("decision_id").isEmpty}
        guard !decided.isEmpty || decidedDispositions.contains(where:{(counts[$0] ?? 0)>0}) else {return nil}
        let last=Record(values:header.object("last_result_sent"))
        guard !last.values.isEmpty else {return .init(label:"Send results to "+key,disabledReason:nil)}
        let sent=Set(last.strings("decision_ids"))
        let changed = !listComplete || decided.contains {!sent.contains($0.string("decision_id"))}
        return .init(label:"Send changes to "+key,disabledReason:changed ? nil : allResultsSentText)
    }
    nonisolated static let allResultsSentText="All results sent."
    nonisolated static let nothingNewText="Nothing new to send."
    var resultAction: MediaResultAction? {
        guard !historyOnly,header.id==roundID else {return nil}
        return Self.resultAction(header:header,rows:rows,counts:closureCounts,listComplete:filter=="all" && next==nil)
    }
    /// The plain line beside the send action: progress, the receipt, a refusal, or the last send.
    var resultLine: (text: String,refused: Bool)? {
        if resultSend.roundID==roundID,!resultSend.line.isEmpty {return (resultSend.line,resultSend.refused)}
        let last=Record(values:header.object("last_result_sent"))
        guard header.id==roundID,!last.values.isEmpty,let action=resultAction else {return nil}
        if action.disabledReason != nil {return (Self.allResultsSentText,false)}
        return ("Last sent at "+Self.localTime(last.string("at"))+". Changes since then are not sent yet.",false)
    }
    /// One press sends `media_round_send_result` through the owner command route and waits for its reply.
    func sendResults() async {
        guard let action=resultAction,action.disabledReason==nil,!resultSend.sending,let store else {return}
        if let reason=store.writeBlockReason {store.inform(reason);return}
        let project=projectID,round=roundID,choice=roundChoiceEpoch,key=linkedTask.string("key",fallback:"the ticket")
        func current() -> Bool {projectID==project && roundID==round && roundChoiceEpoch==choice}
        resultSend=MediaResultSend(roundID:round,sending:true,line:"Sending results to "+key+"…")
        do {
            let reply=try await mutateAwaiting("media_round_send_result",["round_id":round,"expected_revision":header.integer("revision")],quiet:true)
            guard current() else {return}
            resultSend=MediaResultSend(roundID:round,line:Self.receiptText(reply))
        } catch {
            guard current() else {return}
            let code=(error as? ChecklistError)?.code ?? ""
            resultSend=MediaResultSend(roundID:round,line:Self.sendRefusalText(error),refused:code != "MEDIA_ROUND_NOTHING_NEW")
        }
    }
    /// "Sent to Codex HEIR-T1 and Claude reviewer at 7:12 PM · 3 items."
    nonisolated static func receiptText(_ reply: MediaValues) -> String {
        let names=(reply["recipients"] as? [MediaValues] ?? []).map {Record(values:$0).string("display",fallback:"an unnamed session")}
        let count=reply["item_count"] as? Int ?? 0
        let items=count==1 ? "1 item" : "\(count) items"
        let who=names.isEmpty ? "" : " to "+listText(names)
        return "Sent"+who+" at "+localTime(reply["sent_at"] as? String ?? "")+" · "+items+((reply["changed_only"] as? Bool ?? false) ? " changed since the last send." : ".")
    }
    nonisolated static func listText(_ names: [String]) -> String {
        guard names.count>1 else {return names.first ?? ""}
        return names.dropLast().joined(separator:", ")+" and "+names.last!
    }
    nonisolated static func sendRefusalText(_ error: Error) -> String {
        switch (error as? ChecklistError)?.code ?? "" {
        case "MEDIA_ROUND_NOTHING_NEW": return nothingNewText
        case "MEDIA_ROUND_NO_TASK": return "Choose the ticket for this round first. Nothing was sent."
        case "MEDIA_ROUND_NO_DECISIONS": return "Decide at least one item first. Nothing was sent."
        default: return "Could not send results: "+PlainError.text(error)
        }
    }
    /// A service time in the owner's local time: the time today, else the date and time.
    nonisolated static func localTime(_ value: String,timeZone: TimeZone = .current) -> String {
        let parser=ISO8601DateFormatter()
        parser.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        guard let date=parser.date(from:value) ?? ISO8601DateFormatter().date(from:value) else {return value.isEmpty ? "an unknown time" : value}
        let formatter=DateFormatter()
        formatter.timeZone=timeZone
        var calendar=Calendar.current;calendar.timeZone=timeZone
        formatter.dateStyle=calendar.isDateInToday(date) ? .none : .medium
        formatter.timeStyle = .short
        return formatter.string(from:date)
    }
}
struct MediaResultAction: Equatable {
    let label: String
    let disabledReason: String?
}
struct MediaResultSend: Equatable {
    var roundID=""
    var sending=false
    var line=""
    var refused=false
}

struct MediaOwnerDraft: Codable,Equatable {
    var note="",winnerID="",noFollowUpReason="",reconciliationReason="",basis="",targetID="",contextToken="",manifestID="",manifestDigest=""
}

/// The old animation page's choices translate to existing native owner actions.
/// A typed note wins; Redo and Other pose retain their reason when no note was entered.
enum MediaAnimationReviewChoice: String,CaseIterable {
    case accept="Accept",redo="Redo",otherPose="Other pose",lookAtIt="Look at it"
    func mapping(note: String) -> MediaOwnerDecisionChoice {
        let disposition: String
        switch self {
        case .accept: disposition="accepted"
        case .redo,.otherPose: disposition="changes_requested"
        case .lookAtIt: disposition="needs_look"
        }
        let mappedNote=disposition == "changes_requested" && note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? rawValue : note
        return MediaOwnerDecisionChoice(disposition:disposition,note:mappedNote)
    }
}
struct MediaOwnerDecisionChoice: Equatable {
    let disposition:String
    let note:String
}

struct MediaFlatRow: Identifiable {
    let id:String
    let title:String
    let item:Record?
    /// The header's metadata prefix, for selecting its whole group (CL-349).
    var group:[MediaValues]=[]
    static func project(_ items:[Record]) -> [Self] {
        var result:[Self]=[],previous:[Data]=[]
        for item in items {
            var prefix:[MediaValues]=[],keys:[Data]=[]
            for (level,group) in item.records("group_path").enumerated() {
                prefix.append(["field_id":group.string("field_id"),"value":group.values["value"] ?? NSNull()])
                let bytes=(try? JSONSerialization.data(withJSONObject:prefix,options:.sortedKeys)) ?? Data()
                keys.append(bytes)
                if level >= previous.count || previous[level] != bytes {
                    let value=group.values["value"].flatMap {$0 is NSNull ? nil : String(describing:$0)} ?? "No value"
                    result.append(.init(id:"group:"+bytes.base64EncodedString(),title:group.string("field_id")+": "+value+" · "+String(group.integer("item_count")),item:nil,group:prefix))
                }
            }
            previous=keys
            result.append(.init(id:"item:"+item.id,title:item.string("title"),item:item))
        }
        return result
    }
}
