import XCTest
@testable import ChecklistBridges

final class CodexQueueFollowupTests: XCTestCase {
    /// Runs each scheduled step at once on an injected clock. Nothing sleeps, which
    /// also shows that the wait needs no held thread.
    private final class Harness: @unchecked Sendable {
        var elapsed: TimeInterval = 0, delays: [TimeInterval] = [], reads = 0, opens: [String] = [], statusReads = 0
        var openEnabled = true, openStatus: Int32 = 0, openFails = false
        var item: (Harness) -> CodexQueueStore.Item = { _ in .pending }
        var status: (Harness) -> CodexQueueDeliveryStatus = { _ in .current }
        var observation = CodexQueueObservation(host:.nativeApp,reason:.sourceVscode)
        var load = CodexThreadLoad.unloaded
        var execHolder: (Harness) -> Bool = { _ in false }
        var result: CodexQueueFollowupReceipt?
        func run(item id: String? = "item") throws -> CodexQueueFollowupReceipt {
            let registration = try XCTUnwrap(NativeLifecycleRegistration(provider:"codex",sessionID:"00000000-0000-4000-8000-000000000413",executionDomain:"codex:24680:5:0",registryPath:nil))
            let environment = CodexQueueFollowupEnvironment(openEnabled:openEnabled,
                item:{ [self] _ in reads += 1;return item(self) },observe:{ [self] in observation },load:{ [self] in load },
                status:{ [self] in statusReads += 1;return status(self) },now:{ [self] in elapsed },
                schedule:{ [self] delay,body in delays.append(delay);elapsed += delay;body() },
                open:{ [self] thread,_ in opens.append(thread);if openFails { throw NativeBridgeError.outcomeUnknown("Synthetic open timeout") };return openStatus },
                execHolder:{ [self] in execHolder(self) })
            CodexQueueFollowup.run(itemID:id,registration:registration,environment:environment) { [self] in result = $0 }
            return try XCTUnwrap(result)
        }
    }

