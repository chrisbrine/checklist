import XCTest
@testable import ChecklistApp

@MainActor final class BackupRetentionObservationTests: XCTestCase {
    func testPruningNeedsConfirmedSavedRuleAndExactPreview() async {
        let model = BackupRetentionObservation();model.changeScope("store")
        model.acceptSettings(["newest_count":5,"daily_days":7,"owner_confirmed":false])
        await model.loadPreview {["preview_sha256":"exact","prune_count":2]}
        XCTAssertFalse(model.canPrune)
        model.acceptSettings(["newest_count":5,"daily_days":7,"owner_confirmed":true])
        await model.loadPreview {["preview_sha256":"exact","prune_count":2]}
        XCTAssertTrue(model.canPrune)
        model.newestCount = 6
        XCTAssertFalse(model.canPrune)
        model.invalidatePreview();XCTAssertTrue(model.previewDigest.isEmpty)
    }
    func testLatePreviewCannotSurviveScopeOrSelectionChange() async {
        let model = BackupRetentionObservation();model.changeScope("old")
        var continuation: CheckedContinuation<[String:Any],Error>?
        let read = Task {await model.loadPreview {try await withCheckedThrowingContinuation {continuation = $0}}}
        for _ in 0..<100 {if continuation != nil {break};await Task.yield()}
        XCTAssertNotNil(continuation)
        model.changeScope("new")
        continuation?.resume(returning:["preview_sha256":"old","prune_count":1]);await read.value
        XCTAssertTrue(model.previewDigest.isEmpty);XCTAssertFalse(model.canPrune)
    }
    func testChangedIncludeChoiceFencesInflightPreview() async {
        let model = BackupRetentionObservation();model.changeScope("store")
        var continuation: CheckedContinuation<[String:Any],Error>?
        let read = Task {await model.loadPreview {try await withCheckedThrowingContinuation {continuation = $0}}}
        for _ in 0..<100 {if continuation != nil {break};await Task.yield()}
        model.includeUnrecorded = true;model.invalidatePreview()
        continuation?.resume(returning:["preview_sha256":"wrong-choice","prune_count":1]);await read.value
        XCTAssertTrue(model.previewDigest.isEmpty);XCTAssertFalse(model.loading)
    }
    func testCanceledAndFailedPreviewNeverLeavesPruneAvailable() async {
        let model = BackupRetentionObservation()
        model.acceptSettings(["newest_count":5,"daily_days":7,"owner_confirmed":true])
        await model.loadPreview {["preview_sha256":"accepted","prune_count":1]};XCTAssertTrue(model.canPrune)
        await model.loadPreview {throw CancellationError()}
        XCTAssertFalse(model.canPrune);XCTAssertTrue(model.message.isEmpty)
        await model.loadPreview {throw NSError(domain:"preview",code:1)}
        XCTAssertFalse(model.canPrune);XCTAssertFalse(model.message.isEmpty)
    }
    func testAutomaticRuleAndHistoryAreVisibleOnlyInTheirStoreScope() {
        let model = BackupRetentionObservation();model.changeScope("original")
        model.acceptSettings(["newest_count":3,"daily_days":3,"owner_confirmed":true,"automatic_prune":true,"last_automatic_prune":["status":"complete","moved_count":2],"automatic_prune_history":[["id":"event","occurred_at":"2026-10-30T12:00:00Z","status":"complete","moved_count":2]]])
        XCTAssertTrue(model.automaticPrune);XCTAssertEqual(model.newestCount,3);XCTAssertEqual(model.dailyDays,3)
        XCTAssertTrue(model.automaticStatusText.contains("2"));XCTAssertEqual(model.automaticHistory.first?.summary,"Moved 2 backup folders to Trash")
        model.changeScope("restored")
        XCTAssertFalse(model.automaticPrune);XCTAssertTrue(model.automaticHistory.isEmpty);XCTAssertTrue(model.automaticStatusText.isEmpty)
    }
    func testLegacyManualRuleDoesNotClaimAutomaticRetention() {
        let model = BackupRetentionObservation()
        model.acceptSettings(["newest_count":3,"daily_days":3,"owner_confirmed":true])
        XCTAssertTrue(model.ownerConfirmed);XCTAssertFalse(model.automaticPrune)
        model.acceptSettings(["newest_count":3,"daily_days":3,"owner_confirmed":true,"automatic_prune":true,"last_automatic_prune":["status":"deferred","error_code":"BACKUP_IN_USE"]])
        XCTAssertTrue(model.automaticStatusText.contains("could not finish"))
    }

}
