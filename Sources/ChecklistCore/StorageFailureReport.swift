import Foundation
import os
import Darwin
import GRDB

/// CL-362: the system call behind a storage failure, carried by value to the
/// point where it reaches a caller. `path` is relative to the opened root, so a
/// reply never exposes the store's absolute location.
struct StorageSystemFailure {
    let operation: String
    let path: String?
    let code: Int32
    /// The opened root, for the log only.
    var root: String? = nil
}

extension StorageSnapshotFailure {
    /// Reads errno at the throw, before any cleanup can change it.
    static func failed(_ operation: String,path: String? = nil,root: String? = nil,code: Int32 = errno) -> StorageSnapshotFailure {
        .systemCall(StorageSystemFailure(operation:operation,path:path,code:code,root:root))
    }
    var isIO: Bool {
        switch self {
        case .io,.systemCall: return true
        default: return false
        }
    }
}

// A failure that reaches a caller reads as its reason and next step, never "error N".
extension StorageSnapshotFailure: LocalizedError {
    var errorDescription: String? {StorageFailureReport(self).message}
}

/// The stable public form of one StorageSnapshotFailure.
struct StorageFailureReport {
    let code: String
    let reason: String
    let explanation: String
    let nextStep: String
    let retryable: Bool
    let system: StorageSystemFailure?

    static let retrySameCommand = "Retry with the same command ID; a repeat cannot apply the change twice."
    /// Errors that clear by themselves. EMFILE and ENFILE occur when the service or the Mac has too many files open.
    static let transientErrnos: Set<Int32> = [EMFILE,ENFILE,EINTR,EAGAIN,EBUSY,ETIMEDOUT]
    /// Bounded in-service pauses for attachment_add before it reports the failure (3.25 s in all).
    static let transientRetryPauses: [TimeInterval] = [0.25,1,2]

    init(_ failure: StorageSnapshotFailure) {
        var system: StorageSystemFailure?
        let row: (String,String,String,String,Bool)
        switch failure {
        case .invalidFixture:
            row = ("STORAGE_INVALID_STATE","invalid_state","Checklist found an unexpected state in its storage.","Do not retry. Keep the store and report this command ID.",false)
        case .unsupportedAuthority:
            row = ("STORAGE_UNSUPPORTED_ENTRY","unsupported_entry","A stored path is not a regular file or a private folder, or Checklist is not allowed to use it.","Do not retry until the entry is corrected. Keep the store and report this command ID.",false)
        case .sourceChanged:
            row = ("STORAGE_SOURCE_CHANGED","source_changed","A file changed while Checklist was reading it.",Self.retrySameCommand,true)
        case .incomplete:
            row = ("STORAGE_INCOMPLETE","incomplete","A required file or record is missing or incomplete.","Do not retry. Keep the store and existing backups and report this command ID.",false)
        case .limit:
            row = ("STORAGE_LIMIT_EXCEEDED","limit_exceeded","The data is larger than Checklist's limit for this operation.","Do not retry with the same input. Reduce the input.",false)
        case .canceled:
            row = ("STORAGE_CANCELED","canceled","The storage operation was canceled before it finished. Existing data was kept.",Self.retrySameCommand,true)
        case .deadline:
            row = ("STORAGE_DEADLINE_EXCEEDED","deadline_exceeded","The storage operation did not finish within its time limit. Existing data was kept.",Self.retrySameCommand,true)
        case .publicationUncertain:
            row = ("OUTCOME_UNKNOWN","publication_uncertain","Checklist could not confirm that the result was saved.","Check command_status with this command ID. If the result is absent, retry with the same command ID.",true)
        case .freeSpace:
            row = ("STORAGE_FREE_SPACE","free_space","The volume does not have enough free space.","Free space on the volume, then retry with the same command ID.",false)
        case .io:
            row = ("STORAGE_IO_ERROR","io_error","Checklist could not read or write a stored file. The system error was not recorded.","Check command_status with this command ID, then retry once with the same command ID.",true)
        case .systemCall(let value):
            system = value
            row = Self.systemRow(value)
        }
        (code,reason,explanation,nextStep,retryable) = row
        self.system = system
    }

    private static func systemRow(_ value: StorageSystemFailure) -> (String,String,String,String,Bool) {
        let call = "\(value.operation) failed with \(errnoName(value.code))"
        switch value.code {
        case EMFILE,ENFILE:
            return ("STORAGE_OPEN_FILES_EXHAUSTED","open_files_exhausted","The Checklist service temporarily has too many files open (\(call)).",retrySameCommand,true)
        case _ where transientErrnos.contains(value.code):
            return ("STORAGE_TEMPORARILY_UNAVAILABLE","temporarily_unavailable","A stored file was temporarily unavailable (\(call)).",retrySameCommand,true)
        case ENOSPC,EDQUOT:
            return ("STORAGE_DISK_FULL","disk_full","The volume is full (\(call)).","Free space on the volume, then retry with the same command ID.",false)
        case EACCES,EPERM,EROFS:
            return ("STORAGE_ACCESS_DENIED","access_denied","macOS refused access to a stored file (\(call)).","Restore access to the folder, then retry with the same command ID.",false)
        case ENOENT,ENOTDIR:
            return ("STORAGE_FILE_MISSING","file_missing","A required stored file is missing (\(call)).","Do not retry. Keep the store and report this command ID.",false)
        default:
            return ("STORAGE_IO_ERROR","io_error","Checklist could not read or write a stored file (\(call)).","Check command_status with this command ID, then retry once with the same command ID.",true)
        }
    }

