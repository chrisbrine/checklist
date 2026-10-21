import XCTest
@testable import ChecklistApp

/// CL-52: the next-action bar under the status line; a blocking request comes first.
final class NextActionTests: XCTestCase {
    let ready = Record(values: ["id": "t1", "readiness": "ready", "status_category": "queued", "active_attempt_id": "a1"])
    let attempt = Record(values: ["id": "a1", "session_id": "s1", "state": "active", "phase": "implementation"])
    let blocking = Record(values: ["id": "r1", "state": "pending", "blocking": true])

    func testABlockingRequestComesFirst() {
        let ended = Record(values: ["id": "s1", "state": "ended"])
        XCTAssertEqual(TicketNextAction.lead(task: ready, requests: [blocking], activeAttempt: attempt, session: ended), .answer("r1"))
        let draft = Record(values: ["id": "t2", "readiness": "draft", "status_category": "queued"])
        XCTAssertEqual(TicketNextAction.lead(task: draft, requests: [blocking], activeAttempt: nil, session: nil), .answer("r1"))
        let answered = Record(values: ["id": "r2", "state": "answered", "blocking": true]), legacy = Record(values: ["id": "r3", "state": "cancelled", "blocking": true])
        let optional = Record(values: ["id": "r4", "state": "pending", "blocking": false])
        XCTAssertNil(TicketNextAction.blockingRequest([answered, legacy, optional]))
    }

    func testEndedOrUnknownSessionsNeedRecoveryNotWork() {
        XCTAssertEqual(TicketNextAction.lead(task: ready, requests: [], activeAttempt: attempt, session: Record(values: ["id": "s1", "state": "ended"])), .recover("a1"))
        XCTAssertEqual(TicketNextAction.lead(task: ready, requests: [], activeAttempt: attempt, session: Record(values: ["id": "s1", "state": "revoked"])), .recover("a1"))
        XCTAssertEqual(TicketNextAction.lead(task: ready, requests: [], activeAttempt: attempt, session: nil), .recover("a1"), "An unknown session is not shown as working")
        XCTAssertNil(TicketNextAction.lead(task: ready, requests: [], activeAttempt: attempt, session: Record(values: ["id": "s1", "state": "connected"])))
        // Review finding f56506ec: an existing session whose recorded state is unknown also needs recovery.
        XCTAssertEqual(TicketNextAction.lead(task: ready, requests: [], activeAttempt: attempt, session: Record(values: ["id": "s1", "state": "unknown"])), .recover("a1"))
        XCTAssertEqual(TicketNextAction.lead(task: ready, requests: [], activeAttempt: attempt, session: Record(values: ["id": "s1"])), .recover("a1"), "No recorded state is unknown")
        let owner = Record(values: ["id": "a2", "session_id": "human", "state": "active"])
        XCTAssertFalse(WorkHealth.needsRecovery(owner, session: nil), "The owner's own work has no agent session")
    }

    func testDoneAndDraft() {
        XCTAssertEqual(TicketNextAction.lead(task: Record(values: ["id": "t3", "status_category": "done"]), requests: [blocking], activeAttempt: nil, session: nil), .completed)
        XCTAssertEqual(TicketNextAction.lead(task: Record(values: ["id": "t4", "readiness": "draft", "status_category": "queued"]), requests: [], activeAttempt: nil, session: nil), .makeReady)
        XCTAssertNil(TicketNextAction.lead(task: Record(values: ["id": "t5", "readiness": "ready", "status_category": "queued"]), requests: [], activeAttempt: nil, session: nil))
    }

    /// The bar sits directly under the header; Make ready moved from the header into the bar.
    func testTheBarIsUnderTheStatusLine() throws {
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChecklistApp/Views")
        let detail = try String(contentsOf: views.appendingPathComponent("TaskDetailView.swift"), encoding: .utf8)
        XCTAssertTrue(detail.contains("                    header\n                    TicketNextActionBar(task: task)\n"))
        XCTAssertFalse(detail.contains(#"Button("Make ready")"#), "Make ready lives in the next-action bar")
        let review = try String(contentsOf: views.appendingPathComponent("ReviewDetailView.swift"), encoding: .utf8)
        XCTAssertTrue(review.contains("case .nextAction: NextActionBar { nextAction }"))
        XCTAssertFalse(review.contains("pendingHumanRequest {"), "The blocking request is decided once, first, by TicketNextAction")
    }
}
