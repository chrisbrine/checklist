import Foundation
import Darwin
import XCTest
@testable import ChecklistIPC

final class StorageUpgradeStatusTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private func fixture(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> (URL, Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("checklist-upgrade-status-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var value: [String: Any] = ["state": "upgrading", "stage": "protected_snapshot", "estimated_remaining_seconds": 900,
            "updated_at": ISO8601DateFormatter().string(from: instant), "pid": getpid()]
        change(&value)
        let bytes = try JSONSerialization.data(withJSONObject: value)
        try bytes.write(to: root.appendingPathComponent(StorageUpgradeStatus.fileName))
        return (root, bytes)
    }

    func testLiveUpgradeMarkerReportsStageEstimateAndFallbackWithoutWriting() throws {
        let (root, bytes) = try fixture { $0["reason"] = "source_changed_after_preparation" }
        let status = try XCTUnwrap(StorageUpgradeStatus.read(root: root, now: instant))
        XCTAssertEqual(status.stage, "protected_snapshot")
        XCTAssertEqual(status.estimatedRemainingSeconds, 900)
        XCTAssertTrue(status.summary.contains("verifying the protected pre-upgrade backup"))
        XCTAssertTrue(status.summary.contains("about 15 minutes"))
        XCTAssertTrue(status.summary.contains("store changed after preparation"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(StorageUpgradeStatus.fileName)), bytes)
    }

    func testDeadStaleFutureAndInvalidMarkersAreIgnored() throws {
        let (root, _) = try fixture()
        XCTAssertNil(StorageUpgradeStatus.read(root: root, now: instant, isProcessAlive: { _ in false }))
        XCTAssertNil(StorageUpgradeStatus.read(root: root, now: instant.addingTimeInterval(2101)))
        XCTAssertNil(StorageUpgradeStatus.read(root: root, now: instant.addingTimeInterval(-61)))
        let invalid: [(inout [String: Any]) -> Void] = [
            { $0["state"] = "ready" }, { $0["stage"] = "unknown" }, { $0["estimated_remaining_seconds"] = true },
            { $0["estimated_remaining_seconds"] = 1.5 }, { $0["estimated_remaining_seconds"] = -1 },
            { $0["estimated_remaining_seconds"] = 7201 }, { $0["pid"] = 0 }, { $0["pid"] = true },
            { $0["updated_at"] = "invalid timestamp" }
        ]
        for change in invalid {
            let (root, _) = try fixture(change)
            XCTAssertNil(StorageUpgradeStatus.read(root: root, now: instant, isProcessAlive: { _ in true }))
        }
    }

    func testLinkedOversizedAndAbsentMarkerAreIgnored() throws {
        let (root, _) = try fixture()
        let marker = root.appendingPathComponent(StorageUpgradeStatus.fileName), other = root.appendingPathComponent("other.json")
        try FileManager.default.moveItem(at: marker, to: other)
        XCTAssertNil(StorageUpgradeStatus.read(root: root, now: instant))
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: other)
        XCTAssertNil(StorageUpgradeStatus.read(root: root, now: instant))
        try FileManager.default.removeItem(at: marker)
        try Data(repeating: 65, count: 16_385).write(to: marker)
        XCTAssertNil(StorageUpgradeStatus.read(root: root, now: instant))
    }

    func testPreflightReturnsNotSentBeforeOpeningAnyNativeConnection() throws {
        let (root, _) = try fixture { $0["updated_at"] = ISO8601DateFormatter().string(from: Date()) }
        let request = try JSONSerialization.data(withJSONObject: ["method": "task_edit", "params": ["command_id": "original-upgrade-command"]])
        XCTAssertThrowsError(try MacOSLocalCommandTransport().request(request, replyTimeout: 1, connection: nil, upgradeRoot: root)) { failure in
            let error = failure as? ChecklistError
            XCTAssertEqual(error?.code, "STORAGE_UPGRADING")
            XCTAssertEqual(error?.details["command_outcome"] as? String, "not_sent")
            XCTAssertEqual(error?.details["command_id"] as? String, "original-upgrade-command")
            XCTAssertFalse(CommandReply.shouldRetainPending(after: failure))
        }
    }

    func testPostSendUpgradeNeverChangesUnknownOutcomeIntoRejection() throws {
        let status = try XCTUnwrap(StorageUpgradeStatus(stage: "final_migration", estimatedRemainingSeconds: 90))
        let error = status.error(commandID: "original-upgrade-command", outcomeUnknown: true, transportReason: "connection_ended")
        XCTAssertEqual(error.details["command_outcome"] as? String, "unknown")
        XCTAssertEqual(error.details["command_id"] as? String, "original-upgrade-command")
        XCTAssertEqual(error.details["transport_reason"] as? String, "connection_ended")
        XCTAssertTrue(CommandReply.shouldRetainPending(after: error))
        XCTAssertEqual(StorageUpgradeStatus(error: error), status)
        XCTAssertTrue(error.localizedDescription.contains("reconcile its original command ID"))
    }

    func testEverySupportedStageHasHumanTextAndBoundedEstimate() throws {
        for stage in ["protected_snapshot", "migration_rehearsal", "final_migration", "preparation_validation"] {
            let status = try XCTUnwrap(StorageUpgradeStatus(stage: stage, estimatedRemainingSeconds: 30))
            XCTAssertFalse(status.stageTitle.contains("_")); XCTAssertTrue(status.estimateText.contains("30 seconds"))
            XCTAssertTrue(status.error().localizedDescription.contains("Checklist is upgrading"))
        }
        XCTAssertNil(StorageUpgradeStatus(stage: "invalid", estimatedRemainingSeconds: 30))
        XCTAssertNil(StorageUpgradeStatus(stage: "final_migration", estimatedRemainingSeconds: -1))
        XCTAssertNil(StorageUpgradeStatus(error: ChecklistError("SERVICE_UNAVAILABLE", "Synthetic offline")))
    }
}
