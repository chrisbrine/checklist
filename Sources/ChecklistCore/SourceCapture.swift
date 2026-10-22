import Foundation
import GRDB
import Darwin

/// CL-71: one bounded git call. Both pipes are read at the same time, so a full stderr pipe
/// cannot block the child while the parent waits on stdout, and a hung git ends at the deadline.
enum SourceGit {
    static let defaultTimeout: TimeInterval = 60

    static let trustedPaths = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]

    /// No PATH lookup. Check every ancestor and every symlink destination, including
    /// Homebrew's bin -> Cellar links. Symlink modes are not meaningful on macOS;
    /// their owner and containing directory must still be trusted.
    static func trustedExecutable(_ path: String, owner: uid_t = getuid()) throws -> String {
        func refused(_ component: String, _ reason: String) -> CoreError {
            CoreError("SOURCE_GIT_UNTRUSTED", "Source capture refused Git at \(path): \(reason) (\(component)).", details: ["path": path, "component": component, "reason": reason])
        }
        func check(_ candidate: String, hops: Int) throws -> String {
            guard candidate.hasPrefix("/"), hops <= 40 else { throw refused(candidate, "the executable path or symlink chain is invalid") }
            let parts = URL(fileURLWithPath: candidate).standardizedFileURL.path.split(separator: "/").map(String.init)
            var prefix = ""
            for (index, part) in ([""] + parts).enumerated() {
                prefix = index == 0 ? "/" : (prefix == "/" ? "/" + part : prefix + "/" + part)
                var info = stat()
                guard lstat(prefix, &info) == 0 else { throw refused(prefix, "the path cannot be inspected") }
                guard info.st_uid == 0 || info.st_uid == owner else { throw refused(prefix, "the path is not owned by root or the owner") }
                let kind = info.st_mode & S_IFMT
                if kind == S_IFLNK {
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: prefix)
                    let destination = target.hasPrefix("/") ? target : URL(fileURLWithPath: prefix).deletingLastPathComponent().appendingPathComponent(target).path
                    let suffix = parts.dropFirst(index).joined(separator: "/")
                    return try check(destination + (suffix.isEmpty ? "" : "/" + suffix), hops: hops + 1)
                }
                guard info.st_mode & 0o022 == 0 else { throw refused(prefix, "the path is writable by other users") }
                let isFile = index == parts.count
                guard kind == (isFile ? S_IFREG : S_IFDIR) else { throw refused(prefix, "the path is not a regular executable and directories") }
            }
            guard access(candidate, X_OK) == 0 else { throw refused(candidate, "the file is not executable") }
            return URL(fileURLWithPath: candidate).standardizedFileURL.path
        }
        return try check(path, hops: 0)
    }

    static func resolve(candidates: [String] = trustedPaths) throws -> String {
        var refusals: [String] = []
        for path in candidates {
            var info = stat()
            if lstat(path, &info) != 0, errno == ENOENT { continue }
            do { return try trustedExecutable(path) }
            catch let error as CoreError { refusals.append(error.message) }
        }
        throw CoreError("SOURCE_GIT_UNAVAILABLE", refusals.isEmpty ? "Source capture needs a trusted command-line Git in /opt/homebrew/bin, /usr/local/bin or /usr/bin." : refusals.joined(separator: " "), details: ["reason": "no_trusted_git"])
    }

    static func run(_ path: String, _ args: [String], executable: String? = nil, timeout: TimeInterval = defaultTimeout) throws -> Data {
        let executable = try executable.map { try trustedExecutable($0) } ?? resolve()
        let process = Process(), out = Pipe(), err = Pipe(), exited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = ["-C", path] + args
        process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        let readers = DispatchGroup(), lock = NSLock()
        var output = Data(), errors = Data()
        try process.run()
        for (handle, isOutput) in [(out.fileHandleForReading, true), (err.fileHandleForReading, false)] {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = handle.readDataToEndOfFile()
                lock.lock(); if isOutput { output = data } else { errors = data }; lock.unlock()
                readers.leave()
            }
        }
        let deadline = DispatchTime.now() + timeout
        guard exited.wait(timeout: deadline) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = exited.wait(timeout: .now() + 2) }
            _ = readers.wait(timeout: .now() + 2)
            throw CoreError("SOURCE_CAPTURE_INCOMPLETE", "Git did not finish the source inventory within \(Int(timeout)) seconds.", details: ["reason": "git_timeout"])
        }
        // The child has exited; its pipes reach end of file unless a grandchild still holds them.
        guard readers.wait(timeout: .now() + 5) == .success else { throw CoreError("SOURCE_CAPTURE_INCOMPLETE", "Git output did not close after git exited.", details: ["reason": "git_pipe_open"]) }
        lock.lock(); defer { lock.unlock() }
        guard process.terminationStatus == 0 else {
            let reason = String(data: errors.prefix(4096), encoding: .utf8) ?? "git failed"
            let diagnostic = reason.lowercased()
            if diagnostic.contains("xcode") && diagnostic.contains("license") {
                throw CoreError("SOURCE_GIT_LICENSE_REQUIRED", "Git could not run because the Xcode license has not been accepted. The owner must run sudo xcodebuild -license accept in Terminal, then retry.", details: ["git_path": executable, "reason": "xcode_license_not_accepted"])
            }
            throw CoreError("SOURCE_CAPTURE_INCOMPLETE", "Git could not inventory the complete enrolled source tree.", details: ["reason": reason, "git_path": executable])
        }
        return output
    }
}

