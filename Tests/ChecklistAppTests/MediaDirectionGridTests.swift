import XCTest
import ChecklistCore
import ChecklistIPC
@testable import ChecklistApp

@MainActor private final class GridTake: MediaTakeControl {
    var plays=0,pauses=0,unloads=0
    func play() {plays+=1}
    func pause() {pauses+=1}
    func unload() {unloads+=1}
}

@MainActor private final class GridNoAlerts: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization {.denied}
    func requestAuthorizationFromOwnerAction() async throws -> Bool {false}
    func send(_ alert: DesktopAlert) async throws {}
    func remove(_ identifiers: [String]) {}
}

/// Mock transport and controls only. No native app, service, keychain or decoder.
@MainActor final class MediaDirectionGridTests: XCTestCase {
    private let directions=["N","NE","E","SE","S","SW","W","NW"]
    private func take(_ key: String,control: GridTake = GridTake(),bytes: Int = 1024,width: Int = 64,height: Int = 64) -> MediaPreparedTake {
        .init(key:key,label:key,kind:"video",ids:[:],control:control,measurement:.init(copyMilliseconds:0,probeMilliseconds:0,bytes:bytes,facts:.init(durationSeconds:1,width:width,height:height,frames:8,hasVideo:true,hasAudio:false)))
    }
    private func header() -> Record {
        Record(values:["id":"round","state":"open","revision":3,"observed_context_token":"context","manifest":["id":"manifest","digest":"digest"],"attention":[],"type_revision":["schema":MediaTypeSettings.schema(title:"Animation",starter:"animation_video")]])
    }
    private func item(_ direction: String) -> Record {
        Record(values:["id":"item-"+direction,"revision":2,"published":true,"disposition":"pending",
            "target":["id":"target-"+direction,"review_basis_signature":"basis-"+direction,"metadata":["character":"Hero","animation_label":"walk","direction":direction,"hint":"Exact hint"],"candidate_ids":["candidate-"+direction]],
            "candidates":[["id":"candidate-"+direction,"slots":[]]],"originals":[]])
    }
    private func card(_ direction: String) -> MediaDirectionCard {
        let item=item(direction),header=header()
        var draft=MediaOwnerDraft();draft.basis="basis-"+direction;draft.targetID="target-"+direction
        draft.contextToken="context";draft.manifestID="manifest";draft.manifestDigest="digest"
        return MediaDirectionCard(item:item,header:header,draft:draft)
    }
    func testGridKeepsEightPlayingWithoutPausingSiblingsAndReleasesAll() {
        let grid=MediaPlaybackCoordinator(directionGrid:true),controls=directions.map {_ in GridTake()}
        for (index,direction) in directions.enumerated() {XCTAssertTrue(grid.admit(take(direction,control:controls[index])))}
        grid.playAll()
        XCTAssertEqual(grid.playingKeys,Set(directions));XCTAssertTrue(controls.allSatisfy {$0.plays==1 && $0.pauses==0})
        grid.didStart("N");XCTAssertTrue(controls.allSatisfy {$0.pauses==0},"Native Play must leave sibling directions playing")
        let ninth=GridTake();XCTAssertFalse(grid.admit(take("ninth",control:ninth)));XCTAssertEqual(ninth.unloads,1)
        XCTAssertEqual(grid.takes.count,8)
        grid.pauseAll();XCTAssertTrue(grid.playingKeys.isEmpty)
        grid.playAll();grid.releaseAll();XCTAssertTrue(grid.takes.isEmpty);XCTAssertTrue(grid.playingKeys.isEmpty)
        XCTAssertTrue(controls.allSatisfy {$0.unloads==1})
    }
    func testOpeningGridRetiresComparisonImagesSoReturningCanReloadThem() {
        let model=MediaReviewModel()
        XCTAssertTrue(model.beginImage("current",historical:false));model.endImage()
        XCTAssertTrue(model.beginImage("historical",historical:true));model.endImage()
        model.playback.admit(take("comparison"));model.playback.play("comparison")
        model.prepareForDirectionGrid()
        XCTAssertTrue(model.playback.takes.isEmpty)
        XCTAssertFalse(model.imageIsActive("current",historical:false))
        XCTAssertFalse(model.imageIsActive("historical",historical:true))
        XCTAssertTrue(model.beginImage("current",historical:false));model.endImage()
    }
    func testGridBytePixelAndSinglePreparationBounds() {
        let grid=MediaPlaybackCoordinator(directionGrid:true)
        XCTAssertTrue(grid.beginPreparation("first"));XCTAssertFalse(grid.beginPreparation("second"));grid.endPreparation("first")
        XCTAssertFalse(grid.admit(take("too-large",bytes:MediaPlaybackBudget.directionGridOriginalBytes+1)))
        XCTAssertFalse(grid.admit(take("edge",width:1025)))
        XCTAssertFalse(grid.admit(take("invalid",width:0)))
        XCTAssertTrue(grid.admit(take("one",width:1024,height:1024)))
        XCTAssertTrue(grid.admit(take("two",width:1024,height:1024)))
        XCTAssertFalse(grid.admit(take("three",width:1,height:1)),"Aggregate decoder pixels must remain bounded")
        grid.releaseAll()
        for direction in directions {XCTAssertTrue(grid.admit(take(direction,bytes:MediaPlaybackBudget.directionGridOriginalBytes,width:512,height:512)))}
        XCTAssertEqual(grid.cachedBytes,MediaPlaybackBudget.directionGridCacheBytes)
    }
    func testGroupResolvesWholeCharacterActionBeyondListPageAndKeepsOpaqueValues() throws {
        let schema=MediaTypeSettings.schema(title:"Animation",starter:"animation_video")
        let metadata:MediaValues=["character":"Hero\"/é","animation_label":"walk/\"","direction":"N"]
        let group=try XCTUnwrap(MediaAnimationGroup(metadata:metadata,schema:schema))
        let path: [MediaValues]=[["field_id":"character","value":metadata["character"]!],["field_id":"animation_label","value":metadata["animation_label"]!]]
        let headerID="group:"+(try JSONSerialization.data(withJSONObject:path,options:.sortedKeys)).base64EncodedString()
        XCTAssertEqual(MediaAnimationGroup(headerID:headerID,schema:schema),group)
        let request=group.pageRequest(roundID:"round",schema:schema)
        XCTAssertEqual(request["limit"] as? Int,9)
        XCTAssertEqual(NSDictionary(dictionary:(request["filter"] as? MediaValues)?["metadata"] as? MediaValues ?? [:]),NSDictionary(dictionary:group.metadata))
        XCTAssertNil(request["cursor"]);XCTAssertNil((request["filter"] as? MediaValues)?["dispositions"])
        XCTAssertNil(MediaAnimationGroup(headerID:"group:invalid",schema:schema))
        XCTAssertNil(MediaAnimationGroup(metadata:metadata,schema:MediaTypeSettings.schema(title:"Images",starter:"animation")))
    }
    func testEveryDecisionTargetsItsOwnFrozenItemAndRequiresReasonAndBasis() throws {
        for direction in directions {
            let card=card(direction)
            for disposition in ["accepted","needs_look","changes_requested"] {
                card.draft.note="Fix only "+direction
                let request=try card.decisionRequest(disposition),selection=try XCTUnwrap((request["items"] as? [MediaValues])?.first)
                XCTAssertEqual(selection["item_id"] as? String,"item-"+direction)
                XCTAssertEqual(selection["target_id"] as? String,"target-"+direction)
                XCTAssertEqual(selection["review_basis_signature"] as? String,"basis-"+direction)
                XCTAssertEqual(request["manifest_id"] as? String,"manifest");XCTAssertEqual(request["observed_context_token"] as? String,"context")
                if disposition=="accepted" {XCTAssertEqual(request["winner_id"] as? String,"candidate-"+direction)}
            }
            card.draft.note=" ";XCTAssertThrowsError(try card.decisionRequest("changes_requested"))
            card.draft.targetID="older";XCTAssertThrowsError(try card.decisionRequest("accepted"))
            card.inspectCurrentBasis();XCTAssertNoThrow(try card.decisionRequest("accepted"))
        }
    }
    func testCardPersistsNoteOnEditBeforeAnyViewLifecycleCallback() {
        var saved:[MediaOwnerDraft]=[]
        let card=MediaDirectionCard(item:item("N"),header:header(),draft:MediaOwnerDraft(),saveDraft:{saved.append($0)})
        card.draft.note="Last typed character"
        XCTAssertEqual(saved.last?.note,"Last typed character")
        card.draft.note+="!"
        XCTAssertEqual(saved.last?.note,"Last typed character!")
    }
    func testPerItemRateAndEncodedFallbackDoNotApplyToReferencesOrHistoricalExamples() throws {
        let layout=MediaTypeSettings.schema(title:"Animation",starter:"animation_video")["layout"] as! MediaValues
        for rate in [4.0,8.0,12.0] {
            let source=MediaComparisonLabels.playbackSettings(slotID:"take",layout:layout,historical:false)
            XCTAssertTrue(source.loop);XCTAssertNil(source.frameRate)
            XCTAssertEqual(try MediaPlaybackTiming(nominalFrameRate:rate,declaredFrameRate:source.frameRate).rate,1)
            let stated=MediaComparisonLabels.playbackSettings(slotID:"take",layout:layout,historical:false,metadata:["frame_rate":12])
            XCTAssertEqual(stated.frameRate,12);XCTAssertEqual(try MediaPlaybackTiming(nominalFrameRate:rate,declaredFrameRate:stated.frameRate).rate,Float(12/rate))
            XCTAssertNil(MediaComparisonLabels.playbackSettings(slotID:"reference",layout:layout,historical:false,metadata:["frame_rate":12]).frameRate)
            XCTAssertNil(MediaComparisonLabels.playbackSettings(slotID:"take",layout:layout,historical:true,metadata:["frame_rate":12]).frameRate)
        }
    }

