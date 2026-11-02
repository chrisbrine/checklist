import Foundation
import Darwin
import GRDB

public enum CodexQueueReason: String, Sendable {
    case sourceVscode = "source_vscode", sourceExec = "source_exec", sourceMCP = "source_mcp"
    case sourceSubagent = "source_subagent", sourceUnknown = "source_unknown", threadMissing = "thread_missing"
    case databaseMissing = "database_missing", databaseVersionUnsupported = "database_version_unsupported"
    case databaseLocked = "database_locked", schemaUnrecognized = "schema_unrecognized"
    case databaseReadError = "database_read_error", databaseUnsafe = "database_unsafe"
    case recipientInvalid = "recipient_invalid", routeDisabled = "route_disabled"

    public var explanation: String {
        switch self {
        case .sourceVscode: "Codex records this exact thread as source vscode."
        case .sourceExec: "Codex records source exec; its queue can lose a message when exec exits."
        case .sourceMCP: "Codex records source mcp; this is not a supported app thread."
        case .sourceSubagent: "Codex records a subagent source; this is not a supported app thread."
        case .sourceUnknown: "Codex records an unsupported source; only exact source vscode is accepted."
        case .threadMissing: "The exact thread UUID has no row in the supported Codex state database."
        case .databaseMissing: "The supported Codex database file is missing."
        case .databaseVersionUnsupported: "A newer Codex database filename is present; this reader supports only the documented version."
        case .databaseLocked: "The read-only Codex database is locked; no wait or queue is attempted."
        case .schemaUnrecognized: "The Codex database table shape or selected row is not supported."
        case .databaseReadError: "The Codex database could not be read; no ownership is inferred."
        case .databaseUnsafe: "The Codex database path is not an owned regular file with safe write permissions."
        case .recipientInvalid: "The recipient is not an exact registered Codex thread UUID."
        case .routeDisabled: "The Codex queue route is disabled."
        }
    }
}

public struct CodexQueueObservation: Equatable, Sendable {
    public let host: CodexQueueHost
    public let reason: CodexQueueReason
    public let source: String?
    public init(host: CodexQueueHost = .unproven, reason: CodexQueueReason, source: String? = nil) {
        self.host = host; self.reason = reason; self.source = source
    }
    public var receipt: [String:Any] {
        var result: [String:Any] = ["route":"codex_app_queue", "observer":"codex_state_5_threads_source", "reason_code":reason.rawValue]
        if let source { result["source"] = source }
        return result
    }
}

/// Only the actual account's conventional store is supported. A caller-selected
/// HOME or CODEX_HOME cannot redirect the service's ownership observation.
public struct CodexQueueStore: Sendable {
    let directory: URL
    let owner: uid_t
    public static var current: CodexQueueStore? {
        guard let raw = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return .init(directory:URL(fileURLWithPath:String(cString:raw)).appendingPathComponent(".codex"), owner:getuid())
    }
    init(directory: URL, owner: uid_t = getuid()) { self.directory = directory; self.owner = owner }

    public func observe(threadID: String) -> CodexQueueObservation {
        guard let thread = UUID(uuidString:threadID) else { return .init(reason:.recipientInvalid) }
        do {
            return try read(file:"state_5.sqlite", stem:"state", version:5) { db in
                try validate(db, table:"threads", required:["id":("TEXT",true),"source":("TEXT",false),"originator":("TEXT",false)])
                let rows = try Row.fetchAll(db, sql:"SELECT id,source,originator FROM threads WHERE id=? COLLATE BINARY LIMIT 2",arguments:[thread.uuidString.lowercased()])
                guard let row = rows.first else { return .init(reason:.threadMissing) }
                let idValue: DatabaseValue = row["id"],sourceValue: DatabaseValue = row["source"]
                guard rows.count == 1,case .string(let id) = idValue.storage,UUID(uuidString:id) == thread,
                      case .string(let source) = sourceValue.storage else { throw ReadFailure(.schemaUnrecognized) }
                switch source {
                case "vscode": return .init(host:.nativeApp,reason:.sourceVscode,source:"vscode")
                case "exec": return .init(host:.exec,reason:.sourceExec,source:"exec")
                case "mcp": return .init(reason:.sourceMCP,source:"mcp")
                default:
                    let object = source.data(using:.utf8).flatMap { try? JSONSerialization.jsonObject(with:$0) }
                    let subagent = source == "subagent" || source == "subAgent" || (object as? [String:Any])?.keys.contains(where:{ $0.lowercased() == "subagent" }) == true
                    return .init(reason:subagent ? .sourceSubagent : .sourceUnknown,source:subagent ? "subagent" : "unknown")
                }
            }
        } catch { return .init(reason:reason(error)) }
    }

