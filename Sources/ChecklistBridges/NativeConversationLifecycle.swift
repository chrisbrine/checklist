import Foundation
import CoreFoundation
import CryptoKit
import Darwin

/// Service-owned registration, derived from an authenticated automatic bootstrap.
/// An MCP/CLI shim PID must never be substituted for this native host identity.
public struct NativeLifecycleRegistration: Sendable {
    public let provider: String
    public let sessionID: String
    public let processID: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public let registryPath: String?

    public init?(provider: String, sessionID: String, executionDomain: String, registryPath: String?) {
        let parts = executionDomain.split(separator: ":", omittingEmptySubsequences: false)
        guard ["codex", "claude"].contains(provider), parts.count == 4,
              parts[0] == provider, UUID(uuidString: sessionID) != nil,
              let pid = Int32(parts[1]), pid > 1,
              let seconds = UInt64(parts[2]), seconds > 0,
              let microseconds = UInt64(parts[3]), microseconds < 1_000_000,
              registryPath == nil || registryPath!.hasPrefix("/") else { return nil }
        self.provider = provider; self.sessionID = sessionID; self.processID = pid
        self.startSeconds = seconds; self.startMicroseconds = microseconds; self.registryPath = registryPath
    }
}

public struct NativeLifecycleObservation: Sendable {
    public enum ProcessState: String, Sendable { case running, gone, replaced, unknown }
    public enum RegistryState: String, Sendable { case matching, absent, replaced, unsupported, unknown }
    public let process: ProcessState
    public let registry: RegistryState
    public let detail: String
    public let registryDigest: String?
    public var provesClosure: Bool {
        [.gone, .replaced].contains(process) && [.absent, .replaced].contains(registry)
    }
    public init(process: ProcessState, registry: RegistryState, detail: String, registryDigest: String? = nil) {
        self.process = process; self.registry = registry; self.detail = detail; self.registryDigest = registryDigest
    }
}

public enum NativeLifecycleInspector {
    public static func inspect(_ registration: NativeLifecycleRegistration) -> NativeLifecycleObservation {
        let process = processState(registration)
        let registry = registryState(registration)
        return .init(process: process, registry: registry.state, detail: registry.detail, registryDigest: registry.digest)
    }

    private static func processState(_ registration: NativeLifecycleRegistration) -> NativeLifecycleObservation.ProcessState {
        var info = proc_bsdinfo()
        if proc_pidinfo(registration.processID, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) {
            guard info.pbi_uid == getuid() else { return .unknown }
            return info.pbi_start_tvsec == registration.startSeconds && info.pbi_start_tvusec == registration.startMicroseconds ? .running : .replaced
        }
        // A lookup failure is not death. ESRCH from the kernel's existence check
        // is positive absence; EPERM and every other result remain unknown.
        errno = 0
        return kill(registration.processID, 0) == -1 && errno == ESRCH ? .gone : .unknown
    }

    private static func registryState(_ registration: NativeLifecycleRegistration) -> (state: NativeLifecycleObservation.RegistryState, detail: String, digest: String?) {
        // Current Codex bootstrap has no qualified per-thread registry. Host
        // death, stdio EOF, a completed turn or thread unload cannot invent one.
        guard registration.provider == "claude", let path = registration.registryPath else {
            return (.unsupported, "No qualified native conversation registry is available.", nil)
        }
        let url = URL(fileURLWithPath: path)
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return (.unknown, "The native registry directory could not be verified.", nil) }
        defer { close(directory) }
        var parent = stat()
        guard fstat(directory, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR,
              parent.st_uid == getuid(), parent.st_mode & 0o022 == 0 else {
            return (.unknown, "The native registry directory is not private to this user.", nil)
        }
        let fd = openat(directory, url.lastPathComponent, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            return errno == ENOENT ? (.absent, "The registered native registry path is absent.", nil)
                : (.unknown, "The native registry could not be read securely.", nil)
        }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, secure(before), before.st_size > 0, before.st_size <= 65_536 else {
            return (.unknown, "The native registry is not a bounded secure regular file.", nil)
        }
        var bytes = [UInt8](repeating: 0, count: 65_537)
        let count = read(fd, &bytes, bytes.count)
        var after = stat(), entry = stat()
        guard count > 0, count <= 65_536, fstat(fd, &after) == 0, secure(after),
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, Int64(count) == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              fstatat(directory, url.lastPathComponent, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              secure(entry), entry.st_dev == after.st_dev, entry.st_ino == after.st_ino else {
            return (.unknown, "The native registry changed or was incomplete while being read.", nil)
        }
        let data = Data(bytes.prefix(count))
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = object["pid"] as? NSNumber, CFGetTypeID(pid) != CFBooleanGetTypeID(),
              pid.doubleValue == Double(registration.processID),
              let session = object["sessionId"] as? String, UUID(uuidString: session) != nil,
              let cwd = object["cwd"] as? String, cwd.hasPrefix("/") else {
            return (.unknown, "The native registry has no valid process/session/workspace identity.", nil)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return session.utf8.elementsEqual(registration.sessionID.utf8)
            ? (.matching, "The registry still identifies this conversation.", digest)
            : (.replaced, "A valid registry at this address identifies a different conversation.", digest)
    }

    private static func secure(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_uid == getuid() && value.st_mode & 0o022 == 0
    }
}
