import XCTest
import Foundation
@testable import ChecklistCore

/// CL-308: rows of one explicit candidate group that fill different slots (Take and
/// Reference) join one candidate, so a video or audio round publishes complete.
final class MediaGroupJoinTests: XCTestCase {
    let helper = MediaFrozenIntakeTests()

    /// The native "Video takes"/"Audio takes" starter schema (MediaReviewWorkspace.schema).
    func starter(_ kind: String, maxCandidates: Int? = nil) -> JSON {
        var value: JSON = ["schema_version": 1, "id": "server", "name": kind,
            "slots": [["id": "take", "label": "Take", "kind": kind, "material": true], ["id": "reference", "label": "Reference", "kind": kind, "material": true]],
            "layout": ["kind": kind + "_compare", "primary_slot_id": "take", "reference_slot_id": "reference"]]
        value["max_candidates"] = maxCandidates
        return value
    }
    func wav(seconds: Int) -> Data {
        let payload = 8000 * 2 * seconds
        var wav = Data("RIFF".utf8)
        func word(_ value: UInt16) { wav.append(UInt8(value & 255)); wav.append(UInt8(value >> 8)) }
        func dword(_ value: UInt32) { word(UInt16(value & 65535)); word(UInt16(value >> 16)) }
        dword(UInt32(36 + payload)); wav.append(Data("WAVEfmt ".utf8)); dword(16); word(1); word(1); dword(8000); dword(16000); word(2); word(16)
        wav.append(Data("data".utf8)); dword(UInt32(payload)); wav.append(Data(repeating: 1, count: payload))
        return wav
    }
    func write(_ f: MediaFrozenIntakeTests.Fixture, _ name: String, _ data: Data) throws -> JSON {
        let path = f.workspace.appendingPathComponent(name); try data.write(to: path); return ["path": path.path]
    }
    /// Resolves rows (in source order) to the named slots in one explicit group, confirms,
    /// then captures one row per call in the given order.
    func groupAndCapture(_ f: MediaFrozenIntakeTests.Fixture, _ round: JSON, _ sources: [JSON], slots: [String], captureOrder: [Int]) throws -> [JSON] {
        var intake = try helper.preview(f, round, sources)
        let rows = (intake["rows"] as! [JSON]).sorted { int($0, "order") < int($1, "order") }
        XCTAssertEqual(rows.count, slots.count)
        intake = try helper.resolve(f, intake, zip(rows, slots).map { ["row_id": $0["id"]!, "slot_id": $1, "group_id": "ar42b-g1", "disposition": "include"] })
        XCTAssertEqual((intake["groups"] as! [JSON]).count, 1)
        intake = try helper.confirm(f, intake)
        for index in captureOrder { intake = try helper.capture(f, intake, [rows[index]["id"] as! String]) }
        XCTAssertTrue(strings(intake, "remaining_row_ids").isEmpty)
        return rows
    }
    func draftCandidates(_ f: MediaFrozenIntakeTests.Fixture) throws -> [JSON] {
        let items = try f.rows("media_item"); XCTAssertEqual(items.count, 1)
        let target = try f.record(items[0]["draft_target_id"] as! String, "media_item_target")
        return try strings(target, "candidate_ids").map { try f.record($0, "media_candidate") }
    }
    func slotIDs(_ candidate: JSON) -> [String] { (candidate["slots"] as! [JSON]).map { $0["slot_id"] as! String } }

