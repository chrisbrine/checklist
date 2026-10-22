import XCTest
import GRDB
@testable import ChecklistCore

extension TicketRetirementTests {
    func trash(_ p: JSON,_ t: JSON) throws -> JSON {try call("task_archive",params(p,try read(p,t)).merging(["action":"trash"]) {_,new in new})}
    func purge(_ p: JSON,_ t: JSON,_ preview: JSON) throws -> JSON {try call("task_purge",params(p,t).merging(["preview_digest":preview["digest"]!]) {_,new in new})}

    func testPurgeRemovesOwnedContentKeepsTombstoneRelationsSharedRecordsAndFiles() throws {
        let (p,original) = try fixture(),pid = p["id"] as! String,tid = original["id"] as! String
        let other = try call("task_create",["project_id":pid,"title":"Other ticket"])
        _ = try call("task_link",params(p,other).merging(["relation":"depends_on","target_task_id":tid]) {_,new in new})
        _ = try note(p,original,["body":"Private ticket note"])
        let workspace = directory.appendingPathComponent("external-workspace");try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let external = workspace.appendingPathComponent("external.txt");try Data("External original".utf8).write(to:external)
        let attachment = try call("attachment_add",["project_id":pid,"task_id":tid,"path":external.path,"mode":"managed_copy"])
        let storedPath = attachment["path"] as! String
        _ = try call("attachment_add",["project_id":pid,"task_id":tid,"path":external.path,"mode":"reference"])
        var epic = try call("epic_create",["project_id":pid,"name":"Epic"])
        epic = try call("group_membership",["project_id":pid,"group_id":epic["id"]!,"task_id":tid,"expected_revision":epic["revision"]!,"action":"add"])
        var triage = try call("triage_create",["project_id":pid,"name":"Triage"])
        triage = try call("group_membership",["project_id":pid,"group_id":triage["id"]!,"task_id":tid,"expected_revision":triage["revision"]!,"action":"add"])
        let attempt = uuid(),message = uuid(),delivery = uuid(),shared = uuid()
        try fixtureWrite {db in
            var copy = attachment;copy["id"] = uuid();copy["task_id"] = other["id"]!;try self.router.save(db,copy,type:"attachment")
            for type in ["attempt","checkpoint","request","review_request","review","finding","manifest","task_session","source_capture","source_execution"] {
                let id = type == "attempt" ? attempt : uuid()
                try self.router.save(db,["id":id,"project_id":pid,"task_id":tid,"state":type == "request" ? "answered" : "finished","revision":1,"private_text":"Only this ticket"],type:type)
            }
            try self.router.save(db,["id":message,"project_id":pid,"task_id":tid,"body":"Private message","revision":1],type:"message")
            try self.router.save(db,["id":delivery,"project_id":pid,"message_id":message,"state":"acknowledged","revision":1],type:"delivery")
            try self.router.save(db,["id":shared,"project_id":pid,"task_id":tid,"body":"Shared evidence","revision":1],type:"manifest")
            try self.router.save(db,["id":uuid(),"project_id":pid,"task_id":other["id"]!,"evidence_ref":shared,"revision":1],type:"manifest")
            var project = try self.router.record(db,pid,type:"project");project["root_path"] = workspace.path;try self.router.save(db,project,type:"project")
            try self.router.event(db,caller:self.owner,project:pid,entity:tid,kind:"private_fixture",data:["body":"Private event text"])
            try self.router.event(db,caller:self.owner,project:pid,entity:message,kind:"message_acknowledged",data:["body":"Private receipt text"])
        }
        let t = try trash(p,original)
        let before = try router.dbQueue.read {try Row.fetchAll($0,sql:"SELECT seq FROM events WHERE project_id=? ORDER BY seq",arguments:[pid]).map {$0["seq"] as Int64}}
        let page = try call("history_list",["project_id":pid,"task_id":tid,"limit":1])
        let preview = try call("task_purge_preview",params(p,t))
        XCTAssertGreaterThanOrEqual((preview["impact"] as! JSON)["shared_record_count"] as? Int ?? 0,1)
        let result = try purge(p,t,preview)
        XCTAssertEqual(result["managed_bytes_action"] as? String,"completed")
        let tombstone = try router.dbQueue.read {try router.record($0,tid,type:"task")}
        XCTAssertEqual(Set(tombstone.keys),["id","project_id","key","title","revision","purged","purged_at","purged_by","archived","trashed"])
        XCTAssertEqual(tombstone["title"] as? String,"Purged ticket")
        XCTAssertEqual(tombstone["key"] as? String,original["key"] as? String)
        XCTAssertEqual(tombstone["purged_by"] as? String,owner.principal)
        try router.dbQueue.read {db in
            XCTAssertEqual(try router.records(db,type:"message",project:pid).count,0)
            XCTAssertEqual(try router.records(db,type:"delivery",project:pid).count,0)
            XCTAssertEqual(try router.records(db,type:"attempt",project:pid).count,0)
            XCTAssertEqual(try router.record(db,shared,type:"manifest")["body"] as? String,"Shared evidence")
            let relations = try router.records(db,type:"relation",project:pid)
            XCTAssertEqual(relations.count,1);XCTAssertEqual(relations[0]["target_task_id"] as? String,tid)
            for group in [epic,triage] {XCTAssertFalse(self.router.triageMemberIDs(try self.router.record(db,group["id"] as! String,type:"group")).contains(tid))}
            let after = try Row.fetchAll(db,sql:"SELECT seq,kind,data FROM events WHERE project_id=? ORDER BY seq",arguments:[pid])
            XCTAssertEqual(Array(after.dropLast()).map {$0["seq"] as Int64},before)
            XCTAssertEqual(after.last?["kind"] as String?,"task_purged")
            XCTAssertFalse(after.contains {($0["data"] as String).contains("Private")})
            XCTAssertEqual((jsonObject(after.last?["data"] as String? ?? ""))["managed_bytes_deleted"] as? Int,0)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath:storedPath))
        XCTAssertEqual(try String(contentsOf:external,encoding:.utf8),"External original")
        XCTAssertNoThrow(try call("history_list",["project_id":pid,"task_id":tid,"cursor":page["next_cursor"]!,"limit":200]))
        XCTAssertTrue((try call("task_list",["project_id":pid,"view":["surface":"trash","status_filter":"all","tag_filter":"all","group_by":"none","order_by":"manual"]])["tickets_page"] as! JSON)["tasks"] is [JSON])
        let dependent = try read(p,other)
        XCTAssertEqual((dependent["prerequisite_blockers"] as! [JSON]).first?["status_category"] as? String,"purged")
        XCTAssertFalse(((try call("task_list",["project_id":pid])["tasks"] as! [JSON]).contains {$0["id"] as? String == tid}))
        code("TICKET_PURGED") {_ = try self.call("task_archive",self.params(p,tombstone).merging(["action":"restore"]) {_,new in new})}
        code("TICKET_PURGED") {_ = try self.note(p,tombstone)}
    }

    func testPurgeRefusesNonTrashActiveWorkPendingRequestsAndAgentCaller() throws {
        let (p,t) = try fixture(),pid = p["id"] as! String,tid = t["id"] as! String
        code("TRASH_REQUIRED") {_ = try self.call("task_purge",self.params(p,t).merging(["preview_digest":"invalid"]) {_,new in new})}
        let trashed = try trash(p,t),preview = try call("task_purge_preview",params(p,trashed))
        let worker = Caller(role:"worker",installation:"untrusted",projectIDs:[pid])
        code("FORBIDDEN") {_ = try self.call("task_purge",self.params(p,trashed).merging(["preview_digest":preview["digest"]!]) {_,new in new},worker)}
        XCTAssertFalse(router.toolCatalog(worker).contains {$0["name"] as? String == "task_purge"})
        for type in ["attempt","review_request","source_execution","request"] {
            let id = uuid()
            try fixtureWrite {db in try self.router.save(db,["id":id,"project_id":pid,"task_id":tid,"state":type == "source_execution" ? "running" : type == "request" ? "pending" : "active","revision":1],type:type)}
            let expected = type == "source_execution" ? "SOURCE_EXECUTION_ACTIVE" : type == "request" ? "OWNER_REQUEST_PENDING" : "CLAIM_CONFLICT"
            code(expected) {_ = try self.purge(p,trashed,preview)}
            try fixtureWrite {db in try db.execute(sql:"DELETE FROM records WHERE id=?",arguments:[id])}
        }
        try fixtureWrite {db in var value = try self.router.record(db,tid,type:"task");value["active_verification_request_id"] = "verification";try self.router.save(db,value,type:"task")}
        code("CLAIM_CONFLICT") {_ = try self.purge(p,trashed,preview)}
    }

    func testPurgePreviewRejectsNewNotesAndRevisionChangesAndExpiresOldReceipts() throws {
        let (p,t) = try fixture(),pid = p["id"] as! String,tid = t["id"] as! String
        let command = uuid(),noteParams: JSON = ["project_id":pid,"task_id":tid,"body":"Sensitive receipt","command_id":command]
        _ = try router.handle(method:"message_send",params:noteParams,caller:owner)
        var trashed = try trash(p,t),preview = try call("task_purge_preview",params(p,trashed))
        _ = try note(p,t,["body":"A note after the preview"])
        code("PURGE_PREVIEW_STALE") {_ = try self.purge(p,trashed,preview)}
        preview = try call("task_purge_preview",params(p,trashed))
        trashed = try call("task_edit",params(p,trashed).merging(["title":"Changed after preview"]) {_,new in new})
        code("PURGE_PREVIEW_STALE") {_ = try self.purge(p,trashed,preview)}
        let latest = try call("task_purge_preview",params(p,trashed))
        var purgeParams = params(p,trashed);purgeParams["preview_digest"] = latest["digest"]!;purgeParams["command_id"] = uuid()
        let result = try router.handle(method:"task_purge",params:purgeParams,caller:owner)
        XCTAssertEqual((try router.handle(method:"task_purge",params:purgeParams,caller:owner))["replayed"] as? Bool,true)
        XCTAssertTrue((result["data"] as! JSON)["task"] is JSON)
        code("COMMAND_RESULT_EXPIRED") {_ = try self.router.handle(method:"message_send",params:noteParams,caller:self.owner)}
    }

    func testPurgeRollbackRestoresNotesEventsAndCachedReceipts() throws {
        let (p,t) = try fixture(),tid = t["id"] as! String
        _ = try note(p,t,["body":"Must survive rollback"])
        let trashed = try trash(p,t),preview = try call("task_purge_preview",params(p,trashed))
        try router.dbQueue.write {db in try db.execute(sql:"CREATE TRIGGER cl24_purge_failure BEFORE UPDATE ON records WHEN NEW.id='"+tid+"' AND json_extract(NEW.data,'$.purged')=1 BEGIN SELECT RAISE(ABORT,'synthetic purge failure'); END")}
        XCTAssertThrowsError(try purge(p,trashed,preview))
        XCTAssertEqual(try router.dbQueue.read {try router.records($0,type:"message",project:p["id"] as? String).first?["body"] as? String},"Must survive rollback")
        XCTAssertFalse(try read(p,t)["purged"] as? Bool ?? false)
        XCTAssertFalse((try call("history_list",["project_id":p["id"]!,"task_id":tid])["events"] as! [JSON]).contains {$0["kind"] as? String == "task_purged"})
    }
}
