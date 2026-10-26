import SwiftUI
import AppKit
import AVKit
import PDFKit
import ImageIO
import ChecklistCore

struct NativeFilePreview: View {
    let file: AuthorizedPreviewFile
    let kind: FilePreviewKind
    let presentation: FilePreviewPresentation
    var source = false
    var resources: [Record] = []
    var body: some View {
        // Own the accessibility label on a concrete container. A label on the
        // transparent Group rewrites its descendants' AX preferences (including
        // ContentUnavailableView's) and can cycle during hierarchy queries.
        VStack {
            let capability = FilePreviewCapability.assess(kind: kind, size: file.source.integer("size", fallback: -1))
            if !capability.builtIn { NativePreviewUnavailable(reason: capability.reason ?? "") }
            else {
            switch kind {
            case .image: NativeImagePreview(url: file.url, presentation: presentation)
            case .video, .audio: NativePlaybackPreview(url: file.url, audio: kind == .audio)
            case .pdf: NativePDFPreview(url: file.url)
            case .markdown, .text: TextDocumentPreview(file: file, markdown: kind == .markdown && !source, resources: resources)
            case .unsupported: NativePreviewUnavailable(reason: "Use Open in… to choose a compatible installed app. This file will not be executed by Checklist.")
            }
            }
        }.accessibilityElement(children: .contain)
            .accessibilityLabel(presentation.accessibleLabel.isEmpty ? "Preview of " + file.source.string("name") : presentation.accessibleLabel)
    }
}

struct NativePreviewUnavailable: View {
    let reason: String
    var title = "Preview unavailable"
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc").font(.largeTitle).accessibilityHidden(true)
            Text(title).font(.headline)
            Text(reason).foregroundStyle(Color.checklistSecondaryText).multilineTextAlignment(.center).textSelection(.enabled)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
    }
}

struct Checkerboard: View {
    var body: some View {
        // One tiled fill stays bounded even when an actual-pixel image is zoomed
        // far beyond the viewport. Never enumerate its millions of visible cells.
        let tile = NSImage(size: CGSize(width: 24, height: 24), flipped: false) { _ in
            NSColor(white: 0.72, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 24, height: 24).fill()
            NSColor(white: 0.88, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 12, height: 12).fill(); NSRect(x: 12, y: 12, width: 12, height: 12).fill()
            return true
        }
        Rectangle().fill(ImagePaint(image: Image(nsImage: tile))).accessibilityHidden(true)
    }
}

struct NativeImageMetadata {
    let size: CGSize
    let frameCount: Int
    let frameDuration: Double
    let orientation: Int
    init(size: CGSize, frameCount: Int, frameDuration: Double, orientation: Int = 1) {
        self.size = size; self.frameCount = frameCount; self.frameDuration = frameDuration; self.orientation = orientation
    }
    func displaySize(_ raw: CGSize) -> CGSize { (5...8).contains(orientation) ? CGSize(width: raw.height, height: raw.width) : raw }
    var nativeOrientation: Image.Orientation {
        switch orientation { case 2: .upMirrored; case 3: .down; case 4: .downMirrored; case 5: .leftMirrored; case 6: .right; case 7: .rightMirrored; case 8: .left; default: .up }
    }
}

struct NativeImagePreview: View {
    let url: URL
    var presentation = FilePreviewPresentation(kind: .image)
    var frameIndex = 0
    var sourceRect: CGRect? = nil
    var onMetadata: ((NativeImageMetadata) -> Void)? = nil
    @State private var image: CGImage?
    @State private var dimensions = CGSize.zero
    @State private var orientation: Image.Orientation = .up
    @State private var actualPixels = false
    @State private var nearest = false
    @State private var zoom = 1.0
    @State private var problem = ""
    @State private var loading = true
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        VStack {
            HStack {
                Toggle("Actual pixels", isOn: $actualPixels).toggleStyle(.button)
                Toggle("Nearest neighbor", isOn: $nearest).toggleStyle(.button)
                if actualPixels { Slider(value: $zoom, in: 1...8, step: 1).frame(maxWidth: 150).accessibilityLabel("Pixel zoom"); Text("\(Int(zoom * 100))%") }
                Spacer()
                if dimensions != .zero { Text("\(Int(dimensions.width)) × \(Int(dimensions.height)) px").font(.caption).foregroundStyle(Color.checklistSecondaryText) }
            }
            if loading { ProgressView("Decoding image…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if !problem.isEmpty { Text(problem).foregroundStyle(.orange).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let image {
                GeometryReader { geometry in
                    let factor = actualPixels ? zoom / max(displayScale, 1) : min(geometry.size.width / max(dimensions.width, 1), geometry.size.height / max(dimensions.height, 1))
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: image, scale: 1, orientation: orientation).resizable().interpolation(nearest ? .none : .high)
                            .frame(width: dimensions.width * factor, height: dimensions.height * factor)
                            .background(Checkerboard())
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    }
                }
            }
        }.onAppear { actualPixels = presentation.scale == .actualPixels; nearest = presentation.nearestNeighbor }
            .task(id: url.path + "|" + String(actualPixels) + "|" + String(frameIndex) + "|" + String(describing: sourceRect)) { await decode() }
    }
    func decode() async {
        loading = true; problem = ""; image = nil
        let original = actualPixels
        let index = frameIndex, crop = sourceRect
        let work = Task.detached(priority: .userInitiated) {
            try NativeImageDecoder.decode(url: url, original: original, index: index, crop: crop)
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            try Task.checkCancellation(); image = result.0; dimensions = result.2.displaySize(result.1); orientation = result.2.nativeOrientation
            loading = false; onMetadata?(result.2)
        } catch { if !Task.isCancelled { problem = PlainError.text(error); loading = false } }
    }
}

