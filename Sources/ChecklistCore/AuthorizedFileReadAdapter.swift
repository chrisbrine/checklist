import Foundation
import Darwin

/// This native capability owns the open/descriptor/revalidation boundary. Scope
/// comes from the authenticated caller; adapters never expand its allowed roots.
protocol AuthorizedFileReading {
    func read(_ path: String, maximum: Int, allowedRoots: [String]) throws -> SafeFileRead.Opened
}

struct MacOSAuthorizedFileReader: AuthorizedFileReading {
    func read(_ path: String, maximum: Int, allowedRoots: [String]) throws -> SafeFileRead.Opened {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP { throw CoreError("FILE_ACCESS_REQUIRED", "A symlink cannot be read through this route. Choose the file itself.") }
            throw CoreError("FILE_ACCESS_REQUIRED", "The file could not be opened.")
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CoreError("INVALID_INPUT", "Attach a regular file. Directories can be provided as human-request references.") }
        guard info.st_size <= off_t(maximum) else { throw CoreError("FILE_TOO_LARGE", "This file exceeds the read limit.") }
        let resolved = try SafeFileRead.descriptorPath(fd)
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
        return SafeFileRead.Opened(bytes: bytes, resolvedPath: resolved)
    }
}

struct UnavailableAuthorizedFileReader: AuthorizedFileReading {
    func read(_ path: String, maximum: Int, allowedRoots: [String]) throws -> SafeFileRead.Opened {
        throw CoreError("PLATFORM_CAPABILITY_UNAVAILABLE", "Verified descriptor-based local file access is unavailable.", details: ["capability": "authorized_file_read"])
    }
}
