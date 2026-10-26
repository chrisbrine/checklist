import XCTest
import ChecklistIPC
@testable import ChecklistApp

/// CL-58: disabled actions say why, ignored actions show a notice, and service errors read as plain text.
@MainActor final class ViewStateTests: XCTestCase {
    struct Down: LocalizedError { var errorDescription: String? { "Connection refused" } }

    private func makeStore(_ transport: @escaping @MainActor @Sendable (String, [String: Any]) async throws -> [String: Any]) -> (ChecklistStore, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("viewstate-" + UUID().uuidString)
        let preferences = isolatedDefaults("ViewState").preferences
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: root), preferences: preferences, restorePendingCommand: false,
                                   desktopAlerts: DesktopAlertCoordinator(sink: ViewStateAlertSink()), requestTransport: transport)
        return (store, { try? FileManager.default.removeItem(at: root) })
    }

    func testAnActionIgnoredOfflineShowsANoticeAndNoAlert() {
        let (store, cleanup) = makeStore { _, _ in throw Down() }; defer { cleanup() }
        XCTAssertFalse(store.connected)
        store.run("task_edit", ["project_id": "p", "task_id": "t"])
        XCTAssertNil(store.error)
        XCTAssertEqual(store.notice, DisabledReasons.offline)
        XCTAssertTrue(store.noticeIsWarning)
        store.notice = "Ticket updated"
        XCTAssertFalse(store.noticeIsWarning, "A plain notice does not keep the warning style")
    }

    func testAServiceErrorWithoutAMessageReadsAsPlainText() async {
        let (store, cleanup) = makeStore { _, _ in ["error": ["code": "INVALID_INPUT", "details": ["field": "x"]]] }; defer { cleanup() }
        do { _ = try await store.request("task_list", ["project_id": "p"]); XCTFail("expected an error") }
        catch {
            let text = error.localizedDescription
            XCTAssertFalse(text.contains("[") || text.contains("details"), text)
            XCTAssertTrue(text.contains("could not complete this request"), text)
        }
    }

    func testCandidateChoicesHaveDistinctStates() {
        XCTAssertEqual(CandidateListState(loaded: false, loading: true, error: nil, offline: false, count: 0), .loading)
        XCTAssertEqual(CandidateListState(loaded: false, loading: false, error: "Could not load", offline: false, count: 0), .failed("Could not load"))
        XCTAssertEqual(CandidateListState(loaded: false, loading: false, error: "Could not load", offline: true, count: 0), .offline)
        XCTAssertEqual(CandidateListState(loaded: false, loading: false, error: nil, offline: true, count: 0), .offline)
        XCTAssertEqual(CandidateListState(loaded: true, loading: false, error: nil, offline: false, count: 0), .empty)
        XCTAssertEqual(CandidateListState(loaded: true, loading: false, error: nil, offline: true, count: 2), .choices)
    }

    /// A failed first read of Epic or Triage ticket choices shows its error and Retry, not an empty picker.
    func testAFailedCandidateReadIsVisible() async throws {
        let (store, cleanup) = makeStore { _, _ in throw ChecklistError("SERVICE_UNAVAILABLE", "Synthetic failed read") }; defer { cleanup() }
        store.detail = .group("g1")
        store.loadGroupCandidates(Record(values: ["id": "g1", "project_id": "p1", "kind": "triage"]), closed: false)
        for _ in 0..<300 where store.groupCandidateLoading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(store.groupCandidateLoading)
        XCTAssertTrue(store.groupCandidateRows.isEmpty)
        let error = try XCTUnwrap(store.groupCandidateError)
        XCTAssertEqual(CandidateListState(loaded: store.groupCandidatesLoaded, loading: false, error: error, offline: store.showsOfflineBanner,
                                          count: store.groupCandidateRows.count), .failed(error))
    }

    func testEveryDisabledControlNamesItsReason() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChecklistApp")
        var plain: [String] = []
        for file in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!.compactMap({ $0 as? URL }) where file.pathExtension == "swift" && file.lastPathComponent != "DisabledReason.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains(".disabled(") { plain.append(file.lastPathComponent) }
        }
        XCTAssertEqual(plain, [], "Use checklistDisabled with a reason")
        XCTAssertNil(DisabledReason(reason: nil).reason)
    }
}

@MainActor private final class ViewStateAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws {}
    func remove(_ identifiers: [String]) {}
}
