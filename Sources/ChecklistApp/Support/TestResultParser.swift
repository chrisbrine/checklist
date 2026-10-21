import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reported case outcomes are evidence, never a Checklist verdict or proof of execution.
struct TestResultSummary: Equatable, Sendable {
    enum Format: String, Sendable { case nunit = "NUnit XML", trx = "TRX", swift = "Swift XCTest output" }
    let format: Format
    let total: Int
    let passed: Int
    let failed: Int
    let skipped: Int
    let other: Int
    let failingNames: [String]
    let warnings: [String]
}

enum TestResultParseError: Error, LocalizedError {
    case invalid(String), limit, canceled
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .limit: return "Result exceeds the parsing limits. Use a smaller complete result file."
        case .canceled: return "Reading results was canceled."
        }
    }
}

enum TestResultParser {
    static let maxBytes = 4 * 1024 * 1024
    static let maxCases = 20_000
    static let maxNameLength = 512

    static func parse(_ data: Data, milliseconds: Int = 250, isCanceled: @escaping () -> Bool = { false }) throws -> TestResultSummary {
        guard data.count <= maxBytes else { throw TestResultParseError.limit }
        let budget = ParseBudget(milliseconds: milliseconds, canceled: isCanceled)
        try budget.check()
        guard let raw = String(data: data, encoding: .utf8) else { throw TestResultParseError.invalid("Use a UTF-8 NUnit XML, TRX or Swift XCTest log.") }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        try budget.check()
        if text.hasPrefix("<") {
            // No DTD, entity declarations, network resolution or paths from document content.
            guard text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
                  text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
                throw TestResultParseError.invalid("DTD and entity declarations are not supported.")
            }
            let delegate = ResultXML(budget: budget)
            let parser = XMLParser(data: Data(text.utf8))
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            let complete = parser.parse()
            if let error = delegate.failure { throw error }
            guard complete else { throw TestResultParseError.invalid("The XML result is incomplete or malformed.") }
            return try delegate.summary()
        }
        return try swiftOutput(text, budget: budget)
    }

    private static func swiftOutput(_ text: String, budget: ParseBudget) throws -> TestResultSummary {
        let cases = try NSRegularExpression(pattern: "^Test Case '(.{1,512})' (passed|failed|skipped) ")
        let suites = try NSRegularExpression(pattern: "^Test Suite '(.{1,512})' (started|passed|failed)[ .]")
        let totals = try NSRegularExpression(pattern: "^Executed ([0-9]+) tests?, with (?:([0-9]+) tests? skipped and )?([0-9]+) failures?")
        let incomplete = TestResultParseError.invalid("Use one complete Swift XCTest run, from its All tests or Selected tests suite start through its final suite completion and Executed summary.")
        var outcomes: [ResultCase] = [], suiteStack: [String] = [], declaredTotal: Int?
        var rootStarted = false, rootClosed = false
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            try budget.check()
            guard line.utf8.count <= 65_536 else { throw TestResultParseError.limit }
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            if let match = suites.firstMatch(in: value, range: range),
               let nameRange = Range(match.range(at: 1), in: value), let stateRange = Range(match.range(at: 2), in: value) {
                let name = String(value[nameRange]), state = String(value[stateRange])
                guard name.utf8.count <= 2_048 else { throw TestResultParseError.limit }
                if state == "started" {
                    guard !rootClosed, suiteStack.count < 64 else { throw incomplete }
                    if suiteStack.isEmpty {
                        guard !rootStarted, ["All tests", "Selected tests"].contains(name) else { throw incomplete }
                        rootStarted = true
                    }
                    suiteStack.append(name)
                } else {
                    guard suiteStack.last == name else { throw incomplete }
                    suiteStack.removeLast()
                    if suiteStack.isEmpty { rootClosed = true }
                }
            } else if value.hasPrefix("Test Suite ") { throw incomplete }
            if let match = cases.firstMatch(in: value, range: range),
               let name = Range(match.range(at: 1), in: value), let outcome = Range(match.range(at: 2), in: value) {
                guard !suiteStack.isEmpty, !rootClosed else { throw incomplete }
                guard outcomes.count < maxCases else { throw TestResultParseError.limit }
                let label = String(value[name])
                guard label.utf8.count <= 2_048, label.count <= maxNameLength else { throw TestResultParseError.limit }
                outcomes.append(ResultCase(name: label, outcome: String(value[outcome])))
            } else if value.hasPrefix("Test Case "), suiteStack.isEmpty { throw incomplete }
            if let match = totals.firstMatch(in: value, range: range), let number = Range(match.range(at: 1), in: value), rootClosed {
                guard declaredTotal == nil, let count = Int(value[number]) else { throw incomplete }
                declaredTotal = count
            }
        }
        // Inner-suite summaries cannot qualify a log cut while its outer run is open.
        guard rootStarted, rootClosed, suiteStack.isEmpty, let total = declaredTotal, total == outcomes.count else { throw incomplete }
        return makeSummary(.swift, outcomes, warnings: [])
    }

    fileprivate struct ResultCase {
        let name: String
        let outcome: String
        var children = false
    }
    fileprivate static func makeSummary(_ format: TestResultSummary.Format, _ cases: [ResultCase], warnings: [String]) -> TestResultSummary {
        let passed = cases.filter { ["passed", "success"].contains($0.outcome) }.count
        let failed = cases.filter { ["failed", "failure", "error", "timeout", "aborted"].contains($0.outcome) }
        let skipped = cases.filter { ["skipped", "ignored", "notexecuted", "notrun"].contains($0.outcome) }.count
        return TestResultSummary(format: format, total: cases.count, passed: passed, failed: failed.count, skipped: skipped,
                                 other: cases.count - passed - failed.count - skipped, failingNames: failed.map(\.name), warnings: warnings)
    }
}

