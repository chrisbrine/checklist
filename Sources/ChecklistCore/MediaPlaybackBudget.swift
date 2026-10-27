import Foundation

/// Explicit bounds shared by byte-only intake validation and the native comparison
/// adapters. These are display/decode budgets, never review authority.
public enum MediaPlaybackBudget {
    public static let originalBytes = 500 * 1024 * 1024
    public static let videoSeconds = 600.0
    public static let audioSeconds = 1800.0
    public static let videoPixels = 3840 * 2160
    public static let videoEdge = 8192
    public static let videoFrames = 36_000
    /// Verified playback copies retained at once (current and historical side).
    public static let preparedTakes = 2
    public static let cacheBytes = 1024 * 1024 * 1024
    public static let concurrentPreparations = 1
    public static let playingTakes = 1
    /// Native decoder probe (asset load, tracks, duration) wall-clock limit.
    public static let probeSeconds = 15.0
    /// Short reader lease; each Open original or load requests a fresh exact lease.
    public static let leaseSeconds = 60

    public struct Facts: Equatable, Sendable {
        public var durationSeconds: Double
        public var width: Int
        public var height: Int
        public var frames: Int
        public var hasVideo: Bool
        public var hasAudio: Bool
        public init(durationSeconds: Double, width: Int = 0, height: Int = 0, frames: Int = 0, hasVideo: Bool, hasAudio: Bool) {
            self.durationSeconds = durationSeconds; self.width = width; self.height = height
            self.frames = frames; self.hasVideo = hasVideo; self.hasAudio = hasAudio
        }
    }

    /// Returns a plain refusal for measured facts outside the declared kind's budget.
    public static func refusal(_ facts: Facts, kind: String) -> String? {
        guard facts.durationSeconds.isFinite, facts.durationSeconds > 0 else { return "The original has no measurable duration." }
        switch kind {
        case "video":
            guard facts.hasVideo else { return "The original has no video track." }
            guard facts.durationSeconds <= videoSeconds else { return "The video lasts \(Int(facts.durationSeconds.rounded())) s; the comparison limit is \(Int(videoSeconds)) s." }
            guard facts.width > 0, facts.height > 0, facts.width <= videoEdge, facts.height <= videoEdge,
                  facts.width <= videoPixels / facts.height else { return "The video is \(facts.width)×\(facts.height) pixels; the comparison limit is 3840×2160 pixels (8,294,400)." }
            guard facts.frames <= videoFrames else { return "The video has \(facts.frames) frames; the comparison limit is \(videoFrames) frames." }
            return nil
        case "audio":
            guard facts.hasAudio, !facts.hasVideo else { return "The original is not an audio-only take." }
            guard facts.durationSeconds <= audioSeconds else { return "The audio lasts \(Int(facts.durationSeconds.rounded())) s; the comparison limit is \(Int(audioSeconds)) s." }
            return nil
        default: return "This media format is not supported."
        }
    }
}

