import SwiftUI
import AppKit
import AVKit
import Combine
import ChecklistCore

/// Native take control. AVPlayer is the production adapter; tests use small fakes.
@MainActor protocol MediaTakeControl: AnyObject {
    func play()
    func pause()
    func unload()
}
extension MediaTakeControl { func unload() { pause() } }
extension AVPlayer: MediaTakeControl {}

/// Keeps the queue's replicas and looper alive while paused. Loop boundaries never
/// seek or replace the displayed player, avoiding an end notification/poster reset.
@MainActor final class MediaNativeTakeControl: MediaTakeControl {
    let player: AVQueuePlayer
    let playbackRate: Float
    private(set) var looper: AVPlayerLooper?
    private var rateObservation: AnyCancellable?
    private var endObservation: AnyCancellable?
    private var unloaded = false
    private var rewindGeneration = 0
    private var rewindPending = false

    init(asset: AVAsset, loop: Bool, playbackRate: Float) {
        self.playbackRate = playbackRate
        player = AVQueuePlayer()
        player.defaultRate = playbackRate
        let item = AVPlayerItem(asset: asset)
        if loop { looper = AVPlayerLooper(player: player, templateItem: item) }
        else { player.actionAtItemEnd = .pause; player.insert(item, after: nil) }
        // Native AVKit controls may change rate directly rather than call play().
        // Keep the declared game speed, but never turn a native Pause into Play.
        rateObservation = player.publisher(for: \.rate).receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.unloaded, self.player.rate > 0 else { return }
                // AVKit may call Play directly on a retained item at its end.
                // Seeking while already playing preserves a subsequent native Pause.
                _ = self.rewindAtEnd()
                if abs(self.player.rate - self.playbackRate) > 0.00001 { self.player.rate = self.playbackRate }
            }
        }
        if !loop {
            // Retain and rewind a completed single take for the next native Play.
            // This seek never starts playback; looping takes use only the looper.
            endObservation = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
                .receive(on: DispatchQueue.main).sink { [weak self] _ in
                    MainActor.assumeIsolated { _ = self?.rewindAtEnd() }
                }
        }
    }
    func play() {
        guard !unloaded else { return }
        _ = rewindAtEnd()
        // Start now and let AVFoundation preserve the requested rate during seek.
        // A later native Pause can never be overridden by a seek completion.
        player.play()
    }
    func pause() {
        rewindGeneration += 1; rewindPending = false
        player.pause(); player.currentItem?.cancelPendingSeeks()
    }
    private func rewindAtEnd() -> Bool {
        guard !unloaded, looper == nil, let item = player.currentItem else { return false }
        let duration = item.duration.seconds, time = item.currentTime().seconds
        guard duration.isFinite, duration > 0, time.isFinite, time >= duration - 0.001 else { return false }
        guard !rewindPending else { return true }
        rewindPending = true; rewindGeneration += 1
        let generation = rewindGeneration
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.unloaded, self.rewindGeneration == generation else { return }
                self.rewindPending = false
            }
        }
        return true
    }
    func unload() {
        guard !unloaded else { return }
        unloaded = true; rateObservation = nil; endObservation = nil; pause()
        looper?.disableLooping(); looper = nil
        player.removeAllItems()
    }
    isolated deinit { unload() }
}

struct MediaPlaybackTiming: Equatable, Sendable {
    let nominalFrameRate: Double?
    let declaredFrameRate: Double?
    let rate: Float

