import SwiftUI
import AppKit

struct MediaProjectTab: View {
    @EnvironmentObject var store: ChecklistStore
    @ObservedObject var model: MediaReviewModel
    var body: some View {
        if model.hasMedia {
            Button("Media review") {store.page = .media;store.windowPreferences.set(Page.media.rawValue,forKey:"lastPage")}
                .buttonStyle(.plain).padding(10)
                .overlay(alignment:.bottom) {if store.page == .media {Rectangle().frame(height:2)}}
                .accessibilityAddTraits(store.page == .media ? .isSelected : [])
                .accessibilityIdentifier("projectTab-Media review")
        }
    }
}

struct MediaTypeSettings: View {
    @EnvironmentObject var store: ChecklistStore
    let projectID: String
    @ObservedObject var model: MediaReviewModel
    @State private var title=""
    @State private var starter="generic"
    @State private var renames:[String:String]=[:]
    @State private var confirmation: PendingConfirmation?
    @State private var historyType:Record?
    var body: some View {
        DetailSection(title:"Media review") {
            TextField("Review type name",text:$title).accessibilityIdentifier("mediaTypeTitle")
            Picker("Native starter",selection:$starter) {
                Text("Text and images").tag("generic")
                Text("Story text").tag("text")
                Text("Character animation images").tag("animation")
                Text("Video takes").tag("video")
                Text("Audio takes").tag("audio")
            }
            Button("Add review type") {
                model.mutate("media_type_create",["title":title,"schema":Self.schema(title:title,starter:starter)]) { result in
                    title=""
                    model.mutate("media_type_adopt",["type_id":result["id"]!,"expected_revision":result["revision"]!,"type_revision_id":result["draft_revision_id"]!,"observed_type_token":result["observed_type_token"]!])
                }
            }.checklistDisabled([(title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,"Enter a review type name."),(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)])
            ForEach(model.types.filter {$0.string("state") != "retired"}) {type in
                HStack {
                    TextField("Type title",text:Binding(get:{renames[type.id] ?? type.string("title")},set:{renames[type.id]=$0}))
                    Button("Rename") {model.mutate("media_type_revise",["type_id":type.id,"expected_revision":type.integer("revision"),"title":renames[type.id] ?? type.string("title")]) {result in
                        model.mutate("media_type_adopt",["type_id":result["id"]!,"expected_revision":result["revision"]!,"type_revision_id":result["draft_revision_id"]!,"observed_type_token":result["observed_type_token"]!])
                    }}.checklistDisabled([((renames[type.id] ?? type.string("title")).isEmpty,"Enter a type name.")])
                    Spacer()
                    if type.bool("enabled") {
                        Button("Retire type…") {confirmation = model.retireTypeConfirmation(type)}
                    } else {
                        Button("Enable type") {Task {
                            do {let current=try await model.read("media_type_get",["type_id":type.id]);model.mutate("media_type_adopt",["type_id":type.id,"expected_revision":current["revision"]!,"type_revision_id":current["draft_revision_id"]!,"observed_type_token":current["observed_type_token"]!])} catch {model.error=PlainError.text(error)}
                        }}
                    }
                }.checklistDisabled([(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)])
            }
            ForEach(model.types.filter {$0.string("state") == "retired"}) {type in
                Button("View retained rounds: "+type.string("title")) {historyType=type}
            }
            Text("Optional. Types appear only after you add one. Finish or cancel Draft and Open rounds before retiring their type. Originals and history are retained.").font(.caption).foregroundStyle(Color.checklistSecondaryText)
            if let error=model.error {Text(error).foregroundStyle(.orange)}
        }.task {if store.projectID == projectID {await model.connect(store:store)}}
        .checklistConfirmation($confirmation)
        .sheet(item:$historyType) {type in MediaRetainedHistory(type:type)}
    }
    static func schema(title:String,starter:String) -> MediaValues {
        var value:MediaValues=["schema_version":1,"id":"server-owned","name":title,"slots":[["id":"text","kind":"text","material":true],["id":"image","kind":"image","material":true]],"layout":["kind":"generic"]]
        if starter == "text" {value["slots"]=[["id":"text","kind":"text","required":true]];value["layout"]=["kind":"text_compare","primary_slot_id":"text"]}
        if starter == "animation" {
            value["fields"]=[["id":"character","kind":"short_text","material":true],["id":"animation_label","kind":"short_text","material":true],["id":"direction","kind":"choice","material":true,"choices":["N","NE","E","SE","S","SW","W","NW"]]]
            value["layout"]=["kind":"image_compare","primary_slot_id":"image"]
        }
        if starter == "video" || starter == "audio" {
            // CL-117: a candidate take and a declared reference of the same kind; portable IDs and kinds only.
            value["slots"]=[["id":"take","label":"Take","kind":starter,"material":true],["id":"reference","label":"Reference","kind":starter,"material":true]]
            value["layout"]=["kind":starter+"_compare","primary_slot_id":"take","reference_slot_id":"reference"]
        }
        return value
    }
}

