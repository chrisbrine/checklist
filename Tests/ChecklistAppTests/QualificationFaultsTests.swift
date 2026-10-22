import XCTest
@testable import ChecklistApp
import ChecklistIPC

@MainActor final class QualificationFaultsTests: XCTestCase {
    func testLiveNeverReadsOrWritesEvenWhenTheKeyWouldBeArmed() throws {
        var reads = 0, writes = 0, logs = 0
        let faults = QualificationFaults(instance:try ChecklistInstance(environment:[:]),read:{ _ in
            reads += 1;return ["selected_records":"cursor_reset_twice","remaining":10]
        },write:{ _,_ in writes += 1 },log:{_ in logs += 1})
        faults.refresh()
        for boundary in [QualificationFaults.Read.records,.history,.freshContext] {try faults.inject(boundary)}
        XCTAssertFalse(faults.isArmed);XCTAssertEqual(faults.remaining,0)
        XCTAssertEqual(reads,0);XCTAssertEqual(writes,0);XCTAssertEqual(logs,0)
    }

    func testEachSlotUsesOnlyItsOwnDomainAndCountsDownAcrossBoundaries() throws {
        for slot in 1...4 {
            let domain = "org.checklist.app.test\(slot)"
            var value: [String:Any] = ["selected_records":"cursor_reset_twice","remaining":2], logs: [String] = []
            let faults = QualificationFaults(instance:try ChecklistInstance(slotValue:slot),read:{ actual in
                XCTAssertEqual(actual,domain);return value
            },write:{ actual,new in XCTAssertEqual(actual,domain);value = new },log:{logs.append($0)})
            XCTAssertTrue(faults.isArmed)
            XCTAssertThrowsError(try faults.inject(.records)) {XCTAssertEqual(($0 as? ChecklistError)?.code,"CURSOR_RESET")}
            XCTAssertEqual(faults.remaining,1)
            try faults.inject(.freshContext) // Successful recovery does not consume the reset budget.
            XCTAssertEqual(faults.remaining,1)
            XCTAssertThrowsError(try faults.inject(.history)) {XCTAssertEqual(($0 as? ChecklistError)?.code,"CURSOR_RESET")}
            XCTAssertEqual(value["remaining"] as? Int,0);XCTAssertFalse(faults.isArmed)
            try faults.inject(.records);try faults.inject(.freshContext)
            XCTAssertEqual(logs.count,2);XCTAssertTrue(logs.allSatisfy {$0.contains("slot-domain="+domain)})
            XCTAssertTrue(logs.last?.contains("remaining=0") == true)
        }
    }

    func testFreshContextFaultAndExternalArmingDisarming() throws {
        var value: [String:Any] = [:], logs: [String] = []
        let faults = QualificationFaults(instance:try ChecklistInstance(slotValue:2),read:{_ in value},write:{_,new in value = new},log:{logs.append($0)})
        XCTAssertFalse(faults.isArmed)
        value = ["selected_records":"fresh_context_fail","remaining":2];faults.refresh()
        XCTAssertTrue(faults.isArmed)
        XCTAssertThrowsError(try faults.inject(.history)) {XCTAssertEqual(($0 as? ChecklistError)?.code,"CURSOR_RESET")}
        XCTAssertThrowsError(try faults.inject(.freshContext)) {
            XCTAssertEqual(($0 as? ChecklistError)?.code,"QUALIFICATION_FRESH_CONTEXT_FAILED")
            XCTAssertTrue($0.localizedDescription.contains("fresh context read failed"))
        }
        XCTAssertFalse(faults.isArmed);XCTAssertEqual(logs.count,2)
        value = ["selected_records":"fresh_context_fail","remaining":3];faults.refresh()
        XCTAssertTrue(faults.isArmed)
        value = [:];faults.refresh();XCTAssertFalse(faults.isArmed)
        try faults.inject(.records);XCTAssertEqual(logs.count,2)
    }

    func testMalformedUnknownAndExhaustedValuesDoNotInject() throws {
        for value: Any in ["cursor_reset_twice",[:],
            ["selected_records":"unknown","remaining":2],
            ["selected_records":"cursor_reset_twice","remaining":0],
            ["selected_records":"cursor_reset_twice","remaining":-1],
            ["selected_records":"cursor_reset_twice","remaining":true],
            ["selected_records":"cursor_reset_twice","remaining":2.5],
            ["selected_records":"cursor_reset_twice","remaining":"2"]] {
            let faults = QualificationFaults(instance:try ChecklistInstance(slotValue:1),read:{_ in value},write:{_,_ in XCTFail("Invalid key was written")},log:{_ in XCTFail("Invalid key injected")})
            faults.refresh();XCTAssertFalse(faults.isArmed)
            for boundary in [QualificationFaults.Read.records,.history,.freshContext] {try faults.inject(boundary)}
        }
    }
}
