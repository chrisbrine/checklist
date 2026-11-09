import Foundation
import Darwin
import os

/// One command's monotonic phase boundaries. Payload and source paths never
/// enter the log. Per-file progress is deliberately excluded.
final class StoragePhaseTiming {
    static let events: Set<String> = [
        "writer_lease_acquired", "writer_lease_released", "backup_done", "capture_released",
        "inventory_started", "inventory_finished", "copying_objects", "objects_finished",
        "directories_synchronized", "manifest_written", "verify_started", "verify_manifest_loaded",
        "verify_database_hashed", "verify_inventory_finished", "verify_objects_finished", "verify_finished",
        "before_publish", "published_before_parent_flush", "reconcile_before_parent_flush",
        "receipt_prepare_begin", "receipt_manifest_loaded", "receipt_index_prepared", "receipt_usage_measured",
        "receipt_prepare_end", "retention_begin", "retention_end", "restore_objects_started",
        "restore_objects_finished", "restore_fencing_started", "restore_fencing_finished",
        "restore_before_publish", "restore_published_before_flush", "restore_usage_started", "restore_usage_finished"
    ]
    private static let logger = Logger(subsystem: "org.checklist.coordination", category: "storage-phase")
    private let operation: String
    private let command: String?
    private let uptime: () -> TimeInterval
    private let sink: (String) -> Void
    private let started: TimeInterval
    private var previous: TimeInterval
    private var phase = "started"

    init(operation: String, command: String?, uptime: @escaping () -> TimeInterval,
         sink: @escaping (String) -> Void = StoragePhaseTiming.log) {
        self.operation = operation; self.command = command; self.uptime = uptime; self.sink = sink
        started = uptime(); previous = started
    }

    /// The budget's observer lock serializes the joined verification workers.
    func record(_ event: String, terminal: Bool = false) {
        guard terminal || Self.events.contains(event) else { return }
        let current = uptime()
        var load = [Double](repeating: 0, count: 3)
        let observed = getloadavg(&load, 3)
        var value: JSON = ["kind": "storage_phase_timing", "operation": operation,
            "phase": phase, "next_phase": event, "seconds": max(0, current - previous),
            "elapsed_seconds": max(0, current - started), "load": observed == 3 ? load : [], "time": now()]
        if let command { value["command_id"] = command }
        if let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let line = String(data: bytes, encoding: .utf8) { sink(line) }
        previous = current; phase = event
    }

    private static func log(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        fputs(line + "\n", stderr)
    }
}

extension StorageSnapshotBudget {
    func beginTiming(operation: String, command: String? = nil) {
        measurement.observerLock.lock(); defer { measurement.observerLock.unlock() }
        measurement.phaseTiming = StoragePhaseTiming(operation: operation, command: command, uptime: uptime)
    }

    func finishTiming(outcome: String) {
        measurement.observerLock.lock(); defer { measurement.observerLock.unlock() }
        measurement.phaseTiming?.record(outcome, terminal: true)
        measurement.phaseTiming = nil
    }
}
