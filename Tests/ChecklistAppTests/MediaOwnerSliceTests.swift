import XCTest
import SwiftUI
@testable import ChecklistApp
import ChecklistIPC
import CryptoKit
import ChecklistCore

@MainActor final class MediaOwnerSliceTests: XCTestCase {
    @MainActor final class Peer {
        var calls:[(String,MediaValues)]=[]
        var types:[MediaValues]=[]
        var rows:[MediaValues]=[]
        var secondPage:[MediaValues]=[]
        var roundRecords:[MediaValues]=[]
        var token="context-1",basis="basis-1",target="target-1"
        var reject=false
        var extra:[String:MediaValues]=[:]
        /// Replies served in order for one method before `extra` applies (CL-307 chunk loop).
        var sequence:[String:[MediaValues]]=[:]
        var onRequest:((String)->Void)?
        var itemDisposition="pending"
        var pageCounts:[String:Int]?
        var pending:[String:String]=[:]
        let project="synthetic-project"
        var schema:MediaValues=MediaTypeSettings.schema(title:"Animation",starter:"animation")
        func request(_ method:String,_ params:MediaValues) async throws -> MediaValues {
            calls.append((method,params));onRequest?(method)
            let value:MediaValues
            switch method {
            case "media_navigation":value=["types":types]
            case "media_round_create":
                let round:MediaValues=["id":"round-c","title":params["title"]!,"state":"draft","revision":1]
                roundRecords.append(round);value=round
            case "media_round_page" where !roundRecords.isEmpty:
                let matches=roundRecords.filter {$0["state"] as? String == params["state"] as? String}
                value=["rows":Array(matches.dropFirst(params["offset"] as? Int ?? 0).prefix(100)),"has_more":false]
            case "media_round_header" where !roundRecords.isEmpty:
                value=roundRecords.first {$0["id"] as? String == params["round_id"] as? String} ?? [:]
            case "media_round_page":value=["rows":[["id":"round","title":"Synthetic round","state":"open"]],"has_more":false]
            case "media_round_header":value=["id":"round","title":"Synthetic round","state":"open","revision":1,"observed_context_token":token,"manifest":["id":"manifest","digest":"digest"],"type_revision":["schema":schema],"attention":[],"attention_ids":[]]
            case "media_publication_preview":
                value=["round":["id":"round","state":"draft","revision":1,"observed_context_token":token],"items":[["item_id":"frozen-item","target_id":"frozen-target","expected_revision":1,"review_basis_signature":"frozen-basis","title":"Frozen item","publication_ready":true]]]
            case "media_item_page":
                let page=params["cursor"] as? String == "second" ? secondPage : rows
                var result:MediaValues=["rows":page,"counts":pageCounts ?? ["pending":rows.count+secondPage.count]]
                if params["cursor"] == nil && !secondPage.isEmpty {result["next_cursor"]="second"}
                value=result
            case "media_item_get":value=["id":params["item_id"]!,"title":"Exact item","published":true,"revision":1,"disposition":itemDisposition,"target":["id":target,"review_basis_signature":basis,"candidate_ids":["candidate"]],"candidates":[["id":"candidate","author_session_id":"human","origin":"human_ui","slots":[["slot_id":"text","text":"Exact text\r\n"]]]]]
            case "media_approved_examples":value=["examples":[["id":"historical","target_id":"historical","historical_context_label":"Historical owner-accepted example — no current approval","display_only":true,"grants_current_approval":false,"context_id":"historical-context","slots":[["slot_id":"text","text":"Past exact text"]]]]]
            case "media_decide":
                if reject {throw ChecklistError("MEDIA_CONTEXT_CHANGED","Approved context changed; no records changed.",details:["command_outcome":"rejected"])}
                value=["decisions":[["id":"owner-action","origin":"human_ui"]]]
            default:
                if var queue=sequence[method],!queue.isEmpty {value=queue.removeFirst();sequence[method]=queue} else {value=extra[method] ?? [:]}
            }
            return ["data":value]
        }
        func store(_ defaults:UserDefaults,_ directory:URL) -> ChecklistStore {
            let store=ChecklistStore(draftJournal:LocalDraftJournal(directory:directory),preferences:defaults,restorePendingCommand:false,
                desktopAlerts:DesktopAlertCoordinator(sink:MediaNoAlerts()),requestTransport:{[self] in try await request($0,$1)},navigationMemory:DetailItemNavigationMemory(),pendingCommandPersistence:PendingCommandPersistence(read:{[self] in pending[$0]},save:{[self] in pending[$1]=$0},remove:{[self] in pending.removeValue(forKey:$0)}))
            store.data=["service":["store_incarnation":"synthetic-media-store"]];store.connected=true;store.projectID=project;return store
        }
    }
    func fixture() -> (Peer,ChecklistStore,IsolatedDefaults,URL) {
        let defaults=isolatedDefaults("MediaOwner")
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {try? FileManager.default.removeItem(at:directory)}
        let peer=Peer();return (peer,peer.store(defaults.preferences,directory),defaults,directory)
    }
    func setup(_ peer:Peer,_ store:ChecklistStore) async -> MediaReviewModel {
        peer.types=[["id":"animation","title":"Animation","enabled":true],["id":"story","title":"Story","enabled":true]]
        let model=store.mediaReview;await model.connect(store:store);model.roundID="round";await model.refresh();return model
    }
    func settle(_ predicate:@escaping ()->Bool) async throws {
        for _ in 0..<200 {if predicate() {return};try await Task.sleep(nanoseconds:5_000_000)}
        XCTFail("Bounded synthetic action did not settle")
    }
    func testNoTypesNoMediaEntryAndTwoOptionalTabsWithoutTicketCaptureChanges() async {
        let (peer,store,_,_)=fixture(),model=store.mediaReview
        store.page = .tasks;await model.connect(store:store)
        XCTAssertFalse(model.hasMedia);XCTAssertEqual(store.page,.tasks);XCTAssertFalse(store.showCapture)
        _ = await setup(peer,store)
        XCTAssertEqual(model.enabledTypes.map(\.id),["animation","story"])
        XCTAssertEqual(model.typeID,"animation");XCTAssertEqual(store.page,.tasks)
        XCTAssertEqual(Page.tasks.title,"Tickets");XCTAssertEqual(Page.epics.title,"Epics")
    }
    func testCreatingDraftRoundFromOpenFilterSelectsDraftAndPickerChoice() async throws {
        let (peer,store,_,_)=fixture();let model=await setup(peer,store)
        peer.roundRecords=[["id":"round-b","title":"Round B","state":"open","revision":1]]
        model.roundState="open";model.roundID="round-b";await model.refresh()
        XCTAssertEqual(model.rounds.first?.string("title"),"Round B")
        model.roundOffset=100
        store.connected=true;peer.calls=[]
        var title="Round C"
        model.createRound(title:title) {title=""}
        try await settle {model.header.id=="round-c" && !model.loading && !store.busy}
        XCTAssertEqual(title,"")
        XCTAssertEqual(model.roundState,"draft")
        XCTAssertEqual(model.roundOffset,0)
        XCTAssertEqual(model.roundID,"round-c")
        XCTAssertEqual(model.header.string("state"),"draft")
        XCTAssertEqual(model.rounds.first {$0.id==model.roundID}?.string("title"),"Round C", "The selected ID must have the new title in the picker options")
        let creates=peer.calls.filter {$0.0=="media_round_create"}
        XCTAssertEqual(creates.count,1)
        XCTAssertEqual(creates.first?.1["title"] as? String,"Round C")
        XCTAssertEqual(creates.first?.1["type_id"] as? String,"animation")
    }
    func row(_ id:String,_ direction:String) -> MediaValues {
        ["id":id,"title":"Hero walk "+direction,"disposition":"pending","metadata":["direction":direction],"group_path":[["field_id":"character","value":"Hero","item_count":2],["field_id":"animation_label","value":"walk","item_count":2]]]
    }
    func testFlatVirtualizedRowsDeclaredOrderSelectionAndKeyboardAcrossLiveFilterUpdates() async throws {
        let (peer,store,_,_)=fixture();peer.rows=[row("north","N"),row("east","E")]
        let model=await setup(peer,store)
        let entries=MediaFlatRow.project(model.rows)
        XCTAssertEqual(entries.count,4);XCTAssertEqual(entries.compactMap {$0.item?.id},["north","east"])
        XCTAssertEqual((model.list["group_by"] as? [String]),["character","animation_label"])
        XCTAssertEqual((model.list["sort"] as? [MediaValues])?.first?["order"] as? String,"declared_choice_order")
        await model.moveSelection(1);XCTAssertEqual(model.selectedID,"north")
        await model.moveSelection(1);XCTAssertEqual(model.selectedID,"east")
        model.draft.note="Keep this note"
        peer.rows=[row("north","N")];model.filter="accepted";await model.reloadRows()
        XCTAssertEqual(model.selectedID,"east");XCTAssertTrue(model.selectedOutsideFilter);XCTAssertEqual(model.draft.note,"Keep this note")
        peer.rows=[row("north","N"),row("east","E")];await model.refresh()
        XCTAssertEqual(model.selectedID,"east");XCTAssertFalse(model.selectedOutsideFilter)
        XCTAssertEqual(MediaFlatRow.project(model.rows).map(\.id),entries.map(\.id))
        XCTAssertTrue(MediaReviewWorkspace.rowLabel(Record(values:row("east","E"))).contains("Pending"))
        XCTAssertTrue(MediaReviewWorkspace.rowLabel(Record(values:row("east","E"))).contains("direction E"))
    }
    func testShowHideIsReadOnlyAndExamplesKeepHistoricalContext() async {
        let (peer,store,_,_)=fixture();let model=await setup(peer,store);await model.select("item")
        peer.calls=[];await model.showExamples(true)
        XCTAssertEqual(model.examples.first?.string("context_id"),"historical-context")
        XCTAssertTrue(model.examples.first!.bool("display_only"));XCTAssertFalse(model.examples.first!.bool("grants_current_approval"))
        await model.showExamples(false)
        XCTAssertTrue(model.examples.isEmpty);XCTAssertEqual(peer.calls.map(\.0),["media_approved_examples"])
        XCTAssertEqual(model.item.string("disposition"),"pending")
    }
    func testExactOwnerActionsConflictPreservesDraftAcrossRefreshAndReopen() async throws {
        let (peer,store,defaults,directory)=fixture();let model=await setup(peer,store);await model.select("item")
        model.draft.note="Owner's unsent input";model.draft.winnerID="candidate";peer.reject=true
        model.decide("accepted");try await settle {model.contextConflict && !store.busy}
        let sent=try XCTUnwrap(peer.calls.first {$0.0=="media_decide"}?.1)
        XCTAssertEqual(sent["observed_context_token"] as? String,"context-1")
        XCTAssertEqual((sent["items"] as? [MediaValues])?.first?["target_id"] as? String,"target-1")
        XCTAssertEqual(sent["winner_id"] as? String,"candidate")
        XCTAssertEqual(model.draft.note,"Owner's unsent input")
        peer.token="context-2";peer.basis="basis-2";peer.target="target-2";await model.refresh()
        XCTAssertEqual(model.selectedID,"item");XCTAssertEqual(model.draft.note,"Owner's unsent input");XCTAssertTrue(model.contextConflict)
        model.reviewRefreshedContext();XCTAssertFalse(model.contextConflict);XCTAssertEqual(model.draft.basis,"basis-2")
        XCTAssertEqual(model.draft.note,"Owner's unsent input")
        let reopened=peer.store(defaults.preferences,directory);let restored=await setup(peer,reopened);await restored.select("item")
        XCTAssertEqual(restored.draft.note,"Owner's unsent input")
        peer.reject=false;store.connected=true;XCTAssertTrue(model.decisionEnabled);XCTAssertNil(store.writeBlockReason);model.decide("needs_look");try await settle {model.draft.note.isEmpty}
        XCTAssertEqual(peer.calls.last {$0.0=="media_decide"}?.1["disposition"] as? String,"needs_look")
    }
    func testFrozenPublicationDoesNotReselectFromChangedFilterOrContext() async throws {
        let (peer,store,_,_)=fixture();let model=await setup(peer,store)
        await model.previewPublication();peer.token="context-2";peer.rows=[];model.filter="accepted";await model.refresh()
        store.connected=true;model.publish();try await settle {peer.calls.contains {$0.0=="media_round_publish"}}
        let sent=try XCTUnwrap(peer.calls.last {$0.0=="media_round_publish"}?.1)
        XCTAssertEqual(sent["observed_context_token"] as? String,"context-1")
        let items=try XCTUnwrap(sent["items"] as? [MediaValues]);XCTAssertEqual(items.count,1)
        XCTAssertEqual(items[0]["item_id"] as? String,"frozen-item");XCTAssertEqual(items[0]["target_id"] as? String,"frozen-target")
        XCTAssertNil(items[0]["title"]);XCTAssertNil(items[0]["publication_ready"])
    }
    /// CL-307: one Capture press repeats the 200-row service chunks until no included row
    /// remains. The mock captures 200, then only 100, then the last 100 rows.
    func testOneCapturePressRepeatsChunksUntilNoRowRemains() async throws {
        let (peer,store,_,_)=fixture();let model=await setup(peer,store)
        let ids=(0..<400).map {"row-"+String($0)}
        func intake(_ revision:Int,remaining:Int) -> MediaValues {
            ["id":"intake","revision":revision,"plan_id":"plan","confirmed_plan_id":"plan","state":remaining == 0 ? "captured" : "partial",
             "committed_row_ids":Array(ids.prefix(400-remaining)),"remaining_row_ids":Array(ids.suffix(remaining))]
        }
        peer.sequence["media_intake_capture"]=[intake(2,remaining:200),intake(3,remaining:100),intake(4,remaining:0)]
        model.intake=Record(values:intake(1,remaining:400));store.connected=true
        model.captureIntake()
        try await settle {model.intake.strings("remaining_row_ids").isEmpty && !store.busy}
        let sent=peer.calls.filter {$0.0=="media_intake_capture"}.map(\.1)
        XCTAssertEqual(sent.count,3)
        XCTAssertEqual(sent.map {$0["expected_revision"] as? Int},[1,2,3])
        XCTAssertEqual(sent.map {($0["row_ids"] as? [String])?.count},[200,200,100])
        XCTAssertEqual(sent.map {($0["row_ids"] as? [String])?.first},["row-0","row-200","row-300"])
        XCTAssertEqual(Set(sent.compactMap {$0["command_id"] as? String}).count,3)
        XCTAssertEqual(model.intake.strings("committed_row_ids").count,400);XCTAssertNil(store.error);XCTAssertFalse(model.capturing)
        // V43A: after a long chunk the store was not writable when the reply arrived (here:
        // offline until a reconnect). The sequence waits and continues; it does not stop.
        let ids2=(0..<300).map {"next-"+String($0)}
        func next(_ revision:Int,remaining:Int) -> MediaValues {
            ["id":"intake-2","revision":revision,"plan_id":"plan","confirmed_plan_id":"plan","committed_row_ids":Array(ids2.prefix(300-remaining)),"remaining_row_ids":Array(ids2.suffix(remaining))]
        }
        peer.sequence["media_intake_capture"]=[next(2,remaining:100),next(3,remaining:0)]
        peer.onRequest={method in if method=="media_intake_capture" && peer.sequence["media_intake_capture"]?.count == 2 {store.connected=false}}
        model.intake=Record(values:next(1,remaining:300));model.captureIntake()
        try await settle {model.intake.strings("remaining_row_ids").count == 100 && !store.busy}
        XCTAssertTrue(model.capturing);try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertEqual(peer.calls.filter {$0.0=="media_intake_capture"}.count,4)
        store.connected=true
        try await settle {model.intake.strings("remaining_row_ids").isEmpty && !store.busy}
        XCTAssertEqual(peer.calls.filter {$0.0=="media_intake_capture"}.map {($0.1["row_ids"] as? [String])?.first},["row-0","row-200","row-300","next-0","next-200"])
        XCTAssertFalse(model.capturing)
    }
    func testFrozenIntakeGroupResolutionIsExplicitAndRevisionChecked() async throws {
        let (peer,store,_,_)=fixture();let model=await setup(peer,store)
        model.intake=Record(values:["id":"intake","revision":7]);store.connected=true
        model.resolveIntake(Record(values:["id":"source-row"]),disposition:"include",slotID:"image",groupID:"explicit-takes")
        try await settle {peer.calls.contains {$0.0=="media_intake_revise"}}
        let sent=try XCTUnwrap(peer.calls.last {$0.0=="media_intake_revise"}?.1)
        XCTAssertEqual(sent["expected_revision"] as? Int,7)
        let resolution=try XCTUnwrap((sent["resolutions"] as? [MediaValues])?.first)
        XCTAssertEqual(resolution["row_id"] as? String,"source-row");XCTAssertEqual(resolution["group_id"] as? String,"explicit-takes")
        XCTAssertEqual(resolution["slot_id"] as? String,"image");XCTAssertEqual(resolution["disposition"] as? String,"include")
    }
    func testVideoAndAudioStartersOfferIncludeForValidRowsAndSendTheExactSlot() async throws {
        let (peer,store,_,_)=fixture();peer.schema=MediaTypeSettings.schema(title:"Takes",starter:"video");let model=await setup(peer,store)
        XCTAssertEqual(model.slots.map(\.id),["take","reference"]);XCTAssertEqual(model.slots.map {$0.string("kind")},["video","video"])
        XCTAssertEqual(model.referenceSlotID,"reference")
        let movie=Record(values:["id":"movie-row","media_kind":"video","status":"valid","disposition":"unresolved"])
        let choices=MediaFrozenIntakeView.includeChoices(movie,slots:model.slots)
        XCTAssertEqual(choices.map(\.label),["Include as Take","Include as Reference"])
        XCTAssertEqual(MediaFrozenIntakeView.includeChoices(Record(values:["id":"dup","media_kind":"video","status":"duplicate"]),slots:model.slots).count,2)
        XCTAssertTrue(MediaFrozenIntakeView.includeChoices(Record(values:["id":"wav","media_kind":"audio","status":"valid"]),slots:model.slots).isEmpty,"A video type offers no audio slot")
        XCTAssertTrue(MediaFrozenIntakeView.includeChoices(Record(values:["id":"long","media_kind":"video","status":"unsupported"]),slots:model.slots).isEmpty,"Unsupported rows offer Skip only")
        model.intake=Record(values:["id":"intake","revision":4])
        model.resolveIntake(movie,disposition:"include",slotID:choices[0].slot.id)
        try await settle {peer.calls.contains {$0.0=="media_intake_revise"}}
        let sent=try XCTUnwrap(peer.calls.last {$0.0=="media_intake_revise"}?.1)
        XCTAssertEqual(sent["expected_revision"] as? Int,4)
        let resolution=try XCTUnwrap((sent["resolutions"] as? [MediaValues])?.first)
        XCTAssertEqual(resolution["row_id"] as? String,"movie-row");XCTAssertEqual(resolution["slot_id"] as? String,"take");XCTAssertEqual(resolution["disposition"] as? String,"include")
        let audioSlots=(MediaTypeSettings.schema(title:"Voice",starter:"audio")["slots"] as? [MediaValues] ?? []).map {Record(values:$0)}
        let wav=Record(values:["id":"wav-row","media_kind":"audio","status":"valid"])
        XCTAssertEqual(MediaFrozenIntakeView.includeChoices(wav,slots:audioSlots).map(\.label),["Include as Take","Include as Reference"])
        XCTAssertTrue(MediaFrozenIntakeView.includeChoices(movie,slots:audioSlots).isEmpty,"An audio type offers no video slot")
        XCTAssertEqual(MediaComparisonLabels.role(slotID:"reference",candidateIndex:0,referenceSlotID:model.referenceSlotID,historical:false),"Reference")
        XCTAssertEqual(MediaComparisonLabels.role(slotID:"take",candidateIndex:0,referenceSlotID:model.referenceSlotID,historical:false),"Candidate 1")
    }
    func testLoadedPagesKeepSelectedAnchorAndImageReadsHaveTwoJobBound() async {
        let (peer,store,_,_)=fixture();peer.rows=[row("north","N")];peer.secondPage=[row("east","E")]
        let model=await setup(peer,store);await model.moreRows();await model.select("east")
        await model.refresh()
        XCTAssertEqual(model.rows.map(\.id),["north","east"]);XCTAssertEqual(model.selectedID,"east");XCTAssertFalse(model.selectedOutsideFilter)
        XCTAssertTrue(model.beginImage("current-1",historical:false))
        XCTAssertTrue(model.beginImage("historical-1",historical:true))
        XCTAssertFalse(model.beginImage("excess",historical:false))
        model.endImage();XCTAssertTrue(model.beginImage("current-2",historical:false))
        XCTAssertFalse(model.imageIsActive("current-1",historical:false));XCTAssertTrue(model.imageIsActive("current-2",historical:false))
        model.endImage();model.endImage();XCTAssertEqual(model.imageLoads,0)
        await model.showExamples(false);XCTAssertFalse(model.imageIsActive("historical-1",historical:true))
    }
    func assertConfirmation(_ make: () -> PendingConfirmation, method: String, object: String, peer: Peer, store: ChecklistStore) async throws -> MediaValues {
        peer.calls=[]
        var pending: PendingConfirmation?=make()
        XCTAssertTrue(pending!.title.contains(object))
        XCTAssertTrue(pending!.cancelIsDefault, "Cancel must be the default native dialog action")
        XCTAssertTrue(pending!.effect.contains("originals"))
        XCTAssertTrue(pending!.effect.contains("history"))
        XCTAssertTrue(peer.calls.isEmpty, "Opening the dialog must not send the command")
        PendingConfirmation.resolve(Binding(get:{pending},set:{pending=$0}),confirmed:false)
        XCTAssertNil(pending, "The shared Escape/Keep path dismisses the confirmation")
        await Task.yield()
        XCTAssertTrue(peer.calls.isEmpty, "Cancel must send nothing")
        XCTAssertFalse(store.busy)
        pending=make()
        XCTAssertTrue(peer.calls.isEmpty)
        pending!.respond(confirmed:true)
        try await settle {peer.calls.contains {$0.0==method} && !store.busy}
        let calls=peer.calls.filter {$0.0==method}
        XCTAssertEqual(calls.count,1)
        return try XCTUnwrap(calls.first?.1)
    }
    func testRetireTypeWaitsForNativeConfirmationAndCancelSendsNothing() async throws {
        let (peer,store,_,_)=fixture();let model=await setup(peer,store)
        let type=Record(values:["id":"exact-type","title":"Hero animation","revision":7])
        let sent=try await assertConfirmation({model.retireTypeConfirmation(type)},method:"media_type_retire",object:"Hero animation",peer:peer,store:store)
        XCTAssertEqual(sent["type_id"] as? String,"exact-type")
        XCTAssertEqual(sent["expected_revision"] as? Int,7)
    }
    func testCancelRoundWaitsForNativeConfirmationAndCancelSendsNothing() async throws {
        let (peer,store,_,_)=fixture();let model=await setup(peer,store)
        let sent=try await assertConfirmation({model.cancelRoundConfirmation(reason:"Superseded by the new direction")},method:"media_round_cancel",object:"Synthetic round",peer:peer,store:store)
        XCTAssertEqual(sent["round_id"] as? String,"round")
        XCTAssertEqual(sent["reason"] as? String,"Superseded by the new direction")
        XCTAssertEqual(sent["expected_revision"] as? Int,1)
    }
    func testArchiveRoundWaitsForNativeConfirmationAndCancelSendsNothing() async throws {
        let (peer,store,_,_)=fixture();let model=await setup(peer,store)
        model.header=Record(values:["id":"round","title":"Finished round","state":"closed","revision":9])
        let sent=try await assertConfirmation({model.archiveRoundConfirmation()},method:"media_round_archive",object:"Finished round",peer:peer,store:store)
        XCTAssertEqual(sent["round_id"] as? String,"round")
        XCTAssertEqual(sent["expected_revision"] as? Int,9)
    }
    func testRoundConfirmationKeepsDisplayedObjectAndRevisionAcrossRefresh() async throws {
        let (peer,store,_,_)=fixture();let model=await setup(peer,store)
        let pending=model.cancelRoundConfirmation(reason:"Original reason")
        model.roundID="another-round";model.header=Record(values:["id":"another-round","title":"Another round","revision":99])
        store.connected=true;peer.calls=[];pending.respond(confirmed:true)
        try await settle {peer.calls.contains {$0.0=="media_round_cancel"}}
        let sent=try XCTUnwrap(peer.calls.first {$0.0=="media_round_cancel"}?.1)
        XCTAssertEqual(sent["round_id"] as? String,"round")
        XCTAssertEqual(sent["expected_revision"] as? Int,1)
        XCTAssertEqual(sent["reason"] as? String,"Original reason")
    }
    func testComparisonAndWinnerLabelsUseTitleOriginTimeAndSlotWithoutTechnicalIdentity() throws {
        let candidateID="6167d5d8-31b1-48ab-8499-639a494c60f4",slotID="6e0c4dd3-efe7-4e96-b40b-454af7c475eb"
        let hash=String(repeating:"abc123ef",count:8),author="auto-codex/00000000-0000-0000-0000-000000000001"
        let slot=Record(values:["slot_id":slotID,"media_kind":"image","sha256":hash])
        let definitions=[Record(values:["id":slotID,"label":"Walk north","kind":"image"])]
        let candidate:MediaValues=["id":candidateID,"source_name":"hero-walk.png","origin":"agent","author_session_id":author,"created_at":"2026-10-21T12:00:00Z","slots":[slot.values],"content_signature":hash]
        let item=Record(values:["id":UUID().uuidString,"title":"Hero walk","candidates":[candidate,candidate.merging(["id":UUID().uuidString]) {_,new in new}],"target":["id":UUID().uuidString,"review_basis_signature":hash]])
        let choices=MediaComparisonLabels.choices(item:item,definitions:definitions)
        XCTAssertEqual(choices.count,2)
        XCTAssertEqual(choices[0].id,candidateID,"Exact winner binding is retained")
        XCTAssertNotEqual(choices[0].label,choices[1].label,"Capture order disambiguates identical sources and times")
        for (index,choice) in choices.enumerated() {
            for label in ["Candidate \(index+1)","Hero walk","hero-walk.png","Agent capture",MediaComparisonLabels.time("2026-10-21T12:00:00Z"),"Walk north"] {XCTAssertTrue(choice.label.contains(label),label)}
            for technical in [candidateID,slotID,hash,author] {XCTAssertFalse(choice.label.contains(technical),technical)}
        }
        let imageLabel=MediaComparisonLabels.imageAccessibilityLabel(slot,definitions:definitions)
        XCTAssertEqual(imageLabel,"Verified original image, Walk north")
        XCTAssertFalse(imageLabel.contains(slotID));XCTAssertFalse(imageLabel.contains(hash))
        XCTAssertEqual(MediaComparisonLabels.slot(Record(values:["slot_id":slotID,"text":"literal"]),definitions:[]),"Text slot")
        XCTAssertEqual(MediaComparisonLabels.origin("human_ui"),"Owner")
        XCTAssertEqual(MediaComparisonLabels.slot(slot,definitions:[Record(values:["id":slotID,"label":slotID,"kind":"image"])]),"Image slot 1")
        let context=Record(values:["approved_context":["brief":"Use the green palette","brief_revision":8,"pinned_decisions":[["id":candidateID,"title":"Style","body":"Keep the silhouette","sha256":hash]]]])
        XCTAssertEqual(MediaComparisonLabels.context(context),"Use the green palette\n\nStyle: Keep the silhouette")
        let intakeRow=Record(values:["id":candidateID,"group_id":candidateID])
        XCTAssertEqual(MediaFrozenIntakeView.groupLabel(intakeRow,rows:[intakeRow]),"Candidate group 1")
        XCTAssertEqual(MediaFrozenIntakeView.editableGroup(intakeRow,rows:[intakeRow]),"")
        let explicitGroup=Record(values:["id":candidateID,"group_id":"Hero walk"])
        XCTAssertEqual(MediaFrozenIntakeView.groupLabel(explicitGroup,rows:[explicitGroup]),"Candidate group: Hero walk")
        XCTAssertEqual(MediaFrozenIntakeView.editableGroup(explicitGroup,rows:[explicitGroup]),"Hero walk")
        let details=TechnicalDetails(raw:[("Selected media and candidates",item.values)])
        let raw=ReviewProjection.readableJSON(details.raw[0].value)
        XCTAssertTrue(raw.contains(candidateID));XCTAssertTrue(raw.contains(hash))
        let rendered=Record(values:try XCTUnwrap(JSONSerialization.jsonObject(with:Data(raw.utf8)) as? MediaValues))
        XCTAssertEqual(rendered.records("candidates").first?.string("author_session_id"),author)
    }
    func testMediaViewsWireSharedDialogsAndKeepTechnicalMetadataCollapsed() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/ChecklistApp")
        let workspace=try String(contentsOf:root.appendingPathComponent("Media/MediaReviewWorkspace.swift"),encoding:.utf8)
        for action in ["confirmation = model.retireTypeConfirmation(type)","confirmation = model.cancelRoundConfirmation(reason:cancelReason)","confirmation = model.archiveRoundConfirmation()"] {XCTAssertTrue(workspace.contains(action),action)}
        XCTAssertEqual(workspace.components(separatedBy:".checklistConfirmation($confirmation)").count-1,2)
        for command in ["media_type_retire","media_round_cancel","media_round_archive"] {XCTAssertFalse(workspace.contains("model.mutate(\""+command+"\""),command)}
        let comparison=try String(contentsOf:root.appendingPathComponent("Media/MediaOwnerComparison.swift"),encoding:.utf8)
        for technical in ["Text(\"Target:","Text(\"Basis:","Text(\"Round:","Text(\"Attention:","SHA-256: ",".id.prefix(","string(\"author_session_id\")","string(\"decision_author_session_id\")"] {XCTAssertFalse(comparison.contains(technical),technical)}
        XCTAssertTrue(comparison.contains("Text(choice.label).tag(choice.id).accessibilityLabel(choice.label)"))
        XCTAssertTrue(comparison.contains("Text(choice.label).font(.headline).accessibilityLabel(choice.label)"))
        XCTAssertEqual(comparison.components(separatedBy:"TechnicalDetails(raw:").count-1,1)
        XCTAssertTrue(workspace.contains("TechnicalDetails(raw: [(\"Round\",model.header.values)"))
        for technical in [" · Revision ","intake.id.prefix(","row.string(\"target_id\")"] {XCTAssertFalse(workspace.contains(technical),technical)}
        let dialogs=try String(contentsOf:root.appendingPathComponent("Support/Confirmations.swift"),encoding:.utf8)
        XCTAssertTrue(dialogs.contains(".onExitCommand { PendingConfirmation.resolve(pending, confirmed: false) }"))
        XCTAssertTrue(workspace.contains("model.createRound(title:roundTitle)"))
        let details=try String(contentsOf:root.appendingPathComponent("Support/TechnicalDetails.swift"),encoding:.utf8)
        XCTAssertTrue(details.contains("DisclosureGroup(\"Technical details\")"))
        XCTAssertFalse(details.contains("isExpanded:"),"Shared technical details start collapsed")
    }
    func testImageDecoderRequiresExactDigestAndDecodesActualBoundedOriginal() async throws {
        let bytes=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let digest=SHA256.hash(data:bytes).map {String(format:"%02x",$0)}.joined()
        let image=try await MediaImageDecode.decode(bytes,sha256:digest)
        XCTAssertEqual(image.size.width,1);XCTAssertEqual(image.size.height,1)
        do {_ = try await MediaImageDecode.decode(bytes,sha256:String(repeating:"0",count:64));XCTFail("Changed bytes must refuse")} catch {}
    }
    func testComparisonAvailabilityExactTextUnavailableOversizedAndUnsupportedOriginals() {
        let text="literal\r\n\nUnicode e\u{301}"
        XCTAssertEqual(MediaComparisonAvailability.resolve(slot:Record(values:["text":text]),original:nil),.text(text))
        let image=Record(values:["media_kind":"image"])
        if case .unavailable = MediaComparisonAvailability.resolve(slot:image,original:nil) {} else {XCTFail("Missing original")}
        XCTAssertEqual(MediaComparisonAvailability.resolve(slot:image,original:Record(values:["availability":"available","size":100])),.image)
        if case .unsupported = MediaComparisonAvailability.resolve(slot:image,original:Record(values:["availability":"available","size":9*1024*1024])) {} else {XCTFail("Bounded image")}
        for kind in ["audio","video"] {
            let slot=Record(values:["media_kind":kind])
            XCTAssertEqual(MediaComparisonAvailability.resolve(slot:slot,original:nil),.unavailable(MediaComparisonAvailability.unavailableText(nil)))
            XCTAssertEqual(MediaComparisonAvailability.resolve(slot:slot,original:Record(values:["availability":"available","size":100]),declaredKind:kind),.playback(kind))
            if case .unsupported(let label)=MediaComparisonAvailability.resolve(slot:slot,original:Record(values:["availability":"available","size":MediaPlaybackBudget.originalBytes+1])) {XCTAssertTrue(label.contains("500 MiB"),label)} else {XCTFail(kind)}
            if case .unsupported(let label)=MediaComparisonAvailability.resolve(slot:slot,original:Record(values:["availability":"available","size":100]),declaredKind:"image") {XCTAssertTrue(label.contains("declares image"),label)} else {XCTFail(kind)}
            for (reason,text) in [("cleaned","Original cleaned."),("missing","Original missing"),("changed","Original changed"),("reference_unavailable","Original reference unavailable")] {
                if case .unavailable(let label)=MediaComparisonAvailability.resolve(slot:slot,original:Record(values:["availability":"unavailable","unavailable_reason":reason])) {XCTAssertTrue(label.hasPrefix(text),label)} else {XCTFail(reason)}
            }
        }
        XCTAssertEqual(MediaComparisonLabels.role(slotID:"reference",candidateIndex:0,referenceSlotID:"reference",historical:false),"Reference")
        XCTAssertEqual(MediaComparisonLabels.role(slotID:"take",candidateIndex:1,referenceSlotID:"reference",historical:false),"Candidate 2")
        XCTAssertEqual(MediaComparisonLabels.role(slotID:"take",candidateIndex:nil,referenceSlotID:"",historical:true),"Approved example · Candidate")
    }
}
@MainActor private final class MediaNoAlerts:DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization {.denied}
    func requestAuthorizationFromOwnerAction() async throws -> Bool {false}
    func send(_ alert:DesktopAlert) async throws {}
    func remove(_ identifiers:[String]) {}
}
