import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

/// CL-70: a command that fails leaves no orphan file copies, and a retry works.
extension EvidenceAuthorityTests {
    var storeRoot: URL { directory.appendingPathComponent("store") }

    /// Capture directories below source-captures/project-*/.
    func captureDirectories() throws -> [String] {
        let base = storeRoot.appendingPathComponent("source-captures")
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: base.path).flatMap { namespace in
            try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent(namespace).path).map { namespace + "/" + $0 }
        }.sorted()
    }
    func pendingMarkers() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: storeRoot.appendingPathComponent("staging/source-captures").path)) ?? []
    }
    func reopenRouter() throws { router = nil; router = try TestStore.router(root: storeRoot) }

    func testFailedSourceSubmitLeavesNoCaptureAndRetryLeavesOne() throws {
        try sourceFixture()
        let p = try project(), t = try ready(p), a = try claim(p, t)
        var failing = auth(p, a); failing["acceptance_revision"] = 1
        // The source capture succeeds; the missing artifact then rolls the submission back.
        failing["evidence_manifest"] = ["kind": "source", "source_capture": [:], "artifact_refs": [["artifact_id": UUID().uuidString, "sha256": String(repeating: "0", count: 64)]]]
        XCTAssertThrowsError(try call("work_submit", failing))
        XCTAssertEqual(try captureDirectories(), [], "a rolled-back submission keeps no capture copy")
        XCTAssertEqual(pendingMarkers(), [])

        let submitted = try submitSource(p, a)
        let manifest = try router.dbQueue.read { try router.record($0, submitted["manifest_id"] as! String, type: "manifest") }
        let capture = (manifest["evidence"] as! JSON)["source_capture"] as! JSON
        let directories = try captureDirectories()
        XCTAssertEqual(directories.count, 1, "the retry leaves exactly one capture")
        XCTAssertTrue((capture["snapshot_path"] as! String).contains(directories[0]))
        XCTAssertEqual(pendingMarkers(), [], "commit removes the pending marker")
    }

    func testStartupRemovesUncommittedCaptureAndKeepsCommittedOne() throws {
        try sourceFixture()
        let p = try project(), t = try ready(p), a = try claim(p, t)
        let submitted = try submitSource(p, a)
        let manifest = try router.dbQueue.read { try router.record($0, submitted["manifest_id"] as! String, type: "manifest") }
        let committedID = ((manifest["evidence"] as! JSON)["source_capture"] as! JSON)["id"] as! String
        let namespace = "project-" + ChecklistCore.hash(Data((p["id"] as! String).utf8))
        // A crash left one capture without a record, and one marker after a commit.
        let files = try StorageObjectFiles(root: storeRoot), orphan = UUID().uuidString.lowercased()
        try files.writeNew("source-captures/" + namespace + "/" + orphan + "/source/tracked.txt", bytes: Data("dirty".utf8), permissions: 0o444)
        for id in [orphan, committedID] {
            try files.writeNew("staging/source-captures/" + id + ".json", bytes: try JSONSerialization.data(withJSONObject: ["id": id, "namespace": namespace, "created_at": "2026-10-20T00:00:00Z"]))
        }
        XCTAssertEqual(try captureDirectories().count, 2)
        try reopenRouter()
        XCTAssertEqual(try captureDirectories(), [namespace + "/" + committedID])
        XCTAssertEqual(pendingMarkers(), [])
        // The committed capture still validates as the review target.
        XCTAssertNoThrow(try router.dbQueue.read { db in try router.validateCapturedFiles(try router.record(db, committedID, type: "source_capture")) })
    }

    func testFailedExportCanBeRetriedToTheSameDestination() throws {
        let p = try project(), t = try ready(p)
        try write("art/sprite.txt", "original bytes")
        let attachment = try call("attachment_add", ["project_id": p["id"]!, "task_id": t["id"]!, "path": workspace.appendingPathComponent("art/sprite.txt").path])
        let object = URL(fileURLWithPath: attachment["path"] as! String)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: object.path)
        try Data("damaged bytes!".utf8).write(to: object)
        let destination = directory.appendingPathComponent("exports/fixture-export")
        XCTAssertThrowsError(try call("export_project", ["project_id": p["id"]!, "path": destination.path])) { XCTAssertEqual(($0 as? CoreError)?.code, "SOURCE_CHANGED") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), [], "no partial export folder remains")

        try Data("original bytes".utf8).write(to: object)
        let exported = try call("export_project", ["project_id": p["id"]!, "path": destination.path])
        XCTAssertEqual(exported["path"] as? String, canonical(destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("project.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["fixture-export"])
        assertCode("DESTINATION_EXISTS") { _ = try self.call("export_project", ["project_id": p["id"]!, "path": destination.path]) }
    }

    /// Finding 5194cd31: the receipt INSERT fails after the export folder was published.
    func testExportRolledBackAtTheReceiptIsRemovedAndTheSameCommandRetrySucceeds() throws {
        let p = try project(), destination = directory.appendingPathComponent("exports/receipt-boundary")
        let command = UUID().uuidString, input: JSON = ["project_id": p["id"]!, "path": destination.path]
        // A per-connection trigger makes the receipt INSERT fail after export publication.
        try router.dbQueue.writeWithoutTransaction { db in try db.execute(sql: "CREATE TEMP TRIGGER synthetic_receipt_failure BEFORE INSERT ON commands BEGIN SELECT RAISE(ABORT,'synthetic receipt failure'); END") }
        XCTAssertThrowsError(try call("export_project", input, command: command))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "an export whose receipt rolled back is removed")
        try router.dbQueue.writeWithoutTransaction { db in try db.execute(sql: "DROP TRIGGER synthetic_receipt_failure") }
        let exported = try call("export_project", input, command: command)
        XCTAssertEqual(exported["path"] as? String, canonical(destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("project.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(ExportPublication.markerName).path), "a committed export keeps no owner marker")
        XCTAssertEqual(try router.handle(method: "export_project", params: input.merging(["command_id": command]) { $1 }, caller: owner)["replayed"] as? Bool, true)
    }

    func testCrashLeftExportIsReplacedOnlyByItsOwnCommand() throws {
        let p = try project(), destination = directory.appendingPathComponent("exports/crash-left")
        let command = UUID().uuidString, input: JSON = ["project_id": p["id"]!, "path": destination.path]
        // A crash after publication and before the receipt left this command's own folder.
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let digest = ChecklistCore.hash(Data(("export_project" + (try jsonString(input.merging(["command_id": command]) { $1 }))).utf8))
        try ExportPublication(destination: destination, principal: owner.principal, command: command, digest: digest).writeMarker(in: destination)
        XCTAssertNotNil(try call("export_project", input, command: command)["path"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("project.json").path))
        // A folder without this command's marker is never replaced.
        let foreign = directory.appendingPathComponent("exports/foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: foreign.appendingPathComponent("owner-file.txt"))
        assertCode("DESTINATION_EXISTS") { _ = try self.call("export_project", ["project_id": p["id"]!, "path": foreign.path]) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.appendingPathComponent("owner-file.txt").path))
    }

    func pendingExportRecords() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: storeRoot.appendingPathComponent("staging/pending-exports").path)) ?? []
    }

    /// Exercise the current file-publication boundary without its receipt/after-step.
    /// Copying is outside a writer transaction; this is an owned crash fixture only.
    func publishExportWithoutReceipt(_ input: JSON) throws {
        var injected = false
        do {
            try ArchiveStorageGate.withExclusive(root:storeRoot) { permit in
                try router.dbQueue.writeWithoutTransaction { db in
                    _ = try router.executeProjectExport(db,input,owner,permit:permit,observe:{ point in
                        if point == "published" { injected = true;throw CoreError("OWNED_EXPORT_CRASH","Synthetic exit before receipt.") }
                    })
                }
            }
            XCTFail("The synthetic publication fault did not run")
        } catch let error as CoreError where error.code == "OWNED_EXPORT_CRASH" {}
        XCTAssertTrue(injected)
    }

    /// Finding 97a3b139: a process exit after publication and before the receipt leaves an export
    /// that only the store's pending record can find. Startup removes it.
    func testStartupRemovesCrashLeftUncommittedExportAndKeepsCommittedOnes() throws {
        let p = try project(), crashed = directory.appendingPathComponent("exports/crash-window")
        let input: JSON = ["project_id": p["id"]!, "path": crashed.path, "command_id": UUID().uuidString]
        // The real publication runs, then its receipt and after-step are skipped.
        try publishExportWithoutReceipt(input)
        router.exportPublications = []
        XCTAssertTrue(FileManager.default.fileExists(atPath: crashed.appendingPathComponent("project.json").path))
        XCTAssertEqual(pendingExportRecords().count, 1, "the pending record is durable before publication")

        // A committed export whose after-step was lost keeps its folder; only the marker goes.
        let committed = directory.appendingPathComponent("exports/committed"), command = UUID().uuidString
        let committedInput: JSON = ["project_id": p["id"]!, "path": committed.path]
        _ = try call("export_project", committedInput, command: command)
        let digest = ChecklistCore.hash(Data(("export_project" + (try jsonString(committedInput.merging(["command_id": command]) { $1 }))).utf8))
        let leftover = ExportPublication(destination: committed, principal: owner.principal, command: command, digest: digest, journal: "staging/pending-exports/" + UUID().uuidString.lowercased() + ".json")
        try leftover.writeMarker(in: committed); try leftover.recordPending(StorageObjectFiles(root: storeRoot))
        // A recorded destination without this command's marker is never removed.
        let foreign = directory.appendingPathComponent("exports/foreign-recorded")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: foreign.appendingPathComponent("owner-file.txt"))
        try ExportPublication(destination: foreign, principal: owner.principal, command: UUID().uuidString, digest: digest, journal: "staging/pending-exports/" + UUID().uuidString.lowercased() + ".json").recordPending(StorageObjectFiles(root: storeRoot))
        XCTAssertEqual(pendingExportRecords().count, 3)

        try reopenRouter()
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashed.path), "the crash-left uncommitted export is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed.appendingPathComponent("project.json").path), "a committed export is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.appendingPathComponent(ExportPublication.markerName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.appendingPathComponent("owner-file.txt").path), "a foreign folder is kept")
        XCTAssertEqual(pendingExportRecords(), [], "every pending record is reconciled")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("exports").path).sorted(), ["committed", "foreign-recorded"], "no partial folder remains")
        // The crashed command can run again to the same destination.
        XCTAssertNotNil(try call("export_project", ["project_id": p["id"]!, "path": crashed.path], command: input["command_id"] as? String)["path"])
    }

    /// Finding 2e21045b: a cleanup that fails keeps its pending record, and a later startup retries it.
    func testStartupKeepsThePendingExportUntilItsCleanupSucceeds() throws {
        let p = try project(), parent = directory.appendingPathComponent("locked-exports")
        let crashed = parent.appendingPathComponent("crashed")
        let input: JSON = ["project_id": p["id"]!, "path": crashed.path, "command_id": UUID().uuidString]
        try publishExportWithoutReceipt(input)
        router.exportPublications = []
        // A committed export whose marker removal fails while its folder is not writable.
        let committed = directory.appendingPathComponent("locked-committed"), command = UUID().uuidString
        let committedInput: JSON = ["project_id": p["id"]!, "path": committed.path]
        _ = try call("export_project", committedInput, command: command)
        let digest = ChecklistCore.hash(Data(("export_project" + (try jsonString(committedInput.merging(["command_id": command]) { $1 }))).utf8))
        let leftover = ExportPublication(destination: committed, principal: owner.principal, command: command, digest: digest, journal: "staging/pending-exports/" + UUID().uuidString.lowercased() + ".json")
        try leftover.writeMarker(in: committed); try leftover.recordPending(StorageObjectFiles(root: storeRoot))
        XCTAssertEqual(pendingExportRecords().count, 2)

        for folder in [parent, committed] { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path) }
        defer { for folder in [parent, committed] { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) } }
        try reopenRouter()
        XCTAssertTrue(FileManager.default.fileExists(atPath: crashed.appendingPathComponent(ExportPublication.markerName).path), "a refused removal leaves the export and its marker intact")
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed.appendingPathComponent(ExportPublication.markerName).path))
        XCTAssertEqual(pendingExportRecords().count, 2, "a failed cleanup keeps its pending record")

        for folder in [parent, committed] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        try reopenRouter()
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashed.path), "a later startup removes the uncommitted export")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [], "no partial folder remains")
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed.appendingPathComponent("project.json").path), "the committed export is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.appendingPathComponent(ExportPublication.markerName).path))
        XCTAssertEqual(pendingExportRecords(), [], "every pending record is reconciled after its cleanup")
    }

    /// Finding 4b933bf0: an owner marker that cannot be read keeps the export and its record.
    func testStartupKeepsThePendingExportWhileItsMarkerIsUnreadable() throws {
        let p = try project(), crashed = directory.appendingPathComponent("marker-exports/crashed")
        let input: JSON = ["project_id": p["id"]!, "path": crashed.path, "command_id": UUID().uuidString]
        try publishExportWithoutReceipt(input)
        router.exportPublications = []
        let committed = directory.appendingPathComponent("marker-exports/committed"), command = UUID().uuidString
        let committedInput: JSON = ["project_id": p["id"]!, "path": committed.path]
        _ = try call("export_project", committedInput, command: command)
        let digest = ChecklistCore.hash(Data(("export_project" + (try jsonString(committedInput.merging(["command_id": command]) { $1 }))).utf8))
        let leftover = ExportPublication(destination: committed, principal: owner.principal, command: command, digest: digest, journal: "staging/pending-exports/" + UUID().uuidString.lowercased() + ".json")
        try leftover.writeMarker(in: committed); try leftover.recordPending(StorageObjectFiles(root: storeRoot))
        let markers = [crashed, committed].map { $0.appendingPathComponent(ExportPublication.markerName) }
        for marker in markers { try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: marker.path) }
        defer { for marker in markers { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path) } }
        XCTAssertEqual(leftover.ownership(), .unknown)
        try reopenRouter()
        XCTAssertTrue(FileManager.default.fileExists(atPath: crashed.appendingPathComponent("project.json").path), "an unreadable marker authorizes no removal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markers[1].path))
        XCTAssertEqual(pendingExportRecords().count, 2, "both records stay while ownership cannot be read")

        for marker in markers { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path) }
        try reopenRouter()
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashed.path), "a later startup removes the uncommitted export")
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed.appendingPathComponent("project.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markers[1].path))
        XCTAssertEqual(pendingExportRecords(), [])
        // A missing marker or another command's marker is foreign: the record goes and the folder stays.
        let foreign = directory.appendingPathComponent("marker-exports/foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        XCTAssertEqual(ExportPublication(destination: foreign, principal: owner.principal, command: command, digest: digest).ownership(), .foreign)
        try ExportPublication(destination: foreign, principal: owner.principal, command: UUID().uuidString, digest: digest).writeMarker(in: foreign)
        XCTAssertEqual(ExportPublication(destination: foreign, principal: owner.principal, command: command, digest: digest).ownership(), .foreign)
    }

    /// A retained crash journal reserves its original intent, even after startup could not
    /// read the destination marker. Other methods must refuse before preparing any files.
    func testRetainedExportJournalReservesIntentAcrossRestartAndAllowsOriginalRetry() throws {
        let p = try project(), t = try ready(p), command = UUID().uuidString
        let destination = directory.appendingPathComponent("retained-export/original")
        let changed = directory.appendingPathComponent("changed-export/second")
        let input: JSON = ["project_id": p["id"]!, "path": destination.path, "command_id": command]
        try publishExportWithoutReceipt(input)
        router.exportPublications = []
        let marker = destination.appendingPathComponent(ExportPublication.markerName)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: marker.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path) }
        try reopenRouter()
        XCTAssertEqual(pendingExportRecords().count, 1)
        assertCode("IDEMPOTENCY_CONFLICT") { _ = try self.call("export_project", ["project_id": p["id"]!, "path": changed.path], command: command) }
        assertCode("IDEMPOTENCY_CONFLICT") { _ = try self.call("backup_create", ["path": changed.path], command: command) }
        assertCode("IDEMPOTENCY_CONFLICT") { _ = try self.call("task_create", ["project_id": p["id"]!, "title": "Another intent"], command: command) }
        // A missing source would otherwise fail during import preparation, before the writer.
        assertCode("IDEMPOTENCY_CONFLICT") { _ = try self.call("attachment_add", ["project_id": p["id"]!, "task_id": t["id"]!, "path": self.workspace.appendingPathComponent("missing.txt").path], command: command) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: changed.deletingLastPathComponent().path), "no changed-intent file preparation or publication")
        XCTAssertEqual(pendingExportRecords().count, 1)
        XCTAssertEqual(try router.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM commands WHERE principal=? AND command_id=?", arguments: [owner.principal, command]) }, 0)

        // UUID ownership is principal-scoped, not global.
        let otherOwner = Caller(role: "owner", installation: "other-export-owner", projectIDs: [])
        _ = try call("export_project", ["project_id": p["id"]!, "path": changed.path], otherOwner, command: command)
        XCTAssertEqual(pendingExportRecords().count, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        XCTAssertNotNil(try call("export_project", ["project_id": p["id"]!, "path": destination.path], command: command)["path"], "the original intent can replace only its own uncommitted export")
        try reopenRouter()
        XCTAssertEqual(pendingExportRecords(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("project.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: changed.appendingPathComponent("project.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// A historical conflicting receipt is an uncertain outcome, not a commit or rollback
    /// of the journal's intent. Startup must preserve that journal and its owned export.
    func testStartupKeepsExportJournalForAConflictingReceipt() throws {
        let p = try project(), command = UUID().uuidString
        let destination = directory.appendingPathComponent("receipt-conflict/original")
        let input: JSON = ["project_id": p["id"]!, "path": destination.path, "command_id": command]
        try publishExportWithoutReceipt(input)
        let export = try XCTUnwrap(router.exportPublications.first)
        router.exportPublications = []
        let journal = storeRoot.appendingPathComponent(try XCTUnwrap(export.journal))
        let journalBytes = try Data(contentsOf: journal), markerBytes = try Data(contentsOf: export.marker)
        try router.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)", arguments: [self.owner.principal, command, "different-intent", "{}"])
        }
        try reopenRouter()
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("project.json").path))
        XCTAssertEqual(try? Data(contentsOf: export.marker), markerBytes)
        XCTAssertEqual(try? Data(contentsOf: journal), journalBytes, "a different digest cannot reconcile this journal")

        // With no receipt, the original intent is uncommitted and its own files can be cleaned.
        try router.dbQueue.write { db in try db.execute(sql: "DELETE FROM commands WHERE principal=? AND command_id=?", arguments: [self.owner.principal, command]) }
        try reopenRouter()
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(pendingExportRecords(), [])
    }

    func testPostCommandKeepsExportJournalForAConflictingReceipt() throws {
        let p = try project(), command = UUID().uuidString
        let destination = directory.appendingPathComponent("post-command-conflict/original")
        let input: JSON = ["project_id": p["id"]!, "path": destination.path, "command_id": command]
        try publishExportWithoutReceipt(input)
        let export = try XCTUnwrap(router.exportPublications.first)
        router.exportPublications = []
        let journal = storeRoot.appendingPathComponent(try XCTUnwrap(export.journal))
        let journalBytes = try Data(contentsOf: journal), markerBytes = try Data(contentsOf: export.marker)
        try router.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)", arguments: [self.owner.principal, command, "different-intent", "{}"])
        }
        router.finishExportPublications([export])
        XCTAssertEqual(try? Data(contentsOf: journal), journalBytes)
        XCTAssertEqual(try? Data(contentsOf: export.marker), markerBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("project.json").path))

        // Even if another folder now occupies the destination, the conflicting receipt gives
        // no authority to touch its marker or files, or the recorded private partial path.
        let foreign = ExportPublication(destination: destination, principal: owner.principal, command: UUID().uuidString, digest: export.digest)
        try FileManager.default.removeItem(at: export.marker)
        try foreign.writeMarker(in: destination)
        let foreignBytes = try Data(contentsOf: foreign.marker)
        let partial = try XCTUnwrap(export.partial)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false)
        let sentinel = partial.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        router.finishExportPublications([export])
        XCTAssertEqual(try? Data(contentsOf: journal), journalBytes)
        XCTAssertEqual(try? Data(contentsOf: foreign.marker), foreignBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))

        // Resolve the synthetic receipt to the original intent. Only its matching marker goes.
        try FileManager.default.removeItem(at: foreign.marker)
        try export.writeMarker(in: destination)
        try router.dbQueue.write { db in try db.execute(sql: "UPDATE commands SET digest=? WHERE principal=? AND command_id=?", arguments: [export.digest, self.owner.principal, command]) }
        router.finishExportPublications([export])
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.marker.path))
        XCTAssertEqual(pendingExportRecords(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("project.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path), "commit cleanup removes only the owner marker")
    }

    func testManagedImportRetryReusesBytesAndStartupSettlesOnlyAbandonedJobs() throws {
        let p = try project(), t = try ready(p)
        try write("art/committed.txt", "committed bytes"); try write("art/retried.txt", "retried bytes"); try write("art/abandoned.txt", "abandoned bytes")
        let committed = try call("attachment_add", ["project_id": p["id"]!, "task_id": t["id"]!, "path": workspace.appendingPathComponent("art/committed.txt").path])
        func prepareOnly(_ name: String, command: String) throws -> ManagedAttachmentPreparation {
            // Failure injection: files staged and published, then the command never commits.
            let input: JSON = ["project_id": p["id"]!, "task_id": t["id"]!, "path": workspace.appendingPathComponent(name).path, "command_id": command]
            return try XCTUnwrap(try router.dbQueue.writeWithoutTransaction { db in try router.prepareManagedAttachmentImport(db, method: "attachment_add", params: input, caller: owner) })
        }
        let retryCommand = UUID().uuidString, retried = try prepareOnly("art/retried.txt", command: retryCommand)
        let reused = try call("attachment_add", ["project_id": p["id"]!, "task_id": t["id"]!, "path": workspace.appendingPathComponent("art/retried.txt").path], command: retryCommand)
        XCTAssertEqual(reused["id"] as? String, retried.attachment["id"] as? String, "a same-command retry reuses the staged object")

        let abandoned = try prepareOnly("art/abandoned.txt", command: UUID().uuidString)
        let abandonedObject = try router.managedURL(abandoned.attachment["path"] as! String,family:"objects").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: abandonedObject))
        try reopenRouter()
        XCTAssertTrue(FileManager.default.fileExists(atPath: abandonedObject), "a job inside the grace period is retained")

        try router.dbQueue.write { db in
            var job = try router.record(db, abandoned.job["id"] as! String, type: "storage_job")
            job["created_at"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-8 * 86_400)); try router.save(db, job, type: "storage_job")
            for id in [committed["storage_job_id"] as! String, reused["storage_job_id"] as! String] {
                var old = try router.record(db, id, type: "storage_job"); old["created_at"] = job["created_at"]; try router.save(db, old, type: "storage_job")
            }
        }
        try reopenRouter()
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedObject), "the abandoned object is removed")
        let job = try router.dbQueue.read { try router.record($0, abandoned.job["id"] as! String, type: "storage_job") }
        XCTAssertEqual(job["state"] as? String, "settled"); XCTAssertEqual(job["settled_reason"] as? String, "abandoned_without_receipt")
        for kept in [committed, reused] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept["path"] as! String), "a committed object is never removed")
            XCTAssertNotNil(try call("attachment_read", ["project_id": p["id"]!, "attachment_id": kept["id"]!, "representation": "original"])["url"])
        }
        // The backup path accepts the settled job.
        XCTAssertNoThrow(try call("backup_create", ["path": directory.appendingPathComponent("backup-after-sweep").path]))
    }
}
