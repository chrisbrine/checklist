import ChecklistAXTestSupport
import XCTest
import SwiftUI
@testable import ChecklistApp

@MainActor final class TicketStatusReasonTests: XCTestCase {
    private func ticket(_ reason: [String:Any]? = nil, category: String = "blocked") -> Record {
        var value: [String:Any] = ["id":"ticket", "status_category":category, "status_name":category.capitalized, "title":"Fix this"]
        value["status_reason"] = reason
        return Record(values:value)
    }
    func testHeaderAndEverySharedListLineRetainFullReasonAndAttribution() throws {
        let text = "Waiting for the exact installed build.\nOwner must inspect the header and all lists. " + String(repeating:"More detail. ",count:40)
        let task = ticket(["text":text,"actor_display":"Reviewer","at":"2026-10-22T21:00:00Z"])
        let header = try XCTUnwrap(TicketStatusReasonDetail(task:task).reason)
        XCTAssertEqual(header.text,text);XCTAssertEqual(header.actor,"Reviewer");XCTAssertEqual(header.at,"2026-10-22T21:00:00Z")
        XCTAssertEqual(TicketStatusReasonLine(task:task).reason,header)
        XCTAssertEqual(TaskRowPresentation(task:task,selected:false,projectName:nil,age:"now").statusReason,header)
    }
    func testReasonIsShownForQueuedAndClearedWhenFieldDisappears() {
        let task = ticket(["text":"Continue in a later pass"],category:"queued")
        XCTAssertNotNil(TicketStatusReasonDetail(task:task).reason)
        XCTAssertNotNil(TicketStatusReasonLine(task:task).reason)
        XCTAssertNil(TicketStatusReasonDetail(task:ticket()).reason)
        XCTAssertNil(TicketStatusReasonLine(task:ticket(["text":"  \n"])).reason)
    }
    func testReasonChangesInvalidateEquatableTicketRows() {
        let before = ticket(["text":"First"]), after = ticket(["text":"Second"])
        func row(_ task:Record) -> TaskRowPresentation {TaskRowPresentation(task:task,selected:false,projectName:nil,age:"now")}
        XCTAssertNotEqual(row(before),row(after));XCTAssertNotEqual(row(after),row(ticket()))
        XCTAssertEqual(row(before),row(before))
    }
}

extension TicketStatusReasonTests {
    @MainActor func testNativeHeaderAndTruncatedRowExposeCompleteTextAndClear() async throws {
        let task = ticket(["text":"Waiting for the exact build. More details continue beyond the visible row width.","actor_display":"Reviewer","at":"2026-10-22T21:00:00Z"])
        let reason = task.object("status_reason")["text"] as! String
        let enhanced = NSAccessibility.Attribute(rawValue:"AXEnhancedUserInterface")
        let previous = ChecklistTestAXAttributeValue(NSApplication.shared, enhanced) ?? false
        ChecklistTestAXSetValue(NSApplication.shared, true, enhanced)
        defer {ChecklistTestAXSetValue(NSApplication.shared, previous, enhanced)}
        let host = NSHostingView(rootView: AnyView(VStack {
            TicketStatusReasonDetail(task:task)
            TicketStatusReasonLine(task:task)
        }))
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:260,height:240),styleMask:[.titled],backing:.buffered,defer:false)
        window.title = "Synthetic Checklist status-reason test (offscreen)"
        window.isReleasedWhenClosed = false;window.contentView = host
        defer {window.contentView = nil;window.close()}
        window.orderFront(nil)
        try await Task.sleep(nanoseconds:100_000_000)
        host.layoutSubtreeIfNeeded()
        func values(_ object:NSObject, depth:Int = 0) -> [String] {
            guard depth < 30 else {return []}
            func attribute(_ name:String) -> Any? {
                let selector = NSSelectorFromString(name)
                return object.responds(to:selector) ? object.perform(selector)?.takeUnretainedValue() : nil
            }
            return ["accessibilityLabel","accessibilityValue","accessibilityHelp"].compactMap {attribute($0) as? String}
                + (attribute("accessibilityChildren") as? [NSObject] ?? []).flatMap {values($0,depth:depth+1)}
        }
        let shown = values(host).joined(separator:" | ")
        XCTAssertTrue(shown.contains(reason),shown)
        XCTAssertTrue(shown.contains("Reviewer"),shown)
        XCTAssertTrue(shown.contains("Reason: " + reason),shown)
        host.rootView = AnyView(VStack {
            TicketStatusReasonDetail(task:ticket())
            TicketStatusReasonLine(task:ticket())
        })
        try await Task.sleep(nanoseconds:100_000_000)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(values(host).joined().contains(reason))
    }
}
