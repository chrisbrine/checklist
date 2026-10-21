import Foundation

enum CheckFailure: Error { case failed(String) }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}
func parsed(_ text: String, milliseconds: Int = 250) throws -> TestResultSummary {
    try TestResultParser.parse(Data(text.utf8), milliseconds: milliseconds)
}
func rejects(_ body: () throws -> TestResultSummary) throws {
    do { _ = try body() }
    catch is TestResultParseError { return }
    throw CheckFailure.failed("Malformed/over-limit input was accepted")
}

let nunit = """
<?xml version="1.0" encoding="utf-8"?>
<test-run total="3" passed="1" failed="1" skipped="1" result="Failed">
 <test-suite total="3" passed="1" failed="1" skipped="1" result="Failed">
  <test-suite><test-case fullname="Suite.good" result="Passed"/></test-suite>
  <test-case fullname="Suite.bad &amp; &lt;script&gt;" result="Failed"><failure><message><![CDATA[not executable <html>]]></message></failure></test-case>
  <test-case fullname="Suite.ignored" result="Skipped"/>
 </test-suite>
</test-run>
"""
let trx = """
<TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010">
 <Results><UnitTestResult testName="Core.Good" outcome="Passed"/><UnitTestResult testName="Core.Bad" outcome="Failed"/><UnitTestResult testName="Core.Skip" outcome="NotExecuted"/></Results>
 <ResultSummary outcome="Failed"><Counters total="3" passed="1" failed="1" notExecuted="1"/></ResultSummary>
</TestRun>
"""
let swift = """
Test Suite 'All tests' started.
Test Suite 'ExampleTests.xctest' started.
Test Suite 'CoreTests' started.
Test Case '-[ExampleTests.CoreTests testGood]' started.
Test Case '-[ExampleTests.CoreTests testGood]' passed (0.001 seconds).
Test Case '-[ExampleTests.CoreTests testBad]' started.
Test Case '-[ExampleTests.CoreTests testBad]' failed (0.001 seconds).
Test Case '-[ExampleTests.CoreTests testSkip]' started.
Test Case '-[ExampleTests.CoreTests testSkip]' skipped (0.001 seconds).
Test Suite 'CoreTests' failed.
 Executed 3 tests, with 1 test skipped and 2 failures (0 unexpected) in 0.005 seconds
Test Suite 'ExampleTests.xctest' failed.
 Executed 3 tests, with 1 test skipped and 2 failures (0 unexpected) in 0.005 seconds
Test Suite 'All tests' failed.
 Executed 3 tests, with 1 test skipped and 2 failures (0 unexpected) in 0.005 seconds
◇ Test run started.
✔ Test run with 0 tests passed after 0.001 seconds.
"""