    enum Item: Equatable { case pending, removed, failed(CodexQueueReason) }
    func item(_ item: String, threadID: String) -> Item {
        guard let thread = UUID(uuidString:threadID) else { return .failed(.recipientInvalid) }
        do {
            return try read(file:"queue_1.sqlite",stem:"queue",version:1) { db in
                try validate(db,table:"queued_items",required:["id":("TEXT",true),"thread_id":("TEXT",false)])
                let rows = try Row.fetchAll(db,sql:"SELECT id,thread_id FROM queued_items WHERE id=? COLLATE BINARY AND thread_id=? COLLATE BINARY LIMIT 2",arguments:[item,thread.uuidString.lowercased()])
                guard rows.count <= 1 else { throw ReadFailure(.schemaUnrecognized) }
                return rows.isEmpty ? .removed : .pending
            }
        } catch { return .failed(reason(error)) }
    }

    private struct ReadFailure: Error { let reason: CodexQueueReason; init(_ reason: CodexQueueReason) { self.reason = reason } }
    private func reason(_ error: Error) -> CodexQueueReason {
        if let failure = error as? ReadFailure { return failure.reason }
        if let error = error as? DatabaseError, error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED { return .databaseLocked }
        return .databaseReadError
    }

    private func read<T>(file: String, stem: String, version: Int, _ body: (Database) throws -> T) throws -> T {
        // Exact filenames, never newest-file guessing. Retained earlier versions
        // are harmless; a newer version refuses even when the old file remains.
        var folder = stat()
        guard lstat(directory.path,&folder) == 0 else { throw ReadFailure(errno == ENOENT ? .databaseMissing : .databaseReadError) }
        guard folder.st_mode & S_IFMT == S_IFDIR,folder.st_uid == owner,folder.st_mode & 0o022 == 0 else { throw ReadFailure(.databaseUnsafe) }
        let names = try FileManager.default.contentsOfDirectory(atPath:directory.path)
        if names.contains(where:{ name in
            guard name.hasPrefix(stem+"_"),name.hasSuffix(".sqlite"),
                  let value = Int(name.dropFirst(stem.count+1).dropLast(7)) else { return false }
            return value > version
        }) { throw ReadFailure(.databaseVersionUnsupported) }
        let path = directory.appendingPathComponent(file).path
        var before = stat()
        guard lstat(path,&before) == 0 else {
            throw ReadFailure(errno == ENOENT ? .databaseMissing : .databaseReadError)
        }
        guard before.st_mode & S_IFMT == S_IFREG,before.st_uid == owner,before.st_mode & 0o022 == 0 else { throw ReadFailure(.databaseUnsafe) }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .immediateError
        let queue = try DatabaseQueue(path:path,configuration:configuration)
        defer { try? queue.close() }
        var opened = stat()
        guard lstat(path,&opened) == 0,opened.st_dev == before.st_dev,opened.st_ino == before.st_ino else { throw ReadFailure(.databaseUnsafe) }
        return try queue.read { db in
            guard db.configuration.readonly else { throw ReadFailure(.databaseReadError) }
            let result = try body(db)
            var after = stat()
            guard lstat(path,&after) == 0,after.st_dev == before.st_dev,after.st_ino == before.st_ino else { throw ReadFailure(.databaseUnsafe) }
            return result
        }
    }

    private func validate(_ db: Database, table: String, required: [String:(String,Bool)]) throws {
        guard try String.fetchOne(db,sql:"SELECT type FROM sqlite_master WHERE name=? COLLATE BINARY",arguments:[table]) == "table" else { throw ReadFailure(.schemaUnrecognized) }
        let columns = try Row.fetchAll(db,sql:"PRAGMA table_info(\(table))")
        guard columns.filter({ ($0["pk"] as Int) > 0 }).count == 1 else { throw ReadFailure(.schemaUnrecognized) }
        for (name,spec) in required {
            guard let column = columns.first(where:{ ($0["name"] as String) == name }),
                  (column["type"] as String).uppercased() == spec.0,
                  !spec.1 || (column["pk"] as Int) == 1 else { throw ReadFailure(.schemaUnrecognized) }
        }
    }
}
