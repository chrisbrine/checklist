import Foundation
import Dispatch
import Darwin
import ChecklistCore
import ChecklistIPC

/// Every entry to the coordinator queue records its actual occupied interval.
/// File IO runs on a separate lane, so diagnostics cannot extend that interval.
final class ServiceCommandQueue: @unchecked Sendable {
    let dispatchQueue = DispatchQueue(label: "org.checklist.commands", autoreleaseFrequency: .workItem)
    let busyPeriods: CommandQueueBusyPeriods
    private let watchdog: ServiceHoldWatchdog?
    private var activities: [String: Double] = [:]
    var didCompletePeriod: ((String, Double, [String: Double]) -> Void)?

    init(logURL: URL, serviceBusyPeriods: CommandQueueBusyPeriods? = nil) {
        busyPeriods = serviceBusyPeriods ?? CommandQueueBusyPeriods(url: logURL)
        watchdog = serviceBusyPeriods == nil ? nil : .shared
    }

    func async(source: String = #fileID, line: Int = #line, function: String = #function,
               execute work: @escaping @Sendable () -> Void) {
        async(work: "\(function) [\(source):\(line)]", execute: work)
    }

    func async(work label: String, execute work: @escaping @Sendable () -> Void) {
        dispatchQueue.async { self.perform(work: label, work) }
    }

    func sync<T>(source: String = #fileID, line: Int = #line, function: String = #function,
                 execute work: () throws -> T) rethrows -> T {
        try dispatchQueue.sync { try perform(work: "\(function) [\(source):\(line)]", work) }
    }

    func asyncAfter(deadline: DispatchTime, source: String = #fileID, line: Int = #line,
                    function: String = #function, execute work: @escaping @Sendable () -> Void) {
        dispatchQueue.asyncAfter(deadline: deadline) { self.perform(work: "\(function) [\(source):\(line)]", work) }
    }

    func asyncAfter(deadline: DispatchTime, source: String = #fileID, line: Int = #line,
                    function: String = #function, execute work: DispatchWorkItem) {
        dispatchQueue.asyncAfter(deadline: deadline) {
            guard !work.isCancelled else { return }
            self.perform(work: "\(function) [\(source):\(line)]") { work.perform() }
        }
    }

    /// Dispatch sources use the underlying queue and enter through this wrapper.
    func perform<T>(work: String, _ body: () throws -> T) rethrows -> T {
        dispatchPrecondition(condition: .onQueue(dispatchQueue))
        let start = ProcessInfo.processInfo.systemUptime, date = Date()
        let hold = watchdog?.begin(resource: "command_queue", work: work)
        activities = [:]
        defer {
            let duration = ProcessInfo.processInfo.systemUptime - start
            if let watchdog {
                watchdog.end(hold, activities: activities)
            } else if duration > 1 {
                busyPeriods.record(startedAt: date, durationMS: duration * 1000, work: work, activities: activities)
            }
            didCompletePeriod?(work, duration * 1000, activities)
            activities = [:]
        }
        return try body()
    }

    /// Method names and fixed phase labels only. No arguments or caller identity.
    func activity<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        defer { activities[name, default: 0] += (ProcessInfo.processInfo.systemUptime - start) * 1000 }
        return try body()
    }
}

/// A bounded diagnostic file outside the database and managed store. The last 64
/// completed intervals survive service restart and can be read with ordinary tools.
final class CommandQueueBusyPeriods: @unchecked Sendable {
    struct Period: Codable {
        let started_at: String
        let duration_ms: Double
        let work: String
        let activities_ms: [String: Double]
        let resource: String?
        let active: Bool?
    }
    let url: URL
    private let lane = DispatchQueue(label: "org.checklist.command-queue-diagnostics", qos: .utility, autoreleaseFrequency: .workItem)
    private var periods: [Period] = []

    init(url: URL) {
        self.url = url
        lane.async { [self] in
            // Refuse an unbounded or non-regular preexisting diagnostic file.
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               attributes[.type] as? FileAttributeType == .typeRegular,
               let size = attributes[.size] as? NSNumber, size.intValue <= 256 * 1024,
               let data = try? Data(contentsOf: url),
               let previous = try? JSONDecoder().decode([Period].self, from: data) {
                periods = Array(previous.suffix(64))
            }
        }
    }

    func record(_ hold: ServiceHoldWatchdog.Hold) {
        record(startedAt: hold.startedAt, durationMS: hold.durationMS, work: hold.work,
               activities: hold.activities, resource: hold.resource, active: hold.active)
    }

    func recordMaximum(_ hold: ServiceHoldWatchdog.Hold) {
        lane.async {
            var averages = [Double](repeating: 0, count: 3)
            let sampleCount = getloadavg(&averages, 3)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            CallTimingLog.write([
                "scope": "service_hold_maximum", "resource": hold.resource, "work": hold.work,
                "duration_ms": hold.durationMS, "started_at": formatter.string(from: hold.startedAt),
                "observed_at": formatter.string(from: Date()), "loadavg": Array(averages.prefix(max(0, Int(sampleCount))))
            ])
        }
    }

    func record(startedAt: Date, durationMS: Double, work: String, activities: [String: Double],
                resource: String? = nil, active: Bool? = nil) {
        lane.async { [self] in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            periods.append(Period(started_at: formatter.string(from: startedAt), duration_ms: durationMS,
                                  work: work, activities_ms: activities, resource: resource, active: active))
            periods = Array(periods.suffix(64))
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let data = try JSONEncoder().encode(periods)
                try data.write(to: url, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                fputs("ChecklistService: could not persist command queue busy periods: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    func flush() { lane.sync {} }

    static func logURL(slot: Int?) -> URL {
        let name = slot.map { "service-command-queue-test\($0).json" } ?? "service-command-queue.json"
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Checklist").appendingPathComponent(name)
    }
}
