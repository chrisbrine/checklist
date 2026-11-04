import Foundation
import XCTest
import GRDB
@testable import ChecklistCore

/// CL-427 uses the real ticket-status completion hook and ordinary cleanup engine
/// on owned synthetic stores. No installed app, service or native relay is used.
final class MediaLinkedTaskCleanupTests: XCTestCase {
    typealias Fixture = MediaFrozenIntakeTests.Fixture
    let media = MediaAgentRoundActionTests()
    let results = MediaRoundResultTests()
    let intake = MediaFrozenIntakeTests()

    /// Completion guards have their own command tests. This fixture sets only
    /// their already-qualified Done result, then executes the shared status hook
    /// under the same validated transaction used by every completion route.
    func done(_ f: Fixture,_ task: JSON,changeStatus: Bool = true) throws {
        try ArchiveStorageGate.withExclusive(root:f.root) {_ in
            try f.router.dbQueue.writeWithoutTransaction {db in
                try f.router.withValidatedDomainTransaction(db) {
                    var current = try f.router.record(db,task["id"] as! String,type:"task")
                    if changeStatus {
                        current["status_id"] = try f.router.status(db,f.project,"done")["id"]!
                        current["completed_at"] = now();current = f.router.revised(current)
                        try f.router.save(db,current,type:"task")
                    }
                    try f.router.recordTicketStatusAction(db,task:current,caller:f.owner)
                    return .commit
                }
            }
        }
    }

    func linkedPublished(_ f: Fixture,count: Int) throws -> (JSON,JSON,[String]) {
        let task = try results.task(f),(round,ids) = try media.published(f,count)
        _ = try results.link(f,round,task)
        return (task,round,ids)
    }

    func testDoneFinishesArchivesAndPreservesDecisionsWithSystemFollowUp() throws {
        let f = try Fixture(),(task,round,ids) = try linkedPublished(f,count:4)
        for (id,disposition) in zip(ids,["accepted","changes_requested","needs_look","excluded"]) {
            try results.decide(f,round,id,disposition,"Exact owner note \(disposition)")
        }
        let decisions = try f.rows("media_owner_decision").map {try jsonString($0)}.sorted()
        try done(f,task)
        let stored = try f.record(round["id"] as! String,"media_round")
        XCTAssertEqual(stored["state"] as? String,"archived")
        for key in ["closed_by","archived_by"] {
            XCTAssertEqual((stored[key] as? JSON)?["actor_kind"] as? String,"system")
            XCTAssertEqual((stored[key] as? JSON)?["reason"] as? String,task["id"] as? String)
        }
        let counts = (stored["closure"] as? JSON)?["counts"] as? JSON
        for disposition in ["accepted","changes_requested","needs_look","excluded"] {XCTAssertEqual(counts?[disposition] as? Int,1)}
        XCTAssertEqual(counts?["worker_reason"] as? Int,1)
        let followUp = try XCTUnwrap(f.rows("media_rework_link").first)
        XCTAssertEqual(followUp["origin"] as? String,"system")
        XCTAssertEqual(followUp["author_session_id"] as? String,"system")
        XCTAssertTrue((followUp["follow_up_reason"] as? String ?? "").contains(task["id"] as! String))
        XCTAssertEqual(try f.rows("media_owner_decision").map {try jsonString($0)}.sorted(),decisions)
        let before = try f.allState();try done(f,task,changeStatus:false)
        XCTAssertEqual(try f.allState(),before,"Repeated completion effects must not reclose, duplicate a reason or enqueue another handoff")
        XCTAssertEqual(try f.get(round)["state"] as? String,"archived","Retained history stays readable")
    }

    func testUndecidedDoneNotifiesOnlyTriageOrchestratorOnceBeforeMembershipEnds() throws {
        let f = try Fixture(),(task,round,ids) = try linkedPublished(f,count:2)
        try results.decide(f,round,ids[0],"accepted","Keep")
        let orchestrator = try results.session(f,"cleanup-orchestrator")
        try results.triage(f,task,orchestrator)
        try done(f,task)
        XCTAssertEqual(try f.record(round["id"] as! String,"media_round")["state"] as? String,"open")
        let warning = try XCTUnwrap(f.rows("message").first)
        XCTAssertEqual(warning["body"] as? String,"First pass has 1 undecided items; it stays open")
        XCTAssertEqual(warning["origin"] as? String,"system")
        XCTAssertEqual(strings(warning,"handler_session_ids_at_send"),[orchestrator.sessionID!])
        let deliveries = try f.rows("delivery").filter {$0["message_id"] as? String == warning["id"] as? String}
        XCTAssertEqual(deliveries.compactMap {$0["recipient_session_id"] as? String},[orchestrator.sessionID!])
        XCTAssertTrue(try f.rows("group").filter {$0["kind"] as? String == "triage"}.allSatisfy {!f.router.triageMemberIDs($0).contains(task["id"] as! String)})
        let before = try f.allState();try done(f,task,changeStatus:false)
        XCTAssertEqual(try f.allState(),before)
    }