    func testVideoAndAudioGroupJoinTakeAndReferenceIntoOneCompleteCandidate() throws {
        let movies = [MediaPlaybackOriginalTests.movie(seconds: 2, tracks: [MediaPlaybackOriginalTests.track(width: 80, height: 60, frames: 24)]),
                      MediaPlaybackOriginalTests.movie(seconds: 1, tracks: [MediaPlaybackOriginalTests.track(width: 64, height: 48, frames: 12)])]
        let cases: [(String, [Data], [String])] = [("video", movies, ["r42b-ref-80x60-24f.mp4", "r42b-take-64x48-12f.mp4"]),
                                                   ("audio", [wav(seconds: 2), wav(seconds: 1)], ["tone-660hz-2s.wav", "tone-440hz-1s.wav"])]
        for (kind, data, names) in cases {
            // Each capture order (Reference first, Take first) gives the same single candidate.
            for captureOrder in [[0, 1], [1, 0]] {
                let f = try MediaFrozenIntakeTests.Fixture(), round = try f.round(f.type(starter(kind)))
                let sources = try zip(names, data).map { try write(f, $0, $1) }
                let rows = try groupAndCapture(f, round, sources, slots: ["reference", "take"], captureOrder: captureOrder)
                XCTAssertEqual(rows.map { $0["media_kind"] as? String }, [kind, kind])
                let candidates = try draftCandidates(f)
                XCTAssertEqual(candidates.count, 1, "\(kind) \(captureOrder)")
                XCTAssertEqual(slotIDs(candidates[0]), ["reference", "take"], "\(kind) \(captureOrder)")
                let bySlot = Dictionary(uniqueKeysWithValues: (candidates[0]["slots"] as! [JSON]).map { ($0["slot_id"] as! String, $0) })
                XCTAssertEqual(bySlot["reference"]?["sha256"] as? String, rows[0]["sha256"] as? String)
                XCTAssertEqual(bySlot["take"]?["sha256"] as? String, rows[1]["sha256"] as? String)
                XCTAssertEqual(candidates[0]["source_name"] as? String, rows[0]["name"] as? String, "The group's earliest row names the candidate")
                // Every committed row of the group names the joined candidate.
                let committed = try f.rows("media_intake_row").filter { $0["capture_state"] as? String == "committed" }
                XCTAssertEqual(Set(committed.compactMap { $0["candidate_id"] as? String }), [candidates[0]["id"] as! String])
                // Publication preview: no incomplete item; publish succeeds with one item.
                let observed = try f.get(round), items = observed["items"] as! [JSON]
                XCTAssertEqual(items.count, 1)
                XCTAssertEqual((items[0]["publication_preview"] as! JSON)["publication_ready"] as? Bool, true, "\(kind) \(captureOrder)")
                let owner = try f.router.handle(method: "media_publication_preview", params: ["project_id": f.project, "round_id": round["id"]!], caller: f.owner)["data"] as! JSON
                let preview = owner["items"] as! [JSON]
                XCTAssertEqual(preview.count, 1); XCTAssertEqual(preview.filter { $0["publication_ready"] as? Bool != true }.count, 0)
                let published = try f.publish(round)
                XCTAssertEqual(((published["manifest"] as! JSON)["items"] as! [JSON]).count, 1)
                let after = ((try f.get(round))["items"] as! [JSON])[0]
                XCTAssertEqual(strings(after["published_target"] as! JSON, "candidate_ids"), [candidates[0]["id"] as! String])
            }
        }
    }

    func testTwoTakesAndOneReferenceMakeTwoCandidatesInPlanOrder() throws {
        let f = try MediaFrozenIntakeTests.Fixture(), round = try f.round(f.type(starter("video")))
        let sources = try [(80, 60), (64, 48), (32, 24)].enumerated().map { index, size in
            try write(f, "group-\(index).mp4", MediaPlaybackOriginalTests.movie(tracks: [MediaPlaybackOriginalTests.track(width: size.0, height: size.1)]))
        }
        // Take A (first), Take B (second), Reference (third); captured Reference, B, A.
        let rows = try groupAndCapture(f, round, sources, slots: ["take", "take", "reference"], captureOrder: [2, 1, 0])
        let candidates = try draftCandidates(f)
        XCTAssertEqual(candidates.count, 2)
        let joined = try XCTUnwrap(candidates.first { slotIDs($0).count == 2 }), single = try XCTUnwrap(candidates.first { slotIDs($0).count == 1 })
        XCTAssertEqual(slotIDs(joined), ["reference", "take"])
        let joinedTake = (joined["slots"] as! [JSON]).first { $0["slot_id"] as? String == "take" }
        XCTAssertEqual(joinedTake?["sha256"] as? String, rows[0]["sha256"] as? String, "The first Take joins the first Reference")
        XCTAssertEqual((single["slots"] as! [JSON])[0]["sha256"] as? String, rows[1]["sha256"] as? String)
        let observed = try f.get(round)
        XCTAssertEqual(((observed["items"] as! [JSON])[0]["publication_preview"] as! JSON)["publication_ready"] as? Bool, true)
        _ = try f.publish(round)
    }

