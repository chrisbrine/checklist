import ChecklistContracts
import ChecklistTestSupport
import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

/// CL-446 uses disposable owned stores. Every delete enters the owner domain seam or
/// the public worker router; only the existing deletion cohort may move managed bytes.
final class MediaRoundDeletionTests: XCTestCase {
    typealias Fixture = MediaFrozenIntakeTests.Fixture
    let checks = MediaRoundTests()
    let channel = MediaWorkerChannelTests()
    let intake = MediaFrozenIntakeTests()
    let results = MediaRoundResultTests()
    let actions = MediaAgentRoundActionTests()

    func worker(_ f: Fixture,_ method: String,_ input: JSON = [:],as caller: Caller? = nil,command: String? = nil) throws -> JSON {
        try channel.worker(f,method,input,as:caller,command:command)
    }
    func input(_ f: Fixture,_ round: JSON,reason: String = "Retire this synthetic media pass") throws -> JSON {
        let current = try f.get(round)
        return ["round_id":current["id"]!,"expected_revision":current["revision"]!,"reason":reason]
    }
    func deletion(_ f: Fixture,_ round: JSON,as caller: Caller? = nil) throws -> JSON {
        try f.router.executeMediaCommand(method:"media_round_deletion_get",params:["project_id":f.project,"round_id":round["id"]!],caller:caller ?? f.owner)
    }
    func cancel(_ f: Fixture,_ round: JSON,archive: Bool = false) throws -> JSON {
        let current = try f.get(round)
        let canceled = try f.call("media_round_cancel",["round_id":current["id"]!,"expected_revision":current["revision"]!,"reason":"Synthetic cancellation"])
        return archive ? try f.call("media_round_archive",["round_id":round["id"]!,"expected_revision":canceled["revision"]!]) : canceled
    }
    func imageRound(_ f: Fixture,_ name: String,index: Int = 0) throws -> JSON {
        let round = try f.round(f.type(intake.imageSchema()))
        let plan = try intake.confirm(f,intake.preview(f,round,[intake.source(f,name,index)]))
        _ = try intake.capture(f,plan)
        return round
    }
    func trash(_ f: Fixture) throws {
        let path = f.base.appendingPathComponent("round-deletion-trash",isDirectory:true)
        try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
        f.router.ticketCleanupTrashRoot = path
    }
    func counts(_ f: Fixture,_ families: Set<String>) throws -> [String:Int] {
        try f.router.dbQueue.read { db in
            var result: [String:Int] = [:]
            for family in families { result[family] = try f.router.records(db,type:family,project:f.project).count }
            return result
        }
    }
    func exactRecords(_ f: Fixture,_ families: Set<String>) throws -> [String:String] {
        try f.router.dbQueue.read { db in
            var result: [String:String] = [:]
            for family in families {
                for record in try f.router.records(db,type:family,project:f.project) {
                    result[record["id"] as! String] = try jsonString(record)
                }
            }
            return result
        }
    }
    func assertRefusal(_ f: Fixture,_ code: String,_ body: () throws -> Any,file: StaticString = #filePath,line: UInt = #line) throws {
        let before = try f.allState()
        checks.checkError(code,body,file:file,line:line)
        XCTAssertEqual(try f.allState(),before,"A refused deletion changes no records, events or command receipts",file:file,line:line)
    }

    func testDraftAndOpenRoundDeletionRefuseWithoutWrites() throws {
        let f = try Fixture(),round = try f.round(f.type(checks.schema()))
        _ = try f.item(round)
        try assertRefusal(f,"MEDIA_ROUND_NOT_CLOSED") {try self.worker(f,"media_round_delete",self.input(f,round))}
        _ = try f.publish(round)
        try assertRefusal(f,"MEDIA_ROUND_NOT_CLOSED") {try f.call("media_round_delete",self.input(f,round))}
        try assertRefusal(f,"NOT_FOUND") {try self.worker(f,"media_round_delete",["round_id":uuid(),"expected_revision":1,"reason":"Unknown round"])}
        try assertRefusal(f,"NOT_FOUND") {try self.deletion(f,round)}
    }

    func testDeletionRequiresCurrentGrantWorkspaceRevisionReasonCommandAndSetting() throws {
        let f = try Fixture(),round = try cancel(f,f.round(f.type(checks.schema())))
        let p = try input(f,round)
        let denied = Caller(role:"worker",installation:f.worker.installation,projectIDs:[],sessionID:f.worker.sessionID,workspace:f.workspace.path)
        let outside = Caller(role:"worker",installation:f.worker.installation,projectIDs:[f.project],sessionID:f.worker.sessionID,workspace:f.base.path)
        let assistant = Caller(role:"assistant",installation:"assistant",projectIDs:[f.project],assistantGrants:[f.project:["read":true,"draft":true]])
        try assertRefusal(f,"FORBIDDEN") {try self.worker(f,"media_round_delete",p,as:denied)}
        try assertRefusal(f,"ROOT_MISMATCH") {try self.worker(f,"media_round_delete",p,as:outside)}
        try assertRefusal(f,"FORBIDDEN") {try self.worker(f,"media_round_delete",p,as:assistant)}
        try assertRefusal(f,"FORBIDDEN") {try self.worker(f,"media_round_deletion_get",["round_id":round["id"]!],as:assistant)}
        var stale = p;stale["expected_revision"] = (p["expected_revision"] as! Int) + 1
        try assertRefusal(f,"REVISION_CONFLICT") {try self.worker(f,"media_round_delete",stale)}
        for reason: Any in ["", " \n\t", NSNull(), 42] {
            var invalid = p;invalid["reason"] = reason
            try assertRefusal(f,"INVALID_INPUT") {try self.worker(f,"media_round_delete",invalid)}
        }
        var missing = p;missing["reason"] = nil
        try assertRefusal(f,"INVALID_INPUT") {try self.worker(f,"media_round_delete",missing)}
        var noRevision = p;noRevision["expected_revision"] = nil
        try assertRefusal(f,"REVISION_REQUIRED") {try f.call("media_round_delete",noRevision)}
        var noCommand = p;noCommand["project_id"] = f.project
        try assertRefusal(f,"INVALID_INPUT") {try f.router.handle(method:"media_round_delete",params:noCommand,caller:f.worker)}
        try assertRefusal(f,"INVALID_INPUT") {try self.worker(f,"media_round_delete",p,command:"not-a-uuid")}
        try MediaAgentTypeChangeTests().setAgentRuleChanges(f,"owner_only")
        try assertRefusal(f,"HUMAN_CHANNEL_REQUIRED") {try self.worker(f,"media_round_delete",p)}
        // The owner's trusted domain command remains available under owner_only.
        let deleted = try f.call("media_round_delete",p)
        XCTAssertEqual(deleted["deleted"] as? Bool,true)
        XCTAssertEqual(deleted["actor_kind"] as? String,"owner")
        XCTAssertEqual(deleted["actor"] as? String,f.owner.principal)
    }

