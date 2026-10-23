import Foundation
import CryptoKit
import Darwin
import Combine
import ChecklistCore
import ChecklistIPC

struct FilePreviewFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// An owned, verified copy isolates all native decoders and external editors from
/// immutable evidence. Its attribution describes the source, never a new artifact.
final class AuthorizedPreviewFile: @unchecked Sendable {
    let url: URL
    let source: Record
    let sha256: String
    let directory: URL
    init(url: URL, source: Record, directory: URL) {
        self.url = url; self.source = source; sha256 = source.string("sha256"); self.directory = directory
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    static func copy(path: String, source: Record, isCanceled: () -> Bool = { Task.isCancelled }, progress: Progress? = nil, didCopyChunkForTesting: (@Sendable (Int64) -> Void)? = nil) throws -> AuthorizedPreviewFile {
        if isCanceled() || progress?.isCancelled == true { throw CancellationError() }
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FilePreviewFailure("The authorized original is missing or cannot be read safely.") }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_size >= 0, before.st_size <= FilePreviewLimits.fileBytes,
              before.st_size == Int64(source.integer("size", fallback: -1)) else { throw FilePreviewFailure("The original changed or exceeds the 500 MiB preview limit.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChecklistPreview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: root) } }
        let name = (source.string("name") as NSString).lastPathComponent
        let outputURL = root.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "attachment" : name)
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw FilePreviewFailure("The preview copy could not be created.") }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        var digest = SHA256(), count: Int64 = 0
        progress?.totalUnitCount = before.st_size
        progress?.completedUnitCount = 0
        while true {
            if isCanceled() || progress?.isCancelled == true { throw CancellationError() }
            guard let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
            count += Int64(chunk.count)
            guard count <= before.st_size else { throw FilePreviewFailure("The original changed while preparing its preview.") }
            digest.update(data: chunk); try output.write(contentsOf: chunk)
            progress?.completedUnitCount = count
            didCopyChunkForTesting?(count)
        }
        var after = stat()
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard fstat(fd, &after) == 0, before.st_ino == after.st_ino, before.st_dev == after.st_dev,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, count == before.st_size,
              hash == source.string("sha256"), hash.count == 64 else { throw FilePreviewFailure("The original no longer matches its recorded SHA-256. Preview and opening are unavailable.") }
        if isCanceled() || progress?.isCancelled == true { throw CancellationError() }
        try output.synchronize()
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: outputURL.path)
        finished = true
        return AuthorizedPreviewFile(url: outputURL, source: source, directory: root)
    }

    /// External copies persist in the app cache, with a provenance sidecar. They
    /// are intentionally not imported back or used to satisfy an inspection.
    static var defaultExternalWorkingCopyBase: URL { ChecklistInstance.current.cachesRoot }
    func externalWorkingCopy(baseDirectory: URL? = nil) throws -> URL {
        let base = baseDirectory ?? Self.defaultExternalWorkingCopyBase
        let root = base.appendingPathComponent("Checklist/OpenCopies/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let content = root.appendingPathComponent("content", isDirectory: true)
            try FileManager.default.createDirectory(at: content, withIntermediateDirectories: false)
            let copy = content.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: copy)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
            let provenance: [String: Any] = ["kind": "external_working_copy", "attachment_id": source.id,
                "project_id": source.string("project_id"), "task_id": source.string("task_id"),
                "source_sha256": sha256, "source_name": source.string("name"), "source_origin": source.string("origin"),
                "source_author": source.string("author"), "created_at": ISO8601DateFormatter().string(from: Date()),
                "target_manifest_id": source.string("target_manifest_id"), "review_attempt_id": source.string("review_attempt_id"),
                "approval": "none; edits do not replace the source artifact"]
            try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent(".checklist-source.json"), options: .atomic)
            return copy
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
}