    func testPendingUnloadedItemPollsEveryFiveSecondsAndOpensOnce() throws {
        let h = Harness()
        let result = try h.run()
        XCTAssertEqual(h.delays,[5,5,5,5]);XCTAssertEqual(h.elapsed,20);XCTAssertEqual(h.reads,6);XCTAssertEqual(h.opens.count,1)
        XCTAssertEqual(result,.init(pollResult:"pending_after_20s",openResult:"exited_zero",openExitStatus:0))
    }
    func testLoadedConsumptionDoesNotOpenOrClaimAcknowledgment() throws {
        let h = Harness();h.item = { $0.elapsed >= 10 ? .removed : .pending }
        let result = try h.run()
        XCTAssertEqual(h.elapsed,10);XCTAssertEqual(h.opens.count,0);XCTAssertEqual(result.pollResult,"removed");XCTAssertEqual(result.openResult,"not_needed")
    }
    /// A loaded thread with a long turn keeps its item for 20 s, as an unloaded thread does.
    func testRunningTurnAndUnknownStateNeverOpen() throws {
        for (load,expected) in [(CodexThreadLoad.loaded,"loaded_pending"),(.unknown,"state_unknown")] {
            let h = Harness();h.load = load
            XCTAssertEqual(try h.run().openResult,expected);XCTAssertEqual(h.opens.count,0)
        }
    }
    func testOpenSwitchAndSourceChangeRefuseOpen() throws {
        let off = Harness();off.openEnabled = false
        XCTAssertEqual(try off.run().openResult,"disabled");XCTAssertEqual(off.opens.count,0)
        let exec = Harness();exec.observation = .init(host:.exec,reason:.sourceExec)
        XCTAssertEqual(try exec.run().openResult,"refused");XCTAssertEqual(exec.opens.count,0)
    }
    func testFastAcknowledgmentIsNotAuthorizationChange() throws {
        let h = Harness();h.status = { $0.elapsed >= 5 ? .acknowledged : .current }
        XCTAssertEqual(try h.run(),.init(pollResult:"acknowledged",openResult:"not_needed"));XCTAssertEqual(h.opens.count,0)
    }
    func testFenceDuringWaitAndAtLastCheckRefuseOpen() throws {
        let h = Harness();h.status = { $0.elapsed >= 5 ? .changed : .current }
        XCTAssertEqual(try h.run(),.init(pollResult:"authorization_changed",openResult:"authorization_changed"));XCTAssertEqual(h.opens.count,0)
        let last = Harness();last.status = { $0.statusReads >= 6 ? .changed : .current }
        XCTAssertEqual(try last.run().openResult,"authorization_changed");XCTAssertEqual(last.opens.count,0)
    }
    func testReadErrorsMissingItemAndLateConsumptionNeverOpen() throws {
        for reason in [CodexQueueReason.databaseMissing,.databaseReadError,.schemaUnrecognized,.databaseVersionUnsupported] {
            let h = Harness();h.item = { _ in .failed(reason) }
            XCTAssertEqual(try h.run().pollResult,reason.rawValue);XCTAssertEqual(h.delays,[]);XCTAssertEqual(h.opens.count,0)
        }
        XCTAssertEqual(try Harness().run(item:nil).pollResult,"item_unconfirmed")
        XCTAssertEqual(try Harness().run(item:"bad item").openResult,"refused")
        let late = Harness();late.item = { $0.reads >= 6 ? .removed : .pending }
        XCTAssertEqual(try late.run().pollResult,"removed");XCTAssertEqual(late.opens.count,0)
    }
    func testOpenFailureAndTimeoutKeepQueueReceiptHonestAndNeverRetry() throws {
        for fail in [false,true] {
            let h = Harness();h.openStatus = 7;h.openFails = fail
            let result = try h.run()
            XCTAssertEqual(h.opens.count,1);XCTAssertEqual(result.openResult,fail ? "outcome_unknown" : "failed")
            XCTAssertNil(result.metadata["acknowledged"]);XCTAssertNil(result.metadata["delivered"])
        }
    }
    /// F1: the exec takes the item at its turn end and exits, so it can be gone at the read that sees the removal.
    func testItemGoneAfterAnExecHolderIsASeparateResult() throws {
        let h = Harness();h.item = { $0.elapsed >= 10 ? .removed : .pending };h.execHolder = { $0.elapsed == 5 }
        XCTAssertEqual(try h.run(),CodexQueueFollowup.removedByExec);XCTAssertEqual(h.opens,[])
        XCTAssertFalse(CodexQueueFollowup.removedByExec.metadata.values.contains { $0 as? String == "not_needed" })
        let late = Harness();late.item = { $0.elapsed >= 10 ? .removed : .pending };late.execHolder = { $0.elapsed >= 10 }
        XCTAssertEqual(try late.run(),CodexQueueFollowup.removedByExec)
        let none = Harness();none.item = { $0.elapsed >= 10 ? .removed : .pending }
        XCTAssertEqual(try none.run(),.init(pollResult:"removed",openResult:"not_needed"))
    }
    func testExecHolderDuringTheWaitOrAtTheLastCheckNeverOpens() throws {
        let during = Harness();during.execHolder = { $0.elapsed == 5 }
        XCTAssertEqual(try during.run(),.init(pollResult:"pending_after_20s",openResult:"exec_holder"));XCTAssertEqual(during.opens,[])
        // Polls run at 0, 5, 10, 15 and 20 s. The next read is the last check, after the load read.
        let last = Harness();var calls = 0;last.execHolder = { _ in calls += 1;return calls > 5 }
        XCTAssertEqual(try last.run(),.init(pollResult:"pending_after_20s",openResult:"exec_holder"));XCTAssertEqual(last.opens,[])
    }

    func testLockedReadContinuesTheWaitAndNeverOpensOnAnUnknownItem() throws {
        let later = Harness();later.item = { $0.reads <= 2 ? .failed(.databaseLocked) : .pending }
        let opened = try later.run()
        XCTAssertEqual(opened.pollResult,"pending_after_20s");XCTAssertEqual(opened.openResult,"exited_zero");XCTAssertEqual(later.opens.count,1)
        XCTAssertEqual(later.delays,[5,5,5,5])
        let taken = Harness();taken.item = { $0.reads == 1 ? .failed(.databaseLocked) : .removed }
        let result = try taken.run()
        XCTAssertEqual(result.pollResult,"removed");XCTAssertEqual(result.openResult,"not_needed");XCTAssertEqual(taken.delays,[5])
        let always = Harness();always.item = { _ in .failed(.databaseLocked) }
        let locked = try always.run()
        XCTAssertEqual(locked.pollResult,"database_locked");XCTAssertEqual(locked.openResult,"refused");XCTAssertEqual(always.opens.count,0)
        XCTAssertEqual(always.delays,[5,5,5,5],"The wait runs to its time limit")
        let atLast = Harness();atLast.item = { $0.reads >= 6 ? .failed(.databaseLocked) : .pending }
        let last = try atLast.run()
        XCTAssertEqual(last.pollResult,"database_locked");XCTAssertEqual(atLast.opens.count,0,"A locked read at the last check does not open")
        let other = Harness();other.item = { $0.reads == 1 ? .failed(.databaseReadError) : .pending }
        XCTAssertEqual(try other.run().pollResult,"database_read_error");XCTAssertEqual(other.delays,[],"Only a locked read continues")
    }
}
