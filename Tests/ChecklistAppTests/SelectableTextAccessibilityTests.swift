import ChecklistAXTestSupport
import XCTest
import SwiftUI
@testable import ChecklistApp

/// CL-312: an explicit accessibility label (or value, or a combining/ignoring wrapper) on selectable text sends an AX
/// client's label read into endless recursion and crashes the app (CL-127 tables, CL-312 media comparison).
/// Selectable text carries its label with `accessibilityRepresentation` instead. Synthetic sources and views only.
enum SelectableTextAccessibilityScan {
    static let selectable = ".textSelection(.enabled)"
    static let forbidden = ["accessibilityLabel(", "accessibilityValue(", "accessibilityElement(children: .combine", "accessibilityElement(children:.combine",
                            "accessibilityElement(children: .ignore", "accessibilityElement(children:.ignore"]
    /// Lines whose selectable text gets a forbidden modifier on the same node: in its receiver (also a container whose
    /// children inherit the selection) or in the modifier chain after the selection, across lines.
    static func findings(_ text: String, file: String = "sample") -> [String] {
        let c = Array(text), needle = Array(selectable)
        var out: [String] = [], i = 0
        while i + needle.count <= c.count {
            guard Array(c[i..<(i + needle.count)]) == needle else { i += 1; continue }
            let rec = receiver(c, before: i), node = rec + selectable + chain(c, from: i + needle.count)
            let line = c[..<i].filter { $0 == "\n" }.count + 1
            if let hit = forbidden.first(where: node.contains) { out.append("\(file):\(line) \(hit)") }
            else if let hit = wrappers(c, outside: i - rec.count).first { out.append("\(file):\(line) wrapper \(hit)") }
            i += needle.count
        }
        return out
    }
    /// A combining or ignoring wrapper up to four enclosing blocks out merges the selectable text into a labelled node.
    static func wrappers(_ c: [Character], outside start: Int, levels: Int = 4) -> [String] {
        var out: [String] = [], i = start - 1
        for _ in 0..<levels {
            var depth = 0
            while i >= 0 {
                let ch = c[i]
                if ")}]".contains(ch) { depth += 1 } else if "({[".contains(ch) { if depth == 0 { break }; depth -= 1 }
                i -= 1
            }
            guard i >= 0 else { break }
            var j = i, d = 0
            while j < c.count { if "({[".contains(c[j]) { d += 1 } else if ")}]".contains(c[j]) { d -= 1; if d == 0 { break } }; j += 1 }
            let after = chain(c, from: min(j + 1, c.count))
            out += forbidden.filter { $0.hasPrefix("accessibilityElement") && after.contains($0) }
            i -= 1
        }
        return out
    }
    static func count(_ text: String) -> Int { text.components(separatedBy: selectable).count - 1 }
    static func chain(_ c: [Character], from start: Int) -> String {
        var i = start, depth = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\"" { i += 1; while i < c.count, c[i] != "\"" { i += c[i] == "\\" ? 2 : 1 } }
            else if "({[".contains(ch) { depth += 1 }
            else if ")}]".contains(ch) { if depth == 0 { break }; depth -= 1 }
            else if depth == 0, ch == ";" { break }
            else if depth == 0, ch == "\n" {
                var j = i + 1; while j < c.count, c[j] == " " || c[j] == "\t" { j += 1 }
                if j >= c.count || c[j] != "." { break }
            }
            i += 1
        }
        return String(c[start..<min(i, c.count)])
    }
    static func receiver(_ c: [Character], before end: Int) -> String {
        var i = end - 1, depth = 0
        while i >= 0 {
            let ch = c[i]
            if ch == "\"" { i -= 1; while i >= 0, !(c[i] == "\"" && (i == 0 || c[i - 1] != "\\")) { i -= 1 } }
            else if ")}]".contains(ch) { depth += 1 }
            else if "({[".contains(ch) { if depth == 0 { break }; depth -= 1 }
            else if depth == 0, ch == ";" { break }
            else if depth == 0, ch == "\n" {
                var j = i + 1; while j < end, c[j] == " " || c[j] == "\t" { j += 1 }
                if j >= end || c[j] != "." { break }
            }
            i -= 1
        }
        return String(c[max(i + 1, 0)..<end])
    }
}