// Exact retained XCTest prefix (wave5 lines372–394), not a synthetic summary-only truncation.
let truncatedInnerSuite = """
Test Suite 'All tests' started at 2026-10-18 01:24:35.719.
Test Suite 'ChecklistPackageTests.xctest' started at 2026-10-18 01:24:35.720.
Test Suite 'AgentReviewAssessmentTests' started at 2026-10-18 01:24:35.720.
Test Case '-[ChecklistCoreTests.AgentReviewAssessmentTests testCapturedInstructionResolverRejectsEscapeCycleMissingAndOverlongChains]' started.
Test Case '-[ChecklistCoreTests.AgentReviewAssessmentTests testCapturedInstructionResolverRejectsEscapeCycleMissingAndOverlongChains]' passed (0.050 seconds).
Test Case '-[ChecklistCoreTests.AgentReviewAssessmentTests testCapturedInstructionSymlinkRequiresExactLinkAndResolvedContentCoverage]' started.
Test Case '-[ChecklistCoreTests.AgentReviewAssessmentTests testCapturedInstructionSymlinkRequiresExactLinkAndResolvedContentCoverage]' passed (0.112 seconds).
Test Case '-[ChecklistCoreTests.AgentReviewAssessmentTests testCurrentProjectRequirementsChangeAssessmentContractAndNeedFullCoverage]' started.
Test Case '-[ChecklistCoreTests.AgentReviewAssessmentTests testCurrentProjectRequirementsChangeAssessmentContractAndNeedFullCoverage]' passed (0.044 seconds).
Test Case '-[ChecklistCoreTests.AgentReviewAssessmentTests testDisabledRunnerNeverExecutesSubmittedCodeOrQueuesAJob]' started.
Test Case '-[ChecklistCoreTests.AgentReviewAssessmentTests testDisabledRunnerNeverExecutesSubmittedCodeOrQueuesAJob]' passed (0.037 seconds).
Test Case '-[ChecklistCoreTests.AgentReviewAssessmentTests testEachAcceptanceMustBeAssessedAndOwnEvidenceIsRequiredWithoutForcedTests]' started.
Test Case '-[ChecklistCoreTests.AgentReviewAssessmentTests testEachAcceptanceMustBeAssessedAndOwnEvidenceIsRequiredWithoutForcedTests]' passed (0.042 seconds).
Test Case '-[ChecklistCoreTests.AgentReviewAssessmentTests testFreshPreparationDoesNotClaimOrLaunchAndKeepsExactContext]' started.
Test Case '-[ChecklistCoreTests.AgentReviewAssessmentTests testFreshPreparationDoesNotClaimOrLaunchAndKeepsExactContext]' passed (0.043 seconds).
Test Case '-[ChecklistCoreTests.AgentReviewAssessmentTests testManagedReviewerReportBindsExactAttemptAndCleansBytesOnRollback]' started.
Test Case '-[ChecklistCoreTests.AgentReviewAssessmentTests testManagedReviewerReportBindsExactAttemptAndCleansBytesOnRollback]' passed (0.064 seconds).
Test Case '-[ChecklistCoreTests.AgentReviewAssessmentTests testNestedCapturedInstructionSymlinkChainUsesOnlyIncludedTargets]' started.
Test Case '-[ChecklistCoreTests.AgentReviewAssessmentTests testNestedCapturedInstructionSymlinkChainUsesOnlyIncludedTargets]' passed (0.048 seconds).
Test Case '-[ChecklistCoreTests.AgentReviewAssessmentTests testSubmittedAuthorFileCannotImpersonateOwnReviewReport]' started.
Test Case '-[ChecklistCoreTests.AgentReviewAssessmentTests testSubmittedAuthorFileCannotImpersonateOwnReviewReport]' passed (0.038 seconds).
Test Suite 'AgentReviewAssessmentTests' passed at 2026-10-18 01:24:36.199.
	 Executed 9 tests, with 0 failures (0 unexpected) in 0.478 (0.479) seconds
"""

