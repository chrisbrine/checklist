import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

final class TicketBulkEditTests: XCTestCase {
    var directory: URL!
    var router: CommandRouter!
    let owner = Caller(role:"owner",installation:"bulk-tests",projectIDs:[])
    override func setUpWithError() throws {
        // macOS /var and /tmp paths traverse a symlink that storage admission rejects; use the test cache root.
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ChecklistQualification/CL-16", isDirectory: true)
        directory = root.appendingPathComponent("bulk-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        router = try TestStore.router(root:directory)
    }
    override func tearDownWithError() throws {router = nil;try? FileManager.default.removeItem(at:directory)}
    @discardableResult func call(_ method: String,_ input: JSON = [:],caller: Caller? = nil,command: String = UUID().uuidString) throws -> JSON {
        var p = input;if !CommandRouter.readMethods.contains(method) {p["command_id"] = command}
        return try router.handle(method:method,params:fixtureTaskInput(router,method:method,input:p),caller:caller ?? owner)["data"] as! JSON
    }
    func fixture() throws -> (JSON,[JSON]) {
        let project = try call("project_create",["name":"Bulk","key_prefix":"B","root_path":directory.path])
        let tasks = try ["One","Two","Three"].map {try call("task_create",["project_id":project["id"]!,"title":$0,"brief":"A bounded synthetic outcome"])}
        return (project,tasks)
    }
    func refs(_ tasks: [JSON]) -> [JSON] {tasks.map {["task_id":$0["id"]!,"expected_revision":$0["revision"]!]}}
    func current(_ p: JSON,_ t: JSON) throws -> JSON {try call("task_get",["project_id":p["id"]!,"task_id":t["id"]!])}
    func edit(_ p: JSON,_ tasks: [JSON],_ changes: JSON,preview: Bool = false,command: String = UUID().uuidString) throws -> JSON {
        try call("task_bulk_edit",["project_id":p["id"]!,"tasks":refs(tasks),"changes":changes,"preview":preview],command:command)
    }
    func undo(_ p: JSON,_ tasks: [JSON],_ receipt: JSON,preview: Bool = false,reason: String? = nil) throws -> JSON {
        var input: JSON = ["project_id":p["id"]!,"tasks":refs(tasks),"original_command_id":receipt["command_id"]!,"preview":preview]
        input["reason"] = reason
        return try call("task_bulk_undo",input)
    }
    func code(_ expected: String,_ action: () throws -> Void,file: StaticString = #filePath,line: UInt = #line) {XCTAssertThrowsError(try action(),file:file,line:line) {XCTAssertEqual(($0 as? CoreError)?.code,expected,file:file,line:line)}}

    func testPreviewReportsEveryConflictAndAtomicApplyLeavesEligibleRowsUnchanged() throws {
        let (p,t) = try fixture()
        _ = try call("task_edit",["project_id":p["id"]!,"task_id":t[1]["id"]!,"expected_revision":t[1]["revision"]!,"patch":["title":"Changed elsewhere"]])
        let preview = try edit(p,t,["kind":"archive","action":"archive"],preview:true),rows = preview["rows"] as! [JSON]
        XCTAssertEqual(int(preview,"affected_count"),2);XCTAssertEqual(rows[1]["code"] as? String,"REVISION_CONFLICT")
        XCTAssertFalse(bool(try current(p,t[0]),"archived"))
        code("BULK_CONFLICT") {_ = try self.edit(p,t,["kind":"archive","action":"archive"])}
        XCTAssertEqual(int(try current(p,t[0]),"revision"),1)
        let applied = try edit(p,[t[0],t[2]],["kind":"archive","action":"archive"])
        XCTAssertEqual(int(applied,"affected_count"),2)
        XCTAssertTrue(bool(try current(p,t[0]),"archived"));XCTAssertFalse(bool(try current(p,t[1]),"archived"))
        let row = (applied["rows"] as! [JSON])[0]
        XCTAssertNotNil(row["before"]);XCTAssertNotNil(row["after"]);XCTAssertEqual(int(row,"after_revision"),2)
    }

    func testTagUndoPreservesLaterTitleTagsAndNotesAndIsIdempotent() throws {
        let (p,t) = try fixture(),a = try call("tag_create",["project_id":p["id"]!,"name":"Art"]),b = try call("tag_create",["project_id":p["id"]!,"name":"Audio"])
        let command = UUID().uuidString,receipt = try edit(p,[t[0],t[1]],["kind":"tags","add":[a["id"]!]],command:command)
        _ = try edit(p,[t[0],t[1]],["kind":"tags","add":[a["id"]!]],command:command)
        var one = try current(p,t[0]);one = try call("task_edit",["project_id":p["id"]!,"task_id":one["id"]!,"expected_revision":one["revision"]!,"patch":["title":"Later title","tag_ids":[a["id"]!,b["id"]!]]])
        _ = try call("message_send",["project_id":p["id"]!,"task_id":one["id"]!,"body":"Keep this note"])
        let preview = try undo(p,[one,try current(p,t[1])],receipt,preview:true);XCTAssertEqual(int(preview,"affected_count"),2)
        _ = try undo(p,[one,try current(p,t[1])],receipt)
        let restored = try current(p,t[0]);XCTAssertEqual(restored["title"] as? String,"Later title");XCTAssertEqual(strings(restored,"tag_ids"),[b["id"] as! String])
        let messages = try call("history_list",["project_id":p["id"]!,"task_id":one["id"]!])["messages"] as! [JSON]
        XCTAssertTrue(messages.contains {$0["body"] as? String == "Keep this note"})
    }

    func testUndoKeepsInterveningSameFieldAndRejectsStaleRevisions() throws {
        let (p,t) = try fixture(),receipt = try edit(p,[t[0]],["kind":"status","action":"block"])
        let blocked = try current(p,t[0])
        code("BULK_CONFLICT") {_ = try self.undo(p,[t[0]],receipt)}
        _ = try call("task_transition",["project_id":p["id"]!,"task_id":blocked["id"]!,"expected_revision":blocked["revision"]!,"action":"defer"])
        let preview = try undo(p,[try current(p,t[0])],receipt,preview:true)
        XCTAssertEqual(int(preview,"affected_count"),0);XCTAssertEqual((preview["rows"] as! [JSON])[0]["code"] as? String,"UNDO_CONFLICT")
    }

    func testUndoCannotReviveProtectedStatusOrAdvancedWorkAndBulkRejectsActiveClaims() throws {
        let (p,t) = try fixture()
        let ready = try call("task_edit",["project_id":p["id"]!,"task_id":t[0]["id"]!,"expected_revision":t[0]["revision"]!,"patch":["readiness":"ready"]])
        let receipt = try edit(p,[ready],["kind":"tags","add":[try call("tag_create",["project_id":p["id"]!,"name":"Code"])["id"]!]])
        let sid = UUID().uuidString
        _ = try call("session_register",["project_id":p["id"]!,"session_id":sid,"provider":"codex","role":"worker","label":"Synthetic worker"])
        let agent = Caller(role:"worker",installation:"bulk-worker",projectIDs:[p["id"] as! String],sessionID:sid,workspace:directory.path)
        var ticket = try current(p,t[0]);let claim = try call("work_claim",["project_id":p["id"]!,"task_id":ticket["id"]!,"expected_revision":ticket["revision"]!],caller:agent)
        ticket = try current(p,t[0])
        XCTAssertEqual(int(try edit(p,[ticket],["kind":"archive","action":"archive"],preview:true),"affected_count"),0)
        XCTAssertEqual(int(try undo(p,[ticket],receipt,preview:true),"affected_count"),0)
        _ = try call("work_release",["project_id":p["id"]!,"attempt_id":claim["id"]!,"claim_token":claim["claim_token"]!,"reason":"Synthetic check complete"],caller:agent)
        let preview = try undo(p,[try current(p,t[0])],receipt,preview:true)
        XCTAssertEqual((preview["rows"] as! [JSON])[0]["code"] as? String,"UNDO_UNAVAILABLE")
        XCTAssertEqual(int(preview,"affected_count"),0)
    }

    func testEpicMovesTriageUndoAndStatusDepartureUseNormalHistory() throws {
        let (p,t) = try fixture(),e1 = try call("epic_create",["project_id":p["id"]!,"name":"Art"]),e2 = try call("epic_create",["project_id":p["id"]!,"name":"Code"])
        _ = try edit(p,Array(t.prefix(2)),["kind":"epic","epic_id":e1["id"]!])
        let moved = try edit(p,[try current(p,t[0]),try current(p,t[1])],["kind":"epic","epic_id":e2["id"]!])
        _ = try undo(p,[try current(p,t[0]),try current(p,t[1])],moved)
        XCTAssertEqual(try current(p,t[0])["epic_id"] as? String,e1["id"] as? String)
        let group = try call("triage_create",["project_id":p["id"]!,"name":"This pass","phase":"implementation"])
        let added = try edit(p,[try current(p,t[0]),try current(p,t[1])],["kind":"triage","triage_id":group["id"]!,"action":"add"])
        _ = try undo(p,[try current(p,t[0]),try current(p,t[1])],added)
        _ = try edit(p,[try current(p,t[0]),try current(p,t[1])],["kind":"triage","triage_id":group["id"]!,"action":"add"])
        _ = try edit(p,[try current(p,t[0]),try current(p,t[1])],["kind":"status","action":"queue"])
        let groups = try call("triage_list",["project_id":p["id"]!])["groups"] as! [JSON]
        XCTAssertTrue(strings(groups.first {$0["id"] as? String == group["id"] as? String}!,"task_ids").isEmpty)
        XCTAssertEqual(try current(p,t[0])["epic_id"] as? String,e1["id"] as? String)
    }

    func testArchiveUndoNeverRestoresCleanedBytesAndReceiptsAreScoped() throws {
        let (p,t) = try fixture(),receipt = try edit(p,[t[0]],["kind":"archive","action":"archive"])
        let undone = try undo(p,[try current(p,t[0])],receipt)
        XCTAssertFalse(bool(try current(p,t[0]),"archived"));XCTAssertEqual(undone["files_notice"] as? String,"Unarchiving does not restore cleaned files.")
        let other = Caller(role:"owner",installation:"other-owner",projectIDs:[])
        code("UNDO_UNAVAILABLE") {_ = try self.call("task_bulk_undo",["project_id":p["id"]!,"tasks":self.refs([try self.current(p,t[0])]),"original_command_id":receipt["command_id"]!,"preview":true],caller:other)}
    }

    func testReopenedDuplicateExplainsWhyItsLinkChangesCannotBeUndone() throws {
        let (p,t) = try fixture()
        _ = try call("task_link",["project_id":p["id"]!,"task_id":t[0]["id"]!,"expected_revision":t[0]["revision"]!,"relation":"duplicate_of","target_task_id":t[1]["id"]!])
        let receipt = try edit(p,[try current(p,t[0])],["kind":"status","action":"reopen","reason":"Investigate this ticket separately"])
        let preview = try undo(p,[try current(p,t[0])],receipt,preview:true)
        XCTAssertEqual(int(preview,"affected_count"),0)
        XCTAssertEqual((preview["rows"] as! [JSON])[0]["code"] as? String,"UNDO_UNAVAILABLE")
        XCTAssertEqual(try current(p,t[0])["disposition"] as? String,"open")
    }

    func testTriageRemovalUndoRetainsManualExitPolicyWithNewHistory() throws {
        let (p,t) = try fixture(),group = try call("triage_create",["project_id":p["id"]!,"name":"Manual pass","phase":"implementation"])
        let added = try call("group_membership",["project_id":p["id"]!,"group_id":group["id"]!,"expected_revision":group["revision"]!,"task_id":t[0]["id"]!,"expected_task_revision":t[0]["revision"]!,"action":"add","exit_milestone":"manual"])
        let originalMember = try XCTUnwrap((added["members"] as! [JSON]).first {$0["task_id"] as? String == t[0]["id"] as? String})
        _ = try call("group_membership",["project_id":p["id"]!,"group_id":group["id"]!,"expected_revision":added["revision"]!,"task_id":t[1]["id"]!,"expected_task_revision":t[1]["revision"]!,"action":"add"])
        let receipt = try edit(p,[try current(p,t[0])],["kind":"triage","triage_id":group["id"]!,"action":"remove"])
        _ = try undo(p,[try current(p,t[0])],receipt)
        let groups = try call("triage_list",["project_id":p["id"]!])["groups"] as! [JSON]
        let restored = try XCTUnwrap((groups.first {$0["id"] as? String == group["id"] as? String}!["members"] as! [JSON]).first {$0["task_id"] as? String == t[0]["id"] as? String})
        XCTAssertEqual(restored["exit_milestone"] as? String,"manual")
        XCTAssertNotEqual(restored["membership_id"] as? String,originalMember["membership_id"] as? String)
    }

    func testUndoAssignmentPreservesAnInterveningReasonAndRevalidatesEligibility() throws {
        let (p,t) = try fixture()
        let unchangedReasonReceipt = try edit(p,[t[1]],["kind":"assignee","planned_assignee":"human"])
        _ = try undo(p,[try current(p,t[1])],unchangedReasonReceipt)
        XCTAssertNil(try current(p,t[1])["assignment_reason"])
        let receipt = try edit(p,[t[0]],["kind":"assignee","planned_assignee":"human"])
        var ticket = try current(p,t[0])
        ticket = try call("task_edit",["project_id":p["id"]!,"task_id":ticket["id"]!,"expected_revision":ticket["revision"]!,"patch":["assignment_reason":"Later explanation"]])
        _ = try undo(p,[ticket],receipt)
        let restored = try current(p,t[0])
        XCTAssertEqual(restored["planned_assignee"] as? String,"unassigned")
        XCTAssertEqual(restored["assignment_reason"] as? String,"Later explanation")
    }

    func testUndoAfterActualArchiveCleanupKeepsOriginalBytesUnavailable() throws {
        let (p,t) = try fixture()
        _ = try call("archive_storage_settings",["project_id":p["id"]!,"expected_revision":p["revision"]!,"settings_revision":p["settings_revision"]!,"archive_storage":["preset":"clean_large_managed_on_archive","large_original_bytes":1,"retained_budget_bytes":0]])
        let source = directory.appendingPathComponent("owned-original.bin");try Data(repeating:3,count:64).write(to:source)
        let file = try call("attachment_add",["project_id":p["id"]!,"task_id":t[0]["id"]!,"path":source.path])
        let receipt = try edit(p,[try current(p,t[0])],["kind":"archive","action":"archive"])
        let preview = try call("attachment_cleanup_preview",["project_id":p["id"]!,"task_id":t[0]["id"]!]),archived = try current(p,t[0])
        _ = try call("task_archive",["project_id":p["id"]!,"task_id":t[0]["id"]!,"expected_revision":archived["revision"]!,"action":"archive","cleanup":true,"cleanup_preview_id":preview["cleanup_preview_id"]!])
        try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {
            var job = try self.router.records(db,type:"cleanup_job",project:p["id"] as? String).last!
            job["enqueued_at_ms"] = Int64(1);job["not_before_ms"] = Int64(2);job["revision"] = try self.router.nextCleanupJobRevision(job)
            try self.router.save(db,job,type:"cleanup_job");return .commit
        } }
        try router.runStorageMaintenance()
        XCTAssertFalse(FileManager.default.fileExists(atPath:file["path"] as! String))
        _ = try undo(p,[try current(p,t[0])],receipt)
        XCTAssertFalse(bool(try current(p,t[0]),"archived"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:file["path"] as! String))
        XCTAssertTrue(FileManager.default.fileExists(atPath:source.path))
    }

    func testStatusUndoCannotRestoreDoneWithoutCompletionGates() throws {
        let (p,t) = try fixture()
        try router.dbQueue.writeWithoutTransaction { db in try router.withValidatedDomainTransaction(db) {
            var ticket = try self.router.scoped(db,t[0]["id"] as! String,p["id"] as! String,type:"task")
            ticket["status_id"] = try self.router.status(db,p["id"] as! String,"done")["id"]
            try self.router.save(db,self.router.revised(ticket),type:"task");return .commit
        } }
        let receipt = try edit(p,[try current(p,t[0])],["kind":"status","action":"reopen","reason":"Completion needs another pass"])
        let preview = try undo(p,[try current(p,t[0])],receipt,preview:true)
        XCTAssertEqual(int(preview,"affected_count"),0)
        XCTAssertEqual((preview["rows"] as! [JSON])[0]["code"] as? String,"INVALID_TRANSITION")
    }

    func testBulkStatusRequiresReasonBeforeRowsAndRecordsItForEveryTicket() throws {
        let (p,t) = try fixture()
        for preview in [true,false] {
            for action in ["cancel","reopen"] {
                XCTAssertThrowsError(try edit(p,t,["kind":"status","action":action],preview:preview)) { error in
                    XCTAssertEqual((error as? CoreError)?.code,"INVALID_INPUT")
                    XCTAssertEqual((error as? CoreError)?.message,"Add a reason to cancel or reopen tickets.")
                    XCTAssertNil((error as? CoreError)?.details["rows"])
                }
            }
        }
        for ticket in t {
            XCTAssertEqual(try jsonString(current(p,ticket)),try jsonString(ticket))
            let events = try call("history_list",["project_id":p["id"]!,"task_id":ticket["id"]!])["events"] as! [JSON]
            XCTAssertFalse(events.contains {$0["kind"] as? String == "task_transitioned"})
        }
        for invalid in [" \n",String(repeating:"é",count:2001)] {
            code("INVALID_INPUT") {_ = try self.edit(p,t,["kind":"status","action":"cancel","reason":invalid])}
        }
        for (action,reason) in [("cancel","Scope no longer needed"),("reopen","Scope restored")] {
            let tasks = try t.map {try current(p,$0)}
            XCTAssertEqual(int(try edit(p,tasks,["kind":"status","action":action,"reason":reason],preview:true),"affected_count"),t.count)
            let receipt = try edit(p,tasks,["kind":"status","action":action,"reason":reason])
            XCTAssertEqual(int(receipt,"affected_count"),t.count)
            for ticket in t {
                let events = try call("history_list",["project_id":p["id"]!,"task_id":ticket["id"]!])["events"] as! [JSON]
                XCTAssertEqual(events.filter {$0["kind"] as? String == "task_transitioned" && ($0["data"] as? JSON)?["reason"] as? String == reason}.count,1)
            }
        }
    }

    func testStatusUndoRecordsOriginalCommandAndOptionalReason() throws {
        let (p,t) = try fixture()
        for explanation in [nil,"Scope is needed again"] as [String?] {
            let receipt = try edit(p,try t.map {try current(p,$0)},["kind":"status","action":"cancel","reason":"Scope removed"])
            let canceled = try t.map {try current(p,$0)}
            XCTAssertEqual(int(try undo(p,canceled,receipt,preview:true,reason:explanation),"affected_count"),t.count)
            _ = try undo(p,canceled,receipt,reason:explanation)
            let reason = "Undo of bulk change \(receipt["command_id"]!)" + (explanation.map {": " + $0} ?? "")
            for ticket in t {
                XCTAssertEqual(try current(p,ticket)["status_id"] as? String,ticket["status_id"] as? String)
                let events = try call("history_list",["project_id":p["id"]!,"task_id":ticket["id"]!])["events"] as! [JSON]
                XCTAssertTrue(events.contains {$0["kind"] as? String == "task_transitioned" && ($0["data"] as? JSON)?["reason"] as? String == reason})
            }
        }
        // Undo of a reopen must also supply a reason when returning to Canceled.
        _ = try edit(p,try t.map {try current(p,$0)},["kind":"status","action":"cancel","reason":"Close the scope"])
        let reopened = try edit(p,try t.map {try current(p,$0)},["kind":"status","action":"reopen","reason":"Recheck the scope"])
        _ = try undo(p,try t.map {try current(p,$0)},reopened)
        for ticket in t {XCTAssertEqual(try current(p,ticket)["status_category"] as? String,"canceled")}
    }

    func testBulkAssignmentForwardsExplicitReasonToEveryRow() throws {
        let (p,t) = try fixture(),reason = "Owner will inspect this scope"
        _ = try edit(p,t,["kind":"assignee","planned_assignee":"human","assignment_reason":reason])
        for ticket in t {
            XCTAssertEqual(try current(p,ticket)["assignment_reason"] as? String,reason)
            let events = try call("history_list",["project_id":p["id"]!,"task_id":ticket["id"]!])["events"] as! [JSON]
            XCTAssertTrue(events.contains {($0["data"] as? JSON)?["assignment_reason"] as? String == reason})
        }
    }

    func testBulkFirstAssignmentNeedsNoReasonButReassignmentDoes() throws {
        let (p,t) = try fixture()
        _ = try edit(p,[t[0],t[1]],["kind":"assignee","planned_assignee":"human"])
        let assigned = try current(p,t[0])
        XCTAssertNil(assigned["assignment_reason"])
        let unchanged = try edit(p,[assigned],["kind":"assignee","planned_assignee":["kind":"human"]],preview:true)
        XCTAssertEqual(int(unchanged,"affected_count"),1)
        let selected = [try current(p,t[0]),t[2]]
        let change: JSON = ["kind":"assignee","planned_assignee":"unassigned"]
        let preview = try edit(p,selected,change,preview:true)
        XCTAssertEqual(int(preview,"affected_count"),1)
        let refused = (preview["rows"] as! [JSON])[0]
        XCTAssertEqual(refused["code"] as? String,"INVALID_INPUT")
        XCTAssertTrue((refused["reason"] as? String)?.contains("existing planned assignee") == true)
        code("BULK_CONFLICT") {_ = try self.edit(p,selected,change)}
        XCTAssertEqual(int(try current(p,t[0]),"revision"),int(assigned,"revision"))
        XCTAssertEqual(int(try current(p,t[2]),"revision"),int(t[2],"revision"))
        let reason = "Clear the owner preference for worker pickup"
        _ = try edit(p,[try current(p,t[0]),try current(p,t[1])],["kind":"assignee","planned_assignee":"unassigned","assignment_reason":reason])
        for ticket in t.prefix(2) {
            let events = try call("history_list",["project_id":p["id"]!,"task_id":ticket["id"]!])["events"] as! [JSON]
            XCTAssertTrue(events.contains {
                let data = $0["data"] as? JSON ?? [:]
                return data["from_assignee"] as? String == "human" && data["to_assignee"] as? String == "unassigned" && data["assignment_reason"] as? String == reason
            })
        }
    }

    func testPreparedSchemasMatchDiscoveredBulkParameters() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let schema = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("contracts/ticket-bulk-edit.schema.json"))) as! JSON
        let properties = schema["properties"] as! JSON
        XCTAssertEqual(try jsonString(properties["changes"]!),try jsonString(CommandRouter.ticketBulkChangesSchema))
        XCTAssertEqual(try jsonString(properties["tasks"]!),try jsonString(CommandRouter.ticketBulkTasksSchema))
        let tools = router.toolCatalog(owner)
        for name in ["task_bulk_edit","task_bulk_undo"] {XCTAssertNotNil(tools.first {$0["name"] as? String == name})}
        let assistant = Caller(role:"assistant",installation:"assistant",projectIDs:[])
        XCTAssertFalse(router.toolCatalog(assistant).contains {($0["name"] as? String ?? "").hasPrefix("task_bulk_")})
    }

    func testAssistantCannotBulkEditOrBeAssignedAndProjectArchiveAuthorityRemains() throws {
        let (p,t) = try fixture(),sid = UUID().uuidString
        _ = try call("session_register",["project_id":p["id"]!,"session_id":sid,"role":"assistant","provider":"codex"])
        let denied = try edit(p,[t[0]],["kind":"assignee","planned_assignee":["kind":"agent","session_id":sid]],preview:true)
        XCTAssertEqual(int(denied,"affected_count"),0)
        let assigned = try edit(p,[t[0]],["kind":"assignee","planned_assignee":"human"])
        XCTAssertEqual(int(assigned,"affected_count"),1);XCTAssertEqual(try current(p,t[0])["planned_assignee"] as? String,"human")
        code("INVALID_INPUT") {_ = try self.edit(p,t,["kind":"status","action":"complete"])}
        code("INVALID_INPUT") {_ = try self.edit(p,[t[1],t[1]],["kind":"archive","action":"archive"])}
        let workerID = UUID().uuidString
        _ = try call("session_register",["project_id":p["id"]!,"session_id":workerID,"role":"worker","provider":"codex"])
        var policy = try call("policy_get",["project_id":p["id"]!])["policy"] as! JSON;policy["agent_rule_changes"] = "owner_only"
        let settings = try call("project_settings_get",["project_id":p["id"]!])
        _ = try call("policy_apply",["project_id":p["id"]!,"expected_revision":settings["revision"]!,"policy":policy])
        let worker = Caller(role:"worker",installation:"bulk-worker",projectIDs:[p["id"] as! String],sessionID:workerID,workspace:directory.path)
        let preview = try call("task_bulk_edit",["project_id":p["id"]!,"tasks":refs([t[1]]),"changes":["kind":"archive","action":"archive"],"preview":true],caller:worker)
        XCTAssertEqual((preview["rows"] as! [JSON])[0]["code"] as? String,"HUMAN_CHANNEL_REQUIRED")
    }
}
