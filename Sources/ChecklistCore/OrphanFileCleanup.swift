import Foundation
import GRDB
import Darwin

/// CL-70: files that a command writes before its transaction commits.
///
/// - A source capture records a pending marker in `staging/source-captures/` before any
///   capture file exists. Commit removes the marker. A failed command removes its own capture
///   when no `source_capture` record names it; startup does the same for every marker left
///   by a crash. A capture that a committed record names is never removed.
/// - A managed import already records its durable job before any file. Startup settles a job
///   that stayed without a receipt for the grace period and removes only its own unreferenced
///   stage and final files. A committed or referenced object is never removed.
struct PendingSourceCapture {
    let id: String
    let namespace: String
    var directory: String { "source-captures/" + namespace + "/" + id }
    var marker: String { "staging/source-captures/" + id + ".json" }
}

extension CommandRouter {
    static let abandonedImportGrace: TimeInterval = 7 * 86_400

    func recordPendingSourceCapture(_ capture: PendingSourceCapture) throws {
        let body: JSON = ["id": capture.id, "namespace": capture.namespace, "created_at": now()]
        try StorageObjectFiles(root: root).writeNew(capture.marker, bytes: Data((try jsonString(body)).utf8))
    }

    /// After commit: the record now names the capture, so only the marker goes.
    func settlePendingSourceCaptures(_ captures: [PendingSourceCapture]) {
        guard !captures.isEmpty, let files = try? StorageObjectFiles(root: root) else { return }
        for capture in captures { _ = try? removeManagedFile(files, relative: capture.marker) }
    }

    /// After a failed command. The record check runs in its own read, after the failed
    /// transaction has rolled back, so a capture that did commit is kept.
    @discardableResult
    func discardUncommittedSourceCaptures(_ db: Database, _ captures: [PendingSourceCapture]) -> [String] {
        var removed: [String] = []
        guard !captures.isEmpty, let files = try? StorageObjectFiles(root: root) else { return removed }
        for capture in captures {
            do {
                let committed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM records WHERE id=CAST(? AS TEXT) AND type='source_capture'", arguments: [Data(capture.id.utf8)]) ?? 1
                if committed == 0, try removeManagedTree(files, relative: capture.directory) { removed.append(capture.id) }
                _ = try removeManagedFile(files, relative: capture.marker)
            } catch {
                // The marker stays; startup retries this capture conservatively.
            }
        }
        return removed
    }

    /// Startup only: no command of this router is in flight yet.
    func sweepPendingSourceCaptures(_ db: Database) throws {
        let files = try StorageObjectFiles(root: root)
        guard let markers = try? managedDirectoryEntries(files, relative: "staging/source-captures") else { return }
        var captures: [PendingSourceCapture] = []
        for name in markers where name.hasSuffix(".json") {
            let id = String(name.dropLast(".json".count))
            guard UUID(uuidString: id) != nil, let data = try? files.read("staging/source-captures/" + name, maximum: 65_536),
                  let body = (try? JSONSerialization.jsonObject(with: data)) as? JSON, body["id"] as? String == id,
                  let namespace = body["namespace"] as? String, namespace.range(of: "^project-[0-9a-f]{64}$", options: .regularExpression) != nil else { continue }
            captures.append(PendingSourceCapture(id: id, namespace: namespace))
        }
        discardUncommittedSourceCaptures(db, captures)
    }

    /// The durable journal reserves principal+UUID before publication, including when a
    /// startup cleanup cannot read the destination marker. Unknown journals fail closed.
    /// Also used before command preparation, so competing methods cannot start file work.
    func requirePendingExportIntent(command: String,digest: String,caller: Caller) throws {
        let files = try StorageObjectFiles(root:root)
        for journal in try pendingExportJournals(files) {
            guard let data = try? files.read(journal,maximum:65_536),
                  let export = ExportPublication.pending(from:data,journal:journal) else {
                throw StoreRecovery.required("pending_export_intent_unavailable")
            }
            if EnvelopeStorageIdentity.equal(export.principal,caller.principal),
               EnvelopeStorageIdentity.equal(export.command,command),
               !EnvelopeStorageIdentity.equal(export.digest,digest) {
                throw CoreError("IDEMPOTENCY_CONFLICT","This command ID already belongs to another original intent.")
            }
        }
    }

    private func pendingExportJournals(_ files: StorageObjectFiles) throws -> [String] {
        let names: [String]
        do { names = try managedDirectoryEntries(files,relative:"staging/pending-exports") }
        catch { if errno == ENOENT { return [] }; throw error }
        return names.filter { $0.hasSuffix(".json") && UUID(uuidString:String($0.dropLast(".json".count))) != nil }
            .map { "staging/pending-exports/" + $0 }
    }

    /// Startup only: an export whose pending record survived a crash. Its command's receipt
    /// decides: committed exports keep their folder (only the owner marker goes); uncommitted
    /// ones lose the folder that carries this command's marker and the recorded partial folder.
    func sweepPendingExports(_ db: Database) throws {
        let files = try StorageObjectFiles(root: root)
        for journal in try pendingExportJournals(files) {
            guard let data = try? files.read(journal, maximum: 65_536),
                  let body = (try? JSONSerialization.jsonObject(with:data)) as? JSON,
                  let sourceRoot = body["source_root"] as? String,EnvelopeStorageIdentity.equal(sourceRoot,root.path),
                  let export = ExportPublication.pending(from: data, journal: journal) else { continue }
            guard let committed = try exportReceiptCommitted(db,export:export) else { continue }
            reconcileExport(export, committed: committed)
        }
    }

