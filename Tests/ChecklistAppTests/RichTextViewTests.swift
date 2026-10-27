import ChecklistAXTestSupport
import XCTest
import SwiftUI
import ChecklistCore
@testable import ChecklistApp

/// CL-127: the shared rich text renderer, with synthetic templates only (no store, no live data).
final class RichTextViewTests: XCTestCase {
    let chartText = "Frame time (ms): before 24; after 16. Target: at most 20 ms."
    var chartContent: [String: Any] {
        ["schema_version": 1, "blocks": [["block_id": "frame-time", "type": "chart", "fallback": chartText, "chart_kind": "bar", "x_label": "Build", "y_label": "Frame time", "y_unit": "ms",
                                          "series": [["label": "Measured", "points": [["x": "before", "y": 24], ["x": "after", "y": 16]]]], "caption": "Target: at most 20 ms."]]]
    }
    var buttonContent: [String: Any] {
        ["schema_version": 1, "blocks": [["block_id": "fake-approval", "type": "html", "fallback": "Approve", "html": "<button>Approve</button>", "css": ""]]]
    }

    // Item 2/6: export states its contents and keeps the exact source and envelope.
    func testExportJSONKeepsExactSourceAndEnvelope() throws {
        let text = "Line 1\r\nLine ✓ e\u{301} </script> https://example.com/a/b"
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(RichTextView.exportJSON(text: text, content: nil).utf8)) as? [String: Any])
        XCTAssertEqual(plain["text"] as? String, text); XCTAssertEqual(plain["export"] as? String, "original_source"); XCTAssertNil(plain["content"])
        XCTAssertTrue(RichTextView.exportJSON(text: text, content: nil).contains("https://example.com/a/b"), "Slashes stay unescaped")
        let rich = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(RichTextView.exportJSON(text: chartText, content: chartContent).utf8)) as? [String: Any])
        XCTAssertEqual(rich["text"] as? String, chartText)
        let content = try XCTUnwrap(rich["content"])
        XCTAssertEqual(RichContentEnvelope.digest(text: chartText, content: content as? [String: Any]), RichContentEnvelope.digest(text: chartText, content: chartContent))
        // A value that is not JSON is never exported as content.
        XCTAssertNil((try JSONSerialization.jsonObject(with: Data(RichTextView.exportJSON(text: "a", content: Date()).utf8)) as? [String: Any])?["content"])
    }

    // Item 4: the preparation key changes with text, content and field, so stale work is canceled.
    func testPreparationKeyAndSynchronousBound() {
        let base = RichTextView.preparationKey(text: chartText, content: chartContent, capability: .note)
        XCTAssertEqual(base, RichTextView.preparationKey(text: chartText, content: chartContent, capability: .note))
        XCTAssertNotEqual(base, RichTextView.preparationKey(text: chartText + " ", content: chartContent, capability: .note))
        XCTAssertNotEqual(base, RichTextView.preparationKey(text: chartText, content: nil, capability: .note))
        XCTAssertNotEqual(base, RichTextView.preparationKey(text: chartText, content: chartContent, capability: .ticketBrief))
        XCTAssertTrue(RichTextView(text: "small", capability: .note).synchronous)
        XCTAssertFalse(RichTextView(text: chartText, content: chartContent, capability: .note).synchronous)
        XCTAssertFalse(RichTextView(text: String(repeating: "x", count: RichTextView.synchronousBytes + 1), capability: .note).synchronous)
    }

    // Item 5: a media block shows only this ticket's attachment with the exact hash.
    func testMediaBlockResolvesOnlyExactSameTicketAttachment() {
        let hash = String(repeating: "a", count: 64)
        let task = Record(values: ["id": "synthetic-ticket", "project_id": "synthetic-project"])
        func file(_ id: String, task: String = "synthetic-ticket", sha: String = hash, unlinked: Bool = false) -> Record {
            Record(values: ["id": id, "project_id": "synthetic-project", "task_id": task, "name": "frame.png", "sha256": sha, "unlinked": unlinked])
        }
        let ref = RichMediaReference(attachmentID: "file-1", sha256: hash, representation: "original", mediaKind: "image")
        XCTAssertEqual(RichMediaBlock.resolve(ref, in: [file("file-1"), file("file-2")], task: task)?.id, "file-1")
        XCTAssertNil(RichMediaBlock.resolve(ref, in: [file("file-1", sha: String(repeating: "b", count: 64))], task: task))
        XCTAssertNil(RichMediaBlock.resolve(ref, in: [file("file-1", task: "other-ticket")], task: task))
        XCTAssertNil(RichMediaBlock.resolve(ref, in: [file("file-1", unlinked: true)], task: task))
        XCTAssertNil(RichMediaBlock.resolve(ref, in: [file("file-1"), file("file-1")], task: task), "An ambiguous ID shows the fallback")
        XCTAssertNil(RichMediaBlock.resolve(ref, in: [], task: task))
    }

    // Item 3: only literal hexadecimal colors reach the native view.
    func testHTMLColorAcceptsOnlyHexLiterals() throws {
        let white = try XCTUnwrap(RichHTMLBlock.color("#fff").map { NSColor($0).usingColorSpace(.sRGB) } ?? nil)
        XCTAssertEqual(white.redComponent, 1, accuracy: 0.001); XCTAssertEqual(white.alphaComponent, 1, accuracy: 0.001)
        let half = try XCTUnwrap(RichHTMLBlock.color("#ff000080").map { NSColor($0).usingColorSpace(.sRGB) } ?? nil)
        XCTAssertEqual(half.greenComponent, 0, accuracy: 0.001); XCTAssertEqual(half.alphaComponent, 128.0 / 255, accuracy: 0.01)
        for bad in ["red", "#12", "#ggg", "#1234567", "url(x)"] { XCTAssertNil(RichHTMLBlock.color(bad), bad) }
    }

    // Items 2/6: declared fields render text only; a fake approval control never becomes a control.
    func testFieldCapabilitiesAndRefusedControlFallBackToText() {
        let brief = RichContentPresentation.prepare(text: chartText, content: chartContent, capability: .ticketBrief)
        XCTAssertEqual(brief.notice, "Rich view unavailable: this field shows text only."); XCTAssertEqual(brief.source, chartText)
        let fake = RichContentPresentation.prepare(text: "Approve", content: buttonContent, capability: .note)
        XCTAssertFalse(fake.rich); XCTAssertEqual(fake.blocks, [.plain("Approve")]); XCTAssertTrue(fake.notice?.hasPrefix("Rich view unavailable") == true)
    }

    // Items 2/4/6: a hosted note renders, offers Source and Copy, and adds no workflow button.
    @MainActor func testHostedNoteRendersWithSourceControlsAndNoActionButton() async throws {
        let watchdog = DispatchWorkItem { fputs("RICH TEXT HOSTED RENDER EXCEEDED 20 SECONDS\n", stderr); _exit(124) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
        defer { watchdog.cancel() }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let wasEnhanced = ChecklistTestAXAttributeValue(NSApplication.shared, enhanced) ?? false
        ChecklistTestAXSetValue(NSApplication.shared, true, enhanced)
        defer { ChecklistTestAXSetValue(NSApplication.shared, wasEnhanced, enhanced) }
        func attribute(_ obj: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return obj.responds(to: selector) ? obj.perform(selector)?.takeUnretainedValue() : nil
        }
        func nodes(_ object: NSObject, depth: Int = 0) -> [NSObject] {
            guard depth < 40 else { return [] }
            return [object] + (attribute(object, "accessibilityChildren") as? [NSObject] ?? []).flatMap { nodes($0, depth: depth + 1) }
        }
        for (text, content, expectsNotice) in [(chartText, chartContent, false), ("Approve", buttonContent, true)] {
            let host = NSHostingView(rootView: RichTextView(text: text, content: content, capability: .note).frame(width: 640))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Synthetic Checklist rich note regression (offscreen)"
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.contentView = nil; window.close() }
            window.orderFront(nil)
            var labels: [String] = []
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 50_000_000)
                host.layoutSubtreeIfNeeded()
                labels = nodes(host).compactMap { attribute($0, "accessibilityLabel") as? String }
                if labels.contains("Show source") { break }
            }
            XCTAssertTrue(labels.contains("Show source"), "Source control expected: \(labels)")
            XCTAssertTrue(labels.contains("Copy source"))
            XCTAssertEqual(labels.contains("Copy source and content (JSON)"), true)
            let buttons = nodes(host).filter { (attribute($0, "accessibilityRole") as? String) == NSAccessibility.Role.button.rawValue }
                .compactMap { attribute($0, "accessibilityLabel") as? String }
            XCTAssertFalse(buttons.contains("Approve"), "Rendering adds no workflow control: \(buttons)")
            let values = nodes(host).compactMap { (attribute($0, "accessibilityValue") as? String) ?? (attribute($0, "accessibilityLabel") as? String) }
            XCTAssertEqual(values.contains { $0.hasPrefix("Rich view unavailable") }, expectsNotice, "\(values)")
            XCTAssertGreaterThan(host.fittingSize.height, 10)
        }
    }
}
