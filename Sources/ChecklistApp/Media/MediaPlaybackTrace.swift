import AVFoundation
import CoreVideo
import QuartzCore

/// Opt-in qualification evidence from the existing player's video output. This is
/// not a compositor/physical-display receipt. In particular, a delayed observer
/// cannot establish whether a sample was presented while that observer was away.
final class MediaPlaybackTrace: @unchecked Sendable {
    static let configuredDirectory = directory(arguments: ProcessInfo.processInfo.arguments,
                                               environment: ProcessInfo.processInfo.environment)

    static func directory(arguments: [String], environment: [String: String]) -> URL? {
        let path: String?
        if let index = arguments.firstIndex(of: "-ChecklistPlaybackTraceDirectory") {
            path = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        } else { path = environment["CHECKLIST_PLAYBACK_TRACE_DIR"] }
        guard let path, path.hasPrefix("/"), path != "/" else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    struct Position: Equatable, Sendable {
        let cycle: Int
        let sourceSeconds: Double
        let estimatedFrame: Int?
    }

    static func position(presentationSeconds: Double, sourceDuration: Double, frameRate: Double?) -> Position? {
        guard presentationSeconds.isFinite, presentationSeconds >= 0, sourceDuration.isFinite, sourceDuration > 0 else { return nil }
        let cycle = floor((presentationSeconds + 0.0000001) / sourceDuration)
        guard cycle < Double(Int.max) else { return nil }
        let source = max(0, presentationSeconds - cycle * sourceDuration)
        let frame = frameRate.flatMap { rate -> Int? in
            guard rate.isFinite, rate > 0, source * rate < Double(Int.max) else { return nil }
            return Int(floor(source * rate + 0.000001))
        }
        return Position(cycle: Int(cycle), sourceSeconds: source, estimatedFrame: frame)
    }

    @MainActor static func make(directory: URL, item: AVPlayerItem, source: AVURLAsset,
                                rate: Float, label: String) async throws -> MediaPlaybackTrace? {
        guard let track = try await source.loadTracks(withMediaType: .video).first else { return nil }
        let (nominal, minimum) = try await track.load(.nominalFrameRate, .minFrameDuration)
        let sourceDuration = try await source.load(.duration).seconds
        let timelineDuration = try await item.asset.load(.duration).seconds
        let frameRate = MediaPlaybackTiming.sourceFrameRate(nominal: Double(nominal), minimumFrameDuration: minimum.seconds)
        let trace = try MediaPlaybackTrace(directory: directory, label: label, sourceDuration: sourceDuration,
                                          frameRate: frameRate, timelineDuration: timelineDuration, rate: rate)
        item.add(trace.output)
        do { try trace.start() }
        catch { item.remove(trace.output); trace.stop(); throw error }
        return trace
    }

    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    let fileURL: URL
    private let sourceDuration: Double
    private let frameRate: Double?
    private var displayLink: CVDisplayLink?
    private let sink: Sink
    private let lock = NSLock()
    private var stopped = false
    private var sequence = 0
    private var lastCallbackHost: Double?

    /// Queue closures retain only the sink, so releasing the tracer can always
    /// drain the writer without its deinit running on that same writer queue.
    private final class Sink: @unchecked Sendable {
        let queue = DispatchQueue(label: "org.checklist.playback-trace", qos: .utility)
        let file: FileHandle
        var failed = false // accessed only by queue
        init(file: FileHandle) { self.file = file }
        func append(_ row: [String: any Sendable]) {
            queue.async { [self] in
                guard !failed else { return }
                var written = row; written["write_host_seconds"] = CACurrentMediaTime()
                do {
                    var data = try JSONSerialization.data(withJSONObject: written, options: [.sortedKeys])
                    data.append(10); try file.write(contentsOf: data)
                } catch {
                    failed = true
                    NSLog("Checklist playback trace failed: %@", error.localizedDescription)
                }
            }
        }
        func close() { queue.sync { try? file.synchronize(); try? file.close() } }
    }

    init(directory: URL, label: String, sourceDuration: Double, frameRate: Double?, timelineDuration: Double, rate: Float) throws {
        self.sourceDuration = sourceDuration; self.frameRate = frameRate
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("playback-\(UUID().uuidString).jsonl")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw FilePreviewFailure("The playback trace file could not be created.")
        }
        sink = Sink(file: try FileHandle(forWritingTo: fileURL))
        output.suppressesPlayerRendering = false
        var metadata: [String: any Sendable] = [
            "event": "metadata", "schema_version": 1, "label": label,
            "source_duration_seconds": sourceDuration, "timeline_duration_seconds": timelineDuration,
            "playback_rate": rate, "pid": ProcessInfo.processInfo.processIdentifier,
            "clock": "mach_absolute_time_seconds", "wall_unix_seconds": Date().timeIntervalSince1970,
            "evidence": "AVPlayerItemVideoOutput; not AVPlayerLayer presentation or physical scan-out",
            "frame_index": "estimated from output PTS and source cadence; use pixels for numbered CFR fixtures"
        ]
        if let frameRate, frameRate.isFinite { metadata["source_frame_rate"] = frameRate }
        record(metadata)
    }

