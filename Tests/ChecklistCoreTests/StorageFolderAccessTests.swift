import ChecklistTestSupport
import XCTest
import Darwin
import GRDB
@testable import ChecklistCore

final class StorageFolderAccessTests: XCTestCase {
    /// Keep both ends open and never write: the child really blocks in read,
    /// independent of permissions, TCC, sync state or machine load.
    private func blocked(_ folder: URL, _ body: (StorageFolderAccess) throws -> Void) throws {
        var ends = [Int32](repeating:0,count:2)
        XCTAssertEqual(pipe(&ends),0)
        defer { Darwin.close(ends[0]);Darwin.close(ends[1]) }
        var access = StorageFolderAccess(), children: [pid_t] = []
        access.timeout = 0.15
        access.reusePinnedRoots = false
        access.blockingReadDescriptor = { $0.standardizedFileURL.path == folder.standardizedFileURL.path ? ends[0] : -1 }
        access.observeChild = {children.append($0)}
        let start = ProcessInfo.processInfo.systemUptime
        try body(access)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,3)
        // The finite process exit event reaps the child without an open worker
        // thread, process wait thread or a repeated service timer.
        let reaped = expectation(description:"killed openers are reaped")
        let childPIDs = children
        DispatchQueue.global().asyncAfter(deadline:.now()+0.5) {
            for child in childPIDs {
                XCTAssertEqual(waitpid(child,nil,WNOHANG),-1)
                XCTAssertEqual(errno,ECHILD)
            }
            reaped.fulfill()
        }
        wait(for:[reaped],timeout:3)
    }
    private func timeout(_ error: Error, folder: URL) {
        let error = error as? CoreError
        XCTAssertEqual(error?.code,"FOLDER_ACCESS_TIMED_OUT")
        XCTAssertEqual(error?.details["folder"] as? String,folder.path)
        XCTAssertTrue(error?.message.contains(folder.path) == true)
        XCTAssertTrue(error?.message.contains("privacy") == true)
        XCTAssertTrue(error?.message.contains("sync") == true)
    }

    func testBlockedRootOpenEndsAndReapsChild() throws {
        try QualificationSuite.requireEnabled()
        let f = try StorageFixture()
        try blocked(f.workspace) { access in
            XCTAssertThrowsError(try StorageObjectFiles(root:f.workspace,folderAccess:access)) {self.timeout($0,folder:f.workspace)}
            XCTAssertEqual((try f.call("service_info")["data"] as? JSON)?["name"] as? String,"Checklist")
        }
    }
    func testRootBoundaryRunsOnceForManyRelativeFileOperations() throws {
        let f = try StorageFixture()
        var access = StorageFolderAccess(),opens = 0
        access.blockingReadDescriptor = { _ in opens += 1;return -1 }
        let files = try StorageObjectFiles(root:f.workspace,folderAccess:access)
        for i in 0..<40 {
            let path = "new/child/file-\(i)"
            try files.writeNew(path,bytes:Data([1,2,3]))
            XCTAssertEqual(try files.read(path,maximum:3),Data([1,2,3]))
            XCTAssertTrue(try files.regularOrLinkExists(path))
        }
        XCTAssertEqual(opens,1,"Relative files/descendants must never spawn another root opener")
    }
    func testRepeatedStoreReadersReuseRouterPinnedRootWithoutChildren() throws {
        let f = try StorageFixture(),bytes = Data([4,5,6])
        try bytes.write(to:f.root.appendingPathComponent("reader.bin"))
        var access = StorageFolderAccess(),opens = 0
        access.blockingReadDescriptor = { _ in opens += 1;return -1 }
        for _ in 0..<1000 { XCTAssertEqual(try StorageObjectFiles(root:f.root,folderAccess:access).read("reader.bin",maximum:3),bytes) }
        XCTAssertEqual(opens,0,"Short-lived managed readers must reuse the live router's verified store root")
    }
    func testSustainedRootOpensReuseOneHelperAndReapItsBlockedGeneration() throws {
        let f = try StorageFixture(),bytes = Data([1,2,3])
        try bytes.write(to:f.workspace.appendingPathComponent("source"))
        var access = StorageFolderAccess(),children: [pid_t] = []
        access.observeChild = {children.append($0)}
        for _ in 0..<1000 {
            XCTAssertEqual(try StorageObjectFiles(root:f.workspace,folderAccess:access).read("source",maximum:3),bytes)
        }
        XCTAssertEqual(Set(children).count,1,"Sustained root requests must reuse one native helper")
        var ends = [Int32](repeating:0,count:2)
        XCTAssertEqual(pipe(&ends),0)
        defer { Darwin.close(ends[0]);Darwin.close(ends[1]) }
        access.timeout = 0.15
        access.blockingReadDescriptor = { _ in ends[0] }
        XCTAssertThrowsError(try StorageObjectFiles(root:f.workspace,folderAccess:access)) {self.timeout($0,folder:f.workspace)}
        let finished = expectation(description:"retired helper generation reaped")
        let childPIDs = children
        DispatchQueue.global().asyncAfter(deadline:.now()+0.5) {
            for child in childPIDs { XCTAssertEqual(waitpid(child,nil,WNOHANG),-1);XCTAssertEqual(errno,ECHILD) }
            finished.fulfill()
        }
        wait(for:[finished],timeout:3)
    }
    func testMissingRootUsesStructuredErrnoAfterOtherSyscalls() throws {
        let f = try StorageFixture(),files = try StorageObjectFiles(root:f.workspace)
        do { _ = try StorageObjectFiles(root:f.workspace.appendingPathComponent("missing"));XCTFail("missing root") }
        catch { errno = ECHILD;XCTAssertTrue(StorageFolderAccess.isMissing(error)) }
        XCTAssertFalse(try files.regularOrLinkExists("missing/file"))
    }
    func testPinnedStoreGateRefusesAncestorSymlinkEvenWhenRootInodeMatches() throws {
        let f = try StorageFixture(),ancestor = f.workspace.appendingPathComponent("ancestor"),root = ancestor.appendingPathComponent("store")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let files = try StorageObjectFiles(root:root,pinRootForGates:true),moved = f.workspace.appendingPathComponent("moved")
        try FileManager.default.moveItem(at:ancestor,to:moved)
        try FileManager.default.createSymbolicLink(at:ancestor,withDestinationURL:moved)
        XCTAssertThrowsError(try ArchiveStorageGate.withExclusive(root:root,files:files) {_ in XCTFail("ancestor symlink must not receive gate authority")}) {
            XCTAssertEqual(($0 as? CoreError)?.details["reason"] as? String,"store_root_identity_changed")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:moved.appendingPathComponent("store/.archive-storage.lock").path))
    }

    func testPinnedStoreGateRefusesReplacedRootBeforeCreatingLock() throws {
        let f = try StorageFixture(),files = try StorageObjectFiles(root:f.workspace,pinRootForGates:true)
        let moved = f.base.appendingPathComponent("moved-workspace")
        try FileManager.default.moveItem(at:f.workspace,to:moved)
        try FileManager.default.createDirectory(at:f.workspace,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:f.workspace);try? FileManager.default.moveItem(at:moved,to:f.workspace)}
        XCTAssertThrowsError(try ArchiveStorageGate.withExclusive(root:f.workspace,files:files) {_ in XCTFail("replaced root must not receive gate authority")}) {
            XCTAssertEqual(($0 as? CoreError)?.details["reason"] as? String,"store_root_identity_changed")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.workspace.appendingPathComponent(".archive-storage.lock").path))
    }

    func testBlockedManagedOwnerAnswerEndsBeforeSourceObservationAndRetryCommitsOnce() throws {
        try QualificationSuite.requireEnabled()
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p),source = f.workspace.appendingPathComponent("answer.bin")
        try Data([4,5,6]).write(to:source)
        let request = try XCTUnwrap(try f.call("human_request_create",["project_id":p["id"]!,"task_id":t["id"]!,"file_requests":[["id":"files","prompt":"Select a file","kind":"file"]]])["data"] as? JSON)
        let command = UUID().uuidString,input: JSON = ["project_id":p["id"]!,"request_id":request["id"]!,"expected_revision":request["revision"]!,"command_id":command,"files":[["file_request_id":"files","paths":[source.path],"mode":"managed"]]]
        try blocked(f.workspace) { access in
            XCTAssertThrowsError(try f.router!.prepareHumanRequestAnswerFiles(params:input,caller:f.owner,folderAccess:access)) {self.timeout($0,folder:f.workspace)}
            XCTAssertEqual(try f.router!.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM records WHERE type='attachment'")},0)
        }
        let first = try f.call("human_request_answer",input,command:command)
        XCTAssertEqual((first["data"] as? JSON)?["state"] as? String,"answered")
        XCTAssertEqual(try f.call("human_request_answer",input,command:command)["replayed"] as? Bool,true)
        XCTAssertEqual(try f.router!.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM records WHERE type='attachment'")},1)
    }

    func testSelectedPathNormalizationIsLexicalAndSourceSymlinkStaysRefused() throws {
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p)
        let actual = f.workspace.appendingPathComponent("actual"),link = f.workspace.appendingPathComponent("link")
        try FileManager.default.createDirectory(at:actual,withIntermediateDirectories:true)
        try Data([1]).write(to:actual.appendingPathComponent("source"))
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:actual)
        let raw = link.path + "/./missing/../source"
        XCTAssertEqual(try StorageFolderAccess.lexicalPath(raw),link.path + "/source")
        XCTAssertEqual(try StorageFolderAccess.lexicalPath("/tmp/one/../two"),"/private/tmp/two")
        XCTAssertThrowsError(try StorageFolderAccess.lexicalPath("relative/source"))
        var access = f.router!.managedImportAccessOutsideWriter(),opened: [String] = []
        access.folderAccess.blockingReadDescriptor = {opened.append($0.path);return -1}
        XCTAssertThrowsError(try f.router!.prepareManagedAttachmentImport(method:"attachment_add",params:["project_id":p["id"]!,"task_id":t["id"]!,"path":raw,"command_id":UUID().uuidString],caller:f.owner,access:access))
        XCTAssertTrue(opened.contains(link.path))
        XCTAssertFalse(opened.contains(actual.path))
    }

    func testRelativeWalkRejectsReplacedAncestorWithoutAnotherChild() throws {
        let f = try StorageFixture()
        var access = StorageFolderAccess(),opens = 0
        access.blockingReadDescriptor = {_ in opens += 1;return -1}
        let files = try StorageObjectFiles(root:f.workspace,folderAccess:access)
        let first = try files.parent("one/two/file",create:true);Darwin.close(first.0)
        let opened = opens
        for _ in 0..<100 {let value = try files.parent("one/two/file");Darwin.close(value.0)}
        XCTAssertEqual(opens,opened)
        let original = f.workspace.appendingPathComponent("one"),moved = f.workspace.appendingPathComponent("moved")
        try FileManager.default.moveItem(at:original,to:moved)
        try FileManager.default.createSymbolicLink(at:original,withDestinationURL:moved)
        XCTAssertThrowsError(try files.parent("one/two/file")) { guard case StorageSnapshotFailure.io = $0 else { return XCTFail("Unexpected error: \($0)") } }
        XCTAssertEqual(opens,opened)
    }
    func testFIFOIsRefusedWithoutBlockingOnFinalOpen() throws {
        try QualificationSuite.requireEnabled()
        let f = try StorageFixture(),source = f.workspace.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(source.path,0o600),0)
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try StorageObjectFiles(root:f.workspace).read("fifo",maximum:1024))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-started,2)
    }
    func testFolderSymlinksStayRefusedAndMissingDirectoryIsDistinct() throws {
        let f = try StorageFixture(),link = f.base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:f.workspace)
        XCTAssertThrowsError(try StorageObjectFiles(root:link))
        let files = try StorageObjectFiles(root:f.base)
        XCTAssertThrowsError(try files.parent("link/file"))
        XCTAssertThrowsError(try files.directoryExists("link"))
        XCTAssertFalse(try files.directoryExists("missing"))
        XCTAssertTrue(try files.directoryExists("workspace"))
    }
    func testTimedOutUncommittedImportRetainsIntentAndSameIDRetryCommitsOnceAfterRestart() throws {
        try QualificationSuite.requireEnabled()
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p),source = f.workspace.appendingPathComponent("source.bin")
        try Data([1,2,3]).write(to:source)
        let command = UUID().uuidString,input: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path,"command_id":command]
        let key = try f.router!.managedImportKey(principal:f.owner.principal,command:command)
        var attachmentID = ""
        try blocked(f.workspace) { opener in
            var access = f.router!.managedImportAccessOutsideWriter();access.folderAccess = opener
            XCTAssertThrowsError(try f.router!.prepareManagedAttachmentImport(method:"attachment_add",params:input,caller:f.owner,access:access)) { self.timeout($0,folder:f.workspace) }
            try f.router!.dbQueue.read { db in
                let job = try f.router!.record(db,key,type:"storage_job")
                XCTAssertEqual(job["state"] as? String,"reserved");attachmentID = job["attachment_id"] as! String
                XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE type='attachment'"),0)
                XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands WHERE command_id=?",arguments:[command]),0)
            }
        }
        try f.reopen()
        let first = try f.call("attachment_add",input,command:command),a = try XCTUnwrap(first["data"] as? JSON)
        XCTAssertEqual(a["id"] as? String,attachmentID)
        try FileManager.default.removeItem(at:source)
        let replay = try f.call("attachment_add",input,command:command)
        XCTAssertEqual((replay["data"] as? JSON)?["id"] as? String,attachmentID)
        XCTAssertEqual(replay["replayed"] as? Bool,true)
        try f.router!.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE type='attachment'"),1)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands WHERE command_id=?",arguments:[command]),1)
        }
    }
    func testFinalizedUncommittedImportRetryUsesRetainedBytesWithoutReopeningSource() throws {
        let f = try StorageFixture(),p = try f.project(),t = try f.task(p),source = f.workspace.appendingPathComponent("source.bin")
        try Data([9,8,7]).write(to:source)
        let input: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"path":source.path,"command_id":UUID().uuidString]
        let first = try XCTUnwrap(f.router!.prepareManagedAttachmentImport(method:"attachment_add",params:input,caller:f.owner,access:f.router!.managedImportAccessOutsideWriter()))
        try f.reopen()
        var access = f.router!.managedImportAccessOutsideWriter()
        access.folderAccess.blockingReadDescriptor = { folder in
            XCTAssertNotEqual(folder.path,f.workspace.path,"Retained finalization must not reopen the external source")
            return -1
        }
        let second = try XCTUnwrap(f.router!.prepareManagedAttachmentImport(method:"attachment_add",params:input,caller:f.owner,access:access))
        XCTAssertEqual(first.attachment["id"] as? String,second.attachment["id"] as? String)
        XCTAssertEqual(first.attachment["sha256"] as? String,second.attachment["sha256"] as? String)
    }
    func testBlockedBackupDestinationEndsReleasesRetentionAndSameIDRetryCompletes() throws {
        try QualificationSuite.requireEnabled()
        try blockedBackup(source:false)
    }
    func testBlockedBackupSourceEndsReleasesRetentionAndSameIDRetryCompletes() throws {
        try QualificationSuite.requireEnabled()
        try blockedBackup(source:true)
    }
    private func blockedBackup(source: Bool) throws {
        let f = try StorageFixture(),command = UUID().uuidString,destination = f.base.appendingPathComponent("backup")
        let folder = source ? f.root : f.base
        try blocked(folder) { access in
            var budget = StorageSnapshotBudget.production();budget.folderAccess = access
            XCTAssertThrowsError(try f.router!.executeStorageBackup(params:["command_id":command,"path":destination.path],caller:f.owner,budget:budget)) { self.timeout($0,folder:folder) }
            XCTAssertFalse(try StorageSnapshotRetention.isActive(root:f.root))
            XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
            XCTAssertEqual(try f.router!.dbQueue.read {try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM commands WHERE command_id=?",arguments:[command])},0)
        }
        let result = try f.call("backup_create",["path":destination.path],command:command)
        XCTAssertEqual((result["data"] as? JSON)?["status"] as? String,"complete")
        XCTAssertEqual(try f.call("backup_create",["path":destination.path],command:command)["replayed"] as? Bool,true)
    }
}
