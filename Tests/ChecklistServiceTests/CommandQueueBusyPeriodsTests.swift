import XCTest
import Foundation
@testable import ChecklistService

final class CommandQueueBusyPeriodsTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ChecklistQualification/r12-N/queue-log-" + UUID().uuidString)
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