    func testUndecidedDoneWithoutTriageSavesOneWarningForPickup() throws {
        let f = try Fixture(),(task,round,_) = try linkedPublished(f,count:1)
        try done(f,task)
        let warning = try XCTUnwrap(f.rows("message").first)
        XCTAssertEqual(warning["pickup_pending"] as? Bool,true)
        XCTAssertTrue(strings(warning,"handler_session_ids_at_send").isEmpty)
        XCTAssertEqual(try f.record(round["id"] as! String,"media_round")["state"] as? String,"open")
        let before = try f.allState();try done(f,task,changeStatus:false)
        XCTAssertEqual(try f.allState(),before)
    }

    func testEndedOrchestratorRouteDoesNotBlockDoneAndWarningStaysForPickup() throws {
        let f = try Fixture(),(task,round,_) = try linkedPublished(f,count:1)
        let orchestrator = try results.session(f,"ended-cleanup-orchestrator")
        try results.triage(f,task,orchestrator)
        try f.router.dbQueue.write {db in
            var session = try f.router.record(db,orchestrator.sessionID!,type:"session")
            session["authorization_generation"] = uuid();try f.router.save(db,f.router.revised(session),type:"session")
        }
        try done(f,task)
        let warning = try XCTUnwrap(f.rows("message").first)
        XCTAssertEqual(warning["pickup_pending"] as? Bool,true);XCTAssertTrue(try f.rows("delivery").isEmpty)
        XCTAssertEqual(try f.record(round["id"] as! String,"media_round")["state"] as? String,"open")
        XCTAssertEqual(try f.record(task["id"] as! String,"task")["status_id"] as? String,
                       try f.router.dbQueue.read {try f.router.status($0,f.project,"done")["id"] as? String})
    }

    func testDoneCancelsAndArchivesEmptyDraftButKeepsUndecidedDraftOpen() throws {
        let f = try Fixture(),task = try results.task(f),type = try f.type(MediaRoundTests().schema())
        let empty = try f.round(type),nonempty = try f.round(type)
        _ = try f.item(nonempty)
        for round in [empty,nonempty] {_ = try results.link(f,round,task)}
        try done(f,task)
        let archived = try f.record(empty["id"] as! String,"media_round")
        XCTAssertEqual(archived["state"] as? String,"archived")
        XCTAssertEqual((archived["canceled_by"] as? JSON)?["actor_kind"] as? String,"system")
        XCTAssertTrue((archived["cancellation_reason"] as? String ?? "").contains(task["id"] as! String))
        XCTAssertEqual(try f.record(nonempty["id"] as! String,"media_round")["state"] as? String,"draft")
        XCTAssertEqual(try f.rows("message").count,1)
    }

    func testDoneChecksPublishedMembersAndKeepsExistingFollowUpReason() throws {
        let f = try Fixture(),(task,round,ids) = try linkedPublished(f,count:1)
        var decision = f.decisionParams(try f.get(round),ids:ids,disposition:"changes_requested")
        decision["note"] = "Owner wants a later pass";decision["no_follow_up_reason"] = "The owner handles the remaining work"
        _ = try f.call("media_decide",decision)
        _ = try f.item(round,title:"Unpublished future item")
        try done(f,task)
        let archived = try f.record(round["id"] as! String,"media_round")
        XCTAssertEqual(archived["state"] as? String,"archived")
        XCTAssertEqual(((archived["closure"] as? JSON)?["counts"] as? JSON)?["no_follow_up"] as? Int,1)
        XCTAssertTrue(try f.rows("media_rework_link").isEmpty,"An existing exact resolution is not replaced")
        XCTAssertTrue(try f.rows("message").isEmpty)
    }

