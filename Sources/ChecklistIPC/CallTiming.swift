import Foundation
import os

/// Optional diagnostics outside command parameters and durable receipts.
/// Durations use the monotonic clock; no credentials, workspace or caller IDs.
public enum CallTimingLog {
    public static var enabled: Bool { ProcessInfo.processInfo.environment["CHECKLIST_TIMING"] == "1" }

    public static func write(_ fields: [String: Any], to output: FileHandle = .standardError) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        var line = Data("ChecklistTiming ".utf8); line.append(bytes); line.append(0x0a)
        output.write(line)
    }
}

/// One request owns this value through its serial and off-queue phases.
public final class ServiceCallTiming: Sendable {
    public let requestID = UUID().uuidString.lowercased()
    private let received: TimeInterval
    private let durations = OSAllocatedUnfairLock(initialState: ["queue_wait_ms": 0.0, "bootstrap_verification_ms": 0.0, "execution_ms": 0.0])

    public init(received: TimeInterval = ProcessInfo.processInfo.systemUptime) { self.received = received }
    public func queued(since start: TimeInterval) {
        durations.withLock { $0["queue_wait_ms", default: 0] += (ProcessInfo.processInfo.systemUptime - start) * 1000 }
    }
    public func measure<T>(_ phase: String, _ body: () throws -> T) rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        defer { durations.withLock { $0[phase, default: 0] += (ProcessInfo.processInfo.systemUptime - start) * 1000 } }
        return try body()
    }

    public static func measure<T>(_ timing: ServiceCallTiming?, _ phase: String, _ body: () throws -> T) rethrows -> T {
        guard let timing else { return try body() }
        return try timing.measure(phase,body)
    }

    /// Encode the semantic envelope exactly once. Append the small diagnostics
    /// member separately so its encoding does not double the cost of large replies.
    /// encoding_ms covers the semantic envelope; total_ms ends before the trailer.
    public func encode(_ result: [String: Any]) throws -> Data {
        let start = ProcessInfo.processInfo.systemUptime
        var bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        var fields: [String:Any] = durations.withLock { $0 }
        fields["request_id"] = requestID
        fields["encoding_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
        fields["total_ms"] = (ProcessInfo.processInfo.systemUptime - received) * 1000
        let trailer = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        bytes.removeLast()
        if !result.isEmpty { bytes.append(0x2c) }
        bytes.append(Data("\"_checklist_timing\":".utf8)); bytes.append(trailer); bytes.append(0x7d)
        return bytes
    }
}
