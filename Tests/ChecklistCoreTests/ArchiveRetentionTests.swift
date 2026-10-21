import XCTest
@testable import ChecklistCore

/// Pure, deterministic controls only. These never qualify live holds, deletion or native UI.
final class ArchiveRetentionTests: XCTestCase {
    let mib: Int64 = 1024 * 1024
    func fact(_ id: String,_ bytes: Int64,_ holds: Set<ArchiveProtectionReason> = []) throws -> ArchiveAttachmentFact {
        try .init(id:id,logicalOriginalBytes:bytes,protectionReasons:holds)
    }
    func config(threshold: Int64 = 20 * 1024 * 1024,budget: Int64 = 50 * 1024 * 1024,
                preset: ArchiveRetentionConfiguration.Preset = .cleanLargeManagedOnArchive) throws -> ArchiveRetentionConfiguration {
        try .init(preset:preset,largeOriginalBytes:threshold,retainedBudgetBytes:budget)
    }
    func ids(_ plan: ArchiveRetentionPlan) -> [String] {plan.selected.map(\.id.text)}

    func testDefaultCompleteConfigurationRoundTripAndReset() throws {
        let defaults = try ArchiveRetentionConfiguration.parse(nil)
        XCTAssertEqual(defaults.largeOriginalBytes,20 * mib);XCTAssertEqual(defaults.retainedBudgetBytes,50 * mib)
        XCTAssertEqual(try ArchiveRetentionConfiguration.parse(defaults.jsonValue),defaults)
        let custom = try config(threshold:30 * mib,budget:70 * mib,preset:.keepOriginals)
        XCTAssertEqual(try ArchiveRetentionConfiguration.parse(custom.jsonValue),custom)
        XCTAssertEqual(try ArchiveRetentionConfiguration.parse(nil),.defaults)
        var incomplete = custom.jsonValue;incomplete.removeValue(forKey:"retained_budget_bytes")
        XCTAssertThrowsError(try ArchiveRetentionConfiguration.parse(incomplete))
        var unknown = custom.jsonValue;unknown["provider"] = "codex"
        XCTAssertThrowsError(try ArchiveRetentionConfiguration.parse(unknown))
    }

    func testRejectsBooleanFractionNegativeAndOverflowConfiguration() throws {
        let invalid: [Any] = [true,1.25,-1,NSNumber(value:UInt64.max),"20971520"]
        for value in invalid {
            var raw = ArchiveRetentionConfiguration.defaults.jsonValue;raw["large_original_bytes"] = value
            XCTAssertThrowsError(try ArchiveRetentionConfiguration.parse(raw))
        }
        XCTAssertThrowsError(try config(threshold:0))
        XCTAssertThrowsError(try config(budget:-1))
        XCTAssertEqual(try config(budget:0).retainedBudgetBytes,0)
    }

    func testThresholdBoundaryIsIndependentFromAggregateBudget() throws {
        let facts = try [fact("below",20 * mib-1),fact("equal",20 * mib)]
        let p = try ArchiveRetentionPlanner.make(configuration:config(budget:100 * mib),facts:facts)
        XCTAssertEqual(ids(p),["equal"]);XCTAssertEqual(p.selected[0].reason,.largeOriginal)
        XCTAssertEqual(p.retainedLogicalBytes,20 * mib-1)
        XCTAssertEqual(p.selectedLogicalBytes,20 * mib)
    }

    func testSubthresholdAggregateOverflowPrunesLargestThenExactIDTie() throws {
        let facts = try ["f","e","d","c","b","a"].map {try fact($0,10 * mib)}
        let p = try ArchiveRetentionPlanner.make(configuration:.defaults,facts:facts)
        XCTAssertEqual(ids(p),["a"]);XCTAssertEqual(p.selected[0].reason,.aggregateOverflow)
        XCTAssertEqual(p.logicalOriginalBytes,60 * mib);XCTAssertEqual(p.retainedLogicalBytes,50 * mib)
        let mixed = try ArchiveRetentionPlanner.make(configuration:.defaults,facts:[fact("large",25 * mib),fact("one",19 * mib),fact("two",16 * mib),fact("three",15 * mib)])
        XCTAssertEqual(ids(mixed),["large"]);XCTAssertEqual(mixed.retainedLogicalBytes,50 * mib)
    }