struct MediaReviewWorkspace: View {
    @EnvironmentObject var store: ChecklistStore
    @ObservedObject var model: MediaReviewModel
    @State private var roundTitle=""
    @State private var itemTitle=""
    @State private var paste=""
    @State private var showPaste=false
    @State private var showList=false
    @State private var cancelReason=""
    @State private var confirmation: PendingConfirmation?
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            if model.hasMedia || model.historyOnly {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(model.enabledTypes) {type in
                            Button(type.string("title")) {model.chooseType(type.id)}
                                .accessibilityLabel("Review type: "+type.string("title"))
                                .accessibilityAddTraits(model.typeID == type.id ? .isSelected : [])
                        }
                    }
                }.fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("mediaTypeTabs")
                HStack {
                    Picker("Rounds",selection:$model.roundState) {ForEach(["draft","open","closed","canceled","archived"],id:\.self) {Text($0.capitalized).tag($0)}}.frame(maxWidth:160)
                        .onChange(of:model.roundState) {_,_ in model.roundOffset=0;Task {await model.refresh()}}
                    Picker("Round",selection:Binding(get:{model.roundID},set:{ model.chooseRound($0) })) {
                        Text("Choose round").tag("")
                        ForEach(model.rounds) {Text($0.string("title")).tag($0.id)}
                    }
                    if model.roundOffset>0 {Button("Previous rounds") {model.roundOffset=max(0,model.roundOffset-100);Task {await model.refresh()}}}
                    if model.roundsHaveMore {Button("More rounds") {model.roundOffset+=100;Task {await model.refresh()}}}
                    Button("Refresh") {Task {await model.refresh()}}.accessibilityLabel("Refresh media review")
                }
                if !model.historyOnly {HStack {
                    TextField("New round title",text:$roundTitle)
                    Button("Add Draft round") {model.createRound(title:roundTitle) {roundTitle=""}}.checklistDisabled([(roundTitle.isEmpty,"Enter a round title."),(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)])
                }}
                if let error=model.error {Text(error).foregroundStyle(.orange).textSelection(.enabled)}
                if model.loading {ProgressView("Refreshing media review")}
                if !model.roundID.isEmpty {
                    ScrollView {roundControls}.frame(minHeight:60,maxHeight:190).accessibilityLabel("Round setup and frozen intake")
                    HSplitView {
                        itemList.frame(minWidth:175,idealWidth:220)
                        ScrollView {MediaOwnerComparison(model:model).frame(maxWidth:.infinity,alignment:.leading).padding(8)}.frame(minWidth:280)
                    }.frame(minHeight:150).layoutPriority(1)
                } else {Text("Choose a round, or capture a title-only Draft round.").foregroundStyle(Color.checklistSecondaryText);Spacer()}
            } else {Spacer()} // No onboarding imposed on a project without enabled types.
        }.padding(12)
        .sheet(isPresented:$showPaste) {
            VStack(alignment:.leading) {
                Text("Paste text list").font(.headline)
                Text("One nonblank line per item. Text stays literal. TSV uses a header with text and optional title, group and slot columns.").font(.caption)
                TextEditor(text:$paste).frame(minWidth:440,minHeight:220).accessibilityLabel("Media intake text")
                HStack {
                    Button("Cancel") {showPaste=false}
                    Button("Preview lines") {model.previewIntake(["text":paste]);showPaste=false}
                    Button("Preview TSV") {model.previewIntake(["tsv":paste]);showPaste=false}
                }.checklistDisabled([(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)])
            }.padding(20)
        }
        .sheet(isPresented:$showList) {MediaListSettings(model:model)}
        .checklistConfirmation($confirmation)
    }
    var roundControls: some View {
        VStack(alignment:.leading,spacing:6) {
            Text(model.header.string("title")+" · "+GlossaryText.title(model.header.string("state"))).font(.headline)
            Text(MediaReviewModel.countsText(model.counts)).font(.caption)
            if model.writable {
                HStack {
                    TextField("New item title",text:$itemTitle)
                    Button("Add Draft item") {
                        model.createItem(title: itemTitle) { itemTitle = "" }
                    }.checklistDisabled([
                        (itemTitle.isEmpty, "Enter an item title."),
                        (store.writeBlockReason != nil, store.writeBlockReason ?? DisabledReasons.saving)
                    ])
                }
                ScrollView(.horizontal) {HStack {
                    Button("Add files…",action:addFiles)
                    Button("Paste text list…") {showPaste=true}
                    Button("Preview publication") {Task {await model.previewPublication()}}
                    Button("List settings") {showList=true}
                }.checklistDisabled([(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)])}.fixedSize(horizontal:false,vertical:true)
                ForEach(Array(model.header.records("intakes").enumerated()),id:\.element.id) {index,intake in
                    if model.intake.id != intake.id {Button("Resume intake "+String(index+1)+" · "+GlossaryText.title(intake.string("state"))) {Task {await model.resumeIntake(intake.id)}}}
                }
                if model.fields.contains(where:{$0.id=="character"}) {Toggle("Map character__animation_label__direction filename tokens",isOn:$model.mapsAnimationNames).font(.caption)}
                if let project=store.currentProject {Button("Approve current project context for media review") {model.mutate("media_context_approve",["kind":"project","expected_project_revision":project.integer("revision")])}.checklistDisabled([(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)])}
                if !model.intake.id.isEmpty {MediaFrozenIntakeView(model:model)}
                if !model.publication.isEmpty {
                    Text("Frozen publication preview · \(model.publication.count) items · \(model.publication.filter {!$0.bool("publication_ready")}.count) incomplete").font(.caption)
                    DisclosureGroup("Publication items") {
                        ScrollView {LazyVStack(alignment:.leading) {
                            ForEach(model.publication,id:\.publicationItemID) {row in
                                Text(row.string("title")+" · "+(row.bool("publication_ready") ? "Ready" : "Incomplete")).font(.caption).textSelection(.enabled)
                            }
                        }}.frame(maxHeight:120)
                    }
                    Button("Publish these \(model.publication.count) items") {model.publish()}.checklistDisabled([(model.publication.contains {!$0.bool("publication_ready")},"Capture all required originals before publication."),(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)])
                }
                DisclosureGroup("Cancel this round") {
                    TextField("Cancellation reason",text:$cancelReason)
                    Button("Cancel round and retain originals…") {confirmation = model.cancelRoundConfirmation(reason:cancelReason)}.checklistDisabled([(cancelReason.isEmpty,"Enter a cancellation reason."),(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)])
                }
            } else if !model.historyOnly && ["closed","canceled"].contains(model.header.string("state")) {
                Button("Archive round and retain originals…") {confirmation = model.archiveRoundConfirmation()}.checklistDisabled([(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)])
            }
            MediaRoundActions(model:model,confirmation:$confirmation)
            TechnicalDetails(raw: [("Round",model.header.values),("Publication preview",model.publication.map(\.values)),("Frozen intake",model.intake.values)]).id(model.roundID)
        }
    }
    var itemList: some View {
        VStack {
            Picker("Disposition filter",selection:$model.filter) {ForEach(["all","pending","accepted","needs_look","changes_requested","excluded","stale"],id:\.self) {Text($0.replacingOccurrences(of:"_",with:" ").capitalized).tag($0)}}
                .onChange(of:model.filter) {_,_ in Task {await model.reloadRows()}}
            ScrollViewReader {scroll in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:4) {
                        ForEach(MediaFlatRow.project(model.rows)) {row in
                            if let item=row.item {
                                Button {Task {await model.select(item.id)}} label: {
                                    VStack(alignment:.leading) {
                                        Text(row.title).lineLimit(2)
                                        Text(MediaReviewModel.dispositionLabel(item.string("disposition"))).font(.caption)
                                        Text((model.list["visible_columns"] as? [String] ?? item.object("metadata").keys.sorted()).compactMap {key in item.object("metadata")[key].map {key+": "+String(describing:$0)}}.joined(separator:" · ")).font(.caption2)
                                    }.frame(maxWidth:.infinity,alignment:.leading).padding(6)
                                        .background(model.selectedID==item.id ? Color.accentColor.opacity(0.16) : .clear,in:RoundedRectangle(cornerRadius:4))
                                }.buttonStyle(.plain).id(item.id)
                                    .accessibilityLabel(Self.rowLabel(item))
                                    .accessibilityAddTraits(model.selectedID==item.id ? .isSelected : [])
                            } else {Text(row.title).font(.caption.bold()).padding(.top,6).accessibilityAddTraits(.isHeader)}
                        }
                        if model.next != nil {Button("Load more items") {Task {await model.moreRows()}}}
                    }
                }.focusable().accessibilityLabel("Media item list. Up and Down Arrow select an item.")
                    .onKeyPress(.downArrow) {Task {await model.moveSelection(1)};return .handled}
                    .onKeyPress(.upArrow) {Task {await model.moveSelection(-1)};return .handled}
                    .onChange(of:model.selectedID) {_,id in scroll.scrollTo(id,anchor:.center)}
            }
            if model.selectedOutsideFilter {Text("Selected item is outside this filter. Its comparison stays open.").font(.caption)}
        }
    }
    static func rowLabel(_ item: Record) -> String {item.string("title")+", "+MediaReviewModel.dispositionLabel(item.string("disposition"))+", "+item.object("metadata").keys.sorted().map {"\($0) \(item.object("metadata")[$0]!)"}.joined(separator:", ")}
    func addFiles() {
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=true
        if panel.runModal() == .OK {model.previewIntake(["sources":panel.urls.map {["path":$0.path]}])}
    }
}

