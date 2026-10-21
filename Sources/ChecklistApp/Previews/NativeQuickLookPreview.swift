import SwiftUI
import AppKit
import Quartz

struct FileQuickLookSheet: View {
    @Environment(\.dismiss) private var dismiss
    let file: AuthorizedPreviewFile
    var body: some View {
        VStack {
            HStack { Text(file.source.string("name")).font(.headline); Spacer(); Button("Close Quick Look") { dismiss() }.keyboardShortcut(" ", modifiers: []) }
            FileQuickLookAdapter(url: file.url)
        }.padding().frame(minWidth: 640, idealWidth: 1000, minHeight: 480, idealHeight: 720)
            .onExitCommand { dismiss() }
    }
}

private struct FileQuickLookAdapter: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false; view.shouldCloseWithWindow = false; view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL } }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