struct NativePlaybackPreview: View {
    let url: URL
    let audio: Bool
    @State private var player: AVPlayer?
    @State private var problem = ""
    var body: some View {
        VStack {
            if audio { Label("Audio preview", systemImage: "waveform").font(.title2) }
            if let player, let item = player.currentItem {
                NativePlayerAdapter(player: player, audio: audio).frame(minHeight: audio ? 120 : 300)
                    .onReceive(item.publisher(for: \.status)) { status in
                        if status == .failed { problem = "This file could not be played: " + (item.error.map(PlainError.text) ?? "The native decoder failed.") }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)) { _ in
                        problem = "Playback failed. Use Open in… to inspect this file in another app."; player.pause()
                    }
            } else if problem.isEmpty { ProgressView(audio ? "Checking audio preview…" : "Checking video preview…").frame(minHeight: audio ? 120 : 300) }
            if !problem.isEmpty { Text(problem).foregroundStyle(.orange) }
            Text("Press Play to start. Native controls provide pause, seeking and volume.").font(.caption).foregroundStyle(Color.checklistSecondaryText)
        }.task(id: url) {
            player?.pause(); player = nil; problem = ""
            do {
                let asset = try await NativePlaybackAsset.load(url: url)
                try Task.checkCancellation(); player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            } catch { if !Task.isCancelled { problem = PlainError.text(error) } }
        }.onDisappear { player?.pause(); player?.replaceCurrentItem(with: nil); player = nil }
    }
}

/// A concrete AVKit view avoids VideoPlayerView's generic superclass metadata
/// initialization, which aborts in optimized builds when AVPlayerView is unresolved.
struct NativePlayerAdapter: NSViewRepresentable {
    let player: AVPlayer
    let audio: Bool
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = !audio
        view.videoGravity = .resizeAspect
        view.player = player
        view.setAccessibilityLabel(audio ? "Audio playback controls" : "Video playback controls")
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player?.pause(); view.player = player }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause(); view.player = nil
    }
}

/// PDFKit initialization stays off the UI executor. The worker sends its unique
/// document region into this MainActor owner and never accesses it afterward.
@MainActor
final class NativePDFDocument {
    let document: PDFDocument?
    private init(document: sending PDFDocument?) { self.document = document }
    isolated deinit {}

    static func load(url: URL) async -> NativePDFDocument {
        await Task.detached(priority: .userInitiated) {
            let document = PDFDocument(url: url)
            return await NativePDFDocument(document: document)
        }.value
    }
}

struct NativePDFPreview: View {
    let url: URL
    @State private var document: PDFDocument?
    @State private var loading = true
    var body: some View {
        Group {
            if loading { ProgressView("Loading PDF…") }
            else if let document { PDFPageAdapter(document: document) }
            else { Text("This PDF is unreadable, locked, unsupported or exceeds 2,000 pages. Use Open in… to inspect it.").foregroundStyle(.orange) }
        }.task(id: url) {
            let result = await NativePDFDocument.load(url: url).document
            guard !Task.isCancelled else { return }
            document = result.flatMap { !$0.isLocked && $0.pageCount <= 2000 ? $0 : nil }; loading = false
        }
    }
}

private struct PDFPageAdapter: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let view = PassivePDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous
        view.document = document; view.setAccessibilityLabel("PDF pages; use the context menu to zoom and scroll to navigate")
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document } }
}

/// PDF actions (including URL/JavaScript/launch annotations) are never performed.
private final class PassivePDFView: PDFView {
    override func perform(_ action: PDFAction) { }
}

/// Shared audio/video asset preparation, independently testable with verified copies.
enum NativePlaybackAsset {
    static func load(url: URL) async throws -> AVURLAsset {
        // Forcing approximate timing rejects otherwise playable PCM WAV assets.
        // Let AVFoundation choose the appropriate loading path for both media kinds.
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw FilePreviewFailure("The installed macOS codecs cannot play this file. Use Open in… for another app.") }
        return asset
    }
}
