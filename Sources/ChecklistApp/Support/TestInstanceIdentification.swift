import SwiftUI
import ChecklistIPC

extension View {
    @ViewBuilder func checklistTestIdentification() -> some View {
        if let slot = ChecklistInstance.current.slot {
            self.safeAreaInset(edge:.top,spacing:0) {
                Text("TEST INSTANCE \(slot) · synthetic/test data")
                    .font(.caption).fontWeight(.semibold)
                    .frame(maxWidth:.infinity).padding(.vertical,4)
                    .background(.orange.opacity(0.18))
            }
            .navigationTitle(ChecklistInstance.current.displayName)
            .background(TestInstanceWindowTitle())
        } else { self }
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
                let title = ChecklistInstance.current.displayName
                if window.title != title { window.title = title }
            }
        }
    }
    func makeNSView(context:Context) -> TitleView { TitleView() }
    func updateNSView(_ view:TitleView,context:Context) {
        DispatchQueue.main.async { view.window?.title = ChecklistInstance.current.displayName }
    }
}
