import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

/// CL-127: optional rich content v1, validated templates only (no live store).
final class RichContentTests: XCTestCase {
    func chartBlock(_ fallback: String = "Frame time (ms): before 24; after 16. Target: at most 20 ms.") -> JSON {
        ["block_id": "frame-time", "type": "chart", "fallback": fallback, "chart_kind": "bar", "x_label": "Build", "y_label": "Frame time", "y_unit": "ms",
         "series": [["label": "Measured", "points": [["x": "before", "y": 24], ["x": "after", "y": 16]]]], "caption": "Target: at most 20 ms."]
    }
    func envelope(_ blocks: [JSON]) -> JSON { ["schema_version": 1, "blocks": blocks] }
    func code(_ body: () throws -> Void, _ expected: String, contains text: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            let value = error as? CoreError
            XCTAssertEqual(value?.code, expected, value?.message ?? "\(error)", file: file, line: line)
            if !text.isEmpty { XCTAssertTrue(value?.message.contains(text) == true, value?.message ?? "", file: file, line: line) }
        }
    }

    // Item 1: plain strings and Markdown are the default and stay byte-exact.
    func testPlainAndMarkdownDefaultsKeepExactSource() {
        let plain = "Synthetic note with ID CL-1 and evidence_missing.\r\nSecond line ✓ e\u{301}"
        let a = RichContentPresentation.prepare(text: plain, capability: .note)
        XCTAssertEqual(a.blocks, [.plain(plain)]); XCTAssertFalse(a.rich); XCTAssertNil(a.notice)
        XCTAssertEqual(Data(a.source.utf8), Data(plain.utf8))
        let markdown = "# Result\n\n- **bold** item\n\n| A | B |\n|---|---|\n| 1 | 2 |"
        let b = RichContentPresentation.prepare(text: markdown, capability: .note)
        XCTAssertTrue(b.rich); XCTAssertEqual(Data(b.source.utf8), Data(markdown.utf8))
        guard case .markdown(let document) = b.blocks.first else { return XCTFail("Markdown expected") }
        XCTAssertEqual(document.blocks.first, .heading(1, "Result")); XCTAssertTrue(document.blocks.contains(.table([["A", "B"], ["1", "2"]])))
        // Scalar fields never interpret Markdown.
        XCTAssertEqual(RichContentPresentation.prepare(text: "# not a heading", capability: .plain).blocks, [.plain("# not a heading")])
    }

    func testEnvelopeRoundTripsLosslesslyWithDeterministicDigest() throws {
        let text = "Intro **note**\n\nFrame time (ms): before 24; after 16. Target: at most 20 ms."
        let value = envelope([["block_id": "intro", "type": "markdown", "fallback": "Intro **note**"], chartBlock()])
        let accepted = try RichContentEnvelope.validate(value, text: text)
        XCTAssertEqual(accepted.blocks.map(\.type), [.markdown, .chart])
        // Serialize, decode, validate again: identical canonical bytes and digest.
        let decoded = try JSONSerialization.jsonObject(with: accepted.canonicalJSON()) as! JSON
        let again = try RichContentEnvelope.validate(decoded, text: text)
        XCTAssertEqual(again.canonicalJSON(), accepted.canonicalJSON())
        let digest = RichContentEnvelope.digest(text: text, content: accepted.source)
        XCTAssertEqual(digest, RichContentEnvelope.digest(text: text, content: decoded)); XCTAssertEqual(digest.count, 64)
        XCTAssertNotEqual(digest, RichContentEnvelope.digest(text: text + " ", content: decoded))
        let presentation = RichContentPresentation.prepare(text: text, content: decoded, capability: .note)
        XCTAssertNil(presentation.notice); XCTAssertEqual(presentation.contentDigest, digest); XCTAssertEqual(presentation.source, text)
        guard case .chart(let kind, _, _, _, let unit, let series, _, let fallback) = presentation.blocks.last else { return XCTFail("Chart expected") }
        XCTAssertEqual(kind, "bar"); XCTAssertEqual(unit, "ms"); XCTAssertEqual(series.first?.points.map(\.y), [24, 16]); XCTAssertTrue(fallback.contains("before 24"))
    }

    func testClosedValidationRefusesMismatchVersionsAndBounds() {
        let text = "Frame time (ms): before 24; after 16. Target: at most 20 ms."
        code({ _ = try RichContentEnvelope.validate(self.envelope([self.chartBlock()]), text: text + "\n") }, "CONTENT_FALLBACK_MISMATCH")
        code({ _ = try RichContentEnvelope.validate(self.envelope([["block_id": "a", "type": "markdown", "fallback": "A"], ["block_id": "b", "type": "markdown", "fallback": "B"]]), text: "A\nB") }, "CONTENT_FALLBACK_MISMATCH")
        code({ _ = try RichContentEnvelope.validate(["schema_version": 2, "blocks": [["block_id": "a", "type": "markdown", "fallback": "A"]]], text: "A") }, "CONTENT_VERSION_UNSUPPORTED")
        code({ _ = try RichContentEnvelope.validate(["schema_version": true, "blocks": [["block_id": "a", "type": "markdown", "fallback": "A"]]], text: "A") }, "CONTENT_VERSION_UNSUPPORTED")
        code({ _ = try RichContentEnvelope.validate([:] as JSON, text: "A") }, "INVALID_CONTENT")
        code({ _ = try RichContentEnvelope.validate(["schema_version": 1, "blocks": [], "extra": 1], text: "") }, "INVALID_CONTENT", contains: "extra")
        code({ _ = try RichContentEnvelope.validate(self.envelope([["block_id": "a", "type": "markdown", "fallback": "A", "html": "<p>x</p>"]]), text: "A") }, "INVALID_CONTENT", contains: "not a v1 field")
        code({ _ = try RichContentEnvelope.validate(self.envelope([["block_id": "a", "type": "markdown", "fallback": "A"], ["block_id": "a", "type": "markdown", "fallback": "B"]]), text: "A\n\nB") }, "INVALID_CONTENT", contains: "duplicates")
        code({ _ = try RichContentEnvelope.validate(self.envelope([["block_id": "../x", "type": "markdown", "fallback": "A"]]), text: "A") }, "INVALID_CONTENT", contains: "block_id")
        code({ _ = try RichContentEnvelope.validate(self.envelope((0..<33).map { ["block_id": "b\($0)", "type": "markdown", "fallback": ""] }), text: String(repeating: "\n\n", count: 32)) }, "INVALID_CONTENT", contains: "1–32")
        code({ _ = try RichContentEnvelope.validate(self.envelope([["block_id": "t", "type": "table", "fallback": "A", "columns": [["id": "a", "label": "A"], ["id": "b", "label": "B"]], "rows": [["1"]]]]), text: "A") }, "INVALID_CONTENT", contains: "one cell per column")
        code({ _ = try RichContentEnvelope.validate(self.envelope([["block_id": "t", "type": "table", "fallback": "A", "columns": [["id": "a", "label": "A"], ["id": "a", "label": "B"]], "rows": []]]), text: "A") }, "INVALID_CONTENT", contains: "distinct")
        var bad = chartBlock(); bad["series"] = [["label": "S", "points": [["x": 1, "y": 2]]]]
        code({ _ = try RichContentEnvelope.validate(self.envelope([bad]), text: text) }, "INVALID_CONTENT", contains: "bar x")
        bad = chartBlock(); bad["chart_kind"] = "line"; bad["series"] = [["label": "S", "points": [["x": 1, "y": Double.infinity]]]]
        code({ _ = try RichContentEnvelope.validate(self.envelope([bad]), text: text) }, "INVALID_CONTENT", contains: "finite")
        bad = chartBlock(); bad["chart_kind"] = "scatter"; bad["series"] = [["label": "S", "points": (0..<1001).map { ["x": $0, "y": $0] }]]
        code({ _ = try RichContentEnvelope.validate(self.envelope([bad]), text: text) }, "INVALID_CONTENT", contains: "1,000")
        bad = chartBlock(); bad["chart_kind"] = "pie"
        code({ _ = try RichContentEnvelope.validate(self.envelope([bad]), text: text) }, "INVALID_CONTENT", contains: "chart_kind")
        code({ _ = try RichContentEnvelope.validate(self.envelope([["block_id": "m", "type": "media", "fallback": "A", "media_kind": "image", "attachment_ref": ["attachment_id": "x", "sha256": "ABC", "representation": "original"]]]), text: "A") }, "INVALID_CONTENT", contains: "SHA-256")
        code({ _ = try RichContentEnvelope.validate(self.envelope([["block_id": "s", "type": "script", "fallback": "A"]]), text: "A") }, "INVALID_CONTENT", contains: "unsupported block type")
    }

    // Item 3: HTML/CSS is parsed into an allowlist model; active or remote constructs are refused.
    func testHTMLAndCSSAllowlistRefusesActiveRemoteAndFileConstructs() {
        func html(_ markup: String, _ css: String = "") -> Error? {
            do { _ = try RichContentEnvelope.validate(envelope([["block_id": "h", "type": "html", "fallback": "Text", "html": markup, "css": css]]), text: "Text"); return nil } catch { return error }
        }
        XCTAssertNil(html("<section class=\"grid\"><h2>Result</h2><p>One &amp; <strong>two</strong> <a href=\"https://example.com/x\">link</a></p></section>", ".grid { display: grid; grid-template-columns: repeat(2,minmax(0,1fr)); gap: 8px } h2 { color: #336699; font-weight: bold }"))
        for markup in ["<script>alert(1)</script>", "<p onclick=\"x()\">a</p>", "<a href=\"javascript:alert(1)\">a</a>", "<a href=\"http://example.com\">a</a>",
                       "<a href=\"file:///etc/passwd\">a</a>", "<img src=\"https://example.com/a.png\">", "<iframe src=\"https://example.com\"></iframe>", "<!-- c --><p>a</p>",
                       "<p style=\"color:red\">a</p>", "<p id=\"x\">a</p>", "<button>Approve</button>", "<form></form>", "<svg></svg>", "<p>unclosed", "<p>a</div>", "<p role=\"button\">a</p>", "<custom-el>a</custom-el>"] {
            let error = html(markup) as? CoreError
            XCTAssertEqual(error?.code, "INVALID_CONTENT", markup)
        }
        for css in ["p { background: url(https://example.com/a.png) }", "@import url(x.css);", "p { position: fixed }", "p { width: calc(100% - 2px) }", "p { z-index: 9 }",
                    "p { color: red }", "p { --x: 1 }", "p::before { color: #fff }", "#id { color: #fff }", "iframe { color: #fff }", "a b c d e { color: #fff }", "p { transform: none }", "p { color: #fff !important }"] {
            XCTAssertEqual((html("<p>a</p>", css) as? CoreError)?.code, "INVALID_CONTENT", css)
        }
        let deep = String(repeating: "<div>", count: 34) + "x" + String(repeating: "</div>", count: 34)
        XCTAssertTrue((html(deep) as? CoreError)?.message.contains("32 levels") == true)
        let many = String(repeating: "<br>", count: 2_001)
        XCTAssertTrue((html(many) as? CoreError)?.message.contains("2,000") == true)
    }

    func testSafeHTMLLayoutAppliesTheNativeCSSSubset() throws {
        let document = try SafeHTMLDocument.parse(html: "<h3 class=\"t\">Title</h3><ul><li>One <em>a</em></li><li>Two</li></ul><table><caption>Cap</caption><tr><th>H</th></tr><tr><td>&lt;v&gt;</td></tr></table><p>A\n   b</p><pre>x\n  y</pre><hr>",
                                                   css: ".t { font-weight: bold; text-align: center; color: #abc } ul li { font-style: italic }")
        let blocks = document.layoutBlocks()
        guard case .heading(3, let runs, let style) = blocks[0] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(runs.map(\.text).joined(), "Title"); XCTAssertTrue(style.bold); XCTAssertEqual(style.alignment, "center"); XCTAssertEqual(style.color, "#abc")
        guard case .listItem("•", 0, let item, let itemStyle) = blocks[1] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(item.map(\.text).joined(), "One a"); XCTAssertTrue(itemStyle.italic); XCTAssertTrue(item.last?.italic == true)
        guard case .table(let caption, let rows, let header) = blocks[3] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(caption, "Cap"); XCTAssertEqual(header, 1); XCTAssertEqual(rows[1][0].map(\.text).joined(), "<v>")
        XCTAssertTrue(blocks.contains { if case .paragraph(let r, _) = $0 { return r.map(\.text).joined() == "A b" }; return false })
        XCTAssertTrue(blocks.contains(.code("x\n  y"))); XCTAssertEqual(blocks.last, .rule)
    }

    // Items 2, 3, 4: capability metadata, honest fallback, bounded and cancelable work.
    func testCapabilityFallbackCancellationAndLongText() {
        let text = "Frame time (ms): before 24; after 16. Target: at most 20 ms."
        let content = envelope([chartBlock()])
        for capability in [RichFieldCapability.plain, .ticketBrief, .triagePurpose, .reviewExplanation, .requestExplanation] {
            let value = RichContentPresentation.prepare(text: text, content: content, capability: capability)
            XCTAssertTrue(value.notice?.hasPrefix("Rich view unavailable") == true, capability.field); XCTAssertEqual(value.source, text)
            XCTAssertNil(value.contentDigest)
        }
        XCTAssertEqual(RichFieldCapability.all.filter { $0.companion != nil }.map(\.field), ["message.body"])
        let mismatch = RichContentPresentation.prepare(text: "Different **text**", content: content, capability: .note)
        XCTAssertTrue(mismatch.notice?.contains("byte for byte") == true); XCTAssertTrue(mismatch.rich)
        guard case .markdown = mismatch.blocks.first else { return XCTFail("Markdown fallback expected") }
        let future = RichContentPresentation.prepare(text: text, content: ["schema_version": 7, "blocks": ["opaque"]], capability: .note)
        XCTAssertTrue(future.notice?.contains("version 7") == true); XCTAssertEqual(future.blocks, [.plain(text)])
        let unsafe = RichContentPresentation.prepare(text: "Approve", content: envelope([["block_id": "h", "type": "html", "fallback": "Approve", "html": "<button>Approve</button>", "css": ""]]), capability: .note)
        XCTAssertEqual(unsafe.blocks, [.plain("Approve")]); XCTAssertNotNil(unsafe.notice)
        let canceled = RichContentPresentation.prepare(text: text, content: content, capability: .note, isCanceled: { true })
        XCTAssertTrue(canceled.canceled); XCTAssertEqual(canceled.blocks, [.plain(text)])
        var calls = 0
        let midway = RichContentPresentation.prepare(text: "# A\n" + String(repeating: "line\n", count: 5_000), capability: .note, isCanceled: { calls += 1; return calls > 3 })
        XCTAssertTrue(midway.canceled)
        let long = String(repeating: "x", count: RichContentLimits.renderedTextBytes + 10)
        let bounded = RichContentPresentation.prepare(text: long, capability: .note)
        XCTAssertEqual(bounded.source.utf8.count, long.utf8.count)
        guard case .plain(let shown) = bounded.blocks.first else { return XCTFail("Plain prefix expected") }
        XCTAssertEqual(shown.utf8.count, RichContentLimits.renderedTextBytes); XCTAssertTrue(bounded.notice?.contains("Copy source") == true)
    }

    // Items 1, 5, 6: the service stores the companion with provenance and refuses foreign media.
    func testMessageSendStoresContentWithProvenanceAndRefusesForeignMedia() throws {
        let parent = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ChecklistQualification/CL-127/RichContentTests", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let directory = parent.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: directory) }
        let router = try TestStore.router(root: directory)
        let owner = Caller(role: "owner", installation: "rich-content-owner", projectIDs: [])
        func call(_ method: String, _ input: JSON) throws -> JSON {
            var params = input
            if !CommandRouter.readMethods.contains(method) { params["command_id"] = uuid() }
            return try router.handle(method: method, params: fixtureTaskInput(router, method: method, input: params), caller: owner)["data"] as! JSON
        }
        let workspace = directory.appendingPathComponent("workspace"); try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let project = try call("project_create", ["name": "Rich fixtures", "key_prefix": "RICH", "root_path": workspace.path]), pid = project["id"] as! String
        let task = try call("task_create", ["project_id": pid, "title": "Rich note", "brief": "Synthetic"]), other = try call("task_create", ["project_id": pid, "title": "Other", "brief": "Synthetic"])
        let text = "Frame time (ms): before 24; after 16. Target: at most 20 ms."
        let saved = try call("message_send", ["project_id": pid, "task_id": task["id"]!, "body": text, "content": envelope([chartBlock()])])
        XCTAssertEqual(saved["body"] as? String, text); XCTAssertEqual(saved["origin"] as? String, "human_ui"); XCTAssertEqual(saved["content_schema_version"] as? Int, 1)
        let stored = try XCTUnwrap(saved["content"] as? JSON)
        XCTAssertEqual(saved["content_digest"] as? String, RichContentEnvelope.digest(text: text, content: stored))
        XCTAssertEqual(RichContentEnvelope.canonical(stored), RichContentEnvelope.canonical(envelope([chartBlock()])))
        XCTAssertNil(saved["human_response_id"]); XCTAssertNil(saved["verdict"])
        // Refusals write nothing.
        let before = try router.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM records WHERE type='message'")! }
        code({ _ = try call("message_send", ["project_id": pid, "task_id": task["id"]!, "body": text + "!", "content": self.envelope([self.chartBlock()])]) }, "CONTENT_FALLBACK_MISMATCH")
        try "synthetic".write(to: workspace.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let file = try call("attachment_add", ["project_id": pid, "task_id": other["id"]!, "path": workspace.appendingPathComponent("a.txt").path])
        let media: JSON = ["block_id": "m", "type": "media", "fallback": "Report a.txt", "media_kind": "text", "attachment_ref": ["attachment_id": file["id"]!, "sha256": file["sha256"]!, "representation": "original"]]
        code({ _ = try call("message_send", ["project_id": pid, "task_id": task["id"]!, "body": "Report a.txt", "content": self.envelope([media])]) }, "CONTENT_REFERENCE_UNAVAILABLE")
        XCTAssertEqual(try router.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM records WHERE type='message'")! }, before)
        // The same attachment cited on its own ticket is accepted.
        let own = try call("message_send", ["project_id": pid, "task_id": other["id"]!, "body": "Report a.txt", "content": envelope([media])])
        XCTAssertNotNil(own["content_digest"])
        // Plain clients are unchanged.
        let plain = try call("message_send", ["project_id": pid, "task_id": task["id"]!, "body": "Plain note"])
        XCTAssertNil(plain["content"]); XCTAssertNil(plain["content_digest"])
    }

    func testCatalogAdvertisesContentOnlyOnMessageSend() throws {
        let router = try TestStore.router(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let worker = Caller(role: "worker", installation: "rich-catalog", projectIDs: [])
        let catalog = router.toolCatalog(worker)
        func properties(_ name: String) -> JSON { ((catalog.first { $0["name"] as? String == name }?["inputSchema"] as? JSON)?["properties"] as? JSON) ?? [:] }
        XCTAssertEqual((properties("message_send")["content"] as? JSON)?["type"] as? String, "object")
        let advertising = catalog.filter { (($0["inputSchema"] as? JSON)?["properties"] as? JSON)?["content"] != nil }.compactMap { $0["name"] as? String }
        XCTAssertEqual(advertising, ["message_send"])
    }

    func testTruncatedContextPreviewOmitsCompanion() throws {
        let router = try TestStore.router(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let long = String(repeating: "a", count: 1_300)
        let preview = router.contextPreview(["body": long, "content": envelope([["block_id": "a", "type": "markdown", "fallback": long]])])
        XCTAssertNil(preview["content"]); XCTAssertEqual(preview["content_omitted"] as? Bool, true); XCTAssertEqual(preview["body_truncated"] as? Bool, true)
        let short = router.contextPreview(["body": "a", "content": envelope([["block_id": "a", "type": "markdown", "fallback": "a"]])])
        XCTAssertNotNil(short["content"])
    }
}
