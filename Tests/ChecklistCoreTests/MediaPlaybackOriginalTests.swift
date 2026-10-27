import XCTest
import Foundation
@testable import ChecklistCore

/// CL-117: byte-only video validation, playback budgets and exact owner playback leases.
/// Fixtures are small synthetic ISO base media structures, never user media.
final class MediaPlaybackOriginalTests: XCTestCase {
    static func be32(_ value: Int) -> Data { Data([UInt8(value >> 24 & 255), UInt8(value >> 16 & 255), UInt8(value >> 8 & 255), UInt8(value & 255)]) }
    static func box(_ type: String, _ payload: Data) -> Data { be32(8 + payload.count) + Data(type.utf8) + payload }
    static func track(handler: String = "vide", width: Int = 64, height: Int = 48, frames: Int = 20, dref: Data? = nil) -> Data {
        var tkhd = Data(count: 84); tkhd.replaceSubrange(76..<80, with: be32(width << 16)); tkhd.replaceSubrange(80..<84, with: be32(height << 16))
        let hdlr = Data(count: 8) + Data(handler.utf8) + Data(count: 13)
        let entry = dref ?? (be32(12) + Data("url ".utf8) + Data([0, 0, 0, 1]))
        let drefBox = box("dref", Data(count: 4) + be32(1) + entry)
        let stsz = box("stsz", Data(count: 8) + be32(frames))
        let minf = box("minf", box("dinf", drefBox) + box("stbl", stsz))
        return box("trak", box("tkhd", tkhd) + box("mdia", box("hdlr", hdlr) + minf))
    }
    static func movie(seconds: Int = 2, brand: String = "isom", tracks: [Data]? = nil, moovExtra: Data = Data(), mdat: Bool = true) -> Data {
        var mvhd = Data(count: 100); mvhd.replaceSubrange(12..<16, with: be32(600)); mvhd.replaceSubrange(16..<20, with: be32(seconds * 600))
        let moov = box("moov", box("mvhd", mvhd) + (tracks ?? [track()]).reduce(Data(), +) + moovExtra)
        return box("ftyp", Data(brand.utf8) + be32(0) + Data("isom".utf8)) + moov + (mdat ? box("mdat", Data(repeating: 7, count: 64)) : Data())
    }

    func testSelfContainedMovieFactsAndEveryBudgetEdgeRefuse() {
        let facts = try? XCTUnwrap(MediaIntakeMovie.inspect(Self.movie()))
        XCTAssertEqual(facts, MediaPlaybackBudget.Facts(durationSeconds: 2, width: 64, height: 48, frames: 20, hasVideo: true, hasAudio: false))
        XCTAssertNotNil(MediaIntakeMovie.inspect(Self.movie(brand: "qt  ", tracks: [Self.track(), Self.track(handler: "soun", width: 0, height: 0, frames: 100)])))
        XCTAssertEqual(MediaIntakeMovie.inspect(Self.movie(seconds: 600))?.durationSeconds, 600)
        XCTAssertNotNil(MediaIntakeMovie.inspect(Self.movie(tracks: [Self.track(width: 3840, height: 2160, frames: 36_000)])))
        let alias = Self.be32(12) + Data("alis".utf8) + Data([0, 0, 0, 1])
        XCTAssertNotNil(MediaIntakeMovie.inspect(Self.movie(tracks: [Self.track(dref: alias)])), "QuickTime self-reference alias")
        let external = Self.be32(30) + Data("url ".utf8) + Data([0, 0, 0, 0]) + Data("https://invalid/x\0".utf8)
        let refused: [(String, Data)] = [
            ("overlong", Self.movie(seconds: 601)),
            ("pixels", Self.movie(tracks: [Self.track(width: 3841, height: 2160)])),
            ("edge", Self.movie(tracks: [Self.track(width: 8193, height: 2)])),
            ("frames", Self.movie(tracks: [Self.track(frames: 36_001)])),
            ("external data reference", Self.movie(tracks: [Self.track(dref: external)])),
            ("reference movie", Self.movie(moovExtra: Self.box("rmra", Data(count: 8)))),
            ("fragmented", Self.movie(moovExtra: Self.box("mvex", Data()))),
            ("timecode/other track", Self.movie(tracks: [Self.track(), Self.track(handler: "tmcd")])),
            ("audio only", Self.movie(tracks: [Self.track(handler: "soun", width: 0, height: 0)])),
            ("brand", Self.movie(brand: "heic")),
            ("no media data", Self.movie(mdat: false)),
            ("truncated", Self.movie().dropLast()),
            ("no ftyp", Self.movie().dropFirst(20)),
            ("playlist", Data("#EXTM3U\nhttps://invalid/a.mp4\n".utf8)),
        ]
        for (name, bytes) in refused { XCTAssertNil(MediaIntakeMovie.inspect(Data(bytes)), name) }
    }

