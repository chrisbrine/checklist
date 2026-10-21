import XCTest
@testable import ChecklistApp

final class PlaytestBundleViewTests: XCTestCase {
    func ref(_ id: String) -> [String:Any] { ["artifact_id":id,"sha256":"hash-"+id] }
    func projection(unavailable: Bool = false) -> PlaytestBundleProjection {
        let bundle: [String:Any] = ["id":"bundle1","sha256":"bundle-hash","build":ref("build").merging(["build_id":"build1","version":"1.0","platform":"macOS"]) { _,new in new },"scenario":ref("scenario"),"state_files":[ref("state")],"screenshots":[ref("screen")],"log":ref("log")]
        let manifest = Record(values:["id":"m1","project_id":"p","task_id":"t","evidence":["playtest_bundle":bundle]])
        let files = ["build","scenario","state","screen","log"].map { id in ["id":id,"project_id":"p","task_id":"t","name":id,"mode":"managed","availability":unavailable && id == "screen" ? "original_cleaned" : "available","sha256":"hash-"+id] }
        let assessment: [String:Any] = ["contract":["acceptance":[["id":"acceptance:0","text":"Captured historical outcome"]]],"acceptance":[["requirement_id":"acceptance:0","result":"fail","rationale":"Observed a failure","evidence_refs":[ref("screen")]]]]
        let verdicts: [[String:Any]] = [["id":"v1","project_id":"p","task_id":"t","manifest_id":"m1","verdict":"reject","review_assessment":assessment],["id":"v2","project_id":"p","task_id":"t","manifest_id":"m2","verdict":"pass","review_assessment":["evidence_refs":[ref("log")]]]]
        let review = ReviewProjection(task:Record(values:["id":"t","project_id":"p","current_manifest_id":"m2"]),project:nil,data:["manifests":[manifest.values],"attachments":files,"reviews":verdicts])
        return PlaytestBundleProjection(manifest:manifest,review:review)
    }
    func testBundleGroupsExistingFilesAndShowsExactHashes() {
        let p = projection()
        XCTAssertEqual(p.files.map(\.role),["Scenario","Build","State 1","Screenshot 1","Log"])
        XCTAssertTrue(p.files.allSatisfy(\.available));XCTAssertEqual(p.bundle.id,"bundle1")
        XCTAssertEqual(p.files.first?.ref.string("sha256"),"hash-scenario")
    }
    func testCitationsAndAcceptanceStayWithTheirExactHistoricalVerdict() throws {
        let p = projection(),verdict = try XCTUnwrap(p.verdicts.first),row = try XCTUnwrap(Record(values:verdict.object("review_assessment")).records("acceptance").first)
        XCTAssertEqual(p.verdicts.count,1);XCTAssertTrue(p.citedIDs.contains("screen"));XCTAssertFalse(p.citedIDs.contains("log"))
        XCTAssertEqual(p.acceptanceText(row,verdict:verdict),"Captured historical outcome")
        XCTAssertEqual(row.string("result"),"fail")
    }
    func testCleanedOriginalDoesNotBecomeAvailableBecauseBundleExists() throws {
        let p = projection(unavailable:true),screen = try XCTUnwrap(p.files.first { $0.role == "Screenshot 1" })
        XCTAssertFalse(screen.available);XCTAssertTrue(screen.cited);XCTAssertEqual(screen.ref.string("sha256"),"hash-screen")
    }
}