    func testPendingLinkedOwnerRequestRefusesUntilCanceled() throws {
        let f = try Fixture(),task = try results.task(f),round = try f.round(f.type(checks.schema()))
        _ = try results.link(f,round,task)
        let request = try results.call(f,"human_request_create",["task_id":task["id"]!,"title":"Owner input for this pass","blocking":false,"questions":[["id":"q","type":"text","prompt":"Which pass should remain?"]]])
        _ = try cancel(f,round)
        let p = try input(f,round)
        try assertRefusal(f,"MEDIA_OWNER_REQUEST_PENDING") {try self.worker(f,"media_round_delete",p)}
        _ = try results.call(f,"human_request_cancel",["request_id":request["id"]!,"expected_revision":request["revision"]!,"reason":"Synthetic request is resolved"])
        let taskBefore = try jsonString(f.record(task["id"] as! String,"task"))
        let requestBefore = try jsonString(f.record(request["id"] as! String,"request"))
        XCTAssertEqual(try worker(f,"media_round_delete",p)["deleted"] as? Bool,true)
        XCTAssertEqual(try jsonString(f.record(task["id"] as! String,"task")),taskBefore)
        XCTAssertEqual(try jsonString(f.record(request["id"] as! String,"request")),requestBefore)
    }

    func testIncomingSuccessorAndTicketRecordOrManagedFileReferencesRefuse() throws {
        let f = try Fixture(),round = try imageRound(f,"referenced.png")
        _ = try f.publish(round);try f.acceptEach(round)
        let view = try f.get(round),item = (view["items"] as! [JSON])[0]
        var successor = actions.fence(view);successor["source_round_id"] = successor.removeValue(forKey:"round_id")
        successor["title"] = "A live successor";successor["items"] = [["item_id":item["id"]!]]
        _ = try f.call("media_round_successor",successor)
        _ = try cancel(f,round)
        try assertRefusal(f,"MEDIA_ROUND_REFERENCED") {try self.worker(f,"media_round_delete",self.input(f,round))}

        // A ticket can retain an exact stored media record or a managed-file authority.
        // These legacy structural references are seeded only inside this owned fixture.
        let own = try imageRound(f,"ticket-reference.png",index:1),task = try results.task(f)
        let ownItem = try XCTUnwrap((f.get(own)["items"] as? [JSON])?.first)
        let candidateID = try XCTUnwrap(strings(ownItem["draft_target"] as! JSON,"candidate_ids").first)
        let candidate = try f.record(candidateID,"media_candidate")
        let attachmentID = try XCTUnwrap((candidate["slots"] as? [JSON])?.first?["attachment_id"] as? String)
        let attachment = try f.record(attachmentID,"attachment")
        _ = try cancel(f,own)
        for reference: JSON in [["media_candidate_id":candidate["id"]!],["managed_path":attachment["path"]!]] {
            try f.router.dbQueue.writeWithoutTransaction {db in
                try f.router.withValidatedDomainTransaction(db) {
                    var linked = task;linked["media_reference"] = reference
                    try f.router.save(db,linked,type:"task");return .commit
                }
            }
            try assertRefusal(f,"MEDIA_ROUND_REFERENCED") {try f.call("media_round_delete",self.input(f,own))}
        }
        try f.router.dbQueue.writeWithoutTransaction {db in
            try f.router.withValidatedDomainTransaction(db) {try f.router.save(db,task,type:"task");return .commit}
        }
        XCTAssertEqual(try f.call("media_round_delete",input(f,own))["deleted"] as? Bool,true)
    }

    /// Populate every round-owned media family through ordinary domain actions.
    func completeRound(_ f: Fixture) throws -> (round: JSON,task: JSON,oldCommand: String,oldInput: JSON) {
        let task = try results.task(f),round = try imageRound(f,"inventory.png")
        _ = try results.link(f,round,task)
        _ = try f.publish(round)
        let first = try f.get(round,as:f.worker)
        _ = try f.call("media_suggest",f.decisionParams(first,disposition:"needs_look"),as:f.worker)
        _ = try f.call("media_context_approve",["kind":"direction","round_id":round["id"]!,"body":"Private synthetic direction to erase with this round"])
        _ = try f.reconcile(round,action:"keep")
        let current = try f.get(round)
        var bulkInput = f.decisionParams(current,disposition:"changes_requested")
        bulkInput["note"] = "Private synthetic decision to erase with this round"
        let operation = try f.call("media_bulk_prepare",bulkInput),chunk = (operation["chunks"] as! [JSON])[0]
        _ = try f.call("media_bulk_apply",["operation_id":operation["id"]!,"chunk_id":chunk["id"]!],command:chunk["command_id"] as? String)
        let workerView = try worker(f,"media_round_get",["round_id":round["id"]!]),member = (workerView["items"] as! [JSON])[0]
        var followUp = actions.fence(workerView)
        followUp["items"] = [["item_id":member["id"]!,"expected_revision":member["expected_revision"]!,"decision_id":member["decision_id"]!]]
        followUp["reason"] = "The separate production pass handles this work"
        _ = try worker(f,"media_follow_up_record",followUp)
        _ = try f.call("media_round_send_result",results.sendInput(f,round))
        _ = try f.call("media_round_finish",actions.fence(f.get(round)))
        let closed = try f.get(round),archiveInput: JSON = ["round_id":round["id"]!,"expected_revision":closed["revision"]!],oldCommand = uuid()
        let archived = try f.call("media_round_archive",archiveInput,command:oldCommand)
        return (archived,task,oldCommand,archiveInput)
    }

