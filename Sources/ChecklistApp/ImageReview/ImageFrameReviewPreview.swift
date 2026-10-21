import SwiftUI
import ChecklistCore

/// Playback owns only selection/timing. The shared bounded native adapter still
/// owns decoding, pixel scaling, transparency and cancellation.
struct ImageFrameReviewPreview: View {
    let url: URL
    var metadata: [String: Any] = [:]
    var onReady: () -> Void = { }
    @State private var information: NativeImageMetadata?
    @State private var frame = 0
    @State private var playing = false
    @State private var spriteSheet = false
    @State private var columns = 1
    @State private var rows = 1
    @State private var fps = 8.0
    @State private var declaredFrameCount: Int?
    @State private var gridProblem = ""
    var layout: SpriteSheetLayout? { spriteSheet ? try? SpriteSheetLayout(columns: columns, rows: rows, frameCount: declaredFrameCount, framesPerSecond: fps) : nil }
    var count: Int { min(layout?.frameCount ?? information?.frameCount ?? 1, FilePreviewLimits.imageFrames) }
    var sourceRect: CGRect? {
        guard let layout, let information else { return nil }
        return try? layout.frameRect(index: min(frame, count - 1), width: Int(information.size.width), height: Int(information.size.height))
    }
    var presentation: FilePreviewPresentation {
        var value = FilePreviewPresentation.resolved(kind: .image, metadata: metadata)
        value.nearestNeighbor = metadata["nearest_neighbor"] as? Bool ?? true
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            NativeImagePreview(url: url, presentation: presentation, frameIndex: spriteSheet ? 0 : min(frame, count - 1), sourceRect: sourceRect, onMetadata: { info in
                information = info; onReady()
            }).frame(minHeight: 240)
            if let information, information.frameCount > FilePreviewLimits.imageFrames { Text("Only the first 1,000 frames are available in this bounded viewer.").font(.caption).foregroundStyle(.orange) }
            Toggle("Sprite sheet", isOn: $spriteSheet).font(.caption).onChange(of: spriteSheet) { _, _ in frame = 0; playing = false }
            if spriteSheet {
                HStack {
                    Stepper("Columns: \(columns)", value: $columns, in: 1...32)
                    Stepper("Rows: \(rows)", value: $rows, in: 1...32)
                }.font(.caption).onChange(of: columns) { _, _ in gridChanged() }.onChange(of: rows) { _, _ in gridChanged() }
                if let information, let layout {
                    if (try? layout.frameRect(index: 0, width: Int(information.size.width), height: Int(information.size.height))) == nil {
                        Text("The grid does not divide this original into whole-pixel cells. The full sheet remains visible.").font(.caption).foregroundStyle(.orange)
                    }
                }
                if layout == nil { Text("The grid exceeds the 1,000-cell limit or the declared frame count is invalid.").font(.caption).foregroundStyle(.orange) }
            }
            if !gridProblem.isEmpty { Text(gridProblem).font(.caption).foregroundStyle(.orange) }
            if count > 1 {
                HStack {
                    Button(playing ? "Pause" : "Play") { playing.toggle() }.accessibilityLabel(playing ? "Pause image animation" : "Play image animation")
                    Button { playing = false; frame = (frame + count - 1) % count } label: { Image(systemName: "backward.frame") }.accessibilityLabel("Previous image frame")
                    Button { playing = false; frame = (frame + 1) % count } label: { Image(systemName: "forward.frame") }.accessibilityLabel("Next image frame")
                    Text("Frame \(frame + 1) / \(count)").font(.caption).monospacedDigit()
                }
                Slider(value: Binding(get: { Double(frame) }, set: { playing = false; frame = Int($0) }), in: 0...Double(count - 1), step: 1).accessibilityLabel("Image frame")
            }
        }.onAppear {
            if let raw = metadata["sprite_sheet"] as? [String: Any] {
                do { let grid = try SpriteSheetLayout.parse(raw); columns = grid.columns; rows = grid.rows; fps = grid.framesPerSecond; declaredFrameCount = grid.frameCount; spriteSheet = true }
                catch { gridProblem = "Invalid sprite metadata: " + error.localizedDescription }
            }
        }.task(id: playing) {
            guard playing else { return }
            do {
                while !Task.isCancelled {
                    let duration = spriteSheet ? 1 / fps : information?.frameDuration ?? 0.1
                    try await Task.sleep(for: .seconds(max(duration, 0.02)))
                    try Task.checkCancellation()
                    frame = (frame + 1) % max(count, 1)
                }
            } catch { }
        }.onDisappear { playing = false }
    }
    private func gridChanged() { declaredFrameCount = nil; frame = 0; playing = false; gridProblem = "" }
}