    init(nominalFrameRate: Double?, declaredFrameRate: Double?) throws {
        self.nominalFrameRate = nominalFrameRate; self.declaredFrameRate = declaredFrameRate
        guard let declaredFrameRate else { rate = 1; return }
        guard declaredFrameRate.isFinite, (1...240).contains(declaredFrameRate) else {
            throw FilePreviewFailure("The declared frame rate must be between 1 and 240 fps.")
        }
        guard let nominalFrameRate, nominalFrameRate.isFinite, nominalFrameRate > 0 else {
            throw FilePreviewFailure("The video has no measurable nominal frame rate. Supply a video rendition encoded at the stated frame rate.")
        }
        let requestedRate = declaredFrameRate / nominalFrameRate
        guard requestedRate > 0, requestedRate <= 2 else {
            throw FilePreviewFailure("The declared frame rate requires playback above 2× source speed. Supply a video rendition encoded at the stated frame rate.")
        }
        rate = Float(requestedRate)
    }

    /// The encoded cadence of one video track. AVFoundation's nominal rate can understate it:
    /// an 8-frame 12 fps H.264 take with reordered frames reported 10.67 fps, so each loop
    /// played at 1.125x. The minimum frame duration is the per-frame interval actually encoded.
    static func sourceFrameRate(nominal: Double?, minimumFrameDuration: Double?) -> Double? {
        if let minimumFrameDuration, minimumFrameDuration.isFinite, minimumFrameDuration > 0 { return 1 / minimumFrameDuration }
        return nominal
    }
}

struct MediaPlaybackMeasurement: Equatable, Sendable {
    var copyMilliseconds: Int
    var probeMilliseconds: Int
    var bytes: Int
    var facts: MediaPlaybackBudget.Facts
    var loop: Bool = false
    var timing: MediaPlaybackTiming? = nil
}

/// One verified, local, display-only take. Its copy is deleted when released.
/// Exact IDs bind the take to its candidate, slot, typed reference and attachment.
@MainActor final class MediaPreparedTake {
    let key: String
    let label: String
    let kind: String
    let ids: [String: String]
    let control: MediaTakeControl
    let player: AVPlayer?
    let file: AuthorizedPreviewFile?
    let measurement: MediaPlaybackMeasurement
    init(key: String, label: String, kind: String, ids: [String: String], control: MediaTakeControl, player: AVPlayer? = nil, file: AuthorizedPreviewFile? = nil, measurement: MediaPlaybackMeasurement) {
        self.key = key; self.label = label; self.kind = kind; self.ids = ids; self.control = control
        self.player = player; self.file = file; self.measurement = measurement
    }
    var details: MediaValues {
        var values: MediaValues = ["label": label, "kind": kind, "copy_ms": measurement.copyMilliseconds, "probe_ms": measurement.probeMilliseconds,
            "bytes": measurement.bytes, "duration_seconds": measurement.facts.durationSeconds, "width": measurement.facts.width,
            "height": measurement.facts.height, "estimated_frames": measurement.facts.frames, "loop": measurement.loop]
        if let timing = measurement.timing {
            values["playback_rate"] = timing.rate
            if let rate = timing.nominalFrameRate { values["source_nominal_frame_rate"] = rate }
            if let rate = timing.declaredFrameRate { values["declared_frame_rate"] = rate }
        }
        for (key, value) in ids { values[key] = value }
        return values
    }
}

/// Owns every loaded take: at most two verified copies within the shared cache budget,
/// one preparation at a time and exactly one playing take. Display state only.
@MainActor final class MediaPlaybackCoordinator: ObservableObject {
    @Published private(set) var takes: [String: MediaPreparedTake] = [:]
    @Published private(set) var playingKey: String?
    @Published private(set) var preparing: String?
    private var order: [String] = []
    private var observations: [String: AnyCancellable] = [:]

