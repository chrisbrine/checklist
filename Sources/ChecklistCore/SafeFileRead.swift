import Foundation
import Darwin

/// Reads one agent-reachable file without trusting an earlier path check.
/// The final component is opened with O_NOFOLLOW, and the kernel's path for the
/// open descriptor is checked against the allowed roots again. A symlink swap of
/// any component between the earlier check and the open cannot redirect the read.
enum SafeFileRead {
    struct Opened {
        let bytes: Data
        /// The descriptor's own path, normalized like `canonical(_:)`.
        let resolvedPath: String
    }

    /// `allowedRoots` are trusted canonical directories (enrolled workspace, project
    /// root or the managed store). An empty list refuses every path.
    static func read(_ path: String, maximum: Int, allowedRoots: [String]) throws -> Opened {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP { throw CoreError("FILE_ACCESS_REQUIRED", "A symlink cannot be read through this route. Choose the file itself.") }
            throw CoreError("FILE_ACCESS_REQUIRED", "The file could not be opened.")
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CoreError("INVALID_INPUT", "Attach a regular file. Directories can be provided as human-request references.") }
        guard info.st_size <= off_t(maximum) else { throw CoreError("FILE_TOO_LARGE", "This file exceeds the read limit.") }
        let resolved = try descriptorPath(fd)
        guard allowedRoots.contains(where: { containsPath($0, resolved) }) else { throw CoreError("FILE_ACCESS_REQUIRED", "Agent file reads must stay inside the enrolled workspace.") }
        var bytes = Data(capacity: Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw CoreError("FILE_ACCESS_REQUIRED", "The file could not be read.") }
            if count == 0 { break }
            guard bytes.count + count <= maximum else { throw CoreError("FILE_TOO_LARGE", "This file exceeds the read limit.") }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        return Opened(bytes: bytes, resolvedPath: resolved)
    }

    /// F_GETPATH reports the vnode's current path. Foundation's canonical form drops
    /// the /private prefix of the standard firmlinked directories; apply the same rule
    /// textually so that no second symlink resolution happens after the open.
    static func descriptorPath(_ fd: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { throw CoreError("FILE_ACCESS_REQUIRED", "The opened file's location could not be verified.") }
        return normalizedPrivatePrefix(String(cString: buffer))
    }

    static func normalizedPrivatePrefix(_ path: String) -> String {
        for prefix in ["/private/var/", "/private/tmp/", "/private/etc/"] where path.hasPrefix(prefix) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }
}
