import XCTest
import Foundation
@testable import ChecklistCore

final class StorageBackupManifestHashTests: XCTestCase {
    func testStreamingManifestHashCrossesReadChunksAndRefusesReplacedName() throws {
        let f = try StorageFixture(),root = f.workspace.appendingPathComponent("snapshot-hash",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url = root.appendingPathComponent("manifest.json")
        let bytes = Data((0..<(3 * 65_536 + 19)).map {UInt8($0 % 251)})
        try bytes.write(to:url)
        let lease = try StorageBackupUseLease(root:root)
        XCTAssertEqual(try lease.manifestSHA256(),ChecklistCore.hash(bytes))
        // Crash reconciliation uses the same streaming reader on the owned
        // moved directory; its caller independently checks the exact root inode.
        XCTAssertEqual(try StorageBackupUseLease.manifestSHA256(lease.files),ChecklistCore.hash(bytes))
        try bytes.write(to:url,options:.atomic)
        XCTAssertThrowsError(try lease.manifestSHA256()) {error in
            guard let failure = error as? StorageSnapshotFailure,case .sourceChanged = failure else {return XCTFail("Expected current-name refusal: \(error)")}
        }
    }
}
