import ChecklistTestSupport
import XCTest
import Foundation
import Dispatch
import GRDB
@testable import ChecklistCore

final class WorkHealthPreparationTests: XCTestCase {
    func testHealthPreparationKeepsRestoreDrainAdmissionUntilItsCommitFinishes() throws {
        let f = try StorageFixture(fast:true),router = f.router!
        let entered = DispatchSemaphore(value:0),release = DispatchSemaphore(value:0)
        let finished = expectation(description:"preparation and commit finish")
        let failure = LockedTestState<Error?>(nil)
        router.workHealthPreparationProbe = {
            entered.signal()
            guard release.wait(timeout:.now()+10) == .success else {throw CoreError("TEST_TIMEOUT","Health preparation was not released.")}
        }
        defer {release.signal();router.workHealthPreparationProbe = nil}
        DispatchQueue.global().async {
            defer {finished.fulfill()}
            do {_ = try router.runWorkHealthChecks()} catch {failure.withLock {$0 = error}}
        }
        XCTAssertEqual(entered.wait(timeout:.now()+5),.success)
        let drain = try router.beginStorageDrain(caller:f.owner)
        defer {try? router.cancelStorageDrain(drain,caller:f.owner)}
        XCTAssertFalse(try router.waitForStorageDrain(drain,timeout:0,caller:f.owner))
        XCTAssertThrowsError(try router.runWorkHealthChecks()) {error in
            XCTAssertEqual((error as? CoreError)?.code,"STORAGE_DRAINING")
        }
        release.signal();wait(for:[finished],timeout:10)
        XCTAssertNil(failure.snapshot)
        XCTAssertTrue(try router.waitForStorageDrain(drain,timeout:0,caller:f.owner))
    }

