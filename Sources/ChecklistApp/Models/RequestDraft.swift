import Foundation
import CryptoKit
import Darwin

/// Draft identity is the server's form generation, never merely a reused question ID.
enum RequestDraftIdentity {
    static func form(_ request: Record) -> String {
        if !request.string("form_identity").isEmpty { return request.string("form_identity") }
        let keys = ["questions", "file_requests", "command", "target_attachment_id", "target_sha256", "target_manifest_id", "review_request_id"]
        let form = request.values.filter { keys.contains($0.key) }
        guard let bytes = try? JSONSerialization.data(withJSONObject: form, options: [.sortedKeys]) else { return "legacy:\(request.id):\(request.integer("revision"))" }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func archivedKey(_ requestID: String, draft: AnswerDraft) -> String {
        requestID + "#form-\(draft.formRevision)-" + String(draft.targetIdentity.prefix(16)) + "-r\(draft.revision)"
    }
    /// The caller archives the old draft before adopting this reconciled current form.
    /// Removed entries stay in that archive, and cannot become invisible validation blockers.
    static func adoptingCurrentForm(_ oldDraft: AnswerDraft, request: Record) -> AnswerDraft {
        let spec = request.object("spec").isEmpty ? request : Record(values: request.object("spec"))
        let questions = spec.records("questions"), files = spec.records("file_requests")
        let priorQuestions = request.records("form_history").flatMap { $0.records("questions") }
        let decisions = Set((questions + priorQuestions).filter { ["approval", "check", "choice", "single_choice", "multiple_choice"].contains($0.string("type")) }.map(\.id))
        let questionIDs = Set(questions.map(\.id)), fileIDs = Set(files.map(\.id))
        var draft = oldDraft
        draft.inspectedImages = []
        draft.values = draft.values.filter { questionIDs.contains($0.key) && !decisions.contains($0.key) }
        draft.customValues = [:]
        draft.paths = draft.paths.filter { fileIDs.contains($0.key) }
        draft.fileModes = draft.fileModes.filter { fileIDs.contains($0.key) }
        draft.explanations = draft.explanations.filter { fileIDs.contains($0.key) }
        let selectedPaths = Set(draft.paths.values.flatMap { $0 })
        draft.pathHashes = draft.pathHashes.filter { selectedPaths.contains($0.key) }
        draft.revision = request.integer("revision")
        draft.formRevision = request.integer("form_revision")
        draft.targetIdentity = form(request)
        return draft
    }
    static func isComplete(_ draft: AnswerDraft, questions: [Record], fileRequests: [Record]) -> Bool {
        incompleteItems(draft, questions: questions, fileRequests: fileRequests).isEmpty
    }
    /// Keep the visible explanation and Send's accessibility help tied to the same validation.
    static func incompleteMessage(_ draft: AnswerDraft, questions: [Record], fileRequests: [Record]) -> String? {
        let items = incompleteItems(draft, questions: questions, fileRequests: fileRequests)
        guard !items.isEmpty else { return nil }
        var names = items.prefix(3).map { "“\($0.string("prompt", fallback: $0.string("label", fallback: "Required item")))”" }
        if items.count > 3 { names.append("\(items.count - 3) more") }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        let hasFiles = items.contains { item in fileRequests.contains { $0.id == item.id } }
        let action = hasFiles ? "Complete" : "Answer"
        let guidance = items.contains { ["approval", "check"].contains($0.string("type")) }
            ? " Choose No to decline; use Other response for Not checked." : ""
        return "\(action) \(list)." + guidance
    }
    private static func incompleteItems(_ draft: AnswerDraft, questions: [Record], fileRequests: [Record]) -> [Record] {
        let answers = questions.filter { question in
            if ["approval", "check"].contains(question.string("type")) && draft.values[question.id] == "not_checked" { return true }
            guard question.values["required"] as? Bool ?? true else { return false }
            return (draft.values[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(question.bool("allow_custom") && !(draft.customValues[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        let files = fileRequests.filter { ($0.values["required"] as? Bool ?? true) && (draft.paths[$0.id] ?? []).isEmpty }
        return answers + files
    }
    static func fileProblems(_ draft: inout AnswerDraft, fileRequests: [Record]) -> [String: String] {
        let paths = fileRequests.flatMap { draft.paths[$0.id] ?? [] }
        guard let result = inspectFiles(paths: paths, expectedHashes: draft.pathHashes) else { return [:] }
        for (path, digest) in result.hashes where draft.pathHashes[path] == nil { draft.pathHashes[path] = digest }
        return result.problems
    }

    /// Runs on the caller's queue. The request view invokes this only from its
    /// serial background inspector; small synchronous compatibility callers remain.
    static func inspectFiles(paths: [String], expectedHashes: [String: String], isCanceled: () -> Bool = { false }, progress: (RequestFileHashProgress) -> Void = { _ in }) -> RequestFileInspectionResult? {
        var seen: Set<Data> = []
        let selected = paths.filter { seen.insert(Data($0.utf8)).inserted }
        var result = RequestFileInspectionResult()
        for (index, path) in selected.enumerated() {
            if isCanceled() { return nil }
            let outcome = inspectFile(path, isCanceled: isCanceled) { read, total in
                progress(RequestFileHashProgress(completedFiles: index, totalFiles: selected.count, bytesRead: read, fileSize: total))
            }
            switch outcome {
            case .hashed(let digest):
                result.hashes[path] = digest
                if let expected = expectedHashes[path], expected != digest { result.problems[path] = "Original changed. Relink to inspect and select the new bytes." }
            case .directory:
                if expectedHashes[path] != nil {
                    result.problems[path] = "Original changed from a file to a directory. Relink to select the new original."
                } else { result.directories.insert(path) }
            case .unavailable: result.problems[path] = "Original unavailable. Relink or remove this selection."
            case .unreadable: result.problems[path] = "Original cannot be read. Relink or remove this selection."
            case .changed: result.problems[path] = "Original changed while being read. Relink to inspect and select the new bytes."
            case .canceled: return nil
            }
            progress(RequestFileHashProgress(completedFiles: index + 1, totalFiles: selected.count, bytesRead: 0, fileSize: 0))
        }
        return isCanceled() ? nil : result
    }

    static func fileHash(_ path: String) -> String? {
        if case .hashed(let digest) = inspectFile(path) { return digest }
        return nil
    }

    /// Fixed-size reads keep memory bounded and expose cooperative cancellation.
    static func inspectFile(_ path: String, isCanceled: () -> Bool = { false }, progress: (Int64, Int64) -> Void = { _, _ in }) -> RequestFileHashOutcome {
        if isCanceled() { return .canceled }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { return .unavailable }
        if directory.boolValue { return .directory }
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              (values.fileSize ?? 0) <= 500 * 1024 * 1024,
              let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable }
        defer { try? handle.close() }
        var before = stat()
        guard fstat(handle.fileDescriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= 500 * 1024 * 1024 else { return .unreadable }
        var hash = SHA256(), bytes: Int64 = 0
        let total = Int64(before.st_size)
        var nextProgress = DispatchTime.now().uptimeNanoseconds
        progress(0, total)
        do {
            while true {
                if isCanceled() { return .canceled }
                guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
                bytes += Int64(chunk.count)
                guard bytes <= 500 * 1024 * 1024 else { return .changed }
                hash.update(data: chunk)
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= nextProgress {
                    progress(bytes, total)
                    nextProgress = now + 100_000_000
                }
            }
        } catch { return isCanceled() ? .canceled : .unreadable }
        if isCanceled() { return .canceled }
        var after = stat(), current = stat()
        let currentExists = path.withCString { fstatat(AT_FDCWD, $0, &current, 0) } == 0
        guard fstat(handle.fileDescriptor, &after) == 0, currentExists,
              before.st_dev == current.st_dev, before.st_ino == current.st_ino,
              before.st_size == after.st_size, before.st_size == current.st_size, bytes == total,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_mtimespec.tv_sec == current.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == current.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { return .changed }
        progress(bytes, total)
        return .hashed(hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

enum RequestFileHashOutcome: Equatable {
    case hashed(String), directory, unavailable, unreadable, changed, canceled
}
struct RequestFileInspectionResult {
    var hashes: [String: String] = [:]
    var problems: [String: String] = [:]
    var directories: Set<String> = []
}
struct RequestFileHashProgress {
    let completedFiles: Int
    let totalFiles: Int
    let bytesRead: Int64
    let fileSize: Int64
    var fraction: Double {
        guard totalFiles > 0 else { return 1 }
        let partial = fileSize > 0 ? min(1, Double(bytesRead) / Double(fileSize)) : 0
        return min(1, (Double(completedFiles) + partial) / Double(totalFiles))
    }
}
