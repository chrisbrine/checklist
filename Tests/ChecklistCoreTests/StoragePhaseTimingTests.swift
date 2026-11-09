import XCTest
import Foundation
@testable import ChecklistCore

final class StoragePhaseTimingTests: XCTestCase {
    func testPhaseLogUsesMonotonicDurationsAndOmitsPerFileProgress() throws {
        var clock: TimeInterval = 10, lines: [String] = []
        let timer = StoragePhaseTiming(operation: "backup_create", command: "fixture-command",
            uptime: { clock }, sink: { lines.append($0) })
        clock = 12; timer.record("inventory_started")
        clock = 14; timer.record("object_copied")
        clock = 17; timer.record("inventory_finished")
        clock = 19; timer.record("failed", terminal: true)
        let rows = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? JSON) }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map { $0["phase"] as? String }, ["started", "inventory_started", "inventory_finished"])
        XCTAssertEqual(rows.map { $0["seconds"] as? Double }, [2, 5, 2])
        XCTAssertEqual(rows.map { $0["elapsed_seconds"] as? Double }, [2, 7, 9])
        XCTAssertEqual(rows.last?["next_phase"] as? String, "failed")
        for row in rows {
            XCTAssertEqual(row["kind"] as? String, "storage_phase_timing")
            XCTAssertEqual(row["operation"] as? String, "backup_create")
            XCTAssertEqual(row["command_id"] as? String, "fixture-command")
            XCTAssertEqual((row["load"] as? [Double])?.count, 3)
        }
    }

    func testRealSnapshotRecordsBothIndependentVerificationPasses() throws {
        let f = try StorageFixture(), operation = UUID()
        let identity = try StoreIdentityReceipt.decode(Data(contentsOf: f.root.appendingPathComponent(StoreIdentityReceipt.fileName)))
        var lines: [String] = []
        let budget = StorageSnapshotBudget.production()
        budget.measurement.phaseTiming = StoragePhaseTiming(operation: "protected_backup", command: nil,
            uptime: budget.uptime, sink: { lines.append($0) })
        _ = try ArchiveStorageGate.withExclusive(root: f.root) { permit in
            try StorageSnapshot.build(StorageSnapshotSource(source: f.root, parent: f.base,
                storeID: identity.logical_store_id, permit: permit), operation: operation, budget: budget)
        }
        budget.finishTiming(outcome: "complete")
        let rows = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? JSON) }
        let phases = rows.compactMap { $0["next_phase"] as? String }
        XCTAssertEqual(phases.filter { $0 == "verify_started" }.count, 2)
        XCTAssertEqual(phases.filter { $0 == "verify_finished" }.count, 2)
        XCTAssertTrue(phases.contains("inventory_started"))
        XCTAssertTrue(phases.contains("objects_finished"))
        XCTAssertTrue(phases.contains("manifest_written"))
        XCTAssertEqual(phases.last, "complete")
        XCTAssertNil(budget.measurement.phaseTiming)
    }
}
