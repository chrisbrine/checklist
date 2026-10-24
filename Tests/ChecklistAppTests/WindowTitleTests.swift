import XCTest
import AppKit
@testable import ChecklistApp

final class WindowTitleTests: XCTestCase {
    @MainActor func testLegacyTitleHidingPreservesNativeTitleWhenAttachedAndMoved() {
        _ = NSApplication.shared
        for title in ["Checklist", "Checklist TEST INSTANCE 2"] {
            let window = NSWindow(contentRect: NSRect(x: -9000, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = title
            let anchor = HiddenWindowTitle.TitleView()
            window.contentView?.addSubview(anchor)
            XCTAssertEqual(window.titleVisibility, .hidden)
            XCTAssertEqual(window.title, title, "Window menu, Mission Control and accessibility keep the native name")
            anchor.removeFromSuperview()
            window.titleVisibility = .visible
            window.contentView?.addSubview(anchor)
            XCTAssertEqual(window.titleVisibility, .hidden)
            XCTAssertEqual(window.title, title)
            window.orderOut(nil)
        }
    }

    func testContentHidesOnlyVisibleTitleAndKeepsToolbarAndTestIdentification() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(contentsOf: root.appendingPathComponent("Sources/ChecklistApp/Views/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(content.contains(".navigationTitle(\"Checklist\")\n        .checklistHiddenWindowTitle()"))
        for control in ["Toggle sidebar", "All projects", "globalSearch", "New ticket (⌘N)"] { XCTAssertTrue(content.contains(control), control) }
        let policy = try String(contentsOf: root.appendingPathComponent("Sources/ChecklistApp/Support/HiddenWindowTitle.swift"), encoding: .utf8)
        XCTAssertTrue(policy.contains("if #available(macOS 15, *)"))
        XCTAssertTrue(policy.contains("self.toolbar(removing: .title)"))
        let identification = try String(contentsOf: root.appendingPathComponent("Sources/ChecklistApp/Support/TestInstanceIdentification.swift"), encoding: .utf8)
        XCTAssertTrue(identification.contains("TEST INSTANCE"))
        XCTAssertTrue(identification.contains(".background(.orange"))
        XCTAssertTrue(identification.contains("window.title = ChecklistInstance.current.displayName"))
        let sidebar = try String(contentsOf: root.appendingPathComponent("Sources/ChecklistApp/Views/SidebarView.swift"), encoding: .utf8)
        XCTAssertTrue(sidebar.contains("Text(\"Checklist\").checklistFont(.title)"))
    }
}
