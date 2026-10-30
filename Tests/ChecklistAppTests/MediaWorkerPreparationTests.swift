import XCTest
@testable import ChecklistApp

/// CL-332 / CL-336: synthetic owner transport only, with no service, keychain or originals.
extension MediaOwnerSliceTests {
    func testPreparedDraftPublishesWithOnePressAndExactFreshPreviewWithoutOwnerIntake() async throws {
        let (peer,store,_,_)=fixture();let model=await setup(peer,store)
        model.header=Record(values:["id":"round","origin":"agent","state":"draft","revision":4,"observed_context_token":"older-context"])
        model.publication=[Record(values:["item_id":"older-manual-preview","publication_ready":true])]
        peer.calls=[]
        peer.onRequest={method in
            if method=="media_publication_preview" {
                // A changing displayed page/context cannot retarget the frozen reply.
                model.filter="accepted";model.rows=[]
                model.header=Record(values:["id":"round","origin":"agent","state":"draft","revision":99,"observed_context_token":"later-context"])
            }
        }
        XCTAssertTrue(model.preparedPublicationAvailable)
        await model.publishPreparedRound()
        try await settle {peer.calls.contains {$0.0=="media_round_publish"} && !store.busy}
        let previews=peer.calls.filter {$0.0=="media_publication_preview"}
        let publishes=peer.calls.filter {$0.0=="media_round_publish"}
        XCTAssertEqual(previews.count,1);XCTAssertEqual(publishes.count,1)
        let sent=try XCTUnwrap(publishes.first?.1)
        XCTAssertEqual(sent["project_id"] as? String,peer.project)
        XCTAssertEqual(sent["round_id"] as? String,"round")
        XCTAssertEqual(sent["expected_revision"] as? Int,1)
        XCTAssertEqual(sent["observed_context_token"] as? String,"context-1")
        XCTAssertNotNil(sent["command_id"],"Publication uses the durable owner command path")
        let items=try XCTUnwrap(sent["items"] as? [MediaValues])
        XCTAssertEqual(items.count,1)
        XCTAssertEqual(items[0]["item_id"] as? String,"frozen-item")
        XCTAssertEqual(items[0]["target_id"] as? String,"frozen-target")
        XCTAssertEqual(items[0]["review_basis_signature"] as? String,"frozen-basis")
        XCTAssertEqual(items[0]["expected_revision"] as? Int,1)
        XCTAssertEqual(Set(items[0].keys),["item_id","expected_revision","target_id","review_basis_signature"])
        XCTAssertFalse(peer.calls.contains {$0.0.hasPrefix("media_intake_") || $0.0=="media_item_create" || $0.0=="media_decide"})
        XCTAssertEqual(model.roundState,"open");XCTAssertFalse(model.publishingPrepared)
    }

    func testPreparedPublicationIsOnlyOfferedForSelectedAgentDraftAndDropsRetiredSelection() async throws {
        let (peer,store,_,_)=fixture();let model=await setup(peer,store)
        func header(_ origin:String,_ state:String="draft",_ id:String="round") -> Record {Record(values:["id":id,"origin":origin,"state":state,"revision":1])}
        for value in [header("human_ui"),header("agent","open"),header("agent","closed"),header("agent","draft","other")] {
            model.header=value;XCTAssertFalse(model.preparedPublicationAvailable)
        }
        model.header=header("agent");model.historyOnly=true;XCTAssertFalse(model.preparedPublicationAvailable)
        model.historyOnly=false;XCTAssertTrue(model.preparedPublicationAvailable)
        peer.calls=[]
        peer.onRequest={method in if method=="media_publication_preview" {model.chooseRound("other")}}
        await model.publishPreparedRound()
        XCTAssertFalse(peer.calls.contains {$0.0=="media_round_publish"},"An owner press cannot follow a different round selection")
        XCTAssertFalse(model.publishingPrepared)
    }

    func testAgentSuggestionsHaveSourceChoiceNoteAndHistoricalWarningWithoutAdoptingOwnerDraft() async throws {
        let (peer,store,_,_)=fixture();let model=await setup(peer,store)
        let note="Keep the stronger silhouette.\nLiteral second line."
        let suggestion:MediaValues=["id":"suggestion-current","origin":"agent","source_label":"Codex · abcdef12","created_at":"2026-10-28T18:00:00Z","target_id":"target","review_basis_signature":"basis","disposition":"accepted","winner_id":"second","note":note,"stale":false]
        var earlier=suggestion;earlier["id"]="suggestion-earlier";earlier["target_id"]="old-target";earlier["winner_id"]="old-candidate";earlier["stale"]=true
        var forged=suggestion;forged["id"]="not-an-agent-suggestion";forged["origin"]="human_ui"
        model.item=Record(values:["id":"item","disposition":"pending","target":["id":"target","review_basis_signature":"basis"],"candidates":[["id":"first"],["id":"second"]],"suggestions":[suggestion,earlier,forged]])
        model.draft.note="My unsent owner note";model.draft.winnerID="first"
        let draft=model.draft,callCount=peer.calls.count
        let displayed=MediaComparisonLabels.suggestions(item:model.item)
        XCTAssertEqual(displayed.map(\.id),["suggestion-current","suggestion-earlier"])
        XCTAssertTrue(displayed[0].source.hasPrefix("Codex · abcdef12 · "))
        XCTAssertEqual(displayed[0].choice,"Accepted · Candidate 2")
        XCTAssertEqual(displayed[0].note,note);XCTAssertTrue(displayed[0].isCurrent)
        XCTAssertEqual(displayed[1].choice,"Accepted · Earlier candidate");XCTAssertFalse(displayed[1].isCurrent)
        XCTAssertEqual(model.item.string("disposition"),"pending")
        XCTAssertTrue(model.item.object("decision").isEmpty)
        XCTAssertEqual(model.draft,draft);XCTAssertEqual(peer.calls.count,callCount)
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/ChecklistApp/Media")
        let comparison=try String(contentsOf:root.appendingPathComponent("MediaOwnerComparison.swift"),encoding:.utf8)
        XCTAssertTrue(comparison.contains("ForEach(MediaComparisonLabels.suggestions(item:model.item))"))
        XCTAssertTrue(comparison.contains("Text(\"Agent suggestion\")"))
        XCTAssertTrue(comparison.contains("Text(suggestion.note).textSelection(.enabled)"))
        let workspace=try String(contentsOf:root.appendingPathComponent("MediaReviewWorkspace.swift"),encoding:.utf8)
        XCTAssertTrue(workspace.contains("Button(\"Publish\") {Task {await model.publishPreparedRound()}}"))
    }
}