    func testFullInventoryDeletionKeepsOneContentFreeEventTicketsAndOtherRoundAndReplays() throws {
        let f = try Fixture();try trash(f)
        let (round,task,oldCommand,oldInput) = try completeRound(f)
        let families = MediaRecordRegistry.families.subtracting(["media_review_type","media_review_type_revision"])
        let ownedCounts = try counts(f,families)
        let ownershipCounts = try counts(f,["attachment","storage_hold","storage_job"])
        for family in families {XCTAssertGreaterThan(ownedCounts[family] ?? 0,0,"Fixture must exercise \(family)")}
        let owned = try exactRecords(f,families.union(["attachment","storage_hold","storage_job"]))
        let other = try imageRound(f,"retained-other-round.png",index:42)
        let beforeCounts = try counts(f,families)
        let retained = try exactRecords(f,families.union(["attachment","storage_hold","storage_job"])).filter {owned[$0.key] == nil}
        let ticketsBefore = try exactRecords(f,["task","message","delivery"])
        let typesBefore = try exactRecords(f,["media_review_type","media_review_type_revision"])
        let p = try input(f,round),command = uuid(),deleted = try worker(f,"media_round_delete",p,command:command)
        XCTAssertEqual(deleted["deleted"] as? Bool,true)
        XCTAssertEqual(deleted["round_id"] as? String,round["id"] as? String)
        XCTAssertEqual(deleted["project_id"] as? String,f.project)
        XCTAssertEqual(deleted["actor"] as? String,f.worker.principal)
        XCTAssertEqual(deleted["actor_kind"] as? String,"agent")
        XCTAssertEqual(deleted["reason"] as? String,p["reason"] as? String)
        let reported = try XCTUnwrap(deleted["counts"] as? [String:Int]),afterCounts = try counts(f,families)
        for family in families {
            XCTAssertEqual(beforeCounts[family]! - afterCounts[family]!,ownedCounts[family],family)
            XCTAssertEqual(reported[family],ownedCounts[family],family)
        }
        for family in ["attachment","storage_hold","storage_job"] {
            XCTAssertEqual(reported[family],ownershipCounts[family],family)
        }
        let surviving = try exactRecords(f,families.union(["attachment","storage_hold","storage_job"]))
        for id in owned.keys {XCTAssertNil(surviving[id],"Round-owned record survived: \(id)")}
        for (id,value) in retained {XCTAssertEqual(surviving[id],value,id)}
        XCTAssertEqual(try exactRecords(f,["task","message","delivery"]),ticketsBefore)
        XCTAssertEqual(try exactRecords(f,["media_review_type","media_review_type_revision"]),typesBefore)
        XCTAssertEqual(try f.record(task["id"] as! String,"task")["title"] as? String,task["title"] as? String)
        XCTAssertEqual(try f.get(other)["id"] as? String,other["id"] as? String)
        try assertRefusal(f,"NOT_FOUND") {try f.get(round)}
        try assertRefusal(f,"NOT_FOUND") {try self.worker(f,"media_round_get",["round_id":round["id"]!])}
        for state in ["draft","open","closed","canceled","archived"] {
            let list = try f.router.executeMediaOwnerChannel(method:"media_round_page",params:["project_id":f.project,"type_id":round["type_id"]!,"state":state],caller:f.owner)
            XCTAssertFalse((list["rows"] as! [JSON]).contains {$0["id"] as? String == round["id"] as? String},state)
        }
        let events = try f.router.dbQueue.read {db in
            try Row.fetchAll(db,sql:"SELECT kind,data FROM events WHERE entity_id=? ORDER BY seq",arguments:[round["id"] as! String])
        }
        XCTAssertEqual(events.count,1)
        XCTAssertEqual(events.first?["kind"] as? String,"media_round_deleted")
        let history = try jsonObject(XCTUnwrap(events.first?["data"] as? String))
        XCTAssertEqual(history["round_id"] as? String,round["id"] as? String)
        XCTAssertEqual(history["actor"] as? String,f.worker.principal)
        XCTAssertEqual(history["reason"] as? String,p["reason"] as? String)
        XCTAssertEqual(history["counts"] as? [String:Int],reported)
        for key in ["title","items","candidates","manifest","note","body","decisions","record_references"] {XCTAssertNil(history[key],key)}
        let historyText = try jsonString(history)
        XCTAssertFalse(historyText.contains("Private synthetic"));XCTAssertFalse(historyText.contains("inventory.png"))
        try assertRefusal(f,"COMMAND_RESULT_EXPIRED") {try f.call("media_round_archive",oldInput,command:oldCommand)}
        try MediaAgentTypeChangeTests().setAgentRuleChanges(f,"owner_only")
        let beforeReplay = try f.allState(),replayed = try worker(f,"media_round_delete",p,command:command)
        XCTAssertEqual(replayed["replayed"] as? Bool,true)
        var original = replayed;original.removeValue(forKey:"replayed")
        XCTAssertEqual(try jsonString(original),try jsonString(deleted))
        var changed = p;changed["reason"] = "A changed deletion intent"
        checks.checkError("IDEMPOTENCY_CONFLICT") {try self.worker(f,"media_round_delete",changed,command:command)}
        XCTAssertEqual(try f.allState(),beforeReplay)
        let later = try worker(f,"media_round_deletion_get",["round_id":round["id"]!])
        XCTAssertEqual(later["round_id"] as? String,round["id"] as? String)
        XCTAssertEqual(later["counts"] as? [String:Int],reported)
    }

