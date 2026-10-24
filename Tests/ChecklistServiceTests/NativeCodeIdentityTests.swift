import XCTest
import Foundation
import Security
import Darwin
@testable import ChecklistService

final class NativeCodeIdentityTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at:root) } }
    private func sign(_ file: URL, identifier: String) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/codesign")
        process.arguments = ["--force","--sign","-","--identifier",identifier,file.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0)
    }
    private func executable() throws -> URL {
        let file = root.appendingPathComponent("sleeper")
        try FileManager.default.copyItem(at:URL(fileURLWithPath:"/bin/sleep"),to:file)
        try sign(file,identifier:"org.checklist.identity-fixture")
        return file
    }
    func testChangedResignedReplacedAndRemovedExecutableInvalidateStaticIdentity() throws {
        let file = try executable(), cache = NativeCodeIdentity()
        let first = try XCTUnwrap(cache.executable(file))
        XCTAssertEqual(cache.executable(file),first)
        try sign(file,identifier:"org.checklist.resigned-fixture")
        let resigned = try XCTUnwrap(cache.executable(file))
        XCTAssertNotEqual(resigned,first); XCTAssertEqual(resigned.identifier,"org.checklist.resigned-fixture")
        let original = try Data(contentsOf:file)
        func word(_ offset:Int) -> UInt32 {
            original[offset..<offset+4].reduce(UInt32(0)) {($0 << 8) | UInt32($1)}
        }
        // Mutate a signed page in every universal slice, rather than fat padding.
        let offsets = word(0) == 0xcafebabe ? (0..<Int(word(4))).map {Int(word(8 + $0*20 + 8))} : [0]
        let handle = try FileHandle(forWritingTo:file)
        for offset in offsets {
            try handle.seek(toOffset:UInt64(offset + 4096))
            try handle.write(contentsOf:Data(repeating:0xa5,count:16))
        }
        try handle.close()
        XCTAssertNil(cache.executable(file),"A cached positive signature cannot survive changed binary bytes")
        try FileManager.default.removeItem(at:file)
        try FileManager.default.copyItem(at:URL(fileURLWithPath:"/bin/sleep"),to:file)
        try sign(file,identifier:"org.checklist.replaced-fixture")
        XCTAssertEqual(cache.executable(file)?.identifier,"org.checklist.replaced-fixture")
        try FileManager.default.removeItem(at:file); XCTAssertNil(cache.executable(file))
    }
    func testLiveProcessValidityAndExitAreRechecked() throws {
        let file = try executable(), process = Process(), cache = NativeCodeIdentity()
        process.executableURL = file; process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning {process.terminate();process.waitUntilExit()} }
        let first = try XCTUnwrap(cache.signingInfo(process.processIdentifier))
        XCTAssertEqual(first[kSecCodeInfoIdentifier as String] as? String,"org.checklist.identity-fixture")
        XCTAssertNotNil(cache.signingInfo(process.processIdentifier))
        process.terminate(); process.waitUntilExit()
        XCTAssertNil(cache.signingInfo(process.processIdentifier),"PID liveness/generation is checked on each use")
        XCTAssertNil(cache.signingInfo(-1))
    }
    func testResignedRunningImageCannotReusePreviousSigningInformation() throws {
        let file = try executable(), process = Process(), cache = NativeCodeIdentity()
        process.executableURL = file; process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning {process.terminate();process.waitUntilExit()} }
        _ = try XCTUnwrap(cache.signingInfo(process.processIdentifier))
        try sign(file,identifier:"org.checklist.changed-running-fixture")
        let actual = cache.signingInfo(process.processIdentifier)
        // Security may refuse the running image after a signature replacement;
        // either way it must never return the stale cached signing dictionary.
        XCTAssertNotEqual(actual?[kSecCodeInfoIdentifier as String] as? String,"org.checklist.identity-fixture")
    }
}