    func imageRound(_ f: Fixture) throws -> (JSON,JSON,JSON) {
        let trash = f.base.appendingPathComponent("owned-media-trash",isDirectory:true)
        try FileManager.default.createDirectory(at:trash,withIntermediateDirectories:true)
        f.router.ticketCleanupTrashRoot = trash
        let task = try results.task(f),round = try f.round(f.type(intake.imageSchema()))
        let plan = try intake.confirm(f,intake.preview(f,round,[intake.source(f,"managed-take.png")]))
        _ = try intake.capture(f,plan);_ = try f.publish(round);try f.acceptEach(round)
        _ = try results.link(f,round,task)
        return (task,round,try XCTUnwrap(f.rows("attachment").first))
    }
    func cleanupPlan(_ f: Fixture,_ task: JSON) throws -> TicketPurgePlan {
        try f.router.dbQueue.read {db in
            let current = try f.router.record(db,task["id"] as! String,type:"task")
            return try f.router.ticketPurgePlan(db,task:current,doneEvidence:true)
        }
    }

    func testManagedOriginalHandoffUsesExistingBackupProtectedDoneCleanupAndKeepsHistory() throws {
        let f = try Fixture(),(task,round,attachment) = try imageRound(f)
        let original = f.router.ownerManagedPathProjection(attachment,caller:f.owner)["path"] as! String
        let decisions = try f.rows("media_owner_decision").map {try jsonString($0)}
        try done(f,task)
        XCTAssertEqual(try f.record(attachment["id"] as! String,"attachment")["task_id"] as? String,task["id"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath:original),"Completion hands off; it never moves bytes itself")
        let unbacked = try cleanupPlan(f,task)
        XCTAssertTrue(unbacked.byteDeletion.objects.contains {strings($0,"reasons").contains("backup_required")})
        XCTAssertFalse(unbacked.owned.contains {MediaRecordRegistry.families.contains($0.type)},"Ticket purge never owns retained media history")
        try ticketCleanupBackupTemplate(f.router,objects:unbacked.byteDeletion.objects)
        try f.router.runTicketLifecycleCleanup()
        _ = try f.router.runTicketObjectDeletionCohort()
        XCTAssertFalse(FileManager.default.fileExists(atPath:original))
        XCTAssertEqual(try f.record(attachment["id"] as! String,"attachment")["availability"] as? String,"original_cleaned")
        XCTAssertEqual(try f.rows("media_owner_decision").map {try jsonString($0)},decisions)
        XCTAssertEqual(try f.get(round)["state"] as? String,"archived")
        let jobs = try f.rows("storage_job").filter {$0["kind"] as? String == "ticket_object_delete" && $0["cause"] as? String == "done_evidence"}
        XCTAssertEqual(jobs.count,1)
        let moved = try XCTUnwrap((jobs[0]["objects"] as? [JSON] ?? []).first {$0["representation"] as? String == "original"})
        XCTAssertEqual(moved["state"] as? String,"removed")
        XCTAssertEqual(moved["disposal"] as? String,"trash")
        XCTAssertEqual(moved["moved_to_trash"] as? Bool,true)
        let trashPath = try XCTUnwrap(moved["trash_path"] as? String)
        XCTAssertTrue(trashPath.hasPrefix(f.router.ticketCleanupTrashRoot!.path + "/"))
        XCTAssertEqual(ChecklistCore.hash(try Data(contentsOf:URL(fileURLWithPath:trashPath))),attachment["sha256"] as? String,"The original is retained in the owned Trash destination")
        XCTAssertTrue(FileManager.default.fileExists(atPath:URL(fileURLWithPath:trashPath).deletingLastPathComponent().appendingPathComponent("cleanup-owner.json").path))
        let backup = f.base.appendingPathComponent("backup-after-media-trash",isDirectory:true)
        _ = try f.router.handle(method:"backup_create",params:["command_id":uuid(),"path":backup.path],caller:f.owner)
        XCTAssertTrue(FileManager.default.fileExists(atPath:backup.appendingPathComponent("manifest.json").path),"Historical Trash destinations are not required managed-original authority")
    }

