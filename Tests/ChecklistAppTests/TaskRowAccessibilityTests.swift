import XCTest
import SwiftUI
@testable import ChecklistApp

/// Synthetic native rows only; no service, live store or installed app window.
@MainActor final class TaskRowAccessibilityTests: XCTestCase {
    func testPlainRowLabelKeepsDisplayedFactsAndOpenActionAcrossUpdates() async throws {
        _ = NSApplication.shared
        let restoreAX = AXProbe.enableEnhancedUserInterface();defer {restoreAX()}
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preferences = isolatedDefaults("TaskRowAX").preferences
        let store = ChecklistStore(draftJournal:LocalDraftJournal(directory:root),preferences:preferences,
            restorePendingCommand:false,desktopAlerts:DesktopAlertCoordinator(sink:RowAXAlertSink()),
            requestTransport:{_,_ in throw CancellationError()})
        store.data["projects"] = [["id":"p","name":"Synthetic project"]]
        var values: [String:Any] = ["id":"task","project_id":"p","key":"S-1","title":"Synthetic row",
            "kind":"bug","status_category":"done","status_name":"Finished","readiness":"draft",
            "planned_assignee":"human","status_reason":["text":"Complete reason beyond the visible line."]]
        let host = NSHostingView(rootView:TaskRow(task:Record(values:values)).environmentObject(store))
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:600,height:180),
            styleMask:[],backing:.buffered,defer:false)
        window.title = "Synthetic Checklist row accessibility check (offscreen)"
        window.isReleasedWhenClosed = false;window.contentView = host;window.orderFront(nil)
        defer {store.stopWindowReads();window.contentView = nil;window.close();try? FileManager.default.removeItem(at:root)}
        func draw() {host.layoutSubtreeIfNeeded();host.displayIfNeeded();window.displayIfNeeded()}
        let facts = ["Synthetic row","Reason: Complete reason beyond the visible line.","S-1",
            "Synthetic project","Bug","You","Finished","Draft"]
        try await AXProbe.until {draw();let text = AXProbe.text(host);return facts.allSatisfy(text.contains)}
        let before = AXProbe.text(host)
        for fact in facts {XCTAssertTrue(before.contains(fact),fact)}
        values["title"] = "Updated synthetic row";values["status_reason"] = nil;values["readiness"] = "ready"
        values["status_category"] = "queued";values["status_name"] = "Queued"
        host.rootView = TaskRow(task:Record(values:values)).environmentObject(store)
        try await AXProbe.until {draw();return AXProbe.text(host).contains("Updated synthetic row")}
        let after = AXProbe.text(host)
        XCTAssertFalse(after.contains("Complete reason beyond"));XCTAssertFalse(after.contains("Draft"))
        XCTAssertFalse(after.contains("Finished"))
        let button = try XCTUnwrap(AXProbe.nodes(host).first {
            AXProbe.attribute($0,"accessibilityIdentifier") as? String == "taskRow-S-1"
                && (AXProbe.attribute($0,"accessibilityRole") as? String) == "AXButton"
        })
        AXProbe.press(button)
        XCTAssertEqual(store.detail,.task("task"),"The plain label preserves the row's native Open action")
        store.closeDetail();XCTAssertNil(store.detail)
    }
}
@MainActor private final class RowAXAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization {.denied}
    func requestAuthorizationFromOwnerAction() async throws -> Bool {false}
    func send(_ alert:DesktopAlert) async throws {XCTFail("No alerts in row fixture")}
    func remove(_ identifiers:[String]) {}
}