    func testMeasuredFactsUseDeclaredKindBudgets() {
        let video = MediaPlaybackBudget.Facts(durationSeconds: 3, width: 1920, height: 1080, frames: 90, hasVideo: true, hasAudio: true)
        XCTAssertNil(MediaPlaybackBudget.refusal(video, kind: "video"))
        XCTAssertNotNil(MediaPlaybackBudget.refusal(video, kind: "audio"), "A movie is not an audio-only take")
        XCTAssertNotNil(MediaPlaybackBudget.refusal(video, kind: "image"))
        var long = video; long.durationSeconds = 600.5
        XCTAssertTrue(MediaPlaybackBudget.refusal(long, kind: "video")?.contains("600 s") == true)
        let audio = MediaPlaybackBudget.Facts(durationSeconds: 1800, hasVideo: false, hasAudio: true)
        XCTAssertNil(MediaPlaybackBudget.refusal(audio, kind: "audio"))
        var longAudio = audio; longAudio.durationSeconds = 1800.1
        XCTAssertNotNil(MediaPlaybackBudget.refusal(longAudio, kind: "audio"))
        XCTAssertNotNil(MediaPlaybackBudget.refusal(MediaPlaybackBudget.Facts(durationSeconds: .nan, hasVideo: false, hasAudio: true), kind: "audio"))
        XCTAssertEqual(MediaPlaybackBudget.preparedTakes, 2); XCTAssertEqual(MediaPlaybackBudget.playingTakes, 1)
        XCTAssertEqual(MediaPlaybackBudget.concurrentPreparations, 1); XCTAssertEqual(MediaPlaybackBudget.originalBytes, FilePreviewLimits.fileBytes)
    }

    func testPortableVideoAudioSchemaRefusesNativeClassPathBookmarkPlaybackAndRenderer() throws {
        let forbidden = ["swift_class", "class", "path", "bookmark", "playback_state", "player", "renderer", "decoder", "script"]
        for kind in ["video", "audio"] {
            let slots: [[String: Any]] = [["id": "take", "kind": kind, "required": true], ["id": "reference", "kind": kind]]
            let layout: [String: Any] = ["kind": kind + "_compare", "primary_slot_id": "take", "reference_slot_id": "reference"]
            let valid: [String: Any] = ["schema_version": 1, "id": kind, "name": kind, "slots": slots, "layout": layout]
            let schema = try MediaReviewSchema.parse(valid)
            XCTAssertEqual(schema.layout.referenceSlotID?.rawValue, "reference"); XCTAssertEqual(schema.slots[0].kind.rawValue, kind)
            for key in forbidden {
                var top = valid; top[key] = "Checklist.AVPlayerAdapter"
                XCTAssertThrowsError(try MediaReviewSchema.parse(top), key)
                var slot = slots; slot[0][key] = "/private/var/empty/synthetic-take.mov"
                var raw = valid; raw["slots"] = slot
                XCTAssertThrowsError(try MediaReviewSchema.parse(raw), key)
                var badLayout = layout; badLayout[key] = ["position": 1.5]
                raw = valid; raw["layout"] = badLayout
                XCTAssertThrowsError(try MediaReviewSchema.parse(raw), key)
            }
        }
    }

