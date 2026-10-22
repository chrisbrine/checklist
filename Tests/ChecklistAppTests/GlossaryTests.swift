import XCTest
import SwiftUI
@testable import ChecklistApp

/// docs/interface.md#glossary names each visible concept once (CL-56).
final class GlossaryTests: XCTestCase {
    func testOneCanceledSpellingWithOneLegacyAlias() {
        XCTAssertEqual(Canceled.normalized("cancelled"), "canceled")
        XCTAssertEqual(Canceled.normalized("answered"), "answered")
        XCTAssertTrue(Canceled.matches("canceled"))
        XCTAssertTrue(Canceled.matches("cancelled"))
        XCTAssertEqual(StatusPill(name: "Canceled", category: "canceled").color, .checklistSecondaryText)
        XCTAssertEqual(StatusPill(name: "Canceled", category: "cancelled").color, .checklistSecondaryText)
    }

    /// Core and service code also use one spelling; only the legacy stored-value constants name the old one.
    func testCoreAndServiceUseOneCanceledSpelling() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var found: [String] = []
        for folder in ["Sources/ChecklistCore", "Sources/ChecklistService", "Sources/ChecklistIPC", "Sources/ChecklistBridges", "Sources/ChecklistCLI", "Sources/ChecklistApp", "Tests/ChecklistCoreTests"] {
            guard let files = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files where file.pathExtension == "swift" && !["LegacyStoredValue.swift", "Canceled.swift"].contains(file.lastPathComponent) {
                let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "isCancelled", with: "")
                if text.range(of: "cancelled", options: .caseInsensitive) != nil { found.append(file.lastPathComponent) }
            }
        }
        XCTAssertEqual(found, [])
    }

    /// Service identifiers shown as text use the glossary words.
    func testServiceIdentifiersShowGlossaryWords() {
        XCTAssertEqual(GlossaryText.humanize("task_edited"), "ticket edited")
        XCTAssertEqual(GlossaryText.humanize("task_created"), "ticket created")
        XCTAssertEqual(GlossaryText.humanize("request_cancelled"), "request canceled")
        XCTAssertEqual(GlossaryText.humanize("message_saved"), "message saved")
        XCTAssertEqual(GlossaryText.humanize("multitask_mode"), "multitask mode", "Only whole words change")
        XCTAssertEqual(GlossaryText.title("cancelled"), "Canceled")
        XCTAssertEqual(GlossaryText.title("in_progress"), "In progress")
        XCTAssertEqual(GlossaryText.title("open"), "Open")
    }

    /// A request from an older store keeps the stored value "cancelled"; it shows as "Canceled".
    func testAnOldCanceledRequestShowsTheGlossarySpelling() throws {
        XCTAssertEqual(RequestDetailView.stateName(Record(values: ["id": "r1", "state": "cancelled"])), "Canceled")
        XCTAssertEqual(RequestDetailView.stateName(Record(values: ["id": "r2"])), "Open")
        // Every visible state of an old request: the pill and the footer of an answered or canceled request.
        XCTAssertEqual(RequestDetailView.footerText(Record(values: ["id": "r1", "state": "cancelled"])), "This request is canceled.")
        XCTAssertEqual(RequestDetailView.footerText(Record(values: ["id": "r3", "state": "answered"])), "This request is answered.")
        // Stored states go through GlossaryText.title, never through .capitalized.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChecklistApp")
        var raw: [String] = []
        for file in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!.compactMap({ $0 as? URL }) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.range(of: #"string\("(state|status_category)"[^)]*\)\.capitalized"#, options: .regularExpression) != nil { raw.append(file.lastPathComponent) }
            // Nor is a stored state interpolated into visible text as it is stored.
            if text.range(of: #"\\\(\w+\??\.string\("(state|status_category)"[^)]*\)\)"#, options: .regularExpression) != nil { raw.append(file.lastPathComponent + " (interpolated)") }
        }
        XCTAssertEqual(raw, [])
    }

    /// Visible strings use the glossary terms: ticket, Epic, Triage, Start my work, canceled.
    func testVisibleStringsUseGlossaryTerms() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChecklistApp")
        let retired: [(String, String)] = [
            (#"(?<![\w.(\\])[Tt]asks?(?![\w(]|\.\w)"#, "ticket"),
            (#"(?i)(?<![\w.(\\])subprojects?(?![\w(]|\.\w)"#, "Epic"),
            (#"(?i)handling (pass|group|set|brief|phase|purpose|triage)|temporary handling"#, "Triage"),
            (#"(?<![\w.(\\])triages?(?![\w(]|\.\w)"#, "Triage (capitalized)"),
            (#"Start my task"#, "Start my work"),
            (#"cancelled"#, "canceled")]
        var problems: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files where file.lastPathComponent != "Canceled.swift" {
            for value in SwiftLiterals.strings(in: try String(contentsOf: file, encoding: .utf8)) {
                // Keys, identifiers and symbol names have no space; the two single words are the old toolbar and breadcrumb labels.
                guard value.contains(" ") || value.contains("…") || ["Task", "Subproject"].contains(value) else { continue }
                for (pattern, term) in retired where value.range(of: pattern, options: .regularExpression) != nil {
                    problems.append("\(file.lastPathComponent): \"\(value.prefix(80))\" should use \(term)")
                }
            }
        }
        XCTAssertEqual(problems, [])
    }

    /// A literal inside a \( ) interpolation is a visible string too; a quote regex pairs the wrong quotes there.
    func testLiteralScanFollowsInterpolations() {
        let source = ##"""
        let a = "\(name)  /  \(kind == "epic" ? "Subproject" : "Handling triage")" // "Not code"
        let b = #"raw \#(x) "quoted""#; let c = "\"Escaped\" \(f("in", g("deep")))"
        /* "In a comment" */ let d = """
            Multi \(y) line
            """
        """##
        XCTAssertEqual(SwiftLiterals.strings(in: source),
                       ["epic", "Subproject", "Handling triage", "\u{FFFC}  /  \u{FFFC}", "raw \u{FFFC} \"quoted\"",
                        "in", "deep", "\\\"Escaped\\\" \u{FFFC}", "\n    Multi \u{FFFC} line\n    "])
    }
}

/// Swift string literals in source text, in the order they close. Interpolated code is scanned for
/// its own literals and shows as U+FFFC in the enclosing literal; comments are skipped.
enum SwiftLiterals {
    static func strings(in source: String) -> [String] {
        var scanner = Scanner(text: Array(source.unicodeScalars))
        scanner.code(from: 0, nested: false)
        return scanner.found
    }

    private struct Scanner {
        let text: [Unicode.Scalar]
        var found: [String] = []

        func starts(_ token: String, at position: Int) -> Bool {
            let scalars = Array(token.unicodeScalars)
            return position + scalars.count <= text.count && Array(text[position..<position + scalars.count]) == scalars
        }
        func skipComment(at position: Int) -> Int? {
            if starts("//", at: position) { return text[position...].firstIndex(of: "\n") ?? text.count }
            if starts("/*", at: position) {
                var end = position + 2
                while end < text.count, !starts("*/", at: end) { end += 1 }
                return min(end + 2, text.count)
            }
            return nil
        }
        /// Reads code until the end of the text or, for an interpolation, its closing parenthesis.
        @discardableResult mutating func code(from start: Int, nested: Bool) -> Int {
            var position = start, depth = 1
            while position < text.count {
                if let next = skipComment(at: position) { position = next; continue }
                var hashes = 0
                while position + hashes < text.count, text[position + hashes] == "#" { hashes += 1 }
                if position + hashes < text.count, text[position + hashes] == "\"" {
                    let multiline = starts("\"\"\"", at: position + hashes)
                    position = literal(from: position + hashes + (multiline ? 3 : 1), hashes: hashes, multiline: multiline)
                    continue
                }
                if nested, text[position] == "(" { depth += 1 }
                if nested, text[position] == ")" { depth -= 1; if depth == 0 { return position + 1 } }
                position += max(hashes, 1)
            }
            return position
        }
        /// Reads one literal body and returns the position after its closing delimiter.
        mutating func literal(from start: Int, hashes: Int, multiline: Bool) -> Int {
            let close = (multiline ? "\"\"\"" : "\"") + String(repeating: "#", count: hashes)
            let escape = "\\" + String(repeating: "#", count: hashes)
            var position = start, value = String.UnicodeScalarView()
            while position < text.count {
                if starts(close, at: position) { found.append(String(value)); return position + close.unicodeScalars.count }
                if starts(escape + "(", at: position) {
                    position = code(from: position + escape.unicodeScalars.count + 1, nested: true)
                    value.append("\u{FFFC}"); continue
                }
                let step = starts(escape, at: position) ? escape.unicodeScalars.count + 1 : 1
                value.append(contentsOf: text[position..<min(position + step, text.count)]); position += step
            }
            found.append(String(value)); return position
        }
    }
}
