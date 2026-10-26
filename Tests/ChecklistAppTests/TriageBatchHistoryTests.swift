import ChecklistAXTestSupport
import XCTest
import SwiftUI
import ChecklistIPC
@testable import ChecklistApp

@MainActor final class TriageBatchHistoryTests: XCTestCase {
    private let preparedAt = "2026-10-20T09:00:00Z"
    private let discardedAt = "2026-10-21T10:00:00Z"
    private var prepared: [String: Any] {
        ["id": "prepared", "phase": "implementation", "member_count": 2, "triage_revision": 1,
         "lifecycle": "prepared", "created_at": preparedAt]
    }
    private var discarded: [String: Any] {
        var row = prepared
        row["id"] = "discarded"; row["lifecycle"] = "discarded"
        row["disposition"] = ["created_at": discardedAt, "reason": "Superseded unused plan"]
        return row
    }
    private func reply(_ rows: [[String: Any]]) -> [String: Any] {
        ["groups": [["id": "triage", "project_id": "project", "revision": 1, "batches": rows]]]
    }
    private func load(_ history: TriageBatchHistory, rows: [[String: Any]]) async {
        await history.load(projectID: "project", triageID: "triage") { method, params in
            XCTAssertEqual(method, "triage_list")
            XCTAssertEqual(params["project_id"] as? String, "project")
            XCTAssertEqual(params["triage_id"] as? String, "triage")
            XCTAssertEqual(params["fields"] as? [String], ["project_id", "batches"])
            return self.reply(rows)
        }
    }

    func testScopedReadKeepsEveryBatchIncludingReleasedDispatch() async {
        var claimed = prepared; claimed["id"] = "claimed"; claimed["lifecycle"] = "claimed"
        claimed["dispatch"] = ["created_at": discardedAt]
        var released = claimed; released["id"] = "released"; released["outcomes"] = [["state": "released"]]
        let history = TriageBatchHistory()
        await load(history, rows: [prepared, claimed, released, discarded])
        XCTAssertEqual(history.batches.map(\.id), ["prepared", "claimed", "released", "discarded"])
        XCTAssertEqual(history.batches.map { BatchLifecycleDisplay($0).label }, ["Prepared", "Claimed", "Claimed", "Discarded"])
        XCTAssertFalse(history.loading); XCTAssertNil(history.error)
    }

    func testReloadAndRecreatedDetailRetainDiscardReasonAndDate() async {
        let history = TriageBatchHistory()
        await load(history, rows: [prepared])
        XCTAssertEqual(BatchLifecycleDisplay(history.batches[0]).label, "Prepared")
        await load(history, rows: [discarded]) // batch change without a Triage revision change
        let reopened = TriageBatchHistory()
        await load(reopened, rows: [discarded]) // a new detail after app restart reads durable state
        for current in [history, reopened] {
            let display = BatchLifecycleDisplay(current.batches[0])
            XCTAssertEqual(display.label, "Discarded")
            XCTAssertEqual(display.reason, "Superseded unused plan")
            XCTAssertEqual(display.date, discardedAt)
        }
    }

    func testEmptyAndFailedReadsAreDistinctAndRetryRecovers() async {
        let history = TriageBatchHistory()
        await load(history, rows: [])
        XCTAssertTrue(history.batches.isEmpty); XCTAssertNil(history.error); XCTAssertFalse(history.loading)
        await load(history, rows: [prepared])
        await history.load(projectID: "project", triageID: "triage") { _, _ in
            throw ChecklistError("SERVICE_UNAVAILABLE", "Synthetic outage")
        }
        XCTAssertTrue(history.batches.isEmpty); XCTAssertNotNil(history.error); XCTAssertFalse(history.loading)
        await load(history, rows: [discarded])
        XCTAssertEqual(history.batches.count, 1); XCTAssertNil(history.error)
    }

    func testMissingMalformedOrWrongScopeResponseIsAFailureNotEmptyHistory() async {
        let invalid: [[String: Any]] = [[:], ["groups": []],
            ["groups": [["id": "triage", "project_id": "other", "batches": []]]],
            ["groups": [["id": "other", "project_id": "project", "batches": []]]],
            ["groups": [["id": "triage", "project_id": "project"]]],
            reply([["phase": "implementation"]]), reply([prepared, prepared])]
        for result in invalid {
            let history = TriageBatchHistory()
            await history.load(projectID: "project", triageID: "triage") { _, _ in result }
            XCTAssertNotNil(history.error); XCTAssertTrue(history.batches.isEmpty); XCTAssertFalse(history.loading)
        }
    }

    func testLateReadCannotOverwriteNewerDiscardedHistory() async {
        let history = TriageBatchHistory()
        var pending: CheckedContinuation<[String: Any], Never>?
        let began = expectation(description: "Old history read began")
        let old = Task {
            await history.load(projectID: "project", triageID: "triage") { _, _ in
                await withCheckedContinuation { pending = $0; began.fulfill() }
            }
        }
        await fulfillment(of: [began], timeout: 2)
        await load(history, rows: [discarded])
        pending?.resume(returning: fixtureReply(reply([prepared])))
        await old.value
        XCTAssertEqual(history.batches.map(\.id), ["discarded"])
        XCTAssertFalse(history.loading); XCTAssertNil(history.error)
    }

