import Foundation
import SwiftUI
import ChecklistIPC

typealias MediaValues = [String: Any]

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
    private var publicationObservation: MediaValues = [:]
    @Published var publication: [Record] = []
    @Published var error: String?
    @Published var loading = false
    @Published var draft = MediaOwnerDraft() { didSet { saveDraft() } }
    @Published var contextConflict = false
    private(set) var projectID = ""
    private weak var store: ChecklistStore?
    private var epoch = UUID()
    private var selectionEpoch = UUID()
    private var drafts: [String: MediaOwnerDraft] = [:]
    private var draftScope = ""
    private var listScope = ""
    var enabledTypes: [Record] { types.filter { $0.bool("enabled") } }
    var hasMedia: Bool { !enabledTypes.isEmpty }
    var selectedOutsideFilter: Bool { !selectedID.isEmpty && !rows.contains { $0.id == selectedID } }
    var writable: Bool { !historyOnly && ["draft", "open"].contains(header.string("state")) }
    var schema: MediaValues { header.object("type_revision")["schema"] as? MediaValues ?? [:] }
    var fields: [Record] { (schema["fields"] as? [MediaValues] ?? []).map(Record.init) }
    var slots: [Record] { (schema["slots"] as? [MediaValues] ?? []).map(Record.init) }
    var decisionEnabled: Bool { !historyOnly && item.bool("published") && header.string("state") == "open" && !contextConflict && header.records("attention").isEmpty && !item.object("target").isEmpty }

    func connect(store: ChecklistStore) async {
        self.store = store
        let project = store.projectID ?? ""
        if project != projectID {
            saveDraft(); projectID = project; epoch = UUID(); selectionEpoch = UUID()
            currentImageReference="";historicalImageReference="";listScope="";list=[:];roundOffset=0
            types=[];rounds=[];rows=[];typeID="";roundID="";selectedID="";header=Record(values:[:]);item=Record(values:[:]);intake=Record(values:[:]);publication=[];examples=[]
            draftScope="";draft = MediaOwnerDraft(); contextConflict=false
        }
        await refresh()
    }
    func read(_ method: String,_ params: MediaValues = [:]) async throws -> MediaValues {
        guard let store, !projectID.isEmpty else {throw ChecklistError("PROJECT_REQUIRED", "Select a project.")}
        var params=params;params["project_id"]=projectID
        return try await store.request(method,params)
    }
    func mutate(_ method: String,_ params: MediaValues,then: @escaping (MediaValues) throws -> Void = {_ in}) {
        guard let store else {return}
        var params=params;params["project_id"]=projectID
        let project = projectID
        store.run(method,params,failure:{ [weak self] error in
            guard let self,self.projectID == project else {return}
            self.error=PlainError.text(error)
            if ["MEDIA_CONTEXT_CHANGED","MEDIA_CONTEXT_ATTENTION","MEDIA_BASIS_CHANGED","REVISION_CONFLICT"].contains((error as? ChecklistError)?.code ?? "") {self.contextConflict=true}
        }) { [weak self] result in
            guard let self,self.projectID == project else {return}
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
    func refresh() async {
        guard !projectID.isEmpty else {return}
        let token=UUID();epoch=token;loading=true
        defer {if epoch==token {loading=false}}
        do {
            let nav=try await read("media_navigation")
            guard epoch==token else {return}
            types=(nav["types"] as? [MediaValues] ?? []).map(Record.init)
            if !historyOnly && !enabledTypes.contains(where:{$0.id == typeID}) {typeID=enabledTypes.first?.id ?? ""}
            if !hasMedia && !historyOnly {if store?.page == .media {store?.page = .tasks};return}
            if !typeID.isEmpty {
                let result=try await read("media_round_page",["type_id":typeID,"state":roundState,"offset":roundOffset])
                guard epoch==token else {return};roundsHaveMore=result["has_more"] as? Bool ?? false;rounds=(result["rows"] as? [MediaValues] ?? []).map(Record.init)
            }
            if !roundID.isEmpty {try await loadRound(token:token)}
            error=nil
        } catch {if epoch==token {self.error=PlainError.text(error)}}
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
    func chooseType(_ id: String) {saveDraft();roundOffset=0;typeID=id;list=[:];roundID="";selectedID="";rows=[];header=Record(values:[:]);item=Record(values:[:]);intake=Record(values:[:]);publication=[];Task {await refresh()}}
    func chooseRound(_ id: String) {saveDraft();roundID=id;selectedID="";rows=[];item=Record(values:[:]);publication=[];intake=Record(values:[:]);contextConflict=false;Task {await refresh()}}
    private func loadRound(token: UUID) async throws {
        let id=roundID
        let result=try await read("media_round_header",["round_id":id])
        guard epoch==token,roundID==id else {return}
        header=Record(values:result)
        let scope=projectID+":"+typeID
        if listScope != scope {listScope=scope;list=(store?.windowPreferences.dictionary(forKey:"mediaList:"+scope)) ?? Self.defaultList(schema)}
        if list.isEmpty {list=Self.defaultList(schema)}
        let total=try await read("media_item_counts",["round_id":roundID,"list":list])
        guard epoch==token else {return};counts=total["counts"] as? [String:Int] ?? [:]
        let retainedCount=rows.count
        let retainedSelection=rows.contains {$0.id==selectedID}
        try await loadRows(append:false,token:token)
        // Refresh only the pages already inspected; keep their selection/scroll anchor.
        while epoch==token,next != nil,(rows.count<retainedCount || retainedSelection && !rows.contains {$0.id==selectedID}) {try await loadRows(append:true,token:token)}
        if !selectedID.isEmpty {await select(selectedID)}
    }
    func reloadRows() async {store?.windowPreferences.set(list,forKey:"mediaList:"+listScope);let token=UUID();epoch=token;do {try await loadRows(append:false,token:token)} catch {self.error=PlainError.text(error)}}
    func moreRows() async {do {try await loadRows(append:true,token:epoch)} catch {self.error=PlainError.text(error)}}
    private func loadRows(append: Bool,token: UUID) async throws {
        guard !roundID.isEmpty,!append || next != nil else {return}
        var params: MediaValues=["round_id":roundID,"list":list,"limit":100]
        if filter != "all" {params["filter"]=["dispositions":[filter]]}
        if append {params["cursor"]=next}
        let result=try await read("media_item_page",params)
        guard epoch==token else {return}
        let values=(result["rows"] as? [MediaValues] ?? []).map(Record.init)
        if append {let existing=Set(rows.map(\.id));rows += values.filter {!existing.contains($0.id)}} else {rows=values}
        if filter == "all" {counts=result["counts"] as? [String:Int] ?? [:]};next=result["next_cursor"] as? String
    }
    func select(_ id: String) async {
        saveDraft();if selectedID != id {currentImageReference="";historicalImageReference="";item=Record(values:[:]);contextConflict=false};selectedID=id
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
            item=Record(values:result)
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
        guard show,!selectedID.isEmpty else {historicalImageReference="";examples=[];examplesNext=nil;return}
        let selected=selectedID,round=roundID
        do {
            let match=(list["group_by"] as? [String] ?? []) + ((list["visible_columns"] as? [String] ?? []).contains("direction") ? ["direction"] : [])
            var p: MediaValues=["round_id":round,"item_id":selected,"expanded":true,"examples":["enabled":true,"match_fields":Array(match.prefix(3)),"page_size":4]]
            if more {p["cursor"]=examplesNext}
            let result=try await read("media_approved_examples",p)
            guard examplesShown,selectedID==selected,roundID==round else {return}
            let values=(result["examples"] as? [MediaValues] ?? []).map {raw -> Record in var raw=raw;raw["id"]=raw["target_id"];return Record(values:raw)}
            if more {historicalImageReference=""};examples=values;examplesNext=result["next_cursor"] as? String
        } catch {self.error=PlainError.text(error)}
    }
    func beginImage(_ key:String,historical:Bool) -> Bool {
        guard imageLoads<2 else {return false}
        imageLoads+=1
        if historical {historicalImageReference=key} else {currentImageReference=key}
        return true
    }
    func endImage() {imageLoads=max(0,imageLoads-1)}
    func imageIsActive(_ key:String,historical:Bool) -> Bool {(historical ? historicalImageReference : currentImageReference)==key}
    func observation() -> MediaValues {["round_id":roundID,"expected_revision":header.integer("revision"),"observed_context_token":header.string("observed_context_token")]}
    func decide(_ disposition: String) {
        guard decisionEnabled else {return}
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
            self.draft.note="";self.draft.noFollowUpReason=""
        }
    }
    func reconcile(_ action: String) {
        var p=observation();p["attention_ids"]=header.strings("attention_ids");p["action"]=action;p["reason"]=draft.reconciliationReason
        mutate("media_context_reconcile",p) { [weak self] _ in self?.contextConflict=true }
    }
    func previewPublication() async {
        do {let result=try await read("media_publication_preview",["round_id":roundID]);header=Record(values:result["round"] as? MediaValues ?? [:]);publicationObservation=observation();publication=(result["items"] as? [MediaValues] ?? []).map(Record.init)} catch {self.error=PlainError.text(error)}
    }
    func publish() {
        var p=publicationObservation
        p["items"]=publication.map {row -> MediaValues in var value=row.values;value.removeValue(forKey:"title");value.removeValue(forKey:"publication_ready");return value}
        mutate("media_round_publish",p) { [weak self] _ in self?.publication=[];self?.roundState="open" }
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
    func captureIntake() {mutate("media_intake_capture",["intake_id":intake.id,"expected_revision":intake.integer("revision"),"plan_id":intake.string("plan_id"),"row_ids":Array(intake.strings("remaining_row_ids").prefix(200))]) {[weak self] in self?.intake=Record(values:$0)}}
    func resumeIntake(_ id: String) async {do {intake=Record(values:try await read("media_intake_get",["intake_id":id]))} catch {self.error=PlainError.text(error)}}
    private func saveDraft() {guard !draftScope.isEmpty else {return};drafts[draftScope]=draft;if let data=try? JSONEncoder().encode(draft) {store?.windowPreferences.set(data,forKey:"mediaDraft:"+draftScope)}}
    static func defaultList(_ schema: MediaValues) -> MediaValues {
        let ids=(schema["fields"] as? [MediaValues] ?? []).compactMap {$0["id"] as? String}
        return ["visible_columns":Array(ids.prefix(8)),"group_by":["character","animation_label"].filter(ids.contains),"sort":ids.contains("direction") ? [["field_id":"direction","order":((schema["fields"] as? [MediaValues])?.first {$0["id"] as? String == "direction"}?["kind"] as? String == "choice") ? "declared_choice_order" : "ascending"]] : [["key":"order","order":"ascending"]]]
    }
}
struct MediaOwnerDraft: Codable,Equatable {
    var note="",winnerID="",noFollowUpReason="",reconciliationReason="",basis="",targetID="",contextToken="",manifestID="",manifestDigest=""
}

struct MediaFlatRow: Identifiable {
    let id:String
    let title:String
    let item:Record?
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
                    result.append(.init(id:"group:"+bytes.base64EncodedString(),title:group.string("field_id")+": "+value+" · "+String(group.integer("item_count")),item:nil))
                }
            }
            previous=keys
            result.append(.init(id:"item:"+item.id,title:item.string("title"),item:item))
        }
        return result
    }
}