    func testVideoIntakeOwnerLeaseIsExactReleasableAndUnavailableReasonsAreHonest() throws {
        let helper = MediaFrozenIntakeTests(), f = try MediaFrozenIntakeTests.Fixture()
        let schema: JSON = ["schema_version": 1, "id": "server", "name": "Animation", "slots": [["id": "take", "kind": "video", "required": true], ["id": "reference", "kind": "video"]],
                            "layout": ["kind": "video_compare", "primary_slot_id": "take", "reference_slot_id": "reference"]]
        let round = try f.round(f.type(schema))
        let movie = Self.movie(), path = f.workspace.appendingPathComponent("hero__walk.mp4")
        try movie.write(to: path)
        var intake = try helper.preview(f, round, [["path": path.path]])
        XCTAssertEqual((intake["rows"] as! [JSON])[0]["media_kind"] as? String, "video")
        // Two video slots: the owner-facing mapping must choose the candidate slot.
        intake = try helper.resolve(f, intake, [["row_id": (intake["rows"] as! [JSON])[0]["id"]!, "disposition": "include", "slot_id": "take"]])
        intake = try helper.confirm(f, intake); _ = try helper.capture(f, intake)
        let item = ((try f.publish(round))["items"] as! [JSON])[0]
        func owner(_ method: String, _ input: JSON) throws -> JSON {
            var p = input; p["project_id"] = f.project
            return try f.router.handle(method: method, params: p, caller: f.owner)["data"] as! JSON
        }
        func code(_ method: String, _ input: JSON) -> String? {
            do { _ = try owner(method, input); return nil } catch { return (error as? CoreError)?.code ?? String(describing: Swift.type(of: error)) }
        }
        let detail = try owner("media_item_get", ["round_id": round["id"]!, "item_id": item["id"]!])
        let original = (detail["originals"] as! [JSON])[0], target = detail["target"] as! JSON
        XCTAssertEqual(original["availability"] as? String, "available"); XCTAssertNil(original["unavailable_reason"])
        // Portable candidate slots hold typed IDs/digests only: no path, bookmark, class or player state.
        for slot in ((detail["candidates"] as! [JSON])[0]["slots"] as! [JSON]) {
            XCTAssertEqual(slot["media_kind"] as? String, "video")
            XCTAssertTrue(Set(slot.keys).isDisjoint(with: ["path", "url", "bookmark", "swift_class", "player", "playback_state", "renderer"]), "\(slot.keys)")
        }
        let input: JSON = ["round_id": round["id"]!, "item_id": item["id"]!, "target_id": target["id"]!, "reference_id": original["reference_id"]!]
        var leaseInput = input; leaseInput["representation"] = "lease"; leaseInput["seconds"] = 60
        let lease = try owner("media_original_read", leaseInput)
        let attachment = lease["attachment"] as! JSON
        XCTAssertNil(lease["base64"]); XCTAssertEqual(lease["reference_id"] as? String, original["reference_id"] as? String)
        XCTAssertEqual(attachment["id"] as? String, original["attachment_id"] as? String)
        let leasedPath = try XCTUnwrap(attachment["path"] as? String); XCTAssertTrue(leasedPath.hasPrefix("/"))
        XCTAssertEqual(ChecklistCore.hash(try Data(contentsOf: URL(fileURLWithPath: leasedPath))), original["sha256"] as? String)
        let active = { try f.rows("storage_hold").filter { $0["kind"] as? String == "reader" && $0["state"] as? String == "active" } }
        XCTAssertEqual(try active().map { $0["id"] as? String }, [lease["lease_id"] as? String])
        XCTAssertLessThanOrEqual((lease["expires_at"] as! Double) - Date().timeIntervalSince1970, 61)
        _ = try owner("media_example_read_release", ["lease_id": lease["lease_id"]!])
        XCTAssertTrue(try active().isEmpty)
        // Open original reauthorizes: a second request gets a distinct fresh lease.
        let second = try owner("media_original_read", leaseInput)
        XCTAssertNotEqual(second["lease_id"] as? String, lease["lease_id"] as? String)
        _ = try owner("media_example_read_release", ["lease_id": second["lease_id"]!])
        var wrong = leaseInput; wrong["target_id"] = uuid(); XCTAssertEqual(code("media_original_read", wrong), "MEDIA_BASIS_CHANGED")
        wrong = leaseInput; wrong["representation"] = "path"; XCTAssertEqual(code("media_original_read", wrong), "INVALID_INPUT")
        wrong = input; wrong["seconds"] = 5; XCTAssertEqual(code("media_original_read", wrong), "INVALID_INPUT")
        wrong = leaseInput; wrong["seconds"] = 301; XCTAssertNotNil(code("media_original_read", wrong))
        XCTAssertNil(code("media_original_read", input), "Bytes mode keeps its 8 MiB bound and automatic release")
        XCTAssertTrue(try active().isEmpty)
        // Missing original: honest reason and no lease.
        let stored = try f.record(original["attachment_id"] as! String, "attachment")
        let url = try f.router.managedURL(stored["path"] as! String, family: "objects")
        let saved = try Data(contentsOf: url); try FileManager.default.removeItem(at: url)
        var unavailable = (try owner("media_item_get", ["round_id": round["id"]!, "item_id": item["id"]!])["originals"] as! [JSON])[0]
        XCTAssertEqual(unavailable["availability"] as? String, "unavailable"); XCTAssertEqual(unavailable["unavailable_reason"] as? String, "missing")
        XCTAssertNotNil(code("media_original_read", leaseInput)); XCTAssertTrue(try active().isEmpty)
        try saved.write(to: url)
        // Cleaned original: metadata retained, reason distinct, no lease.
        try f.router.dbQueue.write { db in
            var a = try f.router.record(db, original["attachment_id"] as! String, type: "attachment")
            a["availability"] = "original_cleaned"; try f.router.save(db, a, type: "attachment")
        }
        unavailable = (try owner("media_item_get", ["round_id": round["id"]!, "item_id": item["id"]!])["originals"] as! [JSON])[0]
        XCTAssertEqual(unavailable["availability"] as? String, "unavailable"); XCTAssertEqual(unavailable["unavailable_reason"] as? String, "cleaned")
        XCTAssertEqual(code("media_original_read", leaseInput), "MANAGED_ORIGINAL_UNAVAILABLE"); XCTAssertTrue(try active().isEmpty)
    }
}
