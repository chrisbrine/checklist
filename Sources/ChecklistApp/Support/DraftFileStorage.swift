import Foundation
import Darwin
import ChecklistIPC

/// Owner-local draft bytes only. This capability never executes service commands.
protocol DraftFileStorage {
    func exists(_ url: URL) throws -> Bool
    func read(_ url: URL) throws -> Data
    func contents(of directory: URL) throws -> [URL]
    func replace(_ bytes: Data, at target: URL, directory: URL) throws
}

struct MacOSDraftFileStorage: DraftFileStorage {
    func exists(_ url: URL) throws -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    func contents(of directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }
    func replace(_ bytes: Data, at target: URL, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try bytes.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let handle = try FileHandle(forWritingTo: target)
        do { try handle.synchronize(); try handle.close() } catch { try? handle.close(); throw error }
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0, try Data(contentsOf: target) == bytes else { throw POSIXError(.EIO) }
    }
}

/// Future shells must opt in to a qualified implementation, never substitute a
/// temporary journal or treat an unavailable write as a saved draft.
struct UnavailableDraftFileStorage: DraftFileStorage {
    private var failure: ChecklistError {
        ChecklistError("PLATFORM_CAPABILITY_UNAVAILABLE", "Durable owner-local draft storage is unavailable.", details: ["capability": "owner_draft_storage"])
    }
    func exists(_ url: URL) throws -> Bool { throw failure }
    func read(_ url: URL) throws -> Data { throw failure }
    func contents(of directory: URL) throws -> [URL] { throw failure }
    func replace(_ bytes: Data, at target: URL, directory: URL) throws { throw failure }
}
