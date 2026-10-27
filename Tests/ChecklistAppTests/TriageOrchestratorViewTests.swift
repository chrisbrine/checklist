import XCTest
import SwiftUI
import ChecklistIPC
@testable import ChecklistApp

/// CL-126: synthetic records and a mock service only; no live store, installed
/// app window, keychain or system setting.
@MainActor final class TriageOrchestratorViewTests: XCTestCase {
    private let codexSession = "1a2b3c4d-0000-4000-8000-000000000126"
    private func triage(_ extra: [String: Any]) -> Record {
        var values: [String: Any] = ["id": "triage", "project_id": "p", "key": "CL-T9", "name": "Synthetic Triage", "kind": "triage", "member_count": 3]
        for (key, value) in extra { values[key] = value }
        return Record(values: values)
    }
    private func orchestration(_ state: String = "active", display: String = "") -> [String: Any] {
        ["state": state, "session_id": codexSession, "provider": "codex", "actor_display": display]
    }

    // Item 0: orchestrator, truthful state, counts; a plan shows as Planned.
    func testRowStateIsTruthfulForEveryOrchestration() {
        let working = TriageOrchestratorDisplay(triage(["orchestration": orchestration(), "orchestration_connection": "current", "member_working_count": 1]))
        XCTAssertEqual(working.summary, "Codex · 1a2b3c4d · Working")
        XCTAssertEqual(working.sessionID, codexSession)
        XCTAssertEqual(TriageOrchestratorDisplay(triage(["orchestration": orchestration(), "orchestration_connection": "current", "member_working_count": 0])).state, .idle)
        XCTAssertEqual(TriageOrchestratorDisplay(triage(["orchestration": orchestration(), "orchestration_connection": "recovery_required", "member_working_count": 2])).stateLabel, "Needs recovery")
        XCTAssertEqual(TriageOrchestratorDisplay(triage(["orchestration": orchestration(display: "Pass 7 orchestrator")])).orchestrator, "Pass 7 orchestrator")
        XCTAssertEqual(TriageOrchestratorDisplay(triage(["orchestration": orchestration(display: codexSession)])).orchestrator, "Codex · 1a2b3c4d", "A raw ID is never shown as a name")
        let plan = TriageOrchestratorDisplay(triage([:]))
        XCTAssertEqual(plan.summary, "Planned"); XCTAssertNil(plan.orchestrator); XCTAssertEqual(plan.sessionID, "")
        XCTAssertEqual(TriageOrchestratorDisplay(triage(["orchestration": orchestration("finished")])).summary, "Planned", "Finish with tickets leaves a plan")
        XCTAssertEqual(TriageOrchestratorDisplay(triage(["orchestration": orchestration("finished"), "member_count": 0, "archived": true])).summary, "Finished")
        // The full triage_list projection: orchestrator object and category counts.
        let full = triage(["orchestrator": ["session_id": codexSession, "provider": "claude", "actor_display": NSNull()], "orchestration": orchestration(),
                           "orchestration_connection": "current", "member_counts_by_status": ["active": 1, "queued": 2, "review": 0]])
        XCTAssertEqual(TriageOrchestratorDisplay(full).summary, "Claude · 1a2b3c4d · Working")
        XCTAssertEqual(TriageOrchestratorDisplay.statusCountsText(full), "2 Queued · 1 In progress")
        let named = triage(["member_status_counts": [["name": "Review", "category": "review", "count": 1], ["name": "Queued", "category": "queued", "count": 2], ["name": "", "category": "active", "count": 1]]])
        XCTAssertEqual(TriageOrchestratorDisplay.statusCountsText(named), "2 Queued · 1 In progress · 1 Review")
        XCTAssertEqual(TriageOrchestratorDisplay(named).state, .planned)
    }

    func testThereIsNoOrchestratorsTab() {
        XCTAssertNil(Page(rawValue: "orchestrators"))
        XCTAssertFalse(Page.allCases.map(\.title).contains { $0.localizedCaseInsensitiveContains("orchestrator") })
    }

