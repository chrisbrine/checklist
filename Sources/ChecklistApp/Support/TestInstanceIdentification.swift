import SwiftUI
import Combine
import ChecklistIPC

extension View {
    @ViewBuilder func checklistTestIdentification() -> some View {
        if let slot = ChecklistInstance.current.slot {
            self.safeAreaInset(edge:.top,spacing:0) {
                TestInstanceStrip(slot:slot)
            }
            .navigationTitle(ChecklistInstance.current.displayName)
            .background(TestInstanceWindowTitle())
        } else { self }
    }
}

/// Refresh only while a slot strip is visible, so an external `defaults write`
/// appears without a relaunch. The shared controller also updates on each read.
private struct TestInstanceStrip: View {
    let slot: Int
    @ObservedObject private var faults = QualificationFaults.shared
    private let refresh = Timer.publish(every:1,on:.main,in:.common).autoconnect()
    var body: some View {
        HStack {
            Text("TEST INSTANCE \(slot) · synthetic/test data")
            if faults.isArmed { Text("TEST FAULT · \(faults.remaining) remaining").bold() }
        }
        .font(.caption).fontWeight(.semibold)
        .frame(maxWidth:.infinity).padding(.vertical,4)
        .background(.orange.opacity(faults.isArmed ? 0.4 : 0.18))
        .onReceive(refresh) { _ in faults.refresh() }
    }
}

private struct TestInstanceWindowTitle: NSViewRepresentable {
    final class TitleView: NSView {
        private var titleObservation: NSKeyValueObservation?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            titleObservation = nil
            guard let window else { return }
            window.title = ChecklistInstance.current.displayName
            // Child navigation titles can be applied after the scene's title.
            titleObservation = window.observe(\.title, options:[.new]) { window, _ in
                // KVO runs synchronously on the title setter; AppKit title writes are main-thread only.
                MainActor.assumeIsolated {
                    let title = ChecklistInstance.current.displayName
                    if window.title != title { window.title = title }
                }
            }
        }
    }
    func makeNSView(context:Context) -> TitleView { TitleView() }
    func updateNSView(_ view:TitleView,context:Context) {
        DispatchQueue.main.async { view.window?.title = ChecklistInstance.current.displayName }
    }
}