    var cachedBytes: Int { takes.values.reduce(0) { $0 + $1.measurement.bytes } }
    func beginPreparation(_ key: String) -> Bool {
        guard preparing == nil || preparing == key else { return false }
        preparing = key; return true
    }
    func endPreparation(_ key: String) { if preparing == key { preparing = nil } }
    /// Admits a prepared take, evicting the oldest non-playing take beyond the budget.
    func admit(_ take: MediaPreparedTake) {
        release(take.key)
        while !order.isEmpty, takes.count >= MediaPlaybackBudget.preparedTakes || cachedBytes + take.measurement.bytes > MediaPlaybackBudget.cacheBytes {
            release(order.first { $0 != playingKey } ?? order[0])
        }
        takes[take.key] = take; order.append(take.key)
        if let player = take.player {
            // Native inline controls may start playback directly; still keep one playing take.
            observations[take.key] = player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main).sink { [weak self, key = take.key] status in
                MainActor.assumeIsolated {
                    if status == .paused { self?.didStop(key) } else { self?.didStart(key) }
                }
            }
        }
    }
    func play(_ key: String) {
        guard let take = takes[key] else { return }
        didStart(key); take.control.play()
    }
    func pause(_ key: String) { takes[key]?.control.pause(); didStop(key) }
    func didStart(_ key: String) {
        guard takes[key] != nil else { return }
        for (other, take) in takes where other != key { take.control.pause() }
        playingKey = key
    }
    func didStop(_ key: String) { if playingKey == key { playingKey = nil } }
    func release(_ key: String) {
        guard let take = takes.removeValue(forKey: key) else { return }
        observations[key] = nil; take.control.unload(); take.player?.replaceCurrentItem(with: nil)
        order.removeAll { $0 == key }
        if playingKey == key { playingKey = nil }
    }
    func releaseAll(prefix: String = "") {
        for key in Array(takes.keys) where key.hasPrefix(prefix) { release(key) }
    }
}

/// Bounded exact-lease copy and native probe. Every lease is released after its copy,
/// including on refusal or cancellation; the copy is hash-verified against the slot digest.
enum MediaTakeLoader {
    struct Lease: Sendable { let id: String; let path: String; let size: Int; let name: String; let attachmentID: String }

    static func verifiedCopy(expectedSHA256: String, lease: @MainActor () async throws -> Lease,
                             release: @MainActor (String) async -> Void) async throws -> (AuthorizedPreviewFile, Int) {
        try Task.checkCancellation()
        let leased = try await lease()
        do {
            guard leased.size > 0, leased.size <= MediaPlaybackBudget.originalBytes, leased.path.hasPrefix("/") else {
                throw FilePreviewFailure("The original exceeds the 500 MiB playback bound or is unavailable.")
            }
            let source = try JSONSerialization.data(withJSONObject: ["id": leased.attachmentID, "size": leased.size, "sha256": expectedSHA256, "name": leased.name])
            let path = leased.path, start = ContinuousClock.now
            let work = Task.detached(priority: .userInitiated) {
                try AuthorizedPreviewFile.copy(path: path, source: Record(values: try JSONSerialization.jsonObject(with: source) as? [String: Any] ?? [:]))
            }
            let file = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            await release(leased.id)
            try Task.checkCancellation()
            return (file, milliseconds(ContinuousClock.now - start))
        } catch { await release(leased.id); throw error }
    }