let checks: [(String, () throws -> Void)] = [
    ("NUnit nested suites, decoded names and case counts", {
        let r = try parsed(nunit)
        try require(r.format == .nunit && r.total == 3 && r.passed == 1 && r.failed == 1 && r.skipped == 1 && r.other == 0, "NUnit outcomes or suite deduplication")
        try require(r.failingNames == ["Suite.bad & <script>"] && r.warnings.isEmpty, "Failure text must remain literal; ordinary failed runs are not malformed")
    }),
    ("Basic legacy NUnit outcome labels", {
        let r = try parsed("<test-results total=\"3\"><test-suite><test-case name=\"A\" result=\"Success\"/><test-case name=\"B\" result=\"Failure\"/><test-case name=\"C\" result=\"Ignored\"/></test-suite></test-results>")
        try require(r.passed == 1 && r.failed == 1 && r.skipped == 1, "Legacy case outcomes")
    }),
    ("TRX namespace, skipped outcome and failing name", {
        let r = try parsed(trx)
        try require(r.format == .trx && r.total == 3 && r.passed == 1 && r.failed == 1 && r.skipped == 1 && r.failingNames == ["Core.Bad"], "TRX outcomes")
        try require(r.warnings.isEmpty, "An ordinary failed TRX run must remain comparable")
    }),
    ("TRX data-driven aggregate is not counted twice", {
        let r = try parsed("<TestRun><Results><UnitTestResult testName=\"aggregate\" outcome=\"Failed\"><InnerResults><UnitTestResult testName=\"row1\" outcome=\"Failed\"/><UnitTestResult testName=\"row2\" outcome=\"Passed\"/></InnerResults></UnitTestResult></Results><ResultSummary><Counters total=\"2\" passed=\"1\" failed=\"1\"/></ResultSummary></TestRun>")
        try require(r.total == 2 && r.failed == 1 && r.failingNames == ["row1"], "TRX parent double count")
    }),
    ("Unknown and inconclusive results cannot become passes", {
        let r = try parsed("<test-run total=\"2\"><test-case name=\"pending\" result=\"Inconclusive\"/><test-case name=\"future\" result=\"NewState\"/></test-run>")
        try require(r.other == 2 && r.passed == 0 && !r.warnings.isEmpty, "Unknown results should remain other")
    }),
    ("Declared counters do not replace contradictory leaf results", {
        let r = try parsed("<test-run total=\"99\" passed=\"99\" failed=\"0\"><test-case name=\"broken\" result=\"Failed\"/></test-run>")
        try require(r.total == 1 && r.failed == 1 && r.passed == 0 && r.warnings.count >= 2, "Counters may not manufacture a pass")
    }),
    ("Overall run failure with passing cases remains visible", {
        let r = try parsed("<TestRun><Results><UnitTestResult testName=\"ok\" outcome=\"Passed\"/></Results><ResultSummary outcome=\"Failed\"><Counters total=\"1\" passed=\"1\" failed=\"0\"/></ResultSummary></TestRun>")
        try require(r.passed == 1 && !r.warnings.isEmpty, "Run-level failure must not disappear")
    }),
    ("Swift nested totals, skipped case and zero-test trailer", {
        let r = try parsed(swift)
        try require(r.format == .swift && r.total == 3 && r.passed == 1 && r.failed == 1 && r.skipped == 1 && r.failingNames == ["-[ExampleTests.CoreTests testBad]"], "Counts are cases, not duplicated suite totals or assertion failures")
    }),
    ("CRLF Swift output", {
        let r = try parsed(swift.replacingOccurrences(of: "\n", with: "\r\n"))
        try require(r.total == 3, "CRLF log")
    }),
    ("Incomplete Swift run rejected", { try rejects { try parsed("Test Case 'Suite.test' failed (0.1 seconds).") } }),
    ("Inner-suite summary with an open outer XCTest run is rejected", {
        try rejects { try parsed(truncatedInnerSuite) }
    }),
    ("Completed outer XCTest run retains later failures", {
        let completed = truncatedInnerSuite + "\nTest Suite 'LaterTests' started.\nTest Case 'LaterTests.bad' started.\nTest Case 'LaterTests.bad' failed (0.1 seconds).\nTest Suite 'LaterTests' failed.\nExecuted 1 test, with 1 failure (0 unexpected) in 0.1 seconds\nTest Suite 'ChecklistPackageTests.xctest' failed.\nExecuted 10 tests, with 1 failure (0 unexpected) in 0.6 seconds\nTest Suite 'All tests' failed.\nExecuted 10 tests, with 1 failure (0 unexpected) in 0.6 seconds"
        let r = try parsed(completed)
        try require(r.total == 10 && r.passed == 9 && r.failed == 1 && r.failingNames == ["LaterTests.bad"], "Inner all-green prefix must not hide later failure")
        let selected = try parsed(swift.replacingOccurrences(of: "All tests", with: "Selected tests"))
        try require(selected.total == 3 && selected.failed == 1, "Complete filtered XCTest run")
        try rejects { try parsed(completed.replacingOccurrences(of: "Test Suite 'All tests' failed.", with: "Test Suite 'Wrong suite' failed.")) }
        try rejects { try parsed("Test Suite 'All tests' started.\nTest Suite 'All tests' passed.") }
    }),
    ("Concatenated complete Swift runs rejected", {
        let run = "Test Suite 'All tests' started.\nTest Case 'Suite.test' passed (0.1 seconds).\nTest Suite 'All tests' passed.\nExecuted 1 test, with 0 failures (0 unexpected) in 0.1 seconds\n"
        try rejects { try parsed(run + run) }
    }),
    ("Swift-Testing-only and arbitrary shell content not interpreted", {
        try rejects { try parsed("✔ Test run with 3 tests passed after 0.1 seconds.\n$(open /tmp/never)") }
    }),
    ("External DTD and entity references rejected", {
        try rejects { try parsed("<!DOCTYPE test-run SYSTEM 'file:///not-authorized'><test-run total=\"0\"/>") }
        try rejects { try parsed("<!DOCTYPE test-run [<!ENTITY external SYSTEM 'https://invalid.example/never'>]><test-run total=\"0\">&external;</test-run>") }
    }),
    ("Internal entity expansion rejected", {
        try rejects { try parsed("<!DOCTYPE test-run [<!ENTITY a 'abc'><!ENTITY b '&a;&a;'>]><test-run total=\"0\">&b;</test-run>") }
    }),
    ("Malformed and unsupported XML rejected", {
        try rejects { try parsed("<test-run><test-case name=\"a\" result=\"Passed\">") }
        try rejects { try parsed("<html><script>arbitrary text</script></html>") }
    }),
    ("UTF-8 and input byte boundaries", {
        try rejects { try TestResultParser.parse(Data([0xff, 0xfe, 0x00])) }
        try rejects { try TestResultParser.parse(Data(repeating: 0x61, count: TestResultParser.maxBytes + 1)) }
    }),
    ("Name character and combining-byte limits", {
        try rejects { try parsed("<test-run><test-case name=\"\(String(repeating: "a", count: 513))\" result=\"Failed\"/></test-run>") }
        let combining = "a" + String(repeating: "\u{301}", count: 1500)
        try require(combining.count == 1, "Combining fixture should be one grapheme")
        try rejects { try parsed("<test-run><test-case name=\"\(combining)\" result=\"Failed\"/></test-run>") }
    }),
    ("XML depth bound", {
        try rejects { try parsed("<test-run total=\"0\">" + String(repeating: "<x>", count: 65) + String(repeating: "</x>", count: 65) + "</test-run>") }
    }),
    ("Case count bound", {
        try rejects { try parsed("<test-run>" + String(repeating: "<test-case name=\"a\" result=\"Passed\"/>", count: TestResultParser.maxCases + 1) + "</test-run>", milliseconds: 2_000) }
    }),
    ("Deadline and cancellation stop parsing", {
        try rejects { try TestResultParser.parse(Data(nunit.utf8), milliseconds: 0) }
        var checks = 0
        do {
            _ = try TestResultParser.parse(Data(nunit.utf8), isCanceled: { checks += 1; return checks > 5 })
            throw CheckFailure.failed("Expected mid-parse cancellation")
        } catch TestResultParseError.canceled { }
    }),
    ("Negative and overflowing counters rejected", {
        try rejects { try parsed("<test-run total=\"-1\"/>") }
        try rejects { try parsed("<TestRun><ResultSummary><Counters total=\"9999999999999999999999\"/></ResultSummary></TestRun>") }
    }),
    ("Complete empty runs remain zero counts", {
        let xml = try parsed("<test-run total=\"0\" passed=\"0\" failed=\"0\" skipped=\"0\"/>")
        let log = try parsed("Test Suite 'All tests' started.\nTest Suite 'All tests' passed.\nExecuted 0 tests, with 0 failures (0 unexpected) in 0.1 seconds")
        try require(xml.total == 0 && log.total == 0, "Empty complete runs")
    })
]

let requested = Set(CommandLine.arguments.dropFirst())
let known = Set(checks.map { $0.0 })
guard requested.isSubset(of: known) else { print("Unknown selected check; pass exact reported names."); exit(2) }
let selected = checks.filter { requested.isEmpty || requested.contains($0.0) }
var failures = 0
for (name, check) in selected {
    do { try check(); print("PASS \(name)") }
    catch { failures += 1; print("FAIL \(name): \(error)") }
}
print("\(selected.count) selected parser checks, \(failures) failures")
if failures != 0 { exit(1) }