    func testSlowHealthPreparationLeavesUnrelatedWriteAndFollowingReadsFree() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),task = try f.task(project)
        let router = f.router!,entered = DispatchSemaphore(value:0),release = DispatchSemaphore(value:0)
        try router.dbQueue.writeWithoutTransaction {db in
            try router.withValidatedDomainTransaction(db) {
                var active = task
                active["status_id"] = try XCTUnwrap(router.records(db,type:"status",project:project["id"] as? String).first {$0["category"] as? String == "active"}?["id"])
                try router.save(db,active,type:"task");return .commit
            }
        }
        let healthDone = expectation(description:"health pass released")
        let healthResult = LockedTestState<JSON?>(nil)
        router.workHealthPreparationProbe = {
            entered.signal()
            guard release.wait(timeout:.now()+10) == .success else {throw CoreError("TEST_TIMEOUT","Health preparation was not released.")}
        }
        defer {release.signal();router.workHealthPreparationProbe = nil}
        DispatchQueue.global().async {
            defer {healthDone.fulfill()}
            do {let result = try router.runWorkHealthChecks();healthResult.withLock {$0 = result}} catch {XCTFail("Health: \(error)")}
        }
        XCTAssertEqual(entered.wait(timeout:.now()+5),.success)
        let lane = DispatchQueue(label:"checklist-health-responsiveness-test"),finished = DispatchGroup()
        let calls: [(String,JSON)] = [
            ("message_send",["project_id":project["id"]!,"task_id":task["id"]!,"kind":"note","body":"Unrelated health contention regression"]),
            ("service_info",["project_id":project["id"]!]),
            ("task_get",["project_id":project["id"]!,"task_id":task["id"]!])]
        let began = ProcessInfo.processInfo.systemUptime
        for (method,params) in calls {
            finished.enter()
            lane.async {
                defer {finished.leave()}
                do {
                    _ = try f.call(method,params)
                    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-began,1,method)
                } catch {XCTFail("\(method): \(error)")}
            }
        }
        let result = finished.wait(timeout:.now()+1)
        release.signal()
        XCTAssertEqual(result,.success,"Work-health preparation blocked unrelated requests")
        XCTAssertEqual(finished.wait(timeout:.now()+10),.success)
        wait(for:[healthDone],timeout:10)
        XCTAssertEqual(healthResult.snapshot?["inspected"] as? Int,1)
        XCTAssertNil(healthResult.snapshot?["deferred"])
        let saved = try router.dbQueue.read {try router.record($0,task["id"] as! String,type:"task")}
        XCTAssertNotNil(saved["work_health"],"The background pass must actually commit after unrelated traffic")
    }

    func testChangedGroupMembershipUsesExactUnicodeAndLegacyShapes() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),router = f.router!
        let group = try XCTUnwrap(f.call("triage_create",["project_id":project["id"]!,"name":"Exact membership"])["data"] as? JSON)
        let prefix = uuid(),first = prefix + "\u{e9}",second = prefix + "e\u{301}"
        let pid = project["id"] as! String,gid = group["id"] as! String
        var dependencies = WorkHealthPreparationDependencies()
        dependencies.includeProject(pid,facts:try router.workHealthPreparationProjectFacts(project))
        dependencies.selectedTasks.insert(.init(project:Data(pid.utf8),id:Data(second.utf8)))
        for members: Any in [[["task_id":first],["task_id":second]],[first,second],[]] {
            try router.dbQueue.writeWithoutTransaction {db in
                var current = group;current["members"] = members;current["task_ids"] = [first,second]
                try db.execute(sql:"UPDATE records SET data=? WHERE id=?",arguments:[try jsonString(current),gid])
                var seen: [Data] = []
                try router.visitWorkHealthPreparationMembers(db,group:Data(gid.utf8),project:Data(pid.utf8)) {seen.append($0);return true}
                XCTAssertEqual(seen,[Data(first.utf8),Data(second.utf8)])
                let changes = [WorkHealthPreparationChanges.Change(id:Data(gid.utf8),type:Data("group".utf8),project:Data(pid.utf8),task:Data())]
                XCTAssertFalse(try router.workHealthPreparationIsCurrent(db,changes:changes,dependencies:dependencies))
            }
        }
    }

    func testMovedGroupChecksItsNewProjectAndInvalidCurrentEnvelopeDefers() throws {
        let f = try StorageFixture(fast:true),first = try f.project(),router = f.router!
        let otherRoot = f.base.appendingPathComponent("other-workspace")
        try FileManager.default.createDirectory(at:otherRoot,withIntermediateDirectories:true)
        let second = try XCTUnwrap(f.call("project_create",["name":"Other scope","key_prefix":"OS","root_path":otherRoot.path])["data"] as? JSON)
        let projects = [first,second].sorted {Data(($0["id"] as! String).utf8).lexicographicallyPrecedes(Data(($1["id"] as! String).utf8))}
        let old = projects[0],new = projects[1],oldID = old["id"] as! String,newID = new["id"] as! String,target = uuid()
        let group = try XCTUnwrap(f.call("triage_create",["project_id":oldID,"name":"Moved plan"])["data"] as? JSON),gid = group["id"] as! String
        var dependencies = WorkHealthPreparationDependencies()
        for project in projects {dependencies.includeProject(project["id"] as! String,facts:try router.workHealthPreparationProjectFacts(project))}
        dependencies.selectedTasks.insert(.init(project:Data(newID.utf8),id:Data(target.utf8)))
        try router.dbQueue.writeWithoutTransaction {db in
            var current = group;current["project_id"] = newID;current["members"] = [target]
            try db.execute(sql:"UPDATE records SET project_id=?,data=? WHERE id=?",arguments:[newID,try jsonString(current),gid])
            let changes = [oldID,newID].map {WorkHealthPreparationChanges.Change(id:Data(gid.utf8),type:Data("group".utf8),project:Data($0.utf8),task:Data())}
            XCTAssertFalse(try router.workHealthPreparationIsCurrent(db,changes:changes,dependencies:dependencies))
            current["id"] = uuid()
            try db.execute(sql:"UPDATE records SET data=? WHERE id=?",arguments:[try jsonString(current),gid])
            XCTAssertFalse(try router.workHealthPreparationIsCurrent(db,changes:changes,dependencies:dependencies),"A present invalid group is not an absent group")
        }
    }
}