    /// Measures the native asset against the declared kind's duration/pixel/frame budget.
    static func probe(url: URL, kind: String) async throws -> (AVURLAsset, MediaPlaybackBudget.Facts, Int) {
        let start = ContinuousClock.now
        let (asset, facts) = try await withThrowingTaskGroup(of: (AVURLAsset, MediaPlaybackBudget.Facts).self) { group in
            group.addTask { try await measure(url: url) }
            group.addTask {
                try await Task.sleep(for: .seconds(MediaPlaybackBudget.probeSeconds))
                throw FilePreviewFailure("The native decoder probe exceeded its \(Int(MediaPlaybackBudget.probeSeconds)) s budget.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
        try Task.checkCancellation()
        if let refusal = MediaPlaybackBudget.refusal(facts, kind: kind) { throw FilePreviewFailure(refusal) }
        return (asset, facts, milliseconds(ContinuousClock.now - start))
    }

    static func measure(url: URL) async throws -> (AVURLAsset, MediaPlaybackBudget.Facts) {
        let asset = try await NativePlaybackAsset.load(url: url)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video), audio = try await asset.loadTracks(withMediaType: .audio)
        var facts = MediaPlaybackBudget.Facts(durationSeconds: duration, hasVideo: !video.isEmpty, hasAudio: !audio.isEmpty)
        for track in video {
            let (size, rate) = try await track.load(.naturalSize, .nominalFrameRate)
            facts.width = max(facts.width, Int(abs(size.width).rounded())); facts.height = max(facts.height, Int(abs(size.height).rounded()))
            facts.frames = max(facts.frames, duration.isFinite ? Int((Double(rate) * duration).rounded(.up)) : Int.max)
        }
        return (asset, facts)
    }

    static func timing(asset: AVAsset, frameRate: Double?) async throws -> MediaPlaybackTiming {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        var sourceRate: Double?
        if let track = tracks.first {
            let (nominal, minimum) = try await track.load(.nominalFrameRate, .minFrameDuration)
            sourceRate = MediaPlaybackTiming.sourceFrameRate(nominal: Double(nominal), minimumFrameDuration: minimum.seconds)
        }
        return try MediaPlaybackTiming(nominalFrameRate: sourceRate, declaredFrameRate: frameRate)
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}

enum MediaPlaybackLabels {
    static func measurement(_ value: MediaPlaybackMeasurement) -> String {
        let facts = value.facts
        var parts = [String(format: "%.1f s", facts.durationSeconds)]
        if facts.hasVideo { parts.append("\(facts.width)×\(facts.height) px"); parts.append("\(facts.frames) estimated frames") }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(value.bytes), countStyle: .file))
        parts.append("verified in \(value.copyMilliseconds) ms, probed in \(value.probeMilliseconds) ms")
        return "Measured: " + parts.joined(separator: " · ")
    }
    static func playback(loop: Bool, frameRate: Double?) -> String {
        let mode = loop ? "Loops" : "Plays once"
        return mode + (frameRate.map { " at " + String(format: "%g", $0) + " fps" } ?? " at source speed")
    }
}

/// Audio/video take adapter selected by the slot's declared portable kind.
struct MediaPlaybackSlotView: View {
    @ObservedObject var model: MediaReviewModel
    @ObservedObject var playback: MediaPlaybackCoordinator
    let slot: Record
    let original: Record
    let example: Record?
    let kind: String
    let label: String
    var loop: Bool = false
    var frameRate: Double? = nil
    @State private var request = 0
    @State private var status = ""
    var key: String { (example == nil ? "current:" : "example:") + original.string("reference_id") + ":" + slot.string("slot_id") }
    var noun: String { kind == "audio" ? "audio" : "video" }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let take = playback.takes[key], let player = take.player {
                NativePlayerAdapter(player: player, audio: kind == "audio").frame(minWidth: 200, minHeight: kind == "audio" ? 60 : 160, maxHeight: kind == "audio" ? 80 : 300)
                    .accessibilityLabel(label + ", " + noun + " playback")
                ViewThatFits(in: .horizontal) {
                    HStack { controls }
                    VStack(alignment: .leading) { controls }
                }
                Text(MediaPlaybackLabels.playback(loop: take.measurement.loop, frameRate: take.measurement.timing?.declaredFrameRate))
                    .font(.caption).accessibilityLabel("Playback: " + MediaPlaybackLabels.playback(loop: take.measurement.loop, frameRate: take.measurement.timing?.declaredFrameRate))
                Text(MediaPlaybackLabels.measurement(take.measurement)).font(.caption).foregroundStyle(Color.checklistSecondaryText).textSelection(.enabled)
            } else {
                Text(status.isEmpty ? "Take not loaded" : status).foregroundStyle(Color.checklistSecondaryText).textSelection(.enabled)
                Button("Play") { request += 1 }
                    .accessibilityLabel("Play " + label + "; loads exact " + noun + " take and pauses other takes")
                    .checklistDisabled([(playback.preparing != nil && playback.preparing != key, "Another take is being prepared. Wait for it to finish.")])
            }
            Button("Open original") { Task { await openOriginal() } }
                .accessibilityLabel("Open original, " + label)
                .help("Requests a fresh exact lease and opens a verified copy. Edits do not change the reviewed original.")
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("mediaTake:" + original.string("reference_id"))
        // Leaving view cancels its preparation; the lease is released and the copy discarded.
        .task(id: request) { if request > 0 { await load() } }
        .onChange(of: loop) { _, _ in playback.release(key); if request > 0 { request += 1 } }
        .onChange(of: frameRate) { _, _ in playback.release(key); if request > 0 { request += 1 } }
        .onDisappear { playback.release(key) }
    }
    @ViewBuilder var controls: some View {
        if playback.playingKey == key { Button("Pause") { playback.pause(key) }.accessibilityLabel("Pause " + label) }
        else { Button("Play") { playback.play(key) }.accessibilityLabel("Play " + label + "; other takes pause") }
        Button("Unload take") { playback.release(key) }.accessibilityLabel("Unload take, " + label)
    }
    func load() async {
        guard playback.beginPreparation(key) else { status = "Another take is being prepared."; return }
        defer { playback.endPreparation(key) }
        status = "Requesting the exact original…"
        do {
            let (file, copyMilliseconds) = try await MediaTakeLoader.verifiedCopy(expectedSHA256: slot.string("sha256", fallback: original.string("sha256")),
                lease: { try await model.playbackLease(original: original, example: example) }, release: { await model.releasePlaybackLease($0) })
            status = "Measuring the verified " + noun + "…"
            let (asset, facts, probeMilliseconds) = try await MediaTakeLoader.probe(url: file.url, kind: kind)
            let timing = try await MediaTakeLoader.timing(asset: asset, frameRate: frameRate)
            try Task.checkCancellation()
            let control = MediaNativeTakeControl(asset: asset, loop: loop, playbackRate: timing.rate)
            var ids = ["slot_id": slot.string("slot_id"), "reference_id": original.string("reference_id"), "attachment_id": original.string("attachment_id"), "sha256": slot.string("sha256")]
            if let example { ids["target_id"] = example.string("target_id"); ids["decision_id"] = example.string("decision_id") }
            else { ids["target_id"] = model.item.object("target")["id"] as? String ?? "" }
            playback.admit(MediaPreparedTake(key: key, label: label, kind: kind, ids: ids, control: control, player: control.player, file: file,
                measurement: .init(copyMilliseconds: copyMilliseconds, probeMilliseconds: probeMilliseconds, bytes: (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? original.integer("size", fallback: 0), facts: facts, loop: loop, timing: timing)))
            playback.play(key)
            status = ""
        } catch is CancellationError { status = "Loading stopped."
        } catch { status = "Original unavailable or unsupported: " + PlainError.text(error) }
    }
    func openOriginal() async {
        status = "Reauthorizing the exact original…"
        do {
            let (file, _) = try await MediaTakeLoader.verifiedCopy(expectedSHA256: slot.string("sha256", fallback: original.string("sha256")),
                lease: { try await model.playbackLease(original: original, example: example) }, release: { await model.releasePlaybackLease($0) })
            let copy = try file.externalWorkingCopy()
            NSWorkspace.shared.open(copy)
            status = "Opened a verified copy. Edits do not change the reviewed original or record a decision."
        } catch { status = "Original unavailable: " + PlainError.text(error) }
    }
}

/// Exact take IDs and measurements for TechnicalDetails; display state only.
struct MediaTakeDetails: View {
    @ObservedObject var playback: MediaPlaybackCoordinator
    var body: some View {
        if !playback.takes.isEmpty {
            TechnicalDetails(raw: [("Loaded takes", playback.takes.keys.sorted().compactMap { playback.takes[$0]?.details } as [MediaValues])])
        }
    }
}
