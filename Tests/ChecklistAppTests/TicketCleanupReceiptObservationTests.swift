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
        let start = ProcessInfo.processInfo.systemUptime
        await model.load(scope:"project:store:epoch",fetch:fetch)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,0.3)
        XCTAssertEqual(calls,1);XCTAssertEqual(model.receipts.first?.string("bytes_state"),"pending")
        XCTAssertEqual(model.receipts.first?.object("summary")["removed_bytes"] as? Int,42)
        model.invalidate(scope:"project:store:epoch")
        await model.load(scope:"project:store:epoch",fetch:fetch);XCTAssertEqual(calls,2)
        await model.load(scope:"project:new-store:epoch",fetch:fetch);XCTAssertEqual(calls,3)
        await model.load(scope:"project:new-store:new-epoch",fetch:fetch);XCTAssertEqual(calls,4)
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