    func testCancelledReadCannotInstallHistory() async {
        let history = TriageBatchHistory()
        let read = Task {
            await history.load(projectID: "project", triageID: "triage") { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return self.reply([self.prepared])
            }
        }
        await read.value
        XCTAssertTrue(history.batches.isEmpty); XCTAssertFalse(history.loading); XCTAssertNil(history.error)
    }

    func testFixedBatchesSectionRendersDiscardedReadAndPreparedReadTruthfully() async throws {
        let history = TriageBatchHistory()
        await load(history, rows: [discarded, prepared])
        let text = try await sectionText(history)
        XCTAssertTrue(text.contains("Fixed batches"), text)
        XCTAssertTrue(text.contains("Discarded " + relativeTime(discardedAt)), text)
        XCTAssertTrue(text.contains("Superseded unused plan"), text)
        XCTAssertTrue(text.contains("Prepared " + relativeTime(preparedAt)), text)
        XCTAssertFalse(text.contains("Claimed"), text); XCTAssertFalse(text.contains("Started"), text)
    }

    func testFixedBatchesSectionRendersEmptyAndFailureStates() async throws {
        let history = TriageBatchHistory()
        await load(history, rows: [])
        let empty = try await sectionText(history)
        XCTAssertTrue(empty.contains("No fixed batches for this Triage."), empty)
        await history.load(projectID: "project", triageID: "triage") { _, _ in throw ChecklistError("SERVICE_UNAVAILABLE", "Synthetic outage") }
        let failure = try await sectionText(history)
        XCTAssertTrue(failure.contains("Fixed batches could not be loaded."), failure)
        XCTAssertTrue(failure.contains("Retry fixed batches"), failure)
        XCTAssertFalse(failure.contains("No fixed batches"), failure)
    }

    func testDetailLoadsMissingBatchSummaryAndRefreshesAfterServiceChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyntheticTriageBatch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var rows = [prepared]
        var historyReads = 0
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: root),
                                   preferences: isolatedDefaults("TriageBatchHistory").preferences,
                                   restorePendingCommand: false,
                                   desktopAlerts: DesktopAlertCoordinator(sink: TriageBatchNoAlerts()),
                                   requestTransport: { method, params in
            if method == "triage_list" {
                historyReads += 1
                XCTAssertEqual(params["triage_id"] as? String, "triage")
                return self.reply(rows)
            }
            // Other detail pages are outside this fixture, with no live transport.
            throw CancellationError()
        })
        store.connected = true; store.page = .tasks; store.detail = .group("triage")
        let summary = Record(values: ["id": "triage", "project_id": "project", "kind": "triage", "name": "Synthetic handling", "phase": "implementation", "revision": 1])
        XCTAssertNil(summary.values["batches"])
        let text = try await hostedText(TriageDetailView(triage: summary).environmentObject(store)) { host in
            XCTAssertTrue(self.accessibilityText(host).contains("Prepared " + relativeTime(self.preparedAt)))
            rows = [self.discarded]
            // batch_discard does not advance the Triage revision. The existing
            // authenticated change signal must still reload its fixed history.
            await store.applyChangeCoverage(["coverage": ["schema_version": 2, "complete": true, "reset": false,
                "changes": [["project_id": "project", "families": ["groups"]]]]])
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThanOrEqual(historyReads, 2)
        XCTAssertTrue(text.contains("Discarded " + relativeTime(discardedAt)), text)
        XCTAssertTrue(text.contains("Superseded unused plan"), text)
        XCTAssertFalse(text.contains("Prepared " + relativeTime(preparedAt)), text)
    }

    private func sectionText(_ history: TriageBatchHistory) async throws -> String {
        try await hostedText(TriageFixedBatchesSection(history: history, retry: {}).padding())
    }

    private func hostedText<Content: View>(_ content: Content,
        afterMount: (NSHostingView<AnyView>) async throws -> Void = { _ in }) async throws -> String {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let wasEnhanced = ChecklistTestAXAttributeValue(NSApplication.shared, enhanced) ?? false
        ChecklistTestAXSetValue(NSApplication.shared, true, enhanced)
        defer { ChecklistTestAXSetValue(NSApplication.shared, wasEnhanced, enhanced) }
        let host = NSHostingView(rootView: AnyView(content.accessibilityElement(children: .contain)))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic Checklist fixed-batch regression (offscreen)"
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        try await afterMount(host)
        host.layoutSubtreeIfNeeded()
        return accessibilityText(host)
    }

    private func accessibilityText(_ host: NSView) -> String {
        func attribute(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        func nodes(_ object: NSObject, depth: Int = 0) -> [NSObject] {
            guard depth < 30 else { return [] }
            return [object] + (attribute(object, "accessibilityChildren") as? [NSObject] ?? []).flatMap { nodes($0, depth: depth + 1) }
        }
        return nodes(host).flatMap { object in
            ["accessibilityLabel", "accessibilityValue"].compactMap { attribute(object, $0) as? String }
        }.joined(separator: " | ")
    }
}

@MainActor private final class TriageBatchNoAlerts: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("Unexpected notification") }
    func remove(_ identifiers: [String]) {}
}