/// Byte-only ISO base media (MP4/M4V/QuickTime) validation. It never decodes, follows
/// a data reference, reference movie, playlist or remote URL. Only self-contained
/// movies within the shared budget pass; codec support is probed natively later.
public enum MediaIntakeMovie {
    private static let brands: Set<String> = ["isom", "iso2", "iso4", "iso5", "iso6", "mp41", "mp42", "avc1", "M4V ", "M4VH", "M4VP", "qt  "]
    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "dinf", "stbl", "edts"]
    private static let refused: Set<String> = ["rmra", "rmda", "cmov", "moof", "mvex", "sidx"]

    public static func inspect(_ data: Data) -> MediaPlaybackBudget.Facts? {
        let bytes = [UInt8](data)
        guard bytes.count >= 16, bytes.count <= MediaPlaybackBudget.originalBytes else { return nil }
        struct Track { var handler = ""; var width = 0; var height = 0; var samples = 0 }
        var boxes = 0, timescale = 0, duration = 0, movieHeader = false, mediaData = false
        var tracks: [Track] = []
        func u32(_ i: Int) -> Int { Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3]) }
        func u64(_ i: Int) -> Int? {
            let high = u32(i), low = u32(i + 4)
            guard high < 1 << 31 else { return nil }
            return high << 32 | low
        }
        func type(_ i: Int) -> String { String(decoding: bytes[i..<(i + 4)], as: UTF8.self) }
        // Returns false for any malformed, external or unsupported structure.
        func walk(_ start: Int, _ end: Int, depth: Int, parent: String) -> Bool {
            var index = start
            while index < end {
                boxes += 1
                guard boxes <= 100_000, depth <= 8, end - index >= 8 else { return false }
                var size = u32(index), header = 8
                let name = type(index + 4)
                if size == 1 {
                    guard end - index >= 16, let large = u64(index + 8) else { return false }
                    size = large; header = 16
                } else if size == 0 {
                    guard depth == 0 else { return false }
                    size = end - index
                }
                guard size >= header, size <= end - index else { return false }
                let body = index + header, stop = index + size
                guard !refused.contains(name) else { return false }
                if depth == 0 && index == 0 {
                    guard name == "ftyp", stop - body >= 8, brands.contains(type(body)) else { return false }
                }
                switch name {
                case _ where containers.contains(name):
                    if name == "trak" {
                        guard parent == "moov", tracks.count < 8 else { return false }
                        tracks.append(Track())
                    }
                    guard walk(body, stop, depth: depth + 1, parent: name) else { return false }
                case "mvhd":
                    guard parent == "moov", !movieHeader, stop - body >= 32 else { return false }
                    movieHeader = true
                    if bytes[body] == 1 { timescale = u32(body + 20); guard let value = u64(body + 24) else { return false }; duration = value }
                    else { timescale = u32(body + 12); duration = u32(body + 16) }
                case "tkhd":
                    guard parent == "trak", !tracks.isEmpty else { return false }
                    let offset = bytes[body] == 1 ? 88 : 76
                    guard stop - body >= offset + 8 else { return false }
                    tracks[tracks.count - 1].width = u32(body + offset) >> 16
                    tracks[tracks.count - 1].height = u32(body + offset + 4) >> 16
                case "hdlr":
                    guard stop - body >= 12 else { return false }
                    if parent == "mdia", !tracks.isEmpty { tracks[tracks.count - 1].handler = type(body + 8) }
                case "stsz":
                    guard parent == "stbl", !tracks.isEmpty, stop - body >= 12 else { return false }
                    tracks[tracks.count - 1].samples = u32(body + 8)
                case "dref":
                    // Every data reference must be the self-contained flag without a location.
                    guard parent == "dinf", stop - body >= 8 else { return false }
                    let count = u32(body + 4)
                    var entry = body + 8, seen = 0
                    while entry < stop {
                        guard stop - entry >= 12 else { return false }
                        let entrySize = u32(entry), entryType = type(entry + 4)
                        guard entrySize == 12, ["url ", "alis"].contains(entryType), bytes[entry + 11] & 1 == 1 else { return false }
                        entry += entrySize; seen += 1
                    }
                    guard seen == count, seen > 0 else { return false }
                case "mdat":
                    guard depth == 0 else { return false }
                    mediaData = mediaData || stop > body
                default: break
                }
                index = stop
            }
            return index == end
        }
        guard walk(0, bytes.count, depth: 0, parent: ""), movieHeader, mediaData, timescale > 0, duration > 0 else { return nil }
        let video = tracks.filter { $0.handler == "vide" }, audio = tracks.contains { $0.handler == "soun" }
        guard let first = video.first, tracks.allSatisfy({ ["vide", "soun"].contains($0.handler) }) else { return nil }
        let facts = MediaPlaybackBudget.Facts(durationSeconds: Double(duration) / Double(timescale),
            width: video.map(\.width).max() ?? first.width, height: video.map(\.height).max() ?? first.height,
            frames: video.map(\.samples).max() ?? 0, hasVideo: true, hasAudio: audio)
        return MediaPlaybackBudget.refusal(facts, kind: "video") == nil ? facts : nil
    }
}