    func testOpeningGroupLoadsEveryDirectionThenStartsTogetherAndRejectsDuplicateOrNinthItem() async throws {
        let defaults=isolatedDefaults("DirectionGrid"),directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        var calls:[(String,MediaValues)]=[],count=8,duplicate=false
        let header=header(),items=Dictionary(uniqueKeysWithValues:directions.map {($0,item($0))})
        let store=ChecklistStore(draftJournal:LocalDraftJournal(directory:directory),preferences:defaults.preferences,restorePendingCommand:false,
            desktopAlerts:DesktopAlertCoordinator(sink:GridNoAlerts()),requestTransport:{method,params in
                calls.append((method,params))
                let result:MediaValues
                switch method {
                case "media_navigation":result=["types":[["id":"type","title":"Animation","enabled":true]]]
                case "media_round_page":result=["rows":[],"has_more":false]
                case "media_round_header":result=header.values
                case "media_item_page":result=["rows":(0..<count).map {index in ["id":"item-"+(index<8 ? self.directions[index] : "ninth")] as MediaValues}]
                case "media_decide":
                    let selection=(params["items"] as? [MediaValues])?.first ?? [:]
                    result=["decisions":[["id":"decision","item_id":selection["item_id"]!,"target_id":selection["target_id"]!,"disposition":params["disposition"]!]]]
                case "media_item_get":
                    let direction=String((params["item_id"] as? String ?? "").dropFirst(5))
                    result=items[duplicate ? "N" : direction]?.values ?? [:]
                default:result=[:]
                }
                return ["data":result]
            },navigationMemory:DetailItemNavigationMemory(),pendingCommandPersistence:PendingCommandPersistence(read:{_ in nil},save:{_,_ in},remove:{_ in}))
        store.data=["service":["store_incarnation":"synthetic"]];store.connected=true;store.projectID="project"
        let model=store.mediaReview;await model.connect(store:store);model.roundID="round"
        let group=try XCTUnwrap(MediaAnimationGroup(metadata:["character":"Hero","animation_label":"walk"],schema:MediaTypeSettings.schema(title:"Animation",starter:"animation_video")))
        var controls:[GridTake]=[]
        let grid=MediaDirectionGridModel(prepareTake:{card in
            XCTAssertTrue(controls.allSatisfy {$0.plays==0},"Every direction is prepared before any auto-play")
            let control=GridTake();controls.append(control);return self.take(card.key,control:control)
        })
        await grid.open(group:group,model:model)
        XCTAssertNil(grid.error);XCTAssertEqual(grid.cards.map(\.direction),directions)
        XCTAssertEqual(grid.playback.takes.count,8);XCTAssertEqual(grid.playback.playingKeys.count,8)
        XCTAssertTrue(controls.allSatisfy {$0.plays==1});XCTAssertEqual(calls.filter {$0.0=="media_item_get"}.count,8)
        let north=try XCTUnwrap(grid.cards.first)
        await grid.decide("accepted",card:north,model:model)
        for _ in 0..<200 where north.sending {try await Task.sleep(for:.milliseconds(5))}
        let sent=try XCTUnwrap(calls.first {$0.0=="media_decide"}?.1)
        XCTAssertNotNil(sent["command_id"],"Grid uses the durable owner mutation path")
        XCTAssertEqual((sent["items"] as? [MediaValues])?.first?["item_id"] as? String,"item-N")
        XCTAssertEqual(north.item.string("disposition"),"accepted")
        grid.close();XCTAssertTrue(controls.allSatisfy {$0.unloads==1})
        // A replacement waits for a cancelled, suspended preparation to retire.
        var suspended: CheckedContinuation<Void,Never>?,preparations=0,active=0,peak=0
        var serialControls:[GridTake]=[]
        let serial=MediaDirectionGridModel(prepareTake:{card in
            preparations+=1;active+=1;peak=max(peak,active)
            defer {active-=1}
            if preparations==1 {await withCheckedContinuation {suspended=$0}}
            let control=GridTake();serialControls.append(control);return self.take(card.key,control:control)
        })
        let first=Task {await serial.open(group:group,model:model)}
        for _ in 0..<200 where suspended==nil {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertNotNil(suspended)
        let replacement=Task {await serial.open(group:group,model:model)}
        for _ in 0..<200 where !serial.cards.isEmpty {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertTrue(serial.cards.isEmpty,"Replacement closes the old group before retired preparation resumes")
        XCTAssertEqual(preparations,1)
        suspended?.resume();await first.value;await replacement.value
        XCTAssertEqual(serialControls.first?.plays,0,"The cancelled first take never auto-plays")
        XCTAssertEqual(peak,1);XCTAssertEqual(serial.playback.takes.count,8)
        XCTAssertEqual(serialControls.first?.unloads,1,"Cancelled prepared takes are unloaded")
        serial.close();XCTAssertTrue(serialControls.allSatisfy {$0.unloads==1})
        count=9;await grid.open(group:group,model:model);XCTAssertNotNil(grid.error);XCTAssertTrue(grid.cards.isEmpty)
        count=8;duplicate=true;await grid.open(group:group,model:model);XCTAssertNotNil(grid.error);XCTAssertTrue(grid.cards.isEmpty)
        store.projectID="other-project";await model.connect(store:store)
        await model.releasePlaybackLease("old-project-lease",projectID:"project")
        let release=try XCTUnwrap(calls.last {$0.0=="media_example_read_release"}?.1)
        XCTAssertEqual(release["project_id"] as? String,"project","A grid lease releases in its original project after selection changes")

    }
}
