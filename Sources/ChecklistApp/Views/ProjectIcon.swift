import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProjectIcon: View {
    let project: Record
    var size: CGFloat = 20
    var body: some View {
        Group {
            if let image = normalizedIcon {
                // The thumbnail corner follows the caller-supplied fixed icon frame.
                Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: max(3, size * 0.2)))
            } else {
                // The glyph fits the caller-supplied fixed icon frame, independently of text scale.
                Image(systemName: project.string("icon", fallback: "folder")).font(.system(size: size * 0.8)).foregroundStyle(Color.named(project.string("accent")))
            }
        }.frame(width: size, height: size).accessibilityLabel(project.string("name"))
    }
    var normalizedIcon: NSImage? {
        // The service supplies its managed, normalized 256 px thumbnail, never a source image.
        let asset = project.object("icon_asset")
        return ProjectIconImageCache.shared.image(projectID: project.id, path: project.string("icon_path"),
            assetID: asset["id"] as? String, checksum: asset["sha256"] as? String)
    }
}

@MainActor
func chooseProjectIcon() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png, .jpeg, .webP]
    panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
    panel.message = "Choose a PNG, JPEG or WebP up to 5 MiB and 4,096 pixels per edge. Checklist keeps a small managed icon; your original stays unchanged."
    panel.prompt = "Use image"
    return panel.runModal() == .OK ? panel.url : nil
}