    func testManagedFilesHoldWithoutBackupThenMoveThroughVerifiedTrashReceipt() throws {
        let f = try Fixture();try trash(f)
        let round = try imageRound(f,"trash-original.png"),attachment = try XCTUnwrap(f.rows("attachment").first)
        let original = try XCTUnwrap(f.router.ownerManagedPathProjection(attachment,caller:f.owner)["path"] as? String)
        let source = f.workspace.appendingPathComponent("trash-original.png"),sourceBytes = try Data(contentsOf:source)
        _ = try cancel(f,round,archive:true)
        let p = try input(f,round),command = uuid(),deleted = try worker(f,"media_round_delete",p,command:command)
        let receiptID = try XCTUnwrap(deleted["byte_deletion_receipt_id"] as? String)
        let receipt = try f.record(receiptID,"storage_job")
        XCTAssertEqual(receipt["kind"] as? String,"ticket_object_delete")
        let objects = try XCTUnwrap(receipt["objects"] as? [JSON])
        XCTAssertFalse(objects.isEmpty)
        let managed = objects.filter {($0["relative_path"] as? String ?? "").hasPrefix("objects/")}
        XCTAssertFalse(managed.isEmpty)
        XCTAssertTrue(managed.allSatisfy {$0["disposal"] as? String == "trash"})
        let staging = (deleted["files"] as? [JSON] ?? []).filter {($0["relative_path"] as? String ?? "").hasPrefix("staging/")}
        XCTAssertTrue(staging.allSatisfy {$0["status"] as? String == "kept" && strings($0,"reasons").contains("staging_requires_import_recovery")})
        let held = try XCTUnwrap((deleted["files"] as? [JSON])?.first {$0["representation"] as? String == "original"})
        XCTAssertEqual(held["status"] as? String,"held")
        XCTAssertTrue(strings(held,"reasons").contains("backup_required"))
        _ = try f.router.runTicketObjectDeletionCohort()
        let unbacked = try deletion(f,round)
        XCTAssertEqual(((unbacked["files"] as? [JSON])?.first {$0["representation"] as? String == "original"})?["status"] as? String,"held")
        XCTAssertTrue(FileManager.default.fileExists(atPath:original))
        XCTAssertTrue(try f.rows("attachment").isEmpty,"Metadata leaves in the delete transaction while the receipt owns pending bytes")
        try ticketCleanupBackupTemplate(f.router,objects:objects)
        _ = try f.router.runTicketObjectDeletionCohort()
        let completed = try f.record(receiptID,"storage_job")
        let movedObject = try XCTUnwrap((completed["objects"] as? [JSON])?.first {$0["representation"] as? String == "original"})
        XCTAssertEqual(movedObject["state"] as? String,"removed")
        XCTAssertEqual(movedObject["moved_to_trash"] as? Bool,true)
        let destination = try XCTUnwrap(movedObject["trash_path"] as? String)
        XCTAssertTrue(destination.hasPrefix(f.router.ticketCleanupTrashRoot!.path + "/"))
        XCTAssertEqual(ChecklistCore.hash(try Data(contentsOf:URL(fileURLWithPath:destination))),attachment["sha256"] as? String)
        XCTAssertFalse(FileManager.default.fileExists(atPath:original))
        XCTAssertEqual(try Data(contentsOf:source),sourceBytes,"The selected source is outside the managed deletion scope")
        let later = try worker(f,"media_round_deletion_get",["round_id":round["id"]!])
        let moved = try XCTUnwrap((later["files"] as? [JSON])?.first {$0["representation"] as? String == "original"})
        XCTAssertEqual(moved["status"] as? String,"moved")
        XCTAssertFalse((moved["reason"] as? String ?? "").isEmpty)
        let replay = try worker(f,"media_round_delete",p,command:command)
        XCTAssertEqual(((replay["files"] as? [JSON])?.first {$0["representation"] as? String == "original"})?["status"] as? String,"held","Replay keeps the first committed outcome; deletion_get reports current cleanup")
    }

