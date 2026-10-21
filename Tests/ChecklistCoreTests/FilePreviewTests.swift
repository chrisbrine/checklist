import XCTest
@testable import ChecklistCore

final class FilePreviewTests: XCTestCase {
    func testPortableDetectionAndActiveContentIsSource() {
        let expected: [(String, FilePreviewKind)] = [("readme.MD", .markdown), ("sprite.gif", .image), ("clip.mp4", .video), ("voice.wav", .audio), ("report.pdf", .pdf), ("code.swift", .text), ("diagram.svg", .text), ("page.html", .text), ("archive.zip", .unsupported)]
        for (name, kind) in expected { XCTAssertEqual(FilePreviewKind.detect(name: name), kind, name) }
        XCTAssertEqual(FilePreviewKind.detect(name: "no-extension", contentType: "image/png"), .image)
        XCTAssertEqual(FilePreviewKind.detect(name: "attack.svg", contentType: "image/png"), .text)
    }
    func testDeclarativePresentationDoesNotChooseDecoderOrPath() {
        let value = FilePreviewPresentation.resolved(kind: .image, metadata: ["layout": "video", "path": "/etc/passwd", "scale": "actual_pixels", "nearest_neighbor": true, "accessible_label": "Front view"])
        XCTAssertEqual(value.layout, .image); XCTAssertEqual(value.scale, .actualPixels)
        XCTAssertTrue(value.nearestNeighbor); XCTAssertEqual(value.accessibleLabel, "Front view")
        XCTAssertEqual(FilePreviewPresentation.resolved(kind: .text, metadata: ["scale": "execute"]).scale, .fit)
    }
    func testExistingMediaSlotsAdaptToTheSharedPresentationContract() throws {
        let schema = try MediaReviewSchema.parse(["schema_version": 1, "id": "images", "name": "Image review", "slots": [["id": "candidate", "label": "Front candidate", "kind": "image", "required": true], ["id": "reference", "kind": "image"]], "layout": ["kind": "image_compare", "primary_slot_id": "candidate", "reference_slot_id": "reference"]])
        let result = schema.filePreviewPresentation(slotID: try MediaReviewID("candidate"), metadata: ["scale": "actual_pixels", "nearest_neighbor": true])
        XCTAssertEqual(result?.layout, .image); XCTAssertEqual(result?.scale, .actualPixels)
        XCTAssertEqual(result?.accessibleLabel, "Front candidate")
        XCTAssertEqual(result?.nearestNeighbor, true)
        XCTAssertNil(schema.filePreviewPresentation(slotID: try MediaReviewID("unknown")))
    }
    func testCapabilitiesAreSeparateFromDetectionAndNeedNativeCodecProbes() {
        XCTAssertFalse(FilePreviewCapability.assess(kind: .text, size: FilePreviewLimits.textBytes + 1).builtIn)
        XCTAssertTrue(FilePreviewCapability.assess(kind: .video, size: 120).requiresDecoderProbe)
        XCTAssertFalse(FilePreviewCapability.assess(kind: .unsupported, size: 12).builtIn)
        XCTAssertFalse(FilePreviewCapability.assess(kind: .image, size: -1).builtIn)
        XCTAssertTrue(FilePreviewCapability.assess(kind: .markdown, size: 120).builtIn)
        XCTAssertTrue(FilePreviewCapability.assess(kind: .pdf, size: FilePreviewLimits.pdfBytes).builtIn)
        XCTAssertFalse(FilePreviewCapability.assess(kind: .pdf, size: FilePreviewLimits.pdfBytes + 1).builtIn)
    }
    func testMarkdownDocumentRendersRequiredBlocksAndPreservesCode() {
        let value = MarkdownDocument.parse("# Heading\n\nA [link](https://example.invalid)\n- First\n2. Second\n> Quote\n\n| Name | Value |\n| --- | :---: |\n| image | 2 |\n\n```swift\nprint(\"never run\")\n```\n![Front](front.png)\n<script>alert(1)</script>")
        XCTAssertTrue(value.blocks.contains(.heading(1, "Heading")))
        XCTAssertTrue(value.blocks.contains(.list("•", "First")))
        XCTAssertTrue(value.blocks.contains(.list("2.", "Second")))
        XCTAssertTrue(value.blocks.contains(.quote("Quote")))
        XCTAssertTrue(value.blocks.contains(.table([["Name", "Value"], ["image", "2"]])))
        XCTAssertTrue(value.blocks.contains(.code("swift", "print(\"never run\")")))
        XCTAssertTrue(value.blocks.contains(.image("Front", "front.png")))
        XCTAssertTrue(value.blocks.contains(.paragraph("<script>alert(1)</script>")))
        XCTAssertTrue(value.warnings.isEmpty)
    }
    func testMarkdownMalformedAndCancellationAreUsefulFallbacks() {
        let fence = MarkdownDocument.parse("```\nliteral")
        XCTAssertEqual(fence.blocks, [.code("", "literal")]); XCTAssertFalse(fence.warnings.isEmpty)
        XCTAssertTrue(MarkdownDocument.parse(String(repeating: "a", count: FilePreviewLimits.textBytes + 1)).blocks.isEmpty)
        XCTAssertEqual(MarkdownDocument.parse("# hi", isCanceled: { true }).warnings, ["Preview canceled"])
        XCTAssertEqual(MarkdownDocument.parse(String(repeating: "line\n", count: 5000)).blocks.count, 4096)
    }
    func testInlineImagesRenderWithinABoundedDocument() {
        let result = MarkdownDocument.parse("Before ![Front](front.png) after")
        XCTAssertEqual(result.blocks, [.paragraph("Before "), .image("Front", "front.png"), .paragraph(" after")])
        let crowded = MarkdownDocument.parse(String(repeating: "![a](a.png) ", count: 30_000))
        XCTAssertLessThanOrEqual(crowded.blocks.count, 4096)
    }
    func testMarkdownResourcesRequireExactAttachedNamesAndNeverFetchImages() {
        let files = ["front.png": "image-id", "report.md": "report-id"]
        XCTAssertEqual(MarkdownResource.resolve("./front.png", image: true, attachments: files), .attachment("image-id"))
        XCTAssertEqual(MarkdownResource.resolve("report.md", image: false, attachments: files), .attachment("report-id"))
        for path in ["../front.png", "%2e%2e/front.png", "/front.png", "file:///front.png", "javascript:alert(1)", "data:image/png;base64,a", "a\\front.png", "unknown.png", "https://example.invalid/front.png"] {
            guard case .unavailable = MarkdownResource.resolve(path, image: true, attachments: files) else { return XCTFail(path) }
        }
        guard case .externalLink = MarkdownResource.resolve("https://example.invalid", image: false, attachments: files) else { return XCTFail("Explicit web link should be actionable") }
        XCTAssertEqual(MarkdownResource.resolve("#heading", image: false, attachments: files), .anchor("heading"))
    }
}
