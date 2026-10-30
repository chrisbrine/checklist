import Foundation
import Darwin

/// Only an operation-local handle uses this walk. At most eight ancestors stay
/// open; every cached name is checked against its pinned inode before release.
/// A moved/replaced ancestor invalidates the entire operation before publication.
final class StorageObjectWalk {
    private struct Directory { let name: String; let descriptor: Int32; let device: dev_t; let inode: ino_t }
    private let root: Int32
    private let rootPath: String?
    private var directories: [Directory] = []
    init(root: Int32, rootPath: String? = nil) { self.root = root; self.rootPath = rootPath }
    deinit { for directory in directories { Darwin.close(directory.descriptor) } }
    private func pop() throws {
        let directory = directories.removeLast()
        defer { Darwin.close(directory.descriptor) }
        var current = stat()
        guard fstatat(directories.last?.descriptor ?? root,directory.name,&current,AT_SYMLINK_NOFOLLOW) == 0,
              current.st_mode & S_IFMT == S_IFDIR,current.st_dev == directory.device,current.st_ino == directory.inode else { throw StorageSnapshotFailure.sourceChanged }
    }
    func parent(_ parts: [String], create: Bool) throws -> Int32? {
        guard parts.count <= 8 else { try finish(); return nil }
        var shared = 0
        while shared < min(parts.count,directories.count),parts[shared].utf8.elementsEqual(directories[shared].name.utf8) { shared += 1 }
        while directories.count > shared { try pop() }
        for (index,part) in parts.enumerated().dropFirst(shared) {
            let path = parts[...index].joined(separator:"/")
            let parent = directories.last?.descriptor ?? root
            if create,mkdirat(parent,part,0o700) != 0,errno != EEXIST { throw StorageSnapshotFailure.failed("mkdirat",path:path,root:rootPath) }
            let fd = openat(parent,part,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw CoreError("STORAGE_OBJECT_UNAVAILABLE","The managed object parent could not be opened safely.",details:["posix_errno":errno]) }
            var info = stat()
            guard fstat(fd,&info) == 0 else {
                let failure = StorageSnapshotFailure.failed("fstat",path:path,root:rootPath)
                Darwin.close(fd); throw failure
            }
            directories.append(.init(name:part,descriptor:fd,device:info.st_dev,inode:info.st_ino))
        }
        let result = fcntl(directories.last?.descriptor ?? root,F_DUPFD_CLOEXEC,0)
        guard result >= 0 else { throw StorageSnapshotFailure.failed("fcntl",path:parts.joined(separator:"/"),root:rootPath) }
        return result
    }
    func finish() throws { while !directories.isEmpty { try pop() } }
}

/// Digest reuse is confined to one verification/copy pass and binds every
/// pathname to an opened regular inode, exact size, mode, mtime and ctime.
/// A new generation or independent verification always starts an empty cache.
struct StorageFileDigestIdentity: Hashable {
    let device: dev_t, inode: ino_t, size: off_t
    let mode: mode_t
    let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; size = info.st_size; mode = info.st_mode
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
    }
}

/// At most four synchronous verification workers retain eight ancestors each.
/// Materialization stays serial so actual byte admission uses one running total.
/// Every worker joins before any manifest or publication.
/// No asynchronous task, callback, or open descriptor escapes the operation.
enum StorageSnapshotWork {
    private final class Jobs<T>: @unchecked Sendable {
        let body: (Range<Int>) throws -> T
        let count: Int
        let lock = NSLock()
        var results: [Int:T] = [:]
        var error: Error?
        init(count: Int,body: @escaping (Range<Int>) throws -> T) { self.count = count; self.body = body }
        func run(_ worker: Int,total: Int) {
            do {
                let value = try autoreleasepool { try body((count*worker/total)..<(count*(worker+1)/total)) }
                lock.lock();results[worker] = value;lock.unlock()
            } catch { lock.lock();if self.error == nil { self.error = error };lock.unlock() }
        }
    }
    static func map<T>(count: Int,budget: StorageSnapshotBudget,body: @escaping (Range<Int>) throws -> T) throws -> [T] {
        guard count > 0 else { return [] }
        let workers = min(count,max(1,min(4,budget.parallelism)))
        if workers == 1 { return [try body(0..<count)] }
        let jobs = Jobs(count:count,body:body)
        DispatchQueue.concurrentPerform(iterations:workers) { jobs.run($0,total:workers) }
        if let error = jobs.error { throw error }
        return (0..<workers).map { jobs.results[$0]! }
    }
}

