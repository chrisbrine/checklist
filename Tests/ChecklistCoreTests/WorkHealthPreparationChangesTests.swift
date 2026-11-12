import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

final class WorkHealthPreparationChangesTests: XCTestCase {
    private static let families = ["task", "attempt", "project", "group", "status"]
    private static let project = "00000000-0000-0000-0000-000000000001"
    private static let task = "00000000-0000-0000-0000-000000000002"

    private static func schema(_ db: Database) throws {
        try db.execute(sql:"CREATE TABLE records(id TEXT PRIMARY KEY,project_id TEXT,type TEXT,revision INTEGER,data TEXT); CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT)")
    }
    private static func payload(task: String?) throws -> String {
        let value: [String:String] = task.map {["task_id":$0]} ?? [:]
        return String(decoding:try JSONSerialization.data(withJSONObject:value),as:UTF8.self)
    }
    private static func insert(_ db: Database,id: String,type: String,project: String? = WorkHealthPreparationChangesTests.project,task: String? = nil) throws {
        // Match the product's length-aware boundary. GRDB String binding uses
        // a -1 byte count and would truncate a fixture identifier at NUL.
        try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES (CAST(? AS TEXT),CAST(? AS TEXT),CAST(? AS TEXT),1,CAST(? AS TEXT))",
                       arguments:[Data(id.utf8),project.map {Data($0.utf8)},Data(type.utf8),Data((try payload(task:task)).utf8)])
    }
    private func withDatabase(_ body: (Database) throws -> Void) throws {
        let queue = try DatabaseQueue();defer {try? queue.close()}
        try queue.writeWithoutTransaction {db in try Self.schema(db);try body(db)}
    }
    private func assertContains(_ changes: [WorkHealthPreparationChanges.Change],id: String,type: String,project: String?,task: String?,file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertTrue(changes.contains {$0.id==Data(id.utf8) && $0.type==Data(type.utf8) && $0.project==Data((project ?? "").utf8) && $0.task==Data((task ?? "").utf8)},"Missing exact \(type) change",file:file,line:line)
    }

    func testInsertedWatchedFamiliesRecordOnlyTheirExactIdentifiers() throws {
        for family in Self.families {
            try withDatabase {db in
                let journal = WorkHealthPreparationChanges(),version = try journal.install(db)
                defer {try? journal.remove(db)}
                XCTAssertTrue(try XCTUnwrap(journal.read(db,version:version)).isEmpty)
                let id = UUID().uuidString
                try Self.insert(db,id:id,type:family,task:Self.task)
                let changes = try XCTUnwrap(journal.read(db,version:version))
                XCTAssertEqual(changes.count,1)
                assertContains(changes,id:id,type:family,project:Self.project,task:Self.task)
            }
        }
    }

    func testUpdatesCaptureOldAndNewIdentityScopeAndTaskWithoutRevisionChange() throws {
        for family in Self.families {
            try withDatabase {db in
                let oldID = UUID().uuidString,newID = UUID().uuidString,newProject = UUID().uuidString,newTask = UUID().uuidString
                try Self.insert(db,id:oldID,type:family,task:Self.task)
                let journal = WorkHealthPreparationChanges(),version = try journal.install(db)
                defer {try? journal.remove(db)}
                try db.execute(sql:"UPDATE records SET id=?,project_id=?,data=? WHERE id=?",
                               arguments:[newID,newProject,try Self.payload(task:newTask),oldID])
                let changes = try XCTUnwrap(journal.read(db,version:version))
                XCTAssertEqual(changes.count,2)
                assertContains(changes,id:oldID,type:family,project:Self.project,task:Self.task)
                assertContains(changes,id:newID,type:family,project:newProject,task:newTask)
                XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT revision FROM records WHERE id=?",arguments:[newID]),1)
            }
        }
    }

    func testDeletesCaptureEveryWatchedFamily() throws {
        for family in Self.families {
            try withDatabase {db in
                let id = UUID().uuidString
                try Self.insert(db,id:id,type:family,task:Self.task)
                let journal = WorkHealthPreparationChanges(),version = try journal.install(db)
                defer {try? journal.remove(db)}
                try db.execute(sql:"DELETE FROM records WHERE id=?",arguments:[id])
                let changes = try XCTUnwrap(journal.read(db,version:version))
                XCTAssertEqual(changes.count,1)
                assertContains(changes,id:id,type:family,project:Self.project,task:Self.task)
            }
        }
    }

    func testTypeChangesIncludeEachWatchedSideAndIgnoreUnwatchedSides() throws {
        for (before,after) in [("task","message"),("message","attempt"),("attempt","group")] {
            try withDatabase {db in
                let id = UUID().uuidString
                try Self.insert(db,id:id,type:before,task:Self.task)
                let journal = WorkHealthPreparationChanges(),version = try journal.install(db)
                defer {try? journal.remove(db)}
                try db.execute(sql:"UPDATE records SET type=? WHERE id=?",arguments:[after,id])
                let changes = try XCTUnwrap(journal.read(db,version:version))
                let expected = [before,after].filter {Self.families.contains($0)}
                XCTAssertEqual(changes.count,expected.count)
                for family in expected {assertContains(changes,id:id,type:family,project:Self.project,task:Self.task)}
            }
        }
    }

    func testReplaceCapturesWatchedConflictWithRecursiveTriggersOff() throws {
        for family in Self.families {
            try withDatabase {db in
                try db.execute(sql:"PRAGMA recursive_triggers=OFF")
                let id = UUID().uuidString
                try Self.insert(db,id:id,type:family,task:Self.task)
                let journal = WorkHealthPreparationChanges(),version = try journal.install(db)
                defer {try? journal.remove(db)}
                try db.execute(sql:"INSERT OR REPLACE INTO records(id,project_id,type,revision,data) VALUES (?,?,'message',1,'{}')",arguments:[id,Self.project])
                let changes = try XCTUnwrap(journal.read(db,version:version))
                XCTAssertEqual(changes.count,1)
                assertContains(changes,id:id,type:family,project:Self.project,task:Self.task)
            }
        }
    }

    func testRepeatedOuterProductUpsertsAndReplacementsDeduplicateWithoutConstraintFailures() throws {
        try withDatabase {db in
            try db.execute(sql:"PRAGMA recursive_triggers=OFF")
            let journal = WorkHealthPreparationChanges(),version = try journal.install(db)
            defer {try? journal.remove(db)}
            let id = UUID().uuidString
            for revision in 1...16 {
                try db.execute(sql:"""
                    INSERT INTO records(id,project_id,type,revision,data) VALUES (?,?,'task',?,'{}')
                    ON CONFLICT(id) DO UPDATE SET project_id=excluded.project_id,type=excluded.type,revision=excluded.revision,data=excluded.data
                    """,arguments:[id,Self.project,revision])
            }
            for family in ["message","task","message","attempt"] {
                try db.execute(sql:"INSERT OR REPLACE INTO records(id,project_id,type,revision,data) VALUES (?,?,?,1,'{}')",arguments:[id,Self.project,family])
            }
            let changes = try XCTUnwrap(journal.read(db,version:version))
            XCTAssertEqual(changes.count,2)
            assertContains(changes,id:id,type:"task",project:Self.project,task:nil)
            assertContains(changes,id:id,type:"attempt",project:Self.project,task:nil)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records"),1)
        }
    }

    func testUpdateOrReplaceCapturesDisplacedWatchedRowWithRecursiveTriggersOff() throws {
        for family in Self.families {
            try withDatabase {db in
                try db.execute(sql:"PRAGMA recursive_triggers=OFF")
                let selected = UUID().uuidString,ordinary = UUID().uuidString
                try Self.insert(db,id:selected,type:family,task:Self.task)
                try Self.insert(db,id:ordinary,type:"message")
                let journal = WorkHealthPreparationChanges(),version = try journal.install(db)
                defer {try? journal.remove(db)}
                try db.execute(sql:"UPDATE OR REPLACE records SET id=? WHERE id=?",arguments:[selected,ordinary])
                let changes = try XCTUnwrap(journal.read(db,version:version))
                XCTAssertEqual(changes.count,1)
                assertContains(changes,id:selected,type:family,project:Self.project,task:Self.task)
                XCTAssertEqual(try String.fetchOne(db,sql:"SELECT type FROM records WHERE id=?",arguments:[selected]),"message")
                XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records"),1)
            }
        }
    }

    func testUpdateReplacementFromNullOrBlobIdentityStillCapturesDisplacedRow() throws {
        let selected = "target"
        let oldIDs: [Data?] = [nil,Data(selected.utf8)]
        for oldID in oldIDs {
            try withDatabase {db in
                try db.execute(sql:"PRAGMA recursive_triggers=OFF")
                try Self.insert(db,id:selected,type:"attempt",task:Self.task)
                try db.execute(sql:"INSERT INTO records VALUES (?,?,'message',1,'{}')",arguments:[oldID,Self.project])
                let journal = WorkHealthPreparationChanges(),version = try journal.install(db)
                defer {try? journal.remove(db)}
                try db.execute(sql:"UPDATE OR REPLACE records SET id=CAST(? AS TEXT) WHERE type='message'",arguments:[Data(selected.utf8)])
                let changes = try XCTUnwrap(journal.read(db,version:version))
                XCTAssertEqual(changes.count,1)
                assertContains(changes,id:selected,type:"attempt",project:Self.project,task:Self.task)
                XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records"),1)
            }
        }
    }

    func testOrdinaryRecordAndMetadataChangesLeaveJournalEmpty() throws {
        try withDatabase {db in
            let journal = WorkHealthPreparationChanges(),version = try journal.install(db)
            defer {try? journal.remove(db)}
            for family in ["message","delivery","session","request","relation","task_alias"] {
                let id = UUID().uuidString
                try Self.insert(db,id:id,type:family)
                try db.execute(sql:"UPDATE records SET data='not json' WHERE id=?",arguments:[id])
                try db.execute(sql:"DELETE FROM records WHERE id=?",arguments:[id])
            }
            try db.execute(sql:"INSERT INTO metadata VALUES('relay','before'); UPDATE metadata SET value='after'; DELETE FROM metadata")
            XCTAssertTrue(try XCTUnwrap(journal.read(db,version:version)).isEmpty)
        }
    }

    func testNullProjectAndAbsentOrNullTaskMetadataRemainRepresentable() throws {
        try withDatabase {db in
            let journal = WorkHealthPreparationChanges(),version = try journal.install(db)
            defer {try? journal.remove(db)}
            let project = UUID().uuidString,attempt = UUID().uuidString
            try Self.insert(db,id:project,type:"project",project:nil)
            try db.execute(sql:"INSERT INTO records VALUES (?,?,'attempt',1,'{\"task_id\":null}')",arguments:[attempt,Self.project])
            let changes = try XCTUnwrap(journal.read(db,version:version))
            XCTAssertEqual(changes.count,2)
            assertContains(changes,id:project,type:"project",project:nil,task:nil)
            assertContains(changes,id:attempt,type:"attempt",project:Self.project,task:nil)
        }
    }

    func testSqlIdentifiersPreserveEmbeddedNulAndByteDistinctUnicode() throws {
        try withDatabase {db in
            let journal = WorkHealthPreparationChanges(),version = try journal.install(db)
            defer {try? journal.remove(db)}
            let project = "project\0suffix",task = "task\\suffix"
            for id in ["é","e\u{301}","id\0suffix"] {try Self.insert(db,id:id,type:"attempt",project:project,task:task)}
            let changes = try XCTUnwrap(journal.read(db,version:version))
            XCTAssertEqual(changes.count,3)
            for id in ["é","e\u{301}","id\0suffix"] {assertContains(changes,id:id,type:"attempt",project:project,task:task)}
        }
    }

    func testJsonTaskIdentityContainingNulRefusesWithoutAcceptingATruncatedChange() throws {
        try withDatabase {db in
            let journal = WorkHealthPreparationChanges(),version = try journal.install(db)
            defer {try? journal.remove(db)}
            let id = UUID().uuidString,task = "task\0suffix"
            try Self.insert(db,id:id,type:"attempt",task:task)
            XCTAssertNil(try journal.read(db,version:version))
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM \(journal.name)"),0)
            let raw = try XCTUnwrap(Data.fetchOne(db,sql:"SELECT CAST(data AS BLOB) FROM records WHERE id=CAST(? AS TEXT)",arguments:[Data(id.utf8)]))
            let retained = try XCTUnwrap(JSONSerialization.jsonObject(with:raw) as? [String:String])
            XCTAssertEqual(Data(try XCTUnwrap(retained["task_id"]).utf8),Data(task.utf8),"The refusal must preserve the original domain write")
        }
    }

    func testRowBoundRefusesObservationWithoutAbortingTheDomainInsert() throws {
        try withDatabase {db in
            let journal = WorkHealthPreparationChanges(),version = try journal.install(db)
            defer {try? journal.remove(db)}
            let insert = try db.cachedStatement(sql:"INSERT INTO records VALUES (?,?,'task',1,'{}')")
            for index in 0..<4096 {try insert.execute(arguments:[String(index),Self.project])}
            XCTAssertEqual(try XCTUnwrap(journal.read(db,version:version)).count,4096)
            try insert.execute(arguments:["overflow",Self.project])
            XCTAssertNil(try journal.read(db,version:version))
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records"),4097)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM \(journal.name)"),4096)
        }
    }

    func testIdentifierByteBoundRefusesObservationAndRetainsTheDomainWrite() throws {
        try withDatabase {db in
            let journal = WorkHealthPreparationChanges(),version = try journal.install(db)
            defer {try? journal.remove(db)}
            let exactLimitID = String(repeating:"x",count:1024*1024-"task".utf8.count-Self.project.utf8.count)
            try Self.insert(db,id:exactLimitID,type:"task")
            XCTAssertEqual(try XCTUnwrap(journal.read(db,version:version)).count,1)
            try Self.insert(db,id:"exceeds-byte-budget",type:"task")
            XCTAssertNil(try journal.read(db,version:version))
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records"),2)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM \(journal.name)"),1)
        }
    }

    func testInvalidWatchedMetadataRefusesObservationWithoutAbortingWrites() throws {
        let statements = [
            "INSERT INTO records VALUES ('fixture',NULL,'task',1,'{')",
            "INSERT INTO records VALUES ('fixture',NULL,'task',1,'[]')",
            "INSERT INTO records VALUES ('fixture',NULL,'attempt',1,'{\"task_id\":7}')",
            "INSERT INTO records VALUES ('fixture',NULL,'attempt',1,'{\"task_id\":\"\"}')",
            "INSERT INTO records VALUES ('fixture',NULL,'attempt',1,'{\"task_id\":\"a\",\"task_id\":\"b\"}')",
            "INSERT INTO records VALUES ('fixture',X'70726f6a656374','task',1,'{}')",
            "INSERT INTO records VALUES (NULL,NULL,'task',1,'{}')",
            "INSERT INTO records VALUES (CAST(X'ff' AS TEXT),NULL,'task',1,'{}')",
        ]
        for statement in statements {
            try withDatabase {db in
                let journal = WorkHealthPreparationChanges(),version = try journal.install(db)
                defer {try? journal.remove(db)}
                try db.execute(sql:statement)
                XCTAssertNil(try journal.read(db,version:version),statement)
                XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records"),1)
                try Self.insert(db,id:UUID().uuidString,type:"message")
                XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records"),2)
            }
        }
    }

    func testRolledBackChangesAndRefusalDoNotSurviveTheirTransaction() throws {
        try withDatabase {db in
            let journal = WorkHealthPreparationChanges(),version = try journal.install(db)
            defer {try? journal.remove(db)}
            try db.inTransaction {
                try Self.insert(db,id:UUID().uuidString,type:"attempt",task:Self.task)
                XCTAssertEqual(try XCTUnwrap(journal.read(db,version:version)).count,1)
                try db.execute(sql:"INSERT INTO records VALUES ('invalid',NULL,'task',1,'{')")
                XCTAssertNil(try journal.read(db,version:version))
                return .rollback
            }
            XCTAssertTrue(try XCTUnwrap(journal.read(db,version:version)).isEmpty)
        }
    }

    func testRemoveCleansArtifactsAndJournalCanBeInstalledAgain() throws {
        try withDatabase {db in
            let journal = WorkHealthPreparationChanges(),version = try journal.install(db)
            try Self.insert(db,id:UUID().uuidString,type:"task")
            XCTAssertEqual(try XCTUnwrap(journal.read(db,version:version)).count,1)
            try journal.remove(db)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM temp.sqlite_master WHERE substr(name,1,?)=?",arguments:[journal.name.count,journal.name]),0)
            try Self.insert(db,id:UUID().uuidString,type:"attempt")
            let nextVersion = try journal.install(db)
            defer {try? journal.remove(db)}
            XCTAssertTrue(try XCTUnwrap(journal.read(db,version:nextVersion)).isEmpty)
        }
    }

    func testExternalUnjournaledWriteRefusesWhileSameWriterNoteRemainsValid() throws {
        let caches = try FileManager.default.url(for:.cachesDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
        let directory = caches.appendingPathComponent("ChecklistQualification/p11-G/work-health-changes-" + UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.trashItem(at:directory,resultingItemURL:nil)}
        let writer = try DatabaseQueue(path:directory.appendingPathComponent("fixture.sqlite").path)
        defer {try? writer.close()}
        try writer.writeWithoutTransaction {try Self.schema($0)}
        let external = try DatabaseQueue(path:directory.appendingPathComponent("fixture.sqlite").path)
        defer {try? external.close()}
        let journal = WorkHealthPreparationChanges(),version = try writer.writeWithoutTransaction {try journal.install($0)}
        defer {try? writer.writeWithoutTransaction {try journal.remove($0)}}
        try writer.write {try Self.insert($0,id:UUID().uuidString,type:"message")}
        XCTAssertTrue(try XCTUnwrap(writer.writeWithoutTransaction {try journal.read($0,version:version)}).isEmpty)
        try external.write {try Self.insert($0,id:UUID().uuidString,type:"message")}
        XCTAssertNil(try writer.writeWithoutTransaction {try journal.read($0,version:version)})
    }
}