struct MediaListSettings: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var model: MediaReviewModel
    @State private var group1=""
    @State private var group2=""
    @State private var sort="order"
    @State private var columns=Set<String>()
    var body: some View {
        VStack(alignment:.leading) {
            Text("Media list display").font(.headline)
            groupPicker("First group",selection:$group1)
            groupPicker("Second group",selection:$group2)
            Picker("Order",selection:$sort) {Text("Capture order").tag("order");Text("Title").tag("title");ForEach(model.fields) {Text($0.id+" (declared order)").tag($0.id)}}
            ForEach(model.fields) {field in Toggle(field.id,isOn:Binding(get:{columns.contains(field.id)},set:{if $0 {columns.insert(field.id)} else {columns.remove(field.id)}}))}
            Text("These controls affect display only. Direction choices keep their declared order.").font(.caption)
            HStack {Button("Cancel") {dismiss()};Button("Apply display") {
                let fields=model.fields
                let groups=[group1,group2].filter {!$0.isEmpty}
                let order=fields.first {$0.id==sort}?.string("kind") == "choice" ? "declared_choice_order" : "ascending"
                model.list=["visible_columns":fields.filter {columns.contains($0.id)}.prefix(8).map(\.id),"group_by":Array(NSOrderedSet(array:groups)) as? [String] ?? [],"sort":[[sort=="order" || sort=="title" ? "key" : "field_id":sort,"order":order]]]
                Task {await model.reloadRows()};dismiss()
            }.checklistDisabled([(columns.count>8,"Choose at most eight visible columns.")])}
        }.padding(20).frame(minWidth:360).onAppear {
            let groups=model.list["group_by"] as? [String] ?? [];group1=groups.first ?? "";group2=groups.count>1 ? groups[1] : ""
            columns=Set(model.list["visible_columns"] as? [String] ?? [])
            let first=(model.list["sort"] as? [MediaValues])?.first;sort=first?["field_id"] as? String ?? first?["key"] as? String ?? "order"
        }
    }
    func groupPicker(_ title:String,selection:Binding<String>) -> some View {Picker(title,selection:selection) {Text("None").tag("");ForEach(model.fields) {Text($0.id).tag($0.id)}}}
}

