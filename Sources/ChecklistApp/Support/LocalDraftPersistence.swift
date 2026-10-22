import ChecklistIPC
import Foundation
import CryptoKit
import Darwin

struct DraftScope: Codable, Equatable {
    var storeIncarnation: String
    var projectID: String
    var entityID: String

    func matches(store: String, project: String, entity: String) -> Bool {
        !storeIncarnation.isEmpty && storeIncarnation == store && projectID == project && entityID == entity
    }
}

struct StoredNoteDraft: Codable {
    var text: String
    var destination: String
    var scope: DraftScope
}

struct StoredAnswerDraft: Codable {
    var draft: AnswerDraft
    var scope: DraftScope
}

struct TaskEditDraft: Codable {
    var title: String
    var brief: String
    var baseRevision: Int
    var editing: Bool
    var hasChanges: Bool
    var scope: DraftScope
}

struct CaptureDraft: Codable, Equatable {
    var projectID: String
    var title: String
    var brief: String
    var kind: String
    var epicID: String
    var storeIncarnation: String
    var createdTaskID: String? = nil
    var createCommandID: String? = nil
    /// CL-68 optional Bug and Playtest fields. Optional so that drafts saved before this field still load.
    var starterFields: [String: String]? = nil
}

/// The private owner journal contains drafts only. It never replays service commands.
/// Each entity is replaced atomically, synchronized, and read back before Saved is shown.
final class LocalDraftJournal {
    private struct Envelope<Value: Codable>: Codable {
        let schemaVersion: Int
        let kind: String
        let key: String
        let value: Value
    }

    static var defaultDirectory: URL {
        directory(for:ChecklistInstance.current)
    }
    static func directory(for instance: ChecklistInstance) -> URL { instance.ownerDataRoot.appendingPathComponent("OwnerDrafts") }
    static func windowJournal(id: UUID, baseDirectory: URL = defaultDirectory) -> LocalDraftJournal {
        LocalDraftJournal(directory: baseDirectory.appendingPathComponent("Windows", isDirectory: true).appendingPathComponent(id.uuidString.lowercased(), isDirectory: true))
    }
    let directory: URL
    init(directory: URL = LocalDraftJournal.defaultDirectory) {
        self.directory = directory
    }
    func contains(kind: String, key: String) -> Bool { (try? file(kind: kind, key: key)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    func save<Value: Codable>(_ value: Value, kind: String, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let bytes = try JSONEncoder().encode(Envelope(schemaVersion: 1, kind: kind, key: key, value: value))
        let target = try file(kind: kind, key: key)
        try bytes.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let handle = try FileHandle(forWritingTo: target)
        do { try handle.synchronize(); try handle.close() } catch { try? handle.close(); throw error }
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0, try Data(contentsOf: target) == bytes else { throw POSIXError(.EIO) }
    }

    /// A read-only quit check of the snapshot already synchronized by save().
    func checkSaved<Value: Codable & Equatable>(_ value: Value, kind: String, key: String) throws {
        let envelope = try JSONDecoder().decode(Envelope<Value>.self, from: Data(contentsOf: file(kind: kind, key: key)))
        guard envelope.schemaVersion == 1, envelope.kind == kind, envelope.key == key, envelope.value == value else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    func load<Value: Codable>(_ type: Value.Type, kind: String) throws -> [String: Value] {
        let result = try recover(type, kind: kind)
        guard result.errors.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return result.values
    }

    func recover<Value: Codable>(_ type: Value.Type, kind: String) throws -> (values: [String: Value], errors: [String]) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([:], []) }
        let prefix = try checkedKind(kind) + "-"
        var values: [String: Value] = [:]
        var errors: [String] = []
        for path in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter({ $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }) {
            do {
                let envelope = try JSONDecoder().decode(Envelope<Value>.self, from: Data(contentsOf: path))
                guard envelope.schemaVersion == 1, envelope.kind == kind, path.lastPathComponent == (try file(kind: kind, key: envelope.key)).lastPathComponent else { throw CocoaError(.fileReadCorruptFile) }
                values[envelope.key] = envelope.value
            } catch { errors.append(error.localizedDescription) }
        }
        return (values, errors)
    }

    private func file(kind: String, key: String) throws -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(try checkedKind(kind) + "-" + digest + ".json")
    }
    private func checkedKind(_ value: String) throws -> String {
        guard value.range(of: "^[a-z_]{1,30}$", options: .regularExpression) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        return value
    }
}