    func testMixedImageAndVideoReferencesJoinOneTakeAndPublishTogether() throws {
        var schema=starter("video",maxCandidates:1)
        schema["slots"]=[["id":"take","kind":"video","material":true],["id":"sheet","kind":"image","material":true],
            ["id":"concept","kind":"image","material":true],["id":"earlier","kind":"video","material":true]]
        schema["layout"]=["kind":"video_compare","primary_slot_id":"take","reference_slot_ids":["sheet","concept","earlier"],"loop":true,"frame_rate":12]
        let f=try MediaFrozenIntakeTests.Fixture(),round=try f.round(f.type(schema))
        let movie=MediaPlaybackOriginalTests.movie(seconds:1,tracks:[MediaPlaybackOriginalTests.track(width:64,height:48,frames:12)])
        let sources=try [write(f,"1-take.mp4",movie),write(f,"2-sheet.png",helper.png),
            write(f,"3-concept.png",helper.png),write(f,"4-earlier.mp4",movie)]
        _ = try groupAndCapture(f,round,sources,slots:["take","sheet","concept","earlier"],captureOrder:[3,1,0,2])
        let candidates=try draftCandidates(f)
        XCTAssertEqual(candidates.count,1)
        XCTAssertEqual(slotIDs(candidates[0]),["concept","earlier","sheet","take"])
        let published=try f.publish(round),items=published["items"] as! [JSON]
        XCTAssertEqual(items.count,1)
        let detail=try f.router.handle(method:"media_item_get",params:["project_id":f.project,"round_id":round["id"]!,"item_id":items[0]["id"]!],caller:f.owner)["data"] as! JSON
        XCTAssertEqual((detail["candidates"] as! [JSON]).count,1)
        XCTAssertEqual((detail["originals"] as! [JSON]).count,4)
        XCTAssertTrue((detail["originals"] as! [JSON]).allSatisfy {$0["availability"] as? String == "available"})
    }

    func testConfirmCountsJoinedCandidatesNotRows() throws {
        // One candidate allowed: Take + Reference join into one, so the plan confirms.
        let f = try MediaFrozenIntakeTests.Fixture(), round = try f.round(f.type(starter("video", maxCandidates: 1)))
        let sources = try [(80, 60), (64, 48)].enumerated().map { index, size in
            try write(f, "limit-\(index).mp4", MediaPlaybackOriginalTests.movie(tracks: [MediaPlaybackOriginalTests.track(width: size.0, height: size.1)]))
        }
        _ = try groupAndCapture(f, round, sources, slots: ["reference", "take"], captureOrder: [0, 1])
        XCTAssertEqual(try draftCandidates(f).count, 1)
        // Two Takes in one group still make two candidates and exceed the limit at confirm.
        let g = try MediaFrozenIntakeTests.Fixture(), limited = try g.round(g.type(starter("video", maxCandidates: 1)))
        let takes = try [(80, 60), (64, 48)].enumerated().map { index, size in
            try write(g, "takes-\(index).mp4", MediaPlaybackOriginalTests.movie(tracks: [MediaPlaybackOriginalTests.track(width: size.0, height: size.1)]))
        }
        var intake = try helper.preview(g, limited, takes)
        intake = try helper.resolve(g, intake, (intake["rows"] as! [JSON]).map { ["row_id": $0["id"]!, "slot_id": "take", "group_id": "g", "disposition": "include"] })
        XCTAssertThrowsError(try helper.confirm(g, intake)) { XCTAssertEqual(($0 as? CoreError)?.code, "MEDIA_MAPPING_REQUIRED") }
    }
}
