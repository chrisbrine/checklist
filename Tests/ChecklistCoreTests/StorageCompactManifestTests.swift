import XCTest
import Foundation
@testable import ChecklistCore

final class StorageCompactManifestTests: XCTestCase {
    private func template(_ count: Int, format: Int) -> StorageSnapshotManifest {
        let sha = String(repeating:"a",count:64)
        let objects = (0..<count).map { n -> StorageSnapshotMaterializedObject in
            let capture = String(format:"%08d-0000-0000-0000-000000000000",n / 600)
            let name = "Sources/ChecklistCore/RetainedSourceFile-\(n % 600).swift"
            let descriptor = StorageSnapshotObject(relativePath:"source-captures/project-" + String(repeating:"b",count:64) + "/\(capture)/source/" + name,kind:"file",expectedSHA256:sha,expectedSize:24_000,executable:false,linkTarget:nil,authorities:["source_capture:\(capture):\(capture):" + name,"manifest:retained:\(capture):" + name])
            return .init(descriptor:descriptor,sha256:sha,size:24_000)
        }
        return .init(format:format,kind:StorageSnapshot.kind,operationID:UUID().uuidString.lowercased(),storeID:UUID().uuidString.lowercased(),sourceRoot:"/owned/template",schema:3,databaseSHA256:sha,databaseSize:1,objects:objects,unavailable:[],externalReferences:[])
    }

    func testTwoHundredThousandObjectTemplateFitsManifestBudgetWithoutLosingDescriptors() throws {
        let manifest = template(200_000,format:2),start = ProcessInfo.processInfo.systemUptime
        let bytes = try StorageSnapshot.encoded(manifest)
        XCTAssertLessThan(bytes.count,32 * 1_048_576,"Repeated capture descriptors must have bounded compact metadata.")
        let copy = try JSONDecoder().decode(StorageSnapshotManifest.self,from:bytes)
        XCTAssertEqual(copy.objects.map(\.descriptor),manifest.objects.map(\.descriptor))
        XCTAssertEqual(copy.objects.map(\.sha256),manifest.objects.map(\.sha256))
        XCTAssertEqual(copy.objects.map(\.size),manifest.objects.map(\.size))
        print("CL270 template objects=200000 manifest_bytes=\(bytes.count) encode_decode_seconds=\(ProcessInfo.processInfo.systemUptime-start)")
    }

    func testCompactUnicodeNilExpectationsAndMalformedIndices() throws {
        let d = StorageSnapshotObject(relativePath:"objects/é/文件",kind:"file",expectedSHA256:nil,expectedSize:nil,executable:true,linkTarget:nil,authorities:["attachment:é:preview","attachment:e\u{301}:preview"])
        let base = template(0,format:2)
        let manifest = StorageSnapshotManifest(format:2,kind:base.kind,operationID:base.operationID,storeID:base.storeID,sourceRoot:base.sourceRoot,schema:3,databaseSHA256:base.databaseSHA256,databaseSize:1,objects:[.init(descriptor:d,sha256:String(repeating:"a",count:64),size:7)],unavailable:[],externalReferences:[])
        let encoded = try StorageSnapshot.encoded(manifest)
        let copy = try JSONDecoder().decode(StorageSnapshotManifest.self,from:encoded)
        XCTAssertEqual(copy.objects.first?.descriptor,d)
        XCTAssertEqual(copy.objects.first?.descriptor.authorities.map {Data($0.utf8)},d.authorities.map {Data($0.utf8)})
        let shape = try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
        for fault in ["index","prefix","unused","executable","negativeSize"] {
            var changed = shape,table = shape["objects"] as! [String:Any]
            switch fault {
            case "prefix": table["strings"] = [[-1,"bad"]]
            case "unused": var contents = table["contents"] as! [[Int64]];contents += contents;table["contents"] = contents
            default:
                var rows = table["entries"] as! [[Int64]]
                rows[0][fault == "index" ? 0 : fault == "executable" ? 4 : 3] = fault == "index" ? Int64.max : fault == "executable" ? 2 : -2
                table["entries"] = rows
            }
            changed["objects"] = table
            XCTAssertThrowsError(try JSONDecoder().decode(StorageSnapshotManifest.self,from:JSONSerialization.data(withJSONObject:changed)))
        }
    }

    func testLegacyManifestRemainsReadable() throws {
        let manifest = template(3,format:1),bytes = try StorageSnapshot.encoded(manifest)
        let shape = try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        XCTAssertTrue(shape["objects"] is [[String:Any]])
        let copy = try JSONDecoder().decode(StorageSnapshotManifest.self,from:bytes)
        XCTAssertEqual(copy.format,1);XCTAssertEqual(copy.objects.map(\.descriptor),manifest.objects.map(\.descriptor))
    }
}
