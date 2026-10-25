import XCTest
@testable import ChecklistApp

@MainActor final class TicketCleanupReceiptObservationTests: XCTestCase {
    func testCachedOpeningKeepsFactsAndRefreshInvalidates() async {
        let model = TicketCleanupReceiptObservation();var calls = 0
        func fetch() async throws -> [String:Any] {
            calls += 1
            return ["receipts":[["id":"r","created_at":"today","summary":["removed_bytes":42,"retained_count":3],"bytes_state":"pending"]]]
        }
        await model.load(scope:"project:store:epoch",fetch:fetch)
        // A cached opening still refreshes in the background (CL-260); it never skips the read.
        await model.load(scope:"project:store:epoch",fetch:fetch)
        XCTAssertEqual(calls,2);XCTAssertEqual(model.receipts.first?.string("bytes_state"),"pending")
        XCTAssertEqual(model.receipts.first?.object("summary")["removed_bytes"] as? Int,42)
        model.invalidate(scope:"project:store:epoch")
        XCTAssertFalse(model.install(scope:"project:store:epoch"),"Invalidated receipts cannot be installed")
        await model.load(scope:"project:store:epoch",fetch:fetch);XCTAssertEqual(calls,3)
        await model.load(scope:"project:new-store:epoch",fetch:fetch);XCTAssertEqual(calls,4)
        await model.load(scope:"project:new-store:new-epoch",fetch:fetch);XCTAssertEqual(calls,5)
    }
    /// CL-260 item 2: the retained rows of an exact scope install synchronously
    /// and stay visible while the background read is pending or fails.
    func testCachedInstallPrecedesBackgroundReadAndKeepsRowsOnFailure() async {
        let model = TicketCleanupReceiptObservation()
        await model.load(scope:"p") {["receipts":[["id":"cached","summary":["removed_bytes":42]]]]}
        await model.load(scope:"q") {["receipts":[["id":"other"]]]}
        XCTAssertEqual(model.receipts.map(\.id),["other"])
        XCTAssertTrue(model.install(scope:"p"))
        XCTAssertEqual(model.scope,"p");XCTAssertTrue(model.loaded);XCTAssertEqual(model.receipts.map(\.id),["cached"])
        XCTAssertFalse(model.install(scope:"unknown"),"No receipts are installed for a scope without retained rows")
        XCTAssertEqual(model.scope,"p")
        var continuation: CheckedContinuation<[String:Any],Error>?
        let refresh = Task {await model.load(scope:"p") {try await withCheckedThrowingContinuation {continuation = $0}}}
        for _ in 0..<100 {if continuation != nil {break};await Task.yield()}
        XCTAssertNotNil(continuation,"A cached opening issues its background read")
        XCTAssertEqual(model.receipts.map(\.id),["cached"]);XCTAssertTrue(model.loaded)
        continuation?.resume(throwing:NSError(domain:"refresh",code:1))
        await refresh.value
        XCTAssertEqual(model.receipts.map(\.id),["cached"]);XCTAssertTrue(model.error.isEmpty,"A failed background read keeps the retained rows of this exact scope")
        await model.load(scope:"p") {["receipts":[["id":"fresh"]]]}
        XCTAssertEqual(model.receipts.map(\.id),["fresh"])
        XCTAssertTrue(model.install(scope:"p"));XCTAssertEqual(model.receipts.map(\.id),["fresh"],"The fresh reply replaces the retained rows")
    }
    func testSamePanelRetainsFactsAcrossReadVersionsWithoutCachingTheNewScope() async {
        let model = TicketCleanupReceiptObservation()
        await model.load(scope:"p:store:v1",presentationID:"visit:store") {["receipts":[["id":"accepted"]]]}
        var continuation: CheckedContinuation<[String:Any],Error>?
        let read = Task {await model.load(scope:"p:store:v2",presentationID:"visit:store") {try await withCheckedThrowingContinuation {continuation = $0}}}
        for _ in 0..<100 {if continuation != nil {break};await Task.yield()}
        XCTAssertNotNil(continuation)
        XCTAssertEqual(model.receipts.map(\.id),["accepted"])
        XCTAssertTrue(model.loaded)
        XCTAssertFalse(model.install(scope:"p:store:v2"),"Displayed facts do not authorize scoped cache reuse")
        continuation?.resume(returning:["receipts":[["id":"fresh"]]])
        await read.value
        XCTAssertEqual(model.receipts.map(\.id),["fresh"])
        XCTAssertTrue(model.install(scope:"p:store:v2"))
    }
    func testNewPanelOrStoreCannotRetainAnotherPresentationOnCacheMiss() async {
        for next in ["new-visit:store","visit:new-store"] {
            let model = TicketCleanupReceiptObservation()
            await model.load(scope:"p:store:v1",presentationID:"visit:store") {["receipts":[["id":"accepted"]]]}
            await model.load(scope:"p:other-scope",presentationID:next) {throw CancellationError()}
            XCTAssertTrue(model.receipts.isEmpty)
            XCTAssertFalse(model.loaded)
        }
    }
    func testLateProjectReplyDoesNotReplaceCurrentProject() async {
        let model = TicketCleanupReceiptObservation()
        var continuation: CheckedContinuation<[String:Any],Error>?
        let old = Task {await model.load(scope:"old") {try await withCheckedThrowingContinuation {continuation = $0}}}
        for _ in 0..<100 {if continuation != nil {break};await Task.yield()}
        await model.load(scope:"new") {["receipts":[["id":"new"]]]}
        continuation?.resume(returning:["receipts":[["id":"old"]]])
        await old.value
        XCTAssertEqual(model.receipts.map(\.id),["new"]);XCTAssertEqual(model.scope,"new")
    }
    func testFailureAndCanceledReplyDoNotCache() async {
        let model = TicketCleanupReceiptObservation()
        await model.load(scope:"p") {throw NSError(domain:"test",code:1)}
        XCTAssertFalse(model.error.isEmpty)
        let canceled = Task {await model.load(scope:"p") {try Task.checkCancellation();return ["receipts":[["id":"stale"]]]}}
        canceled.cancel();await canceled.value
        await model.load(scope:"p") {["receipts":[["id":"fresh"]]]}
        XCTAssertEqual(model.receipts.map(\.id),["fresh"]);XCTAssertTrue(model.error.isEmpty)
    }
    func testRefreshCancellationKeepsAcceptedRowsWithoutError() async {
        let model = TicketCleanupReceiptObservation()
        await model.load(scope:"p") {["receipts":[["id":"accepted"]]]}
        model.invalidate(scope:"p")
        await model.load(scope:"p") {throw CancellationError()}
        XCTAssertEqual(model.receipts.map(\.id),["accepted"])
        XCTAssertTrue(model.error.isEmpty)
        await model.load(scope:"p") {["receipts":[["id":"refreshed"]]]}
        XCTAssertEqual(model.receipts.map(\.id),["refreshed"])
    }
    func testRefreshKeepsRowsUntilNewReplyAndIgnoresSupersededFailure() async {
        let model = TicketCleanupReceiptObservation()
        await model.load(scope:"p") {["receipts":[["id":"accepted"]]]}
        model.invalidate(scope:"p")
        var continuation: CheckedContinuation<[String:Any],Error>?
        let old = Task {await model.load(scope:"p") {try await withCheckedThrowingContinuation {continuation = $0}}}
        for _ in 0..<100 {if continuation != nil {break};await Task.yield()}
        XCTAssertNotNil(continuation)
        XCTAssertEqual(model.receipts.map(\.id),["accepted"])
        await model.load(scope:"p") {["receipts":[["id":"new"]]]}
        continuation?.resume(throwing:NSError(domain:"late",code:1))
        await old.value
        XCTAssertEqual(model.receipts.map(\.id),["new"]);XCTAssertTrue(model.error.isEmpty)
    }
    func testCanceledTransportIgnoringCancellationCannotReplaceAcceptedRows() async {
        let model = TicketCleanupReceiptObservation()
        await model.load(scope:"p") {["receipts":[["id":"accepted"]]]}
        model.invalidate(scope:"p")
        var continuation: CheckedContinuation<[String:Any],Error>?
        let read = Task {await model.load(scope:"p") {try await withCheckedThrowingContinuation {continuation = $0}}}
        for _ in 0..<100 {if continuation != nil {break};await Task.yield()}
        XCTAssertNotNil(continuation)
        read.cancel();continuation?.resume(returning:["receipts":[["id":"stale"]]])
        await read.value
        XCTAssertEqual(model.receipts.map(\.id),["accepted"]);XCTAssertTrue(model.error.isEmpty)
    }
    func testChangedScopeDoesNotKeepAnotherProjectsRowsOnCancellation() async {
        let model = TicketCleanupReceiptObservation()
        await model.load(scope:"p") {["receipts":[["id":"accepted"]]]}
        await model.load(scope:"different-project") {throw CancellationError()}
        XCTAssertEqual(model.scope,"different-project")
        XCTAssertTrue(model.receipts.isEmpty);XCTAssertTrue(model.error.isEmpty)
    }
    func testAlreadyCanceledCachedReadDoesNotReplaceCurrentProject() async {
        let model = TicketCleanupReceiptObservation()
        await model.load(scope:"old") {["receipts":[["id":"old"]]]}
        await model.load(scope:"new") {["receipts":[["id":"new"]]]}
        let canceled = Task {await model.load(scope:"old") {XCTFail("A canceled cached read must not fetch");return [:]}}
        canceled.cancel();await canceled.value
        XCTAssertEqual(model.scope,"new");XCTAssertEqual(model.receipts.map(\.id),["new"])
    }
}
