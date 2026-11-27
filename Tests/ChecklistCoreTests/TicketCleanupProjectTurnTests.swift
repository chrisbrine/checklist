import ChecklistTestSupport
import Dispatch
import XCTest
import GRDB
@testable import ChecklistCore

/// CL-392: one project must not hold every cleanup turn, a limit refusal must
/// not repeat every minute, and cleanup's own outcome rows must not stop cleanup.
extension TicketLifecycleCleanupTests {
    func testCL520AutomaticPurgePreservesAnotherProjectsAttachmentReplyOnLegacyStore() throws {
        try attachmentOperationAcrossAutomaticPurge(sameProject:false)
    }

    func testCL520AutomaticPurgeRetiresSameProjectAttachmentReply() throws {
        try attachmentOperationAcrossAutomaticPurge(sameProject:true)
    }

    func testCL520AutomaticPurgeRetiresImportPreviewOfAnotherProjectsExport() throws {
        let (source,closed,_) = try fixture(age:20)
        let destination = try otherProjectForPurgeOverlap()
        let export = directory.appendingPathComponent("source-export")
        _ = try call("export_project",["project_id":source["id"]!,"path":export.path])
        let input: JSON = ["project_id":destination["id"]!,"path":export.path,"source_format":"checklist-project/1",
                           "source_namespace":"synthetic-export","command_id":uuid()]
        let preview = try call("import_preview",input)
        XCTAssertTrue(try jsonString(preview).contains(try XCTUnwrap(closed["title"] as? String)))
        let selector = try operationAcrossAutomaticPurge("import_preview",input:input,purging:closed)
        assertOperationReplyExpired(selector)
        let replay = try router.handle(method:"import_preview",params:input,caller:owner)
        XCTAssertEqual((replay["data"] as? JSON)?["operation_id"] as? String,selector["operation_id"] as? String)
        XCTAssertEqual((replay["data"] as? JSON)?["state"] as? String,"succeeded")
    }

    private func otherProjectForPurgeOverlap() throws -> JSON {
        let workspace = directory.appendingPathComponent("other-project")
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let project = try call("project_create",["name":"Other project","key_prefix":"OP","root_path":workspace.path])
        _ = try call("epic_create",["project_id":project["id"]!,"name":"Other project tickets"])
        _ = try configure(project,settings:["done_evidence_enabled":false,"closed_purge_enabled":false,"closed_days":15])
        return project
    }

    private func operationAcrossAutomaticPurge(_ method: String,input: JSON,purging closed: JSON) throws -> JSON {
        let command = try XCTUnwrap(input["command_id"] as? String)
        let id = CommandRouter.commandOperationID(principal:owner.principal,command:command)
        let lane = DispatchQueue(label:"operation-across-automatic-purge")
        let entered = DispatchSemaphore(value:0),release = DispatchSemaphore(value:0)
        router.configureCommandOperations(on:lane)
        router.commandOperations.executionProbe = {running in
            guard running == id else {return}
            entered.signal()
            _ = release.wait(timeout:.now() + 20)
        }
        defer {
            release.signal()
            lane.sync {}
            router.commandOperations.executionProbe = nil
        }
        let accepted = try router.handle(method:method,params:input,caller:owner)
        XCTAssertEqual(accepted["command_outcome"] as? String,"accepted")
        XCTAssertEqual((accepted["data"] as? JSON)?["operation_id"] as? String,id)
        XCTAssertEqual(entered.wait(timeout:.now() + 10),.success)
        let selector: JSON = ["project_id":try XCTUnwrap(input["project_id"] as? String),"operation_id":id]
        XCTAssertEqual(try call("operation_get",selector)["state"] as? String,"running")
        try router.runTicketLifecycleCleanup()
        let purged = try read(closed)
        XCTAssertTrue(bool(purged,"purged"))
        XCTAssertEqual(purged["purged_by"] as? String,"system:ticket_cleanup")
        XCTAssertEqual(try call("operation_get",selector)["state"] as? String,"running")
        release.signal()
        lane.sync {}
        return selector
    }

