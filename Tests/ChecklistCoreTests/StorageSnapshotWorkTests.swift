import XCTest
import Foundation
import Darwin
import GRDB
@testable import ChecklistCore

final class StorageSnapshotWorkTests: XCTestCase {
    func testDirectoryReplacementInvalidatesCachedNoFollowWalk() throws {
        let f = try StorageFixture(open:false),directory = f.workspace.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try Data([1,2,3]).write(to:directory.appendingPathComponent("file"))
        let files = try StorageObjectFiles(root:f.workspace,walkDirectories:true)
        XCTAssertEqual(try files.size("parent/file"),3)
        try FileManager.default.moveItem(at:directory,to:f.workspace.appendingPathComponent("detached"))
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        XCTAssertThrowsError(try files.finishWalk())
    }

    func testDigestReuseRehashesSameInodeAfterContentChangeWithRestoredMtime() throws {
        let f = try StorageFixture(open:false),file = f.workspace.appendingPathComponent("file")
        try Data([1,2,3]).write(to:file)
        let files = try StorageObjectFiles(root:f.workspace,walkDirectories:true,reuseDigests:true)
        let before = try files.digest("file",budget:.production())
        var info = stat();XCTAssertEqual(lstat(file.path,&info),0)
        let fd = Darwin.open(file.path,O_WRONLY | O_NOFOLLOW);XCTAssertGreaterThanOrEqual(fd,0);defer { Darwin.close(fd) }
        var byte: UInt8 = 9;XCTAssertEqual(pwrite(fd,&byte,1,0),1)
        var times = [info.st_atimespec,info.st_mtimespec];XCTAssertEqual(futimens(fd,&times),0)
        let after = try files.digest("file",budget:.production())
        XCTAssertNotEqual(before.0,after.0);XCTAssertEqual(before.1,after.1)
    }

    func testParallelVerificationChecksEveryPathAndRejectsSameSizedDamage() throws {
        let f = try StorageFixture(open:false),files = try StorageObjectFiles(root:f.workspace)
        var objects: [StorageSnapshotMaterializedObject] = []
        for index in 0..<48 {
            let bytes = Data(repeating:UInt8(index),count:64),path = "file-\(index)",sha = StorageObjectFiles.sha(bytes)
            try bytes.write(to:f.workspace.appendingPathComponent(path))
            let descriptor = StorageSnapshotObject(relativePath:path,kind:"file",expectedSHA256:sha,expectedSize:64,executable:false,linkTarget:nil,authorities:["fixture"])
            objects.append(.init(descriptor:descriptor,sha256:sha,size:64))
        }
        XCTAssertEqual(try StorageSnapshotWork.verifyObjects(objects,files:files,prefix:"",budget:.production()),48*64)
        try Data(repeating:255,count:64).write(to:f.workspace.appendingPathComponent("file-47"))
        XCTAssertThrowsError(try StorageSnapshotWork.verifyObjects(objects,files:files,prefix:"",budget:.production()))
    }

