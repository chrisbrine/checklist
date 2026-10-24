import XCTest
import SwiftUI
@testable import ChecklistApp

@MainActor final class SettingsModalLifecycleTests: XCTestCase {
    @MainActor private final class Workspace: ObservableObject {
        let presentation = SettingsModalPresentation()
        @Published var scale: CGFloat = 1
        @Published var loading = true
        var mounts = 0, unmounts = 0, readsStarted = 0, readsCanceled = 0
    }
    private struct MountedWorkspace: View {
        @ObservedObject var workspace: Workspace
        @ObservedObject var presentation: SettingsModalPresentation
        var body: some View {
            VStack {
                Text(workspace.loading ? "Loading tickets…" : "Loaded tickets").checklistFont(.body)
                Button("Settings") { presentation.present() }
            }
            .background(SettingsModalAnchor(presentation: presentation, content: { AnyView(Text("Synthetic Settings")) }))
            .onAppear { workspace.mounts += 1 }
            .onDisappear { workspace.unmounts += 1 }
            .task {
                workspace.readsStarted += 1
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch { workspace.readsCanceled += 1 }
            }
            .modifier(SettingsModalBackground(isPresented: presentation.isPresented))
            .environment(\.checklistTextScale, workspace.scale)
        }
    }
    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
    }
    func testSettingsReopensAfterTextReflowWithoutUnmountingLoadingWorkspace() async throws {
        _ = NSApplication.shared
        let workspace = Workspace(), presentation = workspace.presentation
        let host = NSHostingView(rootView: MountedWorkspace(workspace: workspace, presentation: presentation).frame(width: 1000, height: 750))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 750),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic Checklist Settings lifecycle test (offscreen)"
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer {
            presentation.dismiss()
            window.contentView = nil; window.close()
        }
        try await settle(host)
        let anchor = try XCTUnwrap(descendants(host).first)
        XCTAssertTrue(SettingsModalPresentation.forWindow(window) === presentation)
        XCTAssertTrue(anchor.window === window)
        XCTAssertGreaterThan(window.contentLayoutRect.width, 80)
        XCTAssertGreaterThan(window.contentLayoutRect.height, 80)
        XCTAssertEqual(workspace.readsStarted, 1)

        // Both presentations start while data is loading; native text reflow must
        // preserve the anchor, active read and workspace state across dismissal.
        for scale: CGFloat in [2, 1] {
            presentation.present()
            try await settle(host)
            XCTAssertTrue(presentation.isPresented)
            XCTAssertNotNil(window.attachedSheet)
            workspace.scale = scale
            try await settle(host)
            presentation.dismiss()
            try await settle(host)
            XCTAssertFalse(presentation.isPresented)
            XCTAssertNil(window.attachedSheet)
            XCTAssertTrue(descendants(host).first === anchor, "The native Settings anchor must survive the modal transition")
            XCTAssertTrue(SettingsModalPresentation.forWindow(window) === presentation)
            XCTAssertEqual(workspace.mounts, 1)
            XCTAssertEqual(workspace.unmounts, 0, "Closing Settings must not stop the workspace's reads")
            XCTAssertEqual(workspace.readsStarted, 1)
            XCTAssertEqual(workspace.readsCanceled, 0)
        }
        // A late read can still finish and Settings can open over the loaded list.
        workspace.loading = false
        try await settle(host)
        presentation.present()
        try await settle(host)
        XCTAssertTrue(presentation.isPresented)
        XCTAssertNotNil(window.attachedSheet)
    }
    private func descendants(_ view: NSView) -> [SettingsAnchorView] {
        (view as? SettingsAnchorView).map { [$0] } ?? view.subviews.flatMap { descendants($0) }
    }
}