    func testSharedSuccessorAndReaderLeaseKeepOriginalAfterLinkedTaskDone() throws {
        let f = try Fixture(),(task,round,attachment) = try imageRound(f)
        let view = try f.get(round),item = try XCTUnwrap((view["items"] as? [JSON])?.first)
        var successor = f.observation(view);successor["source_round_id"] = successor.removeValue(forKey:"round_id")
        successor["manifest_id"] = (view["manifest"] as! JSON)["id"]!;successor["manifest_digest"] = (view["manifest"] as! JSON)["digest"]!
        successor["title"] = "Independent next pass";successor["items"] = [["item_id":item["id"]!]]
        let next = try f.call("media_round_successor",successor)
        let target = item["published_target"] as! JSON,referenceID = strings(target,"attachment_reference_ids")[0]
        let owner = try f.router.dbQueue.read {try f.router.mediaOwnerValue($0,id:target["attachment_owner_id"] as! String,project:f.project)}
        let lease = try f.router.acquireMediaAttachmentReadLease(project:f.project,referenceID:referenceID,owner:owner,caller:f.owner)
        try done(f,task)
        XCTAssertEqual(try f.record(next["id"] as! String,"media_round")["state"] as? String,"draft")
        XCTAssertEqual(try f.record(referenceID,"storage_hold")["state"] as? String,"active")
        XCTAssertEqual(try f.record(lease.id,"storage_hold")["state"] as? String,"active")
        let plan = try cleanupPlan(f,task)
        try ticketCleanupBackupTemplate(f.router,objects:plan.byteDeletion.objects)
        try f.router.runTicketLifecycleCleanup();_ = try f.router.runTicketObjectDeletionCohort()
        let path = f.router.ownerManagedPathProjection(attachment,caller:f.owner)["path"] as! String
        XCTAssertTrue(FileManager.default.fileExists(atPath:path))
        let objects = try f.rows("storage_job").filter {$0["cause"] as? String == "done_evidence"}.flatMap {$0["objects"] as? [JSON] ?? []}
        XCTAssertTrue(objects.contains {Set(strings($0,"reasons")).contains("media_owner") || Set(strings($0,"reasons")).contains("reader_lease")})
    }

    func testMediaTrashIntentReconcilesAlreadyMovedDestinationAfterRestart() throws {
        let f = try Fixture(),(task,_,attachment) = try imageRound(f)
        let trash = try XCTUnwrap(f.router.ticketCleanupTrashRoot)
        try done(f,task)
        try ticketCleanupBackupTemplate(f.router,objects:cleanupPlan(f,task).byteDeletion.objects)
        try f.router.runTicketLifecycleCleanup();_ = try f.router.runTicketObjectDeletionCohort()
        let job = try XCTUnwrap(f.rows("storage_job").first {$0["cause"] as? String == "done_evidence"})
        let moved = try XCTUnwrap((job["objects"] as? [JSON])?.first {$0["representation"] as? String == "original"})
        let destination = try XCTUnwrap(moved["trash_path"] as? String)
        XCTAssertEqual(moved["moved_to_trash"] as? Bool,true,"The first pass must establish the exact destination before recovery is tested")
        let imports = try f.rows("storage_job").filter {$0["kind"] as? String == "attachment_import"}.map {try jsonString($0)}.sorted()
        // Reproduce a crash after the durable destination and rename, before
        // the outcome commit. Reopening must prove the exact retained entry.
        try f.router.dbQueue.write {db in
            var pending = job,objects = job["objects"] as! [JSON]
            for index in objects.indices where objects[index]["representation"] as? String == "original" {
                objects[index]["state"] = "pending";objects[index].removeValue(forKey:"moved_to_trash")
            }
            pending["objects"] = objects;pending["state"] = "pending"
            try f.router.save(db,f.router.revised(pending),type:"storage_job")
        }
        try f.reopen();f.router.ticketCleanupTrashRoot = trash
        XCTAssertEqual(try f.rows("storage_job").filter {$0["kind"] as? String == "attachment_import"}.map {try jsonString($0)}.sorted(),imports,
                       "The exact pending Trash intent keeps startup import recovery from creating a new repair owner")
        _ = try f.router.runTicketObjectDeletionCohort()
        let reconciled = try f.record(job["id"] as! String,"storage_job")
        let original = try XCTUnwrap((reconciled["objects"] as? [JSON])?.first {$0["representation"] as? String == "original"})
        let failure = "reasons=\(strings(original,"reasons")); last_failure=\(original["last_failure"] as? String ?? "none"); failures=\(int(original,"failures"))"
        XCTAssertEqual(original["state"] as? String,"removed",failure)
        XCTAssertEqual(original["moved_to_trash"] as? Bool,true,failure)
        XCTAssertEqual(original["trash_path"] as? String,destination)
        XCTAssertEqual(ChecklistCore.hash(try Data(contentsOf:URL(fileURLWithPath:destination))),attachment["sha256"] as? String)
    }

