import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

extension TicketLifecycleCleanupTests {
    func testBackupObservationValidatesUnwantedDescriptorsAndEmptySelections() throws {
        let (_,_,attachment) = try fixture()
        let bad = "backup-generation:invalid-unwanted"
        let malformed: [JSON] = [
            ["path":"objects/unwanted","size":1],
            ["path":"objects/unwanted","sha256":"other","size":-1],
            ["path":12,"sha256":"other","size":1],
            ["path":"objects/unwanted","sha256":"other","size":"1"]
        ]
        let wanted: JSON = ["relative_path":"objects/absent","sha256":attachment["sha256"]!,"size":attachment["size"]!]
        for entry in malformed {
            try write {db in try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:[bad,try jsonString(["state":"complete","objects":[entry]])])}
            for objects in [[],[wanted]] {
                XCTAssertThrowsError(try router.readers!.read {try self.router.ticketCleanupBackupRetentionIndex($0,objects:objects)})
            }
        }
    }

    func testBackupObservationFiltersContentBeforePathNormalizationAndPinsManifest() throws {
        let (_,_,attachment) = try fixture()
        let path = try XCTUnwrap(ManagedPaths.relative(attachment["path"] as! String,family:"objects",root:router.root))
        let wanted: JSON = ["relative_path":path,"sha256":attachment["sha256"]!,"size":attachment["size"]!]
        let other: JSON = ["relative_path":"objects/live-only","sha256":String(repeating:"a",count:64),"size":99]
        try write {db in
            var entries: [JSON] = (0..<1000).map {["path":"objects/unwanted-\($0)","sha256":attachment["sha256"]!,"size":attachment["size"]!]}
            entries.append(["path":self.router.root.standardizedFileURL.path + "/" + path,"sha256":attachment["sha256"]!,"size":attachment["size"]!])
            try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?)",arguments:["backup-generation:unwanted",try jsonString(["state":"complete","objects":entries])])
        }
        var normalized: [String] = []
        // CL-355: the reference full scan keeps its filter; the per-receipt index returns the same result.
        let reference = try router.readers!.read {try self.router.ticketCleanupBackupRetentionIndexFullScan($0,objects:[wanted,other],observeCandidate:{normalized.append($0)})}
        XCTAssertEqual(Set(normalized),Set([path,router.root.standardizedFileURL.path + "/" + path]))
        XCTAssertEqual(normalized.count,2,"A thousand same-content aliases must never reach path normalization")
        let observation = try router.readers!.read {try self.router.ticketCleanupBackupRetentionIndex($0,objects:[wanted,other])}
        XCTAssertEqual(observation.originals,reference.originals);XCTAssertEqual(observation.copyPaths,reference.copyPaths);XCTAssertEqual(observation.copyManifests,reference.copyManifests)
        let key = StorageBackupRetentionIndex.key(path:path,sha:attachment["sha256"] as! String,size:(attachment["size"] as! NSNumber).int64Value)
        XCTAssertEqual(observation.originals,[key])
        let backup = try XCTUnwrap(observation.copyPaths[key]?.first)
        XCTAssertEqual(observation.copyManifests[backup.path],ChecklistCore.hash(try Data(contentsOf:backup.appendingPathComponent("manifest.json"))))
        var checked = observation
        checked.verifyCopy(for:wanted)
        XCTAssertEqual(checked.verifiedCopies[key]?.isCurrent(),true)
    }

    func testSelectedPlansShareOneBackupDescriptorObservationAndRefreshNextPass() throws {
        let (project,first,_) = try fixture(),(_,second,_) = try fixture()
        // Place both selected tickets in one project without changing ownership
        // envelopes by creating the second one through normal project commands.
        let secondLocal = try call("task_create",["project_id":project["id"]!,"title":"Second selected Done ticket"])
        let file = directory.appendingPathComponent("second-evidence.txt")
        try Data("second evidence".utf8).write(to:file)
        _ = try call("attachment_add",["project_id":project["id"]!,"task_id":secondLocal["id"]!,"path":file.path,"mode":"managed_copy"])
        try mark(project,secondLocal,category:"done")
        var scans = 0
        let prepared = try router.readers!.read {db in
            db.trace {if case .statement(let statement) = $0,statement.sql.contains(Self.receiptReadSQL) {scans += 1}}
            defer {db.trace(nil)}
            return try self.router.ticketCleanupSelection(db,project:project)
        }
        XCTAssertEqual(prepared.plans.count,2)
        XCTAssertNotNil(prepared.plans[first["id"] as! String]);XCTAssertNil(prepared.plans[second["id"] as! String])
        XCTAssertLessThanOrEqual(scans,2,"Two completed generations are parsed at most once each for the complete selection")
        // CL-355: a later selection with the same generations reads no receipt value.
        scans = 0
        _ = try router.readers!.read {db in
            db.trace {if case .statement(let statement) = $0,statement.sql.contains(Self.receiptReadSQL) {scans += 1}}
            defer {db.trace(nil)}
            return try self.router.ticketCleanupSelection(db,project:project)
        }
        XCTAssertEqual(scans,0)
        // A subsequent selection must read the exact new generation contents.
        try write {db in try db.execute(sql:"UPDATE metadata SET value=? WHERE key GLOB 'backup-generation:*'",arguments:[try jsonString(["state":"complete","objects":[]])])}
        let refreshed = try router.readers!.read {try self.router.ticketCleanupSelection($0,project:project)}
        let objects = try XCTUnwrap(refreshed.plans[first["id"] as! String]?.byteDeletion.objects)
        XCTAssertTrue(objects.contains {strings($0,"reasons").contains("backup_required")})
    }

    func testUnavailableSharedBackupObservationDoesNotRescanPerPlan() throws {
        let (project,task,_) = try fixture()
        try write {db in try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?)",arguments:["backup-generation:invalid",try jsonString(["state":"complete","objects":[["path":"objects/invalid"]]])])}
        var headers = 0
        let prepared = try router.readers!.read {db in
            db.trace {if case .statement(let statement) = $0,statement.sql.contains(Self.fingerprintSQL) {headers += 1}}
            defer {db.trace(nil)}
            return try self.router.ticketCleanupSelection(db,project:project)
        }
        XCTAssertEqual(headers,1)
        let objects = try XCTUnwrap(prepared.plans[task["id"] as! String]?.byteDeletion.objects)
        XCTAssertTrue(objects.contains {strings($0,"reasons").contains("backup_authority_unavailable")})
    }
}

extension TicketLifecycleCleanupTests {
    func testOpenLifecycleChunkSkipsHistoryAndBackupObservations() throws {
        let (project,task,_) = try fixture(category:"active")
        var historyScans = 0,backupScans = 0
        let prepared = try router.readers!.read {db in
            db.trace {if case .statement(let statement) = $0 {
                if statement.sql.contains("MAX(occurred_at)") || statement.sql.contains("FROM events WHERE project_id=? ORDER BY seq LIMIT 100001") {historyScans += 1}
                if statement.sql.contains(Self.fingerprintSQL) || statement.sql.contains(Self.receiptReadSQL) {backupScans += 1}
            }}
            defer {db.trace(nil)}
            return try self.router.ticketCleanupSelection(db,project:project)
        }
        XCTAssertTrue(prepared.plans.isEmpty)
        XCTAssertEqual(historyScans,0);XCTAssertEqual(backupScans,0)
        let items = try XCTUnwrap(prepared.selection["items"] as? [JSON])
        XCTAssertEqual(items.first {$0["task_id"] as? String == task["id"] as? String}?["reason"] as? String,"open_ticket")
    }
}
