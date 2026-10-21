import Foundation
import GRDB
import Darwin

extension CommandRouter {
    func sourceGit(_ path: String,_ args: [String]) throws -> Data {
        let process = Process(),out = Pipe(),err = Pipe();process.executableURL = URL(fileURLWithPath:"/usr/bin/git");process.arguments = ["-C",path] + args;process.standardOutput = out;process.standardError = err
        try process.run();let bytes = out.fileHandleForReading.readDataToEndOfFile();let error = err.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CoreError("SOURCE_CAPTURE_INCOMPLETE","Git could not inventory the complete enrolled source tree.",details:["reason":String(data:error,encoding:.utf8) ?? "git failed"]) };return bytes
    }
    func sourceInventory(_ path: String, additional: [String] = []) throws -> JSON {
        let git = FileManager.default.fileExists(atPath:URL(fileURLWithPath:path).appendingPathComponent(".git").path)
        var paths: [String] = [],base = "unversioned",index = ""
        if git {
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
        return ["base_revision":base,"index_sha256":index,"files":files,"sha256":hash(Data((try jsonString(identity)).utf8)),"size":total]
    }
    func captureSource(_ db: Database, request: JSON, task: JSON, attempt: JSON) throws -> JSON {
        let pid = task["project_id"] as! String,project = try record(db,pid,type:"project"),path = project["root_path"] as? String ?? ""
        guard !path.isEmpty else { throw CoreError("ROOT_MISMATCH","Source review needs an enrolled writable project root.") }
        if let supplied = request["root_path"] as? String,reservationKey(supplied) != reservationKey(path) { throw CoreError("ROOT_MISMATCH","Source capture always inventories the complete enrolled root.") }
        let additional = strings(request,"additional_paths"),before = try sourceInventory(path,additional:additional)
        if let expected = request["expected_sha256"] as? String,expected != before["sha256"] as? String { throw CoreError("SOURCE_CHANGED","Source changed before capture.") }
        let id = uuid(),directory = root.appendingPathComponent("source-captures").appendingPathComponent(pid).appendingPathComponent(id),snapshot = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:snapshot,withIntermediateDirectories:true)
        var success = false;defer { if !success { try? FileManager.default.removeItem(at:directory) } }
        for file in before["files"] as? [JSON] ?? [] {
            let relative = file["path"] as! String,destination = snapshot.appendingPathComponent(relative)
            if file["kind"] as? String == "deleted" { continue }
            try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
            if file["kind"] as? String == "symlink" { try FileManager.default.createSymbolicLink(atPath:destination.path,withDestinationPath:file["target"] as! String) }
            else { let bytes = try Data(contentsOf:URL(fileURLWithPath:path).appendingPathComponent(relative),options:.mappedIfSafe);guard hash(bytes) == file["sha256"] as? String else { throw CoreError("SOURCE_CHANGED","Source changed while capturing.") };try bytes.write(to:destination,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:bool(file,"executable") ? 0o555 : 0o444],ofItemAtPath:destination.path) }
        }
        let after = try sourceInventory(path,additional:additional)
        guard before["sha256"] as? String == after["sha256"] as? String else { throw CoreError("SOURCE_CHANGED","Source/index/base changed during capture. No submission was created.") }
        var capture = before;capture["id"] = id;capture["project_id"] = pid;capture["task_id"] = task["id"];capture["attempt_id"] = attempt["id"];capture["source_root"] = path;capture["snapshot_path"] = snapshot.path;capture["additional_paths"] = additional;capture["captured_at"] = now();capture["revision"] = 1
        try validateCapturedFiles(capture);try Data((try jsonString(capture)).utf8).write(to:directory.appendingPathComponent("manifest.json"),options:.atomic);try save(db,capture,type:"source_capture");success = true;return capture
    }
    func validateCapturedFiles(_ capture: JSON) throws {
        guard let path = capture["snapshot_path"] as? String,containsPath(reservationKey(root.appendingPathComponent("source-captures").path),reservationKey(path)) else { throw CoreError("EVIDENCE_STALE","The managed source capture is unavailable.") }
        let expectedPaths = Set((capture["files"] as? [JSON] ?? []).filter {$0["kind"] as? String != "deleted"}.compactMap {$0["path"] as? String})
        guard let enumerator = FileManager.default.enumerator(atPath:path) else { throw CoreError("EVIDENCE_STALE","Captured source is unreadable.") }
        var actualPaths = Set<String>()
        for case let relative as String in enumerator {
            let url = URL(fileURLWithPath:path).appendingPathComponent(relative),attrs = try FileManager.default.attributesOfItem(atPath:url.path)
            if attrs[.type] as? FileAttributeType != .typeDirectory { actualPaths.insert(relative) }
            if attrs[.type] as? FileAttributeType == .typeSymbolicLink { enumerator.skipDescendants() }
        }
        guard actualPaths == expectedPaths else { throw CoreError("EVIDENCE_STALE","Captured source membership changed.") }
        for file in capture["files"] as? [JSON] ?? [] {
            let url = URL(fileURLWithPath:path).appendingPathComponent(file["path"] as! String),kind = file["kind"] as? String
            if kind == "deleted" { guard !FileManager.default.fileExists(atPath:url.path) else { throw CoreError("EVIDENCE_STALE","A captured deletion changed.") };continue }
            if kind == "symlink" { guard (try? FileManager.default.destinationOfSymbolicLink(atPath:url.path)) == file["target"] as? String,containsPath(reservationKey(path),reservationKey(url.path)) else { throw CoreError("EVIDENCE_STALE","A captured symlink changed.") } }
            else { let attributes = try? FileManager.default.attributesOfItem(atPath:url.path),executable = ((attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0
                guard executable == bool(file,"executable"),let bytes = try? Data(contentsOf:url,options:.mappedIfSafe),hash(bytes) == file["sha256"] as? String else { throw CoreError("EVIDENCE_STALE","Captured source bytes changed or disappeared.") } }
        }
    }
    func validateSourceTarget(_ db: Database, evidence: JSON, task: JSON) throws -> JSON? {
        guard let ref = evidence["source_capture"] as? JSON else { return nil }
        let capture = try scoped(db,try text(ref,"id"),task["project_id"] as! String,type:"source_capture")
        guard capture["task_id"] as? String == task["id"] as? String,capture["sha256"] as? String == ref["sha256"] as? String else { throw CoreError("REVIEW_TARGET_MISMATCH","Source evidence belongs to another target.") }
        try validateCapturedFiles(capture)
        // An immutable target survives cosmetic metadata; relevant live source edits require a new submission.
        guard let source = capture["source_root"] as? String,try sourceInventory(source,additional:strings(capture,"additional_paths"))["sha256"] as? String == capture["sha256"] as? String else { throw CoreError("EVIDENCE_STALE","Relevant source, index or base changed. Capture and review the new target.") }
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
