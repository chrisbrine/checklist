import ChecklistTestSupport
import XCTest
import Foundation
import Darwin
import GRDB
@testable import ChecklistCore

/// CL-119: the composed media-review workflow at scale. Owned template stores and synthetic
/// media only; never the live store. These Core cases do not observe native UI or playback.
final class MediaWorkflowQualificationTests: XCTestCase {
    typealias Fixture = MediaRoundTests.Fixture
    let checks = MediaRoundTests()
    let lists = MediaListQueryTests()
    let decisions = MediaDecisionTests()
    let rework = MediaReworkTests()
    let intake = MediaFrozenIntakeTests()
    let owners = AttachmentOwnershipTests()

    private func residentBytes() -> Int {
        var info = mach_task_basic_info(),count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to:&info) { $0.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count) } }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
    private func rowBytes(_ rows: [JSON]) throws -> Int { try JSONSerialization.data(withJSONObject:rows).count }

    /// Walks every page from `first`. A changed unsealed index honestly asks for CURSOR_RESET.
    private func walk(_ f: Fixture,_ round: JSON,_ first: JSON,total: Int) throws -> (rows: [JSON],pages: Int,slowest: TimeInterval,cursorBytes: Int,reset: Bool) {
        var rows = first["rows"] as! [JSON],cursor = first["next_cursor"] as? String,pages = 1,slowest = 0.0,cursorBytes = cursor?.utf8.count ?? 0
        while let next = cursor {
            let clock = Date(),response: JSON
            do { response = try lists.page(f,round,cursor:next) }
            catch let error as CoreError where error.code == "CURSOR_RESET" { return (rows,pages,slowest,cursorBytes,true) }
            slowest = max(slowest,Date().timeIntervalSince(clock));pages += 1
            let part = response["rows"] as! [JSON]
            XCTAssertLessThanOrEqual(part.count,100);XCTAssertEqual(response["total"] as? Int,total)
            XCTAssertLessThan(try rowBytes(part),100_000)
            rows += part;cursor = response["next_cursor"] as? String;cursorBytes = max(cursorBytes,cursor?.utf8.count ?? 0)
        }
        return (rows,pages,slowest,cursorBytes,false)
    }

    /// Item 1: grouping, filter, live update and list budgets for one round of `count` items.
    private func scaleRound(_ count: Int) throws {
        let caseStart = Date(),f = try Fixture()
        addTeardownBlock { try? FileManager.default.removeItem(at:f.base) }
        let type = try f.type(lists.schema()),round = try f.round(type)
        var clock = Date()
        try lists.seed(f,round,count:count)
        let seedSeconds = Date().timeIntervalSince(clock),rss = residentBytes()
        clock = Date()
        let first = try lists.page(f,round),firstSeconds = Date().timeIntervalSince(clock),firstRows = first["rows"] as! [JSON]
        XCTAssertEqual(firstRows.count,min(100,count));XCTAssertEqual(first["total"] as? Int,count)
        let firstBytes = try rowBytes(firstRows)
        XCTAssertLessThan(firstBytes,100_000);XCTAssertFalse(try jsonString(firstRows).contains("candidate_ids"))
        // Grouping: two declared levels with prefix counts over the whole round.
        XCTAssertEqual((firstRows[0]["group_path"] as! [JSON]).map {$0["item_count"] as! Int},[count/2,count/2])
        XCTAssertEqual((firstRows[0]["metadata"] as! JSON)["direction"] as? String,"N")
        // Filter: a typed metadata equality returns only matching rows and its own total.
        clock = Date()
        let east = try lists.page(f,round,filter:["metadata":["direction":"E"]]),filterSeconds = Date().timeIntervalSince(clock)
        XCTAssertEqual(east["total"] as? Int,(count+2)/3)
        XCTAssertTrue((east["rows"] as! [JSON]).allSatisfy {($0["metadata"] as! JSON)["direction"] as? String == "E"})
        // Live update and insert after the first page: the cursor window stays frozen.
        let laterID = String(format:"item-%04d",count-5),later = try f.record(laterID,"media_item")
        clock = Date()
        _ = try f.call("media_item_update",["item_id":laterID,"expected_revision":later["revision"]!,"title":"New live title","metadata":["character":"aaa","animation_label":"idle","direction":"S"]])
        _ = try f.item(round,title:"New live insert",metadata:["character":"aaa","animation_label":"idle","direction":"N"])
        let updateSeconds = Date().timeIntervalSince(clock)
        var walked = try walk(f,round,first,total:count)
        let reset = walked.reset
        if reset {
            // Unsealed (digest-only) cursor: the changed index refuses the old window honestly.
            XCTAssertLessThan(walked.rows.count,count)
            walked = try walk(f,round,try lists.page(f,round),total:count+1)
            XCTAssertFalse(walked.reset);XCTAssertEqual(walked.rows.count,count+1)
        } else {
            XCTAssertEqual(walked.rows.count,count);XCTAssertEqual(Set(walked.rows.map {$0["id"] as! String}).count,count)
            XCTAssertEqual(walked.rows.first {$0["id"] as? String == laterID}?["title"] as? String,"Item \(count-5)")
            XCTAssertEqual(walked.pages,(count+99)/100)
        }
        XCTAssertLessThanOrEqual(walked.cursorBytes,1_400_000)
        // Decode budget: an unreadable candidate payload is never decoded by counts or pages.
        try f.router.dbQueue.write {db in
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES ('unreadable-original',?,'media_candidate',1,?)",arguments:[f.project,"{invalid original payload " + String(repeating:"x",count:256*1024)])
        }
        clock = Date()
        let counts = try f.call("media_item_counts",["round_id":round["id"]!,"filter":["metadata":["flag":true,"number":2]]]),countsSeconds = Date().timeIntervalSince(clock)
        XCTAssertEqual(counts["total"] as? Int,1);XCTAssertNil(counts["rows"])
        let fresh = try lists.page(f,round)
        XCTAssertEqual(fresh["total"] as? Int,count+1);XCTAssertFalse(try jsonString(fresh).contains("invalid original"))
        let memory = residentBytes() - rss
        XCTAssertLessThan(memory,512 * 1024 * 1024)
        for seconds in [firstSeconds,filterSeconds,walked.slowest,countsSeconds] { XCTAssertLessThan(seconds,10) }
        print("CL119_SCALE items=\(count) seed_s=\(seedSeconds) first_page_s=\(firstSeconds) first_rows_bytes=\(firstBytes) filter_s=\(filterSeconds)"
            + " update_insert_s=\(updateSeconds) pages=\(walked.pages) slowest_page_s=\(walked.slowest) cursor_bytes_max=\(walked.cursorBytes) cursor_reset=\(reset)"
            + " counts_s=\(countsSeconds) rss_delta_bytes=\(memory) case_s=\(Date().timeIntervalSince(caseStart))")
    }
    func test300ItemRoundGroupingFilterUpdateAndListBudgets() throws { try QualificationSuite.requireEnabled();try scaleRound(300) }
    func test1000ItemRoundGroupingFilterUpdateAndListBudgets() throws { try QualificationSuite.requireEnabled();try scaleRound(1000) }
    func test1200ItemRoundAboveTheFormerCeilingKeepsListBudgets() throws { try QualificationSuite.requireEnabled();try scaleRound(1200) }

    /// Item 2: both cleanup/publication orders, each across a service restart.
    func testCleanupAndPublicationRaceOrdersAcrossRestartKeepHonestOutcomes() throws {
        let caseStart = Date()
        do { // Publication (handover to the target) first, restart, then cleanup.
            let (f,p,t,a) = try owners.fixture(),pid = p["id"] as! String
            _ = try owners.archiveAndDue(f,p,t)
            let source = try owners.anchor(f,p,.draftItem),r = try owners.adopt(f,p,a,source),target = try owners.anchor(f,p,.target)
            let prepared = try f.router!.prepareOwnedAttachmentOriginals(project:pid,owner:source,referenceIDs:[r["id"] as! String],caller:f.owner)
            let published = try owners.tx(f) { db,permit in try f.router!.transferMediaAttachmentReferences(db,permit:permit,project:pid,source:source,referenceIDs:[r["id"] as! String],destination:target,prepared:prepared,caller:f.owner) { _ in } }
            try f.close();try f.reopen()
            try f.router!.runStorageMaintenance()
            XCTAssertTrue(FileManager.default.fileExists(atPath:a["path"] as! String))
            XCTAssertEqual(try f.router!.readMediaAttachment(project:pid,referenceID:published.1[0]["id"] as! String,owner:published.0,caller:f.owner),Data(repeating:37,count:128))
            XCTAssertEqual(try owners.get(f,r["id"] as! String,"storage_hold")["state"] as? String,"released")
        }
        do { // Cleanup first, restart, then adoption: absent bytes refuse with no new hold.
            let (f,p,t,a) = try owners.fixture(),o = try owners.anchor(f,p,.draftItem),pid = p["id"] as! String
            let prepared = try f.router!.prepareAttachmentOriginals(project:pid,attachmentIDs:[a["id"] as! String],caller:f.owner)
            _ = try owners.archiveAndDue(f,p,t);try f.router!.runStorageMaintenance()
            try f.close();try f.reopen()
            XCTAssertFalse(FileManager.default.fileExists(atPath:a["path"] as! String))
            let holds = { try f.router!.dbQueue.read { try f.router!.records($0,type:"storage_hold",project:pid).count } },before = try holds()
            XCTAssertThrowsError(try owners.tx(f) { db,permit in try f.router!.adoptTaskAttachments(db,permit:permit,project:pid,owner:o,prepared:prepared,caller:f.owner) }) {
                print("CL119_RACE cleanup_first_refusal=\(($0 as? CoreError)?.code ?? String(describing:$0))")
            }
            XCTAssertEqual(try holds(),before)
        }
        print("CL119_CASE race_orders_s=\(Date().timeIntervalSince(caseStart))")
    }

    /// Item 2: interrupted capture and interrupted publication resume after a restart; the
    /// protected project export then keeps every media record byte-exact.
    func testInterruptedCaptureAndPublicationResumeAfterRestartAndExportIsLossless() throws {
        let caseStart = Date(),f = try MediaFrozenIntakeTests.Fixture(),round = try f.round(f.type(intake.imageSchema()))
        addTeardownBlock { try? FileManager.default.removeItem(at:f.base) }
        var plan = try intake.confirm(f,intake.preview(f,round,[intake.source(f,"a.png",1),intake.source(f,"b.png",2),intake.source(f,"c.png",3)]))
        let ids = strings(plan,"remaining_row_ids");XCTAssertEqual(ids.count,3)
        plan = try intake.capture(f,plan,[ids[0]])
        let params = intake.captureParams(plan,[ids[1]]),command = uuid()
        try f.router.dbQueue.write {try $0.execute(sql:"CREATE TRIGGER media_fail BEFORE INSERT ON commands BEGIN SELECT RAISE(ABORT,'receipt interruption'); END")}
        XCTAssertThrowsError(try f.call("media_intake_capture",params,as:f.worker,command:command))
        XCTAssertEqual(try f.rows("attachment").count,1)
        try f.router.dbQueue.write {try $0.execute(sql:"DROP TRIGGER media_fail")}
        try f.reopen()
        let resumed = try f.call("media_intake_capture",params,as:f.worker,command:command)
        XCTAssertTrue(strings(resumed,"committed_row_ids").contains(ids[1]));XCTAssertFalse(strings(resumed,"committed_row_ids").contains(ids[2]))
        _ = try f.call("media_intake_capture",params,as:f.worker,command:command)
        XCTAssertEqual(try f.rows("attachment").count,2)
        let done = try intake.capture(f,try intake.get(f,resumed))
        XCTAssertTrue(strings(done,"remaining_row_ids").isEmpty);XCTAssertEqual(try f.rows("attachment").count,3)
        // Interrupted publication: the manifest write fails, the service restarts, the same command finishes once.
        let observed = try f.get(round),before = try f.allState()
        var publish = f.observation(observed);publish["items"] = f.selection(observed,publish:true)
        XCTAssertEqual((publish["items"] as! [JSON]).count,3)
        let publishCommand = uuid()
        try f.router.dbQueue.write {try $0.execute(sql:"CREATE TRIGGER media_fail BEFORE INSERT ON records WHEN NEW.type='media_round_manifest' BEGIN SELECT RAISE(ABORT,'publication interruption'); END")}
        XCTAssertThrowsError(try f.call("media_round_publish",publish,command:publishCommand))
        XCTAssertEqual(try f.allState(),before)
        try f.router.dbQueue.write {try $0.execute(sql:"DROP TRIGGER media_fail")}
        try f.reopen()
        let published = try f.call("media_round_publish",publish,command:publishCommand),replay = try f.call("media_round_publish",publish,command:publishCommand)
        XCTAssertEqual(replay["replayed"] as? Bool,true)
        XCTAssertEqual((published["manifest"] as! JSON)["digest"] as? String,(replay["manifest"] as! JSON)["digest"] as? String)
        XCTAssertEqual((try f.get(round)["items"] as! [JSON]).filter {$0["published_target"] is JSON}.count,3)
        XCTAssertEqual(try f.rows("media_round_manifest").count,1)
        // Protected lossless export: every registered media family is exported byte-exact.
        let export = f.base.appendingPathComponent("export")
        _ = try f.router.handle(method:"export_project",params:["command_id":uuid(),"project_id":f.project,"path":export.path],caller:f.owner)
        let json = try JSONSerialization.jsonObject(with:Data(contentsOf:export.appendingPathComponent("project.json"))) as! JSON
        // Registered media families are exported byte-exact. Their non-media dependencies
        // (project, session, attachment, storage hold/job) are revised by the export itself
        // (the export's own hold and job), so attachments compare by exact identity and bytes.
        let families = try f.router.dbQueue.read {try Set(MediaRecordRegistry.envelopes($0).map(\.type))}.filter {$0.hasPrefix("media_")}
        XCTAssertTrue(families.isSuperset(of:["media_round","media_item","media_item_target","media_round_manifest","media_intake_row"]))
        for family in families.sorted() {
            let saved = try f.rows(family),exported = json[family] as? [JSON] ?? []
            XCTAssertFalse(saved.isEmpty,family)
            XCTAssertEqual(Set(try saved.map {try jsonString($0)}),Set(try exported.map {try jsonString($0)}),family)
        }
        let identity = {(rows: [JSON]) in Set(rows.map {"\($0["id"] ?? "")|\($0["sha256"] ?? "")|\($0["size"] ?? "")"})}
        XCTAssertEqual(identity(json["attachment"] as? [JSON] ?? []),identity(try f.rows("attachment")))
        XCTAssertEqual(identity(try f.rows("attachment")).count,3)
        XCTAssertTrue(try f.rows("storage_hold").filter {$0["purpose"] as? String == "project_export"}.allSatisfy {$0["state"] as? String == "released"})
        print("CL119_CASE interrupted_capture_publication_export_s=\(Date().timeIntervalSince(caseStart)) families=\(families.count)")
    }

    /// Item 3: bulk partial success, a lost reply, reversals and rejected-only rework in a
    /// round above 1,000 items; historical examples keep exact authority and provenance.
    func testBulkPartialSuccessLostReplyReversalsReworkAndExamplesAboveOneThousandItems() throws {
        try QualificationSuite.requireEnabled()
        let caseStart = Date(),(f,r) = try decisions.setup(1050)
        addTeardownBlock { try? FileManager.default.removeItem(at:f.base) }
        let setupSeconds = Date().timeIntervalSince(caseStart)
        let op = try f.call("media_bulk_prepare",decisions.params(f,r)),chunks = op["chunks"] as! [JSON]
        XCTAssertEqual(chunks.map {($0["items"] as! [JSON]).count},[200,200,200,200,200,50])
        _ = try decisions.apply(f,op,chunks[0])
        // Lost reply: the service restarts before the caller reads the result.
        try f.router.closeStore()
        f.router = try TestStore.router(root:f.root,serviceLease:f.storage.lease);f.storage.router = f.router
        XCTAssertEqual(strings(try decisions.bulkGet(f,op),"committed_item_ids").count,200)
        XCTAssertEqual(try decisions.apply(f,op,chunks[0])["replayed"] as? Bool,true)
        // Partial success: one changed item fails only its own chunk.
        let middleID = (chunks[2]["items"] as! [JSON])[17]["item_id"] as! String,middle = decisions.row(try f.get(r),middleID)
        _ = try f.call("media_item_update",["item_id":middleID,"expected_revision":middle["revision"]!,"title":"New label, same material"])
        for chunk in chunks.dropFirst() { _ = try decisions.apply(f,op,chunk) }
        let status = try decisions.bulkGet(f,op)
        XCTAssertEqual(strings(status,"committed_item_ids").count,850);XCTAssertEqual(strings(status,"failed_item_ids").count,200)
        XCTAssertTrue(strings(status,"uncommitted_item_ids").isEmpty)
        // Reversals of three committed passes keep their predecessors.
        let reversed = (chunks[0]["items"] as! [JSON]).prefix(3).map {$0["item_id"] as! String}
        var originals: [JSON] = []
        for id in reversed {
            let original = decisions.row(try f.get(r),id)["decision"] as! JSON;originals.append(original)
            _ = try f.call("media_decide",decisions.params(f,try f.get(r),ids:[id],disposition:"changes_requested"))
            XCTAssertEqual((decisions.row(try f.get(r),id)["decision"] as! JSON)["supersedes_decision_id"] as? String,original["id"] as? String)
        }
        let decided = try f.rows("media_owner_decision").count
        XCTAssertEqual(try decisions.apply(f,op,chunks[0])["replayed"] as? Bool,true)
        XCTAssertEqual(try f.rows("media_owner_decision").count,decided)
        for id in reversed { XCTAssertEqual(decisions.row(try f.get(r),id)["disposition"] as? String,"changes_requested") }
        // Retry only the failed chunk; a committed pass cannot be selected again.
        var refresh = decisions.params(f,try f.get(r),ids:strings(status,"failed_item_ids"));refresh["supersedes_operation_id"] = op["id"]
        let retry = try f.call("media_bulk_prepare",refresh)
        for chunk in retry["chunks"] as! [JSON] { _ = try decisions.apply(f,retry,chunk) }
        XCTAssertEqual(try f.rows("media_owner_decision").count,decided+200)
        let passing = (chunks[1]["items"] as! [JSON])[0]["item_id"] as! String
        var again = decisions.params(f,try f.get(r),ids:[passing]);again["supersedes_operation_id"] = op["id"]
        checks.checkError("MEDIA_BULK_COMMITTED") {try f.call("media_bulk_prepare",again)}
        // Rejected-only rework: Changes requested items get Drafts; a passing sibling is refused.
        let epicID = try rework.epic(f)
        checks.checkError("MEDIA_REWORK_INELIGIBLE") {try self.rework.preview(f,r,[passing],epic:epicID)}
        let shown = try rework.preview(f,r,reversed,epic:epicID),decisionsBefore = try jsonString(f.rows("media_owner_decision"))
        XCTAssertEqual((shown["items"] as! [JSON]).map {$0["action"] as? String},["create","create","create"])
        let created = try f.call("media_rework_create",rework.createInput(shown))
        XCTAssertEqual(strings(created,"created_task_ids").count,3)
        let heads = Set(try reversed.map {decisions.row(try f.get(r),$0)["last_decision_id"] as! String})
        XCTAssertEqual(Set((created["links"] as! [JSON]).map {$0["decision_id"] as! String}),heads)
        XCTAssertEqual(try jsonString(f.rows("media_owner_decision")),decisionsBefore)
        for original in originals { XCTAssertEqual(try jsonString(f.record(original["id"] as! String,"media_owner_decision")),try jsonString(original)) }
        let origins = Set(try f.rows("media_owner_decision").map {$0["origin"] as? String ?? "missing"})
        XCTAssertEqual(origins,["human_ui"])
        // Historical examples in a new round: display-only, owner provenance, no reversed target.
        let type = try f.rows("media_review_type")[0],current = try f.round(type),item = try f.item(current)
        let reversedTargets = Set(try reversed.map {(decisions.row(try f.get(r),$0)["published_target"] as! JSON)["id"] as! String})
        let state = try f.allState()
        var response = try lists.show(f,current,item),examples = response["examples"] as! [JSON]
        while let cursor = response["next_cursor"] as? String { response = try lists.show(f,current,item,cursor:cursor);examples += response["examples"] as! [JSON] }
        XCTAssertFalse(examples.isEmpty);XCTAssertLessThanOrEqual(examples.count,64)
        for example in examples {
            XCTAssertEqual(example["grants_current_approval"] as? Bool,false);XCTAssertEqual(example["round_id"] as? String,r["id"] as? String)
            XCTAssertEqual(example["decision_origin"] as? String,"human_ui");XCTAssertFalse(reversedTargets.contains(example["target_id"] as! String))
        }
        XCTAssertEqual(try f.allState(),state)
        print("CL119_CASE bulk_rework_examples items=1050 setup_s=\(setupSeconds) examples=\(examples.count) case_s=\(Date().timeIntervalSince(caseStart))")
    }
}
