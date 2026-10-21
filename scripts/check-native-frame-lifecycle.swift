// Compile: xcrun swiftc -swift-version 5 -parse-as-library Sources/ChecklistApp/Support/DetailOverlayInteraction.swift scripts/check-native-frame-lifecycle.swift -o /tmp/checklist-native-frame-lifecycle
// Run twice as separate processes: --seed then --relaunch. The standalone test
// executable has its own preferences domain. Set CL17_FRAME_KEY to a fresh UUID
// and CL17_FRAME_PROBE_OUTPUT to a private absolute JSONL path for both runs.
// Native fixture windows stay hidden with activation prohibited.
import AppKit
import SwiftUI

@MainActor final class FrameLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        precondition(Bundle.main.bundleIdentifier != "org.checklist.app", "Run only the standalone private test executable")
        // Model SwiftUI's stale default-sized host frame independently of the
        // stable workspace frame. Never touch org.checklist.app preferences.
        let seedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        seedWindow.setFrame(NSRect(origin: NSScreen.main?.visibleFrame.origin ?? .zero, size: NSSize(width: 1240, height: 820)), display: false)
        seedWindow.saveFrame(usingName: "main")
        if CommandLine.arguments.contains("--seed") {
            seedWindow.setFrame(NSRect(origin: seedWindow.frame.origin, size: NSSize(width: 900, height: 702)), display: false)
            seedWindow.saveFrame(usingName: ProcessInfo.processInfo.environment["CL17_FRAME_KEY"]!)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor final class LifecycleAnchor: NSView {
    let interaction = DetailOverlayInteraction(frameAutosaveName: ProcessInfo.processInfo.environment["CL17_FRAME_KEY"]!)
    private var scheduled = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !scheduled else { return }; scheduled = true
        window.orderOut(nil)
        interaction.attach(self, region: .content)
        record("attached", window: window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            record("restored", window: window)
            let seed = CommandLine.arguments.contains("--seed")
            let expected = seed ? NSSize(width: 900, height: 702) : NSSize(width: 940, height: 710)
            let restored = window.frame.size == expected
            guard window.frameAutosaveName == "main" else { fatalError("Workspace bridge replaced SwiftUI's native autosave ownership") }
            guard !window.isVisible, NSApp.activationPolicy() == .prohibited else { fatalError("Private fixture became visible") }
            if CommandLine.arguments.contains("--expect-baseline-failure") {
                guard !restored, window.frame.size == NSSize(width: 1240, height: 820) else { fatalError("Baseline did not reproduce native singleton restoration failure") }
                print("Observed baseline singleton SwiftUI Window ignored saved 900×702 workspace frame")
                NSApp.terminate(nil); return
            }
            guard restored else { fatalError("Actual native scene did not restore saved frame: \(window.frame.size), expected \(expected)") }
            if seed {
                window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 940, height: 710)), display: false)
                record("owner_resize", window: window)
            }
            // Reattaching a layout bridge must not restart restoration or undo
            // the owner resize. The next independent process proves persistence.
            for _ in 0..<20 { interaction.attach(self, region: .content) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
                guard window.frame.size == NSSize(width: 940, height: 710) else { fatalError("Repeated attachment reset the owner's frame") }
                record("before_quit", window: window)
                print(seed ? "Native singleton scene restored 900×702, retained owner resize 940×710 and native main autosave" : "A fresh native singleton scene process restored 940×710 with native main autosave intact")
                NSApp.terminate(nil)
            }
        }
    }
    private func record(_ phase: String, window: NSWindow) {
        let key = ProcessInfo.processInfo.environment["CL17_FRAME_KEY"]!
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CL17_FRAME_PROBE_OUTPUT"]!)
        let row: [String: Any] = ["phase": phase, "pid": ProcessInfo.processInfo.processIdentifier, "domain": ProcessInfo.processInfo.processName, "frame_autosave_name": window.frameAutosaveName, "frame": NSStringFromRect(window.frame), "saved_workspace_frame": UserDefaults.standard.string(forKey: "NSWindow Frame " + key) ?? "", "visible": window.isVisible, "activation_policy": NSApp.activationPolicy().rawValue]
        let bytes = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data("\n".utf8)
        if FileManager.default.fileExists(atPath: output.path) { let file = try! FileHandle(forWritingTo: output); try! file.seekToEnd(); try! file.write(contentsOf: bytes); try! file.close() }
        else { try! bytes.write(to: output) }
    }
}
struct LifecycleRoot: NSViewRepresentable {
    func makeNSView(context: Context) -> LifecycleAnchor { LifecycleAnchor() }
    func updateNSView(_ view: LifecycleAnchor, context: Context) { view.interaction.attach(view, region: .content) }
    static func dismantleNSView(_ view: LifecycleAnchor, coordinator: ()) { view.interaction.detach(view, region: .content) }
}
@main struct NativeFrameLifecycleChecks: App {
    @NSApplicationDelegateAdaptor(FrameLifecycleDelegate.self) var delegate
    var body: some Scene {
        Window("Private CL17 frame lifecycle fixture", id: "main") {
            LifecycleRoot().frame(minWidth: 900, minHeight: 650)
        }.defaultSize(width: 1240, height: 820)
    }
}
