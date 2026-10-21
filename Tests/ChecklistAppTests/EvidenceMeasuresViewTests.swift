import XCTest
@testable import ChecklistApp

final class EvidenceMeasuresViewTests: XCTestCase {
    func measure(unit: String = "triangles",after: Double = 26000,limit: Double = 25000) -> [String:Any] { ["name":"Triangles","unit":unit,"before":32000,"after":after,"limit":limit] }
    func projection(manifests: [[String:Any]],reports: [[String:Any]] = [],attempts: [[String:Any]] = []) -> EvidenceMeasuresProjection {
        func scope(_ rows: [[String:Any]]) -> [[String:Any]] { rows.map { $0.merging(["project_id":"p","task_id":"t"]) { first,_ in first } } }
        let task = Record(values:["id":"t","project_id":"p","current_manifest_id":"m2"])
        return EvidenceMeasuresProjection(review:ReviewProjection(task:task,project:nil,data:["manifests":scope(manifests),"attachments":scope(reports),"attempts":scope(attempts)]))
    }
    func testSubmissionComparisonUsesPreviousTargetAndSameUnit() throws {
        let p = projection(manifests:[["id":"m1","evidence":["measures":[measure(after:28000)]]],["id":"m2","evidence":["measures":[measure(after:24000,limit:23000)]]]])
        let current = try XCTUnwrap(p.snapshots.last),value = try XCTUnwrap(current.measures.first),prior = try XCTUnwrap(p.previousMeasure(value,in:current))
        XCTAssertTrue(value.overLimit);XCTAssertEqual(prior.after,28000);XCTAssertEqual(prior.limit,25000)
        let changedUnit = projection(manifests:[["id":"m1","evidence":["measures":[measure(unit:"k triangles")]]],["id":"m2","evidence":["measures":[measure()]]]])
        XCTAssertNil(changedUnit.previousMeasure(value,in:changedUnit.snapshots[1]))
    }
    func testMissingPreviousMeasureDoesNotSkipBackToAnOlderPass() throws {
        let p = projection(manifests:[["id":"m0","evidence":["measures":[measure()]]],["id":"m1","evidence":[:]], ["id":"m2","evidence":["measures":[measure()]]]])
        XCTAssertNil(p.previousMeasure(p.snapshots[2].measures[0],in:p.snapshots[2]))
    }
    func testReportsCompareAcrossReviewAttemptsAndKeepSourceIdentity() throws {
        let reports: [[String:Any]] = [["id":"r1","name":"Budget report","author":"critic1","sha256":"hash1","target_manifest_id":"m1","review_attempt_id":"a1","measures":[measure(after:28000)]],["id":"r2","name":"Budget report","author":"critic2","sha256":"hash2","target_manifest_id":"m2","review_attempt_id":"a2","measures":[measure(after:24000)]]]
        let attempts: [[String:Any]] = [["id":"a1","phase":"review","manifest_id":"m1"],["id":"a2","phase":"review","manifest_id":"m2"]]
        let p = projection(manifests:[],reports:reports,attempts:attempts),current = try XCTUnwrap(p.snapshots.last),prior = try XCTUnwrap(p.previous(for:current))
        XCTAssertEqual(prior.id,"r1");XCTAssertEqual(prior.author,"critic1");XCTAssertEqual(prior.sha256,"hash1")
        XCTAssertEqual(p.previousMeasure(current.measures[0],in:current)?.after,28000)
        let ambiguous = projection(manifests:[],reports:reports + [reports[0].merging(["id":"duplicate"]) { _,new in new }],attempts:attempts)
        XCTAssertNil(ambiguous.previous(for:current))
    }
    func testUnboundOrConflictingReviewerReportsAreNotDisplayed() {
        let p = projection(manifests:[],reports:[["id":"r","name":"Report","target_manifest_id":"other","review_attempt_id":"a","measures":[measure()]]],attempts:[["id":"a","phase":"review","manifest_id":"m1"]])
        XCTAssertTrue(p.snapshots.isEmpty)
    }
    func testInvalidNumbersAreNotDisplayedAsValidObservations() {
        var invalid = measure();invalid["after"] = true
        XCTAssertNil(DisplayEvidenceMeasure(Record(values:invalid)))
        invalid["after"] = Double.infinity;XCTAssertNil(DisplayEvidenceMeasure(Record(values:invalid)))
        invalid["after"] = Int64(9_007_199_254_740_993);XCTAssertNil(DisplayEvidenceMeasure(Record(values:invalid)))
    }
    func testBoundedHistoryMergesForComparisonWithoutChangingCurrentAuthority() throws {
        let p = projection(manifests:[["id":"m2","evidence":["measures":[measure(after:24000)]]]])
        let history: [String:Any] = ["manifests":[["id":"m1","project_id":"p","task_id":"t","evidence":["measures":[measure(after:28000)]]],["id":"m2","project_id":"p","task_id":"t","evidence":["measures":[measure(after:24000)]]]]]
        let combined = EvidenceMeasuresProjection(review:p.review,history:history),current = try XCTUnwrap(combined.snapshots.last)
        XCTAssertEqual(combined.previousMeasure(current.measures[0],in:current)?.after,28000)
        XCTAssertEqual(p.review.manifests.count,1);XCTAssertEqual(combined.review.manifests.count,2)
    }
    func testReviewerComparisonDoesNotCrossGates() throws {
        let reports: [[String:Any]] = [["id":"r1","name":"Budget","target_manifest_id":"m1","review_attempt_id":"a1","measures":[measure(after:28000)]],["id":"r2","name":"Budget","target_manifest_id":"m1","review_attempt_id":"a3","measures":[measure(after:24000)]]]
        let attempts: [[String:Any]] = [["id":"a1","phase":"review","manifest_id":"m1","gate":"review"],["id":"a2","phase":"review","manifest_id":"m1","gate":"installed_build_verified"],["id":"a3","phase":"review","manifest_id":"m1","gate":"review"]]
        let p = projection(manifests:[],reports:reports,attempts:attempts),current = try XCTUnwrap(p.snapshots.last)
        XCTAssertEqual(p.previous(for:current)?.id,"r1")
    }
}
