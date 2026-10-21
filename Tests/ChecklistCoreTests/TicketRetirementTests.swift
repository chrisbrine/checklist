import XCTest
import GRDB
@testable import ChecklistCore

final class TicketRetirementTests: XCTestCase {
    var router: CommandRouter!
    var directory: URL!
    let owner = Caller(role:"owner",installation:"cl24-owner",projectIDs:[])
    override func setUpWithError() throws {
        // macOS /var and /tmp paths traverse a symlink that storage admission rejects; use the test cache root.
        let parent = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ChecklistQualification/CL-24", isDirectory: true)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        directory = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        directory = directory.resolvingSymlinksInPath()
        router = try CommandRouter(root:directory)
    }
    override func tearDownWithError() throws {router = nil;try? FileManager.default.removeItem(at:directory)}
    @discardableResult func call(_ method: String,_ input: JSON = [:],_ caller: Caller? = nil) throws -> JSON {
        var p = input
        if !CommandRouter.readMethods.contains(method) {p["command_id"] = UUID().uuidString}
        return try router.handle(method:method,params:p,caller:caller ?? owner)["data"] as! JSON
    }
    func fixtureWrite(_ body: (Database) throws -> Void) throws {
        try router.dbQueue.writeWithoutTransaction {db in try router.withValidatedDomainTransaction(db) {try body(db);return .commit}}
    }
    func fixture() throws -> (JSON,JSON) {
        let project = try call("project_create",["name":"Retirement","key_prefix":"RET"])
        let task = try call("task_create",["project_id":project["id"]!,"title":"Synthetic retirement ticket","brief":"Keep the history"])
        return (project,task)
    }
    func params(_ p: JSON,_ t: JSON) -> JSON {["project_id":p["id"]!,"task_id":t["id"]!,"expected_revision":t["revision"]!]}
    func read(_ p: JSON,_ t: JSON) throws -> JSON {try call("task_get",params(p,t))}
    func code(_ code: String,_ body: () throws -> Void) {XCTAssertThrowsError(try body()) {XCTAssertEqual(($0 as? CoreError)?.code,code)}}
    func note(_ p: JSON,_ t: JSON,_ extra: JSON = [:],_ caller: Caller? = nil) throws -> JSON {
        var values: JSON = ["project_id":p["id"]!,"task_id":t["id"]!,"body":"Original direction"]
        values.merge(extra) {_,new in new};return try call("message_send",values,caller)
    }
    func testOwnCorrectionAndRetractionAreAppendOnlyAndPreserveReceipts() throws {
        let (p,t) = try fixture()
        let original = try note(p,t,["requires_action":true])
        let before = try router.dbQueue.read {try router.record($0,original["id"] as! String,type:"message")}
        _ = try note(p,t,["correction_of":original["id"]!,"body":"Corrected direction"])
        XCTAssertTrue(try router.dbQueue.read {try router.hasPendingDirections($0,task:t)})
        let retraction = try note(p,t,["correction_of":original["id"]!,"kind":"retraction","body":"Scope withdrawn"])
        XCTAssertEqual(retraction["direction_already_addressed"] as? Bool,false)
        XCTAssertFalse(try router.dbQueue.read {try router.hasPendingDirections($0,task:t)})
        let after = try router.dbQueue.read {try router.record($0,original["id"] as! String,type:"message")}
        XCTAssertEqual(try jsonString(before),try jsonString(after))
        let projected = try router.dbQueue.read {try router.noteRevisionProjection($0,messages:[after],project:p["id"] as! String)}
        XCTAssertEqual(projected.first?["note_revision_state"] as? String,"retracted")
        XCTAssertEqual((projected.first?["note_revisions"] as? [JSON])?.count,2)
        let context = try call("task_context",params(p,t))
        XCTAssertTrue((context["unresolved_directions"] as? [JSON] ?? []).isEmpty)
        XCTAssertNoThrow(try router.dbQueue.read {try router.validateDirectionCursor($0,params:["direction_cursor":context["direction_cursor"]!],task:t,caller:owner)})
        let other = Caller(role:"owner",installation:"another-owner",projectIDs:[])
        code("FORBIDDEN") {_ = try self.note(p,t,["correction_of":original["id"]!,"body":"Not mine"],other)}
    }
    func testRetractionAfterAddressingNotifiesCurrentHandlerWithoutChangingOriginal() throws {
        let (p,initial) = try fixture(),pid = p["id"] as! String
        let t = try call("task_edit",params(p,initial).merging(["readiness":"ready"]) {_,new in new})
        let sid = UUID().uuidString
        let workspace = directory.appendingPathComponent("workspace");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        try router.dbQueue.write {db in var project = try router.record(db,pid,type:"project");project["root_path"] = workspace.path;try router.save(db,project,type:"project")}
        _ = try call("session_register",["project_id":pid,"session_id":sid,"role":"worker","provider":"claude","installation":"cl24-worker"])
        let worker = Caller(role:"worker",installation:"cl24-worker",projectIDs:[pid],sessionID:sid,workspace:workspace.path)
        let claim = try call("work_claim",params(p,t),worker)
        let original = try note(p,t,["requires_action":true])
        let delivery = try XCTUnwrap((original["deliveries"] as? [JSON])?.first)
        _ = try call("message_ack",["project_id":pid,"delivery_id":delivery["id"]!,"stage":"acknowledged"],worker)
        let context = try call("task_context",["project_id":pid,"task_id":t["id"]!],worker)
        let checkpoint = try call("work_checkpoint",["project_id":pid,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"progress":"Handled the earlier direction","direction_ids":[original["id"]!],"direction_cursor":context["direction_cursor"]!],worker)
        _ = try call("message_ack",["project_id":pid,"delivery_id":delivery["id"]!,"stage":"addressed","response_ref":["kind":"checkpoint","id":checkpoint["checkpoint_id"]!]],worker)
        let before = try router.dbQueue.read {try router.record($0,original["id"] as! String,type:"message")}
        let receipts = try router.dbQueue.read {try router.records($0,type:"delivery",project:pid)}
        let retract = try note(p,t,["kind":"retraction","correction_of":original["id"]!,"body":"Changed after it was addressed"])
        XCTAssertEqual(retract["direction_already_addressed"] as? Bool,true)
        XCTAssertEqual(retract["direction_already_acknowledged"] as? Bool,true)
        XCTAssertEqual((retract["deliveries"] as? [JSON])?.first?["recipient_session_id"] as? String,sid)
        XCTAssertEqual(try jsonString(before),try router.dbQueue.read {try jsonString(router.record($0,original["id"] as! String,type:"message"))})
        XCTAssertEqual(try jsonString(receipts),try router.dbQueue.read {try jsonString(router.records($0,type:"delivery",project:pid).filter {$0["message_id"] as? String == original["id"] as? String})})
        code("FORBIDDEN") {_ = try self.note(p,t,["correction_of":original["id"]!,"body":"Agent cannot revise owner"],worker)}
        let own = try note(p,t,["body":"Agent finding"],worker)
        XCTAssertEqual(try note(p,t,["correction_of":own["id"]!,"body":"Updated finding"],worker)["origin"] as? String,"agent")
    }
    func testCancelReopenAndReassignmentRequireReasonsAndKeepRelations() throws {
        let (p,t) = try fixture()
        let other = try call("task_create",["project_id":p["id"]!,"title":"Related ticket"])
        _ = try call("task_link",params(p,t).merging(["target_task_id":other["id"]!,"relation":"related_to"]) {_,new in new})
        let current = try call("task_edit",params(p,try read(p,t)).merging(["planned_assignee":["kind":"agent","provider":"codex"],"assignment_reason":"Initial implementation preference"]) {_,new in new})
        var triage = try call("triage_create",["project_id":p["id"]!,"name":"Implementation grouping"])
        triage = try call("group_membership",["project_id":p["id"]!,"group_id":triage["id"]!,"task_id":t["id"]!,"expected_revision":triage["revision"]!,"action":"add"])
        code("INVALID_INPUT") {_ = try self.call("task_transition",self.params(p,current).merging(["action":"cancel"]) {_,new in new})}
        code("INVALID_INPUT") {_ = try self.call("task_edit",self.params(p,current).merging(["planned_assignee":"human"]) {_,new in new})}
        let canceled = try call("task_transition",params(p,current).merging(["action":"cancel","reason":"Scope no longer needed"]) {_,new in new})
        let reopened = try call("task_transition",params(p,canceled).merging(["action":"reopen","reason":"Scope restored"]) {_,new in new})
        XCTAssertEqual(reopened["status_category"] as? String,"queued")
        XCTAssertEqual((try call("relation_list",["project_id":p["id"]!,"task_id":t["id"]!])["relations"] as! [JSON]).count,1)
        let group = try router.dbQueue.read {try router.record($0,triage["id"] as! String,type:"group")}
        XCTAssertTrue(router.triageMemberIDs(group).isEmpty)
        let assigned = try call("task_edit",params(p,reopened).merging(["planned_assignee":"human","assignment_reason":"Owner will inspect"]) {_,new in new})
        XCTAssertEqual(assigned["assignment_reason"] as? String,"Owner will inspect")
        let history = try call("history_list",["project_id":p["id"]!,"task_id":t["id"]!])["events"] as! [JSON]
        XCTAssertTrue(history.contains {($0["data"] as? JSON)?["reason"] as? String == "Scope no longer needed"})
        XCTAssertTrue(history.contains {($0["data"] as? JSON)?["reason"] as? String == "Scope restored"})
    }
    func testFirstPlannedAssignmentAndSameAssigneeNeedNoReason() throws {
        let (p,initial) = try fixture()
        for unassigned in [NSNull(), "unassigned", ["kind":"unassigned"]] as [Any] {
            var t = try call("task_create",["project_id":p["id"]!,"title":"First assignment"])
            if !(unassigned is NSNull) {
                t = try call("task_edit",params(p,t).merging(["patch":["planned_assignee":unassigned]]) {_,new in new})
            }
            let assigned = try call("task_edit",params(p,t).merging(["patch":["planned_assignee":"human"]]) {_,new in new})
            XCTAssertEqual(assigned["planned_assignee"] as? String,"human")
            XCTAssertNil(assigned["assignment_reason"])
            let unchanged = try call("task_edit",params(p,assigned).merging(["patch":["planned_assignee":["kind":"human"]]]) {_,new in new})
            XCTAssertNil(unchanged["assignment_reason"])
            let events = try call("history_list",params(p,t))["events"] as! [JSON]
            XCTAssertTrue(events.contains {($0["data"] as? JSON)?["to_assignee"] as? String == "human" && ($0["data"] as? JSON)?["assignment_reason"] == nil})
        }
        // The existing agent policy override still needs its explanation.
        code("INVALID_INPUT") {_ = try self.call("task_edit",self.params(p,initial).merging(["patch":["planned_assignee":["kind":"agent","provider":"codex"]]]) {_,new in new})}
    }

