import Foundation
import Darwin
import GRDB

extension CommandRouter {
    /// The retired swift_test producer used this exact key. The directory name
    /// alone is never ownership: require its recorded execution and capture.
    func sourceBuildCachePath(_ db: Database,execution: JSON) throws -> String? {
        guard execution["tool"] as? String == "swift_test",
              !strings(execution,"args").contains(where: {$0.hasPrefix("--scratch-path") || $0.hasPrefix("--package-path")}),let pid = execution["project_id"] as? String,
              let cid = execution["source_capture_id"] as? String,let toolchain = execution["toolchain_sha256"] as? String,
              toolchain.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,
              let capture = try? scoped(db,cid,pid,type:"source_capture"),
              capture["task_id"] as? String == execution["task_id"] as? String,
              let source = capture["sha256"] as? String,source.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else {return nil}
        return "source-build-cache/" + hash(Data((source + toolchain).utf8))
    }

    func sourceBuildCacheOwners(_ db: Database) throws -> [String:[JSON]] {
        var owners: [String:[JSON]] = [:]
        for execution in try records(db,type:"source_execution") {
            if let path = try sourceBuildCachePath(db,execution:execution) {owners[path,default:[]].append(execution)}
        }
        return owners
    }

    /// Only enumerate names through a no-follow descriptor. Unknown/link entries
    /// stay; no recursive filesystem walk can establish a ticket owner.
    private func sourceBuildCacheChildren(_ files: StorageObjectFiles,path: String) throws -> [(String,mode_t)] {
        let parent: Int32,name: String
        do {(parent,name) = try files.parent(path)} catch {if errno == ENOENT {return []};throw error}
        defer {Darwin.close(parent)}
        let fd = openat(parent,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0,errno == ENOENT {return []}
        guard fd >= 0 else {throw CoreError("CACHE_INVENTORY_UNAVAILABLE","Cache inventory is unavailable; entries retained.")}
        guard let directory = fdopendir(fd) else {Darwin.close(fd);throw StorageSnapshotFailure.io}
        defer {closedir(directory)}
        var entries: [(String,mode_t)] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {guard errno == 0 else {throw StorageSnapshotFailure.io};break}
            let name = withUnsafePointer(to:&entry.pointee.d_name) {pointer in pointer.withMemoryRebound(to:CChar.self,capacity:Int(entry.pointee.d_namlen)+1) {String(validatingCString:$0)}}
            guard let name else {throw StorageSnapshotFailure.unsupportedAuthority}
            if name == "." || name == ".." {continue}
            guard entries.count < 100000 else {throw CoreError("PURGE_LIMIT","Cache inventory exceeds the safe cleanup limit.")}
            var info = stat()
            guard fstatat(fd,name,&info,AT_SYMLINK_NOFOLLOW) == 0 else {throw StorageSnapshotFailure.io}
            entries.append((path + "/" + name,info.st_mode & S_IFMT))
        }
        return entries.sorted {$0.0 < $1.0}
    }

    /// Pass-level accounting also reports caches with no recorded owner. Their
    /// lengths remain unknown, rather than counting an unscanned directory as 0.
    func sourceBuildCacheRetainedEntries(_ db: Database,project: String) throws -> [JSON] {
        let owners = try sourceBuildCacheOwners(db),files = try StorageObjectFiles(root:root)
        return try sourceBuildCacheChildren(files,path:"source-build-cache").compactMap {path,kind in
            let known = owners[path] ?? []
            if !known.isEmpty && !known.contains(where: {$0["project_id"] as? String == project}) {return nil}
            let tickets = Set(known.compactMap {$0["task_id"] as? String})
            let reason = tickets.isEmpty ? "unowned_source_build_cache" : tickets.count > 1 ? "shared_source_build_cache" : kind != S_IFDIR ? "unsupported_cache_entry" : nil
            guard let reason else {return nil}
            // Do not disclose another project's ticket/execution IDs.
            return ["relative_path":path,"state":"retained","reason":reason,"size":NSNull()]
        }
    }

