import XCTest
@testable import ChecklistIPC

final class ChecklistInstanceTests: XCTestCase {
    let home = URL(fileURLWithPath:"/Users/instance-fixture")
    func testSharedPathOverlapVectors() throws {
        struct Link: Decodable { let path: String; let target: String }
        struct Vector: Decodable {
            let id: String; let a: String; let b: String; let overlap: Bool
            let requires_firmlink: Bool?
        }
        struct Table: Decodable { let directories: [String]; let symlinks: [Link]; let vectors: [Vector] }
        let repository = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let table = try JSONDecoder().decode(Table.self,from:Data(contentsOf:repository.appendingPathComponent("Tests/Fixtures/path-overlap-vectors.json")))
        let files = FileManager.default, fixture = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at:fixture) }
        for path in table.directories { try files.createDirectory(at:fixture.appendingPathComponent(path),withIntermediateDirectories:true) }
        for link in table.symlinks { try files.createSymbolicLink(atPath:fixture.appendingPathComponent(link.path).path,withDestinationPath:link.target) }
        let missing = "checklist-overlap-" + UUID().uuidString
        func path(_ value: String) -> URL {
            let expanded = value.replacingOccurrences(of:"{missing}",with:missing)
            return expanded.hasPrefix("/") ? URL(fileURLWithPath:expanded) : fixture.appendingPathComponent(expanded)
        }
        for vector in table.vectors {
            if vector.requires_firmlink == true && !files.fileExists(atPath:"/System/Volumes/Data/Users") {
                print("SKIP \(vector.id): /System/Volumes/Data/Users firmlink alias is absent on this machine.")
                continue
            }
            XCTAssertEqual(try ChecklistInstance.rootsOverlap(path(vector.a),path(vector.b)),vector.overlap,vector.id)
            XCTAssertEqual(try ChecklistInstance.rootsOverlap(path(vector.b),path(vector.a)),vector.overlap,vector.id + " reverse")
        }
    }
    func testLiveAndSlotsRefuseFoldedEffectiveRootSpellings() throws {
        let files = FileManager.default, directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at:directory) }
        let fixture = directory.appendingPathComponent("Café")
        for n in 1...4 {
            let data = fixture.appendingPathComponent("Library/Application Support/Checklist Test Instances/slot-\(n)/data")
            try files.createDirectory(at:data,withIntermediateDirectories:true)
            for value in [data.path.lowercased(),data.path.decomposedStringWithCanonicalMapping,
                          data.appendingPathComponent("Fûture/Child").path.lowercased().decomposedStringWithCanonicalMapping] {
                let environment = ["CHECKLIST_DATA_ROOT":value]
                XCTAssertThrowsError(try ChecklistInstance(slotValue:n,home:fixture,environment:environment),value)
                XCTAssertThrowsError(try ChecklistInstance(home:fixture,environment:environment),value)
            }
        }
    }
    func testLiveValuesStayExact() throws {
        let live = try ChecklistInstance(home:home,environment:[:])
        XCTAssertNil(live.slot)
        XCTAssertEqual(live.bundleIdentifier,"org.checklist.app")
        XCTAssertEqual(live.displayName,"Checklist")
        XCTAssertEqual(live.bundleFileName,"Checklist.app")
        XCTAssertEqual(live.machServiceName,"org.checklist.coordination")
        XCTAssertEqual(live.agentPlistName,"org.checklist.coordination.plist")
        XCTAssertEqual(live.retiredAgentPlistName,"org.checklist.service.plist")
        XCTAssertEqual(live.keychainService,"org.checklist.local.enrollments")
        XCTAssertEqual(live.root.path,home.path + "/Library/Application Support/Checklist")
        XCTAssertEqual(live.ownerPathSuffix,"/Checklist.app/Contents/MacOS/ChecklistApp")
        XCTAssertEqual(live.ownerRequirement,"identifier \"org.checklist.app\"")
        XCTAssertEqual(try ChecklistInstance(home:home,environment:["CHECKLIST_DATA_ROOT":"/tmp/custom"]).root.path,"/tmp/custom")
    }
    func testFourSlotsAreIsolatedAndIgnoreEnvironment() throws {
        let live = try ChecklistInstance(home:home,environment:[:])
        for n in 1...4 {
            let test = try ChecklistInstance(slotValue:n,home:home,environment:["CHECKLIST_DATA_ROOT":live.root.path])
            XCTAssertEqual(test.slot,n)
            XCTAssertEqual(test.bundleIdentifier,"org.checklist.app.test\(n)")
            XCTAssertEqual(test.displayName,"Checklist Test \(n)")
            XCTAssertEqual(test.bundleFileName,"Checklist Test \(n).app")
            XCTAssertEqual(test.machServiceName,"org.checklist.test\(n).coordination")
            XCTAssertEqual(test.agentPlistName,"org.checklist.test\(n).coordination.plist")
            XCTAssertEqual(test.retiredAgentPlistName,"org.checklist.test\(n).service.plist")
            XCTAssertEqual(test.keychainService,"org.checklist.test\(n).enrollments")
            XCTAssertEqual(test.root.path,home.path + "/Library/Application Support/Checklist Test Instances/slot-\(n)/data")
            XCTAssertEqual(test.ownerPathSuffix,"/Checklist Test \(n).app/Contents/MacOS/ChecklistApp")
            XCTAssertEqual(test.ownerRequirement,"identifier \"org.checklist.app.test\(n)\"")
            XCTAssertNotEqual(test.bundleIdentifier,live.bundleIdentifier)
            XCTAssertNotEqual(test.machServiceName,live.machServiceName)
            XCTAssertNotEqual(test.keychainService,live.keychainService)
            XCTAssertNotEqual(test.root,live.root)
        }
    }
    func testSlotsRefuseEffectiveLiveRootOverlap() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:fixture) }
        let tree = fixture.appendingPathComponent("Library/Application Support/Checklist Test Instances")
        for n in 1...4 {
            let folder = tree.appendingPathComponent("slot-\(n)"), data = folder.appendingPathComponent("data")
            try FileManager.default.createDirectory(at:data,withIntermediateDirectories:true)
            for live in [data,folder,tree,data.appendingPathComponent("nested"),folder.appendingPathComponent("other"),
                         data.appendingPathComponent("../data")] {
                XCTAssertThrowsError(try ChecklistInstance(slotValue:n,home:fixture,environment:["CHECKLIST_DATA_ROOT":live.path]),live.path)
            }
        }
    }
    func testSlotsAllowComponentSiblingsAndEmptyOverride() throws {
        for value in ["",home.path + "/Library/Application Support/Checklist",
                      home.path + "/Library/Application Support/Checklist Test Instances2"] {
            for n in 1...4 {
                let instance = try ChecklistInstance(slotValue:n,home:home,environment:["CHECKLIST_DATA_ROOT":value])
                XCTAssertEqual(instance.root.path,home.path + "/Library/Application Support/Checklist Test Instances/slot-\(n)/data")
            }
        }
    }
    func testLiveRefusesReservedTestTreeOverlap() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:fixture) }
        let tree = fixture.appendingPathComponent("Library/Application Support/Checklist Test Instances")
        try FileManager.default.createDirectory(at:tree,withIntermediateDirectories:true)
        for live in [tree,tree.appendingPathComponent("slot-1/data"),tree.deletingLastPathComponent(),fixture,
                     tree.appendingPathComponent("slot-1/../slot-2/data")] {
            XCTAssertThrowsError(try ChecklistInstance(home:fixture,environment:["CHECKLIST_DATA_ROOT":live.path])) { error in
                XCTAssertTrue(error.localizedDescription.contains("reserved test"),error.localizedDescription)
            }
        }
    }
    func testLiveUnrelatedOverridesKeepFormerValues() throws {
        let defaultRoot = home.appendingPathComponent("Library/Application Support/Checklist")
        for value in ["",defaultRoot.path,"/tmp/custom",home.path + "/Library/Application Support/Checklist Test Instances2"] {
            let live = try ChecklistInstance(home:home,environment:["CHECKLIST_DATA_ROOT":value])
            XCTAssertEqual(live.root.path,value.isEmpty ? defaultRoot.path : value)
            XCTAssertEqual(live.ownerDataRoot,defaultRoot)
            XCTAssertEqual(live.cliCommand,"/Applications/Checklist.app/Contents/MacOS/checklist")
            XCTAssertEqual(live.bundleIdentifier,"org.checklist.app")
            XCTAssertEqual(live.machServiceName,"org.checklist.coordination")
            XCTAssertEqual(live.keychainService,"org.checklist.local.enrollments")
        }
    }
    func testCanonicalLiveAliasesRefuseSlotAndLiveOverlap() throws {
        let files = FileManager.default
        let fixture = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at:fixture) }
        let data = fixture.appendingPathComponent("Library/Application Support/Checklist Test Instances/slot-1/data")
        try files.createDirectory(at:data,withIntermediateDirectories:true)
        let alias = fixture.appendingPathComponent("alias")
        try files.createSymbolicLink(at:alias,withDestinationURL:data)
        let dangling = fixture.appendingPathComponent("dangling-alias")
        try files.createSymbolicLink(at: dangling,withDestinationURL:data.appendingPathComponent("unpublished"))
        let relative = fixture.appendingPathComponent("relative-alias")
        try files.createSymbolicLink(atPath:relative.path,withDestinationPath:"Library/Application Support/Checklist Test Instances/slot-1/data")
        for value in [alias.path,alias.appendingPathComponent("nested").path,alias.appendingPathComponent("../other").path,
                      dangling.path,relative.appendingPathComponent("nested").path] {
            XCTAssertThrowsError(try ChecklistInstance(slotValue:1,home:fixture,environment:["CHECKLIST_DATA_ROOT":value]))
            XCTAssertThrowsError(try ChecklistInstance(home:fixture,environment:["CHECKLIST_DATA_ROOT":value]))
        }
        let unrelated = fixture.appendingPathComponent("unrelated")
        try files.createDirectory(at:unrelated,withIntermediateDirectories:true)
        let allowedAlias = fixture.appendingPathComponent("allowed-alias")
        try files.createSymbolicLink(at:allowedAlias,withDestinationURL:unrelated)
        XCTAssertEqual(try ChecklistInstance(home:fixture,environment:["CHECKLIST_DATA_ROOT":allowedAlias.path]).root.path,allowedAlias.path)
        XCTAssertNoThrow(try ChecklistInstance(slotValue:1,home:fixture,environment:["CHECKLIST_DATA_ROOT":allowedAlias.path]))
    }
    func testInvalidSlotsRefuseStartup() {
        for value: Any in [0,5,-1,"1","live",true,1.5,1.0,NSNull(),Int64.max] {
            XCTAssertThrowsError(try ChecklistInstance(slotValue:value,home:home))
        }
    }
    func testBundleAndUnbundledResolution() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let bundle = directory.appendingPathComponent("Checklist Test 2.app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at:contents.appendingPathComponent("MacOS"),withIntermediateDirectories:true)
        let plist = contents.appendingPathComponent("Info.plist")
        try PropertyListSerialization.data(fromPropertyList:["ChecklistInstanceSlot":2],format:.xml,options:0).write(to:plist)
        for executable in ["ChecklistApp","ChecklistService","checklist"] {
            XCTAssertEqual(try ChecklistInstance.read(executable:contents.appendingPathComponent("MacOS/"+executable)).slot,2)
        }
        try PropertyListSerialization.data(fromPropertyList:[:],format:.xml,options:0).write(to:plist)
        XCTAssertNil(try ChecklistInstance.read(executable:contents.appendingPathComponent("MacOS/checklist")).slot)
        try PropertyListSerialization.data(fromPropertyList:["ChecklistInstanceSlot":"2"],format:.xml,options:0).write(to:plist)
        XCTAssertThrowsError(try ChecklistInstance.read(executable:contents.appendingPathComponent("MacOS/checklist")))
        XCTAssertNil(try ChecklistInstance.read(executable:directory.appendingPathComponent(".build/debug/checklist")).slot)
    }
    func testMissingMalformedUnreadableAndDanglingPlistsRefuse() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let contents = directory.appendingPathComponent("Checklist.app/Contents")
        try FileManager.default.createDirectory(at:contents.appendingPathComponent("MacOS"),withIntermediateDirectories:true)
        let executable = contents.appendingPathComponent("MacOS/checklist"),plist = contents.appendingPathComponent("Info.plist")
        XCTAssertThrowsError(try ChecklistInstance.read(executable:executable))
        try Data("malformed plist".utf8).write(to:plist)
        XCTAssertThrowsError(try ChecklistInstance.read(executable:executable))
        try PropertyListSerialization.data(fromPropertyList:[:],format:.xml,options:0).write(to:plist)
        try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:plist.path)
        XCTAssertThrowsError(try ChecklistInstance.read(executable:executable))
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:plist.path)
        try FileManager.default.removeItem(at:plist)
        try FileManager.default.createSymbolicLink(atPath:plist.path,withDestinationPath:"absent.plist")
        XCTAssertThrowsError(try ChecklistInstance.read(executable:executable),"An existing dangling link is not an absent Info.plist")
    }

    func testActualStartupRefusesMissingAppPlistButAllowsDevelopmentAndTestHosts() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? files.removeItem(at:directory) }
        let repository = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let main = directory.appendingPathComponent("main.swift"), helper = directory.appendingPathComponent("startup")
        try Data("import Foundation\nprint(ChecklistInstance.current.machServiceName)\n".utf8).write(to:main)
        func run(_ executable: URL,_ arguments: [String] = []) throws -> (Int32,String) {
            let process = Process(),pipe = Pipe()
            process.executableURL = executable; process.arguments = arguments
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let output = String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus,output)
        }
        // Compile the production current/exit handler and its error type, with no IPC calls.
        let compiled = try run(URL(fileURLWithPath:"/usr/bin/xcrun"),["swiftc","-swift-version","5",
            repository.appendingPathComponent("Sources/ChecklistIPC/Protocol.swift").path,
            repository.appendingPathComponent("Sources/ChecklistIPC/ChecklistInstance.swift").path,main.path,"-o",helper.path])
        XCTAssertEqual(compiled.0,0,compiled.1)
        guard compiled.0 == 0 else { return }
        for name in ["Checklist Test 4.app","Checklist.app","Other.app"] {
            let executable = directory.appendingPathComponent(name + "/Contents/MacOS/checklist")
            try files.createDirectory(at:executable.deletingLastPathComponent(),withIntermediateDirectories:true)
            try files.copyItem(at:helper,to:executable)
            let result = try run(executable)
            XCTAssertEqual(result.0,78,result.1)
            XCTAssertTrue(result.1.contains("Checklist:"),result.1)
            XCTAssertFalse(result.1.contains("org.checklist.coordination"),result.1)
        }
        for path in [".build/debug/checklist","Tests.xctest/Contents/MacOS/checklist"] {
            let executable = directory.appendingPathComponent(path)
            try files.createDirectory(at:executable.deletingLastPathComponent(),withIntermediateDirectories:true)
            try files.copyItem(at:helper,to:executable)
            let result = try run(executable)
            XCTAssertEqual(result.0,0,result.1)
            XCTAssertEqual(result.1,"org.checklist.coordination\n")
        }
    }
}