    /// Startup only. A receipt-less job older than the grace period is abandoned: its
    /// command can no longer be retried with the same ID to reuse the staged bytes.
    func sweepAbandonedManagedImports(_ db: Database, now current: Date = Date()) throws {
        let files = try StorageObjectFiles(root: root)
        let formatter = ISO8601DateFormatter()
        for var job in try records(db, type: "storage_job") where job["kind"] as? String == "attachment_import" {
            if job["settled_reason"] as? String == "canceled_media_staging" {
                // Cancellation already committed its fence. Retry only its own
                // incomplete staging cleanup, without the abandonment grace period.
                if job["cancellation_cleanup_complete"] as? Bool != true { _ = try? finishCanceledMediaImport(db,job:job) }
                continue
            }
            guard ["reserved", "staging", "finalized"].contains(job["state"] as? String ?? "") else { continue }
            guard let created = (job["created_at"] as? String).flatMap(formatter.date(from:)), current.timeIntervalSince(created) >= Self.abandonedImportGrace,
                  let principal = job["parent_principal"] as? String, let command = job["parent_command_id"] as? String, let digest = job["intent_digest"] as? String,
                  let attachmentID = job["attachment_id"] as? String, let pid = job["project_id"] as? String else { continue }
            do {
                guard try managedImportReceipt(db, principal: principal, command: command, digest: digest) == nil,
                      (try? scoped(db, attachmentID, pid, type: "attachment")) == nil else { continue }
                for object in (job["objects"] as? [JSON] ?? []) {
                    for field in ["stage", "final"] {
                        guard let path = object[field] as? String, path.hasPrefix(field == "stage" ? "staging/attachment-imports/" : "objects/") else { continue }
                        try removeManagedImportStage(db, files: files, path: path)
                    }
                }
                // Job-owned partial stages from an interrupted rename.
                let stageDirectory = "staging/attachment-imports/" + (job["id"] as! String)
                for name in (try? managedDirectoryEntries(files, relative: stageDirectory)) ?? [] where name.contains(".partial-") {
                    _ = try removeManagedFile(files, relative: stageDirectory + "/" + name)
                }
                try withValidatedDomainTransaction(db) {
                    let latest = try self.record(db, job["id"] as! String, type: "storage_job")
                    guard int(latest, "revision") == int(job, "revision") else { return .rollback }
                    job["state"] = "settled"; job["settled_reason"] = "abandoned_without_receipt"; job["settled_at"] = now()
                    try self.save(db, self.revised(job), type: "storage_job"); return .commit
                }
            } catch {
                // Kept for a later startup; a referenced object stops the sweep for this job.
            }
        }
    }

    // MARK: Store-relative removal that never follows a symlink

    func removeManagedFile(_ files: StorageObjectFiles, relative: String) throws -> Bool {
        let (directory, name) = try files.parent(relative); defer { Darwin.close(directory) }
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 { if errno == ENOENT { return false }; throw CoreError("CLEANUP_IO", "A pending file could not be inspected.") }
        guard info.st_mode & S_IFMT == S_IFREG, unlinkat(directory, name, 0) == 0, fsync(directory) == 0 else { throw CoreError("CLEANUP_IO", "A pending file could not be removed.") }
        return true
    }

    func removeManagedTree(_ files: StorageObjectFiles, relative: String) throws -> Bool {
        let parentFD: Int32, name: String
        do { (parentFD, name) = try files.parent(relative) } catch { if errno == ENOENT { return false }; throw error }
        defer { Darwin.close(parentFD) }
        var info = stat()
        if fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) != 0 { if errno == ENOENT { return false }; throw CoreError("CLEANUP_IO", "A pending capture could not be inspected.") }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw CoreError("CLEANUP_PATH_REFUSED", "A pending capture is not a directory.") }
        try removeContents(parentFD, name)
        guard unlinkat(parentFD, name, AT_REMOVEDIR) == 0, fsync(parentFD) == 0 else { throw CoreError("CLEANUP_IO", "A pending capture could not be removed.") }
        return true
    }

    func managedDirectoryEntries(_ files: StorageObjectFiles, relative: String) throws -> [String] {
        let (parentFD, name) = try files.parent(relative); defer { Darwin.close(parentFD) }
        return try directoryEntries(parentFD, name)
    }

    private func directoryEntries(_ parent: Int32, _ name: String) throws -> [String] {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CoreError("CLEANUP_IO", "A pending directory could not be opened.") }
        guard let stream = fdopendir(fd) else { Darwin.close(fd); throw CoreError("CLEANUP_IO", "A pending directory could not be read.") }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let child = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            if child != ".", child != ".." { names.append(child) }
        }
        return names
    }

    private func removeContents(_ parent: Int32, _ name: String) throws {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CoreError("CLEANUP_IO", "A pending directory could not be opened.") }
        defer { Darwin.close(fd) }
        for child in try directoryEntries(parent, name) {
            var info = stat()
            guard fstatat(fd, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw CoreError("CLEANUP_IO", "A pending entry could not be inspected.") }
            if info.st_mode & S_IFMT == S_IFDIR {
                try removeContents(fd, child)
                guard unlinkat(fd, child, AT_REMOVEDIR) == 0 else { throw CoreError("CLEANUP_IO", "A pending directory could not be removed.") }
            } else {
                guard unlinkat(fd, child, 0) == 0 else { throw CoreError("CLEANUP_IO", "A pending file could not be removed.") }
            }
        }
    }
}
