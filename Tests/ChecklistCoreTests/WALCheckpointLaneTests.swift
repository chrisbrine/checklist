import Dispatch
import GRDB
import SQLite3
import XCTest
@testable import ChecklistCore

final class WALCheckpointLaneTests: XCTestCase {
    func testConcurrentCheckpointRequiresAFixedRuntime() {
        XCTAssertFalse(WALCheckpointLane.supportsConcurrentCheckpoint(sqliteVersion: 3_044_006))
        XCTAssertFalse(WALCheckpointLane.supportsConcurrentCheckpoint(sqliteVersion: 3_051_002))
        XCTAssertTrue(WALCheckpointLane.supportsConcurrentCheckpoint(sqliteVersion: 3_051_003))
        XCTAssertTrue(WALCheckpointLane.supportsConcurrentCheckpoint(sqliteVersion: 3_054_000))
    }

    func testCommitKeepsFullSyncAndPassiveCheckpointRunsWhileRouterWriterIsOccupied() throws {
        try XCTSkipUnless(WALCheckpointLane.supportsConcurrentCheckpoint(sqliteVersion: sqlite3_libversion_number()))
        let fixture = try StorageFixture(open:false)
        let router = try CommandRouter(root:fixture.root)
        fixture.router = router
        let files = try StorageObjectFiles(root: router.root, pinRootForGates: true)
        let completed = expectation(description: "dedicated connection copied existing WAL frames")
        let writerOccupied = expectation(description: "router writer is occupied")
        let releaseWriter = DispatchSemaphore(value: 0)
        let writerFinished = DispatchGroup()
        let checkpoint = try XCTUnwrap(WALCheckpointLane(files: files, incarnation: router.incarnation,
                                                        admission: router.storageAdmission) { result, frames, checkpointed in
            XCTAssertEqual(result, SQLITE_OK)
            XCTAssertGreaterThanOrEqual(frames, 1_000)
            XCTAssertEqual(checkpointed, frames)
            completed.fulfill()
        })
        XCTAssertTrue(router.dbQueue.writeWithoutTransaction { checkpoint.install(on: $0) })
        defer {
            releaseWriter.signal()
            XCTAssertEqual(writerFinished.wait(timeout: .now() + .seconds(8)), .success)
            router.dbQueue.writeWithoutTransaction { checkpoint.remove(from: $0) }
            XCTAssertNoThrow(try checkpoint.close())
        }

        writerFinished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { writerFinished.leave() }
            router.dbQueue.writeWithoutTransaction { db in
                do {
                    try db.inTransaction {
                        XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA synchronous"), 2)
                        try db.execute(sql: "CREATE TABLE wal_checkpoint_fixture (bytes BLOB NOT NULL)")
                        try db.execute(sql: "INSERT INTO wal_checkpoint_fixture VALUES(zeroblob(8388608))")
                        return .commit
                    }
                } catch { XCTFail("Fixture commit failed: \(error)") }
                writerOccupied.fulfill()
                _ = releaseWriter.wait(timeout: .now() + .seconds(12))
            }
        }
        wait(for: [writerOccupied, completed], timeout: 8, enforceOrder: true)
        let bytes = try XCTUnwrap(router.readers).read { db in
            try Int.fetchOne(db, sql: "SELECT length(bytes) FROM wal_checkpoint_fixture")
        }
        XCTAssertEqual(bytes, 8_388_608)
    }

    func testPartialCheckpointRetriesAfterItsReaderReleasesWithoutAnotherCommit() throws {
        try XCTSkipUnless(WALCheckpointLane.supportsConcurrentCheckpoint(sqliteVersion: sqlite3_libversion_number()))
        let fixture = try StorageFixture(open:false)
        let router = try CommandRouter(root:fixture.root)
        fixture.router = router
        let files = try StorageObjectFiles(root:router.root,pinRootForGates:true)
        let reader = try router.openMaintenanceReader()
        let pinned = expectation(description:"original SQLite snapshot pinned")
        let partial = expectation(description:"checkpoint stops at the reader snapshot")
        partial.assertForOverFulfill = false
        let completed = expectation(description:"checkpoint catches up after the reader releases")
        let release = DispatchSemaphore(value:0)
        let readerFinished = DispatchGroup()
        let lane = try XCTUnwrap(WALCheckpointLane(files:files,incarnation:router.incarnation,
                                                  admission:router.storageAdmission) { result,frames,checkpointed in
            XCTAssertEqual(result,SQLITE_OK)
            XCTAssertGreaterThanOrEqual(frames,1_000)
            if checkpointed < frames { partial.fulfill() }
            else { completed.fulfill() }
        })
        XCTAssertTrue(router.dbQueue.writeWithoutTransaction { lane.install(on:$0) })
        defer {
            release.signal()
            XCTAssertEqual(readerFinished.wait(timeout:.now() + .seconds(8)),.success)
            router.dbQueue.writeWithoutTransaction { lane.remove(from:$0) }
            XCTAssertNoThrow(try lane.close())
            XCTAssertNoThrow(try reader.close())
        }
        readerFinished.enter()
        DispatchQueue.global(qos:.userInitiated).async {
            defer { readerFinished.leave() }
            do {
                try reader.read { db in
                    _ = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key='incarnation'")
                    pinned.fulfill()
                    _ = release.wait(timeout:.now() + .seconds(12))
                }
            } catch { XCTFail("Could not retain the fixture snapshot: \(error)") }
        }
        wait(for:[pinned],timeout:8)
        try router.dbQueue.write { db in
            try db.execute(sql:"CREATE TABLE wal_checkpoint_fixture (bytes BLOB NOT NULL)")
            try db.execute(sql:"INSERT INTO wal_checkpoint_fixture VALUES(zeroblob(8388608))")
        }
        wait(for:[partial],timeout:8)
        release.signal()
        wait(for:[completed],timeout:8)
    }
}
