import Foundation
import AppKit

/// Formatter instances are mutable. All use/reconfiguration is serialized, and
/// only String results leave the lock. No relative-age output is retained.
final class RelativeTimeFormatterCache: @unchecked Sendable {
    static let shared = RelativeTimeFormatterCache()
    private let lock = NSLock()
    private let parser: ISO8601DateFormatter
    /// Service timestamps may carry fractional seconds; the plain parser rejects them.
    private let fractionalParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser
    }()
    private let formatter: RelativeDateTimeFormatter
    private var context: (locale: Locale, calendar: Calendar)?

    init(makeParser: () -> ISO8601DateFormatter = { ISO8601DateFormatter() },
         makeFormatter: () -> RelativeDateTimeFormatter = { RelativeDateTimeFormatter() }) {
        parser = makeParser()
        formatter = makeFormatter()
    }

    func string(from value: String, now: Date = Date(), locale: Locale = .current,
                calendar: Calendar = .current) -> String {
        lock.lock()
        defer { lock.unlock() }
        // Preserve the existing parser options and invalid-input fallback.
        guard let date = parser.date(from: value) ?? fractionalParser.date(from: value) else { return value }
        if abs(date.timeIntervalSince(now)) < 5 { return "just now" }
        if context?.locale != locale || context?.calendar != calendar {
            formatter.calendar = calendar
            formatter.locale = locale
            context = (locale, calendar)
        }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Positive cache for service-owned immutable normalized thumbnails. Capacity is
/// deterministic; NSCache's advisory count/cost limits are not used as a bound.
@MainActor final class ProjectIconImageCache {
    static let shared = ProjectIconImageCache()
    private struct Key: Hashable {
        let project: [UInt8]
        let path: [UInt8]
        let asset: [UInt8]
        let checksum: [UInt8]
    }
    private let lock = NSLock()
    private let capacity: Int
    private let available: (String) -> Bool
    private let load: (String) -> NSImage?
    private var images: [Key: NSImage] = [:]
    private var recency: [Key] = []

    init(capacity: Int = 64,
         available: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
         load: @escaping (String) -> NSImage? = { NSImage(contentsOfFile: $0) }) {
        self.capacity = max(0, capacity)
        self.available = available
        self.load = load
    }

    func image(projectID: String, path: String, assetID: String?, checksum: String?) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        let project = Array(projectID.utf8)
        guard !path.isEmpty, available(path) else {
            remove(project: project)
            return nil
        }
        guard let assetID, !assetID.isEmpty, let checksum, !checksum.isEmpty else {
            // A legacy mutable path has no immutable byte identity. Preserve its
            // fresh-read behavior instead of inventing a watcher or revision rule.
            remove(project: project)
            return load(path)
        }
        let key = Key(project: project, path: Array(path.utf8), asset: Array(assetID.utf8), checksum: Array(checksum.utf8))
        if let image = images[key] {
            recency.removeAll { $0 == key }
            recency.append(key)
            return image
        }
        guard let image = load(path) else { return nil } // Failed loads are retryable.
        guard capacity > 0 else { return image }
        while images.count >= capacity, let oldest = recency.first {
            images.removeValue(forKey: oldest)
            recency.removeFirst()
        }
        images[key] = image
        recency.append(key)
        return image
    }

    var retainedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return images.count
    }

    private func remove(project: [UInt8]) {
        let removed = recency.filter { $0.project == project }
        for key in removed { images.removeValue(forKey: key) }
        recency.removeAll { $0.project == project }
    }
}
