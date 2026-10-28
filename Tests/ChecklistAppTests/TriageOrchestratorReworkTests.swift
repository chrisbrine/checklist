import XCTest
@testable import ChecklistApp

/// CL-126 rework after runner R42A item 5 (D1-D4) and reviewer candidate C1.
/// Synthetic records and a mock service only; no live store, installed app,
/// keychain or system setting.
@MainActor final class TriageOrchestratorReworkTests: XCTestCase {
    private let holder = "7b027ccb-42db-4275-9f01-42657a59bf89"
    private let orchestratorSession = "77e4c5e9-9f14-4739-a471-cb7f3a8ca151"

    // D1: an Orchestrator only note stays in the ticket's own list with its receipt.
    func testOrchestratorOnlyNoteStaysInTicketConversationWithReceipt() {
        let delivery: [String: Any] = ["id": "d3", "message_id": "n3", "recipient_role": "triage_orchestrator", "recipient_session_id": orchestratorSession, "state": "queued"]
        let rows = [
            Record(values: ["id": "n1", "task_id": "t", "created_at": "2026-10-27T23:14:48Z", "body": "1"]),
            Record(values: ["id": "n2", "task_id": "t", "audience": "holder", "created_at": "2026-10-27T23:14:58Z", "body": "2"]),
            Record(values: ["id": "n3", "task_id": "t", "audience": "orchestrator", "created_at": "2026-10-27T23:15:09Z", "body": "3", "deliveries": [delivery]]),
            Record(values: ["id": "other", "task_id": "u", "created_at": "2026-10-27T23:16:00Z"]),
        ]
        let shown = DeliveryLabels.correlateReplies(TaskDetailView.conversation(rows, taskID: "t"))
        XCTAssertEqual(shown.map(\.id), ["n3", "n2", "n1"])
        XCTAssertEqual(shown.first?.records("deliveries").first?.string("recipient_role"), "triage_orchestrator")
        XCTAssertEqual(DeliveryLabels.receipt("queued"), "Queued for agent pickup")
    }

    // D2: the detail state and counts come from the row's source.
    func testDetailStateMatchesRowSummaryOrMemberCounts() {
        let orchestration: [String: Any] = ["state": "active", "session_id": orchestratorSession, "provider": "claude", "actor_display": "Claude thread 77e4c5e9"]
        let full = Record(values: ["id": "T3", "kind": "triage", "orchestration": orchestration, "orchestrator": orchestration, "task_ids": ["a", "b", "c"], "orchestration_connection": "current"])
        XCTAssertEqual(TriageOrchestratorDisplay(full).stateLabel, "Idle", "R42A baseline: the full projection alone has no member counts")
        let summary = Record(values: ["id": "T3", "member_working_count": 3, "member_status_counts": [["name": "In progress", "category": "active", "count": 3]], "orchestration_connection": "current"])
        let merged = TriageOrchestratorDisplay.withMemberState(full, summary: summary, members: [])
        XCTAssertEqual(TriageOrchestratorDisplay(merged).summary, "Claude thread 77e4c5e9 · Working")
        XCTAssertEqual(TriageOrchestratorDisplay(merged).summary, TriageOrchestratorDisplay(Record(values: summary.values.merging(["orchestration": orchestration]) { $1 })).summary, "row and detail agree")
        XCTAssertEqual(TriageOrchestratorDisplay.statusCountsText(merged), "3 In progress")
        let members = [Record(values: ["id": "a", "status_category": "active"]), Record(values: ["id": "b", "status_category": "queued", "active_attempt_id": "x"]), Record(values: ["id": "c", "status_category": "queued"])]
        let fromMembers = TriageOrchestratorDisplay.withMemberState(full, summary: nil, members: members)
        XCTAssertEqual(fromMembers.integer("member_working_count", fallback: -1), 2)
        XCTAssertEqual(TriageOrchestratorDisplay(fromMembers).state, .working)
        XCTAssertEqual(TriageOrchestratorDisplay(TriageOrchestratorDisplay.withMemberState(full, summary: nil, members: [members[2]])).state, .idle)
        let other = Record(values: ["id": "other", "member_working_count": 4])
        XCTAssertEqual(TriageOrchestratorDisplay(TriageOrchestratorDisplay.withMemberState(full, summary: other, members: [])).state, .idle, "another Triage's summary is never used")
    }

