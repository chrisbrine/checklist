import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

final class ManagedImportStageReferenceTests: XCTestCase {
    private func createRecords(_ db: Database) throws {
        try db.execute(sql:"""
            CREATE TABLE records (id TEXT PRIMARY KEY,project_id TEXT,type TEXT NOT NULL,data TEXT NOT NULL);
            CREATE INDEX records_scope ON records(project_id,type);
            """)
    }

    func testLookupMatchesCanonicalScanAcrossPathsAndWriterChanges() throws {
        let writer = try DatabaseQueue()
        try writer.writeWithoutTransaction { db in
            try createRecords(db)
            let root = "/fixture/"
            let names = (0..<24).map { "staging/attachment-imports/\($0)/original" }
                + ["staging/attachment-imports/é/original","staging/attachment-imports/e\u{301}/original"]
            func put(_ id: String,_ type: String,_ value: JSON,replace: Bool = false) throws {
                try db.execute(sql:"""
                    INSERT \(replace ? "OR REPLACE" : "") INTO records(id,project_id,type,data) VALUES (?,?,?,?)
                    """,arguments:[id,"project-\(id)",type,try jsonString(value)])
            }
            for (index,name) in names.enumerated() {
                let field = index % 2 == 0 ? "path" : "preview_path"
                let spelling = index % 3 == 0 ? root + name : name
                try put("entry-\(index)",index % 5 == 0 ? "message" : "attachment",[field:spelling])
            }
            let lookup = try ManagedImportStageReferences(db)
            func compare(_ extra: [String] = []) throws {
                for path in names + extra + ["staging/attachment-imports/missing/original"] {
                    let previous = try ManagedImportStageReferences.scan(db,absolute:root+path,relative:path)
                    XCTAssertEqual(try lookup.contains(db,absolute:root+path,relative:path),previous,path)
                }
            }
            try compare()

            let inserted = "staging/attachment-imports/new/original"
            try put("new","attachment",["preview_path":inserted])
            try compare([inserted])
            try db.execute(sql:"UPDATE records SET id='renamed',rowid=500,data=? WHERE id='new'",
                           arguments:[try jsonString(["path":root+inserted])])
            try compare([inserted])
            try put("renamed","message",["path":names[0]],replace:true)
            try compare([inserted])

            try db.inSavepoint {
                try put("temporary","attachment",["path":inserted])
                try db.execute(sql:"DELETE FROM records WHERE id='entry-2'")
                try compare([inserted])
                return .rollback
            }
            try compare([inserted])

            try db.execute(sql:"INSERT INTO records VALUES ('bad','other','attachment','{invalid json')")
            try compare([inserted])
            XCTAssertEqual(try lookup.contains(db,absolute:root+inserted,relative:inserted),true)
            try db.execute(sql:"DELETE FROM records WHERE id='bad'")
            try compare([inserted])
            XCTAssertEqual(try lookup.contains(db,absolute:root+inserted,relative:inserted),false)
        }
    }

    func testUnobservedWriterInvalidatesTemporaryLookup() throws {
        let name = UUID().uuidString
        let writer = try DatabaseQueue(named:name), other = try DatabaseQueue(named:name)
        let lookup = try writer.writeWithoutTransaction { db in
            try createRecords(db)
            return try ManagedImportStageReferences(db)
        }
        let relative = "staging/attachment-imports/new/original", absolute = "/fixture/" + relative
        try writer.read { db in
            XCTAssertEqual(try lookup.contains(db,absolute:absolute,relative:relative),false)
        }
        try other.write { db in
            try db.execute(sql:"INSERT INTO records VALUES ('external','fixture','attachment',?)",
                           arguments:[try jsonString(["path":relative])])
        }
        try writer.read { db in
            XCTAssertNil(try lookup.contains(db,absolute:absolute,relative:relative))
            XCTAssertTrue(try ManagedImportStageReferences.scan(db,absolute:absolute,relative:relative))
        }
    }
}
