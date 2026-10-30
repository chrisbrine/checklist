import XCTest
@testable import ChecklistApp

@MainActor final class StorageSettingsObservationTests: XCTestCase {
    func testRetiredPreviewNamesWhyAndRetryCanPresentVerifiedContent() async {
        let model = StorageSettingsObservation()
        await model.previewRestore {throw CancellationError()}
        XCTAssertEqual(model.result,StorageSettingsObservation.previewRetiredText);XCTAssertFalse(model.restoring)
        XCTAssertFalse(model.showingRestorePreview)
        await model.previewRestore {["path":"/verified","manifest_sha256":"digest"]}
        XCTAssertTrue(model.showingRestorePreview)
        XCTAssertEqual(model.restorePreview["path"] as? String,"/verified")
        XCTAssertTrue(model.result.isEmpty)
    }
    func testLatePreviewCannotReplaceNewerPreviewOrReportItsError() async {
        let model = StorageSettingsObservation()
        var continuation: CheckedContinuation<[String:Any],Error>?
        let old = Task {await model.previewRestore {try await withCheckedThrowingContinuation {continuation = $0}}}
        for _ in 0..<100 {if continuation != nil {break};await Task.yield()}
        XCTAssertNotNil(continuation)
        await model.previewRestore {["path":"/new"]}
        continuation?.resume(throwing:NSError(domain:"late-preview",code:1));await old.value
        XCTAssertEqual(model.restorePreview["path"] as? String,"/new")
        XCTAssertTrue(model.showingRestorePreview);XCTAssertTrue(model.result.isEmpty)
    }
    func testCanceledPreviewTransportIgnoringCancellationCannotPresentReply() async {
        let model = StorageSettingsObservation()
        var continuation: CheckedContinuation<[String:Any],Error>?
        let read = Task {await model.previewRestore {try await withCheckedThrowingContinuation {continuation = $0}}}
        for _ in 0..<100 {if continuation != nil {break};await Task.yield()}
        XCTAssertNotNil(continuation)
        read.cancel();continuation?.resume(returning:["path":"/stale"]);await read.value
        XCTAssertFalse(model.showingRestorePreview);XCTAssertTrue(model.restorePreview.isEmpty)
        XCTAssertFalse(model.restoring);XCTAssertTrue(model.result.isEmpty)
    }
    func testCanceledStorageRefreshKeepsAcceptedStatusAndNoError() async {
        let model = StorageSettingsObservation()
        await model.refreshStatus {["last_verified_backup":["path":"/accepted"]]}
        await model.refreshStatus {throw CancellationError()}
        XCTAssertEqual((model.info["last_verified_backup"] as? [String:Any])?["path"] as? String,"/accepted")
        XCTAssertTrue(model.statusError.isEmpty);XCTAssertTrue(model.result.isEmpty)
    }
    func testLateStatusCannotReplaceNewerStatus() async {
        let model = StorageSettingsObservation()
        var continuation: CheckedContinuation<[String:Any],Error>?
        let old = Task {await model.refreshStatus {try await withCheckedThrowingContinuation {continuation = $0}}}
        for _ in 0..<100 {if continuation != nil {break};await Task.yield()}
        XCTAssertNotNil(continuation)
        await model.refreshStatus {["database_path":"new"]}
        continuation?.resume(returning:["database_path":"old"]);await old.value
        XCTAssertEqual(model.info["database_path"] as? String,"new");XCTAssertTrue(model.statusError.isEmpty)
    }
    func testCommittedBackupShowsSuccessAndNewStatusDespiteOlderInFlightStatus() async {
        let model = StorageSettingsObservation()
        await model.refreshStatus {["last_verified_backup":["path":"/previous"]]}
        var continuation: CheckedContinuation<[String:Any],Error>?
        let old = Task {await model.refreshStatus {try await withCheckedThrowingContinuation {continuation = $0}}}
        for _ in 0..<100 {if continuation != nil {break};await Task.yield()}
        XCTAssertNotNil(continuation)
        await model.backup(path:"/new",fetch:{["path":"/new","status":"complete"]},status:{["last_verified_backup":["path":"/new"]]})
        continuation?.resume(returning:["last_verified_backup":["path":"/previous"]]);await old.value
        XCTAssertEqual(model.result,"Backup saved to /new.")
        XCTAssertEqual((model.info["last_verified_backup"] as? [String:Any])?["path"] as? String,"/new")
        XCTAssertFalse(model.backingUp);XCTAssertTrue(model.statusError.isEmpty)
    }
    func testCanceledBackupDoesNotShowErrorOrRefreshFromUnacceptedReply() async {
        let model = StorageSettingsObservation();var statusCalls = 0
        await model.backup(path:"/backup",fetch:{throw CancellationError()},status:{statusCalls += 1;return [:]})
        XCTAssertTrue(model.result.isEmpty);XCTAssertFalse(model.backingUp);XCTAssertEqual(statusCalls,0)
    }
    func testStatusCancellationAfterCommittedBackupDoesNotEraseSuccess() async {
        let model = StorageSettingsObservation()
        await model.backup(path:"/backup",fetch:{["path":"/backup"]},status:{throw CancellationError()})
        XCTAssertEqual(model.result,"Backup saved to /backup.")
        XCTAssertTrue(model.statusError.isEmpty);XCTAssertFalse(model.backingUp)
    }
    func testKnownStorageChangeFencesOlderStatusBeforeRefreshStarts() async {
        let model = StorageSettingsObservation()
        await model.refreshStatus {["database_path":"accepted"]}
        var continuation: CheckedContinuation<[String:Any],Error>?
        let old = Task {await model.refreshStatus {try await withCheckedThrowingContinuation {continuation = $0}}}
        for _ in 0..<100 {if continuation != nil {break};await Task.yield()}
        XCTAssertNotNil(continuation)
        model.storageDidChange()
        continuation?.resume(returning:["database_path":"stale"]);await old.value
        XCTAssertEqual(model.info["database_path"] as? String,"accepted")
    }
    func testRealStatusFailurePreservesFactsAndSuccessfulRefreshClearsError() async {
        let model = StorageSettingsObservation()
        await model.refreshStatus {["database_path":"accepted"]}
        await model.refreshStatus {throw NSError(domain:"storage-status",code:2)}
        XCTAssertFalse(model.statusError.isEmpty);XCTAssertEqual(model.info["database_path"] as? String,"accepted")
        await model.refreshStatus {["database_path":"fresh"]}
        XCTAssertTrue(model.statusError.isEmpty);XCTAssertEqual(model.info["database_path"] as? String,"fresh")
    }
    func testScopeChangeClearsEarlierStatusAndFencesLateReply() async {
        let model = StorageSettingsObservation();model.changeScope("old-store")
        await model.refreshStatus {["database_path":"old"]}
        var continuation: CheckedContinuation<[String:Any],Error>?
        let old = Task {await model.refreshStatus {try await withCheckedThrowingContinuation {continuation = $0}}}
        for _ in 0..<100 {if continuation != nil {break};await Task.yield()}
        XCTAssertNotNil(continuation)
        model.changeScope("new-store");XCTAssertTrue(model.info.isEmpty)
        await model.refreshStatus {["database_path":"new"]}
        continuation?.resume(returning:["database_path":"late-old"]);await old.value
        XCTAssertEqual(model.info["database_path"] as? String,"new")
    }
    func testScopeChangeFencesPendingBackupAndItsStatusRefresh() async {
        let model = StorageSettingsObservation();model.changeScope("old-store")
        var continuation: CheckedContinuation<[String:Any],Error>?,statusCalls = 0
        let old = Task {await model.backup(path:"/old-backup",fetch:{try await withCheckedThrowingContinuation {continuation = $0}},status:{statusCalls += 1;return ["database_path":"old"]})}
        for _ in 0..<100 {if continuation != nil {break};await Task.yield()}
        XCTAssertNotNil(continuation)
        model.changeScope("new-store")
        await model.refreshStatus {["database_path":"new"]}
        continuation?.resume(returning:["path":"/old-backup"]);await old.value
        XCTAssertEqual(model.info["database_path"] as? String,"new")
        XCTAssertTrue(model.result.isEmpty);XCTAssertFalse(model.backingUp);XCTAssertEqual(statusCalls,0)
    }
    func testScopeChangeFencesPendingPreview() async {
        let model = StorageSettingsObservation();model.changeScope("old-store")
        var continuation: CheckedContinuation<[String:Any],Error>?
        let old = Task {await model.previewRestore {try await withCheckedThrowingContinuation {continuation = $0}}}
        for _ in 0..<100 {if continuation != nil {break};await Task.yield()}
        XCTAssertNotNil(continuation)
        model.changeScope("new-store")
        await model.previewRestore {["path":"/new-store-preview"]}
        continuation?.resume(returning:["path":"/old-store-preview"]);await old.value
        XCTAssertEqual(model.restorePreview["path"] as? String,"/new-store-preview")
        XCTAssertTrue(model.showingRestorePreview);XCTAssertTrue(model.result.isEmpty)
    }
    func testBlankIdentityKeepsPendingPreviewAndADifferentStoreNamesWhyItEnded() async {
        let model = StorageSettingsObservation();model.changeScope("store")
        var continuation: CheckedContinuation<[String:Any],Error>?
        let read = Task {await model.previewRestore {try await withCheckedThrowingContinuation {continuation = $0}}}
        for _ in 0..<100 {if continuation != nil {break};await Task.yield()}
        XCTAssertNotNil(continuation)
        model.changeScope("");XCTAssertTrue(model.restoring);XCTAssertEqual(model.scope,"store")
        model.changeScope("store");XCTAssertTrue(model.restoring)
        model.changeScope("other");XCTAssertFalse(model.restoring)
        XCTAssertEqual(model.result,StorageSettingsObservation.storeChangedText)
        continuation?.resume(returning:["path":"/old"]);await read.value
        XCTAssertFalse(model.showingRestorePreview);XCTAssertTrue(model.restorePreview.isEmpty)
    }
    func testStoreIdentityComparison() {
        XCTAssertTrue(StorageSettingsObservation.sameStore("","a"));XCTAssertTrue(StorageSettingsObservation.sameStore("a",""))
        XCTAssertTrue(StorageSettingsObservation.sameStore("a","a"));XCTAssertFalse(StorageSettingsObservation.sameStore("b","a"))
    }
    func testAlreadyCanceledPreviewDoesNotHideAcceptedConfirmation() async {
        let model = StorageSettingsObservation()
        await model.previewRestore {["path":"/accepted"]}
        let canceled = Task {await model.previewRestore {XCTFail("A canceled preview must not fetch");return [:]}}
        canceled.cancel();await canceled.value
        XCTAssertTrue(model.showingRestorePreview)
        XCTAssertEqual(model.restorePreview["path"] as? String,"/accepted")
        XCTAssertTrue(model.result.isEmpty);XCTAssertFalse(model.restoring)
    }
}