extension EvidenceAuthorityTests {
    func testWorkHealthPreparationFullStalePageDoesNotStarveFollowingQuietTicket() throws {
        let p = try project()
        var attempts: [String] = []
        for index in 0..<10 {
            let task = try ready(p),worker = try native(p,"health-stale-page-\(index)",domain:"health-stale-page-\(index)")
            attempts.append(try claim(p,task,caller:worker)["id"] as! String)
        }
        let quiet = try ready(p),worker = try native(p,"health-after-stale-page",domain:"health-after-stale-page")
        _ = try claim(p,quiet,caller:worker)
        router.workHealthPreparationProbe = { [self] in
            try router.dbQueue.writeWithoutTransaction {db in
                for id in attempts {
                    try db.execute(sql:"UPDATE records SET data=json_set(data,'$.health_progress_at',?,'$.health_progress_id',?) WHERE id=?",arguments:[now(),uuid(),id])
                }
            }
        }
        defer {router.workHealthPreparationProbe = nil}
        let first = try router.runWorkHealthChecks()
        XCTAssertEqual(first["deferred_count"] as? Int,10)
        XCTAssertEqual(first["inspected"] as? Int,0)
        XCTAssertEqual(first["has_more"] as? Bool,true)
        XCTAssertGreaterThan(router.workHealthScanPosition,0)
        let second = try router.runWorkHealthChecks()
        XCTAssertEqual(second["inspected"] as? Int,1)
        XCTAssertEqual(second["has_more"] as? Bool,false)
        XCTAssertEqual(router.workHealthScanPosition,0)
        let health = try call("work_health_get",["project_id":p["id"]!,"task_id":quiet["id"]!])
        XCTAssertNotNil(health["observed_at"])
    }

    func testWorkHealthPreparationBusyCandidateDoesNotStarveQuietCandidateOnSamePage() throws {
        let p = try project(),busy = try ready(p),busyWorker = try native(p,"health-same-page-busy",domain:"health-same-page-busy")
        let attempt = try claim(p,busy,caller:busyWorker)
        let quiet = try ready(p),quietWorker = try native(p,"health-same-page-quiet",domain:"health-same-page-quiet")
        _ = try claim(p,quiet,caller:quietWorker)
        _ = try router.runWorkHealthChecks()
        router.workHealthPreparationProbe = { [self] in
            try router.dbQueue.writeWithoutTransaction {db in
                try db.execute(sql:"UPDATE records SET data=json_set(data,'$.health_progress_at',?,'$.health_progress_id',?) WHERE id=?",arguments:[now(),uuid(),attempt["id"] as! String])
            }
        }
        defer {router.workHealthPreparationProbe = nil}
        var request: String?
        for _ in 0..<3 {
            let result = try router.runWorkHealthChecks(at:Date().addingTimeInterval(1202))
            XCTAssertNil(result["deferred"])
            XCTAssertEqual(result["deferred_count"] as? Int,1)
            XCTAssertEqual(result["inspected"] as? Int,1)
            let health = try call("work_health_get",["project_id":p["id"]!,"task_id":quiet["id"]!])
            let current = try XCTUnwrap(health["request_id"] as? String)
            if let request {XCTAssertEqual(current,request)} else {request = current}
        }
    }

