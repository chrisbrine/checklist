import XCTest
import Foundation
import ChecklistCore
@testable import ChecklistService

final class CommandQueueBusyPeriodsTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ChecklistQualification/r13-P512/queue-log-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func retire(_ root: URL) {
        let target = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").appendingPathComponent(root.lastPathComponent)
        try? FileManager.default.moveItem(at: root, to: target)
    }

    func testRealOccupiedQueuePeriodPersistsStartLengthAndResponsibleWork() throws {
        let root = try root(); defer { retire(root) }
        let url = root.appendingPathComponent("busy.json")
        let queue = ServiceCommandQueue(logURL: url)
        queue.sync {
            queue.activity("synthetic_held_closure") { Thread.sleep(forTimeInterval: 1.02) }
        }
        queue.busyPeriods.flush()
        let periods = try JSONDecoder().decode([CommandQueueBusyPeriods.Period].self, from: Data(contentsOf: url))
        let period = try XCTUnwrap(periods.last)
        XCTAssertEqual(periods.count, 1)
        XCTAssertNotNil(ISO8601DateFormatter.withFractionalSeconds.date(from: period.started_at))
        XCTAssertGreaterThan(period.duration_ms, 1000)
        XCTAssertTrue(period.work.contains("testRealOccupiedQueuePeriod"))
        XCTAssertGreaterThan(try XCTUnwrap(period.activities_ms["synthetic_held_closure"]), 1000)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // A short queue turn does not produce a false positive.
        queue.sync {}
        queue.busyPeriods.flush()
        XCTAssertEqual(try JSONDecoder().decode([CommandQueueBusyPeriods.Period].self, from: Data(contentsOf: url)).count, 1)
    }

    func testDiagnosticHistoryIsBoundedAndSurvivesLoggerRestart() throws {
        let root = try root(); defer { retire(root) }
        let url = root.appendingPathComponent("busy.json")
        let periods = CommandQueueBusyPeriods(url: url)
        for index in 0..<70 {
            periods.record(startedAt: Date(timeIntervalSince1970: Double(index)), durationMS: 1001, work: "work-\(index)", activities: [:])
        }
        periods.flush()
        let restarted = CommandQueueBusyPeriods(url: url)
        restarted.record(startedAt: Date(), durationMS: 1002, work: "after-restart", activities: [:])
        restarted.flush()
        let saved = try JSONDecoder().decode([CommandQueueBusyPeriods.Period].self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.count, 64)
        XCTAssertEqual(saved.first?.work, "work-7")
        XCTAssertEqual(saved.last?.work, "after-restart")
    }

    func testWatchdogRecordsConcurrentActiveAndCompletedHolds() throws {
        let root = try root(); defer { retire(root) }
        let log = CommandQueueBusyPeriods(url: root.appendingPathComponent("busy.json"))
        let watchdog = ServiceHoldWatchdog()
        let active = DispatchSemaphore(value: 0)
        watchdog.observe { hold in
            log.record(hold)
            if hold.active { active.signal() }
        }
        let writer = watchdog.begin(resource: "writer", work: "routine_prune_command_results")
        let gate = watchdog.begin(resource: "archive_storage_gate", work: "archive_cleanup")
        XCTAssertEqual(active.wait(timeout: .now() + 6), .success)
        XCTAssertEqual(active.wait(timeout: .now() + 6), .success)
        let snapshot = try XCTUnwrap(watchdog.status["active"] as? [[String: Any]])
        XCTAssertEqual(Set(snapshot.compactMap { $0["work"] as? String }), ["routine_prune_command_results", "archive_cleanup"])
        watchdog.end(writer)
        watchdog.end(gate)
        XCTAssertEqual((watchdog.status["active"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((watchdog.status["recent"] as? [[String: Any]])?.count, 2)
        log.flush()
        let entries = try JSONDecoder().decode([CommandQueueBusyPeriods.Period].self, from: Data(contentsOf: log.url))
        XCTAssertEqual(entries.filter { $0.active == true }.count, 2)
        XCTAssertEqual(entries.filter { $0.active == false }.count, 2)
        XCTAssertEqual(Set(entries.compactMap(\.resource)), ["writer", "archive_storage_gate"])
        XCTAssertTrue(entries.allSatisfy { $0.duration_ms > 1000 })
    }

    func testWrappingCancelledDeadlineAndThrowingSyncPreservesDispatchResults() throws {
        let root = try root(); defer { retire(root) }
        let queue = ServiceCommandQueue(logURL: root.appendingPathComponent("busy.json"))
        let cancelled = DispatchWorkItem { XCTFail("A cancelled deadline must not execute") }
        cancelled.cancel()
        queue.asyncAfter(deadline: .now(), execute: cancelled)
        queue.sync {}
        enum Expected: Error { case failure }
        XCTAssertThrowsError(try queue.sync { throw Expected.failure }) { XCTAssertTrue($0 is Expected) }
        XCTAssertEqual(queue.sync { 42 }, 42)
        queue.busyPeriods.flush()
    }
}

private extension ISO8601DateFormatter {
    static var withFractionalSeconds: ISO8601DateFormatter {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }
}
