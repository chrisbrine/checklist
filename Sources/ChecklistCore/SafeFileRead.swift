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
    static func read(_ path: String, maximum: Int, allowedRoots: [String], reader: any AuthorizedFileReading = MacOSAuthorizedFileReader()) throws -> Opened {
        try reader.read(path, maximum: maximum, allowedRoots: allowedRoots)
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
