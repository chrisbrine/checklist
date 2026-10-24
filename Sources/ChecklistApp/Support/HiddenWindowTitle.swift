import SwiftUI

extension View {
    /// Hide the drawn title while retaining the scene/navigation title for native window identification.
    @ViewBuilder func checklistHiddenWindowTitle() -> some View {
        if #available(macOS 15, *) {
            self.toolbar(removing: .title)
        } else {
            self.background(HiddenWindowTitle())
        }
    }
}

/// macOS 14 has no SwiftUI toolbar-title removal API.
struct HiddenWindowTitle: NSViewRepresentable {
    final class TitleView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titleVisibility = .hidden
        }
    }
    func makeNSView(context: Context) -> TitleView { TitleView() }
    func updateNSView(_ view: TitleView, context: Context) {
        view.window?.titleVisibility = .hidden
    }
}
