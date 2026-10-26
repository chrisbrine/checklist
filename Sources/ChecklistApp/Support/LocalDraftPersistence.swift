import ChecklistIPC
import Foundation
import CryptoKit

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

struct CaptureDraft: Codable, Equatable, Sendable {
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
final class LocalDraftJournal: Sendable {
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
    private let files: any DraftFileStorage
    init(directory: URL = LocalDraftJournal.defaultDirectory, files: any DraftFileStorage = MacOSDraftFileStorage()) {
        self.directory = directory
        self.files = files
    }
    func contains(kind: String, key: String) -> Bool { (try? files.exists(try file(kind: kind, key: key))) ?? false }

    func save<Value: Codable>(_ value: Value, kind: String, key: String) throws {
        let bytes = try JSONEncoder().encode(Envelope(schemaVersion: 1, kind: kind, key: key, value: value))
        try files.replace(bytes, at: file(kind: kind, key: key), directory: directory)
    }

    /// A read-only quit check of the snapshot already synchronized by save().
    func checkSaved<Value: Codable & Equatable>(_ value: Value, kind: String, key: String) throws {
        let envelope = try JSONDecoder().decode(Envelope<Value>.self, from: files.read(file(kind: kind, key: key)))
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
        guard try files.exists(directory) else { return ([:], []) }
        let prefix = try checkedKind(kind) + "-"
        var values: [String: Value] = [:]
        var errors: [String] = []
        for path in try files.contents(of: directory).filter({ $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }) {
            do {
                let envelope = try JSONDecoder().decode(Envelope<Value>.self, from: files.read(path))
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
