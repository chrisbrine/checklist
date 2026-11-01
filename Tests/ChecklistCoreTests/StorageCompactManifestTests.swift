import ChecklistTestSupport
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
        try QualificationSuite.requireEnabled()
        let manifest = template(200_000,format:2),start = ProcessInfo.processInfo.systemUptime
        let bytes = try StorageSnapshot.encoded(manifest)
        XCTAssertLessThan(bytes.count,32 * 1_048_576,"Repeated capture descriptors must have bounded compact metadata.")
        let copy = try JSONDecoder().decode(StorageSnapshotManifest.self,from:bytes)
        XCTAssertEqual(copy.objects.map(\.descriptor),manifest.objects.map(\.descriptor))
        XCTAssertEqual(copy.objects.map(\.sha256),manifest.objects.map(\.sha256))
        XCTAssertEqual(copy.objects.map(\.size),manifest.objects.map(\.size))
        print("CL270 template objects=200000 manifest_bytes=\(bytes.count) encode_decode_seconds=\(ProcessInfo.processInfo.systemUptime-start)")
    }

    private func absences(_ count: Int) -> [StorageSnapshotAbsence] {
        (0..<count).map { n in
            let capture = String(format:"%08d-0000-0000-0000-000000000000",n / 600)
            return .init(authority:"source_capture:\(capture):\(capture):Sources/ChecklistApp/Views/RetainedSourceFile-\(String(format:"%04d",n % 600)).swift",reason:n % 2 == 0 ? "evidence_cleaned" : "deletion_object_absent")
        }
    }
    private func withAbsences(_ list: [StorageSnapshotAbsence], objects: Int = 0, format: Int) -> StorageSnapshotManifest {
        let b = template(objects,format:format)
        return .init(format:format,kind:b.kind,operationID:b.operationID,storeID:b.storeID,sourceRoot:b.sourceRoot,schema:3,databaseSHA256:b.databaseSHA256,databaseSize:1,objects:b.objects,unavailable:list,externalReferences:[],recordFamilies:nil,tableRows:nil,capturedAt:nil)
    }
    func testManifestLimitHoldsTheObjectLimitAndItsCleanedEntries() throws {
        // CL-387: the live store has 4.43 unavailable entries per object, with no bound. Scale a sample at six per object.
        let sample = 2_000,bytes = try StorageSnapshot.encoded(withAbsences(absences(sample * 6),objects:sample,format:3)).count
        XCTAssertLessThan(bytes * (StorageSnapshotBudget.objectLimit / sample),StorageSnapshotBudget.manifestByteLimit)
    }
    func testFormatThreeKeepsEveryUnavailableEntryAndReadsOlderFormats() throws {
        var list = absences(1_200)
        list.append(.init(authority:"attachment:é:original",reason:"original_cleaned"))
        list.append(.init(authority:"attachment:e\u{301}:original",reason:"original_cleaned"))
        let compact = try StorageSnapshot.encoded(withAbsences(list,format:3))
        let copy = try JSONDecoder().decode(StorageSnapshotManifest.self,from:compact)
        XCTAssertEqual(copy.format,3)
        XCTAssertEqual(copy.unavailable.map {Data($0.authority.utf8)},list.map {Data($0.authority.utf8)})
        XCTAssertEqual(copy.unavailable.map(\.reason),list.map(\.reason))
        for format in [1,2] {
            let older = try JSONDecoder().decode(StorageSnapshotManifest.self,from:StorageSnapshot.encoded(withAbsences(list,format:format)))
            XCTAssertEqual(older.unavailable.map {Data($0.authority.utf8)},list.map {Data($0.authority.utf8)})
        }
        XCTAssertLessThan(compact.count * 3,try StorageSnapshot.encoded(withAbsences(list,format:2)).count)
    }
    func testFormatThreeRefusesMalformedUnavailableRows() throws {
        let encoded = try StorageSnapshot.encoded(withAbsences(absences(3),format:3))
        let shape = try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
        for row in [[9,0,"x"],[0,-1,"x"],[0,9_999,"x"],[0,0]] as [[Any]] {
            var changed = shape,table = shape["unavailable"] as! [String:Any]
            table["entries"] = [row];changed["unavailable"] = table
            XCTAssertThrowsError(try JSONDecoder().decode(StorageSnapshotManifest.self,from:JSONSerialization.data(withJSONObject:changed)))
        }
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