extension CommandRouter {
    func sourceGit(_ path: String,_ args: [String]) throws -> Data {
        _ = try sourceGitMetadataOutsideStore(path)
        return try SourceGit.run(path,args)
    }
    /// Bindings are not permission to recursively inventory this instance's data.
    /// Use the existing physical/Unicode/volume-case reservation comparison so
    /// aliases cannot move a source read across the store boundary.
    private func requireSourceOutsideStore(_ path: String, recursive: Bool) throws {
        let source = reservationKey(path), store = reservationKey(root.path)
        guard !containsPath(store, source), !(recursive && containsPath(source, store)) else {
            throw CoreError("SOURCE_CAPTURE_INCOMPLETE", "Source capture cannot read a Checklist data root or a folder containing it.", details: ["reason":"checklist_store_overlap"])
        }
    }
    /// Inspect only Git's filesystem pointers here. Git configuration remains
    /// project content under the owner's binding trust (CL-180).
    private func sourceGitMetadataOutsideStore(_ path: String) throws -> Bool {
        let project = URL(fileURLWithPath:path), entry = project.appendingPathComponent(".git")
        func information(_ url: URL) throws -> stat? {
            var value = stat()
            guard lstat(url.path,&value) == 0 else {
                if errno == ENOENT || errno == ENOTDIR { return nil }
                throw CoreError("SOURCE_CAPTURE_INCOMPLETE","Git metadata could not be inspected before source capture.")
            }
            return value
        }
        func pointer(_ value: String, relativeTo parent: URL) -> URL {
            URL(fileURLWithPath:value,relativeTo:parent).standardizedFileURL
        }
        guard let info = try information(entry) else { return false }
        // lstat precedes resolution. Refuse before reading a symlink's target.
        try requireSourceOutsideStore(entry.path,recursive:true)
        var directory = entry
        if info.st_mode & S_IFMT == S_IFLNK {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath:entry.path)
            directory = pointer(target,relativeTo:project).resolvingSymlinksInPath()
            try requireSourceOutsideStore(directory.path,recursive:true)
        }
        if let resolved = try information(directory), resolved.st_mode & S_IFMT == S_IFREG {
            let value = try String(contentsOf:directory,encoding:.utf8)
            if value.hasPrefix("gitdir: ") {
                directory = pointer(String(value.dropFirst(8)).trimmingCharacters(in:.newlines),relativeTo:project)
                try requireSourceOutsideStore(directory.path,recursive:true)
            }
        }
        let common = directory.appendingPathComponent("commondir")
        if try information(common) != nil {
            try requireSourceOutsideStore(common.path,recursive:false)
            let value = try String(contentsOf:common,encoding:.utf8).trimmingCharacters(in:.newlines)
            try requireSourceOutsideStore(pointer(value,relativeTo:directory).path,recursive:true)
        }
        return true
    }
    /// `useCache` returns the inventory that this command computed before the writer (CL-71).
    func sourceInventory(_ path: String, additional: [String] = [], useCache: Bool = true) throws -> JSON {
        try requireSourceOutsideStore(path, recursive: true)
        let git = try sourceGitMetadataOutsideStore(path)
        if useCache {
            let preparation = commandPreparation, key = inventoryKey(path,additional)
            if let cached = preparation.inventories[key] { return cached }
            // A failed prefetch fails here with its own error instead of running git again inside the writer.
            if let failure = preparation.failedInventories[key] { throw failure }
        }
        var paths: [String] = [],base = "unversioned",index = ""
        var gitProvenance: JSON = [:]
        if git {
            let executable = try SourceGit.resolve()
            func sourceGit(_ path: String, _ args: [String]) throws -> Data {
                _ = try sourceGitMetadataOutsideStore(path)
                return try SourceGit.run(path, args, executable: executable)
            }
            let version = String(decoding: try sourceGit(path, ["--version"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            gitProvenance = ["git_path": executable, "git_version": version]
            let top = String(data:try sourceGit(path,["rev-parse","--show-toplevel"]),encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            guard reservationKey(top) == reservationKey(path) else { throw CoreError("SOURCE_CAPTURE_INCOMPLETE","Capture the complete enrolled repository root, not a nested checkout view.") }
            base = (try? String(data:sourceGit(path,["rev-parse","HEAD"]),encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines)) ?? "unborn"
            let entries = try sourceGit(path,["ls-files","--stage","-z"])
            guard !String(decoding:entries,as:UTF8.self).split(separator:"\0").contains(where: {$0.hasPrefix("160000 ")}) else { throw CoreError("SOURCE_CAPTURE_INCOMPLETE","Submodule source needs an explicitly supported complete capture; a commit pointer alone is insufficient.") }
            index = hash(entries)
            paths = String(decoding:try sourceGit(path,["ls-files","-z","--cached","--others","--exclude-standard"]),as:UTF8.self).split(separator:"\0").map(String.init)
        } else {
            guard let enumerator = FileManager.default.enumerator(atPath:path) else { throw CoreError("SOURCE_CAPTURE_INCOMPLETE","The project root is unreadable.") }
            for case let relative as String in enumerator {
                let url = URL(fileURLWithPath:path).appendingPathComponent(relative)
                if [".git",".build","node_modules",".checklist-build",".DS_Store"].contains(url.lastPathComponent) { enumerator.skipDescendants();continue }
                try requireSourceOutsideStore(url.path, recursive: false)
                let attrs = try FileManager.default.attributesOfItem(atPath:url.path)
                if attrs[.type] as? FileAttributeType != .typeDirectory { paths.append(relative) }
            }
        }
        paths += additional
        guard Set(paths).count <= 20000 else { throw CoreError("SOURCE_CAPTURE_INCOMPLETE","The bounded capture accepts at most 20,000 source entries.") }
        var files: [JSON] = [],total = 0
        for relative in Set(paths).sorted() {
            guard !relative.isEmpty,!relative.hasPrefix("/"),!relative.split(separator:"/").contains(".."),!relative.split(separator:"/").contains(".git") else { throw CoreError("SOURCE_CAPTURE_INCOMPLETE","Source entries must be relative to the enrolled root.") }
            let url = URL(fileURLWithPath:path).appendingPathComponent(relative),attrs: [FileAttributeKey:Any]
            try requireSourceOutsideStore(url.path, recursive: false)
            do { attrs = try FileManager.default.attributesOfItem(atPath:url.path) }
            catch { if !FileManager.default.fileExists(atPath:url.path) { files.append(["path":relative,"kind":"deleted"]);continue };throw error }
            let type = attrs[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath:url.path)
                guard !target.hasPrefix("/"),containsPath(reservationKey(path),reservationKey(url.path)) else { throw CoreError("SOURCE_CAPTURE_INCOMPLETE","Source symlinks must stay within the captured tree.") }
                files.append(["path":relative,"kind":"symlink","target":target,"sha256":hash(Data(target.utf8))]);continue
            }
            guard type == .typeRegular else { throw CoreError("SOURCE_CAPTURE_INCOMPLETE","Only regular source files and internal symlinks can be captured.") }
            let bytes = try Data(contentsOf:url,options:.mappedIfSafe);total += bytes.count
            guard total <= 512*1024*1024 else { throw CoreError("SOURCE_CAPTURE_INCOMPLETE","The bounded source capture accepts at most 512 MiB.") }
            let executable = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            files.append(["path":relative,"kind":"file","sha256":hash(bytes),"size":bytes.count,"executable":executable & 0o111 != 0])
        }
        for file in files where file["kind"] as? String == "symlink" {
            let destination = reservationKey(URL(fileURLWithPath:path).appendingPathComponent(file["path"] as! String).path)
            guard files.contains(where: {$0["kind"] as? String == "file" && reservationKey(URL(fileURLWithPath:path).appendingPathComponent($0["path"] as! String).path) == destination}) else { throw CoreError("SOURCE_CAPTURE_INCOMPLETE","A source symlink must resolve to a regular file included in this exact capture.") }
        }
        guard !files.isEmpty else { throw CoreError("SOURCE_CAPTURE_INCOMPLETE","The source capture is empty.") }
        let identity: JSON = ["base_revision":base,"index_sha256":index,"files":files]
        var inventory: JSON = ["base_revision":base,"index_sha256":index,"files":files,"sha256":hash(Data((try jsonString(identity)).utf8)),"size":total]
        inventory.merge(gitProvenance) { _, new in new }
        return inventory
    }
    /// Inside the submission transaction: only metadata. The capture's files were copied,
    /// hashed and checked before the object gate and the SQL writer (CL-71). A path with no
    /// prepared capture (for example a direct internal call) copies here as before.
    func captureSource(_ db: Database, request: JSON, task: JSON, attempt: JSON) throws -> JSON {
        let pid = task["project_id"] as! String,project = try record(db,pid,type:"project"),path = project["root_path"] as? String ?? ""
        guard !path.isEmpty else { throw CoreError("ROOT_MISMATCH","Source review needs an enrolled writable project root.") }
        try requireSourceOutsideStore(path, recursive: true)
        if let supplied = request["root_path"] as? String,reservationKey(supplied) != reservationKey(path) { throw CoreError("ROOT_MISMATCH","Source capture always inventories the complete enrolled root.") }
        let additional = strings(request,"additional_paths")
        let prepared: PreparedSourceCapture
        if let key = attempt["id"] as? String,let existing = commandPreparation.captures[try Self.preparedCaptureKey(attempt:key,request:request)] {
            guard existing.projectID == pid,reservationKey(existing.sourceRoot) == reservationKey(path),existing.additional == additional else { throw CoreError("SOURCE_CHANGED","The prepared source capture no longer matches this project. No submission was created.") }
            prepared = existing
        } else {
            prepared = try copySourceCapture(projectID:pid,sourceRoot:path,request:request)
            inlineSourceCaptures.append(prepared.pending)
        }
        let durable = try StorageObjectFiles(root:root)
        // A cheap presence check; the full byte and membership validation ran after the copy.
        let (captureParent,_) = try durable.parent(prepared.pending.directory + "/source/.check");Darwin.close(captureParent)
        consumedSourceCaptures.insert(prepared.pending.id)
        var capture = prepared.inventory;capture["id"] = prepared.pending.id;capture["project_id"] = pid;capture["task_id"] = task["id"];capture["attempt_id"] = attempt["id"];capture["source_root"] = path;capture["snapshot_path"] = prepared.pending.directory + "/source";capture["additional_paths"] = additional;capture["captured_at"] = now();capture["revision"] = 1
        var relevance = sourceRelevance(root:path,attempt:attempt,additional:additional)
        if relevance["mode"] as? String == "scoped" {
            let entries = try relevantSourceEntries(capture,relevance:relevance)
            relevance["symlink_inputs"] = entries.keys.sorted().compactMap {entries[$0]?["resolved_input"] as? JSON}
            capture["relevant_sha256"] = hash(Data((try jsonString(entries)).utf8))
        } else {capture["relevant_sha256"] = capture["sha256"]}
        capture["relevance"] = relevance
        try durable.writeNew(prepared.pending.directory + "/manifest.json",bytes:Data((try jsonString(capture)).utf8));try save(db,capture,type:"source_capture");return capture
    }

    static func preparedCaptureKey(attempt: String,request: JSON) throws -> String { attempt + "\u{0}" + (try jsonString(request)) }

    /// File and git work for one capture: inventory, copy, re-inventory and byte validation.
    /// It writes a pending marker first; on failure it removes its own partial capture.
    func copySourceCapture(projectID pid: String,sourceRoot path: String,request: JSON) throws -> PreparedSourceCapture {
        let additional = strings(request,"additional_paths"),before = try sourceInventory(path,additional:additional,useCache:false)
        if let expected = request["expected_sha256"] as? String,expected != before["sha256"] as? String { throw CoreError("SOURCE_CHANGED","Source changed before capture.") }
        let pending = PendingSourceCapture(id:uuid(),namespace:"project-" + hash(Data(pid.utf8)))
        let durable = try StorageObjectFiles(root:root)
        try recordPendingSourceCapture(pending)
        do {
            let (captureParent,_) = try durable.parent(pending.directory + "/source/.admission",create:true);Darwin.close(captureParent)
            for file in before["files"] as? [JSON] ?? [] {
                let relative = file["path"] as! String
                if file["kind"] as? String == "deleted" { continue }
                try requireSourceOutsideStore(URL(fileURLWithPath:path).appendingPathComponent(relative).path, recursive: false)
                if file["kind"] as? String == "symlink" { try durable.writeLink(pending.directory + "/source/" + relative,target:file["target"] as! String) }
                else { let bytes = try Data(contentsOf:URL(fileURLWithPath:path).appendingPathComponent(relative),options:.mappedIfSafe);guard hash(bytes) == file["sha256"] as? String else { throw CoreError("SOURCE_CHANGED","Source changed while capturing.") };try durable.writeNew(pending.directory + "/source/" + relative,bytes:bytes,permissions:bool(file,"executable") ? 0o555 : 0o444) }
            }
            let after = try sourceInventory(path,additional:additional,useCache:false)
            guard before["sha256"] as? String == after["sha256"] as? String else { throw CoreError("SOURCE_CHANGED","Source/index/base changed during capture. No submission was created.") }
            var check = before;check["snapshot_path"] = pending.directory + "/source"
            try validateCapturedFiles(check)
        } catch {
            _ = try? removeManagedTree(durable,relative:pending.directory)
            _ = try? removeManagedFile(durable,relative:pending.marker)
            throw error
        }
        return PreparedSourceCapture(pending:pending,projectID:pid,sourceRoot:path,additional:additional,inventory:before)
    }
    func validateCapturedFiles(_ capture: JSON) throws {
        guard let stored = capture["snapshot_path"] as? String,let local = try? managedURL(stored,family:"source-captures") else { throw CoreError("EVIDENCE_STALE","The managed source capture is unavailable.") }
        let captured = try StorageObjectFiles(root:local), entries = capture["files"] as? [JSON] ?? []
        var expected: [String:JSON] = [:]
        for file in entries {
            let path = try text(file,"path",max:4000)
            _ = try StorageObjectFiles.parts(path)
            guard expected[path] == nil else { throw CoreError("EVIDENCE_STALE","Captured source paths are ambiguous.") }
            expected[path] = file
        }
        let expectedPaths = Set(expected.filter { $0.value["kind"] as? String != "deleted" }.keys)
        guard try captured.listedFiles(budget:.production()) == expectedPaths else { throw CoreError("EVIDENCE_STALE","Captured source membership changed.") }
        for (path,file) in expected {
            if file["kind"] as? String == "deleted" {
                guard !(try captured.regularOrLinkExists(path)) else { throw CoreError("EVIDENCE_STALE","A captured deletion changed.") }
                continue
            }
            if file["kind"] as? String == "symlink" {
                let target = try text(file,"target",max:4000)
                guard !target.hasPrefix("/"),!target.contains("\0"),
                      try captured.linkTarget(path) == target,hash(Data(target.utf8)) == file["sha256"] as? String else { throw CoreError("EVIDENCE_STALE","A captured symlink changed.") }
                // A captured link must close over an included regular file. Resolve
                // its lexical target only; never follow a captured link on disk.
                let prefix = local.path + "/"
                var cursor = path,visited = Set<String>()
                while expected[cursor]?["kind"] as? String == "symlink" {
                    guard visited.insert(cursor).inserted,visited.count <= 32,
                          let link = expected[cursor]?["target"] as? String,!link.hasPrefix("/"),!link.contains("\0") else { throw CoreError("EVIDENCE_STALE","A captured symlink chain is invalid.") }
                    let destination = local.appendingPathComponent(cursor).deletingLastPathComponent().appendingPathComponent(link).standardizedFileURL.path
                    guard destination.hasPrefix(prefix) else { throw CoreError("EVIDENCE_STALE","A captured symlink leaves its immutable capture.") }
                    cursor = String(destination.dropFirst(prefix.count))
                }
                guard expected[cursor]?["kind"] as? String == "file" else { throw CoreError("EVIDENCE_STALE","A captured symlink must resolve to an included regular file.") }
            } else {
                guard file["kind"] as? String == "file" else { throw CoreError("EVIDENCE_STALE","Captured source has an unsupported entry.") }
                let executable = try captured.openRegular(path) { fd -> Bool in
                    var info = stat();guard fstat(fd,&info) == 0 else { throw StorageSnapshotFailure.io }
                    return info.st_mode & 0o111 != 0
                }
                let bytes = try captured.read(path,maximum:500 * 1024 * 1024)
                guard executable == bool(file,"executable"),hash(bytes) == file["sha256"] as? String else { throw CoreError("EVIDENCE_STALE","Captured source bytes changed or disappeared.") }
            }
        }
    }
    /// Content metadata of every captured entry, without reading bytes: kind, device, inode,
    /// size, modification time, executable bit and symlink target, plus the capture folder.
    /// A content write, an added or removed entry, a replacement or an executable-bit change
    /// changes it; a permission or ownership change alone does not.
    func captureObservation(_ capture: JSON) throws -> [String: String] {
        guard let stored = capture["snapshot_path"] as? String,let local = try? managedURL(stored,family:"source-captures") else { throw CoreError("EVIDENCE_STALE","The managed source capture is unavailable.") }
        let path = local.path, captured = try StorageObjectFiles(root:local)
        func describe(_ relative: String) throws -> String {
            var info = stat()
            if relative == "." { guard fstat(captured.descriptor,&info) == 0 else { throw StorageSnapshotFailure.io } }
            else {
                let (parent,name) = try captured.parent(relative);defer { Darwin.close(parent) }
                guard fstatat(parent,name,&info,AT_SYMLINK_NOFOLLOW) == 0 else { throw CoreError("EVIDENCE_STALE","Captured source membership changed.") }
            }
            let kind = info.st_mode & S_IFMT
            let executable = kind == S_IFREG && info.st_mode & 0o111 != 0
            var value = "\(kind):\(info.st_dev):\(info.st_ino)"
            if kind != S_IFDIR { value += ":\(info.st_size):\(executable):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)" }
            if kind == S_IFLNK { value += ":" + (try captured.linkTarget(relative)) }
            return value
        }
        var result: [String: String] = [".": try describe(".")]
        guard let enumerator = FileManager.default.enumerator(atPath:path) else { throw CoreError("EVIDENCE_STALE","Captured source is unreadable.") }
        for case let relative as String in enumerator {
            let value = try describe(relative)
            result[relative] = value
        }
        return result
    }
    /// Resolve only immutable inventory entries, shared by instruction coverage and scoped freshness.
    func capturedSourceInput(_ alias: String,entries: [String:JSON]) throws -> JSON {
        func linkedPath(from path: String,target: String) throws -> String {
            guard !target.isEmpty,!target.hasPrefix("/"),!target.contains("\0") else {throw CoreError("EVIDENCE_STALE","Captured project instruction links must remain inside the immutable capture.")}
            var components = path.split(separator:"/").dropLast().map(String.init)
            for component in target.split(separator:"/") {
                if component == "." {continue}
                if component == ".." {
                    guard !components.isEmpty else {throw CoreError("EVIDENCE_STALE","Captured project instruction links must remain inside the immutable capture.")}
                    components.removeLast()
                } else {components.append(String(component))}
            }
            guard !components.isEmpty else {throw CoreError("EVIDENCE_STALE","Captured project instruction links must resolve to an included regular file.")}
            return components.joined(separator:"/")
        }
        var path = alias,visited = Set<String>(),links: [JSON] = []
        while true {
            guard visited.insert(path).inserted,let entry = entries[path] else {throw CoreError("EVIDENCE_STALE","Captured project instructions contain a cyclic or missing link target.")}
            if entry["kind"] as? String == "file",let contentHash = entry["sha256"] as? String {
                var ref: JSON = ["path":alias,"sha256":contentHash]
                if !links.isEmpty {ref["resolved_path"] = path;ref["link_chain"] = links}
                return ref
            }
            guard entry["kind"] as? String == "symlink",links.count < 32,let target = entry["target"] as? String,let linkHash = entry["sha256"] as? String,hash(Data(target.utf8)) == linkHash else {throw CoreError("EVIDENCE_STALE","Captured project instructions must resolve through at most 32 hash-verified internal links to a regular file.")}
            links.append(["path":path,"target":target,"sha256":linkHash]);path = try linkedPath(from:path,target:target)
        }
    }
    /// Keep declared aliases alongside canonical reservations. Freeze root-relative,
    /// case-insensitive prefixes so future additions under a directory are relevant too.
    func sourceRelevance(root: String,attempt: JSON,additional: [String]) -> JSON {
        let files = attempt["file_scopes"] as? [JSON] ?? []
        guard !files.isEmpty else { return ["mode":"whole"] }
        let base = reservationKey(root).lowercased()
        let paths = files.flatMap { scope -> [String] in
            let aliases = (scope["declared_path"] as? String).map {[declaredScopePath($0,root:root)]} ?? []
            return aliases + ((scope["path"] as? String).map {[$0]} ?? [])
        }
        let scopes = paths.compactMap { path -> String? in
            let key = path.lowercased()
            guard containsPath(base,key) else { return nil }
            return key == base ? "." : String(key.dropFirst(base.count + 1))
        }
        return ["mode":"scoped","scopes":Set(scopes + additional.map {$0.lowercased()}).sorted(),"instruction_names":["AGENTS.md","CLAUDE.md"]]
    }
    func relevantSourceEntries(_ inventory: JSON,relevance: JSON) throws -> [String:JSON] {
        let scopes = strings(relevance,"scopes"),instructions = Set(strings(relevance,"instruction_names").map {$0.lowercased()})
        let files = inventory["files"] as? [JSON] ?? []
        var captured: [String:JSON] = [:],entries: [String:JSON] = [:]
        for file in files {
            guard let path = file["path"] as? String,captured[path] == nil else {throw CoreError("EVIDENCE_STALE","Relevant source paths are ambiguous.")}
            captured[path] = file
        }
        for file in files {
            guard let path = file["path"] as? String else { continue }
            let key = path.lowercased()
            guard relevance["mode"] as? String != "scoped" || instructions.contains(key.split(separator:"/").last.map(String.init) ?? "") || scopes.contains(where: {$0 == "." || containsPath($0,key)}) else { continue }
            // Size and Git bookkeeping are not freshness inputs. Case-folded paths match
            // reservations; ambiguous case aliases refuse rather than hide a changed entry.
            guard entries[key] == nil else { throw CoreError("EVIDENCE_STALE","Relevant source paths are ambiguous: \(path).") }
            var identity = file.filter {["kind","sha256","executable","target"].contains($0.key)}
            if file["kind"] as? String == "symlink" {
                var resolved = try capturedSourceInput(path,entries:captured)
                resolved["executable"] = captured[resolved["resolved_path"] as! String]?["executable"]
                identity["resolved_input"] = resolved
            }
            entries[key] = identity
        }
        return entries
    }
    func validateSourceTarget(_ db: Database, evidence: JSON, task: JSON) throws -> JSON? {
        guard let ref = evidence["source_capture"] as? JSON else { return nil }
        let capture = try scoped(db,try text(ref,"id"),task["project_id"] as! String,type:"source_capture")
        guard capture["task_id"] as? String == task["id"] as? String,capture["sha256"] as? String == ref["sha256"] as? String else { throw CoreError("REVIEW_TARGET_MISMATCH","Source evidence belongs to another target.") }
        // Captured bytes were validated before the writer for this command (CL-71). The same
        // content observation of every entry stands for them. A changed observation or an
        // already failed validation fails at once, without hashing inside the writer (finding
        // b906f027); a permission-only change keeps the observation. Only a capture that this
        // command did not prepare is validated here.
        let preparation = commandPreparation
        if let id = capture["id"] as? String, let observed = preparation.validatedCaptures[id] {
            guard (try? captureObservation(capture)) == observed else { throw CoreError("EVIDENCE_STALE","Captured source changed after it was checked. Read the current target and retry.") }
        } else if let id = capture["id"] as? String, preparation.failedCaptures.contains(id) {
            throw CoreError("EVIDENCE_STALE","Captured source bytes changed or disappeared.")
        } else { try validateCapturedFiles(capture) }
        guard let source = capture["source_root"] as? String else { throw CoreError("EVIDENCE_STALE","The source root is unavailable.") }
        let live = try sourceInventory(source,additional:strings(capture,"additional_paths"))
        if let relevance = capture["relevance"] as? JSON,relevance["mode"] as? String == "scoped" {
            let before = try relevantSourceEntries(capture,relevance:relevance),after = try relevantSourceEntries(live,relevance:relevance)
            let changed = try Set(before.keys).union(after.keys).filter {try jsonString(before[$0] ?? [:]) != jsonString(after[$0] ?? [:])}.sorted()
            let files = (live["files"] as? [JSON] ?? []) + (capture["files"] as? [JSON] ?? [])
            let paths = changed.prefix(5).map { key in files.compactMap {$0["path"] as? String}.first {$0.lowercased() == key} ?? key }
            guard changed.isEmpty else { throw CoreError("EVIDENCE_STALE","Relevant source changed: \(paths.joined(separator:", ")). Capture and review the new target.",details:["changed_paths":paths]) }
        } else {
            // Legacy and unscoped captures retain the complete inventory, HEAD and index check.
            guard live["sha256"] as? String == capture["sha256"] as? String else { throw CoreError("EVIDENCE_STALE","Relevant source, index or base changed. Capture and review the new target.") }
        }
        return capture
    }
    func sourceReviewExecute(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try worker(c);let pid = try scope(db,p,c,write:true);_ = try claimAttempt(db,p,c,pid)
        throw CoreError("UNSUPPORTED_CAPABILITY","Service-run submitted code is disabled because no execution sandbox is qualified. Use a fresh independent reviewer session, choose the project's meaningful checks there, and attach your own hashed review evidence. No test or validate-plan receipt is required.")
    }
    func sourceExecutionGet(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        let pid = try scope(db,p,c);var execution = try scoped(db,try text(p,"execution_id"),pid,type:"source_execution")
        if !c.isOwner { execution.removeValue(forKey:"output_path");execution.removeValue(forKey:"working_directory") };return execution
    }

}

extension CommandRouter {
    func interruptSourceExecutionsAfterRestart(_ db: Database) throws {
        for var run in try records(db,type:"source_execution") where ["queued","running"].contains(run["state"] as? String ?? "") {
            run["state"] = "interrupted";run["finished_at"] = now();run["error"] = ["code":"SERVICE_RESTARTED","message":"The service restarted. This job has no completion receipt; start a deliberate new check. External process stop is unverified."]
            try save(db,revised(run),type:"source_execution")
        }
    }
}

extension CommandRouter {
    func unresolvedSourceExecutions(_ db: Database, attemptID: String? = nil, taskID: String? = nil) throws -> [JSON] {
        try records(db,type:"source_execution").filter { (["queued","running","interrupted"].contains($0["state"] as? String ?? "") || bool($0,"process_stop_unverified")) && (attemptID == nil || $0["attempt_id"] as? String == attemptID) && (taskID == nil || $0["task_id"] as? String == taskID) }
    }
    func requireNoSourceExecutions(_ db: Database, attempt: JSON) throws {
        guard try unresolvedSourceExecutions(db,attemptID:attempt["id"] as? String).isEmpty else { throw CoreError("SOURCE_EXECUTION_ACTIVE","A queued, running or interrupted source process retains its attempt reservations. Await actual completion, or record explicit owner stop verification before recovery.") }
    }
    func recoverSourceExecutions(_ db: Database, attempt: JSON, params: JSON, caller: Caller) throws {
        try owner(caller)
        let runs = try unresolvedSourceExecutions(db,attemptID:attempt["id"] as? String)
        guard !runs.isEmpty else {return}
        guard Set(strings(params,"source_execution_ids")) == Set(runs.compactMap {$0["id"] as? String}) else { throw CoreError("RECOVERY_REQUIRED","Explicitly name every source execution whose external process stop was verified.",details:["source_execution_ids":runs.compactMap {$0["id"] as? String}]) }
        let expected = params["expected_source_execution_revisions"] as? JSON ?? [:]
        guard Set(expected.keys) == Set(runs.compactMap {$0["id"] as? String}),runs.allSatisfy({int(expected,$0["id"] as! String,default:-1) == int($0,"revision")}) else { throw CoreError("REVISION_CONFLICT","Source process state changed after the stop observation. Inspect the current launch/stop receipt before recovery.",details:["source_execution_revisions":Dictionary(uniqueKeysWithValues:runs.map {($0["id"] as! String,int($0,"revision"))})]) }
        for var run in runs { run["state"] = "stopped";run["process_stop_unverified"] = false;run["stop_verified_by"] = caller.principal;run["stop_observation_refs"] = params["observation_refs"];run["file_state_refs"] = params["file_state_refs"];run["stop_reason"] = params["reason"];run["finished_at"] = now();try save(db,revised(run),type:"source_execution") }
    }
}

struct PreparedSourceCapture {
    let pending: PendingSourceCapture
    let projectID: String
    let sourceRoot: String
    let additional: [String]
    let inventory: JSON
}

/// Files and inventories that one command prepared before the object gate and the SQL
/// writer (CL-71). It grants nothing: the transaction re-checks every authority.
struct CommandPreparation {
    var captures: [String: PreparedSourceCapture] = [:]
    var inventories: [String: JSON] = [:]
    /// Managed objects whose bytes were hashed before the writer, by stored descriptor.
    var verifiedObjects: [String: VerifiedObject] = [:]
    /// Source captures whose captured bytes and membership were validated before the writer,
    /// with the content observation of every captured entry at that time (finding bcbee370).
    var validatedCaptures: [String: [String: String]] = [:]
    /// Prepared captures and objects whose validation already failed; the writer fails at once.
    var failedCaptures: Set<String> = []
    var failedObjects: Set<String> = []
    /// Live inventories whose prefetch failed, with the error that the writer reports.
    var failedInventories: [String: CoreError] = [:]
    var referenceImport: PreparedReferenceImport?
    var humanRequestFiles: PreparedHumanRequestFiles?
    var pending: [PendingSourceCapture] { captures.values.map(\.pending) }
}

extension CommandRouter {
    static let sourceCaptureMethods: Set<String> = ["work_submit", "batch_submit"]
    /// Writes that check a submitted source target against the live tree.
    static let sourceTargetMethods: Set<String> = ["work_claim", "review_request", "review_record", "batch_review_record", "batch_claim", "batch_prepare", "task_complete", "batch_complete_passing", "review_evidence_add", "human_request_answer", "triage_transition", "review_draft_save", "review_draft_submit", "release_set_complete"]

    /// Methods that the service may run off its serial queue: their large file work runs
    /// before the writer, and pure reads use the read-only connections (CL-71, CL-72).
    public static func runsOutsideSerialQueue(_ method: String) -> Bool {
        sourceCaptureMethods.contains(method) || sourceTargetMethods.contains(method) || method == "attachment_add" || pureReadMethods.contains(method)
    }

    func inventoryKey(_ path: String, _ additional: [String]) -> String {
        reservationKey(path) + "\u{0}" + additional.sorted().joined(separator: "\u{0}")
    }

    /// Large file and git work for one command, before the object gate and the SQL writer.
    /// One short read plans the work; a refused or replayed command prepares nothing.
    /// The transaction re-checks every authority; a prepared result only replaces re-reading.
    func prepareCommandFiles(method: String, params p: JSON, caller c: Caller) throws -> CommandPreparation {
        var preparation = CommandPreparation()
        if method == "attachment_add" { preparation.referenceImport = try prepareReferenceImport(method: method, params: p, caller: c); return preparation }
        guard Self.sourceCaptureMethods.contains(method) || Self.sourceTargetMethods.contains(method), p["project_id"] is String else { return preparation }
        struct Plan { var pid = ""; var captures: [(attempt: String, request: JSON, root: String)] = []; var inventories: [(root: String, additional: [String])] = []; var objects: [(path: String, sha256: String)] = []; var validations: [JSON] = [] }
        let plan: Plan? = try readForPreparation { db -> Plan? in
            let pid = try self.scope(db, p, c, write: true)
            if let command = p["command_id"] as? String, try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM commands WHERE principal=? AND command_id=?)", arguments: [c.principal, command]) == true { return nil }
            var plan = Plan(); plan.pid = pid
            var artifactIDs = Self.referencedValues(p, key: "artifact_id").union(Self.referencedValues(p,key:"attachment_id")), captureIDs = Self.referencedValues(p, key: "source_capture_id")
            if Self.sourceCaptureMethods.contains(method) {
                let root = try self.record(db, pid, type: "project")["root_path"] as? String ?? ""
                // Validate every member before copying any source, including artifact-only
                // members of a mixed batch. The write transaction repeats this gate.
                for input in method == "batch_submit" ? (p["members"] as? [JSON] ?? []) : [p] {
                    var claim = input;claim["project_id"] = pid
                    guard let attempt = try? self.claimAttempt(db,claim,c,pid),let tid = attempt["task_id"] as? String,let task = try? self.scoped(db,tid,pid,type:"task"),int(input,"acceptance_revision") == int(task,"acceptance_revision",default:1),let evidence = input["evidence_manifest"] as? JSON else { continue }
                    _ = try self.normalizedAcceptanceEvidence(db,params:input,evidence:evidence,task:task,attempt:attempt,caller:c)
                }
                for input in method == "batch_submit" ? (p["members"] as? [JSON] ?? []) : [p] {
                    guard !root.isEmpty, let attempt = input["attempt_id"] as? String, let evidence = input["evidence_manifest"] as? JSON else { continue }
                    let kind = evidence["kind"] as? String ?? (evidence["source_capture"] != nil ? "source" : "artifact")
                    guard kind == "source", evidence["decision"] == nil, let request = evidence["source_capture"] as? JSON else { continue }
                    if let supplied = request["root_path"] as? String, self.reservationKey(supplied) != self.reservationKey(root) { continue }
                    var claim = input; claim["project_id"] = pid
                    // No large copy for a stale or foreign claim; the transaction reports it.
                    guard (try? self.claimAttempt(db, claim, c, pid)) != nil else { continue }
                    plan.captures.append((attempt, request, root))
                }
            } else {
                for taskID in try self.preparationTaskIDs(db, method: method, p, pid) {
                    guard let task = try? self.scoped(db, taskID, pid, type: "task"), let mid = task["current_manifest_id"] as? String,
                          let manifest = try? self.scoped(db, mid, pid, type: "manifest") else { continue }
                    let evidence = manifest["evidence"] as? JSON ?? [:]
                    artifactIDs.formUnion(((evidence["artifact_refs"] as? [JSON] ?? []) + self.acceptanceArtifactRefs(evidence)).compactMap { $0["artifact_id"] as? String })
                    if let ref = evidence["source_capture"] as? JSON, let cid = ref["id"] as? String { captureIDs.insert(cid) }
                }
                if method == "human_request_answer", let rid = p["request_id"] as? String, let request = try? self.scoped(db, rid, pid, type: "request"), let target = request["target_attachment_id"] as? String { artifactIDs.insert(target) }
            }
            for id in artifactIDs.sorted() {
                guard let attachment = try? self.scoped(db, id, pid, type: "attachment"), attachment["mode"] as? String == "managed", attachment["availability"] as? String == "available",
                      let path = attachment["path"] as? String, let sha = attachment["sha256"] as? String else { continue }
                plan.objects.append((path, sha))
            }
            for id in captureIDs.sorted() {
                guard let capture = try? self.scoped(db, id, pid, type: "source_capture") else { continue }
                plan.validations.append(capture)
                if let source = capture["source_root"] as? String { plan.inventories.append((source, strings(capture, "additional_paths"))) }
            }
            return plan
        }
        guard let plan else { return preparation }
        do {
            for item in plan.captures {
                let key = try Self.preparedCaptureKey(attempt: item.attempt, request: item.request)
                if preparation.captures[key] == nil { preparation.captures[key] = try copySourceCapture(projectID: plan.pid, sourceRoot: item.root, request: item.request) }
            }
        } catch {
            // Nothing can name these captures yet.
            if let files = try? StorageObjectFiles(root: root) {
                for pending in preparation.pending { _ = try? removeManagedTree(files, relative: pending.directory); _ = try? removeManagedFile(files, relative: pending.marker) }
            }
            throw error
        }
        // Every prepared item is recorded as checked or as failed; the transaction never repeats
        // the file or git work of a prefetch that failed (finding 4485fafb).
        for item in plan.inventories {
            let key = inventoryKey(item.root, item.additional)
            guard preparation.inventories[key] == nil, preparation.failedInventories[key] == nil else { continue }
            do { preparation.inventories[key] = try sourceInventory(item.root, additional: item.additional, useCache: false) }
            catch { preparation.failedInventories[key] = error as? CoreError ?? CoreError("SOURCE_CAPTURE_INCOMPLETE", "The live source inventory could not be read.") }
        }
        for object in plan.objects { prefetchVerifiedObject(object.path, sha256: object.sha256, into: &preparation) }
        for capture in plan.validations {
            // The observation must be the same before and after the byte validation.
            guard let id = capture["id"] as? String else { continue }
            guard let before = try? captureObservation(capture) else { preparation.failedCaptures.insert(id); continue }
            let valid = (try? validateCapturedFiles(capture)) != nil
            if valid, let after = try? captureObservation(capture), after == before { preparation.validatedCaptures[id] = after } else { preparation.failedCaptures.insert(id) }
        }
        return preparation
    }

    /// Ticket IDs that a source-target write names directly or through its attempt, request, batch or Triage.
    func preparationTaskIDs(_ db: Database, method: String, _ p: JSON, _ pid: String) throws -> [String] {
        if method == "work_claim", p["phase"] as? String != "review", p["review_request_id"] == nil { return [] }
        var ids: [String] = [], inputs: [JSON] = [p]
        inputs += (p["members"] as? [JSON] ?? []) + (p["tasks"] as? [JSON] ?? [])
        for input in inputs {
            if let id = input["task_id"] as? String { ids.append(id) }
            if let id = input["attempt_id"] as? String, let attempt = try? scoped(db, id, pid, type: "attempt"), let task = attempt["task_id"] as? String { ids.append(task) }
            if let id = input["review_request_id"] as? String, let request = try? scoped(db, id, pid, type: "review_request"), let task = request["task_id"] as? String { ids.append(task) }
        }
        if let id = p["batch_id"] as? String, let batch = try? scoped(db, id, pid, type: "batch") { ids += (batch["members"] as? [JSON] ?? []).compactMap { $0["task_id"] as? String } }
        if let id = p["triage_id"] as? String ?? p["group_id"] as? String, let group = try? scoped(db, id, pid, type: "group") { ids += triageMemberIDs(group) }
        if method == "release_set_complete", let name = p["release_set"] as? String {
            ids += try records(db, type: "task", project: pid).filter { ($0["release_hold"] as? JSON)?["release_set"] as? String == name }.compactMap { $0["id"] as? String }
        }
        if method == "batch_claim", let id = p["batch_id"] as? String, let batch = try? scoped(db, id, pid, type: "batch"), batch["phase"] as? String != "review" { return [] }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// A short read for preparation planning; it never holds the object gate.
    func readForPreparation<T>(_ body: (Database) throws -> T) throws -> T {
        if let readers { return try readers.read(body) }
        return try dbQueue.read(body)
    }
}
