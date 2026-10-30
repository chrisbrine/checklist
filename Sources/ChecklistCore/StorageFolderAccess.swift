import Foundation
import os
import Darwin
import ChecklistFileAccess

/// A folder syscall cannot be canceled by a Dispatch timeout. Isolate the
/// no-follow root walk in a reusable native helper and transfer only its descriptor.
/// The privacy boundary is the selected root, not each relative file operation.
/// No timed-out root opener can publish imports.
struct StorageFolderAccess {
    static let seconds: TimeInterval = 5
    var timeout: TimeInterval = Self.seconds
    var reusePinnedRoots = true
    // Internal owned-fixture seam, never selected by an environment or client.
    var blockingReadDescriptor: (URL) -> Int32 = { _ in -1 }
    var observeChild: (pid_t) -> Void = { _ in }

    func open(path: String, folder: URL) throws -> Int32 {
        let reaper = StorageFolderReaper.shared
        guard reaper.acquire(timeout:min(timeout,Self.seconds)) else {
            throw CoreError("FOLDER_ACCESS_UNAVAILABLE","Checklist could not open the folder ‘\(folder.path)’ because its bounded file-access workers are busy. A prior privacy or sync-provider open may still be ending. Retry using the original command ID.",details:["folder":folder.path,"reason":"folder_opener_busy","command_outcome":"unknown"])
        }
        let (descriptor,failure,workers) = reaper.open(path:path,timeout:Int32(max(1,min(timeout,Self.seconds) * 1000)),barrier:blockingReadDescriptor(folder))
        for worker in workers { observeChild(worker) }
        guard descriptor >= 0 else {
            // Preserve ENOENT for descriptor-relative existence checks. Other
            // failures remain explicit rather than masquerading as missing data.
            // CL-362: a missing folder is a finished rejection, so its command ID does not run
            // again. Any other failure keeps an accepted operation recoverable under its ID.
            if failure == ENOENT || failure == ENOTDIR {
                let error = CoreError("FOLDER_ACCESS_UNAVAILABLE","Checklist could not open the folder ‘\(folder.path)’ because it does not exist. Choose an existing folder, then retry with a new command ID.",
                    details:["folder":folder.path,"reason":"folder_open_failed","posix_errno":failure,"timeout_seconds":timeout,"command_outcome":"rejected","next_step":"Choose an existing folder, then retry with a new command ID."])
                errno = failure
                throw error
            }
            let error = CoreError(failure == ETIMEDOUT ? "FOLDER_ACCESS_TIMED_OUT" : "FOLDER_ACCESS_UNAVAILABLE",
                "Checklist could not open the folder ‘\(folder.path)’\(failure == ETIMEDOUT ? " within \(timeout) seconds" : ""). macOS privacy access or a cloud/sync provider may be waiting. Check folder access or use a local folder such as ~/Library/Caches, then reconcile using the original command ID.",
                details:["folder":folder.path,"reason":failure == ETIMEDOUT ? "folder_open_timeout" : "folder_open_failed","posix_errno":failure,"timeout_seconds":timeout,"command_outcome":"unknown"])
            errno = failure
            throw error
        }
        return descriptor
    }

    /// Normalize selected paths without asking Foundation to resolve any source
    /// symlink before the bounded opener. Descendant symlinks remain refused.
    static func lexicalPath(_ raw: String) throws -> String {
        let expanded = raw == "~" ? NSHomeDirectory() : raw.hasPrefix("~/") ? NSHomeDirectory() + String(raw.dropFirst()) : raw
        guard expanded.hasPrefix("/"), !expanded.contains("\0") else { throw CoreError("FILE_ACCESS_REQUIRED","Choose an absolute local file path.") }
        var parts: [Substring] = []
        for part in expanded.split(separator:"/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else { parts.append(part) }
        }
        var path = "/" + parts.joined(separator:"/")
        // Match macOS's verified platform aliases without looking up the user's
        // selected folder. StorageObjectFiles still verifies those root aliases.
        for alias in ["/tmp","/var"] where path == alias || path.hasPrefix(alias + "/") { path = "/private" + path;break }
        return path
    }

    static func isMissing(_ error: Error) -> Bool {
        if let error = error as? CoreError { return (error.details["posix_errno"] as? NSNumber)?.int32Value == ENOENT }
        return errno == ENOENT
    }
}

/// SIGCHLD is delivered when a child is waitable. A per-child NOTE_EXIT/read
/// source can fire earlier or be starved under sustained command traffic. One
/// registered signal source and a capped set keep both races and process count
/// bounded; only our own PIDs are reaped, without altering signal dispositions.
private final class StorageFolderReaper: Sendable {
    static let shared = StorageFolderReaper()
    private let queue = DispatchQueue(label:"checklist.folder-reaper",qos:.userInitiated)
    private let worker = DispatchSemaphore(value:1)
    private let slots = DispatchSemaphore(value:16)
    private let children = OSAllocatedUnfairLock(initialState: Set<pid_t>())
    private let signal: DispatchSourceSignal
    private let registration = DispatchGroup()
    private init() {
        signal = DispatchSource.makeSignalSource(signal:SIGCHLD,queue:queue)
        registration.enter()
        let ready = registration
        signal.setRegistrationHandler { ready.leave() }
        signal.setEventHandler { [weak self] in self?.reap() }
        signal.resume()
    }
    func acquire(timeout: TimeInterval) -> Bool {
        guard registration.wait(timeout:.now()+2) == .success,worker.wait(timeout:.now()+max(0,timeout)) == .success else { return false }
        // Reserve room for both an idle-expired generation and its replacement.
        guard slots.wait(timeout:.now()) == .success else { worker.signal();return false }
        guard slots.wait(timeout:.now()) == .success else { slots.signal();worker.signal();return false }
        return true
    }
    func open(path: String,timeout: Int32,barrier: Int32) -> (Int32,Int32,[pid_t]) {
        defer { worker.signal() }
        return queue.sync {
            var retired = [pid_t](repeating:0,count:2),active: pid_t = 0
            let descriptor = checklist_open_bounded(path,timeout,barrier,&retired,&active)
            let failure = errno
            for child in retired {
                if child > 0 { children.withLock { _ = $0.insert(child) } } else { slots.signal() }
            }
            reap()
            return (descriptor,failure,Array(Set(retired.filter {$0 > 0} + (active > 0 ? [active] : []))))
        }
    }
    private func reap() {
        // This queue also owns the native helper state, so a SIGCHLD callback
        // cannot reap/recycle a PID while a request is retiring that generation.
        checklist_reap_idle_folder_helper()
        children.withLock { children in
            for child in children {
                let result = waitpid(child,nil,WNOHANG)
                if result == child || result < 0 && errno == ECHILD { children.remove(child);slots.signal() }
            }
        }
    }
}