    func testSharedOriginalBecomesTrashEligibleWhenBothLinkedTasksAreDone() throws {
        let f = try Fixture(),(firstTask,round,attachment) = try imageRound(f)
        let path = try XCTUnwrap(ManagedPaths.resolve(try XCTUnwrap(attachment["path"] as? String),family:"objects",root:f.root)).path
        let view = try f.get(round),item = (view["items"] as! [JSON])[0]
        var p = f.observation(view);p["source_round_id"] = p.removeValue(forKey:"round_id")
        p["manifest_id"] = (view["manifest"] as! JSON)["id"]!;p["manifest_digest"] = (view["manifest"] as! JSON)["digest"]!
        p["title"] = "Second linked pass";p["items"] = [["item_id":item["id"]!]]
        let next = try f.call("media_round_successor",p),secondTask = try results.task(f)
        _ = try results.link(f,next,secondTask)
        try done(f,firstTask)
        XCTAssertTrue(try cleanupPlan(f,firstTask).byteDeletion.objects.contains {$0["state"] as? String == "retained"})
        _ = try f.publish(next);try f.acceptEach(next);try done(f,secondTask)
        let plan = try cleanupPlan(f,firstTask)
        try ticketCleanupBackupTemplate(f.router,objects:plan.byteDeletion.objects)
        try f.router.runTicketLifecycleCleanup();_ = try f.router.runTicketObjectDeletionCohort()
        XCTAssertFalse(FileManager.default.fileExists(atPath:path))
        let moved = try f.rows("storage_job").filter {$0["cause"] as? String == "done_evidence"}.flatMap {$0["objects"] as? [JSON] ?? []}.first {$0["representation"] as? String == "original" && $0["moved_to_trash"] as? Bool == true}
        XCTAssertNotNil(moved)
    }

