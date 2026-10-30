import Foundation
import Darwin

/// A conservative hold over this root's immutable managed namespace. Metadata
/// writes and new immutable publications remain admitted. All managed deletion
/// paths refuse while capture is active; the ordinary object gate orders their
/// final check/unlink against capture's SQLite copy. Retention starts before
/// that copy and protects the entire namespace while inventory runs outside it.
///
/// The kernel releases this hold on process death. An interrupted stage is
/// independent partial bytes, never resumed from an unprotected source: retry
/// verifies a complete stage or quarantines it and captures a fresh inventory.
final class StorageSnapshotRetention {
    private let files: StorageObjectFiles
    private let descriptor: Int32
    private var active = false
    private init(root: URL) throws {
        files = try StorageObjectFiles(root:root)
        descriptor = try Self.open(files)
    }
    deinit { Darwin.close(descriptor) }

    private static func open(_ files: StorageObjectFiles) throws -> Int32 {
        let fd = openat(files.descriptor,".snapshot-retention.lock",O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else {
            let code = errno
            throw CoreError("BACKUP_HOLD_UNAVAILABLE","The backup retention barrier cannot be opened; managed files were retained.",details:["operation":"open_snapshot_retention","posix_errno":code])
        }
        var info = stat()
        guard fstat(fd,&info) == 0 else {
            let code = errno
            let failure = CoreError("BACKUP_HOLD_UNAVAILABLE","The backup retention barrier is not a private regular file; managed files were retained.",details:["operation":"inspect_snapshot_retention","posix_errno":code])
            Darwin.close(fd)
            throw failure
        }
        guard info.st_mode & S_IFMT == S_IFREG,info.st_nlink == 1 else {
            Darwin.close(fd)
            throw CoreError("BACKUP_HOLD_UNAVAILABLE","The backup retention barrier is not a private regular file; managed files were retained.",details:["operation":"validate_snapshot_retention","reason":"unsafe_retention_lock"])
        }
        return fd
    }
    func requireRoot(_ root: URL) throws {
        guard active,Data(files.root.path.utf8) == Data(root.standardizedFileURL.path.utf8) else {throw StorageSnapshotFailure.invalidFixture}
        var entry = stat(),actual = stat()
        guard fstat(descriptor,&actual) == 0,fstatat(files.descriptor,".snapshot-retention.lock",&entry,AT_SYMLINK_NOFOLLOW) == 0,
              actual.st_dev == entry.st_dev,actual.st_ino == entry.st_ino else {throw StorageSnapshotFailure.sourceChanged}
    }
    static func withCapture<T>(root: URL,_ body: (StorageSnapshotRetention) throws -> T) throws -> T {
        // Publish retention under the same gate as final deletion checks. An
        // already admitted maintenance pass finishes before the hold appears;
        // it must never count a newly appeared backup hold as an unlink failure.
        let hold = try ArchiveStorageGate.withExclusive(root:root) { _ in
            let hold = try StorageSnapshotRetention(root:root)
            while flock(hold.descriptor,LOCK_EX | LOCK_NB) != 0 {
                if errno == EINTR {continue}
                let code = errno
                guard code == EWOULDBLOCK else {throw CoreError("BACKUP_HOLD_UNAVAILABLE","The backup retention barrier could not be acquired.",details:["operation":"acquire_snapshot_retention","posix_errno":code])}
                throw CoreError("BACKUP_IN_PROGRESS","Another backup is still copying or verifying this store. Retry backup_create with a new command ID after it finishes.",details:["command_outcome":"rejected","next_step":"Retry backup_create with a new command ID after the other backup finishes."])
            }
            hold.active = true
            return hold
        }
        defer {hold.active = false;_ = flock(hold.descriptor,LOCK_UN)}
        return try body(hold)
    }
    static func isActive(root: URL) throws -> Bool {
        let files = try StorageObjectFiles(root:root),fd = try open(files)
        defer {Darwin.close(fd)}
        while flock(fd,LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR {continue}
            let code = errno
            guard code == EWOULDBLOCK else {throw CoreError("BACKUP_HOLD_UNAVAILABLE","Backup retention could not be checked; managed files were retained.",details:["operation":"observe_snapshot_retention","posix_errno":code])}
            return true
        }
        return false // close releases this observation lock; caller retains the object gate.
    }
    static func requireNoCapture(root: URL) throws {
        guard try !isActive(root:root) else {
            throw CoreError("BACKUP_CAPTURE_ACTIVE","Backup is copying or verifying managed files. Cleanup is deferred until it finishes; retry afterward.",details:["reason":"backup_capture","command_outcome":"rejected"])
        }
    }
}
