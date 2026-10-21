import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import ChecklistApp
@testable import ChecklistCore

final class ImageInspectionNativeTests: XCTestCase {
    let sha = String(repeating: "a", count: 64)
    func image(_ id: String, name: String, manifest: String = "current", availability: String = "available", expectedSHA: String? = nil) -> ImageReviewCandidate {
        ImageReviewCandidate(file: Record(values: ["id": id, "project_id": "p", "task_id": "t", "name": name, "sha256": sha, "size": 50, "mode": "managed", "availability": availability]), manifestID: manifest, expectedSHA256: expectedSHA)
    }
    func testGroupsKeepEveryCandidateAndNeverGuessAnAmbiguousPreviousImage() {
        let current = [image("front2", name: "front-round2.png"), image("front2b", name: "front-round2.png"), image("rear2", name: "rear-round2.png")]
        let prior = [image("front1", name: "front-round1.png", manifest: "old"), image("front1b", name: "front-round1.png", manifest: "old")]
        let groups = ImageReviewGroup.make(current: current, previous: prior)
        XCTAssertEqual(groups.map(\.viewName), ["front", "rear"])
        XCTAssertEqual(groups[0].current.count, 2); XCTAssertEqual(groups[0].previous.count, 2)
        XCTAssertTrue(groups[1].previous.isEmpty)
        let unicode = ImageReviewGroup.make(current: [image("a", name: "é.png"), image("b", name: "e\u{301}.png")], previous: [])
        XCTAssertEqual(unicode.count, 2)
        let manyCurrent = (0..<1000).map { image("current-\($0)", name: "view\($0 % 50)-round2.png") }
        let manyPrevious = (0..<1000).map { image("previous-\($0)", name: "view\($0 % 50)-round1.png", manifest: "old") }
        let manyGroups = ImageReviewGroup.make(current: manyCurrent, previous: manyPrevious)
        XCTAssertEqual(manyGroups.count, 50)
        XCTAssertEqual(manyGroups.reduce(0) { $0 + $1.current.count }, 1000)
        XCTAssertEqual(manyGroups.reduce(0) { $0 + $1.previous.count }, 1000)
    }
    func testCleanedMissingChangedAndStaleMarksCannotEnableApproval() {
        let current = image("a", name: "front.png")
        XCTAssertFalse(ImageReviewProjection.readyToApprove([current], selection: [], problem: ""))
        XCTAssertTrue(ImageReviewProjection.readyToApprove([current], selection: [current.identity], problem: ""))
        for state in ["original_cleaned", "unavailable", "missing"] {
            let unavailable = image("a", name: "front.png", availability: state)
            XCTAssertFalse(ImageReviewProjection.readyToApprove([unavailable], selection: [current.identity], problem: ""))
        }
        let changed = image("a", name: "front.png", expectedSHA: String(repeating: "b", count: 64))
        XCTAssertNotNil(changed.unavailable)
        XCTAssertFalse(ImageReviewProjection.readyToApprove([current], selection: [image("a", name: "front.png", manifest: "old").identity], problem: ""))
        XCTAssertFalse(ImageReviewProjection.readyToApprove([current], selection: [current.identity], problem: "The exact set could not be loaded"))
    }
    func testInspectionDraftSurvivesRoundTripButIsClearedForARevisedForm() throws {
        var draft = AnswerDraft(revision: 1)
        draft.inspectedImages = [image("front", name: "front.png").identity.record]
        draft.values = ["q": "approved"]; draft.explanation = "Keep this note"
        let restored = try JSONDecoder().decode(AnswerDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(restored.inspectedImages, draft.inspectedImages)
        XCTAssertTrue(try JSONDecoder().decode(AnswerDraft.self, from: Data("{}".utf8)).inspectedImages.isEmpty)
        let request = Record(values: ["id": "r", "revision": 2, "form_revision": 2, "form_identity": "new-form", "questions": [["id": "q", "type": "approval"]], "file_requests": []])
        let next = RequestDraftIdentity.adoptingCurrentForm(restored, request: request)
        XCTAssertTrue(next.inspectedImages.isEmpty); XCTAssertNil(next.values["q"])
        XCTAssertEqual(next.explanation, "Keep this note")
        XCTAssertEqual(restored.inspectedImages.count, 1, "The caller's separately archived draft retains the original selections")
    }
    func testPreviousRoundSelectionDoesNotUseALaterOrAmbiguousTarget() {
        let task = Record(values: ["id": "t", "project_id": "p", "current_manifest_id": "latest"])
        func manifest(_ id: String, _ time: String) -> [String: Any] { ["id": id, "task_id": "t", "project_id": "p", "created_at": time] }
        let rows = [manifest("first", "2026-10-20T00:00:01Z"), manifest("second", "2026-10-20T00:00:02Z"), manifest("latest", "2026-10-20T00:00:03Z")]
        let projection = ReviewProjection(task: task, project: nil, data: ["manifests": rows])
        XCTAssertEqual(ImageReviewProjection.previous(to: Record(values: rows[1]), review: projection)?.id, "first")
        let ambiguous = ReviewProjection(task: task, project: nil, data: ["manifests": [rows[0], rows[1], manifest("tie", "2026-10-20T00:00:02Z")]])
        XCTAssertNil(ImageReviewProjection.previous(to: Record(values: rows[1]), review: ambiguous))
    }
    func testActualPixelDecodeSpriteCropAndGIFFrameSelectionUseOriginalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImageDecoder-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func bitmap(_ red: CGFloat, _ blue: CGFloat) -> CGImage {
            let context = CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 0.5)); context.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
            return context.makeImage()!
        }
        let first = bitmap(1, 0), second = bitmap(0, 1)
        let png = root.appendingPathComponent("sprite.png")
        let pngWriter = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(pngWriter, first, nil); XCTAssertTrue(CGImageDestinationFinalize(pngWriter))
        XCTAssertEqual(try FilePreviewThumbnailDecoder.retainedPreview(path: png.path)?.width, 16)
        let alias = root.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: png)
        XCTAssertNil(try FilePreviewThumbnailDecoder.retainedPreview(path: alias.path))
        let oversized = root.appendingPathComponent("oversized.png")
        try Data(repeating: 0, count: FilePreviewThumbnailDecoder.retainedBytes + 1).write(to: oversized)
        XCTAssertNil(try FilePreviewThumbnailDecoder.retainedPreview(path: oversized.path))
        let original = try NativeImageDecoder.decode(url: png, original: true)
        XCTAssertEqual(original.0.width, 16); XCTAssertEqual(original.0.height, 8)
        XCTAssertEqual(original.2.size, CGSize(width: 16, height: 8))
        let jpeg = root.appendingPathComponent("oriented.jpg")
        let jpegWriter = CGImageDestinationCreateWithURL(jpeg as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(jpegWriter, first, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(jpegWriter))
        let oriented = try NativeImageDecoder.decode(url: jpeg, original: true)
        XCTAssertEqual(oriented.2.orientation, 6)
        XCTAssertEqual(oriented.2.displaySize(oriented.1), CGSize(width: 8, height: 16))
        let grid = try SpriteSheetLayout(columns: 2, rows: 1)
        let crop = try NativeImageDecoder.decode(url: png, original: true, crop: grid.frameRect(index: 1, width: 16, height: 8))
        XCTAssertEqual(crop.0.width, 8); XCTAssertEqual(crop.1, CGSize(width: 8, height: 8))
        XCTAssertThrowsError(try NativeImageDecoder.decode(url: png, original: true, crop: CGRect(x: 15, y: 0, width: 2, height: 8)))
        let gif = root.appendingPathComponent("animation.gif")
        let gifWriter = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 2, nil)!
        let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary
        CGImageDestinationAddImage(gifWriter, first, properties); CGImageDestinationAddImage(gifWriter, second, properties)
        XCTAssertTrue(CGImageDestinationFinalize(gifWriter))
        let frame0 = try NativeImageDecoder.decode(url: gif, original: true, index: 0)
        let frame1 = try NativeImageDecoder.decode(url: gif, original: true, index: 1)
        XCTAssertEqual(frame1.2.frameCount, 2); XCTAssertEqual(frame1.2.frameDuration, 0.2, accuracy: 0.02)
        XCTAssertNotEqual(frame0.0.dataProvider!.data! as Data, frame1.0.dataProvider!.data! as Data)
        XCTAssertThrowsError(try NativeImageDecoder.decode(url: gif, original: true, index: 2))
    }
    func testReviewContextDrivesChooserNamedPreviousImagesAndEarlierMeasureWarning() throws {
        let task = Record(values:["id":"t","project_id":"p","current_manifest_id":"round2"])
        var files: [[String:Any]] = [], manifests: [[String:Any]] = []
        for round in 1...2 {
            var refs: [[String:Any]] = []
            for view in ["front","rear","corner"] {
                let id = "\(view)-\(round)"
                // All six originals intentionally share bytes/hash; explicit view names win.
                files.append(["id":id,"task_id":"t","project_id":"p","name":"output-\(id).png","sha256":sha,"availability":"available","mode":"managed"])
                refs.append(["artifact_id":id,"sha256":sha,"view_name":view])
            }
            manifests.append(["id":"round\(round)","task_id":"t","project_id":"p","created_at":"2026-10-21T00:00:00Z","previous_manifest_id":round == 2 ? "round1" as Any : NSNull(),"evidence":["artifact_refs":refs,"measures":[["name":"Triangles","unit":"triangles","limit":25000,"before":32000,"after":round == 1 ? 26000 : 24000]]]])
        }
        let history: [String:Any] = ["manifests":manifests,"attachments":files,"reviews":[["id":"old-pass","task_id":"t","project_id":"p","manifest_id":"round1","verdict":"pass"]]]
        let data: [String:Any] = ["manifests":[manifests[1]],"attachments":Array(files.suffix(3)),"review_target_history":history]
        let display = ReviewTargetPresentation.projection(task:task,project:nil,data:data)
        let current = try XCTUnwrap(display.current)
        let previous = try XCTUnwrap(ImageReviewProjection.previous(to:current,review:display))
        XCTAssertEqual(previous.id,"round1")
        XCTAssertNotNil(display.manifests.first { $0.id == "round1" },"The chooser and finding-selection lookup receive the earlier target")
        XCTAssertNil(ImageReviewProjection.previous(to:previous,review:display))
        let groups = ImageReviewGroup.make(current:ImageReviewProjection.candidates(manifest:current,review:display),previous:ImageReviewProjection.candidates(manifest:previous,review:display))
        XCTAssertEqual(Set(groups.map(\.viewName)),["front","rear","corner"])
        for group in groups {
            XCTAssertEqual(group.current.count,1);XCTAssertEqual(group.previous.count,1)
            XCTAssertEqual(group.current.first?.file.id,group.viewName+"-2")
            XCTAssertEqual(group.previous.first?.file.id,group.viewName+"-1")
            XCTAssertEqual(group.previous.first?.identity.targetManifestID,"round1")
        }
        let measures = EvidenceMeasuresProjection(review:display)
        let old = try XCTUnwrap(measures.snapshots.first {$0.manifestID == "round1"})
        XCTAssertEqual(old.measures.first?.after,26000);XCTAssertEqual(old.measures.first?.limit,25000)
        XCTAssertTrue(old.measures.first?.overLimit == true)
        XCTAssertFalse(try XCTUnwrap(measures.snapshots.first {$0.manifestID == "round2"}).measures[0].overLimit)
        XCTAssertTrue(display.reviews.isEmpty,"Presentation history cannot add an old passing verdict to action authority")
    }

}
