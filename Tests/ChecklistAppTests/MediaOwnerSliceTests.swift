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
        /// Errors served in order for one method (CL-318 lost chunk reply).
        var failures:[String:[Error]]=[:]
        /// CL-315: the recovery journal cannot save, so ChecklistStore.run returns before sending.
        var saveFails=false
        var itemDisposition="pending"
        var pageCounts:[String:Int]?
        var pending:[String:String]=[:]
        let project="synthetic-project"
        var schema:MediaValues=MediaTypeSettings.schema(title:"Animation",starter:"animation")
        func request(_ method:String,_ params:MediaValues) async throws -> MediaValues {
            calls.append((method,params));onRequest?(method)
            if var queue=failures[method],!queue.isEmpty {let failure=queue.removeFirst();failures[method]=queue;throw failure}
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
                desktopAlerts:DesktopAlertCoordinator(sink:MediaNoAlerts()),requestTransport:{[self] in try await request($0,$1)},navigationMemory:DetailItemNavigationMemory(),pendingCommandPersistence:PendingCommandPersistence(read:{[self] in pending[$0]},save:{[self] in if saveFails {throw ChecklistError("SAVE_FAILED","Synthetic journal failure.")};pending[$1]=$0},remove:{[self] in pending.removeValue(forKey:$0)}))
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
        peer.reject=false;store.connected=true;XCTAssertTrue(model.decisionEnabled);XCTAssertNil(store.writeBlockReason);model.decide("needs_look");try await settle {peer.calls.filter {$0.0=="media_decide"}.count==2 && !store.busy}
        XCTAssertEqual(model.draft.note,"Owner's unsent input")
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
    /// CL-315 (V42B): the store identity is empty for a moment after a media write. The second
    /// chunk waits for a known identity and is then sent; one press still captures every row.
    func testOneCapturePressWaitsForTheStoreIdentityBetweenChunks() async throws {
        let (peer,store,_,_)=fixture();let model=await setup(peer,store)
        let ids=(0..<300).map {"row-"+String($0)}
        func intake(_ revision:Int,remaining:Int) -> MediaValues {
            ["id":"intake","revision":revision,"plan_id":"plan","confirmed_plan_id":"plan","committed_row_ids":Array(ids.prefix(300-remaining)),"remaining_row_ids":Array(ids.suffix(remaining))]
        }
        peer.sequence["media_intake_capture"]=[intake(2,remaining:100),intake(3,remaining:0)]
        peer.onRequest={method in if method=="media_intake_capture" {store.data=["service":[String:Any]()]}}
        model.intake=Record(values:intake(1,remaining:300));store.connected=true;model.error=nil
        model.captureIntake()
        try await settle {model.intake.strings("remaining_row_ids").count == 100 && !store.busy}
        try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertEqual(store.writeBlockReason,DisabledReasons.storeUnknown)
        XCTAssertTrue(model.capturing,"The sequence waits; it does not stop or send into an unknown store")
        XCTAssertEqual(peer.calls.filter {$0.0=="media_intake_capture"}.count,1)
        XCTAssertNil(model.error);XCTAssertNil(store.error)
        peer.onRequest=nil;store.data=["service":["store_incarnation":"synthetic-media-store"]]
        try await settle {model.intake.strings("remaining_row_ids").isEmpty && !store.busy && !model.capturing}
        let sent=peer.calls.filter {$0.0=="media_intake_capture"}.map(\.1)
        XCTAssertEqual(sent.map {($0["row_ids"] as? [String])?.count},[200,100])
        XCTAssertEqual(sent.map {$0["expected_revision"] as? Int},[1,2])
        XCTAssertNil(model.error);XCTAssertNil(store.error)
    }
    /// CL-315: every early return of ChecklistStore.run reaches the caller's failure path, so a
    /// capture that cannot start ends with a visible error and the Capture button enabled.
    func testRunThatReturnsEarlyEndsCaptureWithVisibleErrorAndReachesEveryCaller() async throws {
        let (peer,store,_,_)=fixture();let model=await setup(peer,store)
        let ids=(0..<300).map {"row-"+String($0)}
        model.intake=Record(values:["id":"intake","revision":1,"plan_id":"plan","confirmed_plan_id":"plan","remaining_row_ids":ids]);store.connected=true
        peer.saveFails=true
        model.captureIntake()
        XCTAssertFalse(model.capturing,"The Capture button is enabled again (it is disabled only while capturing)")
        XCTAssertTrue(model.error?.contains("Cannot preserve the command") == true,model.error ?? "no error")
        XCTAssertFalse(peer.calls.contains {$0.0=="media_intake_capture"});XCTAssertFalse(store.busy)
        peer.saveFails=false;model.error=nil;store.error=nil
        // A press while the identity is unknown shows why and leaves the button enabled.
        store.data=["service":[String:Any]()]
        model.captureIntake()
        XCTAssertFalse(model.capturing);XCTAssertEqual(store.notice,DisabledReasons.storeUnknown)
        // Other callers: unknown identity, offline and a busy store all reach the failure path.
        var failures:[String]=[]
        store.run("task_create",["project_id":peer.project],failure:{failures.append(($0 as? ChecklistError)?.code ?? "")})
        store.data=["service":["store_incarnation":"synthetic-media-store"]];store.connected=false
        store.run("task_create",["project_id":peer.project],failure:{failures.append(($0 as? ChecklistError)?.message ?? "")})
        store.connected=true;store.busy=true
        store.run("task_create",["project_id":peer.project],failure:{failures.append(($0 as? ChecklistError)?.message ?? "")})
        store.busy=false
        XCTAssertEqual(failures,["WRITE_NOT_STARTED",DisabledReasons.offline,DisabledReasons.saving])
        XCTAssertFalse(peer.calls.contains {$0.0=="task_create"});XCTAssertFalse(store.hasPendingMutation)
        // A later press in the same app session captures normally.
        peer.sequence["media_intake_capture"]=[["id":"intake","revision":2,"plan_id":"plan","confirmed_plan_id":"plan","remaining_row_ids":Array(ids.suffix(100))],["id":"intake","revision":3,"plan_id":"plan","confirmed_plan_id":"plan","remaining_row_ids":[String]()]]
        model.captureIntake()
        try await settle {model.intake.strings("remaining_row_ids").isEmpty && !store.busy && !model.capturing}
        XCTAssertEqual(peer.calls.filter {$0.0=="media_intake_capture"}.count,2);XCTAssertNil(model.error)
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
        XCTAssertTrue(model.imageIsActive("current-1",historical:false));XCTAssertTrue(model.imageIsActive("current-2",historical:false))
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

/// CL-427: the round names its ticket, the owner links it and sends the results to it.
/// Synthetic peer replies only. No native app, service, keychain or decoder.
extension MediaOwnerSliceTests {
    private static let sentAt="2026-11-03T02:12:00Z"
    private func linkedHeader(task: MediaValues?,last: MediaValues? = nil,state: String = "open") -> MediaValues {
        var header:MediaValues=["id":"round","title":"Behemoth walk: whole paws","state":state,"revision":5,"observed_context_token":"context-1","manifest":["id":"manifest","digest":"digest"],
            "type_revision":["schema":MediaTypeSettings.schema(title:"Animation",starter:"animation")],"attention":[],"attention_ids":[],"task":task ?? NSNull()]
        if let last {header["last_result_sent"]=last}
        return header
    }
    private static let heir130:MediaValues=["id":"task-130","key":"HEIR-130","title":"Behemoth walk","status_name":"In progress"]
    private func decided(_ id: String,decision: String,disposition: String = "accepted") -> MediaValues {
        ["id":id,"title":"Behemoth walk "+id,"disposition":disposition,"decision_id":decision,"metadata":["direction":"N"]]
    }
    private func linkedSetup(task: MediaValues?,last: MediaValues? = nil,rows: [MediaValues] = [],state: String = "open") async -> (Peer,ChecklistStore,MediaReviewModel) {
        let (peer,store,_,_)=fixture()
        peer.roundRecords=[linkedHeader(task:task,last:last,state:state)];peer.rows=rows
        peer.pageCounts=rows.isEmpty ? ["pending":1] : ["accepted":rows.count]
        let model=await setup(peer,store)
        return (peer,store,model)
    }
    func testRoundHeaderNamesItsTicketInPlainWords() async {
        XCTAssertEqual(MediaReviewModel.ticketLine(Record(values:linkedHeader(task:Self.heir130))),"For HEIR-130 — Behemoth walk")
        XCTAssertEqual(MediaReviewModel.ticketLine(Record(values:linkedHeader(task:nil))),"No ticket")
        XCTAssertEqual(MediaReviewModel.ticketLine(Record(values:[:])),"No ticket")
        let (_,_,model)=await linkedSetup(task:Self.heir130)
        XCTAssertEqual(MediaReviewModel.ticketLine(model.header),"For HEIR-130 — Behemoth walk")
        XCTAssertEqual(model.linkedTask.string("key"),"HEIR-130")
        XCTAssertTrue(model.ticketChangeAvailable)
        // No ticket, or no owner decision: the send action is hidden.
        XCTAssertNil(model.resultAction,"No owner decision yet")
        let (_,_,unlinked)=await linkedSetup(task:nil,rows:[decided("a",decision:"d1")])
        XCTAssertEqual(MediaReviewModel.ticketLine(unlinked.header),"No ticket");XCTAssertNil(unlinked.resultAction)
        // A closed round keeps its ticket line but offers no ticket change.
        let (_,_,closed)=await linkedSetup(task:Self.heir130,rows:[decided("a",decision:"d1")],state:"closed")
        XCTAssertFalse(closed.ticketChangeAvailable);XCTAssertEqual(closed.resultAction?.label,"Send results to HEIR-130")
    }
    func testOwnerLinksAndRemovesTheTicketWithTheRoundRevision() async throws {
        let (peer,store,model)=await linkedSetup(task:nil)
        store.connected=true;peer.calls=[]
        model.linkTask("task-130")
        try await settle {peer.calls.contains {$0.0=="media_round_link_task"} && !store.busy}
        let link=try XCTUnwrap(peer.calls.first {$0.0=="media_round_link_task"}?.1)
        XCTAssertEqual(link["round_id"] as? String,"round");XCTAssertEqual(link["expected_revision"] as? Int,5)
        XCTAssertEqual(link["task_id"] as? String,"task-130");XCTAssertEqual(link["project_id"] as? String,peer.project)
        let removal=MediaReviewModel.linkTaskParams(header:model.header,taskID:nil)
        XCTAssertTrue(removal["task_id"] is NSNull,"No ticket sends task_id null")
        // A refusal shows one line beside the ticket and no global alert.
        await model.waitUntilWritable();peer.calls=[]
        peer.failures["media_round_link_task"]=[ChecklistError("MEDIA_ROUND_CLOSED","This round is closed. Its ticket cannot change.",details:["command_outcome":"rejected"])]
        model.linkTask(nil)
        try await settle {!model.ticketLinkLine.isEmpty}
        XCTAssertTrue(model.ticketLinkLine.hasPrefix("Could not change the ticket: "),model.ticketLinkLine)
        XCTAssertTrue(peer.calls.first {$0.0=="media_round_link_task"}?.1["task_id"] is NSNull)
        XCTAssertNil(store.error,"No global alert");XCTAssertNil(model.error)
        // The picker offers open tickets only, from the existing ticket list read.
        peer.extra["task_list"]=["tasks":[["id":"task-131","key":"HEIR-131","title":"Wizard idle","status_category":"active"],["id":"task-129","key":"HEIR-129","title":"Old walk","status_category":"done"],["id":"task-130","key":"HEIR-130","title":"Behemoth walk","status_category":"queued"]]]
        await model.loadTicketChoices("HEIR")
        XCTAssertEqual(model.ticketChoices.map {$0.string("key")},["HEIR-130","HEIR-131"])
        let read=try XCTUnwrap(peer.calls.last {$0.0=="task_list"}?.1)
        XCTAssertEqual(read["text"] as? String,"HEIR");XCTAssertEqual(read["archived"] as? Bool,false)
    }
    func testSendShowsProgressThenReceiptAndTheChangesLabel() async throws {
        let (peer,store,model)=await linkedSetup(task:Self.heir130,rows:[decided("a",decision:"d1"),decided("b",decision:"d2",disposition:"changes_requested")])
        XCTAssertEqual(model.resultAction,MediaResultAction(label:"Send results to HEIR-130",disabledReason:nil))
        peer.extra["media_round_send_result"]=["message_id":"note-1","recipients":[["session_id":"s1","display":"Codex HEIR-T1"],["session_id":"s2","display":"Claude reviewer"]],"item_count":2,"changed_only":false,"sent_at":Self.sentAt]
        store.connected=true;peer.calls=[]
        var progress=""
        peer.onRequest={method in if method=="media_round_send_result" {progress=model.resultLine?.text ?? ""}}
        await model.sendResults()
        peer.onRequest=nil
        XCTAssertEqual(progress,"Sending results to HEIR-130…","A progress line shows while the send runs")
        let sent=try XCTUnwrap(peer.calls.first {$0.0=="media_round_send_result"}?.1)
        XCTAssertEqual(sent["round_id"] as? String,"round");XCTAssertEqual(sent["expected_revision"] as? Int,5)
        XCTAssertNotNil(sent["command_id"],"The owner command route journals the send")
        let time=MediaReviewModel.localTime(Self.sentAt)
        XCTAssertFalse(time.contains("T02") || time.hasSuffix("Z"),time)
        XCTAssertEqual(model.resultLine?.text,"Sent to Codex HEIR-T1 and Claude reviewer at "+time+" · 2 items.")
        XCTAssertEqual(model.resultLine?.refused,false);XCTAssertFalse(model.resultSend.sending)
        XCTAssertNil(store.error);XCTAssertNil(model.error)
        // After the send the round records what it carried: nothing new disables the action.
        peer.roundRecords=[linkedHeader(task:Self.heir130,last:["message_id":"note-1","at":Self.sentAt,"decision_ids":["d1","d2"]])]
        await model.refresh()
        XCTAssertEqual(model.resultAction,MediaResultAction(label:"Send changes to HEIR-130",disabledReason:"All results sent."))
        // A new decision since the last send enables "Send changes".
        peer.rows=[decided("a",decision:"d3"),decided("b",decision:"d2",disposition:"changes_requested")];await model.refresh()
        XCTAssertEqual(model.resultAction,MediaResultAction(label:"Send changes to HEIR-130",disabledReason:nil))
        // With a filter the list is not complete, so the service decides what is new.
        peer.rows=[decided("a",decision:"d1")];model.filter="accepted";await model.reloadRows()
        XCTAssertNil(model.resultAction?.disabledReason)
    }
    func testNothingNewAndRefusalsShowOneLineWithNoGlobalAlert() async throws {
        let (peer,store,model)=await linkedSetup(task:Self.heir130,rows:[decided("a",decision:"d1")])
        store.connected=true
        peer.failures["media_round_send_result"]=[ChecklistError("MEDIA_ROUND_NOTHING_NEW","No decision or note changed since the last send.",details:["command_outcome":"rejected"])]
        await model.sendResults()
        XCTAssertEqual(model.resultLine?.text,"Nothing new to send.");XCTAssertEqual(model.resultLine?.refused,false)
        XCTAssertNil(store.error,"No global alert");XCTAssertNil(model.error,"No orange model line")
        await model.waitUntilWritable()
        peer.failures["media_round_send_result"]=[ChecklistError("MEDIA_ROUND_NO_TASK","This round names no ticket.",details:["command_outcome":"rejected"])]
        await model.sendResults()
        XCTAssertEqual(model.resultLine?.text,"Choose the ticket for this round first. Nothing was sent.");XCTAssertEqual(model.resultLine?.refused,true)
        await model.waitUntilWritable()
        peer.failures["media_round_send_result"]=[ChecklistError("MEDIA_ROUND_NO_DECISIONS","Decide an item first.",details:["command_outcome":"rejected"])]
        await model.sendResults()
        XCTAssertEqual(model.resultLine?.text,"Decide at least one item first. Nothing was sent.")
        XCTAssertNil(store.error,"No global alert");XCTAssertNil(model.error);XCTAssertFalse(store.hasPendingMutation)
        XCTAssertEqual(peer.calls.filter {$0.0=="media_round_send_result"}.count,3)
        // Choosing another round clears the line.
        model.chooseRound("round");XCTAssertNil(model.resultSend.line.isEmpty ? nil : model.resultSend.line)
    }
}

/// CL-430: each item may name its own ticket; the send posts one note per ticket.
/// Synthetic peer replies only. No native app, service, keychain or decoder.
extension MediaOwnerSliceTests {
    private static let heir89:MediaValues=["id":"task-89","key":"HEIR-89","title":"Story walk north","status_name":"Queued"]
    private static let heir90:MediaValues=["id":"task-90","key":"HEIR-90","title":"Story walk east","status_name":"Queued"]
    private func item(_ id: String,task: MediaValues?,decision: String = "",disposition: String = "accepted") -> MediaValues {
        var value=decided(id,decision:decision,disposition:disposition);value["task"]=task ?? NSNull()
        if decision.isEmpty {value["disposition"]="pending";value["decision_id"]=""}
        return value
    }
    func testCardShowsItsOwnTicketOnlyWhenItDiffersAndTheHeaderCountsTickets() async {
        let round=Record(values:linkedHeader(task:Self.heir130)),none=Record(values:linkedHeader(task:nil))
        XCTAssertEqual(MediaReviewModel.cardTicketLabel(item:Record(values:item("a",task:Self.heir89)),header:round),"For HEIR-89")
        XCTAssertNil(MediaReviewModel.cardTicketLabel(item:Record(values:item("b",task:Self.heir130)),header:round),"Same as the round's ticket")
        XCTAssertNil(MediaReviewModel.cardTicketLabel(item:Record(values:item("c",task:nil)),header:round),"Uses the round's ticket")
        XCTAssertEqual(MediaReviewModel.cardTicketLabel(item:Record(values:item("a",task:Self.heir89)),header:none),"For HEIR-89")
        XCTAssertNil(MediaReviewModel.cardTicketLabel(item:Record(values:item("c",task:nil)),header:none))
        XCTAssertEqual(MediaReviewModel.itemTicketLine(item:Record(values:item("a",task:Self.heir89)),header:round),"Ticket: HEIR-89 — Story walk north")
        XCTAssertEqual(MediaReviewModel.itemTicketLine(item:Record(values:item("c",task:nil)),header:round),"Ticket: HEIR-130 — Behemoth walk (the round's ticket)")
        XCTAssertEqual(MediaReviewModel.itemTicketLine(item:Record(values:item("c",task:nil)),header:none),"Ticket: none. Results for this item are not sent.")
        // The header counts the distinct effective tickets of the items.
        let mixed=[item("a",task:Self.heir89),item("b",task:Self.heir90),item("c",task:nil)].map(Record.init)
        XCTAssertEqual(MediaReviewModel.ticketLine(round,rows:mixed),"For 3 tickets")
        XCTAssertEqual(MediaReviewModel.ticketLine(none,rows:mixed),"For 2 tickets","An item with no ticket and no round ticket names none")
        XCTAssertEqual(MediaReviewModel.ticketLine(none,rows:[mixed[0],mixed[2]]),"For HEIR-89 — Story walk north","One item ticket and no round ticket")
        XCTAssertEqual(MediaReviewModel.ticketLine(round,rows:[mixed[2]]),"For HEIR-130 — Behemoth walk")
        XCTAssertEqual(MediaReviewModel.ticketLine(none,rows:[mixed[2]]),"No ticket")
        let (_,_,model)=await linkedSetup(task:Self.heir130,rows:[item("a",task:Self.heir89),item("b",task:Self.heir90),item("c",task:nil)])
        XCTAssertEqual(model.ticketLineText,"For 3 tickets")
    }
    func testOwnerSetsAndRemovesAnItemTicketWithOneRefusalLine() async throws {
        var row=item("a",task:nil);row["revision"]=3
        let (peer,store,model)=await linkedSetup(task:Self.heir130,rows:[row])
        store.connected=true;peer.calls=[]
        model.linkItemTask("a","task-89")
        try await settle {peer.calls.contains {$0.0=="media_item_link_task"} && !store.busy}
        let link=try XCTUnwrap(peer.calls.first {$0.0=="media_item_link_task"}?.1)
        XCTAssertEqual(link["round_id"] as? String,"round");XCTAssertEqual(link["item_id"] as? String,"a")
        XCTAssertEqual(link["expected_revision"] as? Int,3,"The item revision, not the round revision 5");XCTAssertEqual(link["task_id"] as? String,"task-89")
        XCTAssertEqual(link["project_id"] as? String,peer.project);XCTAssertNotNil(link["command_id"],"The owner command route journals the change")
        XCTAssertTrue(MediaReviewModel.itemLinkTaskParams(header:model.header,item:Record(values:row),taskID:nil)["task_id"] is NSNull,"Use the round's ticket sends task_id null")
        await model.waitUntilWritable();peer.calls=[]
        peer.failures["media_item_link_task"]=[ChecklistError("MEDIA_ROUND_CLOSED","This round is closed. Its tickets cannot change.",details:["command_outcome":"rejected"])]
        model.linkItemTask("a",nil)
        try await settle {model.itemTicketLines["a"] != nil}
        XCTAssertTrue(model.itemTicketLines["a"]!.hasPrefix("Could not change this item's ticket: "),model.itemTicketLines["a"]!)
        XCTAssertTrue(peer.calls.first {$0.0=="media_item_link_task"}?.1["task_id"] is NSNull)
        XCTAssertNil(store.error,"No global alert");XCTAssertNil(model.error);XCTAssertEqual(model.ticketLinkLine,"","The round's line stays clear")
        // A closed round offers no item ticket change and sends nothing.
        let (closedPeer,_,closed)=await linkedSetup(task:Self.heir130,rows:[item("a",task:nil)],state:"closed")
        closedPeer.calls=[];closed.linkItemTask("a","task-89")
        XCTAssertFalse(closedPeer.calls.contains {$0.0=="media_item_link_task"})
    }
    /// Round 95 UI check: a one-ticket send from a round whose items name tickets named no key, and
    /// after the owner withdrew a sent decision the action said "All results sent." (CL-428 U1).
    func testOneSendOfAMixedRoundNamesItsKeyAndAWithdrawnSentDecisionCanBeSent() async throws {
        let time=MediaReviewModel.localTime(Self.sentAt)
        let one=MediaReviewModel.receiptText(["sends":[["task_id":"task-89","task_key":"HEIR-89","message_id":"n1",
            "recipients":[["session_id":"s1","display":"Codex HEIR-T1"],["session_id":"s2","display":"Claude worker"]],"item_count":1]],
            "unsent_item_count":0,"changed_only":true,"sent_at":Self.sentAt],roundTaskID:"task-130")
        XCTAssertEqual(one,"Sent to HEIR-89: Codex HEIR-T1 and Claude worker at "+time+" · 1 item changed since the last send.")
        // A send to the round's own ticket names the key only while the items name more than one ticket.
        let toRound:MediaValues=["sends":[["task_id":"task-130","task_key":"HEIR-130","recipients":[["session_id":"s1","display":"Codex HEIR-T1"]],"item_count":1]],
            "unsent_item_count":0,"changed_only":true,"sent_at":Self.sentAt]
        XCTAssertEqual(MediaReviewModel.receiptText(toRound,roundTaskID:"task-130",mixed:true),"Sent to HEIR-130: Codex HEIR-T1 at "+time+" · 1 item changed since the last send.")
        XCTAssertEqual(MediaReviewModel.receiptText(toRound,roundTaskID:"task-130",mixed:false),"Sent to Codex HEIR-T1 at "+time+" · 1 item changed since the last send.")
        // The CL-427 top-level fields of a round-only send keep the receipt without a key.
        XCTAssertEqual(MediaReviewModel.receiptText(["recipients":[["session_id":"s1","display":"Codex HEIR-T1"]],"item_count":2,"changed_only":false,"sent_at":Self.sentAt,
            "sends":[["task_id":"task-130","task_key":"HEIR-130","recipients":[["session_id":"s1","display":"Codex HEIR-T1"]],"item_count":2]]]),
            "Sent to Codex HEIR-T1 at "+time+" · 2 items.")
        // The last send carried d1 (HEIR-89) and d2, d3 (HEIR-130). The owner then withdrew d1.
        let last:MediaValues=["at":Self.sentAt,"decision_ids":["d1","d2","d3"],
            "sends":[["task_id":"task-89","decision_ids":["d1"]],["task_id":"task-130","decision_ids":["d2","d3"]]]]
        let withdrawn=[item("a",task:Self.heir89),item("b",task:nil,decision:"d2"),item("c",task:nil,decision:"d3")]
        let (_,_,model)=await linkedSetup(task:Self.heir130,last:last,rows:withdrawn)
        XCTAssertEqual(model.resultAction,MediaResultAction(label:"Send changes to 2 tickets",disabledReason:nil),"The withdrawal is a change for HEIR-89")
        XCTAssertEqual(MediaReviewModel.withdrawnSentTickets(header:model.header,rows:withdrawn.map(Record.init)),["d1":"task-89"])
        // Every decision withdrawn: the action still offers the send, named for both tickets.
        let none=[item("a",task:Self.heir89),item("b",task:nil),item("c",task:nil)].map(Record.init)
        XCTAssertEqual(MediaReviewModel.resultAction(header:model.header,rows:none,counts:[:],listComplete:true),MediaResultAction(label:"Send changes to 2 tickets",disabledReason:nil))
        // A round-only send (CL-427 baseline, no `sends`): a withdrawal there keeps the one-ticket label.
        let roundHeader=Record(values:linkedHeader(task:Self.heir130,last:["at":Self.sentAt,"decision_ids":["d2","d3"]]))
        let roundRows=[item("b",task:nil),item("c",task:nil,decision:"d3")].map(Record.init)
        XCTAssertEqual(MediaReviewModel.withdrawnSentTickets(header:roundHeader,rows:roundRows),["d2":"task-130"])
        XCTAssertEqual(MediaReviewModel.resultAction(header:roundHeader,rows:roundRows,counts:[:],listComplete:true),MediaResultAction(label:"Send changes to HEIR-130",disabledReason:nil))
        // Nothing withdrawn and nothing new: all results sent.
        let same=[item("a",task:Self.heir89,decision:"d1"),item("b",task:nil,decision:"d2"),item("c",task:nil,decision:"d3")].map(Record.init)
        XCTAssertEqual(MediaReviewModel.resultAction(header:model.header,rows:same,counts:[:],listComplete:true)?.disabledReason,MediaReviewModel.allResultsSentText)
        // While the list is incomplete the model cannot prove anything; it stays enabled.
        XCTAssertNil(MediaReviewModel.resultAction(header:model.header,rows:Array(same.prefix(1)),counts:[:],listComplete:false)?.disabledReason)
    }
    func testMixedRoundSendNamesTheTicketsAndTheReceiptListsEachTicket() async throws {
        let rows=[item("a",task:Self.heir89,decision:"d1"),item("b",task:Self.heir90,decision:"d2",disposition:"changes_requested"),item("c",task:nil,decision:"d3"),item("d",task:Self.heir89)]
        let (peer,store,model)=await linkedSetup(task:Self.heir130,rows:rows)
        XCTAssertEqual(model.resultAction,MediaResultAction(label:"Send results to 3 tickets",disabledReason:nil))
        // A pending item does not count: its ticket has no decision to send.
        XCTAssertEqual(MediaReviewModel.resultAction(header:model.header,rows:[rows[0],rows[3]].map(Record.init),counts:[:],listComplete:true)?.label,"Send results to HEIR-89")
        // No round ticket: an item ticket alone shows the action; no ticket at all hides it.
        let none=Record(values:linkedHeader(task:nil))
        XCTAssertEqual(MediaReviewModel.resultAction(header:none,rows:[Record(values:rows[0])],counts:[:],listComplete:true)?.label,"Send results to HEIR-89")
        XCTAssertNil(MediaReviewModel.resultAction(header:none,rows:[Record(values:rows[2])],counts:[:],listComplete:true))
        peer.extra["media_round_send_result"]=["sends":[
            ["task_id":"task-89","task_key":"HEIR-89","message_id":"n1","recipients":[["session_id":"s1","display":"Codex HEIR-T1"]],"item_count":1],
            ["task_id":"task-90","task_key":"HEIR-90","message_id":"n2","recipients":[["session_id":"s1","display":"Codex HEIR-T1"],["session_id":"s2","display":"Claude worker"]],"item_count":1],
            ["task_id":"task-130","task_key":"HEIR-130","message_id":"n3","recipients":[],"item_count":1]],
            "unsent_item_count":2,"changed_only":false,"sent_at":Self.sentAt]
        store.connected=true;peer.calls=[]
        var progress=""
        peer.onRequest={method in if method=="media_round_send_result" {progress=model.resultLine?.text ?? ""}}
        await model.sendResults()
        peer.onRequest=nil
        XCTAssertEqual(progress,"Sending results to 3 tickets…")
        let sent=try XCTUnwrap(peer.calls.first {$0.0=="media_round_send_result"}?.1)
        XCTAssertEqual(sent["round_id"] as? String,"round");XCTAssertEqual(sent["expected_revision"] as? Int,5)
        let time=MediaReviewModel.localTime(Self.sentAt)
        XCTAssertEqual(model.resultLine?.text,["Sent to 3 tickets at "+time+".","HEIR-89: Codex HEIR-T1 · 1 item","HEIR-90: Codex HEIR-T1 and Claude worker · 1 item","HEIR-130 · 1 item · saved for pickup, nobody was notified","2 items have no ticket."].joined(separator:"\n"))
        XCTAssertEqual(model.resultLine?.refused,false);XCTAssertNil(store.error);XCTAssertNil(model.error)
        // A repeat that sends only changes says so on its first line; one unsent item reads in the singular.
        let repeated=MediaReviewModel.receiptText(["sends":(peer.extra["media_round_send_result"]?["sends"] as? [MediaValues] ?? []).prefix(2).map {$0},"unsent_item_count":1,"changed_only":true,"sent_at":Self.sentAt])
        XCTAssertEqual(repeated.components(separatedBy:"\n").first,"Sent to 2 tickets at "+time+" · only changes since the last send.")
        XCTAssertEqual(repeated.components(separatedBy:"\n").last,"1 item has no ticket.")
        // After the send, nothing new disables the action with the multi-ticket label.
        peer.roundRecords=[linkedHeader(task:Self.heir130,last:["at":Self.sentAt,"decision_ids":["d1","d2","d3"],
            "sends":[["task_id":"task-89","decision_ids":["d1"]],["task_id":"task-90","decision_ids":["d2"]],
                     ["task_id":"task-130","decision_ids":["d3"]]]])]
        await model.refresh()
        XCTAssertEqual(model.resultAction,MediaResultAction(label:"Send changes to 3 tickets",disabledReason:"All results sent."))
    }
    func testOneTicketRoundKeepsTheCL427LabelsAndReceipt() async throws {
        let (_,_,model)=await linkedSetup(task:Self.heir130,rows:[item("a",task:nil,decision:"d1"),item("b",task:Self.heir130,decision:"d2")])
        XCTAssertEqual(model.ticketLineText,"For HEIR-130 — Behemoth walk")
        XCTAssertEqual(model.resultAction,MediaResultAction(label:"Send results to HEIR-130",disabledReason:nil))
        XCTAssertEqual(MediaReviewModel.resultTarget(header:model.header,rows:model.rows),"HEIR-130")
        let time=MediaReviewModel.localTime(Self.sentAt)
        let recipients:[MediaValues]=[["session_id":"s1","display":"Codex HEIR-T1"]]
        // The CL-427 top-level fields win; the one `sends` entry gives the same text.
        let oneSend:MediaValues=["task_id":"task-130","task_key":"HEIR-130","message_id":"n1","recipients":recipients,"item_count":2]
        let both=MediaReviewModel.receiptText(["sends":[oneSend],"message_id":"n1","recipients":recipients,"item_count":2,"unsent_item_count":0,"changed_only":false,"sent_at":Self.sentAt])
        let sendsOnly=MediaReviewModel.receiptText(["sends":[oneSend],"unsent_item_count":0,"changed_only":false,"sent_at":Self.sentAt])
        let legacy=MediaReviewModel.receiptText(["message_id":"n1","recipients":recipients,"item_count":2,"changed_only":false,"sent_at":Self.sentAt])
        XCTAssertEqual(legacy,"Sent to Codex HEIR-T1 at "+time+" · 2 items.")
        XCTAssertEqual(both,legacy);XCTAssertEqual(sendsOnly,legacy)
        // An item with no ticket in a one-ticket send adds the unsent count.
        XCTAssertEqual(MediaReviewModel.receiptText(["sends":[oneSend],"unsent_item_count":3,"changed_only":true,"sent_at":Self.sentAt]),
                       "Sent to Codex HEIR-T1 at "+time+" · 2 items changed since the last send. 3 items have no ticket.")
    }
    func testPickupOnlyReceiptsSayNobodyWasNotifiedForSingleAndMixedSends() {
        let time=MediaReviewModel.localTime(Self.sentAt)
        let pickup:MediaValues=["task_id":"task-89","task_key":"HEIR-89","message_id":"pickup-note",
            "recipients":[],"delivery_state":"saved_for_pickup","item_count":1]
        let queued:MediaValues=["task_id":"task-90","task_key":"HEIR-90","message_id":"queued-note",
            "recipients":[["session_id":"s1","display":"Codex HEIR-T1"]],"delivery_state":"queued","item_count":2]
        let single:MediaValues=["sends":[pickup],"unsent_item_count":1,"changed_only":true,"sent_at":Self.sentAt]
        for mixed in [false,true] {
            XCTAssertEqual(MediaReviewModel.receiptText(single,roundTaskID:"task-130",mixed:mixed),
                "Saved for pickup at "+time+" · HEIR-89 · 1 item changed since the last send. Nobody was notified. 1 item has no ticket.")
        }
        // CL-427 round-only replies also carry the one send alongside legacy top-level fields.
        var roundOnly=single
        for key in ["message_id","recipients","delivery_state","item_count"] {roundOnly[key]=pickup[key]}
        XCTAssertEqual(MediaReviewModel.receiptText(roundOnly),MediaReviewModel.receiptText(single))
        XCTAssertEqual(MediaReviewModel.receiptText(["sends":[queued,pickup],"sent_at":Self.sentAt]),[
            "Sent to 2 tickets at "+time+".","HEIR-90: Codex HEIR-T1 · 2 items",
            "HEIR-89 · 1 item · saved for pickup, nobody was notified"].joined(separator:"\n"))
        // Older service replies have no delivery_state; the empty recipients still prove pickup only.
        var legacy=pickup;legacy["delivery_state"]=nil
        XCTAssertEqual(MediaReviewModel.receiptText(["sends":[legacy],"sent_at":Self.sentAt]),
            "Saved for pickup at "+time+" · HEIR-89 · 1 item. Nobody was notified.")
        XCTAssertEqual(MediaReviewModel.receiptText(["recipients":[],"item_count":2,"sent_at":Self.sentAt]),
            "Saved for pickup at "+time+" · 2 items. Nobody was notified.")
        var stateOnly=pickup;stateOnly["recipients"]=nil
        XCTAssertEqual(MediaReviewModel.receiptText(["sends":[stateOnly],"sent_at":Self.sentAt]),
            "Saved for pickup at "+time+" · HEIR-89 · 1 item. Nobody was notified.")
        // An explicit recipient list wins over a conflicting state label, in either direction.
        legacy["delivery_state"]="queued"
        XCTAssertTrue(MediaReviewModel.receiptText(["sends":[legacy],"sent_at":Self.sentAt]).contains("Nobody was notified."))
        var actualRecipients=queued;actualRecipients["delivery_state"]="saved_for_pickup"
        XCTAssertEqual(MediaReviewModel.receiptText(["sends":[actualRecipients],"sent_at":Self.sentAt]),
            "Sent to Codex HEIR-T1 at "+time+" · 2 items.")
    }
    func testWithdrawalActionKeepsEarlierDestinationAfterItemOrRoundLinksChange() {
        let last:MediaValues=["at":Self.sentAt,"decision_ids":["d1"],
            "sends":[["task_id":"task-89","task_key":"HEIR-89","decision_ids":["d1"]]]]
        let cases:[(String,MediaValues?,MediaValues?)]=[
            ("item moved",Self.heir130,Self.heir90),
            ("item cleared to round fallback",Self.heir130,nil),
            ("round moved",Self.heir90,nil),
            ("every current link cleared",nil,nil)]
        for (name,roundTask,itemTask) in cases {
            let header=Record(values:linkedHeader(task:roundTask,last:last))
            // Native rows retain the withdrawal head ID while its disposition becomes Pending.
            let rows=[Record(values:item("a",task:itemTask,decision:"withdrawal-d1",disposition:"pending"))]
            XCTAssertEqual(MediaReviewModel.withdrawnSentTickets(header:header,rows:rows),["d1":"task-89"],name)
            XCTAssertEqual(MediaReviewModel.resultTarget(header:header,rows:rows),"HEIR-89",name)
            XCTAssertEqual(MediaReviewModel.resultAction(header:header,rows:rows,counts:["pending":1],listComplete:true),
                MediaResultAction(label:"Send changes to HEIR-89",disabledReason:nil),name+": the new ticket has no separate changed decision")
            let withNewDecision=rows+[Record(values:item("b",task:Self.heir90,decision:"new-d2"))]
            XCTAssertEqual(MediaReviewModel.resultAction(header:header,rows:withNewDecision,counts:[:],listComplete:true),
                MediaResultAction(label:"Send changes to 2 tickets",disabledReason:nil),name+": a separate new decision also names its ticket")
        }
        // A frozen legacy baseline may retain only the old opaque ID. Never label it with the new key.
        let legacy=Record(values:linkedHeader(task:Self.heir90,last:["at":Self.sentAt,"decision_ids":["d1"],
            "sends":[["task_id":"task-89","decision_ids":["d1"]]]]))
        let pending=[Record(values:item("a",task:nil))]
        XCTAssertEqual(MediaReviewModel.resultAction(header:legacy,rows:pending,counts:[:],listComplete:true),
            MediaResultAction(label:"Send changes to the previous ticket",disabledReason:nil))
        // The same current decision must be sent again when its destination changes.
        let moved=[Record(values:item("a",task:Self.heir90,decision:"d1"))]
        XCTAssertTrue(MediaReviewModel.withdrawnSentTickets(header:legacy,rows:moved).isEmpty)
        XCTAssertEqual(MediaReviewModel.resultAction(header:legacy,rows:moved,counts:[:],listComplete:true),
            MediaResultAction(label:"Send changes to HEIR-90",disabledReason:nil))
    }
    func testWithdrawalOnlySendRemainsAvailableWithAllCurrentTicketLinksCleared() async throws {
        let last:MediaValues=["at":Self.sentAt,"decision_ids":["d1"],
            "sends":[["task_id":"task-89","task_key":"HEIR-89","decision_ids":["d1"]]]]
        let (peer,store,model)=await linkedSetup(task:nil,last:last,
            rows:[item("a",task:nil,decision:"withdrawal-d1",disposition:"pending")])
        peer.extra["media_round_send_result"]=["sends":[["task_id":"task-89","task_key":"HEIR-89","message_id":"withdrawal-note",
            "recipients":[],"delivery_state":"saved_for_pickup","item_count":1]],"changed_only":true,"sent_at":Self.sentAt]
        store.connected=true;peer.calls=[]
        var progress=""
        peer.onRequest={method in if method=="media_round_send_result" {progress=model.resultLine?.text ?? ""}}
        await model.sendResults()
        peer.onRequest=nil
        XCTAssertEqual(progress,"Sending results to HEIR-89…")
        XCTAssertEqual(peer.calls.filter {$0.0=="media_round_send_result"}.count,1)
        let expected="Saved for pickup at "+MediaReviewModel.localTime(Self.sentAt)
        XCTAssertEqual(model.resultLine?.text,expected+" · HEIR-89 · 1 item changed since the last send. Nobody was notified.")
        XCTAssertEqual(model.resultLine?.refused,false);XCTAssertNil(store.error);XCTAssertNil(model.error)
    }
}
