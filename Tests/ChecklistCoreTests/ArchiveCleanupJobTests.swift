import XCTest
@testable import ChecklistCore

/// New job-state tests only. Existing nine retention-planner cases are carried, not repeated.
final class ArchiveCleanupJobTests: XCTestCase {
    func original(_ id: String = "object",bytes: Int64 = 7,revision: Int64 = 1) throws -> ArchiveCleanupOriginal {
        try .init(id:id,sha256:String(repeating:"a",count:64),logicalBytes:bytes,attachmentRevision:revision)
    }
    func job(_ originals: [ArchiveCleanupOriginal]? = nil) throws -> ArchiveCleanupJob {
        try .init(id:"job",projectID:"project",taskID:"task",taskRevision:2,settingsRevision:3,previewID:"preview",planDigest:String(repeating:"b",count:64),enqueuedAtMS:1000,notBeforeMS:31000,originals:originals ?? [original()])
    }
    func json(_ value: [String:Any]) throws -> Data {try JSONSerialization.data(withJSONObject:value,options:.sortedKeys)}
    func admission(_ original: ArchiveCleanupOriginal,complete: Bool = true,holds: Set<ArchiveCleanupJob.Hold> = [],project: String = "project") throws -> ArchiveCleanupJob.Admission {
        try .init(projectID:ArchiveAttachmentID(project),taskID:ArchiveAttachmentID("task"),original:original,referencesComplete:complete,holds:holds)
    }
    func testCompleteCodecRefusesMalformedRevisionUnknownFieldsAndItemCount() throws {
        let value = try job().record(revision:1);XCTAssertEqual(try json(ArchiveCleanupJob(record:value).record(revision:1)),try json(value))
        let invalidScalars: [Any] = [true,1.5,"1",NSNumber(value:UInt64.max)]
        for bad in invalidScalars {
            var changed = value;changed["revision"] = bad;XCTAssertThrowsError(try ArchiveCleanupJob(record:changed))
        }
        var changed = value;changed["raw_path"] = "/private/original";XCTAssertThrowsError(try ArchiveCleanupJob(record:changed))
        changed = value;changed["items"] = Array(repeating:(value["items"] as! [[String:Any]])[0],count:257);XCTAssertThrowsError(try ArchiveCleanupJob(record:changed))
        XCTAssertThrowsError(try job([original("same"),original("same")]))
        changed = value;var rows = value["items"] as! [[String:Any]];rows[0]["state"] = "held";changed["items"] = rows;changed["state"] = "held"
        XCTAssertThrowsError(try ArchiveCleanupJob(record:changed)) // no unexplained held state.
    }
    func testGraceBlocksAdmissionAndCancelRoundTripsBeforeFirstDeletion() throws {
        var value = try job();let before = try json(value.record(revision:1))
        XCTAssertThrowsError(try value.observe([admission(original())],nowMS:31000-1))
        XCTAssertEqual(try json(value.record(revision:1)),before)
        XCTAssertTrue(value.cancel());XCTAssertEqual(value.state,.canceled);XCTAssertTrue(value.items.allSatisfy {$0.state == .canceled})
        XCTAssertEqual(try ArchiveCleanupJob(record:value.record(revision:2)).state,.canceled)
        XCTAssertEqual(try value.logicalTotals().removed,0)
    }
    func testIncompleteReferenceGraphAndNewReaderHoldCannotBecomeReady() throws {
        var value = try job();try value.observe([admission(original(),complete:false)],nowMS:31000)
        XCTAssertEqual(value.state,.held);XCTAssertTrue(value.items[0].holds.contains(.referenceGraphUnavailable))
        try value.observe([admission(original(),holds:[.activeReader,.backupCapture])],nowMS:31001)
        XCTAssertEqual(value.state,.held);XCTAssertEqual(value.items[0].holds,[.activeReader,.backupCapture])
        try value.observe([admission(original())],nowMS:31002);XCTAssertEqual(value.state,.ready)
        XCTAssertEqual(try value.logicalTotals().removed,0) // metadata readiness is not an unlink.
    }
    func testWrongScopeChangedIdentityAndOversizedAdmissionAreAtomicRefusals() throws {
        var value = try job();let before = try json(value.record(revision:1))
        XCTAssertThrowsError(try value.observe([admission(original(),project:"other")],nowMS:31000))
        XCTAssertThrowsError(try value.observe([admission(original(revision:2))],nowMS:31000))
        XCTAssertThrowsError(try value.observe(Array(repeating:admission(original()),count:9),nowMS:31000))
        XCTAssertEqual(try json(value.record(revision:1)),before)
    }
    func testTwoIdenticalFailuresSuspendAndExplicitRetryNeedsFutureWindow() throws {
        var value = try job();let id = try ArchiveAttachmentID("object")
        try value.recordFailure(id:id,code:.admissionUnavailable);XCTAssertEqual(value.state,.held)
        try value.recordFailure(id:id,code:.admissionUnavailable);XCTAssertEqual(value.state,.suspended)
        XCTAssertEqual(try ArchiveCleanupJob(record:value.record(revision:3)).state,.suspended)
        XCTAssertThrowsError(try value.retry(nowMS:32000,notBeforeMS:32000))
        try value.retry(nowMS:32000,notBeforeMS:62000);XCTAssertEqual(value.state,.queued);XCTAssertEqual(value.items[0].sameFailureCount,0)
        XCTAssertThrowsError(try value.observe([admission(original())],nowMS:61999))
    }
    func testCancellationNeverRestartsAndDoesNotRepeatTerminalMutation() throws {
        var value = try job();XCTAssertTrue(value.cancel());let once = try json(value.record(revision:2))
        XCTAssertFalse(value.cancel());XCTAssertThrowsError(try value.retry(nowMS:32000,notBeforeMS:62000));XCTAssertThrowsError(try value.observe([],nowMS:32000))
        XCTAssertEqual(try json(value.record(revision:2)),once)
    }
    func testPartialCancelKeepsRemovedAndAlreadyMissingLogicalOutcomesSeparate() throws {
        var record = try job([original("removed",bytes:5),original("missing",bytes:6),original("remaining",bytes:7)]).record(revision:1)
        var rows = record["items"] as! [[String:Any]];rows[0]["state"] = "removed";rows[1]["state"] = "already_missing";record["items"] = rows
        var value = try ArchiveCleanupJob(record:record);XCTAssertTrue(value.cancel())
        XCTAssertEqual(value.items.map(\.state),[.removed,.alreadyMissing,.canceled]);XCTAssertEqual(try value.logicalTotals().removed,5);XCTAssertEqual(try value.logicalTotals().alreadyMissing,6)
        XCTAssertEqual(try ArchiveCleanupJob(record:value.record(revision:2)).state,.canceled)
    }
    func testNewJobAccountingRefusesOverflowBeforeAnyRecordCanBeReturned() throws {
        XCTAssertThrowsError(try job([original("one",bytes:Int64.max),original("two",bytes:1)]))
        XCTAssertThrowsError(try job([]))
        let value = try job([original("zero",bytes:0)]);XCTAssertEqual(try value.logicalTotals().selected,0)
    }
}
