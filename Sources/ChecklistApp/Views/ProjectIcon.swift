import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProjectIcon: View {
    let project: Record
    let size: CGFloat
    var body: some View {
        Group {
            if let image = normalizedIcon {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: image.size.width, height: image.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: max(3, size * 0.2)))
            } else {
                // The glyph fits the caller-supplied fixed icon frame, independently of text scale.
                Image(systemName: project.string("icon", fallback: "folder")).font(.system(size: size * 0.8)).foregroundStyle(Color.named(project.string("accent")))
            }
        }.frame(width: size, height: size).accessibilityLabel(project.string("name"))
    }
    var normalizedIcon: NSImage? {
        // Keep the managed thumbnail at full pixel resolution in the cache. Native menu
        // labels can use NSImage.size instead of SwiftUI frames, so size a private
        // display copy in points without changing its bitmap representations.
        let asset = project.object("icon_asset")
        guard let source = ProjectIconImageCache.shared.image(projectID: project.id, path: project.string("icon_path"),
            assetID: asset["id"] as? String, checksum: asset["sha256"] as? String),
            source.size.width > 0, source.size.height > 0,
            let image = source.copy() as? NSImage else { return nil }
        let scale = size / max(source.size.width, source.size.height)
        image.size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        return image
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
