import ChecklistTestSupport
import Darwin
import XCTest
@testable import ChecklistCore

/// CL-362. Exhaustion uses the process's real open-file limit: no injected errno
/// reaches the attachment and write tests, and the limit is restored before teardown.
final class StorageFailureReportTests: XCTestCase {
    /// Holds this process at `headroom` free descriptors below its soft limit.
    private final class Exhaustion: @unchecked Sendable {
        private var original = rlimit()
        private var padding: [Int32] = []
        private let lock = NSLock()
        private var active = true
        init(headroom: Int) throws {
            XCTAssertEqual(getrlimit(RLIMIT_NOFILE,&original),0)
            var low: Int32 = Darwin.open("/dev/null",O_RDONLY | O_CLOEXEC);Darwin.close(low)
            while low < 200 {let fd = Darwin.open("/dev/null",O_RDONLY | O_CLOEXEC);padding.append(fd);low = fd + 1}
            var limited = original;limited.rlim_cur = rlim_t(Int(low) + headroom)
            XCTAssertEqual(setrlimit(RLIMIT_NOFILE,&limited),0)
        }
        func release() {
            lock.lock();defer {lock.unlock()}
            guard active else {return};active = false
            _ = setrlimit(RLIMIT_NOFILE,&original)
            for fd in padding {Darwin.close(fd)}
        }
        deinit {release()}
    }
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock();private var values: [String] = []
        func add(_ line: String) {lock.lock();values.append(line);lock.unlock()}
        var all: [String] {lock.lock();defer {lock.unlock()};return values}
    }
    override func tearDown() {StorageFailureReport.setLogSink(nil)}
    private func source(_ f: StorageFixture,_ name: String) throws -> URL {
        let url = f.workspace.appendingPathComponent(name);try Data(repeating:65,count:7_210).write(to:url);return url
    }
    private func assertPlain(_ text: String,file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertNil(text.range(of:"error [0-9]+",options:.regularExpression),text,file:file,line:line)
        XCTAssertFalse(text.contains("StorageSnapshotFailure"),text,file:file,line:line)
        XCTAssertFalse(text.contains("couldn’t be completed"),text,file:file,line:line)
    }

    func testEveryFailureHasStableCodePlainReasonAndNextStep() {
        let system = {(code: Int32) in StorageSnapshotFailure.failed("openat",path:"objects/a",root:"/private/store",code:code)}
        let expected: [(StorageSnapshotFailure,String,Bool)] = [
            (.invalidFixture,"STORAGE_INVALID_STATE",false),(.unsupportedAuthority,"STORAGE_UNSUPPORTED_ENTRY",false),
            (.sourceChanged,"STORAGE_SOURCE_CHANGED",true),(.incomplete,"STORAGE_INCOMPLETE",false),
            (.limit,"STORAGE_LIMIT_EXCEEDED",false),(.canceled,"STORAGE_CANCELED",true),
            (.deadline,"STORAGE_DEADLINE_EXCEEDED",true),(.io,"STORAGE_IO_ERROR",true),
            (.publicationUncertain,"OUTCOME_UNKNOWN",true),(.freeSpace(measured:1),"STORAGE_FREE_SPACE",false),
            (system(EMFILE),"STORAGE_OPEN_FILES_EXHAUSTED",true),(system(ENFILE),"STORAGE_OPEN_FILES_EXHAUSTED",true),
            (system(EINTR),"STORAGE_TEMPORARILY_UNAVAILABLE",true),(system(ENOSPC),"STORAGE_DISK_FULL",false),
            (system(EACCES),"STORAGE_ACCESS_DENIED",false),(system(ENOENT),"STORAGE_FILE_MISSING",false),
            (system(EIO),"STORAGE_IO_ERROR",true)
        ]
        for (failure,code,retryable) in expected {
            let payload = PublicErrorText.payload(failure)
            XCTAssertEqual(payload["code"] as? String,code)
            XCTAssertEqual(payload["retryable"] as? Bool,retryable,code)
            let message = payload["message"] as? String ?? "",details = payload["details"] as? JSON ?? [:]
            XCTAssertEqual(details["retryable"] as? Bool,retryable,code)
            XCTAssertFalse((details["next_step"] as? String ?? "").isEmpty,code)
            XCTAssertTrue(message.hasSuffix(details["next_step"] as? String ?? "?"),message)
            assertPlain(message);assertPlain(failure.localizedDescription);assertPlain(PublicErrorText.describe(failure))
        }
    }

    func testSystemErrorKeepsOperationPathErrnoInReplyAndLog() throws {
        let lines = Lines();StorageFailureReport.setLogSink {lines.add($0)}
        let details = PublicErrorText.payload(StorageSnapshotFailure.failed("fsync",path:"objects/a.log",root:"/private/store",code:EIO))["details"] as! JSON
        XCTAssertEqual(details["operation"] as? String,"fsync")
        XCTAssertEqual(details["posix_errno"] as? Int,Int(EIO))
        XCTAssertEqual(details["errno_name"] as? String,"EIO")
        XCTAssertEqual(details["relative_path"] as? String,"objects/a.log")
        XCTAssertFalse(try jsonString(details).contains("/private/store"),"The reply must not expose the store root")
        let line = try XCTUnwrap(lines.all.first)
        for part in ["STORAGE_IO_ERROR","operation=fsync","errno=5","root=/private/store","path=objects/a.log"] {XCTAssertTrue(line.contains(part),line)}
    }

    /// A real failed system call carries its own errno and path to the report.
    func testRealSystemCallFailureCarriesErrno() throws {
        let f = try StorageFixture(open:false)
        let files = try StorageObjectFiles(root:f.workspace)
        try files.writeNew("exists.txt",bytes:Data("a".utf8))
        do {try files.writeNew("exists.txt",bytes:Data("b".utf8));XCTFail("Expected EEXIST")}
        catch let failure as StorageSnapshotFailure {
            let report = StorageFailureReport(failure)
            XCTAssertEqual(report.code,"STORAGE_IO_ERROR")
            XCTAssertEqual(report.details["errno_name"] as? String,"EEXIST")
            XCTAssertEqual(report.details["relative_path"] as? String,"exists.txt")
            XCTAssertEqual(report.details["operation"] as? String,"openat")
        }
    }

    func testBackupFailureKeepsCodeAndAddsCause() throws {
        let f = try StorageFixture(open:true,fast:true)
        let lines = Lines();StorageFailureReport.setLogSink {lines.add($0)}
        var budget = StorageSnapshotBudget.production()
        budget.observe = {if $0 == "copying_objects" {throw StorageSnapshotFailure.failed("openat",path:"objects/a.log",root:f.root.path,code:EMFILE)}}
        let destination = f.base.appendingPathComponent("backup")
        XCTAssertThrowsError(try f.router!.executeStorageBackup(params:["command_id":UUID().uuidString,"path":destination.path],caller:f.owner,budget:budget)) {
            let error = $0 as? CoreError
            XCTAssertEqual(error?.code,"BACKUP_IO_ERROR")
            XCTAssertEqual(error?.details["command_outcome"] as? String,"rejected")
            XCTAssertEqual(error?.details["posix_errno"] as? Int,Int(EMFILE))
            XCTAssertEqual(error?.details["relative_path"] as? String,"objects/a.log")
            XCTAssertEqual(error?.details["next_step"] as? String,"Retry backup_create with a new command ID.")
            XCTAssertTrue(error?.message.contains("EMFILE") == true)
        }
        XCTAssertTrue(lines.all.contains {$0.contains("BACKUP") || $0.contains("operation=openat")},"\(lines.all)")
    }

    private func operationRoute(_ f: StorageFixture) -> () -> Void {
        let queue = DispatchQueue(label:"checklist-cl362-" + UUID().uuidString)
        f.router!.configureCommandOperations(on:queue)
        return {queue.sync {}}
    }
    private func operation(_ f: StorageFixture,_ id: Any?,project: JSON? = nil,wait: () -> Void) throws -> JSON {
        var value = JSON()
        for _ in 0..<600 {
            wait()
            var input: JSON = ["operation_id":id ?? ""]
            if let project {input["project_id"] = project["id"]}
            value = try f.call("operation_get",input)["data"] as! JSON
            if ["failed","succeeded"].contains(value["state"] as? String ?? "") {return value}
            Thread.sleep(forTimeInterval:0.05)
        }
        return value
    }

    /// The reviewer's regression: a real EACCES on the backup destination. The stated
    /// step works: the same ID keeps its stored failure, and a new ID succeeds.
    func testBackupAccessDeniedRetriesWithNewCommandIDAfterAccessIsRestored() throws {
        let f = try StorageFixture(open:true,fast:true)
        let wait = operationRoute(f)
        let parent = f.base.appendingPathComponent("locked-parent")
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        chmod(parent.path,0o500)
        defer {chmod(parent.path,0o700)}
        let destination = parent.appendingPathComponent("backup"),command = UUID().uuidString.lowercased()
        let input: JSON = ["path":destination.path]
        let accepted = try f.call("backup_create",input,command:command)["data"] as! JSON
        let failed = try operation(f,accepted["operation_id"],wait:wait)
        XCTAssertEqual(failed["state"] as? String,"failed","\(failed)")
        let error = failed["error"] as? JSON ?? [:],details = error["details"] as? JSON ?? [:]
        XCTAssertEqual(error["code"] as? String,"BACKUP_IO_ERROR","\(error)")
        XCTAssertEqual(details["errno_name"] as? String,"EACCES","\(error)")
        XCTAssertEqual(details["retryable"] as? Bool,false)
        XCTAssertEqual(details["command_outcome"] as? String,"rejected")
        XCTAssertEqual(details["next_step"] as? String,"Restore access to the folder, then retry backup_create with a new command ID.")
        XCTAssertTrue((error["message"] as? String ?? "").hasSuffix(details["next_step"] as? String ?? "?"),"\(error)")
        XCTAssertFalse("\(error)".contains("same command ID"),"\(error)")
        chmod(parent.path,0o700)
        _ = try f.call("backup_create",input,command:command)
        let repeated = try operation(f,accepted["operation_id"],wait:wait)
        XCTAssertEqual(repeated["state"] as? String,"failed","The finished ID stays failed: \(repeated)")
        let next = try f.call("backup_create",input,command:UUID().uuidString.lowercased())["data"] as! JSON
        XCTAssertEqual(try operation(f,next["operation_id"],wait:wait)["state"] as? String,"succeeded")
    }

    /// Every backup step that leads to a retry names a new ID; a no-retry step stays one.
    func testBackupStepsNeverOfferTheFinishedCommandID() throws {
        let f = try StorageFixture(open:true,fast:true)
        for (code,next) in [(ENOSPC,"Free space on the volume, then retry backup_create with a new command ID."),(EDQUOT,"Free space on the volume, then retry backup_create with a new command ID."),(EPERM,"Restore access to the folder, then retry backup_create with a new command ID."),(EROFS,"Restore access to the folder, then retry backup_create with a new command ID."),(ENOENT,"Do not retry. Keep the store and report this command ID."),(EMFILE,"Retry backup_create with a new command ID.")] {
            var budget = StorageSnapshotBudget.production()
            budget.observe = {if $0 == "copying_objects" {throw StorageSnapshotFailure.failed("write",path:"objects/a.log",root:f.root.path,code:code)}}
            let destination = f.base.appendingPathComponent("step-" + UUID().uuidString)
            XCTAssertThrowsError(try f.router!.executeStorageBackup(params:["command_id":UUID().uuidString,"path":destination.path],caller:f.owner,budget:budget)) {
                let error = $0 as? CoreError
                XCTAssertEqual(error?.code,"BACKUP_IO_ERROR")
                XCTAssertEqual(error?.details["next_step"] as? String,next)
                XCTAssertEqual(error?.details["retryable"] as? Bool,StorageFailureReport.transientErrnos.contains(code))
                XCTAssertTrue(error?.message.hasSuffix(next) == true,error?.message ?? "")
            }
        }
        let unsafe: [StorageSnapshotFailure] = [.invalidFixture,.unsupportedAuthority,.sourceChanged,.incomplete,.canceled,.io,.freeSpace(measured:1),.limit,.deadline,.failed("mkdirat",code:EACCES)]
        for failure in unsafe {
            XCTAssertFalse(StorageFailureReport(failure).backupNextStep.contains("same command ID"),"\(failure)")
        }
        let budget = StorageSnapshotBudget.production()
        for error in [budget.freeSpaceFailure(measured:10,margin:1,available:2),budget.capacityFailure("snapshot_deadline")] {
            XCTAssertTrue((error.details["next_step"] as? String ?? "").contains("new command ID"),error.message)
            XCTAssertTrue(error.message.contains("new command ID"),error.message)
        }
    }

    /// attachment_add keeps same-ID recovery: the unreadable source and the store-side
    /// EACCES both leave a recoverable operation, which attaches once after the repair.
    func testAttachmentAddSameCommandSucceedsAfterSourceAccessIsRestored() throws {
        let f = try StorageFixture(open:true,fast:true)
        let wait = operationRoute(f)
        let p = try f.project(),t = try f.task(p),file = try source(f,"locked.log"),command = UUID().uuidString.lowercased()
        chmod(file.path,0o000)
        defer {chmod(file.path,0o600)}
        let input: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"path":file.path]
        let accepted = try f.call("attachment_add",input,command:command)["data"] as! JSON
        let failed = try operation(f,accepted["operation_id"],project:p,wait:wait)
        XCTAssertEqual(failed["state"] as? String,"failed","\(failed)")
        let error = failed["error"] as? JSON ?? [:]
        XCTAssertEqual(error["code"] as? String,"FILE_ACCESS_REQUIRED","\(error)")
        chmod(file.path,0o600)
        _ = try f.call("attachment_add",input,command:command)
        let done = try operation(f,accepted["operation_id"],project:p,wait:wait)
        XCTAssertEqual(done["state"] as? String,"succeeded","\(done)")
        let listed = try f.call("attachment_list",["project_id":p["id"]!,"task_id":t["id"]!])["data"] as! JSON
        XCTAssertEqual((listed["attachments"] as? [JSON])?.count,1,"\(listed)")
    }

    /// A store-side EACCES on the object folder is a finished rejection with no same-ID
    /// step. After the repair, a new command ID attaches the file once.
    func testAttachmentAddStoreAccessFailureOffersNoSameCommandAndNewCommandSucceeds() throws {
        let f = try StorageFixture(open:true,fast:true)
        let wait = operationRoute(f)
        let p = try f.project(),t = try f.task(p),file = try source(f,"store-side.log"),command = UUID().uuidString.lowercased()
        let objects = f.root.appendingPathComponent("objects")
        try FileManager.default.createDirectory(at:objects,withIntermediateDirectories:true)
        let mode = (try FileManager.default.attributesOfItem(atPath:objects.path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o700
        chmod(objects.path,0o500)
        defer {chmod(objects.path,mode)}
        let input: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"path":file.path]
        let accepted = try f.call("attachment_add",input,command:command)["data"] as! JSON
        let failed = try operation(f,accepted["operation_id"],project:p,wait:wait)
        XCTAssertEqual(failed["state"] as? String,"failed","\(failed)")
        let error = failed["error"] as? JSON ?? [:]
        XCTAssertEqual(error["code"] as? String,"STORAGE_OBJECT_UNAVAILABLE","\(error)")
        XCTAssertFalse("\(error)".contains("same command ID"),"\(error)")
        chmod(objects.path,mode)
        let next = try f.call("attachment_add",input,command:UUID().uuidString.lowercased())["data"] as! JSON
        XCTAssertEqual(try operation(f,next["operation_id"],project:p,wait:wait)["state"] as? String,"succeeded")
        let listed = try f.call("attachment_list",["project_id":p["id"]!,"task_id":t["id"]!])["data"] as! JSON
        XCTAssertEqual((listed["attachments"] as? [JSON])?.count,1,"\(listed)")
    }

    /// The folder errors say what their command ID can do: a missing folder is finished.
    func testMissingFolderIsRejectedWithNewCommandStep() throws {
        let f = try StorageFixture(open:true,fast:true)
        let wait = operationRoute(f)
        let input: JSON = ["path":f.base.appendingPathComponent("absent/backup").path],command = UUID().uuidString.lowercased()
        let accepted = try f.call("backup_create",input,command:command)["data"] as! JSON
        let failed = try operation(f,accepted["operation_id"],wait:wait)
        let error = failed["error"] as? JSON ?? [:],details = error["details"] as? JSON ?? [:]
        XCTAssertEqual(error["code"] as? String,"FOLDER_ACCESS_UNAVAILABLE","\(error)")
        XCTAssertEqual(details["command_outcome"] as? String,"rejected","\(error)")
        XCTAssertTrue((details["next_step"] as? String ?? "").contains("new command ID"),"\(error)")
        _ = try f.call("backup_create",input,command:command)
        XCTAssertEqual(try operation(f,accepted["operation_id"],wait:wait)["state"] as? String,"failed")
    }

    /// Outside backup_create, the report keeps an accepted operation recoverable, so its same-ID steps work.
    func testReportedAccessAndSpaceFailuresStayRecoverableOutsideBackup() {
        for code in [EACCES,EPERM,EROFS,ENOSPC,EDQUOT] {
            let details = PublicErrorText.payload(StorageSnapshotFailure.failed("write",path:"objects/a",code:code))["details"] as? JSON ?? [:]
            XCTAssertEqual(details["command_outcome"] as? String,"unknown")
            XCTAssertTrue((details["next_step"] as? String ?? "").hasSuffix("then retry with the same command ID."),"\(details)")
        }
    }

    /// Default-group cover of the retry rule. The real-limit cases that wait through the
    /// production pauses (over 1 s each) run in qualification.
    func testTransientFailureRetriesWithoutPausesAndThenSucceeds() throws {
        let lines = Lines();StorageFailureReport.setLogSink {lines.add($0)}
        var attempts = 0
        let value: Int = try StorageFailureReport.retryingTransient(pauses:[0,0]) {
            attempts += 1
            if attempts < 3 {throw StorageSnapshotFailure.failed("openat",path:"objects/a",code:EMFILE)}
            return 7
        }
        XCTAssertEqual(value,7);XCTAssertEqual(attempts,3)
        XCTAssertEqual(lines.all.filter {$0.contains("STORAGE_TRANSIENT_RETRY")}.count,2)
        XCTAssertThrowsError(try StorageFailureReport.retryingTransient(pauses:[0]) {throw StorageSnapshotFailure.failed("openat",code:EMFILE)}) {
            let details = PublicErrorText.payload($0)["details"] as? JSON ?? [:]
            XCTAssertEqual(details["retryable"] as? Bool,true)
            XCTAssertEqual(details["command_outcome"] as? String,"unknown")
            XCTAssertEqual(details["next_step"] as? String,StorageFailureReport.retrySameCommand)
        }
        XCTAssertThrowsError(try StorageFailureReport.retryingTransient(pauses:[0,0]) {() throws -> Int in attempts += 1;throw StorageSnapshotFailure.failed("openat",code:EACCES)})
        XCTAssertEqual(attempts,4,"A non-transient failure runs once")
    }

    func testCleanupCopyReasonKeepsTransientErrno() {
        let reason = TicketCleanupCopyFailure.reason(StorageSnapshotFailure.failed("openat",code:EMFILE))
        XCTAssertEqual(reason,"backup_copy_unverified:POSIX_24")
        XCTAssertTrue(TicketCleanupCopyFailure.isTransient(reason))
    }

    /// The condition of the 29 Oct failure: no free descriptor while the command
    /// starts, and others release theirs a moment later. The service retries by itself.
    func testAttachmentAddRetriesWhileOpenFilesAreExhausted() throws {
        try QualificationSuite.requireEnabled()
        let f = try StorageFixture(open:true,fast:true)
        let p = try f.project(),t = try f.task(p),file = try source(f,"core-restart-fix.log")
        let lines = Lines();StorageFailureReport.setLogSink {lines.add($0)}
        let exhaustion = try Exhaustion(headroom:2)
        DispatchQueue.global().asyncAfter(deadline:.now() + 0.4) {exhaustion.release()}
        let reply = try f.call("attachment_add",["project_id":p["id"]!,"task_id":t["id"]!,"path":file.path,"expected_sha256":StorageObjectFiles.sha(try Data(contentsOf:file))])
        exhaustion.release()
        XCTAssertNotNil((reply["data"] as? JSON)?["id"])
        XCTAssertTrue(lines.all.contains {$0.contains("STORAGE_TRANSIENT_RETRY")},"The condition did not occur: \(lines.all)")
    }

    /// Exhaustion that outlasts the bounded retries is reported as retryable, and
    /// the same command ID then attaches the file exactly once.
    func testAttachmentAddReportsRetryableThenSameCommandSucceeds() throws {
        try QualificationSuite.requireEnabled()
        let f = try StorageFixture(open:true,fast:true)
        let p = try f.project(),t = try f.task(p),file = try source(f,"held.log"),command = UUID().uuidString.lowercased()
        let input: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"path":file.path]
        let exhaustion = try Exhaustion(headroom:2)
        var failure: Error?
        do {_ = try f.call("attachment_add",input,command:command)} catch {failure = error}
        exhaustion.release()
        let payload = PublicErrorText.payload(try XCTUnwrap(failure))
        let details = payload["details"] as? JSON ?? [:],message = payload["message"] as? String ?? ""
        XCTAssertEqual(payload["retryable"] as? Bool,true,"\(payload)")
        XCTAssertEqual((details["posix_errno"] as? NSNumber)?.int32Value,EMFILE,"\(payload)")
        XCTAssertEqual(details["command_outcome"] as? String,"unknown")
        XCTAssertTrue(message.contains("too many files open"),message);assertPlain(message)
        let first = try f.call("attachment_add",input,command:command)["data"] as? JSON
        let second = try f.call("attachment_add",input,command:command)["data"] as? JSON
        XCTAssertEqual(first?["id"] as? String,second?["id"] as? String)
    }

    /// Accepted-operation route: the failed operation stays recoverable, so the same ID runs again.
    func testOperationRouteRequeuesSameCommandAfterExhaustion() throws {
        try QualificationSuite.requireEnabled()
        let f = try StorageFixture(open:true,fast:true)
        let p = try f.project(),t = try f.task(p),file = try source(f,"operation.log"),command = UUID().uuidString.lowercased()
        let queue = DispatchQueue(label:"checklist-cl362-" + UUID().uuidString)
        f.router!.configureCommandOperations(on:queue)
        func finish() {queue.sync {}}
        final class Box: @unchecked Sendable {var exhaustion: Exhaustion?}
        let box = Box()
        // Lift the limit as soon as the retries end, so the failed state can be recorded.
        StorageFailureReport.setLogSink {if !$0.contains("STORAGE_TRANSIENT_RETRY") {box.exhaustion?.release()}}
        f.router!.commandOperations.executionProbe = {_ in box.exhaustion = try? Exhaustion(headroom:2)}
        let input: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"path":file.path]
        let accepted = try f.call("attachment_add",input,command:command)["data"] as! JSON
        finish()
        box.exhaustion?.release()
        f.router!.commandOperations.executionProbe = nil
        let id = accepted["operation_id"]!
        let failed = try f.call("operation_get",["project_id":p["id"]!,"operation_id":id])["data"] as! JSON
        XCTAssertEqual(failed["state"] as? String,"failed","\(failed)")
        let error = failed["error"] as? JSON ?? [:],details = error["details"] as? JSON ?? [:]
        XCTAssertEqual(details["retryable"] as? Bool,true,"\(error)")
        XCTAssertEqual(details["posix_errno"] as? Int,Int(EMFILE),"\(error)")
        assertPlain(error["message"] as? String ?? "")
        _ = try f.call("attachment_add",input,command:command)
        finish()
        let done = try f.call("operation_get",["project_id":p["id"]!,"operation_id":id])["data"] as! JSON
        XCTAssertEqual(done["state"] as? String,"succeeded","\(done)")
    }

    /// The whole headroom range at the real limit: a caller never sees "error N".
    func testSmallWritesAtEveryHeadroomGiveCodedErrors() throws {
        try QualificationSuite.requireEnabled()
        let f = try StorageFixture(open:true,fast:true)
        let p = try f.project(),t = try f.task(p)
        let lines = Lines();StorageFailureReport.setLogSink {_ in}
        var attachmentFirstSuccess: Int?
        for (method,top) in [("message_send",8),("attachment_add",64)] {
            for headroom in stride(from:0,through:top,by:method == "message_send" ? 1 : 4) {
                var input: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"command_id":UUID().uuidString]
                if method == "message_send" {input["body"] = "Probe \(headroom)"}
                else {input["path"] = try source(f,"sweep-\(headroom).log").path}
                let exhaustion = try Exhaustion(headroom:headroom)
                var outcome = "ok"
                do {_ = try StorageFailureReport.retryingTransient(pauses:[]) {try f.router!.handle(method:method,params:input,caller:f.owner)}}
                catch {
                    exhaustion.release()
                    let payload = PublicErrorText.payload(error)
                    outcome = "\(payload["code"] ?? "?") retryable=\(payload["retryable"] ?? "?") errno=\((payload["details"] as? JSON)?["posix_errno"] ?? "-")"
                    assertPlain(payload["message"] as? String ?? "")
                    XCTAssertNotEqual(payload["code"] as? String,"COMMAND_FAILED")
                    XCTAssertEqual(payload["retryable"] as? Bool,true,"\(method) \(headroom): \(payload)")
                }
                exhaustion.release()
                if method == "attachment_add",outcome == "ok",attachmentFirstSuccess == nil {attachmentFirstSuccess = headroom}
                lines.add("\(method) headroom=\(headroom) -> \(outcome)")
            }
        }
        for line in lines.all {print("SWEEP " + line)}
        print("SWEEP attachment_add first success at headroom \(attachmentFirstSuccess.map(String.init) ?? "none")")
    }
}