    func testReassignmentRequiresFreshReasonAndRecordsHistory() throws {
        let (p,t) = try fixture()
        let assigned = try call("task_edit",params(p,t).merging(["patch":["planned_assignee":"human","assignment_reason":"Initial owner inspection"]]) {_,new in new})
        for destination in ["unassigned", ["kind":"agent","provider":"codex"]] as [Any] {
            for reason in [nil,"","  \n"] as [String?] {
                var patch: JSON = ["planned_assignee":destination];patch["assignment_reason"] = reason
                XCTAssertThrowsError(try call("task_edit",params(p,assigned).merging(["patch":patch]) {_,new in new})) { error in
                    XCTAssertEqual((error as? CoreError)?.code,"INVALID_INPUT")
                    XCTAssertTrue((error as? CoreError)?.message.contains("assignment_reason") == true)
                }
                XCTAssertEqual(int(try read(p,t),"revision"),int(assigned,"revision"))
            }
        }
        let reason = "Return this scope to eligible worker pickup"
        let changed = try call("task_edit",params(p,assigned).merging(["patch":["planned_assignee":"unassigned","assignment_reason":reason]]) {_,new in new})
        XCTAssertEqual(changed["planned_assignee"] as? String,"unassigned")
        XCTAssertEqual(changed["assignment_reason"] as? String,reason)
        let events = try call("history_list",params(p,t))["events"] as! [JSON]
        XCTAssertTrue(events.contains {
            let data = $0["data"] as? JSON ?? [:]
            return data["from_assignee"] as? String == "human" && data["to_assignee"] as? String == "unassigned" && data["assignment_reason"] as? String == reason
        })
    }

