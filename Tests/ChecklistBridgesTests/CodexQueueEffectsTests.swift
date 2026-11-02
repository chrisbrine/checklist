import XCTest
@testable import ChecklistBridges

final class CodexQueueEffectsTests: XCTestCase {
    private let threadID = "00000000-0000-4000-8000-000000000413"

    func testQueueOutputIdentifiesOnlyTheExactThreadReceipt() {
        for ending in ["", "\n"] {
            let output = Data("Queued message opaque_123-abc for thread \(threadID).\(ending)".utf8)
            XCTAssertEqual(CodexQueueOutput.itemID(output,threadID:threadID),"opaque_123-abc")
        }
        XCTAssertNil(CodexQueueOutput.itemID(Data("Queued message item for thread \(UUID().uuidString).\n".utf8),threadID:threadID))
    }

    func testQueueOutputRefusesAmbiguousMalformedAndUnrelatedOutput() {
        let valid = "Queued message item for thread \(threadID)."
        for output in [valid+"\n\n", "prefix "+valid, valid+" suffix", valid+"\r\n",
                       "Queued message bad item for thread \(threadID).", "{\"id\":\"item\"}",
                       "Queued message  for thread \(threadID).",
                       "Queued message "+String(repeating:"x",count:161)+" for thread \(threadID)."] {
            XCTAssertNil(CodexQueueOutput.itemID(Data(output.utf8),threadID:threadID),output)
        }
        XCTAssertNil(CodexQueueOutput.itemID(Data([0xff]),threadID:threadID))
        XCTAssertNil(CodexQueueOutput.itemID(Data(valid.utf8),threadID:"--help"))
    }

    func testQueueOutputAcceptsSafeOpaqueIdentifiersOnly() {
        for itemID in ["a", "ABC_123-def", String(repeating:"x",count:160)] {
            let output = Data("Queued message \(itemID) for thread \(threadID).\n".utf8)
            XCTAssertEqual(CodexQueueOutput.itemID(output,threadID:threadID),itemID)
        }
        for itemID in ["a/b", "a\0b", "a\nb", "å", "a.b"] {
            let output = Data("Queued message \(itemID) for thread \(threadID).\n".utf8)
            XCTAssertNil(CodexQueueOutput.itemID(output,threadID:threadID))
        }
    }

    func testOpenUsesCanonicalUUIDAndArgumentArray() throws {
        XCTAssertEqual(try MacOSCodexThreadOpenEffects.arguments(threadID:threadID.uppercased()),
                       ["-g","codex://threads/"+threadID])
        for hostile in ["--help", threadID+"; open https://example.com", "../"+threadID,
                        threadID+"?message=hostile", threadID+"\n"] {
            XCTAssertThrowsError(try MacOSCodexThreadOpenEffects.arguments(threadID:hostile))
        }
    }

    func testCallerEnvironmentCannotRedirectCodexHome() throws {
        let environment = try CodexCommandEnvironment.pinned(
            ["HOME":"/tmp/hostile","CODEX_HOME":"/tmp/hostile-codex","PATH":"/usr/bin"],home:"/Users/actual")
        XCTAssertEqual(environment["HOME"],"/Users/actual")
        XCTAssertEqual(environment["CODEX_HOME"],"/Users/actual/.codex")
        XCTAssertEqual(environment["PATH"],"/usr/bin")
        XCTAssertThrowsError(try CodexCommandEnvironment.pinned([:],home:"relative"))
        XCTAssertThrowsError(try CodexCommandEnvironment.pinned([:],home:"/bad\0home"))
    }

    func testBoundedCommandCapturesOnlyBoundedOutputWithoutPipeDeadlock() throws {
        let result = try BoundedCodexCommand.run(executable:"/bin/sh",
            arguments:["-c","i=0; while [ \"$i\" -lt 10000 ]; do printf x; i=$((i+1)); done"],
            environment:["PATH":"/usr/bin:/bin"],timeout:5,captureOutput:true)
        XCTAssertEqual(result.exitStatus,0)
        XCTAssertTrue(result.exitedNormally)
        XCTAssertEqual(result.output.count,4096)
        XCTAssertTrue(result.outputOverflow)
    }

    func testBoundedCommandDoesNotWaitForDescendantPipeEOF() throws {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try BoundedCodexCommand.run(executable:"/bin/sh",
            arguments:["-c","sleep 2 & printf synthetic"],
            environment:["PATH":"/usr/bin:/bin"],timeout:0.5,captureOutput:true)
        XCTAssertEqual(result.exitStatus,0)
        XCTAssertEqual(String(data:result.output,encoding:.utf8),"synthetic")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,1.5)
    }

    func testBoundedCommandTimesOutWithoutRetry() {
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try BoundedCodexCommand.run(executable:"/bin/sh",
            arguments:["-c","while :; do :; done"],environment:[:],timeout:0.05,captureOutput:true))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,1.5)
    }

    func testBoundedCommandPreservesNonzeroExitWithoutRetry() throws {
        let result = try BoundedCodexCommand.run(executable:"/bin/sh",arguments:["-c","printf synthetic; exit 7"],
            environment:[:],timeout:1,captureOutput:true)
        XCTAssertTrue(result.exitedNormally)
        XCTAssertEqual(result.exitStatus,7)
        XCTAssertEqual(String(data:result.output,encoding:.utf8),"synthetic")
    }

    func testQueueReceiptRemainsCompatibleWithoutAnIdentifiedItem() {
        let receipt = CodexQueueReceipt(exitStatus:0,byteCount:12)
        XCTAssertNil(receipt.itemID)
        XCTAssertEqual(receipt,CodexQueueReceipt(exitStatus:0,byteCount:12,itemID:nil))
    }
}