    func testTriageRowAccessibilityLabelNamesOrchestratorStateAndCounts() async throws {
        let (store, root, preferences) = makeStore("TriageRowAX")
        _ = preferences
        let summary = triage(["orchestration": orchestration(), "orchestration_connection": "current", "member_working_count": 1, "task_ids": ["a", "b", "c"],
                              "member_status_counts": [["name": "In progress", "category": "active", "count": 1], ["name": "Queued", "category": "queued", "count": 2]]])
        let section = InlineTriageSection(triage: summary, allMembers: [], visibleMembers: [], matchesGroupSearch: false)
        let (host, window) = hostOffscreen(InlineTriageRow(section: section, expanded: .constant(false), filtered: false).environmentObject(store), height: 120)
        defer { store.stopWindowReads(); window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
        try await AXProbe.until { draw(host, window); return AXProbe.text(host).contains("1a2b3c4d") }
        let row = try XCTUnwrap(AXProbe.nodes(host).first { AXProbe.attribute($0, "accessibilityIdentifier") as? String == "triageRow-triage" })
        let label = AXProbe.attribute(row, "accessibilityLabel") as? String ?? ""
        for fact in ["CL-T9", "collapsed Triage", "Codex · 1a2b3c4d · Working", "3 tickets", "2 Queued", "1 In progress"] { XCTAssertTrue(label.contains(fact), "\(fact) in \(label)") }
        XCTAssertFalse(AXProbe.text(host).contains("Choose phase"), "A Triage has no phase")
    }

    // Item 1: combined, paged message list, oldest first, with copy labels.
    func testCombinedFeedMergesTriageAndTicketNotesOldestFirstAcrossPages() async {
        let feed = TriageMessageFeed()
        var calls: [[String: Any]] = []
        func note(_ id: String, _ time: String, task: String? = nil, triage: String? = nil, deliveries: [[String: Any]] = []) -> [String: Any] {
            var value: [String: Any] = ["id": id, "created_at": time, "body": "Body " + id, "deliveries": deliveries]
            if let task { value["task_id"] = task }; if let triage { value["triage_id"] = triage }
            return value
        }
        let copy = ["id": "d2", "recipient_role": "triage_orchestrator", "recipient_session_id": codexSession, "state": "queued"]
        let holder = ["id": "d1", "recipient_role": "handler", "recipient_session_id": "9f8e7d6c-0000-4000-8000-000000000001", "recipient_provider": "claude", "state": "acknowledged"]
        let request: TriageMessageFeed.Request = { method, params in
            calls.append(params); XCTAssertEqual(method, "history_list")
            if params["triage_id"] as? String == "triage" { return ["messages": [note("t1", "2026-10-27T10:00:02Z", triage: "triage")], "events": [], "has_more": false] }
            if params["task_id"] as? String == "a" {
                if params["cursor"] == nil {
                    return ["messages": [note("a1", "2026-10-27T10:00:01Z", task: "a", deliveries: [holder, copy])],
                            "events": [["occurred_at": "2026-10-27T10:00:01Z"]], "has_more": true, "next_cursor": "a-2"]
                }
                return ["messages": [note("a2", "2026-10-27T10:00:05Z", task: "a"), note("t1", "2026-10-27T10:00:02Z", triage: "triage")], "events": [], "has_more": false]
            }
            return ["messages": [note("b1", "2026-10-27T10:00:03Z", task: "b")], "events": [], "has_more": false]
        }
        await feed.load(projectID: "p", triageID: "triage", members: [(id: "a", key: "S-1"), (id: "b", key: "S-2")], request: request)
        XCTAssertEqual(feed.messages.map(\.id), ["a1"], "A later message waits until the source that can hold older ones is read")
        XCTAssertTrue(feed.hasMore)
        XCTAssertEqual(feed.ticketKey(feed.messages[0]), "S-1")
        XCTAssertEqual(TriageCopyLabel.text(feed.messages[0], ticketKey: "S-1"), "Also sent to Claude · 9f8e7d6c, which holds S-1.")
        await feed.loadMore(request: request)
        XCTAssertEqual(feed.messages.map(\.id), ["a1", "t1", "b1", "a2"], "One combined list, oldest first, without duplicates")
        XCTAssertFalse(feed.hasMore)
        XCTAssertEqual(feed.ticketKey(feed.messages[1]), "", "A Triage note names no ticket")
        XCTAssertEqual(calls.last?["cursor"] as? String, "a-2")
        XCTAssertEqual(calls.filter { $0["cursor"] != nil }.count, 1, "Load more reads only the sources with more pages")
        var labelled = Record(values: note("x", "2026-10-27T10:00:09Z", task: "a", deliveries: [["id": "c", "recipient_role": "triage_orchestrator", "label": "Also sent to Codex · 1a2b3c4d, which holds S-1."]]))
        XCTAssertEqual(TriageCopyLabel.text(labelled, ticketKey: "S-1"), "Also sent to Codex · 1a2b3c4d, which holds S-1.", "The service label is shown as sent")
        labelled = Record(values: note("y", "2026-10-27T10:00:09Z", task: "a", deliveries: [holder]))
        XCTAssertNil(TriageCopyLabel.text(labelled, ticketKey: "S-1"), "A holder-only note has no orchestrator copy")
    }

    func testFeedFailureIsPlainAndRetryable() async {
        let feed = TriageMessageFeed()
        await feed.load(projectID: "p", triageID: "triage", members: []) { _, _ in throw ChecklistError("UNAVAILABLE", "Service unavailable.") }
        XCTAssertTrue(feed.error?.hasPrefix("Messages could not be loaded.") == true)
        XCTAssertTrue(feed.messages.isEmpty); XCTAssertFalse(feed.loading)
    }

    func testTriageNoteDraftStaysBoundAcrossSwitchingReopenAndReconnect() {
        let defaults = isolatedDefaults("TriageNoteDraft").preferences
        let drafts = TriageNoteDrafts(preferences: defaults)
        drafts.save("triage", body: "Hold the merge", storeIncarnation: "store-1", projectID: "p", orchestrator: codexSession)
        drafts.save("other", body: "Other Triage", storeIncarnation: "store-1", projectID: "p", orchestrator: "")
        drafts.save("triage", body: "Hold the merge until CL-2 lands", storeIncarnation: "store-1", projectID: "p", orchestrator: "newer")
        let reopened = TriageNoteDrafts(preferences: defaults)
        XCTAssertEqual(reopened.draft("triage")?.body, "Hold the merge until CL-2 lands")
        XCTAssertEqual(reopened.draft("triage")?.orchestratorSessionID, codexSession, "Typing never rebinds the destination")
        XCTAssertEqual(reopened.draft("other")?.body, "Other Triage")
        XCTAssertFalse(reopened.needsConfirmation("triage", storeIncarnation: "store-1", projectID: "p", orchestrator: codexSession), "A reconnect to the same store keeps the draft sendable")
        XCTAssertTrue(reopened.needsConfirmation("triage", storeIncarnation: "store-1", projectID: "p", orchestrator: "takeover-session"))
        XCTAssertTrue(reopened.needsConfirmation("triage", storeIncarnation: "store-2", projectID: "p", orchestrator: codexSession))
        reopened.confirm("triage", storeIncarnation: "store-1", projectID: "p", orchestrator: "takeover-session")
        XCTAssertFalse(reopened.needsConfirmation("triage", storeIncarnation: "store-1", projectID: "p", orchestrator: "takeover-session"))
        XCTAssertEqual(reopened.draft("triage")?.body, "Hold the merge until CL-2 lands", "Confirming keeps the draft")
        reopened.save("triage", body: "", storeIncarnation: "store-1", projectID: "p", orchestrator: "")
        XCTAssertNil(reopened.draft("triage"))
    }

    func testTriageComposerLabelsAndKeyboardShortcut() async throws {
        let (store, root, preferences) = makeStore("TriageComposerAX")
        TriageNoteDrafts(preferences: preferences).save("triage", body: "Saved draft text", storeIncarnation: store.storeIncarnation, projectID: "p", orchestrator: codexSession)
        let summary = triage(["orchestration": orchestration(), "orchestration_connection": "current"])
        let composer = TriageNoteComposer(triage: summary, display: TriageOrchestratorDisplay(summary), sent: {}).environmentObject(store)
        let (host, window) = hostOffscreen(composer, height: 260)
        defer { store.stopWindowReads(); window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
        try await AXProbe.until { draw(host, window); return AXProbe.button(host, "Send Triage note") != nil && AXProbe.text(host).contains("1a2b3c4d") }
        XCTAssertTrue(AXProbe.text(host).contains("Saved draft text"), "The bound draft is restored on reopen")
        let text = AXProbe.text(host)
        XCTAssertTrue(text.contains("Codex · 1a2b3c4d"), text)
        XCTAssertTrue(AXProbe.nodes(host).contains { AXProbe.attribute($0, "accessibilityLabel") as? String == "Note to the orchestrator" })
        let send = try XCTUnwrap(AXProbe.button(host, "Send Triage note"))
        XCTAssertTrue((AXProbe.attribute(send, "accessibilityHelp") as? String ?? "").contains("Checklist is offline") || (AXProbe.attribute(send, "accessibilityHelp") as? String ?? "").contains("⌘Return") || !store.connected,
                      "The send control names its shortcut or its disabled reason")
        XCTAssertFalse(text.contains("Confirm new destination"), "The bound orchestrator is current")
    }

    // Item 2: audience choice, owner directions, changed destination.
    func testAudienceChoiceDefaultsToBothAndOwnerDirectionsCannotNarrow() {
        XCTAssertEqual(NoteAudience.allCases.map(\.label), ["Both", "Holder only", "Orchestrator only"])
        XCTAssertNil(NoteAudience.all.parameter, "Both is the service default")
        XCTAssertEqual(NoteAudience.holder.parameter, "holder"); XCTAssertEqual(NoteAudience.orchestrator.parameter, "orchestrator")
        XCTAssertEqual(NoteAudience.holder.effective(ownerDirection: true), .all)
        XCTAssertEqual(NoteAudience.orchestrator.effective(ownerDirection: false), .orchestrator)
        XCTAssertTrue(NoteAudience.alwaysBothReason.hasPrefix("Owner directions always go to both"))
        XCTAssertNotNil(NoteAudience.orchestrator.unavailableReason(hasOrchestrator: false))
        XCTAssertNil(NoteAudience.holder.unavailableReason(hasOrchestrator: false))
        XCTAssertEqual(NoteAudience.all.destination(holder: "Claude · Worker", orchestrator: "Codex · 1a2b3c4d"), "Claude · Worker and Codex · 1a2b3c4d")
        XCTAssertEqual(NoteAudience.orchestrator.destination(holder: "Claude · Worker", orchestrator: "Codex · 1a2b3c4d"), "Codex · 1a2b3c4d")
        XCTAssertEqual(NoteAudience.orchestrator.destination(holder: "Next pickup", orchestrator: nil), "Next pickup")
    }

    func testTicketDraftKeepsTextAndAsksWhenOrchestratorChanges() {
        let defaults = isolatedDefaults("TicketNoteRouting").preferences
        let routing = TicketNoteRouting(preferences: defaults)
        XCTAssertEqual(routing.audience("task"), .all)
        routing.setAudience(.holder, for: "task")
        routing.bind("task", orchestrator: codexSession)
        let reopened = TicketNoteRouting(preferences: defaults)
        XCTAssertEqual(reopened.audience("task"), .holder, "The choice survives close and reopen")
        XCTAssertFalse(reopened.orchestratorChanged("task", current: codexSession, hasDraft: true))
        XCTAssertTrue(reopened.orchestratorChanged("task", current: "other-orchestrator", hasDraft: true))
        XCTAssertFalse(reopened.orchestratorChanged("task", current: "other-orchestrator", hasDraft: false), "No draft, nothing to confirm")
        reopened.bind("task", orchestrator: "other-orchestrator")
        XCTAssertFalse(reopened.orchestratorChanged("task", current: "other-orchestrator", hasDraft: true), "Confirming binds the new destination")
        reopened.setAudience(.all, for: "task"); XCTAssertEqual(reopened.audience("task"), .all)
    }

    func testAudiencePickerAccessibility() async throws {
        let (store, root, _) = makeStore("AudiencePickerAX")
        let picker = NoteAudiencePicker(selection: .constant(.all), orchestrator: "Codex · 1a2b3c4d").environmentObject(store)
        let (host, window) = hostOffscreen(picker, height: 120)
        defer { store.stopWindowReads(); window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
        try await AXProbe.until { draw(host, window); return AXProbe.text(host).contains("Owner directions always go to both") }
        let text = AXProbe.text(host)
        for fact in ["Both", "Holder only", "Orchestrator only", "Owner directions always go to both"] { XCTAssertTrue(text.contains(fact), fact) }
        XCTAssertTrue(AXProbe.nodes(host).contains { AXProbe.attribute($0, "accessibilityLabel") as? String == "Send note to" })
    }

    // Item 3: receipt texts are truthful; a missing reply is not failure, acknowledgment or completion.
    func testReceiptTextsAreDistinctAndTruthful() {
        let states = ["saved_for_pickup", "queued", "acknowledged", "replied", "fenced"]
        let labels = states.map(DeliveryLabels.receipt)
        XCTAssertEqual(Set(labels).count, states.count, "\(labels)")
        XCTAssertEqual(DeliveryLabels.receipt("replied"), "Replied")
        for state in ["saved_for_pickup", "queued", "acknowledged"] {
            let label = DeliveryLabels.receipt(delivery: Record(values: ["state": state]))
            for word in ["fail", "Replied", "Done", "complete"] { XCTAssertFalse(label.localizedCaseInsensitiveContains(word), "\(state): \(label)") }
        }
        XCTAssertFalse(DeliveryLabels.receipt(delivery: Record(values: ["state": "queued"])).contains("Acknowledged"), "No reply never reads as acknowledgment")
        XCTAssertEqual(DeliveryLabels.receipt(delivery: Record(values: ["state": "acknowledged", "reply_message_id": "reply"])), "Replied")
        XCTAssertEqual(DeliveryLabels.receipt(delivery: Record(values: ["state": "fenced"])), "Not delivered: this conversation was disconnected")
    }

    // M42 wire check: history_list rows carry no receipts (Communication.history), so the feed
    // reads message_delivery_list per shown note with the service's own result shape
    // (Communication.messageDeliveryList fields) and correlates replies by reply_to.
    func testFeedReadsReceiptsWithServiceDeliveryShapesAndCorrelatesReplies() async {
        let feed = TriageMessageFeed()
        let holderSession = "9f8e7d6c-0000-4000-8000-000000000001"
        var receiptCalls: [[String: Any]] = []
        // history_list message rows as stored by message_send: no deliveries, no delivery_status.
        let triageNote: [String: Any] = ["id": "n1", "project_id": "p", "triage_id": "triage", "body": "Hold the merge", "author_session_id": "sender", "created_at": "2026-10-27T10:00:01Z"]
        let ticketNote: [String: Any] = ["id": "n2", "project_id": "p", "task_id": "a", "triage_id": "triage", "audience": "all", "body": "Status?", "author_session_id": "sender", "created_at": "2026-10-27T10:00:02Z"]
        let reply: [String: Any] = ["id": "n3", "project_id": "p", "task_id": "a", "reply_to": "n2", "body": "Merged", "author_session_id": codexSession, "created_at": "2026-10-27T10:00:03Z"]
        func delivery(_ id: String, _ message: String, _ session: String, _ role: String, _ state: String, label: String? = nil) -> [String: Any] {
            var value: [String: Any] = ["id": id, "message_id": message, "recipient_session_id": session, "recipient_authorization_generation": "g1", "recipient_role": role,
                                        "push_state": "unavailable", "created_at": "2026-10-27T10:00:04Z", "state": state]
            if let label { value["label"] = label }
            return value
        }
        let request: TriageMessageFeed.Request = { method, params in
            if method == "history_list" {
                if params["triage_id"] as? String == "triage" { return ["messages": [triageNote], "events": [], "has_more": false] }
                return ["messages": [ticketNote, reply], "events": [], "has_more": false]
            }
            XCTAssertEqual(method, "message_delivery_list"); receiptCalls.append(params)
            switch params["message_id"] as? String {
            case "n1": return ["message_id": "n1", "triage_id": "triage", "deliveries": [delivery("d1", "n1", self.codexSession, "triage_orchestrator", "queued", label: "Triage note for Synthetic Triage.")]]
            case "n2": return ["message_id": "n2", "task_id": "a", "deliveries": [delivery("d2", "n2", holderSession, "handler", "acknowledged"),
                                delivery("d3", "n2", self.codexSession, "triage_orchestrator", "queued", label: "Also sent to Codex · 1a2b3c4d, which holds S-1.")]]
            default: return ["message_id": "n3", "task_id": "a", "deliveries": [], "delivery_status": "saved_for_pickup", "created_at": "2026-10-27T10:00:03Z"]
            }
        }
        await feed.load(projectID: "p", triageID: "triage", members: [(id: "a", key: "S-1")], request: request)
        XCTAssertEqual(feed.messages.map(\.id), ["n1", "n2", "n3"])
        XCTAssertEqual(receiptCalls.count, 3, "One receipt read per shown note")
        XCTAssertEqual(receiptCalls.first { $0["message_id"] as? String == "n1" }?["triage_id"] as? String, "triage", "A Triage note reads receipts by triage_id")
        XCTAssertNil(receiptCalls.first { $0["message_id"] as? String == "n1" }?["task_id"])
        XCTAssertEqual(receiptCalls.first { $0["message_id"] as? String == "n2" }?["task_id"] as? String, "a", "A ticket note reads receipts by task_id")
        let n1 = feed.messages[0], n2 = feed.messages[1], n3 = feed.messages[2]
        XCTAssertEqual(n1.records("deliveries").map { TriageMessageRow.recipient($0) + ": " + DeliveryLabels.receipt(delivery: $0) }, ["Orchestrator · Agent · 1a2b3c4d: Queued for agent pickup"], "message_delivery_list carries no provider or display name")
        XCTAssertEqual(TriageCopyLabel.text(n2, ticketKey: "S-1"), "Also sent to Codex · 1a2b3c4d, which holds S-1.")
        XCTAssertEqual(n2.records("deliveries").map { DeliveryLabels.receipt(delivery: $0) }, ["Acknowledged", "Replied"], "Only the recipient that wrote the reply reads Replied")
        XCTAssertNil(TriageMessageRow.noteReceipt(n2))
        XCTAssertEqual(TriageMessageRow.noteReceipt(n3), "Saved for pickup")
        XCTAssertNil(TriageMessageRow.noteReceipt(Record(values: triageNote)), "A note whose receipts are still loading shows no guessed state")
        // A failed receipt read is shown as unavailable, never as saved or queued.
        let failing = TriageMessageFeed()
        await failing.load(projectID: "p", triageID: "triage", members: []) { method, _ in
            if method == "history_list" { return ["messages": [triageNote], "events": [], "has_more": false] }
            throw ChecklistError("UNAVAILABLE", "Service unavailable.")
        }
        XCTAssertNil(failing.error)
        XCTAssertEqual(failing.messages.first.flatMap(TriageMessageRow.noteReceipt), "Delivery status unavailable")
    }

    // M42 wire check: the service refuses audience with mention_target, so a tagged note never narrows.
    func testTaggedNoteNeverSendsNarrowingAudience() {
        for audience in NoteAudience.allCases {
            XCTAssertNil(audience.effective(ownerDirection: false, mentionPlan: true).parameter, "\(audience)")
        }
        XCTAssertEqual(NoteAudience.holder.effective(ownerDirection: false).parameter, "holder")
        XCTAssertEqual(NoteAudience.orchestrator.effective(ownerDirection: false).parameter, "orchestrator")
        let messages = [Record(values: ["id": "m", "deliveries": [["id": "d", "recipient_session_id": "s", "state": "queued"]]]),
                        Record(values: ["id": "r", "reply_to": "m", "author_session_id": "other"])]
        XCTAssertEqual(DeliveryLabels.correlateReplies(messages)[0].records("deliveries").map { DeliveryLabels.receipt(delivery: $0) }, ["Queued for agent pickup"],
                       "A reply by another session is not this recipient's reply")
    }

    // MARK: helpers
    private func makeStore(_ label: String) -> (ChecklistStore, URL, UserDefaults) {
        _ = NSApplication.shared
        let restoreAX = AXProbe.enableEnhancedUserInterface()
        addTeardownBlock { @MainActor in restoreAX() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preferences = isolatedDefaults(label).preferences
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: root), preferences: preferences,
            restorePendingCommand: false, desktopAlerts: DesktopAlertCoordinator(sink: TriageAXAlertSink()),
            requestTransport: { _, _ in throw CancellationError() })
        store.data["projects"] = [["id": "p", "name": "Synthetic project"]]
        return (store, root, preferences)
    }
    private func hostOffscreen<V: View>(_ view: V, height: CGFloat) -> (NSHostingView<V>, NSWindow) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: height), styleMask: [], backing: .buffered, defer: false)
        window.title = "Synthetic Checklist Triage accessibility check (offscreen)"
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        return (host, window)
    }
    private func draw(_ host: NSView, _ window: NSWindow) { host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); window.displayIfNeeded() }
}

@MainActor private final class TriageAXAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("No alerts in the Triage fixture") }
    func remove(_ identifiers: [String]) {}
}
