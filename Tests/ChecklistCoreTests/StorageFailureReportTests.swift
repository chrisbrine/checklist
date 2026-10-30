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

    func testCleanupCopyReasonKeepsTransientErrno() {
        let reason = TicketCleanupCopyFailure.reason(StorageSnapshotFailure.failed("openat",code:EMFILE))
        XCTAssertEqual(reason,"backup_copy_unverified:POSIX_24")
        XCTAssertTrue(TicketCleanupCopyFailure.isTransient(reason))
    }

    /// The condition of the 29 Oct failure: no free descriptor while the command
    /// starts, and others release theirs a moment later. The service retries by itself.
    func testAttachmentAddRetriesWhileOpenFilesAreExhausted() throws {
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