    func testOrphanActiveChildAndVerificationPreventUnsafeStatusAndRemoval() throws {
        let (p,t) = try fixture()
        let aid = UUID().uuidString
        try router.dbQueue.write {db in try router.save(db,["id":aid,"project_id":p["id"]!,"task_id":t["id"]!,"state":"active","parent_attempt_id":"old-parent","revision":1],type:"attempt")}
        for method in ["task_transition","task_archive","task_edit","task_purge_preview"] {
            var values = params(p,t);values["action"] = method == "task_transition" ? "cancel" : "trash";values["reason"] = "Stop";values["planned_assignee"] = "human";values["assignment_reason"] = "Change holder"
            code("CLAIM_CONFLICT") {_ = try self.call(method,values)}
        }
        try fixtureWrite {db in var a = try self.router.record(db,aid,type:"attempt");a["state"] = "released";try self.router.save(db,a,type:"attempt");var task = try self.router.record(db,t["id"] as! String,type:"task");task["active_verification_request_id"] = "synthetic-verification";try self.router.save(db,task,type:"task")}
        code("CLAIM_CONFLICT") {_ = try self.call("task_archive",self.params(p,t).merging(["action":"trash"]) {_,new in new})}
    }
    func testTrashSurfaceExcludesOrdinaryListsAndRestoresHistory() throws {
        let (p,t) = try fixture();_ = try note(p,t)
        let trashed = try call("task_archive",params(p,t).merging(["action":"trash","reason":"Mistaken capture"]) {_,new in new})
        XCTAssertTrue((try call("task_list",["project_id":p["id"]!,"text":"Synthetic"])["tasks"] as! [JSON]).isEmpty)
        for surface in ["tickets","overview","archived","trash"] {
            let reply = try call("task_list",["project_id":p["id"]!,"text":"Synthetic","view":["surface":surface,"status_filter":"all","tag_filter":"all","group_by":"none","order_by":"updated_desc"]])
            XCTAssertEqual((reply["tickets_page"] as! JSON)["matched_count"] as? Int,surface == "trash" ? 1 : 0)
        }
        _ = try call("task_archive",params(p,trashed).merging(["action":"restore"]) {_,new in new})
        XCTAssertEqual((try call("task_list",["project_id":p["id"]!])["tasks"] as! [JSON]).count,1)
        XCTAssertEqual((try call("history_list",["project_id":p["id"]!,"task_id":t["id"]!])["messages"] as! [JSON]).count,1)
    }
    func testPurgePreviewIsOwnerOnlyHonestAndDoesNotRemoveExternalFiles() throws {
        let (p,t) = try fixture()
        code("TRASH_REQUIRED") {_ = try self.call("task_purge_preview",self.params(p,t))}
        let trashed = try call("task_archive",params(p,t).merging(["action":"trash"]) {_,new in new})
        let file = directory.appendingPathComponent("external.txt");try Data("External project bytes".utf8).write(to:file)
        let preview = try call("task_purge_preview",params(p,trashed))
        XCTAssertEqual(preview["can_purge"] as? Bool,true)
        XCTAssertTrue(strings(preview,"blockers").isEmpty)
        XCTAssertEqual(preview["digest"] as? String,try call("task_purge_preview",params(p,trashed))["digest"] as? String)
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"External project bytes")
        XCTAssertTrue(try read(p,trashed)["trashed"] as? Bool ?? false)
        let tools = router.toolCatalog(Caller(role:"worker",installation:"worker",projectIDs:[p["id"] as! String]))
        XCTAssertFalse(tools.contains {$0["name"] as? String == "task_purge_preview"})
    }
    func testArchiveUndoRefusesCleanedBytesButNormalUnarchiveKeepsVisibility() throws {
        let (p,t) = try fixture()
        let archived = try call("task_archive",params(p,t).merging(["action":"archive"]) {_,new in new})
        try router.dbQueue.write {db in try router.save(db,["id":UUID().uuidString,"project_id":p["id"]!,"task_id":t["id"]!,"mode":"managed","availability":"original_cleaned","revision":1],type:"attachment")}
        code("UNDO_UNAVAILABLE") {_ = try self.call("task_archive",self.params(p,archived).merging(["action":"unarchive","undo":true]) {_,new in new})}
        let unarchived = try call("task_archive",params(p,archived).merging(["action":"unarchive"]) {_,new in new})
        XCTAssertEqual(unarchived["archived"] as? Bool,false)
        code("REVISION_CONFLICT") {_ = try self.call("task_archive",self.params(p,archived).merging(["action":"unarchive","undo":true]) {_,new in new})}
    }
    func testArchivingEpicAndTriageLeavesMemberTicketsUnchanged() throws {
        let (p,t) = try fixture()
        for kind in ["epic","triage"] {
            var group = try call(kind+"_create",["project_id":p["id"]!,"name":"Synthetic grouping"])
            group = try call("group_membership",["project_id":p["id"]!,"group_id":group["id"]!,"task_id":t["id"]!,"expected_revision":group["revision"]!,"action":"add"])
            let before = try read(p,t)
            _ = try call(kind+"_edit",["project_id":p["id"]!,"group_id":group["id"]!,"expected_revision":group["revision"]!,"archived":true])
            XCTAssertEqual(try jsonString(before),try jsonString(read(p,t)))
        }
    }
}