    func testWorkHealthPreparationDoesNotStarveBehindUnrelatedCheckpointsOrProjectCounters() throws {
        let p = try project(),busy = try ready(p),busyWorker = try native(p,"health-busy",domain:"health-busy")
        let busyAttempt = try claim(p,busy,caller:busyWorker)
        let quiet = try ready(p),quietWorker = try native(p,"health-quiet",domain:"health-quiet")
        _ = try claim(p,quiet,caller:quietWorker)
        _ = try router.runWorkHealthChecks()
        let position = try router.dbQueue.writeWithoutTransaction {db -> Int64 in
            let position = try XCTUnwrap(Int64.fetchOne(db,sql:"SELECT rowid FROM records WHERE id=?",arguments:[busy["id"] as! String]))
            router.workHealthScanPosition = position;return position
        }
        router.workHealthPreparationProbe = { [self] in
            // These are watched families, in the same project, but none is a
            // dependency of the quiet ticket's already prepared page.
            for _ in 0..<20 {
                try router.dbQueue.writeWithoutTransaction {db in
                    try db.execute(sql:"UPDATE records SET data=json_set(data,'$.health_progress_at',?,'$.health_progress_id',?) WHERE id=?",arguments:[now(),uuid(),busyAttempt["id"] as! String])
                }
            }
            for _ in 0..<3 {_ = try call("task_create",["project_id":p["id"]!,"title":"Concurrent unrelated counter update"])}
            _ = try call("triage_create",["project_id":p["id"]!,"name":"Unrelated empty plan"])
        }
        defer {router.workHealthPreparationProbe = nil}
        let result = try router.runWorkHealthChecks(at:Date().addingTimeInterval(1202))
        XCTAssertNil(result["deferred"])
        XCTAssertEqual(result["inspected"] as? Int,1)
        XCTAssertEqual(router.workHealthScanPosition,0)
        XCTAssertNotEqual(router.workHealthScanPosition,position)
        let health = try call("work_health_get",["project_id":p["id"]!,"task_id":quiet["id"]!])
        XCTAssertEqual(health["state"] as? String,"awaiting_response")
        XCTAssertNotNil(health["request_id"],"A quiet ticket's due check must commit during unrelated watched-family traffic")
    }

    func testWorkHealthPreparationRejectsANewMatchingTriage() throws {
        let p = try project(),t = try ready(p),w = try native(p,"health-new-triage",domain:"health-new-triage")
        _ = try claim(p,t,caller:w)
        router.workHealthPreparationProbe = { [self] in
            let group = try call("triage_create",["project_id":p["id"]!,"name":"New matching plan"])
            _ = try call("group_membership",["project_id":p["id"]!,"group_id":group["id"]!,"expected_revision":group["revision"]!,"task_id":t["id"]!,"action":"add"])
        }
        defer {router.workHealthPreparationProbe = nil}
        XCTAssertEqual(try router.runWorkHealthChecks()["deferred"] as? Bool,true)
        router.workHealthPreparationProbe = nil
        XCTAssertEqual(try router.runWorkHealthChecks()["inspected"] as? Int,1)
    }

    func testWorkHealthPreparationFencesATriageSiblingOutsideItsCandidatePage() throws {
        let p = try project(),sibling = try ready(p),t = try ready(p),w = try native(p,"health-sibling-fence",domain:"health-sibling-fence")
        _ = try claim(p,t,caller:w)
        var group = try call("triage_create",["project_id":p["id"]!,"name":"Sibling facts"])
        for task in [sibling,t] {
            group = try call("group_membership",["project_id":p["id"]!,"group_id":group["id"]!,"expected_revision":group["revision"]!,"task_id":task["id"]!,"action":"add"])
        }
        try router.dbQueue.writeWithoutTransaction {db in
            router.workHealthScanPosition = try XCTUnwrap(Int64.fetchOne(db,sql:"SELECT rowid FROM records WHERE id=?",arguments:[sibling["id"] as! String]))
        }
        router.workHealthPreparationProbe = { [self] in
            try router.dbQueue.writeWithoutTransaction {db in
                let status = try XCTUnwrap(router.records(db,type:"status",project:p["id"] as? String).first {$0["category"] as? String == "blocked"}?["id"] as? String)
                try db.execute(sql:"UPDATE records SET data=json_set(data,'$.status_id',?) WHERE id=?",arguments:[status,sibling["id"] as! String])
            }
        }
        defer {router.workHealthPreparationProbe = nil}
        XCTAssertEqual(try router.runWorkHealthChecks()["deferred"] as? Bool,true)
    }