    var message: String {explanation + " " + nextStep}

    /// Safe for a reply: stable fields, the system error and the root-relative path.
    var details: JSON {
        var value: JSON = ["reason":reason,"next_step":nextStep,"retryable":retryable,"command_outcome":"unknown"]
        if let system {
            value["operation"] = system.operation
            value["posix_errno"] = Int(system.code)
            value["errno_name"] = Self.errnoName(system.code)
            if let path = system.path,!path.hasPrefix("/") {value["relative_path"] = path}
        }
        return value
    }

    var publicError: CoreError {CoreError(code,message,details:details)}

    static func errnoName(_ code: Int32) -> String {
        let names: [Int32:String] = [EMFILE:"EMFILE",ENFILE:"ENFILE",EINTR:"EINTR",EAGAIN:"EAGAIN",EBUSY:"EBUSY",ETIMEDOUT:"ETIMEDOUT",ENOSPC:"ENOSPC",EDQUOT:"EDQUOT",EACCES:"EACCES",EPERM:"EPERM",EROFS:"EROFS",ENOENT:"ENOENT",ENOTDIR:"ENOTDIR",EEXIST:"EEXIST",EIO:"EIO"]
        return names[code] ?? "errno \(code)"
    }

    // MARK: Transient conditions

    static func isTransient(_ error: Error) -> Bool {
        if let failure = error as? StorageSnapshotFailure,case .systemCall(let value) = failure {return transientErrnos.contains(value.code)}
        if let error = error as? CoreError,let code = (error.details["posix_errno"] as? NSNumber)?.int32Value {return transientErrnos.contains(code)}
        // SQLite cannot open a new connection when no descriptor is free.
        if let error = error as? DatabaseError {return error.resultCode == .SQLITE_CANTOPEN}
        return false
    }

    /// Adds the plain reason and next step to an existing coded error whose
    /// system error is transient. The code stays, and the same command ID can run again.
    static func annotated(_ error: CoreError) -> CoreError {
        guard error.details["retryable"] == nil,isTransient(error),
              let code = (error.details["posix_errno"] as? NSNumber)?.int32Value else {return error}
        let explanation = [EMFILE,ENFILE].contains(code) ? "The Checklist service temporarily has too many files open (\(errnoName(code)))." : "A stored file was temporarily unavailable (\(errnoName(code)))."
        var details = error.details
        details["errno_name"] = errnoName(code)
        details["retryable"] = true
        details["next_step"] = retrySameCommand
        details["command_outcome"] = "unknown"
        log(code:error.code,detail:"\(error.message) errno=\(code)")
        return CoreError(error.code,error.message + " " + explanation + " " + retrySameCommand,details:details)
    }

    /// attachment_add is safe to repeat: its durable job and command ID make a
    /// second attempt continue the first. Each pause lets other work release descriptors.
    static func retryingTransient<T>(pauses: [TimeInterval] = transientRetryPauses,_ body: () throws -> T) throws -> T {
        var remaining = pauses[...]
        while true {
            do {return try body()}
            catch where isTransient(error) && !remaining.isEmpty {
                log(code:"STORAGE_TRANSIENT_RETRY",detail:String(describing:error))
                Thread.sleep(forTimeInterval:remaining.removeFirst())
            }
        }
    }

    // MARK: Log

    private static let logger = Logger(subsystem:"org.checklist.coordination",category:"storage-failure")
    /// The launchd service's stderr is /dev/null, so the unified log keeps this
    /// record. It opens no descriptor, which matters when none is free. Read it with:
    /// log show --predicate 'subsystem == "org.checklist.coordination"' --last 1d
    private static let sink = OSAllocatedUnfairLock<(@Sendable (String) -> Void)?>(initialState:nil)
    /// Owned tests observe the exact line.
    static func setLogSink(_ value: (@Sendable (String) -> Void)?) {sink.withLock {$0 = value}}

    static func log(code: String,detail: String) {
        let line = "ChecklistService: storage failure \(code): \(detail)"
        logger.error("\(line,privacy:.public)")
        fputs(line + "\n",stderr)
        sink.withLock {$0}?(line)
    }

    func log() {
        var detail = reason
        if let system {detail += " operation=\(system.operation) errno=\(system.code) (\(Self.errnoName(system.code))) root=\(system.root ?? "-") path=\(system.path ?? "-")"}
        Self.log(code:code,detail:detail)
    }
}