    private func start() throws {
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else {
            throw FilePreviewFailure("The playback trace display link could not be created.")
        }
        displayLink = link
        guard CVDisplayLinkSetOutputHandler(link, { [weak self] _, _, outputTime, _, _ in
            self?.sample(outputHost: Double(outputTime.pointee.hostTime) / CVGetHostClockFrequency())
            return kCVReturnSuccess
        }) == kCVReturnSuccess, CVDisplayLinkStart(link) == kCVReturnSuccess else {
            throw FilePreviewFailure("The playback trace display link could not start.")
        }
    }

    private func sample(outputHost: Double) {
        let host = CACurrentMediaTime()
        let requestedTime = output.itemTime(forHostTime: outputHost)
        var row: [String: any Sendable] = ["event": "poll", "host_seconds": host, "output_host_seconds": outputHost]
        if requestedTime.isNumeric { row["requested_item_seconds"] = requestedTime.seconds }
        if let lastCallbackHost { row["observer_gap_ms"] = (host - lastCallbackHost) * 1000 }
        lastCallbackHost = host
        let hasNew = requestedTime.isNumeric && output.hasNewPixelBuffer(forItemTime: requestedTime)
        row["has_new_buffer"] = hasNew
        if hasNew {
            var presentation = CMTime.invalid
            if let pixels = output.copyPixelBuffer(forItemTime: requestedTime, itemTimeForDisplay: &presentation) {
                row["event"] = "video_output"
                if presentation.isNumeric {
                    row["presentation_seconds"] = presentation.seconds
                    if let position = Self.position(presentationSeconds: presentation.seconds, sourceDuration: sourceDuration, frameRate: frameRate) {
                        row["cycle"] = position.cycle; row["source_seconds"] = position.sourceSeconds
                        if let frame = position.estimatedFrame { row["estimated_source_frame"] = frame }
                    }
                }
                row["pixel_bgra"] = Self.pixelProbe(pixels)
            } else { row["event"] = "null_buffer" }
        }
        record(row)
    }

    /// Three source-raster probes are enough to identify the synthetic colored
    /// fixture, without a full-frame hash/retained pixel buffer on the observer.
    private static func pixelProbe(_ buffer: CVPixelBuffer) -> [[Int]] {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0 else { return [] }
        return [0.25, 0.5, 0.75].map { fraction in
            let x = min(width - 1, Int(Double(width) * fraction)), y = min(height - 1, Int(Double(height) * fraction))
            let pixel = base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
            return [x, y, Int(pixel[0]), Int(pixel[1]), Int(pixel[2]), Int(pixel[3])]
        }
    }

    func event(_ event: String, fields: [String: any Sendable] = [:]) {
        var row = fields; row["event"] = event; record(row)
    }

    private func record(_ fields: [String: any Sendable]) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        sequence += 1
        var row = fields
        row["sequence"] = sequence
        if row["host_seconds"] == nil { row["host_seconds"] = CACurrentMediaTime() }
        sink.append(row)
    }

    func stop() {
        if let displayLink { CVDisplayLinkStop(displayLink) }
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        sink.close()
    }

    deinit { stop() }
}
