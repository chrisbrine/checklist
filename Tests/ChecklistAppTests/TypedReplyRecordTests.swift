import XCTest
import ChecklistIPC
@testable import ChecklistApp

@MainActor final class TypedReplyRecordTests: XCTestCase {
    func testRequiredIdentityRejectsMalformedReplies() {
        let malformed: [[String: Any]] = [[:], ["id": NSNull()], ["id": true], ["id": 1], ["id": ""]]
        for values in malformed {
            XCTAssertThrowsError(try TypedReplyRecord(values)) { error in
                XCTAssertEqual((error as? ChecklistError)?.code, "INVALID_RESPONSE")
            }
        }
    }

    func testIdentityProjectionPreservesOpenFieldsAndExactBytes() throws {
        let reply = try TypedReplyRecord(["id": " e\u{301} ", "future": ["state": "unknown"], "nullable": NSNull()])
        XCTAssertEqual(Array(reply.id.utf8), Array(" e\u{301} ".utf8))
        XCTAssertEqual(reply.record.object("future")["state"] as? String, "unknown")
        XCTAssertTrue(reply.record.values["nullable"] is NSNull)
    }

    func testMalformedCreateReplyIsVisibleWithoutClearingDraftOrSelection() async throws {
        let defaults = isolatedDefaults("TypedReply")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var pending: [String: String] = [:]
        let store = ChecklistStore(
            draftJournal: LocalDraftJournal(directory: directory), preferences: defaults.preferences,
            restorePendingCommand: false,
            desktopAlerts: DesktopAlertCoordinator(sink: TypedReplyNoAlerts()),
            requestTransport: { method, _ in
                if method == "media_navigation" { return ["data": ["types": []]] }
                return ["data": ["id": NSNull()]]
            },
            navigationMemory: DetailItemNavigationMemory(),
            pendingCommandPersistence: PendingCommandPersistence(
                read: { pending[$0] }, save: { pending[$1] = $0 }, remove: { pending.removeValue(forKey: $0) }))
        store.data = ["service": ["store_incarnation": "synthetic-typed-reply"]]
        store.connected = true
        store.projectID = "synthetic-project"
        let model = store.mediaReview
        await model.connect(store: store)
        model.roundID = "original-round"
        model.selectedID = "original-item"
        model.roundState = "open"
        for createRound in [true, false] {
            model.error = nil
            var cleared = false
            if createRound {
                model.createRound(title: "Retained title") { cleared = true }
            } else {
                model.createItem(title: "Retained title") { cleared = true }
            }
            for _ in 0..<200 {
                if model.error != nil && !store.busy { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertNotNil(model.error)
            XCTAssertFalse(cleared)
            XCTAssertEqual(model.roundID, "original-round")
            XCTAssertEqual(model.selectedID, "original-item")
            XCTAssertEqual(model.roundState, "open")
        }
    }
}

@MainActor private final class TypedReplyNoAlerts: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws {}
    func remove(_ identifiers: [String]) {}
}
