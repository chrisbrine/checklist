import ChecklistAXTestSupport
import XCTest
import SwiftUI
@testable import ChecklistApp

@MainActor final class NativeClosureReleasePresentationTests: XCTestCase {
    private func attempt(state: String = "released", reference: String = "closure", reason: String = "Verified native process and registry closure.") -> Record {
        Record(values: ["id": "synthetic-attempt", "state": state, "native_closure_ref": reference, "reason": reason])
    }
    func testOnlyNativeClosureReleaseGetsReleaseSummary() throws {
        let reason = "Verified the exact process exited and its host registry entry disappeared."
        XCTAssertEqual(try XCTUnwrap(NativeClosureReleasePresentation(attempt: attempt(reason: reason))).reason, reason)
        XCTAssertNil(NativeClosureReleasePresentation(attempt: attempt(state: "active")))
        XCTAssertNil(NativeClosureReleasePresentation(attempt: attempt(reference: "")))
        XCTAssertEqual(NativeClosureReleasePresentation(attempt: attempt(reason: " \n"))?.reason,
                       "Verified native process and registry closure.")
    }
    func testActiveRootAndNewerRootWorkSuppressTicketReleaseSummary() {
        let released = attempt()
        XCTAssertNotNil(NativeClosureReleasePresentation.latestRootRelease(attempts: [released], activeAttemptID: ""))
        XCTAssertNil(NativeClosureReleasePresentation.latestRootRelease(attempts: [released], activeAttemptID: "current-root"))
        XCTAssertNil(NativeClosureReleasePresentation.latestRootRelease(attempts: [attempt(state: "submitted"), released], activeAttemptID: ""))
        var child = released.values; child["parent_attempt_id"] = "root"
        XCTAssertNil(NativeClosureReleasePresentation.latestRootRelease(attempts: [Record(values: child)], activeAttemptID: ""))
        XCTAssertNil(NativeClosureReleasePresentation.latestRootRelease(attempts: [Record(values: child), attempt(state: "active")], activeAttemptID: "root"))
    }
    func testNativeSummaryExposesReleasedClaimAndCompleteReason() async throws {
        let reason = "Verified the exact native process and registry closure. " + String(repeating: "Retained history remains available. ", count: 20)
        let release = try XCTUnwrap(NativeClosureReleasePresentation(attempt: attempt(reason: reason)))
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = ChecklistTestAXAttributeValue(NSApplication.shared, enhanced) ?? false
        ChecklistTestAXSetValue(NSApplication.shared, true, enhanced)
        defer { ChecklistTestAXSetValue(NSApplication.shared, previous, enhanced) }
        let host = NSHostingView(rootView: NativeClosureReleaseSummary(release: release))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 360, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic Checklist native-closure release test (offscreen)"
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        func values(_ object: NSObject, depth: Int = 0) -> [String] {
            guard depth < 30 else { return [] }
            func attribute(_ name: String) -> Any? {
                let selector = NSSelectorFromString(name)
                return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
            }
            return ["accessibilityLabel", "accessibilityValue", "accessibilityHelp"].compactMap { attribute($0) as? String }
                + (attribute("accessibilityChildren") as? [NSObject] ?? []).flatMap { values($0, depth: depth + 1) }
        }
        let shown = values(host).joined(separator: " | ")
        XCTAssertTrue(shown.contains(NativeClosureReleasePresentation.title), shown)
        XCTAssertTrue(shown.contains(reason), shown)
    }
}