    func testWorkHealthPreparationFencesSemanticProjectSettings() throws {
        let p = try project(),t = try ready(p),w = try native(p,"health-settings-fence",domain:"health-settings-fence")
        _ = try claim(p,t,caller:w)
        router.workHealthPreparationProbe = { [self] in
            try router.dbQueue.writeWithoutTransaction {db in
                try db.execute(sql:"UPDATE records SET data=json_set(data,'$.work_health_settings.enabled',json('false')) WHERE id=?",arguments:[p["id"] as! String])
            }
        }
        defer {router.workHealthPreparationProbe = nil}
        XCTAssertEqual(try router.runWorkHealthChecks()["deferred"] as? Bool,true)
        router.workHealthPreparationProbe = nil
        let fresh = try router.runWorkHealthChecks()
        XCTAssertEqual(fresh["enabled"] as? Bool,false)
        XCTAssertEqual(fresh["inspected"] as? Int,0)
    }

    func testWorkHealthPreparationRejectsSameRevisionAttemptChangeAndRetriesWithoutSkipping() throws {
        let p = try project(),t = try ready(p),w = try native(p,"health-preparation-fence",domain:"health-preparation-fence")
        let attempt = try claim(p,t,caller:w),position = router.workHealthScanPosition
        router.workHealthPreparationProbe = { [self] in
            try router.dbQueue.writeWithoutTransaction {db in
                try db.execute(sql:"UPDATE records SET data=json_set(data,'$.health_progress_at',?,'$.health_progress_id',?) WHERE id=?",arguments:[now(),uuid(),attempt["id"] as! String])
            }
        }
        defer {router.workHealthPreparationProbe = nil}
        let refused = try router.runWorkHealthChecks()
        XCTAssertEqual(refused["deferred"] as? Bool,true)
        XCTAssertEqual(refused["changed"] as? Int,0)
        XCTAssertEqual(refused["has_more"] as? Bool,false,"Concurrent changes use the ordinary health wake, not an immediate rescan")
        XCTAssertEqual(router.workHealthScanPosition,position)
        router.workHealthPreparationProbe = nil
        XCTAssertEqual(try router.runWorkHealthChecks()["inspected"] as? Int,1)
    }

    func testWorkHealthPreparationRechecksCurrentSessionBeforeDelivery() throws {
        let p = try project(),t = try ready(p),w = try native(p,"health-preparation-session",domain:"health-preparation-session")
        _ = try claim(p,t,caller:w)
        _ = try router.runWorkHealthChecks()
        router.workHealthPreparationProbe = { [self] in
            try router.dbQueue.writeWithoutTransaction {db in
                var session = try router.record(db,w.sessionID!,type:"session")
                session["state"] = "revoked";try router.save(db,session,type:"session")
            }
        }
        defer {router.workHealthPreparationProbe = nil}
        let result = try router.runWorkHealthChecks(at:Date().addingTimeInterval(1202))
        XCTAssertNil(result["deferred"],"Recipient state is checked at commit; it is not a prepared progress fact")
        let health = try call("work_health_get",["project_id":p["id"]!,"task_id":t["id"]!])
        XCTAssertNotNil(health["request_id"])
        XCTAssertTrue((health["deliveries"] as? [JSON] ?? []).isEmpty,"A prepared target must not deliver to a revoked session")
    }

    func testWorkHealthPreparationFailureRemovesFenceAndAllowsNextPass() throws {
        let p = try project(),t = try ready(p),w = try native(p,"health-preparation-retry",domain:"health-preparation-retry")
        _ = try claim(p,t,caller:w)
        router.workHealthPreparationProbe = {throw CoreError("TEST_PREPARATION_FAILURE","Owned failure")}
        defer {router.workHealthPreparationProbe = nil}
        XCTAssertThrowsError(try router.runWorkHealthChecks())
        try router.dbQueue.read {db in
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM sqlite_temp_master WHERE name LIKE 'work_health_changes_%'"),0)
        }
        router.workHealthPreparationProbe = nil
        XCTAssertEqual(try router.runWorkHealthChecks()["inspected"] as? Int,1)
    }
}
