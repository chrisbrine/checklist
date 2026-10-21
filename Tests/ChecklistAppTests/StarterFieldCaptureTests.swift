import XCTest
import ChecklistIPC
@testable import ChecklistApp

/// CL-68: Bug and Playtest capture offers optional fields; title-only capture still works.
@MainActor final class StarterFieldCaptureTests: XCTestCase {
    func testStarterFieldsBelongToTheirKindAndStayOptional() {
        XCTAssertEqual(StarterFields.fields(for: "bug").map(\.key), ["reproduction", "expected", "actual"])
        XCTAssertEqual(StarterFields.fields(for: "playtest").map(\.key), ["build", "platform", "clip"])
        XCTAssertTrue(StarterFields.fields(for: "work").isEmpty)
        let values = ["reproduction": "Press jump", "expected": " ", "build": "12"]
        XCTAssertEqual(StarterFields.parameters(values, kind: "bug"), ["reproduction": "Press jump"], "Empty fields and other kinds' fields are not sent")
        XCTAssertEqual(StarterFields.parameters(values, kind: "playtest"), ["build": "12"])
        XCTAssertEqual(StarterFields.display(["actual": "Falls", "reproduction": "Jump"], kind: "bug").map(\.label), ["Steps to reproduce", "Actual result"])
    }

    func testCaptureDraftsKeepTheFieldsAndOlderDraftsStillLoad() throws {
        let old = #"{"projectID":"p","title":"t","brief":"","kind":"bug","epicID":"","storeIncarnation":"s"}"#
        let decoded = try JSONDecoder().decode(CaptureDraft.self, from: Data(old.utf8))
        XCTAssertNil(decoded.starterFields, "A draft saved before CL-68 still loads")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("starter-" + UUID().uuidString)
        let preferences = isolatedDefaults("Starter").preferences
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: root), preferences: preferences, restorePendingCommand: false,
                                   desktopAlerts: DesktopAlertCoordinator(sink: StarterAlertSink()), requestTransport: { _, _ in throw ChecklistError("SERVICE_UNAVAILABLE", "offline") })
        store.saveCapture(CaptureDraft(projectID: "p1", title: "Boss is too hard", brief: "", kind: "playtest", epicID: "", storeIncarnation: store.storeIncarnation,
                                       starterFields: ["build": "0.4.2", "platform": "macOS", "reproduction": "not for playtest"]))
        let params = try store.captureCreateParameters(projectID: "p1")
        XCTAssertEqual(params["starter_fields"] as? [String: String], ["build": "0.4.2", "platform": "macOS"])
        store.saveCapture(CaptureDraft(projectID: "p2", title: "Only a title", brief: "", kind: "work", epicID: "", storeIncarnation: store.storeIncarnation))
        XCTAssertNil(try store.captureCreateParameters(projectID: "p2")["starter_fields"], "Title-only capture sends no starter fields")
        let reloaded = try LocalDraftJournal(directory: root).recover(CaptureDraft.self, kind: "capture").values["p1"]
        XCTAssertEqual(reloaded?.starterFields?["platform"], "macOS", "The fields survive in the saved draft")
    }
}

@MainActor private final class StarterAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws {}
    func remove(_ identifiers: [String]) {}
}