@MainActor
final class FilePreviewLoader: ObservableObject {
    @Published private(set) var file: AuthorizedPreviewFile?
    @Published private(set) var loading = false
    @Published private(set) var problem = ""
    @Published private(set) var copiedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var copying = false
    @Published private(set) var canceling = false
    @Published private(set) var canceled = false
    private var generation = UUID()
    private var copyProgress: Progress?
    private var progressObservation: AnyCancellable?
    // Tests can hold the detached copy at a known write boundary until cancellation.
    private let didCopyChunkForTesting: (@Sendable (Int64) -> Void)?
    init(didCopyChunkForTesting: (@Sendable (Int64) -> Void)? = nil) {
        self.didCopyChunkForTesting = didCopyChunkForTesting
    }
    var cancellationSummary: String {
        let outcome = totalBytes > 0
            ? "Preparation stopped after copying \(copiedBytes) of \(totalBytes) bytes."
            : "Preparation was canceled before copying began."
        return outcome + " No inspection was recorded."
    }
    func cancelPreparation() {
        guard loading, !canceling else { return }
        canceling = true
        copyProgress?.cancel()
    }
    func cancel() {
        copyProgress?.cancel(); progressObservation = nil; copyProgress = nil
        generation = UUID(); loading = false; copying = false; file = nil
        copiedBytes = 0; totalBytes = 0; canceled = false; canceling = false
    }
    func load(_ attachment: Record, store: ChecklistStore) async {
        cancel(); let current = generation; loading = true; problem = ""
        defer {
            if generation == current {
                if let copyProgress { copiedBytes = copyProgress.completedUnitCount }
                loading = false; copying = false; canceling = false
                progressObservation = nil; copyProgress = nil
            }
        }
        var hold: String?
        do {
            guard !attachment.bool("unlinked") else { throw FilePreviewFailure("This original is no longer attached to the ticket.") }
            switch attachment.string("availability") {
            case "available": break
            case "original_cleaned", "cleaned": throw FilePreviewFailure("The original is unavailable; its metadata is retained. A retained thumbnail cannot replace it.")
            default: throw FilePreviewFailure("The original is missing or unavailable. A retained thumbnail cannot replace it.")
            }
            try Task.checkCancellation()
            // Capture a returned hold even if the view closes during authorization.
            // The independent read/release tasks retain the transport's usual bounds.
            let response = try await Task { @MainActor in
                try await store.request("attachment_read", ["project_id": attachment.string("project_id"), "attachment_id": attachment.id, "representation": "original"])
            }.value
            hold = response["read_hold_id"] as? String
            try Task.checkCancellation()
            guard generation == current, !canceling else { throw CancellationError() }
            let actual = Record(values: response)
            guard actual.id == attachment.id, actual.string("project_id") == attachment.string("project_id"),
                  actual.string("task_id") == attachment.string("task_id"), actual.string("sha256") == attachment.string("sha256"),
                  actual.string("availability") == "available", actual.string("mode") == attachment.string("mode"),
                  actual.integer("size", fallback: -1) == attachment.integer("size", fallback: -1),
                  actual.string("mode") != "managed" || hold != nil,
                  let path = response["url"] as? String, path.hasPrefix("/") else { throw FilePreviewFailure("The service did not return this exact available original and its reader hold.") }
            try Task.checkCancellation()
            let progress = Progress(totalUnitCount: max(0, Int64(attachment.integer("size", fallback: 0))))
            copyProgress = progress; totalBytes = progress.totalUnitCount; copying = true
            progressObservation = progress.publisher(for: \.completedUnitCount)
                .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] count in
                    guard let self, self.generation == current, self.loading else { return }
                    self.copiedBytes = max(self.copiedBytes, count)
                }
            let didCopyChunkForTesting = self.didCopyChunkForTesting
            let work = Task.detached(priority: .userInitiated) {
                try AuthorizedPreviewFile.copy(path: path, source: attachment, progress: progress, didCopyChunkForTesting: didCopyChunkForTesting)
            }
            let copy = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            try Task.checkCancellation()
            guard generation == current, !canceling else { throw CancellationError() }
            if generation == current { file = copy; loading = false }
        } catch {
            if generation == current, !Task.isCancelled {
                if error is CancellationError {
                    if let copyProgress { copiedBytes = copyProgress.completedUnitCount }
                    canceled = true; loading = false; copying = false; canceling = false
                } else { problem = PlainError.text(error) }
            }
        }
        if let hold {
            let failure = await Task { @MainActor () -> String? in
                do {
                    _ = try await store.request("attachment_read_release", ["command_id": UUID().uuidString, "project_id": attachment.string("project_id"), "read_hold_id": hold])
                    return nil
                } catch { return PlainError.text(error) }
            }.value
            if let failure, generation == current, !Task.isCancelled {
                let warning = "Checklist could not confirm releasing the temporary reader hold. It will expire automatically. " + failure
                problem = problem.isEmpty ? warning : problem + "\n" + warning
            }
        }
    }
}
