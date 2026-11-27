import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

extension TicketRetirementTests {
    func testV28EmptyTicketPurgesWith4097IrrelevantProjects() throws {
        let (project,task) = try fixture()
        try fixtureWrite {db in try insertCleanupProjects(db,count:4097)}
        let trashed = try trash(project,task)
        let preview = try call("task_purge_preview",params(project,trashed))
        let result = try purge(project,trashed,preview)
        XCTAssertEqual((result["task"] as? JSON)?["purged"] as? Bool,true)
        XCTAssertEqual(try router.dbQueue.read {try Int.fetchOne($0,sql:"SELECT count(*) FROM records WHERE type='project'")},4098)
    }

    func testV28ExactProjectReferencesExceedNamedRecordLimit() throws {
        let (project,task) = try fixture()
        let tid = try XCTUnwrap(task["id"] as? String)
        let trashed = try trash(project,task)
        try fixtureWrite {db in try insertCleanupProjects(db,count:4097,reference:tid)}
        XCTAssertThrowsError(try call("task_purge_preview",params(project,trashed))) { error in
            XCTAssertEqual((error as? CoreError)?.code,"CLEANUP_INVENTORY_LIMIT")
            XCTAssertTrue((error as? CoreError)?.message.contains("4,096-record") == true)
        }
        let batch = try router.dbQueue.read {try self.router.ticketCleanupInventories($0,tasks:[trashed])}
        XCTAssertTrue(batch.errors[tid]?.message.contains("4,096-record") == true)
        XCTAssertEqual(try read(project,trashed)["trashed"] as? Bool,true)
    }

    func testV28WorkspaceProjectionMatchesPreviousCanonicalPrefixCheck() throws {
        _ = try fixture()
        let workspace = directory.appendingPathComponent("private workspace",isDirectory:true)
        let alias = directory.appendingPathComponent("workspace alias")
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:workspace)
        let roots = [workspace.path,alias.path,directory.appendingPathComponent("prefix-neighbor").path,"/"]
        try fixtureWrite {db in
            for (index,root) in roots.enumerated() {try insertCleanupProjects(db,count:1,offset:index,root:root)}
        }
        let paths = (0..<72).map {index -> String in
            switch index % 6 {
            case 0: workspace.path
            case 1: alias.appendingPathComponent("generated/\(index)").path
            case 2: workspace.path + "-nearby/\(index)"
            case 3: directory.appendingPathComponent("prefix-neighbor/\(index)").path
            case 4: directory.appendingPathComponent("unrelated/\(index)").path
            default: "/"
            }
        }
        try router.dbQueue.read {db in
            let projected = try CleanupWorkspaceProtection(db,paths:paths)
            let previous = roots.map {URL(fileURLWithPath:$0).resolvingSymlinksInPath().standardizedFileURL.path}
            for path in paths {
                let target = URL(fileURLWithPath:path).resolvingSymlinksInPath().standardizedFileURL.path
                let protected = previous.contains {target == $0 || target.hasPrefix($0 + "/")}
                XCTAssertEqual(projected.protects(path),protected,path)
            }
        }
    }
}

extension MediaRoundDeletionTests {
    func testV28ForeignWorkspaceStillHoldsRoundFilesWithOversizedProjectMetadata() throws {
        let f = try Fixture();try trash(f)
        let round = try cancel(f,imageRound(f,"workspace-held.png"))
        let attachment = try XCTUnwrap(f.rows("attachment").first)
        let original = try XCTUnwrap(f.router.ownerManagedPathProjection(attachment,caller:f.owner)["path"] as? String)
        let workspace = URL(fileURLWithPath:original).deletingLastPathComponent().path
        try f.router.dbQueue.write {db in
            let padding = String(repeating:"unrelated project metadata ",count:39_000)
            try insertCleanupProjects(db,count:17,root:"",padding:padding)
            try insertCleanupProjects(db,count:1,offset:17,root:workspace,padding:padding)
            let unrelated = (0..<70).reduce("\"unrelated\"") {body,_ in "[\(body)]"}
            try db.execute(sql:"UPDATE records SET data=json_set(data,'$.body',json(?)) WHERE id=?",
                           arguments:[unrelated,"00000000-0000-0000-0000-000000270000"])
        }
        let result = try worker(f,"media_round_delete",input(f,round))
        XCTAssertEqual(result["deleted"] as? Bool,true)
        let files = try XCTUnwrap(deletion(f,round)["files"] as? [JSON])
        XCTAssertTrue(files.contains {strings($0,"reasons").contains("workspace_file")})
        XCTAssertTrue(FileManager.default.fileExists(atPath:original))
    }

    func testV28LargeExactProjectReferenceStillRefusesRoundDeletion() throws {
        let f = try Fixture(),round = try cancel(f,f.round(f.type(checks.schema())))
        let rid = try XCTUnwrap(round["id"] as? String)
        try f.router.dbQueue.write {db in
            try insertCleanupProjects(db,count:1,reference:rid,padding:String(repeating:"unrelated prose ",count:2_000))
        }
        let params = try input(f,round)
        checks.checkError("MEDIA_ROUND_REFERENCED") {try self.worker(f,"media_round_delete",params)}
        XCTAssertEqual(try f.get(round)["state"] as? String,"canceled")
    }

    func testV28ProtectingRootsExceedNamedAuthorityLimit() throws {
        let f = try Fixture();try trash(f)
        let round = try cancel(f,imageRound(f,"many-workspace-holds.png"))
        let attachment = try XCTUnwrap(f.rows("attachment").first)
        let original = try XCTUnwrap(f.router.ownerManagedPathProjection(attachment,caller:f.owner)["path"] as? String)
        let workspace = URL(fileURLWithPath:original).deletingLastPathComponent().path
        try f.router.dbQueue.write {db in try insertCleanupProjects(db,count:4097,root:workspace)}
        let params = try input(f,round)
        XCTAssertThrowsError(try worker(f,"media_round_delete",params)) {error in
            XCTAssertEqual((error as? CoreError)?.code,"CLEANUP_INVENTORY_LIMIT")
            XCTAssertTrue((error as? CoreError)?.message.contains("4,096-entry workspace authority limit") == true)
        }
        XCTAssertEqual(try f.get(round)["state"] as? String,"canceled")
        XCTAssertTrue(FileManager.default.fileExists(atPath:original))
    }
}

private func insertCleanupProjects(_ db: Database,count: Int,offset: Int = 0,root: String? = nil,reference: String = "",padding: String = "") throws {
    try db.execute(sql:"""
        WITH RECURSIVE fixture(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM fixture WHERE n+1<?),
        projects AS (SELECT printf('00000000-0000-0000-0000-%012d',n+?+270000) id,n FROM fixture)
        INSERT INTO records(id,project_id,type,revision,data)
        SELECT id,id,'project',1,json_object('id',id,'project_id',id,'revision',1,
            'root_path',coalesce(?,CASE WHEN n % 2 = 0 THEN '' ELSE '/unrelated/fixture/'||n END),
            'reference',?,'body',?) FROM projects
        """,arguments:[count,offset,root,reference,padding])
}
