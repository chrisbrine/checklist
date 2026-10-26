import XCTest
@testable import ChecklistCore

private final class BatchRaceResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) {lock.lock();defer {lock.unlock()};values.append(value)}
    var results: [String] {lock.lock();defer {lock.unlock()};return values}
}
extension CoreTests {
    func raceBatchCommands(_ calls: [(String,JSON,Caller)]) -> [String] {
        let group = DispatchGroup(),start = DispatchSemaphore(value:0),results = BatchRaceResults(),router = self.router!
        for (method,params,caller) in calls {
            group.enter();DispatchQueue.global().async {
                defer {group.leave()};start.wait()
                do {_ = try router.handle(method:method,params:params,caller:caller);results.append(method+":success")}
                catch let error as CoreError {results.append(method+":"+error.code)}
                catch {results.append(method+":"+String(describing:error))}
            }
        }
        for _ in calls {start.signal()}
        XCTAssertEqual(group.wait(timeout:.now()+120),.success)
        return results.results
    }
    func testSharedBatchConcurrentCompetingClaimsCreateOneCohortAndReplayOriginalIDs() throws {
        let p = try cohortProject(),worker = try cohortWorker(p),other = try cohortWorker(p),first = try sharedBatch(p,worker),second = try sharedBatch(p,other)
        let commands = [UUID().uuidString,UUID().uuidString]
        let params: [JSON] = zip([first,second],commands).map {batch,command in ["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"policy_revision":batch["policy_revision"]!,"command_id":command]}
        let results = raceBatchCommands([("batch_claim",params[0],worker),("batch_claim",params[1],other)])
        XCTAssertEqual(results.filter {$0 == "batch_claim:success"}.count,1);XCTAssertEqual(results.filter {$0 == "batch_claim:SCOPE_CONFLICT"}.count,1)
        let attempts = try router.dbQueue.read {try router.records($0,type:"attempt",project:(p["id"] as! String))}
        XCTAssertEqual(attempts.count,2);XCTAssertEqual(Set(attempts.compactMap {$0["batch_id"] as? String}).count,1)
        let winning = attempts[0]["batch_id"] as! String == first["id"] as! String ? 0 : 1
        let replay = try call("batch_claim",params[winning],[worker,other][winning],commands[winning])["claims"] as! [JSON]
        XCTAssertEqual(Set(replay.compactMap {$0["id"] as? String}),Set(attempts.compactMap {$0["id"] as? String}));XCTAssertTrue(replay.allSatisfy {$0["claim_token"] != nil})
    }
    func testDiscardAndClaimRaceHasExactlyOneWinnerAndBothSerialOrdersStayFenced() throws {
        for order in ["race","discard_first","claim_first"] {
            let p = try cohortProject(),worker = try cohortWorker(p),batch = try sharedBatch(p,worker)
            let discard: JSON = ["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"reason":"Unused plan","command_id":UUID().uuidString]
            let claim: JSON = ["project_id":p["id"]!,"batch_id":batch["id"]!,"expected_revision":1,"policy_revision":batch["policy_revision"]!,"command_id":UUID().uuidString]
            let results: [String]
            if order == "race" {results = raceBatchCommands([("batch_discard",discard,worker),("batch_claim",claim,worker)])}
            else {
                let calls = order == "discard_first" ? [("batch_discard",discard),("batch_claim",claim)] : [("batch_claim",claim),("batch_discard",discard)]
                results = calls.map {method,params in
                    do {_ = try router.handle(method:method,params:params,caller:worker);return method+":success"}
                    catch {return method+":"+((error as? CoreError)?.code ?? "unexpected")}
                }
            }
            XCTAssertEqual(results.filter {$0.hasSuffix(":success")}.count,1)
            XCTAssertTrue(results.contains("batch_claim:BATCH_DISCARDED") || results.contains("batch_discard:BATCH_ALREADY_CLAIMED"),"\(results)")
            let state = try router.dbQueue.read {db in (try router.records(db,type:"batch_disposition",project:(p["id"] as! String)),try router.records(db,type:"attempt",project:(p["id"] as! String)),try router.records(db,type:"batch_claim",project:(p["id"] as! String)))}
            if state.0.isEmpty {XCTAssertEqual(state.1.count,2);XCTAssertEqual(state.2.count,1)}
            else {XCTAssertEqual(state.0.count,1);XCTAssertTrue(state.1.isEmpty);XCTAssertTrue(state.2.isEmpty)}
        }
    }
}