final class SelectableTextAccessibilityTests: XCTestCase {
    func testScanFindsTheCrashingShapesAndAcceptsTheRepresentation() {
        let bad = [#"case .text(let value): Text(value).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).accessibilityLabel("Exact captured text: "+value)"#,
                   "Text(value)\n    .font(.callout)\n    .textSelection(.enabled)\n    .accessibilityLabel(\"Label\")",
                   #"VStack { Text(a).accessibilityLabel("A"); Text(b) }.textSelection(.enabled)"#,
                   #"Text(a).textSelection(.enabled).accessibilityValue(a)"#,
                   "HStack { Text(a).textSelection(.enabled).padding(2) }\n    .accessibilityElement(children: .combine)"]
        for sample in bad { XCTAssertEqual(SelectableTextAccessibilityScan.findings(sample).count, 1, sample) }
        let good = [#"cell(value).textSelection(.enabled).accessibilityRepresentation { Text(verbatim: header + ": " + value) }"#,
                    "Text(a).textSelection(.enabled)\nText(b).accessibilityLabel(\"(b)\")",
                    #"if x { Text(a).textSelection(.enabled) }.accessibilityElement(children: .contain).accessibilityLabel("Box")"#,
                    #"Text("a ) ( \" b").textSelection(.enabled); Button("Go") {}.accessibilityLabel("Go")"#]
        for sample in good { XCTAssertEqual(SelectableTextAccessibilityScan.findings(sample), [], sample) }
    }

    /// Guard: no selectable text in the app gets an explicit label, value or combining wrapper on its own node.
    /// A labelled `.contain` container around selectable text is a separate node and stays allowed (CL-127 tables).
    func testNoSelectableTextInTheAppHasAnExplicitAccessibilityLabel() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChecklistApp")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var findings: [String] = [], total = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            total += SelectableTextAccessibilityScan.count(text)
            findings += SelectableTextAccessibilityScan.findings(text, file: file.path.replacingOccurrences(of: root.path + "/", with: ""))
        }
        XCTAssertGreaterThan(total, 50, "the scan must see the app's selectable text")
        XCTAssertEqual(findings, [], "Use accessibilityRepresentation { Text(verbatim: label) } on selectable text instead")
        let comparison = try String(contentsOf: root.appendingPathComponent("Media/MediaOwnerComparison.swift"), encoding: .utf8)
        XCTAssertFalse(comparison.contains("later slice"), "The comparison footnote describes the shipped rework and closure")
        XCTAssertTrue(comparison.contains("case .text(let value): MediaExactCapturedText(value:value)"))
    }

    @MainActor func testExactCapturedTextExposesItsLabelToRepeatedAccessibilityReads() async throws {
        let watchdog = AXProbe.watchdog(seconds: 60, "MEDIA EXACT TEXT AX READ"); defer { watchdog.cancel() }
        let restoreAX = AXProbe.enableEnhancedUserInterface(); defer { restoreAX() }
        XCTAssertEqual(MediaExactCapturedText.accessibilityText("Alpha"), "Exact captured text: Alpha")
        func texts(_ host: NSObject) -> [String] {
            AXProbe.nodes(host).flatMap { node -> [String] in
                ["accessibilityRole", "accessibilityLabel", "accessibilityValue", "accessibilityTitle"].compactMap { AXProbe.attribute(node, $0) as? String }
                    + ["AXRole", "AXDescription", "AXValue", "AXTitle"].compactMap { ChecklistTestAXAttributeValue(node, NSAccessibility.Attribute(rawValue: $0)) as? String }
            }
        }
        let host = NSHostingView(rootView: VStack(alignment: .leading) { Text("Text slot 1"); MediaExactCapturedText(value: "Alpha") }.frame(width: 480))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 520, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic Checklist media exact text AX regression (offscreen)"
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        var all: [String] = []
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            host.layoutSubtreeIfNeeded()
            all = texts(host)
            if all.contains("Exact captured text: Alpha") { break }
        }
        XCTAssertTrue(all.contains("Exact captured text: Alpha"), "label expected in \(all)")
        XCTAssertTrue(all.contains("Text slot 1"))
        // Three full reads, as the installed check does: each one completes and returns the same text.
        for _ in 0..<3 { XCTAssertEqual(texts(host), all) }
    }
}
