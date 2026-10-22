// Compile: bash scripts/compile-component.sh --scratch-path "${CHECKLIST_COMPONENT_BUILD:-/tmp/checklist-components}" check-native-escape-routing
// Run: "${CHECKLIST_COMPONENT_BUILD:-/tmp/checklist-components}/check-native-escape-routing"
// Isolated offscreen SwiftUI/native-event fixture; no Checklist service, drafts, preferences or user windows are changed.
import AppKit
import SwiftUI

@MainActor final class EscapeFixtureModel: ObservableObject {
    @Published var text = "Unsent Your answer draft"
    @Published var presented = true
    var dismissals = 0
    let interaction = DetailOverlayInteraction()
    func dismiss() { presented = false; dismissals += 1 }
}
struct EscapeFixtureView: View {
    @ObservedObject var model: EscapeFixtureModel
    var body: some View {
        VStack {
            Spacer()
            TextField("Your answer", text: $model.text).textFieldStyle(.roundedBorder).frame(width: 300).accessibilityIdentifier("fixtureAnswer")
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .onExitCommand { if model.presented && !model.interaction.leaveEditorBeforeDismiss() { model.dismiss() } }
    }
}
@MainActor final class EscapeOpenerButton: NSButton { override var acceptsFirstResponder: Bool { true } }
@main struct NativeEscapeRoutingChecks {
    @MainActor static func main() async {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let model = EscapeFixtureModel()
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500)); window.contentView = content
        let hosting = NSHostingView(rootView: EscapeFixtureView(model: model)); hosting.frame = NSRect(x: 300, y: 0, width: 400, height: 500); content.addSubview(hosting)
        let opener = EscapeOpenerButton(title: "Open request", target: nil, action: nil); opener.frame = NSRect(x: 30, y: 200, width: 200, height: 30); content.addSubview(opener)
        let contentRegion = InteractionRegionView(frame: content.bounds), overlayRegion = InteractionRegionView(frame: hosting.frame)
        content.addSubview(contentRegion); content.addSubview(overlayRegion)
        model.interaction.attach(contentRegion, region: .content); model.interaction.attach(overlayRegion, region: .overlay)
        window.orderFront(nil); window.layoutIfNeeded()
        window.makeFirstResponder(opener)
        model.interaction.update(presented: true, isPresented: { model.presented }, currentItem: { "request:synthetic" }, dismiss: { model.dismiss() })
        try? await Task.sleep(nanoseconds: 100_000_000)
        var pending: [NSView] = [hosting], fields: [NSTextField] = []
        while let view = pending.popLast() { if let field = view as? NSTextField, field.isEditable { fields.append(field) }; pending.append(contentsOf: view.subviews) }
        guard let field = fields.first else { fatalError("Native SwiftUI text field missing") }
        window.makeFirstResponder(field)
        func sendEscape() {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            app.sendEvent(event)
        }
        sendEscape(); try? await Task.sleep(nanoseconds: 50_000_000)
        print("first_escape presented=\(model.presented) dismissals=\(model.dismissals) responder=\(String(describing: type(of: window.firstResponder))) draft=\(model.text)")
        guard model.presented, model.text == "Unsent Your answer draft" else { fatalError("First Escape lost overlay or draft") }
        sendEscape(); try? await Task.sleep(nanoseconds: 50_000_000)
        print("second_escape presented=\(model.presented) dismissals=\(model.dismissals) draft=\(model.text)")
        if CommandLine.arguments.contains("--expect-baseline-failure") {
            guard model.presented && model.dismissals == 0 else { fatalError("Baseline did not reproduce missing second Escape route") }
            print("Observed baseline regression: second native Escape did not close details")
        } else {
            guard !model.presented, model.dismissals == 1, model.text == "Unsent Your answer draft" else { fatalError("Second native Escape failed to close exactly once with draft retained") }
            guard window.firstResponder === opener else { fatalError("Second native Escape did not restore the opening control") }
            print("Native event-routing regression passed: editor exit, exact second-Escape dismissal, draft retention and opening-control focus")
            var boundaryChecks = 0
            func check(_ condition: @autoclosure () -> Bool, _ message: String) { guard condition() else { fatalError(message) }; boundaryChecks += 1 }
            model.presented = true
            model.interaction.update(presented: true, isPresented: { model.presented }, currentItem: { "request:synthetic" }, dismiss: { model.dismiss() })
            window.makeFirstResponder(window)
            func key(_ code: UInt16 = 53, modifiers: NSEvent.ModifierFlags = [], target: NSWindow? = nil, repeated: Bool = false) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: (target ?? window).windowNumber, context: nil, characters: code == 53 ? "\u{1b}" : "a", charactersIgnoringModifiers: code == 53 ? "\u{1b}" : "a", isARepeat: repeated, keyCode: code)!
            }
            for flag: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
                let modified = key(modifiers: flag)
                check(model.interaction.route(modified) === modified && model.presented, "Modified Escape must keep its normal route")
            }
            let ordinary = key(0)
            check(model.interaction.route(ordinary) === ordinary && model.presented, "Ordinary keys must retain their normal route")
            let repeated = key(repeated: true)
            check(model.interaction.route(repeated) == nil && model.presented, "Holding Escape cannot advance both dismissal stages through autorepeat")
            let other = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            other.orderFront(nil)
            let otherKey = key(target: other)
            check(model.interaction.route(otherKey) === otherKey && model.presented, "Other-window Escape has no dismissal authority")
            let menu = NSMenu(title: "Fixture menu")
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            let menuKey = key()
            check(model.interaction.route(menuKey) === menuKey && model.presented, "Menu tracking must retain Escape for its own cancellation")
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
            let sheet = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            window.beginSheet(sheet, completionHandler: { _ in })
            let sheetKey = key()
            check(window.attachedSheet === sheet && model.interaction.route(sheetKey) === sheetKey && model.presented, "An attached sheet must suspend underlying Escape dismissal")
            let parentClick = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            check(model.interaction.handle(parentClick) === parentClick && model.presented, "An attached sheet must suspend underlying click dismissal before origin capture")
            window.endSheet(sheet); sheet.orderOut(nil)
            let modalSession = app.beginModalSession(for: other)
            let modalKey = key()
            check(app.modalWindow === other && model.interaction.route(modalKey) === modalKey && model.presented, "Another native modal must suspend the underlying Escape route")
            check(model.interaction.handle(parentClick) === parentClick && model.presented, "Another native modal must suspend underlying click dismissal")
            app.endModalSession(modalSession); other.orderOut(nil)
            model.interaction.detach(contentRegion, region: .content)
            let detached = key()
            check(model.interaction.route(detached) === detached && model.presented, "A detached bridge has no remaining Escape authority")
            print("\(boundaryChecks) Escape routing boundary checks passed")
        }
        model.interaction.detach(contentRegion, region: .content); model.interaction.detach(overlayRegion, region: .overlay); window.orderOut(nil)
    }
}
