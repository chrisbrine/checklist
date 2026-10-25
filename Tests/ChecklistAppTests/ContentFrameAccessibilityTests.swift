import XCTest
import SwiftUI
import AppKit
@testable import ChecklistApp

@MainActor final class ContentFrameAccessibilityTests: XCTestCase {
    private final class AXContentNode: NSObject {
        @objc var accessibilityChildren: [NSObject] = []
        @objc var accessibilityRole = "AXGroup"
        @objc var accessibilityIdentifier = ""
        @objc var accessibilityValue = ""
    }
    func testScopedContentRequiresEveryFactAndStaticTextInsideTheSection() {
        let root = AXContentNode(), section = AXContentNode(), background = AXContentNode()
        let first = AXContentNode(), second = AXContentNode(), menu = AXContentNode()
        section.accessibilityIdentifier = "receipts"
        first.accessibilityRole = "AXStaticText";first.accessibilityValue = "receipt one"
        second.accessibilityRole = "AXButton";second.accessibilityValue = "receipt two"
        background.accessibilityRole = "AXStaticText";background.accessibilityValue = "receipt two"
        root.accessibilityChildren = [background,section]
        section.accessibilityChildren = [first,second]
        let expected = ScreenAccessibilityContent(identifier:"receipts",text:["receipt one","receipt two"],staticTextOnly:true)
        XCTAssertFalse(expected.isPresent(in:root),"Neither a background fact nor a matching button satisfies scoped static content")
        XCTAssertTrue(ScreenAccessibilityContent(identifier:"receipts",text:expected.text).isPresent(in:root),"Ordinary text matching remains available")
        second.accessibilityRole = "AXStaticText"
        XCTAssertTrue(expected.isPresent(in:root))
        menu.accessibilityRole = "AXMenu";menu.accessibilityChildren = [second]
        section.accessibilityChildren = [first,menu]
        XCTAssertFalse(expected.isPresent(in:root),"Hidden menu descendants cannot supply a missing fact")
        XCTAssertFalse(ScreenAccessibilityContent(identifier:"missing",text:[]).isPresent(in:root),"An empty receipt page still needs its own section")
        section.accessibilityChildren = [section]
        XCTAssertFalse(expected.isPresent(in:root),"A cyclic or truncated AX tree cannot certify missing content")
    }
    private final class UnavailableAXRoot: NSView {
        override func accessibilityChildren() -> [Any]? {[]}
    }
    func testUnavailableAccessibilityDoesNotEmitAContentReceipt() async throws {
        _ = NSApplication.shared
        let timing = ScreenTiming();timing.begin(.projectSwitch)
        let host = NSHostingView(rootView:Text("Destination").frame(width:400,height:200)
            .screenContentFrame(timing,.projectSwitch,ready:true,accessibilityContent:ScreenAccessibilityContent(text:["Destination"])))
        let root = UnavailableAXRoot(frame:NSRect(x:0,y:0,width:400,height:200));host.frame=root.bounds;root.addSubview(host)
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:400,height:200),styleMask:[],backing:.buffered,defer:false)
        window.title="Synthetic unavailable AX root (offscreen)";window.isReleasedWhenClosed=false;window.contentView=root;window.orderFront(nil)
        defer {NativeRenderMetrics.cancel();window.contentView=nil;window.close()}
        NativeRenderMetrics.begin(sample:254)
        root.layoutSubtreeIfNeeded();root.displayIfNeeded();window.displayIfNeeded()
        XCTAssertNil(NativeRenderMetrics.finish()?.screens["project_switch"])
        XCTAssertNotNil(timing.navigation(.projectSwitch),"Unavailable AX is unmeasured, never reported as installed")
    }
    func testRealSizeListClockWaitsForDestinationAccessibleText() async throws {
        _ = NSApplication.shared
        let restoreAX = AXProbe.enableEnhancedUserInterface(); defer {restoreAX()}
        let timing = ScreenTiming()
        timing.begin(.projectSwitch)
        func content(_ destination: Bool) -> some View {
            VStack {
                Text("Destination project")
                // A matching list-row button behind a not-yet-built detail
                // header cannot stand in for that header's static text.
                Button("Destination ticket 0") {}
                Text("Showing 200 of 286 matching tickets")
                ScrollView {
                    LazyVStack {ForEach(0..<200) {i in Text("\(destination ? "Destination" : "Previous") ticket \(i)")}}
                }
            }.frame(width:900,height:650)
                .screenContentFrame(timing,.projectSwitch,ready:true,accessibilityContent:ScreenAccessibilityContent(text:["Destination project","Showing 200 of 286 matching tickets","Destination ticket 0"],staticTextOnly:true))
        }
        let host = NSHostingView(rootView:content(false))
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:900,height:650),styleMask:[],backing:.buffered,defer:false)
        window.title = "Synthetic content-frame AX qualification (offscreen)";window.isReleasedWhenClosed = false;window.contentView = host;window.orderFront(nil)
        defer {NativeRenderMetrics.cancel();window.contentView = nil;window.close()}
        func draw() {
            host.layoutSubtreeIfNeeded();host.displayIfNeeded();window.displayIfNeeded()
            func probes(_ view:NSView) {for child in view.subviews {probes(child)};if String(describing:type(of:view)).contains("FrameView") {view.display()}}
            probes(host)
        }
        NativeRenderMetrics.begin(sample:254)
        draw()
        XCTAssertTrue(AXProbe.text(host).contains("Previous ticket 0"))
        XCTAssertNil(NativeRenderMetrics.finish()?.screens["project_switch"],"A draw with the wrong AX content cannot finish navigation")
        XCTAssertNotNil(timing.navigation(.projectSwitch))
        NativeRenderMetrics.begin(sample:254)
        host.rootView = content(true)
        for _ in 0..<3 {await Task.yield();draw()}
        let text = AXProbe.text(host)
        XCTAssertTrue(text.contains("Destination project"));XCTAssertTrue(text.contains("Destination ticket 0"));XCTAssertFalse(text.contains("Previous ticket 0"))
        XCTAssertNotNil(NativeRenderMetrics.finish()?.screens["project_switch"])
    }
}