    private func assertOperationReplyExpired(_ selector: JSON,file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertThrowsError(try call("operation_get",selector),file:file,line:line) {error in
            XCTAssertEqual((error as? CoreError)?.code,"COMMAND_RESULT_EXPIRED",file:file,line:line)
        }
    }

    private func attachmentOperationAcrossAutomaticPurge(sameProject: Bool) throws {
        let (purgeProject,closed,_) = try fixture(age:20)
        let activeProject = sameProject ? purgeProject : try otherProjectForPurgeOverlap()
        let project = try XCTUnwrap(activeProject["id"] as? String)
        let open = try call("task_create",["project_id":project,"title":"Open attachment work"])
        let task = try XCTUnwrap(open["id"] as? String)
        let source = URL(fileURLWithPath:try XCTUnwrap(activeProject["root_path"] as? String))
            .appendingPathComponent("concurrent-attachment.txt")
        let bytes = Data("The original attachment operation committed.".utf8)
        try bytes.write(to:source)
        if !sameProject {
            // Reopen a store with just the legacy epoch, before any scoped key
            // has been written for either project.
            try router.dbQueue.write {db in
                try db.execute(sql:"INSERT INTO metadata(key,value) VALUES ('command-operation-purge-epoch',?)",arguments:[uuid()])
            }
            let root = router.root
            try router.closeStore()
            router = try TestStore.router(root:root)
        }
        let command = uuid()
        let input: JSON = ["project_id":project,"task_id":task,"path":source.path,"command_id":command]
        let selector = try operationAcrossAutomaticPurge("attachment_add",input:input,purging:closed)
        func attachments() throws -> [JSON] {
            try router.dbQueue.read {db in
                try self.router.records(db,type:"attachment",project:project).filter {$0["task_id"] as? String == task}
            }
        }
        let committed = try XCTUnwrap(try attachments().first)
        if sameProject {
            assertOperationReplyExpired(selector)
            let receipt = try router.dbQueue.read {db in
                try String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[self.owner.principal,command])
            }
            XCTAssertEqual(receipt,CommandRouter.prunedResult)
        } else {
            let status = try call("operation_get",selector)
            XCTAssertEqual(status["state"] as? String,"succeeded")
            let result = try XCTUnwrap(status["result"] as? JSON)
            XCTAssertEqual(result["command_id"] as? String,command)
            let attachment = try XCTUnwrap(result["data"] as? JSON)
            XCTAssertEqual(attachment["id"] as? String,committed["id"] as? String)
            XCTAssertEqual(attachment["sha256"] as? String,ChecklistCore.hash(bytes))
        }
        let replay = try router.handle(method:"attachment_add",params:input,caller:owner)
        XCTAssertEqual((replay["data"] as? JSON)?["operation_id"] as? String,selector["operation_id"] as? String)
        XCTAssertEqual((replay["data"] as? JSON)?["state"] as? String,"succeeded")
        XCTAssertEqual(try attachments().count,1)
        if sameProject {assertOperationReplyExpired(selector)}
    }

    private func setDue(_ pid: String,at time: Double = 0) throws {
        try router.dbQueue.write {try $0.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",arguments:["ticket-cleanup-next:" + pid,String(time)])}
    }
    private func preparedProject() throws -> String? {
        try router.ticketCleanupMaintenanceLock.withLock {
            try router.readers!.read {try self.router.prepareTicketLifecycleCleanup($0)?.selection["project_id"] as? String}
        }
    }
    private func addEvents(_ pid: String,count: Int,kind: String,entity: String,data: String) throws {
        try router.dbQueue.write {db in
            try db.execute(sql:"WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<?) INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data) SELECT ?||i,?,?,'fixture',?,?,? FROM n",arguments:[count,uuid() + "-",pid,entity,kind,"2026-10-01T00:00:00Z",data])
        }
    }
    private func retry(_ pid: String,_ tid: String) throws -> TicketCleanupRetry? {
        try router.dbQueue.read {try self.router.ticketCleanupRetryEntries($0,project:pid)[tid]}
    }

    func testCL392DueProjectsTakeTurnsWhileTheFirstProjectStaysDue() throws {
        let (first,_,_) = try fixture(),(second,_,_) = try fixture()
        let a = first["id"] as! String,b = second["id"] as! String
        var served: [String] = []
        // No commit: a preparation that never succeeds keeps both projects due.
        for _ in 0..<4 {
            try setDue(a);try setDue(b)
            served.append(try XCTUnwrap(try preparedProject()))
        }
        XCTAssertEqual(Set(served),[a,b])
        XCTAssertEqual(served[0],served[2]);XCTAssertEqual(served[1],served[3]);XCTAssertNotEqual(served[0],served[1])
    }

    func testCL392PreparationThatThrowsSpendsItsTurn() throws {
        let (first,_,_) = try fixture(),(second,_,_) = try fixture()
        let a = first["id"] as! String,b = second["id"] as! String
        var served: [String] = []
        for _ in 0..<2 {
            try setDue(a);try setDue(b)
            struct Failure: Error {}
            XCTAssertThrowsError(try router.ticketCleanupMaintenanceLock.withLock {
                try router.readers!.read {db in
                    served.append(try XCTUnwrap(try self.router.prepareTicketLifecycleCleanup(db)?.selection["project_id"] as? String))
                    throw Failure()
                }
            })
        }
        XCTAssertEqual(Set(served),[a,b])
    }

    func testCL392EarliestDueProjectGoesFirstWhenNoneWasServed() throws {
        let (first,_,_) = try fixture(),(second,_,_) = try fixture()
        let a = first["id"] as! String,b = second["id"] as! String
        router.ticketCleanupProjectTurns = [:]
        try setDue(a,at:200);try setDue(b,at:100)
        XCTAssertEqual(try preparedProject(),b)
    }

    func testCL392LaterProjectCleansWhileAnEarlierProjectStaysDue() throws {
        let (first,_,_) = try fixture(),(second,_,file) = try fixture()
        let a = first["id"] as! String
        for _ in 0..<2 {try setDue(a);try router.runTicketLifecycleCleanup()}
        try finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath:file["path"] as! String))
        XCTAssertTrue(try receipts(second).contains {($0["summary"] as? JSON)?["removed_count"] as? Int == 1})
    }

    func testCL392LimitRefusalDoublesToOneHourAndADoneWakeStartsAgain() throws {
        var count = 0
        for expected in [60.0,120,240,480,960,1920,3600,3600] {
            let time = Date(timeIntervalSince1970:1000)
            let value = TicketCleanupRetry(refusedAfter:TicketCleanupRetry(deadline:0,token:"t",refusals:count),at:time)
            XCTAssertEqual(value.deadline,1000 + expected,accuracy:0.001);count += 1;XCTAssertEqual(value.refusals,count)
        }
        XCTAssertEqual(TicketCleanupRetry(refusedAfter:nil,at:Date(timeIntervalSince1970:0)).deadline,60,accuracy:0.001)

        let (project,task,_) = try fixture(),pid = project["id"] as! String,tid = task["id"] as! String
        try addEvents(pid,count:CommandRouter.ticketCleanupSelectedHistoryRowLimit + 1,kind:"history_fixture",entity:tid,data:"{}")
        var time = Date().addingTimeInterval(1)
        try router.runTicketLifecycleCleanup(at:time)
        let firstRetry = try XCTUnwrap(try retry(pid,tid))
        XCTAssertEqual(firstRetry.refusals,1);XCTAssertEqual(firstRetry.deadline,time.timeIntervalSince1970 + 60,accuracy:0.001)
        try setDue(pid);time = Date(timeIntervalSince1970:firstRetry.deadline + 1)
        try router.runTicketLifecycleCleanup(at:time)
        let secondRetry = try XCTUnwrap(try retry(pid,tid))
        XCTAssertEqual(secondRetry.refusals,2);XCTAssertEqual(secondRetry.deadline,time.timeIntervalSince1970 + 120,accuracy:0.001)
        // The value survives its stored form.
        XCTAssertEqual(try jsonString(secondRetry.value).contains("refusals"),true)

        try mark(project,task,category:"queued");try mark(project,task,category:"done")
        let woken = try XCTUnwrap(try retry(pid,tid))
        XCTAssertEqual(woken.refusals,0);XCTAssertLessThanOrEqual(woken.deadline,Date().timeIntervalSince1970)
        time = Date().addingTimeInterval(1)
        try router.runTicketLifecycleCleanup(at:time)
        let restarted = try XCTUnwrap(try retry(pid,tid))
        XCTAssertEqual(restarted.refusals,1);XCTAssertEqual(restarted.deadline,time.timeIntervalSince1970 + 60,accuracy:0.001)
    }

    func testCL392ConcurrentWriteFenceKeepsItsSixtySecondRetry() throws {
        let (project,task,_) = try fixture(),pid = project["id"] as! String,tid = task["id"] as! String
        let time = Date()
        try router.withTicketCleanupPreparation({db in
            let prepared = try self.router.prepareTicketLifecycleCleanup(db,at:time)
            try self.write {db in
                var value = try self.router.record(db,tid,type:"task");value["revision"] = int(value,"revision") + 1
                try self.router.save(db,value,type:"task")
            }
            return prepared
        }) {db,_,prepared in try self.router.commitTicketLifecycleCleanup(db,prepared:prepared,at:time)}
        let value = try XCTUnwrap(try retry(pid,tid))
        XCTAssertEqual(value.refusals,0);XCTAssertEqual(value.deadline,time.timeIntervalSince1970 + 60,accuracy:0.001)
    }

    func testCL395ByteTurnsAlternateWithTheNewestReceiptAndKeepTheQueuePosition() throws {
        let (project,firstTask,firstFile) = try fixture(),pid = project["id"] as! String
        let second = try call("task_create",["project_id":pid,"title":"Later closed work"])
        let source = URL(fileURLWithPath:project["root_path"] as! String).appendingPathComponent("later.txt");try Data("later evidence".utf8).write(to:source)
        let secondFile = try call("attachment_add",["project_id":pid,"task_id":second["id"]!,"path":source.path,"mode":"managed_copy"])
        try mark(project,second,category:"done")
        try ticketCleanupBackupTemplate(router,objects:try [firstFile,secondFile].map {file in
            ["relative_path":try XCTUnwrap(ManagedPaths.relative(file["path"] as! String,family:"objects",root:router.root)),"sha256":file["sha256"]!,"size":file["size"]!,"kind":"file"]
        })
        for _ in 0..<4 {try setDue(pid);router.ticketCleanupYieldAt = nil;try router.runTicketLifecycleCleanup()}
        func selected() throws -> [String] {
            var order: [String] = []
            try router.ticketCleanupMaintenanceLock.withLock {
                _ = try router.readers!.read {db in
                    try self.router.prepareTicketObjectDeletionCohort(db) {value in
                        if value["phase"] as? String == "selected" {order = (value["receipts"] as? [JSON] ?? []).compactMap {$0["task_id"] as? String}}
                    }
                }
            }
            return order
        }
        let a = firstTask["id"] as! String,b = second["id"] as! String
        router.ticketCleanupByteNewestTurns = [:]
        XCTAssertEqual(try selected().prefix(2),[a,b])
        let cursor = try router.dbQueue.read {try String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-byte-cursor:" + pid])}
        XCTAssertEqual(try selected().prefix(2),[b,a])
        XCTAssertEqual(try router.dbQueue.read {try String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-byte-cursor:" + pid])},cursor)
        try finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath:firstFile["path"] as! String))
        XCTAssertFalse(FileManager.default.fileExists(atPath:secondFile["path"] as! String))
    }

    func testCL392OutcomeRowsOfOtherTicketsDoNotCountAgainstTheHistoryLimit() throws {
        let (project,task,_) = try fixture(),pid = project["id"] as! String
        let foreign = "{\"origin\":\"automatic_cleanup\",\"receipt_id\":\"\(uuid())\",\"removed_bytes\":1,\"state\":\"removed\",\"task_id\":\"\(uuid())\"}"
        try addEvents(pid,count:CommandRouter.ticketCleanupSelectedHistoryRowLimit + 1,kind:"ticket_evidence_cleanup_outcome",entity:pid,data:foreign)
        let items = try XCTUnwrap(try selection(project)["items"] as? [JSON])
        let item = try XCTUnwrap(items.first {$0["task_id"] as? String == task["id"] as? String})
        XCTAssertEqual(item["action"] as? String,"done_evidence",item["reason"] as? String ?? "")
        // The selected history bound also applies to the manual purge plan.
        XCTAssertNoThrow(try router.readers!.read {try self.router.ticketPurgePlan($0,task:self.read(task))})
    }

    func testCL392OutcomeRowThatNamesARemovalKeyStaysInThePlan() throws {
        let (project,task,_) = try fixture(),pid = project["id"] as! String,tid = task["id"] as! String
        let message = uuid(),other = uuid()
        try write {db in try self.router.save(db,["id":message,"project_id":pid,"task_id":tid,"revision":1,"body":"Owned"],type:"message")}
        func outcome(task: String,receipt: String) -> String {"{\"origin\":\"automatic_cleanup\",\"receipt_id\":\"\(receipt)\",\"removed_bytes\":1,\"state\":\"removed\",\"task_id\":\"\(task)\"}"}
        try addEvents(pid,count:1,kind:"ticket_evidence_cleanup_outcome",entity:pid,data:outcome(task:tid,receipt:other))
        try addEvents(pid,count:1,kind:"ticket_evidence_cleanup_outcome",entity:pid,data:outcome(task:other,receipt:message))
        try addEvents(pid,count:1,kind:"ticket_evidence_cleanup_outcome",entity:message,data:outcome(task:other,receipt:other))
        try addEvents(pid,count:1,kind:"ticket_evidence_cleanup_outcome",entity:pid,data:outcome(task:other,receipt:"foreign-receipt"))
        try addEvents(pid,count:1,kind:"ticket_evidence_cleanup_outcome",entity:pid,data:"not json \(tid)")
        try router.readers!.read {db in
            let current = try self.router.record(db,tid,type:"task")
            let batch = try self.router.ticketCleanupInventories(db,tasks:[current])
            let inventory = try XCTUnwrap(batch.inventories[tid])
            let graph = try self.router.ticketPurgeReferenceGraph(task:current,inventory:inventory)
            let observation = try self.router.ticketCleanupEventObservation(db,tasks:[current],inventories:batch.inventories,referenceGraphs:[tid:graph])
            XCTAssertNil(observation.errors[tid])
            let manual = try self.router.ticketPurgePlan(db,task:current,inventory:inventory)
            let observed = try self.router.ticketPurgePlan(db,task:current,inventory:inventory,historyObservation:observation,referenceGraph:graph)
            XCTAssertEqual(manual.digest,observed.digest)
            let rows = observed.events.filter {($0["data"] as String).contains("automatic_cleanup")}.map {$0["data"] as String}
            XCTAssertTrue(rows.contains(outcome(task:tid,receipt:other)))
            XCTAssertTrue(rows.contains(outcome(task:other,receipt:message)))
            XCTAssertTrue(rows.contains(outcome(task:other,receipt:other)))
            XCTAssertFalse(rows.contains(outcome(task:other,receipt:"foreign-receipt")))
        }
    }
}