    func testUncommittedTrashFolderWithMissingOrCorruptMarkerIsRetainedAndRetryUsesFreshFolder() throws {
        for corruptMarker in [false,true] {
            let f = try Fixture(),(task,_,attachment) = try imageRound(f)
            try done(f,task)
            try ticketCleanupBackupTemplate(f.router,objects:cleanupPlan(f,task).byteDeletion.objects)
            try f.router.runTicketLifecycleCleanup()
            let job = try XCTUnwrap(f.rows("storage_job").first {$0["cause"] as? String == "done_evidence"})
            let name = "Checklist-media-" + ChecklistCore.hash(Data((f.router.incarnation + ":" + (job["id"] as! String)).utf8))
            let orphan = f.router.ticketCleanupTrashRoot!.appendingPathComponent(name,isDirectory:true)
            try FileManager.default.createDirectory(at:orphan,withIntermediateDirectories:true)
            let retainedBytes = Data("Uncommitted orphan must never be adopted or removed".utf8)
            let retainedPath = orphan.appendingPathComponent("orphan-content")
            try retainedBytes.write(to:retainedPath)
            let marker = orphan.appendingPathComponent("cleanup-owner.json"),partial = Data("interrupted marker".utf8)
            if corruptMarker {try partial.write(to:marker)}
            _ = try f.router.runTicketObjectDeletionCohort()
            let completed = try f.record(job["id"] as! String,"storage_job")
            let directory = try XCTUnwrap(completed["media_trash_directory"] as? String)
            XCTAssertNotEqual(directory,orphan.path)
            XCTAssertTrue(URL(fileURLWithPath:directory).lastPathComponent.hasPrefix(name + "-"))
            XCTAssertEqual(try Data(contentsOf:retainedPath),retainedBytes)
            if corruptMarker {XCTAssertEqual(try Data(contentsOf:marker),partial)}
            else {XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))}
            let moved = try XCTUnwrap((completed["objects"] as? [JSON])?.first {$0["representation"] as? String == "original"})
            XCTAssertEqual(moved["moved_to_trash"] as? Bool,true)
            XCTAssertEqual(ChecklistCore.hash(try Data(contentsOf:URL(fileURLWithPath:moved["trash_path"] as! String))),attachment["sha256"] as? String)
        }
    }

    func testArchiveCleanupKeepsMarkedMediaForDoneTrashPathIncludingAnOlderQueuedJob() throws {
        let f = try Fixture(),task = try results.task(f)
        var project = try f.record(f.project,"project")
        project = try results.call(f,"project_settings_save",["expected_revision":project["revision"]!,"ticket_cleanup":["done_evidence_enabled":false,"closed_purge_enabled":false,"closed_days":15]])
        _ = try results.call(f,"archive_storage_settings",["expected_revision":project["revision"]!,"settings_revision":project["settings_revision"]!,"archive_storage":["preset":"clean_large_managed_on_archive","large_original_bytes":1,"retained_budget_bytes":0]])
        let source = f.workspace.appendingPathComponent("archived-original.bin")
        try Data("Owned media original must survive the archive executor".utf8).write(to:source)
        let attachment = try results.call(f,"attachment_add",["task_id":task["id"]!,"path":source.path,"mode":"managed_copy"])
        let preview = try results.call(f,"attachment_cleanup_preview",["task_id":task["id"]!])
        let currentTask = try f.record(task["id"] as! String,"task")
        _ = try results.call(f,"task_archive",["task_id":task["id"]!,"expected_revision":currentTask["revision"]!,"action":"archive","cleanup":true,"cleanup_preview_id":preview["cleanup_preview_id"]!])
        let job = try XCTUnwrap(f.rows("cleanup_job").first)
        try f.router.dbQueue.write {db in
            var current = try f.router.record(db,attachment["id"] as! String,type:"attachment")
            current["media_cleanup_round_id"] = uuid();current = f.router.revised(current)
            try f.router.save(db,current,type:"attachment")
            var queued = try f.router.record(db,job["id"] as! String,type:"cleanup_job"),items = queued["items"] as! [JSON]
            for index in items.indices {items[index]["attachment_revision"] = current["revision"]!}
            queued["items"] = items;queued["enqueued_at_ms"] = Int64(1);queued["not_before_ms"] = Int64(2)
            queued["revision"] = try f.router.nextCleanupJobRevision(queued)
            _ = try ArchiveCleanupJob(record:queued)
            try f.router.save(db,queued,type:"cleanup_job")
        }
        let holds = try f.router.dbQueue.read {db in
            try f.router.completeArchiveCleanupHolds(db,attachment:f.router.record(db,attachment["id"] as! String,type:"attachment"),task:f.router.record(db,task["id"] as! String,type:"task"),currentGraph:[])
        }
        XCTAssertTrue(holds.contains(.mediaTrashRequired))
        try f.router.runStorageMaintenance()
        let retained = try f.record(job["id"] as! String,"cleanup_job")
        XCTAssertTrue(((retained["items"] as? [JSON])?.first?["holds"] as? [String] ?? []).contains("mediaTrashRequired"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:attachment["path"] as! String))
        XCTAssertEqual(try f.record(attachment["id"] as! String,"attachment")["availability"] as? String,"available")
    }

    func testPreHandoffNonTrashTicketIntentCannotUnlinkCurrentMarkedMediaOwner() throws {
        let f = try Fixture(),(task,_,attachment) = try imageRound(f)
        try done(f,task)
        try ticketCleanupBackupTemplate(f.router,objects:cleanupPlan(f,task).byteDeletion.objects)
        try f.router.runTicketLifecycleCleanup()
        let job = try XCTUnwrap(f.rows("storage_job").first {$0["cause"] as? String == "done_evidence"})
        // An intent admitted before the handoff has the same exact bytes and
        // owners but no disposal field. Final current metadata must still win.
        try f.router.dbQueue.write {db in
            var stale = job,objects = job["objects"] as! [JSON]
            for index in objects.indices {objects[index].removeValue(forKey:"disposal")}
            stale["objects"] = objects
            try f.router.save(db,f.router.revised(stale),type:"storage_job")
        }
        _ = try f.router.runTicketObjectDeletionCohort()
        let retained = try f.record(job["id"] as! String,"storage_job")
        let original = try XCTUnwrap((retained["objects"] as? [JSON])?.first {$0["representation"] as? String == "original"})
        XCTAssertEqual(original["state"] as? String,"retained")
        XCTAssertTrue(strings(original,"reasons").contains("media_trash_required"))
        XCTAssertNil(original["trash_path"])
        let path = f.router.ownerManagedPathProjection(attachment,caller:f.owner)["path"] as! String
        XCTAssertTrue(FileManager.default.fileExists(atPath:path))
        XCTAssertEqual(try f.record(attachment["id"] as! String,"attachment")["availability"] as? String,"available")
    }
}
