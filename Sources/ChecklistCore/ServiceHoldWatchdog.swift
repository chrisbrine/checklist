import Foundation

/// Service-process instrumentation. Labels identify code paths only.
public final class ServiceHoldWatchdog: @unchecked Sendable {
    public struct Hold: Sendable {
        public let startedAt: Date
        public let durationMS: Double
        public let resource: String
        public let work: String
        public let activities: [String: Double]
        public let active: Bool

        var json: JSON {
            ["started_at": StoredClock.shared.string(from: startedAt),
             "duration_ms": durationMS, "resource": resource, "work": work, "active": active]
        }
    }

    private struct Occupancy {
        let resource: String
        let work: String
        let date: Date
        let uptime: TimeInterval
        var reported = false

        func hold(at now: TimeInterval, active: Bool, activities: [String: Double] = [:]) -> Hold {
            Hold(startedAt: date, durationMS: (now - uptime) * 1000,
                 resource: resource, work: work, activities: activities, active: active)
        }
    }

    public static let shared = ServiceHoldWatchdog()
    private static let workKey = "ChecklistServiceHoldWork"
    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private var sink: (@Sendable (Hold) -> Void)?
    private var maximumSink: (@Sendable (Hold) -> Void)?
    private var maxima: [String: [String: Double]] = [:]
    private var occupied: [UInt64: Occupancy] = [:]
    private var recent: [Hold] = []
    private var nextID: UInt64 = 0

    public init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "org.checklist.hold-watchdog", qos: .utility))
        timer.setEventHandler { [weak self] in self?.reportActive() }
        timer.activate()
    }

    public func observe(_ sink: @escaping @Sendable (Hold) -> Void, maximum: (@Sendable (Hold) -> Void)? = nil) {
        lock.withLock {
            self.sink = sink
            maximumSink = maximum
        }
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(25))
    }

    public static func withWorkLabel<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[workKey]
        dictionary[workKey] = label
        defer { dictionary[workKey] = previous }
        return try body()
    }

    static func workLabel(fallback: String) -> String {
        Thread.current.threadDictionary[workKey] as? String ?? fallback
    }

    public func begin(resource: String, work: String) -> UInt64? {
        lock.withLock {
            guard sink != nil else { return nil }
            nextID += 1
            occupied[nextID] = Occupancy(resource: resource, work: work, date: Date(),
                                         uptime: ProcessInfo.processInfo.systemUptime)
            return nextID
        }
    }

    public func end(_ id: UInt64?, activities: [String: Double] = [:]) {
        guard let id else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            guard let occupancy = occupied.removeValue(forKey: id) else { return }
            let hold = occupancy.hold(at: now, active: false, activities: activities)
            if let maximumSink, hold.durationMS > (maxima[hold.resource]?[hold.work] ?? 0) {
                maxima[hold.resource, default: [:]][hold.work] = hold.durationMS
                maximumSink(hold)
            }
            guard hold.durationMS > 1000 else { return }
            recent.append(hold)
            if recent.count > 64 { recent.removeFirst() }
            sink?(hold)
        }
    }

    private func reportActive() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            for id in Array(occupied.keys) {
                guard var occupancy = occupied[id], !occupancy.reported, now - occupancy.uptime > 1 else { continue }
                occupancy.reported = true
                occupied[id] = occupancy
                sink?(occupancy.hold(at: now, active: true))
            }
        }
    }

    public var status: [String: Any] {
        let now = ProcessInfo.processInfo.systemUptime
        let pair = lock.withLock {
            (occupied.values.filter { now - $0.uptime > 1 }.map { $0.hold(at: now, active: true) }, recent)
        }
        return ["active": pair.0.sorted { $0.startedAt < $1.startedAt }.map(\.json),
                "recent": pair.1.map(\.json)]
    }
}