    func testSuppliedAuthoritativeProtectionWinsAndOverBudgetIsHonest() throws {
        let p = try ArchiveRetentionPlanner.make(configuration:.defaults,facts:[fact("held",60 * mib,[.backupCapture,.keepOriginal]),fact("free",10 * mib),fact("empty",0)])
        XCTAssertEqual(ids(p),["free"]);XCTAssertEqual(p.protectedLogicalBytes,60 * mib)
        XCTAssertEqual(p.retainedLogicalBytes,60 * mib);XCTAssertEqual(p.retainedBudgetExcessBytes,10 * mib)
        XCTAssertEqual(p.protected[0].reasons,[.keepOriginal,.backupCapture])
        XCTAssertEqual(p.unprotectedRetainedLogicalBytes,0)
    }

    func testExternalAndUnavailableOriginalsNeverBecomeDeletionCandidates() throws {
        let facts = try [ArchiveAttachmentFact(id:"external",logicalOriginalBytes:Int64.max,mode:.externalReference),
                         ArchiveAttachmentFact(id:"cleaned",logicalOriginalBytes:Int64.max,availability:.originalCleaned),
                         ArchiveAttachmentFact(id:"missing",logicalOriginalBytes:Int64.max,availability:.missing),fact("managed",21 * mib)]
        let p = try ArchiveRetentionPlanner.make(configuration:.defaults,facts:facts)
        XCTAssertEqual(ids(p),["managed"]);XCTAssertEqual(p.logicalOriginalBytes,21 * mib)
        XCTAssertEqual(p.externalReferenceIDs.map(\.text),["external"])
        XCTAssertEqual(p.unavailableOriginalIDs.map(\.text),["cleaned","missing"])
        XCTAssertEqual(p.accounting,"logical_available_managed_originals_only")
    }

    func testOrderStableWithByteExactOpaqueIDsAndDuplicateRefusal() throws {
        let composed = "\u{e9}",decomposed = "e\u{301}"
        let facts = try [fact(composed,2),fact(decomposed,2),fact("other",2)]
        let cfg = try config(threshold:10,budget:0)
        let a = try ArchiveRetentionPlanner.make(configuration:cfg,facts:facts)
        let b = try ArchiveRetentionPlanner.make(configuration:cfg,facts:Array(facts.reversed()))
        XCTAssertEqual(a.selected.map(\.id),b.selected.map(\.id));XCTAssertEqual(a.selected.count,3)
        XCTAssertNotEqual(try ArchiveAttachmentID(composed),try ArchiveAttachmentID(decomposed))
        XCTAssertThrowsError(try ArchiveRetentionPlanner.make(configuration:cfg,facts:[fact("same",1),fact("same",2)]))
        XCTAssertThrowsError(try fact("   ",1));XCTAssertThrowsError(try fact("negative",-1))
    }

    func testCheckedLogicalAccountingDoesNotReturnPartialPlanOnOverflow() throws {
        XCTAssertThrowsError(try ArchiveRetentionPlanner.make(configuration:.defaults,facts:[fact("one",Int64.max),fact("two",1)])) {error in
            guard case ArchiveRetentionError.arithmeticOverflow = error else {return XCTFail("Expected checked aggregate overflow")}
        }
        let max = try ArchiveRetentionPlanner.make(configuration:config(threshold:Int64.max,budget:Int64.max),facts:[fact("max",Int64.max)])
        XCTAssertEqual(max.selectedLogicalBytes,Int64.max);XCTAssertEqual(max.retainedLogicalBytes,0)
    }

    func testKeepOriginalsPresetAndFreshHoldFactsNeverGrantDeletion() throws {
        let facts = try [fact("target",30 * mib)]
        let kept = try ArchiveRetentionPlanner.make(configuration:config(budget:0,preset:.keepOriginals),facts:facts)
        XCTAssertTrue(kept.selected.isEmpty);XCTAssertTrue(kept.keptByProjectPreset)
        XCTAssertEqual(kept.retainedLogicalBytes,30 * mib);XCTAssertEqual(kept.retainedBudgetExcessBytes,30 * mib)
        let before = try ArchiveRetentionPlanner.make(configuration:.defaults,facts:facts)
        let after = try ArchiveRetentionPlanner.make(configuration:.defaults,facts:[fact("target",30 * mib,[.activeReader])])
        XCTAssertEqual(ids(before),["target"]);XCTAssertTrue(after.selected.isEmpty)
        // This only recomputes a pure projection. The future service must acquire/recheck its real gate.
        XCTAssertEqual(after.protected[0].reasons,[.activeReader])
    }
}