    func sourceBuildCacheDeletionObjects(_ db: Database,owned: [(String,JSON)]) throws -> [JSON] {
        let executions = owned.filter {$0.0 == "source_execution"},owners = try sourceBuildCacheOwners(db)
        let files = try StorageObjectFiles(root:root),budget = StorageSnapshotBudget(deadlineUptime:ProcessInfo.processInfo.systemUptime + 60,canceled:{false})
        var result: [JSON] = [],visited = Set<String>()
        for (_,execution) in executions {
            guard let entry = try sourceBuildCachePath(db,execution:execution),visited.insert(entry).inserted else {continue}
            let all = owners[entry] ?? []
            let local = all.filter {$0["task_id"] as? String == execution["task_id"] as? String && $0["project_id"] as? String == execution["project_id"] as? String}
            let ids = Array(Set(local.flatMap {[$0["id"] as? String,$0["source_capture_id"] as? String].compactMap {$0}})).sorted()
            let exclusive = all.allSatisfy {$0["task_id"] as? String == execution["task_id"] as? String && $0["project_id"] as? String == execution["project_id"] as? String}
            if !exclusive {
                result.append(["stored_path":entry,"relative_path":entry,"name":URL(fileURLWithPath:entry).lastPathComponent,"owner_ids":ids,"representation":"source_build_cache","kind":"directory","state":"retained","reasons":["shared_source_build_cache"],"size":0,"size_unknown":true]);continue
            }
            let start = result.count
            guard db.configuration.readonly else {
                result.append(["stored_path":entry,"relative_path":entry,"owner_ids":ids,"representation":"source_build_cache","kind":"directory","state":"retained","reasons":["cache_requires_read_lane"],"size":0,"size_unknown":true]);continue
            }
            var directories = [entry],count = 0,unsupported = false
            while let directory = directories.popLast() {
                try budget.check()
                for (path,kind) in try sourceBuildCacheChildren(files,path:directory) {
                    count += 1
                    guard count <= 100000 else {throw CoreError("PURGE_LIMIT","Cache inventory exceeds the safe cleanup limit.")}
                    if kind == S_IFDIR {directories.append(path);continue}
                    var item: JSON = ["stored_path":path,"relative_path":path,"cache_path":entry,"name":URL(fileURLWithPath:path).lastPathComponent,"owner_ids":ids,"representation":"source_build_cache","kind":"file","state":"pending","size":0]
                    if kind == S_IFREG {
                        // Capture an exact descriptor on the utility read lane.
                        // The ordinary deletion continuation pins/hashes it again.
                        if try files.size(path) > budget.maximumObjectBytes {
                            item["state"] = "retained";item["reasons"] = ["cache_identity_limit"];item["size_unknown"] = true
                        } else if let observed = try TicketObjectRemovalVerification(root:root,relative:path,check:{try budget.check()}) {item["sha256"] = observed.sha256;item["size"] = observed.size}
                        else {item["state"] = "already_missing"}
                    } else if kind == S_IFLNK {
                        let target = try files.linkTarget(path)
                        item["kind"] = "symlink";item["link_target"] = target
                        item["sha256"] = hash(Data(target.utf8));item["size"] = target.utf8.count
                    } else {unsupported = true;item["state"] = "retained";item["reasons"] = ["unsupported_cache_entry"]}
                    result.append(item)
                }
            }
            if unsupported {
                for index in start..<result.count where result[index]["state"] as? String == "pending" {
                    result[index]["state"] = "retained";result[index]["reasons"] = ["cache_link_authority_unavailable"]
                }
            }
        }
        return result
    }

    func sourceBuildCacheDeletionHolds(_ db: Database,object: JSON) throws -> Set<String> {
        guard object["representation"] as? String == "source_build_cache",let path = object["cache_path"] as? String else {return []}
        let admitted = Set(strings(object,"owner_ids"))
        // New users of the same cache need not contain a literal cache pathname.
        // Recompute their producer key before each unlink as well as admission.
        for execution in try sourceBuildCacheOwners(db)[path] ?? [] {
            if !admitted.contains(execution["id"] as? String ?? "") {return ["shared_source_build_cache"]}
            if !["passed","failed","stale","completed","canceled","stopped"].contains(execution["state"] as? String ?? "") || bool(execution,"process_stop_unverified") {return ["source_execution_active_or_unknown"]}
        }
        return []
    }
}