    func testKeepOriginalReportsKeptAndPartialIntakeLosesItsEntireRecordGraph() throws {
        let f = try Fixture();try trash(f)
        let round = try f.round(f.type(intake.imageSchema()))
        var plan = try intake.confirm(f,intake.preview(f,round,[intake.source(f,"partial-first.png",1),intake.source(f,"partial-second.png",2)]))
        plan = try intake.capture(f,plan,Array(strings(plan,"remaining_row_ids").prefix(1)))
        XCTAssertEqual(strings(plan,"remaining_row_ids").count,1)
        let attachment = try XCTUnwrap(f.rows("attachment").first)
        let original = try XCTUnwrap(f.router.ownerManagedPathProjection(attachment,caller:f.owner)["path"] as? String)
        try f.router.dbQueue.write {db in
            var kept = attachment;kept["keep_original"] = true
            try f.router.save(db,f.router.revised(kept),type:"attachment")
        }
        _ = try cancel(f,round)
        let backup = f.base.appendingPathComponent("keep-original-backup")
        _ = try f.router.handle(method:"backup_create",params:["command_id":uuid(),"path":backup.path],caller:f.owner)
        let deleted = try f.call("media_round_delete",input(f,round))
        let originalReport = try XCTUnwrap((deleted["files"] as? [JSON])?.first {$0["representation"] as? String == "original"})
        XCTAssertEqual(originalReport["status"] as? String,"kept")
        XCTAssertTrue(strings(originalReport,"reasons").contains("keep_original"))
        for family in ["media_round","media_item","media_candidate","media_item_target","media_intake","media_intake_plan","media_intake_row","media_intake_chunk","attachment","storage_hold"] {
            XCTAssertTrue(try f.rows(family).isEmpty,family)
        }
        XCTAssertTrue(try f.rows("storage_job").allSatisfy {$0["kind"] as? String == "ticket_object_delete"})
        _ = try f.router.runTicketObjectDeletionCohort()
        XCTAssertTrue(FileManager.default.fileExists(atPath:original))
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.workspace.appendingPathComponent("partial-second.png").path))
        let later = try deletion(f,round)
        XCTAssertEqual(((later["files"] as? [JSON])?.first {$0["representation"] as? String == "original"})?["status"] as? String,"kept")
    }

    func testDeletionTransactionRollsBackIfAnyOwnedRecordCannotLeave() throws {
        let f = try Fixture(),round = try f.round(f.type(checks.schema()))
        let item = try f.item(round);_ = try cancel(f,round)
        let itemID = item["id"] as! String
        try f.router.dbQueue.write {db in
            try db.execute(sql:"CREATE TEMP TRIGGER media_delete_fixture_failure BEFORE DELETE ON records WHEN OLD.id='" + itemID + "' BEGIN SELECT RAISE(ABORT,'synthetic record deletion failure'); END")
        }
        let p = try input(f,round),before = try f.allState(),command = uuid()
        XCTAssertThrowsError(try worker(f,"media_round_delete",p,command:command))
        XCTAssertEqual(try f.allState(),before)
        try f.router.dbQueue.write {try $0.execute(sql:"DROP TRIGGER media_delete_fixture_failure")}
        XCTAssertEqual(try worker(f,"media_round_delete",p,command:command)["deleted"] as? Bool,true,"A rolled-back attempt did not consume the command ID")
    }

    func testUnrelatedCorpusLargerThanSelectedCleanupBudgetDoesNotBlockDeletion() throws {
        let f = try Fixture(),round = try cancel(f,f.round(f.type(checks.schema())))
        let padding = String(repeating:"Unrelated retained prose. ",count:45_000)
        try f.router.dbQueue.writeWithoutTransaction {db in
            try f.router.withValidatedDomainTransaction(db) {
                for index in 0..<20 {
                    try f.router.save(db,["id":"media-delete-padding-\(index)","project_id":f.project,"revision":1,"body":padding],type:"message")
                }
                return .commit
            }
        }
        func corpus() throws -> [Row] {
            try f.router.dbQueue.read {db in
                try Row.fetchAll(db,sql:"SELECT id,revision,length(CAST(data AS BLOB)) AS bytes FROM records WHERE id LIKE 'media-delete-padding-%' ORDER BY id")
            }
        }
        let before = try corpus()
        XCTAssertEqual(before.count,20)
        XCTAssertGreaterThan(before.reduce(0) {$0 + ($1["bytes"] as Int)},TicketCleanupInventory.byteLimit)
        XCTAssertEqual(try worker(f,"media_round_delete",input(f,round))["deleted"] as? Bool,true)
        XCTAssertEqual(try corpus(),before)
        XCTAssertEqual(try f.record("media-delete-padding-0","message")["body"] as? String,padding)
    }

    func testCanonicallyEquivalentByteDistinctItemIDsStayInTheirOwnRounds() throws {
        let f = try Fixture(),type = try f.type(checks.schema())
        let first = try cancel(f,f.round(type)),second = try cancel(f,f.round(type))
        let firstID = "identity-\u{00E9}",secondID = "identity-e\u{0301}"
        XCTAssertEqual(firstID,secondID,"Swift text equality deliberately cannot identify these storage rows")
        XCTAssertNotEqual(Data(firstID.utf8),Data(secondID.utf8))
        var firstItem = f.router.mediaRecord(["round_id":first["id"]!,"title":"Delete this item","state":"draft"],project:f.project,caller:f.owner,references:[try f.router.mediaRef("media_round",first)])
        var secondItem = f.router.mediaRecord(["round_id":second["id"]!,"title":"Keep this item","state":"draft"],project:f.project,caller:f.owner,references:[try f.router.mediaRef("media_round",second)])
        firstItem["id"] = firstID;secondItem["id"] = secondID
        try f.router.dbQueue.writeWithoutTransaction {db in
            try f.router.withValidatedDomainTransaction(db) {
                try f.router.mediaWrite(db,firstItem,type:"media_item")
                try f.router.mediaWrite(db,secondItem,type:"media_item");return .commit
            }
        }
        func itemKeys() throws -> Set<Data> {
            try f.router.dbQueue.read {db in
                Set(try Data.fetchAll(db,sql:"SELECT CAST(id AS BLOB) FROM records WHERE type='media_item'"))
            }
        }
        XCTAssertEqual(try itemKeys(),Set([Data(firstID.utf8),Data(secondID.utf8)]))
        let secondBefore = try jsonString(f.record(secondID,"media_item"))
        let deleted = try worker(f,"media_round_delete",["round_id":first["id"]!,"expected_revision":first["revision"]!,"reason":"Delete only the exact first round"])
        XCTAssertEqual((deleted["counts"] as? [String:Int])?["media_item"],1)
        XCTAssertEqual(try itemKeys(),Set([Data(secondID.utf8)]))
        XCTAssertEqual(try jsonString(f.record(secondID,"media_item")),secondBefore)
        XCTAssertEqual(try f.record(second["id"] as! String,"media_round")["state"] as? String,"canceled")
    }

    func testDeletingCanceledManagedSuccessorPreservesBorrowedPredecessorRecordsAndFiles() throws {
        let f = try Fixture();try trash(f)
        let predecessor = try imageRound(f,"predecessor-original.png")
        _ = try f.publish(predecessor);try f.acceptEach(predecessor)
        _ = try f.call("media_round_finish",actions.fence(f.get(predecessor)))
        let families = MediaRecordRegistry.families.union(["attachment","storage_job","storage_hold"])
        let retained = try exactRecords(f,families)
        let attachment = try XCTUnwrap(f.rows("attachment").first)
        let original = try XCTUnwrap(f.router.ownerManagedPathProjection(attachment,caller:f.owner)["path"] as? String)
        let view = try f.get(predecessor),item = (view["items"] as! [JSON])[0]
        var p = actions.fence(view);p["source_round_id"] = p.removeValue(forKey:"round_id")
        p["title"] = "Disposable successor";p["items"] = [["item_id":item["id"]!,"carry_decision_id":(item["decision"] as! JSON)["id"]!]]
        let successor = try f.call("media_round_successor",p)
        _ = try cancel(f,successor)
        let deleted = try worker(f,"media_round_delete",input(f,successor))
        XCTAssertEqual(deleted["deleted"] as? Bool,true)
        let after = try exactRecords(f,families)
        for (id,value) in retained {XCTAssertEqual(after[id],value,id)}
        XCTAssertEqual(try f.get(predecessor)["state"] as? String,"closed")
        XCTAssertEqual(try f.rows("attachment").count,1)
        _ = try f.router.runTicketObjectDeletionCohort()
        XCTAssertTrue(FileManager.default.fileExists(atPath:original))
        XCTAssertFalse((try deletion(f,successor)["files"] as? [JSON] ?? []).contains {$0["status"] as? String == "moved"})
    }

    func testTrustedOwnerDeletesPublishedSuccessorOwnAnchorsAndKeepsPredecessorOriginal() throws {
        let f = try Fixture();try trash(f)
        let predecessor = try imageRound(f,"published-predecessor.png")
        _ = try f.publish(predecessor);try f.acceptEach(predecessor)
        _ = try f.call("media_round_finish",actions.fence(f.get(predecessor)))
        let families = MediaRecordRegistry.families.union(["attachment","storage_job","storage_hold"])
        let retained = try exactRecords(f,families)
        let attachment = try XCTUnwrap(f.rows("attachment").first)
        let original = try XCTUnwrap(f.router.ownerManagedPathProjection(attachment,caller:f.owner)["path"] as? String)
        let before = try f.get(predecessor),item = (before["items"] as! [JSON])[0],predecessorTarget = item["published_target"] as! JSON
        var successorInput = actions.fence(before);successorInput["source_round_id"] = successorInput.removeValue(forKey:"round_id")
        successorInput["title"] = "Published disposable successor";successorInput["items"] = [["item_id":item["id"]!]]
        let successor = try f.call("media_round_successor",successorInput)
        _ = try f.publish(successor)
        let published = try f.get(successor),target = ((published["items"] as! [JSON])[0]["published_target"] as! JSON)
        let ownerID = try XCTUnwrap(target["attachment_owner_id"] as? String),holdIDs = strings(target,"attachment_reference_ids")
        XCTAssertNotEqual(Data(ownerID.utf8),Data((predecessorTarget["attachment_owner_id"] as! String).utf8))
        XCTAssertFalse(holdIDs.isEmpty)
        XCTAssertEqual(try f.record(ownerID,"storage_job")["owner_kind"] as? String,"media_target")
        for id in holdIDs {XCTAssertEqual(try f.record(id,"storage_hold")["state"] as? String,"active")}
        _ = try cancel(f,successor)
        var p = try input(f,successor);p["project_id"] = f.project;p["command_id"] = uuid()
        let reply = try f.router.handle(method:"media_round_delete",params:p,caller:f.owner)
        XCTAssertEqual(reply["command_id"] as? String,p["command_id"] as? String)
        let deleted = try XCTUnwrap(reply["data"] as? JSON)
        XCTAssertEqual(deleted["deleted"] as? Bool,true)
        XCTAssertEqual(deleted["actor_kind"] as? String,"owner")
        XCTAssertEqual(deleted["actor"] as? String,f.owner.principal)
        XCTAssertEqual((deleted["counts"] as? [String:Int])?["storage_job"],1)
        XCTAssertEqual((deleted["counts"] as? [String:Int])?["storage_hold"],holdIDs.count)
        checks.checkError("NOT_FOUND") {try f.record(ownerID,"storage_job")}
        for id in holdIDs {checks.checkError("NOT_FOUND") {try f.record(id,"storage_hold")}}
        let after = try exactRecords(f,families)
        for (id,value) in retained {XCTAssertEqual(after[id],value,id)}
        XCTAssertEqual(try f.get(predecessor)["state"] as? String,"closed")
        XCTAssertEqual(try f.rows("attachment").count,1)
        _ = try f.router.runTicketObjectDeletionCohort()
        XCTAssertTrue(FileManager.default.fileExists(atPath:original))
        XCTAssertFalse((try deletion(f,successor)["files"] as? [JSON] ?? []).contains {$0["status"] as? String == "moved"})
    }

    func testFinalizedImportWithoutAttachmentIsInventoriedAndMovesOnlyThroughTrash() throws {
        let f = try Fixture();try trash(f)
        let round = try f.round(f.type(intake.imageSchema()))
        let plan = try intake.confirm(f,intake.preview(f,round,[intake.source(f,"finalized-orphan.png")]))
        try f.router.dbQueue.write {db in
            try db.execute(sql:"CREATE TEMP TRIGGER media_delete_fail_capture BEFORE INSERT ON commands BEGIN SELECT RAISE(ABORT,'synthetic capture receipt interruption'); END")
        }
        XCTAssertThrowsError(try intake.capture(f,plan))
        try f.router.dbQueue.write {try $0.execute(sql:"DROP TRIGGER media_delete_fail_capture")}
        XCTAssertTrue(try f.rows("attachment").isEmpty);XCTAssertTrue(try f.rows("media_item").isEmpty)
        let job = try XCTUnwrap(f.rows("storage_job").first {$0["kind"] as? String == "attachment_import"})
        XCTAssertEqual(job["state"] as? String,"finalized")
        let imported = try XCTUnwrap((job["objects"] as? [JSON])?.first {$0["representation"] as? String == "original"})
        let relative = try XCTUnwrap(imported["final"] as? String),original = f.root.appendingPathComponent(relative)
        XCTAssertTrue(FileManager.default.fileExists(atPath:original.path))
        _ = try cancel(f,round)
        let deleted = try worker(f,"media_round_delete",input(f,round))
        let receipt = try f.record(XCTUnwrap(deleted["byte_deletion_receipt_id"] as? String),"storage_job")
        let objects = try XCTUnwrap(receipt["objects"] as? [JSON])
        let report = try XCTUnwrap((deleted["files"] as? [JSON])?.first {$0["relative_path"] as? String == relative})
        XCTAssertEqual(report["status"] as? String,"held")
        XCTAssertTrue(strings(report,"reasons").contains("backup_required"))
        XCTAssertTrue(try f.rows("storage_job").allSatisfy {$0["kind"] as? String == "ticket_object_delete"})
        XCTAssertTrue(try f.rows("media_intake").isEmpty)
        try ticketCleanupBackupTemplate(f.router,objects:objects)
        _ = try f.router.runTicketObjectDeletionCohort()
        let completed = try f.record(receipt["id"] as! String,"storage_job")
        let moved = try XCTUnwrap((completed["objects"] as? [JSON])?.first {$0["relative_path"] as? String == relative})
        XCTAssertEqual(moved["moved_to_trash"] as? Bool,true)
        XCTAssertFalse(FileManager.default.fileExists(atPath:original.path))
        XCTAssertEqual(ChecklistCore.hash(try Data(contentsOf:URL(fileURLWithPath:try XCTUnwrap(moved["trash_path"] as? String)))),imported["sha256"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.workspace.appendingPathComponent("finalized-orphan.png").path))
    }

    func testActiveReaderLeaseHoldsDeletedRoundBytesUntilReleased() throws {
        let f = try Fixture();try trash(f)
        let round = try imageRound(f,"reader-original.png")
        _ = try f.publish(round)
        let view = try f.get(round),target = ((view["items"] as! [JSON])[0]["published_target"] as! JSON)
        let referenceID = try XCTUnwrap(strings(target,"attachment_reference_ids").first)
        let owner = try f.router.dbQueue.read {try f.router.mediaOwnerValue($0,id:target["attachment_owner_id"] as! String,project:f.project)}
        let lease = try f.router.acquireMediaAttachmentReadLease(project:f.project,referenceID:referenceID,owner:owner,caller:f.owner)
        let original = try XCTUnwrap(lease.attachment["path"] as? String)
        _ = try cancel(f,round)
        let deleted = try worker(f,"media_round_delete",input(f,round))
        let receipt = try f.record(XCTUnwrap(deleted["byte_deletion_receipt_id"] as? String),"storage_job")
        try ticketCleanupBackupTemplate(f.router,objects:receipt["objects"] as! [JSON])
        _ = try f.router.runTicketObjectDeletionCohort()
        let held = try XCTUnwrap((deletion(f,round)["files"] as? [JSON])?.first {$0["representation"] as? String == "original"})
        XCTAssertEqual(held["status"] as? String,"held")
        XCTAssertTrue(strings(held,"reasons").contains("reader_lease"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:original))
        try ArchiveStorageGate.withExclusive(root:f.root) {permit in
            try f.router.dbQueue.write {db in
                try f.router.releaseMediaReadHold(db,permit:permit,project:f.project,id:lease.id,caller:f.owner)
            }
        }
        _ = try f.router.runTicketObjectDeletionCohort()
        XCTAssertEqual(((try deletion(f,round)["files"] as? [JSON])?.first {$0["representation"] as? String == "original"})?["status"] as? String,"moved")
        XCTAssertFalse(FileManager.default.fileExists(atPath:original))
    }

    func testExpiredReaderHoldsWithDictionaryKeyAndAbsolutePathResumeOrdinaryCleanup() throws {
        let f = try Fixture();try trash(f)
        let round = try imageRound(f,"expiring-reader-original.png")
        _ = try f.publish(round)
        let backup = f.base.appendingPathComponent("expiring-reader-backup")
        _ = try f.router.handle(method:"backup_create",params:["command_id":uuid(),"path":backup.path],caller:f.owner)
        let view = try f.get(round),target = ((view["items"] as! [JSON])[0]["published_target"] as! JSON)
        let referenceID = try XCTUnwrap(strings(target,"attachment_reference_ids").first)
        let owner = try f.router.dbQueue.read {try f.router.mediaOwnerValue($0,id:target["attachment_owner_id"] as! String,project:f.project)}
        let keyLease = try f.router.acquireMediaAttachmentReadLease(project:f.project,referenceID:referenceID,owner:owner,caller:f.owner)
        let pathLease = try f.router.acquireMediaAttachmentReadLease(project:f.project,referenceID:referenceID,owner:owner,caller:f.owner)
        let attachmentID = try XCTUnwrap(keyLease.attachment["id"] as? String)
        let original = try XCTUnwrap(keyLease.attachment["path"] as? String)
        // Legacy typed holds can express the same reader authority through a
        // dictionary key or an absolute managed path. Give each only that token.
        try f.router.dbQueue.writeWithoutTransaction {db in
            try f.router.withValidatedDomainTransaction(db) {
                for id in [keyLease.id,pathLease.id] {
                    var hold = try f.router.record(db,id,type:"storage_hold")
                    hold.removeValue(forKey:"attachment_id");hold.removeValue(forKey:"owner_reference_id")
                    if id == keyLease.id {hold["references"] = [attachmentID:true]}
                    else {hold["managed_path"] = original}
                    try f.router.save(db,f.router.revised(hold),type:"storage_hold")
                }
                return .commit
            }
        }
        _ = try cancel(f,round)
        let deleted = try worker(f,"media_round_delete",input(f,round))
        let receiptID = try XCTUnwrap(deleted["byte_deletion_receipt_id"] as? String)
        let receipt = try f.record(receiptID,"storage_job")
        let held = try XCTUnwrap((receipt["objects"] as? [JSON])?.first {$0["representation"] as? String == "original"})
        XCTAssertEqual(receipt["state"] as? String,"completed")
        XCTAssertEqual(held["state"] as? String,"retained")
        XCTAssertTrue(strings(held,"reasons").contains("reader_lease"))
        XCTAssertEqual(Set(strings(held,"reader_hold_ids").map {Data($0.utf8)}),Set([Data(keyLease.id.utf8),Data(pathLease.id.utf8)]))
        func ready() throws -> Bool {
            try f.router.dbQueue.read {db in
                try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM records WHERE id=CAST(? AS TEXT) AND " + CommandRouter.ticketObjectDeletionReadySQL + ")",arguments:[Data(receiptID.utf8)]) == true
            }
        }
        XCTAssertFalse(try ready(),"Active saved reader IDs keep a completed receipt out of the ready queue")
        _ = try f.router.runTicketObjectDeletionCohort()
        XCTAssertEqual(try jsonString(f.record(receiptID,"storage_job")),try jsonString(receipt),"An ordinary maintenance turn must not repeatedly rearm active reader holds")
        XCTAssertTrue(FileManager.default.fileExists(atPath:original))
        func expire(_ id: String) throws {
            try f.router.dbQueue.writeWithoutTransaction {db in
                try f.router.withValidatedDomainTransaction(db) {
                    var hold = try f.router.record(db,id,type:"storage_hold")
                    hold["expires_at"] = Date().addingTimeInterval(-60).timeIntervalSince1970
                    try f.router.save(db,f.router.revised(hold),type:"storage_hold");return .commit
                }
            }
        }
        try expire(keyLease.id)
        XCTAssertTrue(try ready(),"The preview can resume independently after its only reader expires")
        _ = try f.router.runTicketObjectDeletionCohort()
        let stillHeld = try XCTUnwrap((f.record(receiptID,"storage_job")["objects"] as? [JSON])?.first {$0["representation"] as? String == "original"})
        XCTAssertEqual(stillHeld["state"] as? String,"retained")
        XCTAssertEqual(strings(stillHeld,"reader_hold_ids"),[pathLease.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath:original),"The absolute-path reader still holds the original")
        XCTAssertFalse(try ready(),"The remaining active reader does not cause repeated rearm")
        try expire(pathLease.id)
        XCTAssertTrue(try ready(),"Expiry alone admits the completed receipt without a new backup or manual rearm")
        _ = try f.router.runTicketObjectDeletionCohort()
        let completed = try f.record(receiptID,"storage_job")
        let moved = try XCTUnwrap((completed["objects"] as? [JSON])?.first {$0["representation"] as? String == "original"})
        XCTAssertEqual(moved["moved_to_trash"] as? Bool,true)
        XCTAssertEqual(moved["state"] as? String,"removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath:original))
        XCTAssertEqual(ChecklistCore.hash(try Data(contentsOf:URL(fileURLWithPath:try XCTUnwrap(moved["trash_path"] as? String)))),keyLease.attachment["sha256"] as? String)
        XCTAssertFalse(try ready())
    }

    func testDeletionReceiptPreservesFirstOutcomeThroughRoutineCommandRetention() throws {
        let f = try Fixture(),round = try cancel(f,f.round(f.type(checks.schema())))
        let ordinaryCommand = uuid(),epic = try XCTUnwrap(f.rows("group").first {$0["kind"] as? String == "epic"})
        _ = try f.router.handle(method:"task_create",params:["command_id":ordinaryCommand,"project_id":f.project,"epic_id":epic["id"]!,"title":"Ordinary command retention control"],caller:f.owner)
        let p = try input(f,round),command = uuid(),first = try worker(f,"media_round_delete",p,command:command)
        let receipt = try f.record(XCTUnwrap(first["byte_deletion_receipt_id"] as? String),"storage_job")
        XCTAssertEqual(receipt["parent_principal"] as? String,f.worker.principal)
        XCTAssertEqual(receipt["parent_command_id"] as? String,command)
        XCTAssertFalse((receipt["intent_digest"] as? String ?? "").isEmpty)
        try MediaAgentTypeChangeTests().setAgentRuleChanges(f,"owner_only")
        let current = Date()
        _ = try f.router.dbQueue.writeWithoutTransaction {db in
            try f.router.pruneRoutineRecords(db,now:current.addingTimeInterval(7_200))
        }
        let pruned = try f.router.dbQueue.writeWithoutTransaction {db in
            try f.router.pruneRoutineRecords(db,now:current.addingTimeInterval(33 * 86_400))
        }
        XCTAssertGreaterThan(pruned.commandResults,0,"The future retention pass must actually prune ordinary outcomes")
        let ordinaryResult = try f.router.dbQueue.read {db in
            try XCTUnwrap(String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[f.owner.principal,ordinaryCommand]))
        }
        XCTAssertTrue(CommandRouter.isPrunedResult(try jsonObject(ordinaryResult)))
        checks.checkError("NOT_FOUND") {try f.record(round["id"] as! String,"media_round")}
        let before = try f.allState(),replay = try worker(f,"media_round_delete",p,command:command)
        XCTAssertEqual(replay["replayed"] as? Bool,true)
        var replayOutcome = replay;replayOutcome.removeValue(forKey:"replayed")
        XCTAssertEqual(try jsonString(replayOutcome),try jsonString(first),"The durable receipt preserves the exact first outcome after normal command retention")
        var changed = p;changed["reason"] = "Changed intent after retention"
        checks.checkError("IDEMPOTENCY_CONFLICT") {try self.worker(f,"media_round_delete",changed,command:command)}
        XCTAssertEqual(try f.allState(),before)
    }

    func testExportAndLaterBackupRestorePreviewDoNotContainDeletedGraph() throws {
        let f = try Fixture(),round = try f.round(f.type(checks.schema()))
        _ = try f.item(round,texts:["Private deleted media text"])
        _ = try f.publish(round);try f.acceptEach(round)
        _ = try f.call("media_round_finish",actions.fence(f.get(round)))
        let owned = try exactRecords(f,MediaRecordRegistry.families.subtracting(["media_review_type","media_review_type_revision"]))
        _ = try f.call("media_round_delete",input(f,round))
        let export = f.base.appendingPathComponent("after-round-delete-export"),backup = f.base.appendingPathComponent("after-round-delete-backup")
        _ = try results.call(f,"export_project",["path":export.path])
        let exported = try JSONSerialization.jsonObject(with:Data(contentsOf:export.appendingPathComponent("project.json"))) as! JSON
        for family in MediaRecordRegistry.families {
            for row in exported[family] as? [JSON] ?? [] {XCTAssertNil(owned[row["id"] as! String],family)}
        }
        XCTAssertFalse(try String(contentsOf:export.appendingPathComponent("project.json"),encoding:.utf8).contains("Private deleted media text"))
        _ = try f.router.handle(method:"backup_create",params:["command_id":uuid(),"path":backup.path],caller:f.owner)
        let preview = try f.router.handle(method:"restore_preview",params:["path":backup.path],caller:f.owner)["data"] as! JSON
        let previewCounts = try XCTUnwrap(preview["record_families"] as? [String:Int])
        XCTAssertEqual(previewCounts["media_round"] ?? 0,0)
        XCTAssertEqual(previewCounts["media_item"] ?? 0,0)
        var configuration = Configuration();configuration.readonly = true
        configuration.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let copy = try DatabaseQueue(path:backup.appendingPathComponent("database.sqlite").path,configuration:configuration)
        defer {try? copy.close()}
        let envelopes = try copy.read {try MediaRecordRegistry.envelopes($0)}
        try MediaRecordRegistry.validate(envelopes)
        for record in envelopes {XCTAssertNil(owned[record.id],record.type)}
        let restored = try f.router.handle(method:"restore_create",params:["command_id":uuid(),"path":backup.path,"manifest_sha256":preview["manifest_sha256"]!],caller:f.owner)["data"] as! JSON
        let restoredRoot = URL(fileURLWithPath:try XCTUnwrap(restored["path"] as? String))
        let restoredDB = try DatabaseQueue(path:restoredRoot.appendingPathComponent("checklist.sqlite").path,configuration:configuration)
        defer {try? restoredDB.close()}
        XCTAssertEqual(try restoredDB.read {try Int.fetchOne($0,sql:"SELECT count(*) FROM records WHERE type IN ('media_round','media_item','media_candidate')")},0)
    }
}
