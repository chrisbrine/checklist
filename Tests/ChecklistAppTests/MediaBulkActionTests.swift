import XCTest
@testable import ChecklistApp
import ChecklistCore
import ChecklistIPC

/// CL-318/CL-349: selection, one confirmed bulk decision, chunk progress and failed-only retry
/// against the synthetic mock service. Installed checks cover the real service and window.
extension MediaOwnerSliceTests {
    func bulkEntries(_ count: Int,candidates: Int = 1) -> [MediaValues] {
        (0..<count).map {index in
            ["item_id":"item-\(index)","expected_revision":1,"target_id":"target-\(index)","review_basis_signature":"basis-\(index)","disposition":"pending",
             "candidate_ids":(0..<candidates).map {"candidate-\(index)-\($0)"}]
        }
    }
    func bulkSelection(_ entries: [MediaValues],unpublished: Int = 0) -> MediaValues {
        ["round_id":"round","expected_revision":4,"observed_context_token":"context-1","manifest_id":"manifest","manifest_digest":"digest","state":"open","entries":entries,"unpublished":unpublished]
    }
    func bulkChunks(_ entries: [MediaValues]) -> [MediaValues] {
        stride(from:0,to:entries.count,by:200).enumerated().map {index,offset in
            ["id":"chunk-\(index)","command_id":"command-\(index)","items":Array(entries[offset..<min(offset+200,entries.count)])]
        }
    }
    /// The service view of an operation; states line up with its chunks.
    func bulkView(_ entries: [MediaValues],states: [String],id: String = "operation",failure: String? = nil) -> MediaValues {
        let chunks = bulkChunks(entries)
        var committed: [String] = [],failed: [String] = [],uncommitted: [String] = []
        let results = chunks.enumerated().map { index,chunk -> MediaValues in
            var row = chunk;row["state"] = states[index]
            let ids = (chunk["items"] as! [MediaValues]).map {$0["item_id"] as! String}
            switch states[index] {
            case "committed": committed += ids
            case "failed": failed += ids;row["receipt"] = ["error":["code":failure ?? "REVISION_CONFLICT"]]
            default: uncommitted += ids
            }
            return row
        }
        return ["id":id,"selection":entries,"selected_item_ids":entries.map {$0["item_id"] as! String},"action":["disposition":"accepted"],"chunks":chunks,"chunk_results":results,
                "committed_item_ids":committed,"failed_item_ids":failed,"uncommitted_item_ids":uncommitted]
    }
    func bulkSettle(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() {return}
            try await Task.sleep(nanoseconds:5_000_000)
        }
        XCTFail("Synthetic bulk decision did not settle")
    }

    func testBulkAcceptOf250ItemsSendsTheFrozenSelectionInChunksWithStoredCommandIDs() async throws {
        let (peer,store,_,_) = fixture();let model = await setup(peer,store)
        let entries = bulkEntries(250)
        peer.extra["media_bulk_selection"] = bulkSelection(entries)
        peer.extra["media_bulk_prepare"] = bulkView(entries,states:["uncommitted","uncommitted"])
        peer.extra["media_bulk_apply"] = ["chunk":["state":"committed"]]
        peer.sequence["media_bulk_get"] = [bulkView(entries,states:["uncommitted","uncommitted"]),bulkView(entries,states:["committed","uncommitted"]),bulkView(entries,states:["committed","committed"])]
        model.filter = "pending";model.bulk.suggestionFilter = "no_changes";model.bulk.selecting = true;model.selectWholeFilter()
        peer.calls = []
        let pending = await model.bulkConfirmation()
        let confirmation = try XCTUnwrap(pending)
        XCTAssertEqual(confirmation.title,"Accept 250 items?")
        XCTAssertTrue(confirmation.effect.contains("one owner decision for each of these 250 items, in 2 parts"),confirmation.effect)
        // The press itself sends nothing; the confirmation does.
        XCTAssertEqual(peer.calls.map(\.0),["media_bulk_selection"])
        let asked = try XCTUnwrap(peer.calls.first?.1["filter"] as? MediaValues)
        XCTAssertEqual(asked["dispositions"] as? [String],["pending"]);XCTAssertEqual(asked["agent_suggestion_excludes"] as? [String],["changes_requested"])
        confirmation.respond(confirmed:true)
        try await bulkSettle {peer.calls.contains {$0.0=="media_round_header"} && !model.bulk.running}
        XCTAssertFalse(peer.calls.contains {$0.0=="media_decide"})
        let prepare = try XCTUnwrap(peer.calls.first {$0.0=="media_bulk_prepare"}?.1)
        XCTAssertEqual((prepare["items"] as? [MediaValues])?.count,250)
        XCTAssertEqual((prepare["items"] as? [MediaValues])?.first?["winner_id"] as? String,"candidate-0-0")
        XCTAssertEqual(prepare["disposition"] as? String,"accepted");XCTAssertEqual(prepare["observed_context_token"] as? String,"context-1")
        XCTAssertNotNil(prepare["command_id"])
        let applied = peer.calls.filter {$0.0=="media_bulk_apply"}.map(\.1)
        XCTAssertEqual(applied.map {$0["chunk_id"] as? String},["chunk-0","chunk-1"])
        XCTAssertEqual(applied.map {$0["command_id"] as? String},["command-0","command-1"])
        XCTAssertEqual(model.bulk.operation.strings("committed_item_ids").count,250)
        XCTAssertTrue(MediaReviewModel.bulkFailures(model.bulk.operation).isEmpty)
        XCTAssertFalse(model.bulk.hasSelection);XCTAssertNil(model.bulk.error)
    }
    func testFailedChunkIsReportedAndRetrySendsOnlyTheFailedItemsWithTheirTakes() async throws {
        let (peer,store,_,_) = fixture();let model = await setup(peer,store)
        var entries = bulkEntries(201);for index in entries.indices {entries[index]["winner_id"] = "candidate-\(index)-0"}
        let failed = bulkView(entries,states:["committed","failed"])
        model.bulk.operation = Record(values:failed)
        XCTAssertEqual(MediaReviewModel.bulkFailures(model.bulk.operation),["Part 2 of 2: 1 items not decided because an item changed after you selected it."])
        let current = bulkEntries(1).map {row -> MediaValues in var row = row;row["item_id"] = "item-200";row["expected_revision"] = 2;return row}
        peer.extra["media_bulk_selection"] = bulkSelection(current)
        peer.extra["media_bulk_prepare"] = ["id":"retry"]
        peer.extra["media_bulk_get"] = bulkView(current,states:["committed"],id:"retry")
        peer.calls = []
        await model.retryFailedBulk()
        XCTAssertEqual(peer.calls.first {$0.0=="media_bulk_selection"}?.1["item_ids"] as? [String],["item-200"])
        let prepare = try XCTUnwrap(peer.calls.first {$0.0=="media_bulk_prepare"}?.1)
        XCTAssertEqual(prepare["supersedes_operation_id"] as? String,"operation")
        XCTAssertEqual(prepare["disposition"] as? String,"accepted")
        let items = try XCTUnwrap(prepare["items"] as? [MediaValues])
        XCTAssertEqual(items.map {$0["item_id"] as? String},["item-200"])
        XCTAssertEqual(items[0]["expected_revision"] as? Int,2);XCTAssertEqual(items[0]["winner_id"] as? String,"candidate-200-0")
        XCTAssertFalse(peer.calls.contains {$0.0=="media_bulk_apply"})
    }
    func testRetryNeverReplacesADecisionMadeAfterTheSelection() async throws {
        let (peer,store,_,_) = fixture();let model = await setup(peer,store)
        let entries = bulkEntries(202)
        model.bulk.operation = Record(values:bulkView(entries,states:["committed","failed"]))
        var current = Array(entries.suffix(2))
        current[0]["expected_revision"] = 2;current[0]["disposition"] = "changes_requested"
        current[1]["expected_revision"] = 2 // An edited label, still Pending: it stays in the retry.
        peer.extra["media_bulk_selection"] = bulkSelection(current)
        peer.extra["media_bulk_prepare"] = ["id":"retry"]
        peer.extra["media_bulk_get"] = bulkView(Array(current.suffix(1)),states:["committed"],id:"retry")
        peer.calls = []
        await model.retryFailedBulk()
        let prepare = try XCTUnwrap(peer.calls.first {$0.0=="media_bulk_prepare"}?.1)
        XCTAssertEqual((prepare["items"] as? [MediaValues])?.map {$0["item_id"] as? String},["item-201"])
        XCTAssertNil(prepare["supersedes_operation_id"])
        XCTAssertEqual(model.bulk.error,"1 items stay out of this retry because they have a newer decision.")
        // Every failed item has a newer decision: nothing is sent.
        model.bulk.operation = Record(values:bulkView(Array(entries.prefix(1)),states:["failed"]))
        var decided = Array(entries.prefix(1));decided[0]["expected_revision"] = 2;decided[0]["disposition"] = "accepted"
        peer.extra["media_bulk_selection"] = bulkSelection(decided)
        peer.calls = []
        await model.retryFailedBulk()
        XCTAssertFalse(peer.calls.contains {$0.0=="media_bulk_prepare"});XCTAssertTrue(model.bulk.operation.id.isEmpty)
        // A decision the selection already saw (a Needs look filter) has its old revision and stays in.
        XCTAssertFalse(MediaReviewModel.bulkDecidedLater(Record(values:["expected_revision":1,"disposition":"needs_look"]),original:Record(values:["expected_revision":1])))
    }
    func testLostChunkReplyReadsReceiptsAndContinueUsesTheOriginalCommandOnly() async throws {
        let (peer,store,_,_) = fixture();let model = await setup(peer,store)
        let entries = bulkEntries(250)
        peer.extra["media_bulk_prepare"] = bulkView(entries,states:["uncommitted","uncommitted"])
        peer.failures["media_bulk_apply"] = [ChecklistError("OUTCOME_UNKNOWN","The reply was lost.")]
        // The lost chunk did commit: the receipt read says so, and it is never sent again.
        peer.sequence["media_bulk_get"] = [bulkView(entries,states:["uncommitted","uncommitted"]),bulkView(entries,states:["committed","uncommitted"]),
            bulkView(entries,states:["committed","uncommitted"]),bulkView(entries,states:["committed","committed"]),bulkView(entries,states:["committed","committed"])]
        var plan = MediaBulkPlan(disposition:"accepted",note:"");plan.entries = entries;plan.observation = ["round_id":"round"]
        peer.calls = []
        await model.runBulk(plan)
        XCTAssertEqual(peer.calls.filter {$0.0=="media_bulk_apply"}.map {$0.1["chunk_id"] as? String},["chunk-0"])
        XCTAssertEqual(model.bulk.operation.strings("uncommitted_item_ids").count,50)
        XCTAssertNotNil(model.bulk.error)
        await model.continueBulk()
        XCTAssertEqual(peer.calls.filter {$0.0=="media_bulk_apply"}.map {$0.1["command_id"] as? String},["command-0","command-1"])
        XCTAssertEqual(peer.calls.filter {$0.0=="media_bulk_prepare"}.count,1)
        XCTAssertEqual(model.bulk.operation.strings("committed_item_ids").count,250);XCTAssertNil(model.bulk.error)
    }
    func testPlanLeavesOutWhatOnePressMustNotDecide() {
        var entries = bulkEntries(6)
        entries[1]["disposition"] = "accepted"
        entries[2]["disposition"] = "changes_requested"
        entries[3]["candidate_ids"] = ["take-a","take-b"]
        entries[4]["candidate_ids"] = ["take-a","take-b"]
        entries[5]["agent_suggestions"] = ["changes_requested"]
        var noted = MediaOwnerDraft();noted.note = "Redo the arm"
        var chosen = MediaOwnerDraft();chosen.winnerID = "take-b"
        entries.append(contentsOf:bulkEntries(7).suffix(1))
        let selection = Record(values:bulkSelection(entries,unpublished:2))
        let plan = MediaBulkPlan.make(selection:selection,disposition:"accepted",note:"",listFilter:"all",ticked:nil,drafts:["item-4":chosen,"item-6":noted])
        XCTAssertEqual(plan.entries.map {$0["item_id"] as? String},["item-0","item-4","item-5"])
        XCTAssertEqual(plan.entries[1]["winner_id"] as? String,"take-b")
        XCTAssertEqual(plan.alreadyDecided,1);XCTAssertEqual(plan.otherDecision,1);XCTAssertEqual(plan.needsTake,1);XCTAssertEqual(plan.unsentNote,1);XCTAssertEqual(plan.unpublished,2);XCTAssertEqual(plan.agentChanges,1)
        for text in ["already have this decision","another decision","typed note","no chosen take","not published","suggestion of Changes requested"] {XCTAssertTrue(plan.effect.contains(text),text)}
        // A disposition filter or an explicit tick is the owner's own request to change those items.
        XCTAssertEqual(MediaBulkPlan.make(selection:selection,disposition:"accepted",note:"",listFilter:"changes_requested",ticked:nil,drafts:[:]).otherDecision,0)
        let ticks = MediaBulkPlan.make(selection:Record(values:bulkSelection([entries[2]])),disposition:"accepted",note:"",listFilter:"all",ticked:["item-2","gone"],drafts:[:])
        XCTAssertEqual(ticks.entries.count,1);XCTAssertEqual(ticks.gone,1)
        // Several takes: Changes requested says none fit; Needs look selects nothing.
        let changes = MediaBulkPlan.make(selection:Record(values:bulkSelection([entries[3]])),disposition:"changes_requested",note:"Redo",listFilter:"all",ticked:nil,drafts:[:])
        XCTAssertEqual(changes.entries[0]["none_fit"] as? Bool,true);XCTAssertEqual(changes.prepareParams()["note"] as? String,"Redo")
        XCTAssertNil(MediaBulkPlan.make(selection:Record(values:bulkSelection([entries[3]])),disposition:"needs_look",note:"",listFilter:"all",ticked:nil,drafts:[:]).entries[0]["winner_id"])
    }
    func testNewFiltersReachTheListAndDoNotReplaceTheRoundCounts() async throws {
        let (peer,store,_,_) = fixture();peer.rows = [["id":"row","title":"Row","metadata":[:],"disposition":"pending","agent_suggestions":["accepted"]]];let model = await setup(peer,store)
        let closing = model.counts
        peer.calls = [];peer.pageCounts = ["pending":1]
        model.bulk.suggestionFilter = "has";await model.reloadRows()
        XCTAssertEqual((peer.calls.last {$0.0=="media_item_page"}?.1["filter"] as? MediaValues)?["has_agent_suggestion"] as? Bool,true)
        XCTAssertEqual(model.counts,closing)
        var note = MediaOwnerDraft();note.note = "Local only"
        store.windowPreferences.set(try JSONEncoder().encode(note),forKey:"mediaDraft:"+model.projectID+":local-item")
        model.bulk.suggestionFilter = "any";model.bulk.noteFilter = true;await model.reloadRows()
        let filter = try XCTUnwrap(peer.calls.last {$0.0=="media_item_page"}?.1["filter"] as? MediaValues)
        XCTAssertEqual(filter["has_note"] as? Bool,true);XCTAssertEqual(filter["note_item_ids"] as? [String],["local-item"]);XCTAssertNil(filter["has_agent_suggestion"])
        XCTAssertEqual(MediaReviewModel.listFilter(disposition:"all",suggestion:"any",note:false,localNotes:[]).count,0)
        XCTAssertEqual(MediaReviewModel.listFilter(disposition:"pending",suggestion:"none",note:false,localNotes:[])["has_agent_suggestion"] as? Bool,false)
    }
    func testGroupSelectionUsesItsExactMetadataAndAGroupWithNoValueCannotBeSelected() async throws {
        let (peer,store,_,_) = fixture();let model = await setup(peer,store)
        let rows = MediaFlatRow.project([Record(values:["id":"a","title":"A","group_path":[["field_id":"character","value":"Hero","item_count":8],["field_id":"animation_label","value":"walk","item_count":8]]])])
        let header = try XCTUnwrap(rows.first {$0.item == nil && $0.group.count == 2})
        let group = try XCTUnwrap(MediaBulkGroup(title:header.title,path:header.group))
        XCTAssertNil(MediaBulkGroup(title:"No value",path:[["field_id":"character","value":NSNull(),"item_count":2]]))
        peer.extra["media_bulk_selection"] = bulkSelection(bulkEntries(8))
        model.filter = "pending";model.selectBulkGroup(group);peer.calls = []
        let pending = await model.bulkConfirmation()
        XCTAssertEqual(pending?.title,"Accept 8 items?")
        let filter = try XCTUnwrap(peer.calls.first {$0.0=="media_bulk_selection"}?.1["filter"] as? MediaValues)
        let metadata = try XCTUnwrap(filter["metadata"] as? MediaValues)
        XCTAssertEqual(metadata["character"] as? String,"Hero");XCTAssertEqual(metadata["animation_label"] as? String,"walk");XCTAssertEqual(filter["dispositions"] as? [String],["pending"])
    }
    func testTicksSendExactItemsAndAnEmptyPlanSendsNothing() async throws {
        let (peer,store,_,_) = fixture();let model = await setup(peer,store)
        var decided = bulkEntries(1);decided[0]["disposition"] = "accepted"
        peer.extra["media_bulk_selection"] = bulkSelection(decided)
        model.toggleBulkTick("item-0");XCTAssertEqual(model.bulk.selectionText,"1 ticked")
        peer.calls = []
        let pending = await model.bulkConfirmation()
        XCTAssertNil(pending);XCTAssertEqual(model.bulk.error,"No item can take this decision. 1 already have this decision.")
        XCTAssertEqual(peer.calls.first?.1["item_ids"] as? [String],["item-0"])
        XCTAssertFalse(peer.calls.contains {$0.0=="media_bulk_prepare"})
        // A decision that needs a note cannot start without one.
        model.bulk.disposition = "changes_requested";XCTAssertTrue(model.bulk.noteMissing)
        let refused = await model.bulkConfirmation()
        XCTAssertNil(refused)
    }
    func testOnePressAdoptionSendsTheSuggestionAndTheExactDecisionFence() async throws {
        let (peer,store,_,_) = fixture();peer.rows = [["id":"row","title":"Row","metadata":[:],"disposition":"pending"]];let model = await setup(peer,store)
        await model.select("row")
        XCTAssertTrue(model.decisionEnabled)
        model.adoptSuggestion("suggestion-1")
        try await bulkSettle {peer.calls.contains {$0.0=="media_adopt_suggestion"} && !store.busy}
        let sent = try XCTUnwrap(peer.calls.first {$0.0=="media_adopt_suggestion"}?.1)
        XCTAssertEqual(sent["suggestion_id"] as? String,"suggestion-1")
        XCTAssertNil(sent["disposition"]);XCTAssertNil(sent["note"]);XCTAssertNil(sent["winner_id"])
        XCTAssertEqual(sent["observed_context_token"] as? String,"context-1");XCTAssertEqual(sent["manifest_digest"] as? String,"digest")
        let entry = try XCTUnwrap((sent["items"] as? [MediaValues])?.first)
        XCTAssertEqual(entry["item_id"] as? String,"row");XCTAssertEqual(entry["target_id"] as? String,"target-1");XCTAssertEqual(entry["review_basis_signature"] as? String,"basis-1")
        XCTAssertEqual(Set(entry.keys),["item_id","expected_revision","target_id","review_basis_signature"])
    }
}