private struct ParseBudget {
    let deadline: UInt64
    let canceled: () -> Bool
    init(milliseconds: Int, canceled: @escaping () -> Bool) {
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, min(milliseconds, 2_000))) * 1_000_000
        self.canceled = canceled
    }
    func check() throws {
        if canceled() { throw TestResultParseError.canceled }
        if DispatchTime.now().uptimeNanoseconds >= deadline { throw TestResultParseError.limit }
    }
}

private final class ResultXML: NSObject, XMLParserDelegate {
    let budget: ParseBudget
    var failure: TestResultParseError?
    var format: TestResultSummary.Format?
    var names: [String] = []
    var cases: [TestResultParser.ResultCase] = []
    var trxStack: [TestResultParser.ResultCase] = []
    var declared: [String: Int] = [:]
    var nodes = 0
    var runOutcome = ""
    init(budget: ParseBudget) { self.budget = budget }

    func check(_ parser: XMLParser) -> Bool {
        do { try budget.check(); return true }
        catch { failure = error as? TestResultParseError ?? .limit; parser.abortParsing(); return false }
    }
    func stop(_ parser: XMLParser, _ error: TestResultParseError) { failure = error; parser.abortParsing() }
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        guard check(parser) else { return }
        nodes += 1
        guard nodes <= 100_000, names.count < 64 else { stop(parser, .limit); return }
        let name = element.split(separator: ":").last.map(String.init) ?? element
        names.append(name)
        if names.count == 1 {
            switch name {
            case "test-run", "test-results": format = .nunit; runOutcome = a["result"] ?? ""
            case "TestRun": format = .trx
            default: stop(parser, .invalid("Expected a NUnit or TRX result document.")); return
            }
            if format == .nunit { readCounters(a, parser: parser) }
        }
        if format == .trx, names == ["TestRun", "ResultSummary"] { runOutcome = a["outcome"] ?? "" }
        guard runOutcome.utf8.count <= 128 else { stop(parser, .limit); return }
        if format == .trx, names == ["TestRun", "ResultSummary", "Counters"] { readCounters(a, parser: parser) }
        if format == .nunit, name == "test-case" {
            append(a["fullname"] ?? a["name"] ?? "Unnamed test", outcome: a["result"] ?? "unknown", parser: parser)
        }
        if format == .trx, name == "UnitTestResult", names.contains("Results") {
            if !trxStack.isEmpty { trxStack[trxStack.count - 1].children = true }
            let label = a["testName"] ?? "Unnamed test"
            guard label.utf8.count <= 2_048, label.count <= TestResultParser.maxNameLength else { stop(parser, .limit); return }
            trxStack.append(.init(name: label, outcome: (a["outcome"] ?? "unknown").lowercased()))
        }
    }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        guard check(parser) else { return }
        let name = element.split(separator: ":").last.map(String.init) ?? element
        if format == .trx, name == "UnitTestResult", let result = trxStack.popLast(), !result.children {
            append(result.name, outcome: result.outcome, parser: parser)
        }
        if !names.isEmpty { names.removeLast() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { _ = check(parser) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { _ = check(parser) }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        stop(parser, .invalid("External entities are not supported.")); return nil
    }
    func append(_ name: String, outcome: String, parser: XMLParser) {
        guard cases.count < TestResultParser.maxCases, name.utf8.count <= 2_048, name.count <= TestResultParser.maxNameLength else { stop(parser, .limit); return }
        cases.append(.init(name: name, outcome: outcome.lowercased()))
    }
    func readCounters(_ a: [String: String], parser: XMLParser) {
        for key in ["total", "passed", "failed", "skipped", "notExecuted"] where a[key] != nil {
            guard let value = Int(a[key] ?? ""), (0...1_000_000).contains(value) else { stop(parser, .invalid("Invalid test counters.")); return }
            declared[key] = value
        }
    }
    func summary() throws -> TestResultSummary {
        try budget.check()
        guard let format, names.isEmpty, trxStack.isEmpty else { throw TestResultParseError.invalid("Incomplete XML result.") }
        guard !cases.isEmpty || declared["total"] == 0 else { throw TestResultParseError.invalid("No individual test results were found.") }
        var result = TestResultParser.makeSummary(format, cases, warnings: [])
        var warnings: [String] = []
        if let total = declared["total"], total != result.total { warnings.append("Declared total differs from parsed leaf cases; counts below describe only the parsed cases.") }
        for (key, count) in [("passed", result.passed), ("failed", result.failed), (format == .trx ? "notExecuted" : "skipped", result.skipped)] {
            if let value = declared[key], value != count { warnings.append("Declared \(key) differs from parsed case outcomes.") }
        }
        if result.other > 0 { warnings.append("Other outcomes include inconclusive, pending or unrecognized results; they are not passes.") }
        if !runOutcome.isEmpty, !["passed", "completed", "success"].contains(runOutcome.lowercased()), result.failed == 0, result.other == 0 {
            warnings.append("The report's overall run outcome is \(String(runOutcome.prefix(80))) despite no failed/other leaf cases. Inspect the original.")
        }
        result = TestResultParser.makeSummary(format, cases, warnings: warnings)
        try budget.check()
        return result
    }
}
