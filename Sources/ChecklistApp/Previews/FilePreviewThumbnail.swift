import SwiftUI
import AppKit
import ImageIO
import Darwin
import ChecklistCore

struct AttachmentThumbnail: View {
    @EnvironmentObject var store: ChecklistStore
    let file: Record
    @State private var thumbnail: NSImage?
    @State private var problem = ""
    var body: some View {
        Group {
            if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: Radius.small)) }
            else { Image(systemName: problem.isEmpty ? (["reference", "external_reference"].contains(file.string("mode")) ? "link" : "doc") : "exclamationmark.triangle").checklistFont(.sheetHeading).foregroundStyle(.secondary) }
        }.overlay(alignment: .topTrailing) {
            if thumbnail != nil, !problem.isEmpty { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }.help(problem.isEmpty ? "Thumbnail for context; use Preview to inspect the exact original." : problem)
            .accessibilityLabel("Thumbnail of " + file.string("name") + (problem.isEmpty ? "" : ". " + problem))
            .task(id: [file.id, file.string("sha256"), file.string("availability"), file.string("preview_path")].joined(separator: "|")) {
                thumbnail = nil; problem = ""
                let loader = FilePreviewLoader()
                defer { loader.cancel() }
                do {
                    let image: CGImage?
                    if !file.string("preview_path").isEmpty {
                        let actual = Record(values: try await store.request("attachment_read", ["project_id": file.string("project_id"), "attachment_id": file.id, "representation": "preview"]))
                        guard actual.id == file.id, actual.string("project_id") == file.string("project_id"),
                              actual.string("task_id") == file.string("task_id"), actual.string("sha256") == file.string("sha256"),
                              let path = actual.values["url"] as? String, path.hasPrefix("/") else { throw FilePreviewFailure("The service did not return this attachment's thumbnail. Use Preview to inspect the original.") }
                        let work = Task.detached(priority: .utility) { try FilePreviewThumbnailDecoder.retainedPreview(path: path) }
                        image = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                    } else {
                        guard FilePreviewKind.detect(name: file.string("name"), contentType: file.string("content_type")) == .image,
                              (0...(25 * 1024 * 1024)).contains(file.integer("size", fallback: -1)) else { return }
                        await loader.load(file, store: store)
                        try Task.checkCancellation()
                        guard let verified = loader.file else {
                            if !Task.isCancelled { problem = loader.problem }
                            return
                        }
                        problem = loader.problem
                        // Original fallback has a verified identity; allow its full
                        // bounded 25 MiB input rather than the small cache budget.
                        let originalWork = Task.detached(priority: .utility) { try FilePreviewThumbnailDecoder.original(verified) }
                        image = try await withTaskCancellationHandler(operation: { try await originalWork.value }, onCancel: { originalWork.cancel() })
                    }
                    try Task.checkCancellation()
                    if let image { thumbnail = NSImage(cgImage: image, size: .zero) }
                    else { problem = "Thumbnail unavailable. Use Preview to inspect the exact original." }
                } catch { if !Task.isCancelled { problem = PlainError.text(error) } }
            }
    }
}

enum FilePreviewThumbnailDecoder {
    static let retainedBytes = 2 * 1024 * 1024
    static func retainedPreview(path: String) throws -> CGImage? {
        try Task.checkCancellation()
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size >= 0, info.st_size <= retainedBytes else { return nil }
        let data = try handle.read(upToCount: retainedBytes + 1) ?? Data()
        try Task.checkCancellation()
        guard data.count <= retainedBytes, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return try thumbnail(source)
    }
    /// The URL belongs to an already verified owned copy, never an original path.
    static func original(_ file: AuthorizedPreviewFile) throws -> CGImage? {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return try thumbnail(source)
    }
    private static func thumbnail(_ source: CGImageSource) throws -> CGImage? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= FilePreviewLimits.imagePixels / height else { return nil }
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 180, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        try Task.checkCancellation(); return image
    }
}
