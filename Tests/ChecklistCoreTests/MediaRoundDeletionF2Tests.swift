import ChecklistTestSupport
import Dispatch
import Foundation
import GRDB
import XCTest
@testable import ChecklistCore

extension MediaRoundDeletionTests {
    /// The failed field check had an actual image import and its mutable storage
    /// bookkeeping. A text-only round has none of those rows.
    func testF2ImageFenceAllows180SameProjectNotesEventsAndReceiptsDuringPreparation() throws {
        let f = try Fixture(),task = try results.task(f),writer = try results.session(f,"f2-steady-image-writer")
        // Ordinary setup commands must precede capture: their maintenance tail
        // would otherwise settle the import before the read snapshot opens.
        let round = try cancel(f,imageRound(f,"f2-steady-image.png"),archive:true)
        let before = try f.router.dbQueue.read { db in
            (try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM events WHERE kind='message_saved' AND entity_id=?",arguments:[task["id"] as! String])!,
             try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands WHERE principal=?",arguments:[writer.principal])!)
        }
        var elapsed: TimeInterval = 0
        f.router.mediaRoundDeletionPreparationProbe = {
            let start = ProcessInfo.processInfo.systemUptime
            for index in 0..<180 {
                _ = try self.results.call(f,"message_send",["task_id":task["id"]!,"kind":"note","body":"F2 unrelated same-project note \(index)"],as:writer)
                Thread.sleep(forTimeInterval:0.01)
            }
            elapsed = ProcessInfo.processInfo.systemUptime - start
        }
        defer {f.router.mediaRoundDeletionPreparationProbe = nil}
        let deleted = try worker(f,"media_round_delete",input(f,round))
        XCTAssertEqual(deleted["deleted"] as? Bool,true)
        XCTAssertGreaterThanOrEqual(elapsed,1.8,"The snapshot must span a steady stream, not one intervening write")
        let after = try f.router.dbQueue.read { db in
            (try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM events WHERE kind='message_saved' AND entity_id=?",arguments:[task["id"] as! String])!,
             try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM commands WHERE principal=?",arguments:[writer.principal])!,
             try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE type='message' AND json_extract(data,'$.task_id')=? AND json_extract(data,'$.body') LIKE 'F2 unrelated same-project note %'",arguments:[task["id"] as! String])!)
        }
        XCTAssertEqual(after.0-before.0,180)
        XCTAssertEqual(after.1-before.1,180)
        XCTAssertEqual(after.2,180)
    }

    private func assertF2ContextChanged(_ f: Fixture,_ round: JSON,check: String,type: String,id: String,file: StaticString = #filePath,line: UInt = #line) throws {
        XCTAssertThrowsError(try worker(f,"media_round_delete",input(f,round)),file:file,line:line) {error in
            guard let failure = error as? CoreError else {XCTFail(String(describing:error),file:file,line:line);return}
            XCTAssertEqual(failure.code,"MEDIA_CONTEXT_CHANGED",file:file,line:line)
            XCTAssertEqual(failure.details["check"] as? String,check,file:file,line:line)
            XCTAssertEqual(failure.details["record_type"] as? String,type,file:file,line:line)
            XCTAssertEqual(failure.details["record_id"] as? String,id,file:file,line:line)
            XCTAssertEqual(Set(failure.details.keys),["check","record_type","record_id","preparation_seconds","preparation_timings"],"Refusal diagnostics must remain content-free",file:file,line:line)
            XCTAssertGreaterThanOrEqual(failure.details["preparation_seconds"] as? Double ?? -1,0,file:file,line:line)
        }
    }

    func testF2SameRevisionOwnedChangeReportsContentFreeRecordIdentity() throws {
        let f = try Fixture(),round = try cancel(f,f.round(f.type(checks.schema())))
        let id = try XCTUnwrap(round["id"] as? String)
        var afterWrite = ""
        f.router.mediaRoundDeletionPreparationProbe = {
            try f.router.dbQueue.writeWithoutTransaction {db in
                try f.router.withValidatedDomainTransaction(db) {
                    var value = try f.router.record(db,id,type:"media_round")
                    value["title"] = "Private title must not enter refusal details"
                    try f.router.save(db,value,type:"media_round");return .commit
                }
            }
            afterWrite = try f.allState()
        }
        defer {f.router.mediaRoundDeletionPreparationProbe = nil}
        try assertF2ContextChanged(f,round,check:"planned_record_changed",type:"media_round",id:id)
        XCTAssertEqual(try f.allState(),afterWrite)
    }

    func testF2NewDictionaryKeyReferenceReportsContentFreeRecordIdentity() throws {
        let f = try Fixture(),round = try cancel(f,f.round(f.type(checks.schema())))
        let id = "00000000-0000-0000-0000-000000000451"
        var afterWrite = ""
        f.router.mediaRoundDeletionPreparationProbe = {
            try f.router.dbQueue.writeWithoutTransaction {db in
                try f.router.withValidatedDomainTransaction(db) {
                    try f.router.save(db,["id":id,"project_id":"00000000-0000-0000-0000-000000000452","revision":1,"references":[round["id"] as! String:"Private body must not enter refusal details"]],type:"message")
                    return .commit
                }
            }
            afterWrite = try f.allState()
        }
        defer {f.router.mediaRoundDeletionPreparationProbe = nil}
        try assertF2ContextChanged(f,round,check:"changed_reference",type:"message",id:id)
        XCTAssertEqual(try f.allState(),afterWrite)
    }

    func testF2NewPendingLinkedOwnerRequestReportsContentFreeRecordIdentity() throws {
        let f = try Fixture(),task = try results.task(f),round = try f.round(f.type(checks.schema()))
        _ = try results.link(f,round,task);_ = try cancel(f,round)
        var id = "",afterWrite = ""
        f.router.mediaRoundDeletionPreparationProbe = {
            let request = try self.results.call(f,"human_request_create",["task_id":task["id"]!,"title":"Private pending owner question","blocking":false,"questions":[["id":"q","type":"text","prompt":"Private owner prompt"]]])
            id = request["id"] as! String;afterWrite = try f.allState()
        }
        defer {f.router.mediaRoundDeletionPreparationProbe = nil}
        // The new request ID is captured by the preparation probe before refusal.
        XCTAssertThrowsError(try worker(f,"media_round_delete",input(f,round))) {error in
            guard let failure = error as? CoreError else {XCTFail(String(describing:error));return}
            XCTAssertEqual(failure.code,"MEDIA_CONTEXT_CHANGED")
            XCTAssertEqual(failure.details["check"] as? String,"changed_reference")
            XCTAssertEqual(failure.details["record_type"] as? String,"request")
            XCTAssertEqual(failure.details["record_id"] as? String,id)
            XCTAssertEqual(Set(failure.details.keys),["check","record_type","record_id","preparation_seconds","preparation_timings"])
        }
        XCTAssertEqual(try f.allState(),afterWrite)
    }

    func testF2DeferredImportHousekeepingResumesAfterSuccessfulAndRefusedPreparation() throws {
        for refuse in [false,true] {
            let f = try Fixture(),task = try results.task(f),writer = try results.session(f,"f2-resumed-housekeeping-writer")
            let target = try cancel(f,imageRound(f,"f2-housekeeping-target.png"))
            let targetImports = Set(try f.rows("storage_job").filter {$0["kind"] as? String == "attachment_import"}.map {$0["id"] as! String})
            let neighbor = try imageRound(f,"f2-housekeeping-retained.png",index:1)
            let neighborImport = try XCTUnwrap(f.rows("storage_job").first {$0["kind"] as? String == "attachment_import" && !targetImports.contains($0["id"] as! String)})
            let neighborID = neighborImport["id"] as! String
            XCTAssertEqual(neighborImport["state"] as? String,"committed")
            f.router.mediaRoundDeletionPreparationProbe = {
                let active = try f.router.dbQueue.read {_ in f.router.mediaRoundDeletionPreparations[Data(f.project.utf8)]?.count}
                XCTAssertEqual(active,1,"The active ownership map must cover the pinned snapshot")
                _ = try self.results.call(f,"message_send",["task_id":task["id"]!,"kind":"note","body":"F2 note while import housekeeping is deferred"],as:writer)
                XCTAssertEqual(try f.record(neighborID,"storage_job")["state"] as? String,"committed","The ordinary-note tail must defer the retained neighbor during preparation")
                if refuse {
                    try f.router.dbQueue.writeWithoutTransaction {db in
                        try f.router.withValidatedDomainTransaction(db) {
                            var value = try f.router.record(db,target["id"] as! String,type:"media_round")
                            value["title"] = "A real owned edit must still refuse deletion"
                            try f.router.save(db,value,type:"media_round");return .commit
                        }
                    }
                }
            }
            defer {f.router.mediaRoundDeletionPreparationProbe = nil}
            if refuse {
                XCTAssertThrowsError(try worker(f,"media_round_delete",input(f,target))) {error in
                    XCTAssertEqual((error as? CoreError)?.code,"MEDIA_CONTEXT_CHANGED")
                }
            } else {
                XCTAssertEqual(try worker(f,"media_round_delete",input(f,target))["deleted"] as? Bool,true)
            }
            XCTAssertTrue(try f.router.dbQueue.read {_ in f.router.mediaRoundDeletionPreparations.isEmpty},"Success and refusal must both release preparation ownership")
            XCTAssertEqual(try f.record(neighborID,"storage_job")["state"] as? String,"committed")
            _ = try results.call(f,"message_send",["task_id":task["id"]!,"kind":"note","body":"F2 note after preparation releases housekeeping"],as:writer)
            XCTAssertEqual(try f.record(neighborID,"storage_job")["state"] as? String,"settled","The next ordinary-note maintenance pass must resume the retained import")
            XCTAssertEqual(try f.get(neighbor)["id"] as? String,neighbor["id"] as? String)
            XCTAssertTrue(try f.router.dbQueue.read {_ in f.router.mediaRoundDeletionPreparations.isEmpty})
        }
    }

    func testF2HistoryMatcherFindsDictionaryKeysAndByteExactUnicodeAndKeepsUnrelatedReceipts() throws {
        for selectedSuffix in ["\u{e9}","e\u{301}"] {
            let f = try Fixture(),original = try cancel(f,f.round(f.type(checks.schema())))
            let prefix = "00000000-0000-0000-0000-000000000456"
            let selectedID = prefix + selectedSuffix,neighborID = prefix + (selectedSuffix.utf8.count == 2 ? "e\u{301}" : "\u{e9}")
            XCTAssertNotEqual(Data(selectedID.utf8),Data(neighborID.utf8))
            var selected = try f.record(original["id"] as! String,"media_round");selected["id"] = selectedID
            let payloads: [(String,JSON,Bool)] = [
                ("exact_key",[selectedID:"Selected private content"],true),
                ("exact_atom",["reference":selectedID],true),
                ("neighbor_key",[neighborID:"Unrelated retained content"],false),
                ("neighbor_atom",["reference":neighborID],false),
                ("unrelated",["body":"Unrelated retained content"],false)]
            var eventIDs: [String:String] = [:],commandIDs: [String:String] = [:],originalResults: [String:String] = [:]
            let principal = "f2-history-fixture",nonMediaID = uuid(),entityEventID = uuid()
            try f.router.dbQueue.writeWithoutTransaction {db in
                try f.router.withValidatedDomainTransaction(db) {
                    try f.router.save(db,selected,type:"media_round")
                    for (name,payload,_) in payloads {
                        let eventID = uuid(),commandID = uuid(),encoded = try jsonString(payload)
                        eventIDs[name] = eventID;commandIDs[name] = commandID;originalResults[name] = encoded
                        try db.execute(sql:"INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data) VALUES(?,?,NULL,'fixture','media_f2_history',?,?)",arguments:[eventID,f.project,now(),encoded])
                        try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES(?,?,'fixture',?)",arguments:[principal,commandID,encoded])
                    }
                    // Ordinary event payloads do not gain media ownership from
                    // prose; an owned entity still makes any event round-owned.
                    try db.execute(sql:"INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data) VALUES(?,?,NULL,'fixture','message_saved',?,?)",arguments:[nonMediaID,f.project,now(),try jsonString([selectedID:"Retained ordinary event"])])
                    try db.execute(sql:"INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data) VALUES(?,?,?,'fixture','message_saved',?,'{}')",arguments:[entityEventID,f.project,selectedID,now()])
                    return .commit
                }
            }
            XCTAssertEqual(try worker(f,"media_round_delete",input(f,selected))["deleted"] as? Bool,true)
            try f.router.dbQueue.read {db in
                for (name,_,matches) in payloads {
                    let eventExists = try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM events WHERE id=?)",arguments:[eventIDs[name]!])!
                    XCTAssertEqual(eventExists,!matches,"Event \(name) must use exact token bytes")
                    let result = try XCTUnwrap(String.fetchOne(db,sql:"SELECT result FROM commands WHERE principal=? AND command_id=?",arguments:[principal,commandIDs[name]!]))
                    XCTAssertEqual(result,matches ? CommandRouter.prunedResult : originalResults[name]!,"Command \(name) must use exact token bytes")
                }
                XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM events WHERE id=?",arguments:[nonMediaID]),1)
                XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM events WHERE id=?",arguments:[entityEventID]),0)
            }
            XCTAssertEqual(try f.get(original)["id"] as? String,original["id"] as? String)
        }
    }

    /// Use the real fence statements while its TEMP journal still exists, so
    /// this proves index use independently of host scheduling and wall times.
    func testF2ChangedRowFenceUsesIdentityIndexesForRecordsEventsAndCommands() throws {
        let f = try Fixture()
        try f.router.dbQueue.writeWithoutTransaction {db in
            let changes = MediaRoundDeletionChanges(),version = try changes.install(db)
            defer {try? changes.remove(db)}
            let fence = try MediaRoundDeletionFence(db,ids:[],events:[],commands:[],needles:[Data("00000000-0000-0000-0000-000000000453".utf8)],pendingRequestTasks:[],holdDigests:[],filePaths:[])
            let recordID = uuid(),eventID = uuid(),commandID = uuid()
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES(?,?,'message',1,?)",arguments:[recordID,f.project,try jsonString(["id":recordID,"project_id":f.project,"revision":1,"body":"Unrelated fixture payload"])])
            try db.execute(sql:"INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data) VALUES(?,?,NULL,'fixture','message_saved',?,?)",arguments:[eventID,f.project,now(),try jsonString(["message_id":recordID])])
            try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES('f2-index-fixture',?,'fixture',?)",arguments:[commandID,try jsonString(["data":["id":recordID]])])
            var statements: [String] = []
            db.trace {event in
                if case .statement(let statement) = event,statement.sql.contains("FROM media_delete_"),statement.sql.contains("JOIN") {
                    statements.append(statement.expandedSQL)
                }
            }
            defer {db.trace(nil)}
            try fence.validate(db,changes:changes,writerVersion:version)
            db.trace(nil)
            XCTAssertEqual(statements.count,3,"Every journal family must be checked")
            for family in ["records","events","commands"] {
                let sql = try XCTUnwrap(statements.first {$0.contains("JOIN \(family) r")})
                let plan = try Row.fetchAll(db,sql:"EXPLAIN QUERY PLAN " + sql).map {$0["detail"] as String}
                XCTAssertTrue(plan.contains {$0.contains("SEARCH r USING")},"\(family) must use its identity index: \(plan)")
                XCTAssertFalse(plan.contains {$0.hasPrefix("SCAN r")},"\(family) must not scan the corpus per changed row: \(plan)")
            }
        }
    }

    func testF2IndexedChangedRowLookupKeepsNULAndUnicodeIdentityByteExact() throws {
        let f = try Fixture(),target = "00000000-0000-0000-0000-000000000454"
        // Swift String equality considers these Unicode suffixes equivalent;
        // the durable storage identity includes their bytes and embedded NUL.
        let oldID = "00000000-0000-0000-0000-000000000455\0\u{e9}"
        let changedID = "00000000-0000-0000-0000-000000000455\0e\u{301}"
        XCTAssertNotEqual(Data(oldID.utf8),Data(changedID.utf8))
        try f.router.dbQueue.writeWithoutTransaction {db in
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES(CAST(? AS TEXT),?,'message',1,?)",arguments:[Data(oldID.utf8),f.project,try jsonString(["id":oldID,"project_id":f.project,"revision":1,"references":[target]])])
            let changes = MediaRoundDeletionChanges(),version = try changes.install(db)
            defer {try? changes.remove(db)}
            let fence = try MediaRoundDeletionFence(db,ids:[],events:[],commands:[],needles:[Data(target.utf8)],pendingRequestTasks:[],holdDigests:[],filePaths:[])
            try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES(CAST(? AS TEXT),?,'message',1,?)",arguments:[Data(changedID.utf8),f.project,try jsonString(["id":changedID,"project_id":f.project,"revision":1,"body":"An unrelated changed neighbor"])])
            XCTAssertNoThrow(try fence.validate(db,changes:changes,writerVersion:version),"A byte-distinct unchanged neighbor must not become a new reference")
        }
    }

    private final class F2LatencySamples: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [(String,String,TimeInterval)] = []
        private var errors: [String] = []
        private var signaled = false
        private var fenceDurations: [TimeInterval] = []
        func sample(_ method: String,_ phase: String,_ duration: TimeInterval) {
            lock.lock();defer {lock.unlock()};samples.append((method,phase,duration))
        }
        func failure(_ error: Error) {lock.lock();defer {lock.unlock()};errors.append(String(describing:error))}
        func enterFence() -> Bool {
            lock.lock();defer {lock.unlock()}
            if signaled {return false};signaled = true;return true
        }
        func fence(_ duration: TimeInterval) {lock.lock();defer {lock.unlock()};fenceDurations.append(duration)}
        func snapshot() -> ([(String,String,TimeInterval)],[String],[TimeInterval]) {
            lock.lock();defer {lock.unlock()};return (samples,errors,fenceDurations)
        }
    }