    func testCloneAndUnsupportedCloneFallbackKeepIndependentDestinationChecks() throws {
        let f = try StorageFixture(open:false),bytes = Data(repeating:13,count:65_537)
        try bytes.write(to:f.workspace.appendingPathComponent("source"))
        try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:f.workspace.appendingPathComponent("source").path)
        let source = try StorageObjectFiles(root:f.workspace,reuseDigests:true),destination = try StorageObjectFiles(root:f.workspace)
        let expected = StorageObjectFiles.sha(bytes)
        let cloned = try source.copy("source",to:destination,expected:expected,budget:.production(),targetPath:"clone")
        XCTAssertEqual(cloned.0,expected);XCTAssertEqual(cloned.1,Int64(bytes.count))
        var fallback = StorageSnapshotBudget.production();fallback.cloneFile = {_,_,_ in errno = ENOTSUP;return -1}
        XCTAssertEqual(try source.copy("source",to:destination,expected:expected,budget:fallback,targetPath:"fallback").0,expected)
        try Data(repeating:14,count:bytes.count).write(to:f.workspace.appendingPathComponent("clone"))
        XCTAssertEqual(try source.digest("source",budget:.production()).0,expected)
        XCTAssertNotEqual(try destination.digest("clone",budget:.production()).0,expected)
        XCTAssertThrowsError(try source.copy("source",to:destination,expected:String(repeating:"0",count:64),budget:.production(),targetPath:"bad-expected"))
    }

    func testSerialMaterializationAndFourWorkerVerificationFitReal256DescriptorBudgetWith98Open() throws {
        var limits = rlimit();XCTAssertEqual(getrlimit(RLIMIT_NOFILE,&limits),0)
        guard limits.rlim_cur == 256 else { throw XCTSkip("Run under the actual ulimit -n 256.") }
        let f = try StorageFixture(open:false),destinationURL = f.workspace.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at:destinationURL,withIntermediateDirectories:true)
        let source = try StorageObjectFiles(root:f.workspace),destination = try StorageObjectFiles(root:destinationURL,batchSynchronization:true)
        var objects: [StorageSnapshotObject] = []
        for index in 0..<512 {
            let bytes = Data(repeating:UInt8(index % 256),count:128),sha = StorageObjectFiles.sha(bytes)
            let path = "a/b/c/d/e/f/g/file-\(index)"
            try FileManager.default.createDirectory(at:f.workspace.appendingPathComponent("a/b/c/d/e/f/g"),withIntermediateDirectories:true)
            try bytes.write(to:f.workspace.appendingPathComponent(path))
            objects.append(.init(relativePath:path,kind:"file",expectedSHA256:sha,expectedSize:128,executable:false,linkTarget:nil,authorities:["fixture"]))
        }
        func count() -> Int { (0..<256).reduce(0) { $0 + (fcntl(Int32($1),F_GETFD) >= 0 ? 1 : 0) } }
        var padding: [Int32] = [];defer { for fd in padding { Darwin.close(fd) } }
        while count() < 98 { let fd = Darwin.open("/dev/null",O_RDONLY | O_CLOEXEC);XCTAssertGreaterThanOrEqual(fd,0);if fd < 0 { break };padding.append(fd) }
        var budget = StorageSnapshotBudget.production(),peak = count()
        budget.observe = { _ in peak = max(peak,count()) }
        let result = try StorageSnapshotWork.materialize(objects,source:source,destination:destination,budget:budget,logicalBytesBeforeCopy:0)
        XCTAssertEqual(result.count,512)
        XCTAssertEqual(try StorageSnapshotWork.verifyObjects(result,files:destination,prefix:"managed/",budget:budget),512*128)
        XCTAssertLessThan(peak,256);XCTAssertGreaterThanOrEqual(peak,98)
        XCTAssertEqual(count(),98,"Operation-local parent/digest handles must close after join")
        print("P356 descriptor baseline=98 observed_peak=\(peak) final=\(count())")
    }
    func testSingleDecodeInventoryStillRefusesUnavailableTraversalAndWrongFamily() throws {
        let f = try StorageFixture(open:false)
        for (type,pathKey,path,fields) in [
            ("attachment","path","../objects/file",["mode":"managed","availability":"original_cleaned"]),
            ("attachment","path","icons/wrong-family",["mode":"managed","availability":"original_missing"]),
            ("source_execution","working_directory","../source-captures/capture/source",["state":"completed"])
        ] {
            let queue = try DatabaseQueue();defer { try? queue.close() }
            try queue.write { db in
                try db.execute(sql:"CREATE TABLE records(id TEXT,project_id TEXT,type TEXT,revision INTEGER,data TEXT);CREATE TABLE metadata(key TEXT,value TEXT);PRAGMA user_version=3")
                var value: JSON = ["id":"record","project_id":"project","revision":1,pathKey:path]
                for (key,field) in fields { value[key] = field }
                try db.execute(sql:"INSERT INTO records VALUES ('record','project',?,1,?)",arguments:[type,try jsonString(value)])
            }
            try queue.read { db in
                XCTAssertThrowsError(try ManagedPathRelocation.plan(db,root:f.workspace,budget:.production()))
                XCTAssertThrowsError(try StorageSnapshotAuthority.inventory(db,root:f.workspace,budget:.production(),retainedExists:{_ in false}))
            }
        }
    }

    func testConcurrentGrowthDuringAPFSCloneLeavesOnlyBoundedPartialBytes() throws {
        let f = try StorageFixture(open:false),path = f.workspace.appendingPathComponent("growing")
        let bytes = Data(repeating:1,count:128);try bytes.write(to:path)
        let files = try StorageObjectFiles(root:f.workspace)
        var budget = StorageSnapshotBudget.production(),cloned = false
        budget.maximumObjectBytes = 1024
        budget.cloneFile = {source,parent,name in
            do {try Data(repeating:2,count:2048).write(to:path)} catch {errno = EIO;return -1}
            let result = fclonefileat(source,parent,name,0);cloned = result == 0;return result
        }
        XCTAssertThrowsError(try files.copy("growing",to:files,expected:StorageObjectFiles.sha(bytes),budget:budget,targetPath:"partial")) {
            XCTAssertEqual(($0 as? CoreError)?.details["reason"] as? String,"snapshot_object_bytes")
        }
        guard cloned else {throw XCTSkip("APFS cloning is unavailable on this fixture volume.")}
        XCTAssertEqual(try files.size("partial"),0)
        XCTAssertEqual(try files.size("growing"),2048,"Only the new owned clone may be truncated")
    }

    func testCloneTargetFIFOIsRejectedWithoutWaitingForAWriter() throws {
        let f = try StorageFixture(open:false),bytes = Data([1,2,3])
        try bytes.write(to:f.workspace.appendingPathComponent("source"))
        let files = try StorageObjectFiles(root:f.workspace)
        var budget = StorageSnapshotBudget.production()
        budget.cloneFile = {_,_,_ in mkfifo(f.workspace.appendingPathComponent("fifo").path,0o600)}
        XCTAssertThrowsError(try files.copy("source",to:files,expected:StorageObjectFiles.sha(bytes),budget:budget,targetPath:"fifo"))
    }

    func testReplacedHardLinkSourceDirectoryInvalidatesOwnedStage() throws {
        let f = try StorageFixture(open:false)
        let files = try StorageObjectFiles(root:f.workspace,batchSynchronization:true,walkDirectories:true)
        try files.writeNew("source/original",bytes:Data("same".utf8))
        XCTAssertTrue(try files.writeHardLink("target/linked",to:"source/original",link:StorageSnapshotBudget.production().linkFile))
        try FileManager.default.moveItem(at:f.workspace.appendingPathComponent("source"),to:f.workspace.appendingPathComponent("source-before"))
        try FileManager.default.createDirectory(at:f.workspace.appendingPathComponent("source"),withIntermediateDirectories:true)
        XCTAssertThrowsError(try files.finishWalk())
        XCTAssertEqual(try Data(contentsOf:f.workspace.appendingPathComponent("target/linked")),Data("same".utf8))
    }

    func testGrowingSourcesCannotExceedAggregatePartialStageByteLimit() throws {
        let f = try StorageFixture(open:false),outputURL = f.workspace.appendingPathComponent("output")
        try FileManager.default.createDirectory(at:outputURL,withIntermediateDirectories:true)
        let source = try StorageObjectFiles(root:f.workspace),output = try StorageObjectFiles(root:outputURL,batchSynchronization:true)
        var objects: [StorageSnapshotObject] = [],buckets = Set<Int>()
        for index in 0..<256 {
            let original = Data(repeating:UInt8(index),count:128),sha = StorageObjectFiles.sha(original)
            let bucket = Int(UInt32(sha.prefix(8),radix:16)! % 4)
            if !buckets.insert(bucket).inserted {continue}
            let path = "file-\(index)"
            // Four declared files fit preflight (512 B), then each grows before
            // its opened read handle. A four-worker local budget wrote 2000 B.
            try Data(repeating:UInt8(index),count:500).write(to:f.workspace.appendingPathComponent(path))
            objects.append(.init(relativePath:path,kind:"file",expectedSHA256:sha,expectedSize:128,executable:false,linkTarget:nil,authorities:["fixture"]))
            if buckets.count == 4 {break}
        }
        XCTAssertEqual(objects.count,4)
        var budget = StorageSnapshotBudget.production();budget.maximumBytes = 1000
        XCTAssertThrowsError(try StorageSnapshotWork.materialize(objects,source:source,destination:output,budget:budget,logicalBytesBeforeCopy:0))
        let paths = try output.listedFiles(budget:budget)
        let bytes = try paths.reduce(Int64(0)) {try $0 + output.size($1)}
        XCTAssertLessThanOrEqual(bytes,1000)
    }

}