    // D3: each combined-list row names its ticket key; "Triage note" only without a task.
    func testCombinedFeedRowsNameTheirTicketKey() async throws {
        let feed = TriageMessageFeed()
        let note: [String: Any] = ["id": "n3", "project_id": "p", "task_id": "t102", "created_at": "2026-10-27T23:15:09Z", "body": "3"]
        await feed.load(projectID: "p", triageID: "T3", members: [(id: "t102", key: "")]) { method, params in
            if method == "history_list" { return ["messages": params["task_id"] as? String == "t102" ? [note] : [], "has_more": false] }
            return ["deliveries": []]
        }
        let message = try XCTUnwrap(feed.messages.first)
        XCTAssertEqual(TriageMessageRow(message: message, ticketKey: feed.ticketKey(message)).subject, "Ticket note", "a ticket note is never labelled Triage note")
        feed.updateKeys([(id: "t102", key: "HEIR-102")])
        XCTAssertEqual(TriageMessageRow(message: message, ticketKey: feed.ticketKey(message)).subject, "HEIR-102")
        feed.updateKeys([(id: "t102", key: "OTHER")])
        XCTAssertEqual(feed.ticketKey(message), "HEIR-102", "a known key is kept")
        XCTAssertEqual(feed.ticketKey(Record(values: ["id": "x", "task_id": "t9", "task_key": "HEIR-109"])), "HEIR-109")
        XCTAssertEqual(TriageMessageRow(message: Record(values: ["id": "tn", "triage_id": "T3"]), ticketKey: "").subject, "Triage note")
    }

    // D4: the holder line names the holding conversation.
    func testHolderNamesTheHoldingConversation() {
        let enrolled = Record(values: ["id": holder, "provider": "claude", "native_conversation_title": "", "label": "Claude thread 7b027ccb"])
        XCTAssertEqual(ConversationName.label(session: enrolled, sessionID: holder), "Claude thread 7b027ccb", "an empty native title never hides the enrollment name")
        let raw = Record(values: ["id": holder, "provider": "claude", "native_conversation_title": "", "label": holder])
        XCTAssertNil(ConversationName.readable(session: raw))
        XCTAssertEqual(ConversationName.label(session: raw, sessionID: holder), "Claude · 7b027ccb")
        XCTAssertEqual(ConversationName.label(session: raw, sessionID: holder, actorDisplay: "Claude thread 7b027ccb"), "Claude thread 7b027ccb")
        XCTAssertEqual(ConversationName.label(session: Record(values: ["id": holder, "native_conversation_title": "Map pages"]), sessionID: holder), "Map pages")
        XCTAssertEqual(ConversationName.label(session: nil, sessionID: holder), "Agent · 7b027ccb")
    }

    // C1: a stored Orchestrator only choice never blocks Send without a picker.
    func testStoredOrchestratorOnlyChoiceFallsBackToBothWithoutOrchestrator() throws {
        XCTAssertEqual(NoteAudience.orchestrator.available(hasOrchestrator: false), .all)
        XCTAssertNil(NoteAudience.orchestrator.available(hasOrchestrator: false).unavailableReason(hasOrchestrator: false))
        XCTAssertEqual(NoteAudience.orchestrator.available(hasOrchestrator: true), .orchestrator)
        XCTAssertEqual(NoteAudience.holder.available(hasOrchestrator: false), .holder)
        let defaults = isolatedDefaults("P126bAudience").preferences
        let routing = TicketNoteRouting(preferences: defaults)
        routing.setAudience(.orchestrator, for: "t")
        XCTAssertEqual(routing.audience("t").available(hasOrchestrator: false), .all)
        XCTAssertEqual(routing.audience("t"), .orchestrator, "the stored choice returns with the orchestrator and its picker")
    }
}