    /// Exercise the public accepted operation, its real final-fence SQL, and the
    /// commit. The corpus is unrelated to the round and never enters its plan.
    /// Casting each indexed record ID to BLOB made the old final fence scan this
    /// corpus once per journal entry while holding the service's sole writer.
    func testF2EveryReadAndWriteRequestStaysWithinOneSecondThroughPreparationAndCommit() throws {
        try QualificationSuite.requireEnabled() // CL-363: 65,536 seeded records, 540 requests and a wall-clock maximum for each request.
        let f = try Fixture(),round = try cancel(f,f.round(f.type(checks.schema())))
        let task = try results.task(f),writer = try results.session(f,"f2-latency-writer")
        let seedTask = try results.task(f)
        let seed = try results.call(f,"message_send",["task_id":seedTask["id"]!,"kind":"note","body":String(repeating:"u",count:1024)])
        try f.router.dbQueue.write {db in
            try db.execute(sql:"""
                WITH RECURSIVE fixture(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM fixture WHERE n<65536)
                INSERT INTO records(id,project_id,type,revision,data)
                SELECT printf('00000000-0000-0000-0000-%012d',n+100000),?,'message',1,
                    json_set(?,'$.id',printf('00000000-0000-0000-0000-%012d',n+100000),'$.revision',1)
                FROM fixture
                """,arguments:[f.project,try jsonString(seed)])
        }
        let router = f.router!,lane = DispatchQueue(label:"f2-media-delete-operation")
        router.configureCommandOperations(on:lane)
        let prepared = DispatchSemaphore(value:0),release = DispatchSemaphore(value:0),fenceEntered = DispatchSemaphore(value:0)
        let observations = F2LatencySamples()
        router.mediaRoundDeletionPreparationProbe = {
            prepared.signal()
            guard release.wait(timeout:.now()+60) == .success else {throw CoreError("TEST_TIMEOUT","The bounded F2 preparation load did not finish.")}
        }
        router.dbQueue.writeWithoutTransaction {db in
            db.trace(options:[.statement,.profile]) {event in
                switch event {
                case .statement(let statement) where statement.sql.contains("FROM media_delete_") && statement.sql.contains("JOIN records"):
                    if observations.enterFence() {for _ in 0..<3 {fenceEntered.signal()}}
                case .profile(let statement,let duration) where statement.sql.contains("FROM media_delete_") && statement.sql.contains("JOIN"):
                    observations.fence(duration)
                default:break
                }
            }
        }
        defer {
            release.signal()
            let finished = DispatchSemaphore(value:0);lane.async {finished.signal()}
            XCTAssertEqual(finished.wait(timeout:.now()+60),.success)
            router.mediaRoundDeletionPreparationProbe = nil
            router.dbQueue.writeWithoutTransaction {$0.trace(nil)}
        }
        var intent = try input(f,round);intent["project_id"] = f.project;intent["command_id"] = uuid()
        // Use the fixture's actual registered identity at the durable operation boundary.
        let registration = try f.record(f.worker.sessionID!,"session")
        let caller = Caller(role:"worker",installation:try XCTUnwrap(registration["installation"] as? String),projectIDs:[f.project],sessionID:f.worker.sessionID,workspace:f.workspace.path)
        let accepted = try router.handle(method:"media_round_delete",params:intent,caller:caller)
        XCTAssertEqual(accepted["command_outcome"] as? String,"accepted")
        let id = try XCTUnwrap((accepted["data"] as? JSON)?["operation_id"] as? String)
        XCTAssertEqual(prepared.wait(timeout:.now()+45),.success)
        func request(_ method: String,_ phase: String,_ index: Int = 0) {
            var params: JSON = ["project_id":f.project]
            if method != "service_info" {params["task_id"] = task["id"]!}
            if method == "message_send" {params["kind"] = "note";params["body"] = "F2 measured unrelated load \(index)";params["command_id"] = uuid()}
            let start = ProcessInfo.processInfo.systemUptime
            do {_ = try router.handle(method:method,params:params,caller:writer)}
            catch {observations.failure(error)}
            observations.sample(method,phase,ProcessInfo.processInfo.systemUptime-start)
        }
        for index in 0..<180 {
            for method in ["service_info","task_get","message_send"] {request(method,"preparation",index)}
            Thread.sleep(forTimeInterval:0.01)
        }
        let load = DispatchGroup()
        for method in ["service_info","task_get","message_send"] {
            load.enter()
            DispatchQueue.global().async {
                defer {load.leave()}
                guard fenceEntered.wait(timeout:.now()+60) == .success else {
                    observations.failure(CoreError("TEST_TIMEOUT","The actual final fence was not observed."));return
                }
                request(method,"commit",180)
            }
        }
        release.signal()
        XCTAssertEqual(load.wait(timeout:.now()+60),.success)
        let finished = DispatchSemaphore(value:0);lane.async {finished.signal()}
        XCTAssertEqual(finished.wait(timeout:.now()+60),.success)
        let complete = try router.handle(method:"operation_get",params:["project_id":f.project,"operation_id":id],caller:caller)["data"] as! JSON
        XCTAssertEqual(complete["state"] as? String,"succeeded",String(describing:complete["error"]))
        let (samples,errors,durations) = observations.snapshot()
        XCTAssertTrue(errors.isEmpty,errors.joined(separator:"\n"))
        XCTAssertFalse(durations.isEmpty,"The actual final-fence queries must run")
        for method in ["service_info","task_get","message_send"] {
            for phase in ["preparation","commit"] {
                let times = samples.filter {$0.0 == method && $0.1 == phase}.map {$0.2}
                XCTAssertFalse(times.isEmpty,"Missing \(method) \(phase) observation")
                print("F2 request \(method) phase=\(phase) count=\(times.count) maximum_seconds=\(times.max() ?? .infinity)")
                XCTAssertLessThanOrEqual(times.max() ?? .infinity,1,"\(method) \(phase) exceeded the CL-450 maximum")
            }
        }
        print("F2 final-fence query seconds=\(durations)")
    }
}