extension StorageSnapshotWork {
    static func materialize(_ objects: [StorageSnapshotObject],source: StorageObjectFiles,destination: StorageObjectFiles,
                            budget: StorageSnapshotBudget,logicalBytesBeforeCopy: Int64) throws -> [StorageSnapshotMaterializedObject] {
        // Preserve serial actual-byte admission. Worker-local totals cannot
        // bound aggregate partial bytes if multiple sources grow after preflight.
        let workers = 1
        // The private deduplication table never points outside this owned stage.
        var buckets = [[StorageSnapshotObject]](repeating:[],count:workers)
        for (index,object) in objects.enumerated() where object.kind == "file" {
            let bucket = object.expectedSHA256.flatMap { UInt32($0.prefix(8),radix:16) }.map { Int($0 % UInt32(workers)) } ?? index % workers
            buckets[bucket].append(object)
        }
        let groups = try map(count:workers,budget:budget) { range -> [StorageSnapshotMaterializedObject] in
            let input = try StorageObjectFiles(copying:source,reuseDigests:true)
            let output = try StorageObjectFiles(copying:destination,batchSynchronization:true)
            var materialized: [StorageSnapshotMaterializedObject] = [],copiedContent: [String:(path:String,size:Int64)] = [:]
            var total = logicalBytesBeforeCopy
            for bucket in range {
                for descriptor in buckets[bucket] {
                    try autoreleasepool {
                        try budget.check()
                        let value: (String,Int64)
                        if let expected = descriptor.expectedSHA256,let prior = copiedContent[expected] {
                            value = try input.digest(descriptor.relativePath,budget:budget)
                            guard value == (expected,prior.size),value.1 <= budget.maximumObjectBytes else { throw StorageSnapshotFailure.sourceChanged }
                            _ = try budget.adding(value.1,to:total)
                            if try !output.writeHardLink("managed/" + descriptor.relativePath,to:prior.path,link:budget.linkFile) {
                                let copied = try input.copy(descriptor.relativePath,to:output,expected:expected,budget:budget,logicalBytesBeforeCopy:total)
                                guard copied == value else { throw StorageSnapshotFailure.sourceChanged }
                                copiedContent[expected] = ("managed/" + descriptor.relativePath,value.1)
                            }
                        } else {
                            value = try input.copy(descriptor.relativePath,to:output,expected:descriptor.expectedSHA256,budget:budget,logicalBytesBeforeCopy:total)
                            copiedContent[value.0] = ("managed/" + descriptor.relativePath,value.1)
                        }
                        guard descriptor.expectedSize == nil || descriptor.expectedSize == value.1 else { throw StorageSnapshotFailure.sourceChanged }
                        total = try budget.adding(value.1,to:total)
                        materialized.append(.init(descriptor:descriptor,sha256:value.0,size:value.1))
                        try budget.notify("object_copied")
                    }
                }
            }
            try input.finishWalk();try output.finishWalk()
            try output.synchronizeCopiedDirectories(budget:budget)
            try output.finishWalk()
            return materialized
        }
        return groups.flatMap { $0 }
    }

    static func verifyObjects(_ objects: [StorageSnapshotMaterializedObject],files: StorageObjectFiles,
                              prefix: String,budget: StorageSnapshotBudget) throws -> Int64 {
        let totals = try map(count:objects.count,budget:budget) { range -> Int64 in
            let reader = try StorageObjectFiles(copying:files,reuseDigests:true)
            var total: Int64 = 0
            for index in range {
                try autoreleasepool {
                    let object = objects[index],descriptor = object.descriptor,path = prefix + descriptor.relativePath
                    try budget.check()
                    if descriptor.kind == "file" {
                        let value = try reader.digest(path,budget:budget)
                        guard value == (object.sha256,object.size),value.1 <= budget.maximumObjectBytes,
                              descriptor.expectedSHA256 == nil || descriptor.expectedSHA256 == value.0,
                              descriptor.expectedSize == nil || descriptor.expectedSize == value.1 else { throw StorageSnapshotFailure.sourceChanged }
                        total = try budget.adding(value.1,to:total)
                    } else if descriptor.kind == "symlink" {
                        guard let target = descriptor.linkTarget,!target.hasPrefix("/"),!target.contains("\0"),
                              try reader.linkTarget(path) == target,StorageObjectFiles.sha(Data(target.utf8)) == object.sha256,
                              object.sha256 == descriptor.expectedSHA256,object.size == Int64(target.utf8.count) else { throw StorageSnapshotFailure.sourceChanged }
                        total = try budget.adding(Int64(target.utf8.count),to:total)
                    } else { throw StorageSnapshotFailure.unsupportedAuthority }
                    try budget.notify("object_verified")
                }
            }
            try reader.finishWalk()
            return total
        }
        return try totals.reduce(Int64(0)) { try budget.adding($1,to:$0) }
    }

    static func restoreObjects(_ objects: [StorageSnapshotMaterializedObject],source: StorageObjectFiles,
                               destination: StorageObjectFiles,budget: StorageSnapshotBudget,logicalBytesBeforeCopy: Int64) throws {
        var serial = budget;serial.parallelism = 1
        _ = try map(count:objects.count,budget:serial) { range -> Bool in
            let input = try StorageObjectFiles(copying:source,reuseDigests:true)
            let output = try StorageObjectFiles(copying:destination,batchSynchronization:true)
            var total = logicalBytesBeforeCopy
            for index in range {
                try autoreleasepool {
                    let object = objects[index],descriptor = object.descriptor
                    try budget.check()
                    if descriptor.kind == "file" {
                        let copied = try input.copy("managed/" + descriptor.relativePath,to:output,expected:object.sha256,budget:budget,targetPath:descriptor.relativePath,executable:descriptor.executable,logicalBytesBeforeCopy:total)
                        guard copied.1 == object.size else { throw StorageSnapshotFailure.sourceChanged }
                        total = try budget.adding(copied.1,to:total)
                    } else {
                        guard try input.linkTarget("managed/" + descriptor.relativePath) == descriptor.linkTarget,let target = descriptor.linkTarget else { throw StorageSnapshotFailure.sourceChanged }
                        total = try budget.adding(Int64(target.utf8.count),to:total)
                        try output.writeLink(descriptor.relativePath,target:target)
                    }
                }
            }
            try input.finishWalk();try output.finishWalk()
            try output.synchronizeCopiedDirectories(budget:budget)
            try output.finishWalk()
            return true
        }
    }
}