struct MediaFrozenIntakeView: View {
    @EnvironmentObject var store: ChecklistStore
    @ObservedObject var model: MediaReviewModel
    @State private var groups:[String:String]=[:]
    static func editableGroup(_ row: Record, rows: [Record]) -> String {
        let group=row.string("group_id")
        return rows.contains {$0.id==group} ? "" : group
    }
    static func groupLabel(_ row: Record, rows: [Record]) -> String {
        let name=editableGroup(row,rows:rows)
        if !name.isEmpty {return "Candidate group: "+name}
        let first=rows.firstIndex {$0.string("group_id")==row.string("group_id")}
        return first.map {"Candidate group \($0+1)"} ?? "Separate candidate"
    }
    /// Declared slots of the row's measured kind; only rows the service can include (valid or duplicate) get a choice.
    static func includeChoices(_ row: Record, slots: [Record]) -> [(slot: Record, label: String)] {
        guard ["valid","duplicate"].contains(row.string("status")) else {return []}
        return slots.filter {$0.string("kind")==row.string("media_kind")}.map {slot in
            (slot,"Include as "+MediaComparisonLabels.slot(Record(values:["slot_id":slot.id,"media_kind":slot.string("kind")]),definitions:slots))
        }
    }
    var body: some View {
        DisclosureGroup("Frozen intake · \(model.intake.strings("committed_row_ids").count) captured · \(model.intake.strings("remaining_row_ids").count) remaining") {
            Text("Preview only until confirmation. Included, skipped and unresolved rows are explicit; duplicates stay separate unless you supply an explicit group in TSV. Capture never changes Finder originals.").font(.caption)
            ScrollView {LazyVStack(alignment:.leading) {
                ForEach(model.intake.records("rows")) {row in
                    VStack(alignment:.leading) {
                        Text(row.string("title")+" · "+row.string("status")+" · "+row.string("disposition")+" · "+row.string("capture_state"))
                        Text("Source: "+row.string("name")+" · "+MediaComparisonLabels.slot(row,definitions:model.slots)+" · "+Self.groupLabel(row,rows:model.intake.records("rows"))).font(.caption)
                        if row.string("capture_state") != "committed" {
                            HStack {
                                TextField("Explicit candidate group",text:Binding(get:{groups[row.id] ?? Self.editableGroup(row,rows:model.intake.records("rows"))},set:{groups[row.id]=$0})).accessibilityLabel("Candidate group for "+row.string("title"))
                                Button("Apply group") {model.resolveIntake(row,disposition:"include",slotID:row.string("slot_id").isEmpty ? nil : row.string("slot_id"),groupID:groups[row.id] ?? Self.editableGroup(row,rows:model.intake.records("rows")))}
                                    .checklistDisabled([((groups[row.id] ?? Self.editableGroup(row,rows:model.intake.records("rows"))).isEmpty,"Enter an explicit candidate group.")])
                            }
                            HStack {
                                Button("Skip") {model.resolveIntake(row,disposition:"skip")}
                                ForEach(Self.includeChoices(row,slots:model.slots),id:\.slot.id) {choice in
                                    Button(choice.label) {model.resolveIntake(row,disposition:"include",slotID:choice.slot.id)}
                                }
                            }
                        }
                        if !row.object("capture_error").isEmpty {Text(Record(values:row.object("capture_error")).string("message",fallback:"Capture did not finish. See Technical details for the recorded error.")).font(.caption).foregroundStyle(.orange)}
                    }.padding(4).accessibilityElement(children:.contain)
                }
            }}.frame(maxHeight:140)
            HStack {
                Button("Confirm frozen plan") {model.confirmIntake()}.checklistDisabled([(model.intake.records("rows").contains {!["include","skip"].contains($0.string("disposition"))},"Resolve every row to Include or Skip first.")])
                Button("Capture next \(min(200,model.intake.strings("remaining_row_ids").count)) remaining") {model.captureIntake()}.checklistDisabled([(model.intake.string("confirmed_plan_id") != model.intake.string("plan_id"),"Confirm the current frozen plan first."),(model.intake.strings("remaining_row_ids").isEmpty,"Every included row is already captured.")])
            }.checklistDisabled([(store.writeBlockReason != nil,store.writeBlockReason ?? DisabledReasons.saving)])
            Text("Stop between chunks by leaving this view. Resume this intake to capture only its remaining rows; committed Draft items stay captured.").font(.caption)
        }
    }
}

struct MediaRetainedHistory: View {
    @EnvironmentObject var store:ChecklistStore
    @Environment(\.dismiss) var dismiss
    let type:Record
    @StateObject private var history=MediaReviewModel()
    var body: some View {
        VStack(alignment:.leading) {
            HStack {Text("Retained media history: "+type.string("title")).font(.headline);Spacer();Button("Close") {dismiss()}}
            MediaReviewWorkspace(model:history)
        }.padding(12).frame(minWidth:800,minHeight:550)
        .task {await history.connect(store:store);history.historyOnly=true;history.typeID=type.id;history.roundState="canceled";await history.refresh()}
    }
}

private extension Record {var publicationItemID:String {string("item_id")}}
