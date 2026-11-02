import XCTest
@testable import ChecklistBridges

final class CodexQueueFollowupTests: XCTestCase {
    private final class Open: CodexThreadOpenEffects {
        var calls = 0;var thread: String?;var timeout: TimeInterval?;var status: Int32 = 0;var fails = false
        func open(threadID: String, timeout: TimeInterval) throws -> Int32 {
            calls += 1;thread = threadID;self.timeout = timeout
            if fails { throw NativeBridgeError.outcomeUnknown("Synthetic open timeout") };return status
        }
    }
    private func registration() throws -> NativeLifecycleRegistration {
        try XCTUnwrap(NativeLifecycleRegistration(provider:"codex",sessionID:"00000000-0000-4000-8000-000000000413",executionDomain:"codex:24680:5:0",registryPath:nil))
    }
    func testPendingExactItemWaitsTwentySecondsAndOpensOnce() throws {
        let open = Open();var elapsed: TimeInterval = 0;var reads = 0
        let result = CodexQueueFollowup.finish(itemID:"exact-item",registration:try registration(),openEnabled:true,
            item:{ XCTAssertEqual($0,"exact-item");reads += 1;return .pending },observe:{ .init(host:.nativeApp,reason:.sourceVscode) },
            authorized:{ true },now:{ elapsed },pause:{ elapsed += $0 },openEffects:open)
        XCTAssertEqual(elapsed,20);XCTAssertEqual(reads,22);XCTAssertEqual(open.calls,1);XCTAssertEqual(open.timeout,5)
        XCTAssertEqual(result,.init(pollResult:"pending_after_20s",openResult:"exited_zero",openExitStatus:0))
    }
    func testLoadedConsumptionDoesNotOpenOrClaimAcknowledgment() throws {
        let open = Open();var elapsed: TimeInterval = 0
        let result = CodexQueueFollowup.finish(itemID:"item",registration:try registration(),openEnabled:true,
            item:{ _ in elapsed >= 8 ? .removed : .pending },observe:{ .init(host:.nativeApp,reason:.sourceVscode) },
            authorized:{ true },now:{ elapsed },pause:{ elapsed += $0 },openEffects:open)
        XCTAssertEqual(elapsed,8);XCTAssertEqual(open.calls,0);XCTAssertEqual(result.pollResult,"removed");XCTAssertEqual(result.openResult,"not_needed")
    }
    func testOpenSwitchAndSourceOrAuthorizationChangeRefuseOpen() throws {
        for mode in 0..<3 {
            let open = Open();var elapsed: TimeInterval = 0
            let result = CodexQueueFollowup.finish(itemID:"item",registration:try registration(),openEnabled:mode != 0,
                item:{ _ in .pending },observe:{ .init(host:mode == 1 ? .exec : .nativeApp,reason:mode == 1 ? .sourceExec : .sourceVscode) },
                authorized:{ mode != 2 || elapsed < 20 },now:{ elapsed },pause:{ elapsed += $0 },openEffects:open)
            XCTAssertEqual(open.calls,0);XCTAssertEqual(result.openResult,["disabled","refused","authorization_changed"][mode])
        }
    }
    func testReadErrorsMissingItemAndLateConsumptionNeverOpen() throws {
        let open = Open()
        for reason in [CodexQueueReason.databaseLocked,.databaseMissing,.databaseReadError,.schemaUnrecognized,.databaseVersionUnsupported] {
            let result = CodexQueueFollowup.finish(itemID:"item",registration:try registration(),openEnabled:true,
                item:{ _ in .failed(reason) },observe:{ .init(host:.nativeApp,reason:.sourceVscode) },authorized:{ true },now:{ 0 },pause:{ _ in XCTFail("No wait after a read failure") },openEffects:open)
            XCTAssertEqual(result.pollResult,reason.rawValue)
        }
        let missing = CodexQueueFollowup.finish(itemID:nil,registration:try registration(),openEnabled:true,item:{ _ in XCTFail();return .pending },observe:{ .init(reason:.sourceExec) },authorized:{ true },now:{ 0 },pause:{ _ in XCTFail() },openEffects:open)
        XCTAssertEqual(missing.pollResult,"item_unconfirmed")
        var elapsed: TimeInterval = 0;var reads = 0
        let late = CodexQueueFollowup.finish(itemID:"item",registration:try registration(),openEnabled:true,item:{ _ in reads += 1;return reads >= 22 ? .removed : .pending },observe:{ .init(host:.nativeApp,reason:.sourceVscode) },authorized:{ true },now:{ elapsed },pause:{ elapsed += $0 },openEffects:open)
        XCTAssertEqual(late.pollResult,"removed");XCTAssertEqual(open.calls,0)
    }
    func testRevocationDuringLastItemReadRefusesOpen() throws {
        let open = Open();var elapsed: TimeInterval = 0;var reads = 0;var authorized = true
        let result = CodexQueueFollowup.finish(itemID:"item",registration:try registration(),openEnabled:true,
            item:{ _ in reads += 1;if reads == 22 { authorized = false };return .pending },observe:{ .init(host:.nativeApp,reason:.sourceVscode) },
            authorized:{ authorized },now:{ elapsed },pause:{ elapsed += $0 },openEffects:open)
        XCTAssertEqual(result.openResult,"authorization_changed");XCTAssertEqual(open.calls,0)
    }

    func testOpenFailureAndTimeoutKeepQueueReceiptHonestAndNeverRetry() throws {
        for fail in [false,true] {
            let open = Open();open.status = 7;open.fails = fail;var elapsed: TimeInterval = 0
            let result = CodexQueueFollowup.finish(itemID:"item",registration:try registration(),openEnabled:true,item:{ _ in .pending },observe:{ .init(host:.nativeApp,reason:.sourceVscode) },authorized:{ true },now:{ elapsed },pause:{ elapsed += $0 },openEffects:open)
            XCTAssertEqual(open.calls,1);XCTAssertEqual(result.openResult,fail ? "outcome_unknown" : "failed")
            XCTAssertNil(result.metadata["acknowledged"]);XCTAssertNil(result.metadata["delivered"])
        }
    }
}
