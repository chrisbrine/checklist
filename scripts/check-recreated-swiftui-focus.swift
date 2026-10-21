// Compile: xcrun swiftc -swift-version 5 -parse-as-library Sources/ChecklistApp/Models/Record.swift Sources/ChecklistApp/Support/DetailItemStateRetention.swift scripts/check-recreated-swiftui-focus.swift -o /tmp/checklist-recreated-swiftui-focus
// Isolated offscreen native clicks recreate actual SwiftUI detail fields. No
// Checklist service, draft journal, preferences or user windows are changed.
import AppKit
import SwiftUI

@MainActor final class BackFocusModel: ObservableObject {
    @Published var detail = "request"
    @Published var answer = "Unsent answer selected before opening ticket"
}
struct BackFocusRoot: View {
    @ObservedObject var model: BackFocusModel
    var body: some View {
        HStack {
            TextField("Underlying search", text: .constant("")).frame(width: 220).padding(20)
            Spacer()
            VStack {
                Button("Back") { model.detail = "request" }.accessibilityIdentifier("fixtureBack")
                Group {
                    if model.detail == "request" {
                        ScrollView {
                            VStack(spacing: 18) {
                                Button("CL92 ticket") { model.detail = "ticket" }.accessibilityIdentifier("fixtureTicketLink")
                                TextField("Custom answer", text: .constant("")).textFieldStyle(.roundedBorder)
                                TextField("Your answer", text: $model.answer).textFieldStyle(.roundedBorder).accessibilityIdentifier("fixtureAnswer")
                                ForEach(0..<12) { Text("Supporting context \($0)") }
                            }.padding(20)
                        }.id("request")
                    } else {
                        ScrollView { VStack { Text("Ticket detail"); Text("The request field was removed from the native view tree.") }.padding(20) }.id("ticket")
                    }
                }.background(DetailItemStateRetention(key: model.detail).id(model.detail))
            }.frame(width: 400).padding(15)
        }.frame(width: 1200, height: 600)
    }
}
@MainActor final class BackFocusWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
@main struct RecreatedSwiftUIFocusChecks {
    @MainActor static func main() async {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let model = BackFocusModel()
        let window = BackFocusWindow(contentRect: NSRect(x: -5000, y: 0, width: 1200, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: BackFocusRoot(model: model)); window.contentView = hosting; window.orderFront(nil); window.layoutIfNeeded()
        func settle() async { try? await Task.sleep(nanoseconds: 100_000_000); window.layoutIfNeeded() }
        await settle()
        func views() -> [NSView] { var found: [NSView] = [], pending: [NSView] = [hosting]; while let view = pending.popLast() { found.append(view); pending.append(contentsOf: view.subviews) }; return found }
        func answerField() -> NSTextField? { views().compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.placeholderString == "Your answer" } }
        func accessibility(_ id: String) -> NSAccessibilityProtocol? {
            var pending: [Any] = [window], count = 0
            while let candidate = pending.popLast(), count < 2000 {
                count += 1
                guard let item = candidate as? NSAccessibilityProtocol else { continue }
                if item.accessibilityIdentifier() == id { return item }
                pending.append(contentsOf: item.accessibilityChildren() ?? [])
            }
            return nil
        }
        func clickPoint(_ point: NSPoint) {
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                app.sendEvent(event)
            }
        }
        func click(_ id: String) {
            let point: NSPoint
            if let button = views().compactMap({ $0 as? NSButton }).first(where: { $0.title == (id == "fixtureBack" ? "Back" : "CL92 ticket") }) {
                point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            } else if let item = accessibility(id) {
                let bounds = item.accessibilityFrame(); point = window.convertPoint(fromScreen: NSPoint(x: bounds.midX, y: bounds.midY))
            } else if let proxy = views().first(where: { String(reflecting: type(of: $0)).contains("KeyViewProxy") && ($0.enclosingScrollView == nil) == (id == "fixtureBack") }) {
                // SwiftUI buttons are virtual accessibility nodes; their native key
                // proxy occupies the actual hit rectangle in this bounded fixture.
                point = proxy.convert(NSPoint(x: proxy.bounds.midX, y: proxy.bounds.midY), to: nil)
            } else { fatalError("Missing native button hit rectangle \(id)") }
            clickPoint(point)
        }
        guard let original = answerField() else { fatalError("Original actual SwiftUI answer field missing") }
        window.makeFirstResponder(original)
        _ = app.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        await settle()
        guard let before = window.firstResponder as? NSTextView else { fatalError("Original native text responder missing") }
        let selectedBefore = before.selectedRange()
        guard selectedBefore == NSRange(location: 0, length: (model.answer as NSString).length) else { fatalError("Native Select All did not select the exact unsent answer") }
        FileHandle.standardError.write(Data("before selection=\(selectedBefore) fieldEditor=\(before.isFieldEditor) delegate=\(String(describing: type(of: before.delegate))) cache=\(String(describing: DetailItemNavigationMemory.shared.entries["request"]?.focus))\n".utf8))
        click("fixtureTicketLink"); await settle()
        guard model.detail == "ticket", answerField() == nil else { fatalError("Native ticket link did not recreate the SwiftUI detail") }
        click("fixtureBack"); await settle()
        guard let recreated = answerField(), recreated !== original else { fatalError("Back did not instantiate a fresh SwiftUI field") }
        let after = window.firstResponder as? NSTextView
        let restored = after?.delegate as? NSTextField === recreated && after?.selectedRange() == selectedBefore
        FileHandle.standardError.write(Data("after focusedField=\(String(describing: (after?.delegate as? NSTextField)?.placeholderString)) selection=\(String(describing: after?.selectedRange())) responder=\(String(describing: type(of: window.firstResponder))) cache=\(String(describing: DetailItemNavigationMemory.shared.entries["request"]?.focus))\n".utf8))
        guard model.answer == "Unsent answer selected before opening ticket" else { fatalError("Native navigation lost the draft") }
        if CommandLine.arguments.contains("--expect-baseline-failure") { guard !restored else { fatalError("Baseline did not reproduce Back focus/selection failure") }; print("Observed baseline recreated-SwiftUI Back focus/selection failure") }
        else {
            guard restored else { fatalError("Recreated SwiftUI Back failed focus/selection restoration") }
            print("Recreated SwiftUI navigation restores original field focus, selection and draft")
            model.detail = "ticket"; await settle()
            guard let outside = views().compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "Underlying search" }) else { fatalError("Underlying field missing") }
            window.makeFirstResponder(outside); await settle()
            guard (window.firstResponder as? NSTextView)?.delegate as? NSTextField === outside else { fatalError("Underlying native search did not acquire focus") }
            model.detail = "request"; await settle()
            guard model.detail == "request", (window.firstResponder as? NSTextView)?.delegate as? NSTextField === outside else { fatalError("Recreated detail stole focus from an outside editor") }
            print("Recreated SwiftUI navigation preserves an already focused outside native editor")
        }
        window.orderOut(nil)
    }
}
