import XCTest
import Security
import Darwin
import CryptoKit
@testable import ChecklistCore
import ChecklistBridges
@testable import ChecklistService

/// The real router and store, with fake Codex effects. No `codex queue`, `open`,
/// Codex database or process scan runs here.
final class CodexQueueDispatchTests: XCTestCase {
    private var root: URL!
    private var coordinator: Coordinator!
    private var project: String!
    private var taskID: String!
    private let owner = Caller(role:"owner",installation:"dispatch-test-owner",projectIDs:[])
    private let bridge = Caller(role:"owner",installation:"native-bridge",projectIDs:[])
    private let threadA = "00000000-0000-4000-8000-000000000a13",threadB = "00000000-0000-4000-8000-000000000b13"

    private final class Fake: @unchecked Sendable {
        var clock = Date()
        var threads: Set<String> = []
        var preflights: [CodexQueuePreflight] = []
        var sends: [String] = []
        var contents: [String] = []
        var omitted: [CodexQueueStore.OmittedThread] = []
        var omittedReads = 0
        var sendFailure: Error?
        var item: CodexQueueStore.Item = .removed
        var onItem: (@Sendable () -> Void)?
        var proves = true
        var exec = false
    }
    private let allowed = CodexQueuePreflight.allowed(.init(host:.nativeApp,reason:.sourceVscode,source:"vscode"),executable:"/Applications/Fake.app/Contents/codex")

    private func install(_ fake: Fake, enabled: Bool = true) {
        let effects = CodexQueueRouteEffects(enabled:enabled,readAppThreads:{ _ in fake.threads },
            preflight:{ [allowed] _,proven in
                guard proven else { return .refused(.init(reason:.registrationUnproven)) }
                return fake.preflights.isEmpty ? allowed : fake.preflights.removeFirst()
            },
            provesRegistration:{ _ in fake.proves },
            send:{ content,registration,_,_ in
                if let failure = fake.sendFailure { throw failure }
                fake.sends.append(registration.sessionID);fake.contents.append(content);return .init(exitStatus:0,byteCount:content.utf8.count,itemID:"item-\(fake.sends.count)")
            },
            followup:{ _,lane,status in
                .init(openEnabled:true,item:{ _ in fake.onItem?();return fake.item },observe:{ .init(host:.nativeApp,reason:.sourceVscode) },load:{ .loaded },status:status,
                    now:{ fake.clock.timeIntervalSince1970 },schedule:{ _,body in lane.async(execute:body) },open:{ _,_ in XCTFail("A loaded thread is not opened");return 0 },execHolder:{ fake.exec })
            },now:{ fake.clock },readOmittedThreads:{ _,_ in fake.omittedReads += 1;return fake.omitted })
        coordinator.codexRoute = CodexQueueRouteState(markerFile:root.appendingPathComponent("codex-queue-route.json"),effects:effects)
    }
    private func call(_ method: String,_ params: [String:Any],_ caller: Caller? = nil) throws -> [String:Any] {
        var params = params;if params["command_id"] == nil { params["command_id"] = UUID().uuidString }
        let result = try coordinator.router.handle(method:method,params:params,caller:caller ?? owner)
        return result["data"] as? [String:Any] ?? result
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let router = try CommandRouter(root:root.appendingPathComponent("store"))
        coordinator = Coordinator(router:router,enrollmentFile:root.appendingPathComponent("connections.json"),startBackgroundWork:false)
        project = try call("project_create",["name":"Queue fixture","key_prefix":"CQ","root_path":root.path])["id"] as? String
        let epic = try call("epic_create",["project_id":project!,"name":"Queue","brief":"Synthetic"])
        let task = try call("task_create",["project_id":project!,"epic_id":epic["id"]!,"title":"Queue","brief":"Synthetic"])
        taskID = task["id"] as? String
    }
    override func tearDownWithError() throws {
        if let coordinator { drain(coordinator);for _ in 0..<2 { coordinator.storageQueue.sync {};coordinator.workHealthQueue.sync {};coordinator.queue.sync {} } }
        coordinator = nil
        if let root { try FileManager.default.removeItem(at:root) }
    }
    private func drain(_ coordinator: Coordinator) {
        // The chain moves between the lane and the command queue, so it needs more than one pass.
        for _ in 0..<12 { coordinator.codexRoute.lane.sync {};coordinator.queue.sync {} }
    }
    private func enrollment(_ thread: String, installation: String? = nil) -> Enrollment {
        var e = Enrollment(installation:installation ?? "e-\(thread)",name:"Synthetic",provider:"codex",role:"worker",projectIDs:[project],sessionID:thread,workspace:root.path,profileID:nil,tokenDigest:"x",generation:"g-\(thread)")
        e.automatic = true;e.identityVerification = "native_process_verified_thread_observed";e.nativeExecutionDomain = "codex:24680:5:0";e.nativeSessionID = thread;e.codexAppHostProven = true
        return e
    }
    private func register(_ thread: String) throws {
        let e = enrollment(thread)
        _ = try call("session_register",["project_id":project!,"project_ids":[project!],"session_id":thread,"installation":e.installation+"/"+e.generation,"provider":"codex","role":"worker","workspace":root.path])
        coordinator.enrollments[e.installation] = e
    }
    private func note(_ thread: String,_ body: String = "Synthetic") throws -> (id:String,message:[String:Any],delivery:[String:Any]) {
        let sent = try call("message_send",["project_id":project!,"task_id":taskID!,"body":body,"recipient":["kind":"session","session_id":thread]])
        let id = try XCTUnwrap(((sent["deliveries"] as? [[String:Any]])?.first?["id"]) as? String)
        return (id,sent,try stored(id))
    }
    private func stored(_ id: String) throws -> [String:Any] { try coordinator.router.dbQueue.read { try self.coordinator.router.record($0,id,type:"delivery") } }
    private func start(_ id: String,_ thread: String,_ message: [String:Any],proven: Bool? = true) throws {
        var e = enrollment(thread);e.codexAppHostProven = proven
        coordinator.enrollments[e.installation]?.codexAppHostProven = proven
        let registration = try XCTUnwrap(Coordinator.codexQueueRegistration(e))
        coordinator.startCodexQueueDelivery(.init(deliveryID:id,messageID:message["id"] as! String,enrollment:e,registration:registration,origin:.agent,author:"Synthetic $author",body:"Synthetic body $imagegen @plugin",subject:nil,ticket:nil,createdAt:"2026-11-02T10:00:00Z"))
        drain(coordinator)
    }
    private func activate(_ date: Date) throws {
        try JSONSerialization.data(withJSONObject:["activated_at":ISO8601DateFormatter().string(from:date)]).write(to:root.appendingPathComponent("codex-queue-route.json"))
    }

    func testOldNoteStaysUnchangedAndOnlyANewNoteIsAdmitted() throws {
        let fake = Fake();install(fake);try register(threadA)
        let old = try note(threadA,"Older")
        var pass = CodexQueuePass()
        // Created before the route became active on this store.
        fake.clock = Date().addingTimeInterval(120);try activate(fake.clock)
        XCTAssertFalse(coordinator.codexQueueAdmit(threadID:threadA,delivery:old.delivery,message:old.message,pass:&pass))
        // Active earlier, but the note is older than one hour.
        install(fake);fake.clock = Date().addingTimeInterval(3700);try activate(Date().addingTimeInterval(-7200))
        XCTAssertFalse(coordinator.codexQueueAdmit(threadID:threadA,delivery:old.delivery,message:old.message,pass:&pass))
        let after = try stored(old.id)
        XCTAssertEqual(after["state"] as? String,old.delivery["state"] as? String);XCTAssertEqual(after["push_state"] as? String,"unavailable")
        XCTAssertEqual(after["revision"] as? Int,old.delivery["revision"] as? Int);XCTAssertNil(after["transport_receipt"])
        XCTAssertEqual(fake.sends,[]);XCTAssertEqual(pass.total,0)
        // In time: admitted.
        install(fake);fake.clock = Date().addingTimeInterval(60);try activate(Date().addingTimeInterval(-60))
        XCTAssertTrue(coordinator.codexQueueAdmit(threadID:threadA,delivery:old.delivery,message:old.message,pass:&pass))
    }
    func testActivationTimeIsWrittenOnceAndNotMoved() throws {
        let fake = Fake();install(fake)
        let first = try XCTUnwrap(coordinator.codexRoute.activatedAt())
        fake.clock = fake.clock.addingTimeInterval(9000);install(fake)
        XCTAssertEqual(coordinator.codexRoute.activatedAt(),first)
    }
    func testPassBounds() throws {
        let fake = Fake();install(fake);try activate(Date().addingTimeInterval(-60))
        let message: [String:Any] = ["created_at":ISO8601DateFormatter().string(from:fake.clock)],delivery: [String:Any] = [:]
        var pass = CodexQueuePass()
        XCTAssertTrue(coordinator.codexQueueAdmit(threadID:"t0",delivery:delivery,message:message,pass:&pass))
        XCTAssertFalse(coordinator.codexQueueAdmit(threadID:"t0",delivery:delivery,message:message,pass:&pass),"One call per thread in a pass")
        for index in 1..<CodexQueueBounds.queueCallsPerPass { XCTAssertTrue(coordinator.codexQueueAdmit(threadID:"t\(index)",delivery:delivery,message:message,pass:&pass)) }
        XCTAssertFalse(coordinator.codexQueueAdmit(threadID:"more",delivery:delivery,message:message,pass:&pass),"A stated total in a pass")
        var next = CodexQueuePass()
        coordinator.codexRoute.open = CodexQueueBounds.openDeliveries
        XCTAssertFalse(coordinator.codexQueueAdmit(threadID:"t9",delivery:delivery,message:message,pass:&next),"The open limit includes the wait")
        coordinator.codexRoute.open = 0
        coordinator.codexRoute.retryAt["t9"] = fake.clock.addingTimeInterval(1)
        XCTAssertFalse(coordinator.codexQueueAdmit(threadID:"t9",delivery:delivery,message:message,pass:&next))
        XCTAssertFalse(coordinator.codexQueueAdmit(threadID:"t8",delivery:["hook_state":"context_written"],message:message,pass:&next),"A hook took this note")
    }
    /// H1, M1, M10: a refusal writes nothing, and a later dispatch can still try.
    func testRefusalWritesNothingAndALaterDispatchSucceeds() throws {
        let fake = Fake();install(fake);try register(threadA)
        let n = try note(threadA)
        for reason in [CodexQueueReason.holderExec,.hostNotRunning,.databaseLocked,.sourceExec,.sourceSubagent,.queueOccupied,.hostChanged] {
            fake.preflights = [.refused(.init(reason:reason))]
            try start(n.id,threadA,n.message)
            let row = try stored(n.id)
            XCTAssertEqual(row["push_state"] as? String,"unavailable",reason.rawValue);XCTAssertEqual(row["state"] as? String,n.delivery["state"] as? String)
            XCTAssertNil(row["transport_receipt"]);XCTAssertEqual(row["revision"] as? Int,n.delivery["revision"] as? Int)
            XCTAssertEqual(fake.sends,[]);XCTAssertFalse(coordinator.attemptedDeliveries.contains(n.id));XCTAssertEqual(coordinator.codexRoute.open,0)
            XCTAssertNotNil(coordinator.codexRoute.retryAt[threadA])
        }
        fake.preflights = []
        try start(n.id,threadA,n.message)
        let row = try stored(n.id),receipt = try XCTUnwrap(row["transport_receipt"] as? [String:Any])
        XCTAssertEqual(fake.sends,[threadA]);XCTAssertEqual(row["push_state"] as? String,"provider_accepted")
        XCTAssertEqual(receipt["queue_poll_result"] as? String,"removed");XCTAssertEqual(receipt["queued_item_id"] as? String,"item-1");XCTAssertNil(row["acknowledged_at"])
        XCTAssertEqual(coordinator.codexRoute.open,0)
    }
    /// F1: the item went while an exec process held the thread. The note stays in the inbox.
    func testItemTakenWithAnExecHolderIsNotANormalResult() throws {
        let fake = Fake();install(fake);try register(threadA);fake.exec = true
        let n = try note(threadA)
        try start(n.id,threadA,n.message)
        let row = try stored(n.id),receipt = try XCTUnwrap(row["transport_receipt"] as? [String:Any])
        XCTAssertEqual(receipt["queue_poll_result"] as? String,"removed_exec_holder");XCTAssertEqual(receipt["open_result"] as? String,"exec_holder")
        XCTAssertNil(row["acknowledged_at"]);XCTAssertEqual(row["state"] as? String,"provider_accepted")
    }
    /// F6: a thread proven once passes while unloaded. One never proven gets a stated reason.
    func testProofRulesAtDispatch() throws {
        let fake = Fake();install(fake);try register(threadA);try register(threadB);fake.proves = false
        let stored1 = try note(threadA)
        try start(stored1.id,threadA,stored1.message,proven:true)
        XCTAssertEqual(fake.sends,[threadA],"A stored true proof needs no live holder")

        for value: Bool? in [nil,false] {
            let n = try note(threadB)
            try start(n.id,threadB,n.message,proven:value)
            let row = try stored(n.id),receipt = try XCTUnwrap(row["transport_receipt"] as? [String:Any])
            XCTAssertEqual(receipt["reason_code"] as? String,"registration_unproven");XCTAssertEqual(receipt["open_result"] as? String,"not_started")
            XCTAssertNotNil(receipt["reason"]);XCTAssertEqual(row["push_state"] as? String,"unavailable");XCTAssertEqual(row["state"] as? String,n.delivery["state"] as? String)
            XCTAssertEqual(fake.sends,[threadA],"No queue call")
            XCTAssertFalse(coordinator.attemptedDeliveries.contains(n.id))
        }
        // The live check passes later: the proof is stored, and the same note goes out.
        fake.proves = true
        let n = try note(threadB)
        try start(n.id,threadB,n.message,proven:nil)
        XCTAssertEqual(fake.sends,[threadA,threadB])
        XCTAssertEqual(coordinator.enrollments["e-\(threadB)"]?.codexAppHostProven,true)
        XCTAssertTrue(try String(contentsOf:root.appendingPathComponent("connections.json"),encoding:.utf8).contains("codexAppHostProven"))
    }
    func testStoringAProofNeedsTheCurrentGeneration() throws {
        let fake = Fake();install(fake);try register(threadA)
        let installation = "e-\(threadA)"
        coordinator.enrollments[installation]?.codexAppHostProven = false
        coordinator.queue.sync { coordinator.storeCodexAppHostProof(installation:installation,generation:"another") }
        XCTAssertEqual(coordinator.enrollments[installation]?.codexAppHostProven,false)
        coordinator.queue.sync { coordinator.storeCodexAppHostProof(installation:installation,generation:"g-\(threadA)") }
        XCTAssertEqual(coordinator.enrollments[installation]?.codexAppHostProven,true)
    }
    /// F8: a crash during the queue call. The startup record succeeds, so the next startup selects nothing.
    func testRestartEndsACrashInsideTheFenceOnce() throws {
        let fake = Fake();install(fake);try register(threadA)
        let n = try note(threadA)
        _ = try call("delivery_record",["delivery_id":n.id,"state":"uncertain","receipt":["stage":"native_send_started","route":"codex_app_queue","queue_poll_result":"not_started","open_result":"not_started"]],bridge)
        coordinator.queue.sync { coordinator.recordInterruptedCodexQueueFollowups() }
        let row = try stored(n.id),receipt = try XCTUnwrap(row["transport_receipt"] as? [String:Any])
        XCTAssertEqual(receipt["queue_poll_result"] as? String,"service_restarted");XCTAssertEqual(row["push_state"] as? String,"uncertain")
        let again = try coordinator.router.handle(method:"delivery_pending",params:["codex_queue_open_followups":true],caller:bridge)
        XCTAssertEqual(((again["data"] as? [String:Any])?["deliveries"] as? [Any])?.count,0)
        XCTAssertEqual(fake.sends,[])
    }
    /// H1: an exec resume that starts while the fence commits is still refused.
    func testHolderChangeAfterTheFenceRefusesAndRestoresTheDelivery() throws {
        let fake = Fake();install(fake);try register(threadA)
        let n = try note(threadA)
        fake.preflights = [allowed,.refused(.init(reason:.holderExec))]
        try start(n.id,threadA,n.message)
        let row = try stored(n.id)
        XCTAssertEqual(fake.sends,[]);XCTAssertEqual(row["push_state"] as? String,"unavailable");XCTAssertEqual(row["state"] as? String,n.delivery["state"] as? String)
        XCTAssertNil(row["transport_receipt"]);XCTAssertFalse(coordinator.attemptedDeliveries.contains(n.id))
    }
    /// M2: a fence during the wait keeps its state and the earlier acceptance receipt.
    func testFenceDuringTheWaitIsNotChangedByTheFinalReceipt() throws {
        let fake = Fake();install(fake);try register(threadA)
        let n = try note(threadA),router = coordinator.router
        fake.item = .pending
        fake.onItem = { [id = n.id] in
            try? router.dbQueue.write { db in var d = try router.record(db,id,type:"delivery");d["owner_disconnect_ref"] = "synthetic";try router.save(db,d,type:"delivery") }
        }
        try start(n.id,threadA,n.message)
        let row = try stored(n.id),receipt = try XCTUnwrap(row["transport_receipt"] as? [String:Any])
        XCTAssertEqual(fake.sends,[threadA]);XCTAssertEqual(receipt["queue_poll_result"] as? String,"not_started")
        let list = try call("message_delivery_list",["project_id":project!,"task_id":taskID!,"message_id":n.message["id"]!])["deliveries"] as? [[String:Any]]
        XCTAssertEqual(list?.first?["state"] as? String,"fenced")
        XCTAssertEqual(coordinator.codexRoute.open,0)
    }
    /// L3.
    func testAcknowledgmentDuringTheWaitReadsAsAcknowledged() throws {
        let fake = Fake();install(fake);try register(threadA)
        let n = try note(threadA),router = coordinator.router
        fake.item = .pending
        fake.onItem = { [id = n.id] in
            try? router.dbQueue.write { db in var d = try router.record(db,id,type:"delivery");d["state"] = "acknowledged";try router.save(db,d,type:"delivery") }
        }
        try start(n.id,threadA,n.message)
        let row = try stored(n.id),receipt = try XCTUnwrap(row["transport_receipt"] as? [String:Any])
        XCTAssertEqual(receipt["queue_poll_result"] as? String,"acknowledged");XCTAssertEqual(row["state"] as? String,"acknowledged")
    }
    func testQueueFailureIsARealAttemptAndWritesAResult() throws {
        let fake = Fake();install(fake);try register(threadA)
        let n = try note(threadA)
        fake.sendFailure = NativeBridgeError.outcomeUnknown("Synthetic timeout")
        try start(n.id,threadA,n.message)
        let row = try stored(n.id)
        XCTAssertEqual(row["push_state"] as? String,"uncertain");XCTAssertTrue(coordinator.attemptedDeliveries.contains(n.id))
        XCTAssertEqual((row["transport_receipt"] as? [String:Any])?["reason_code"] as? String,"queue_outcome_unknown")
    }
    /// M6.
    func testRestartRecordsAFinalReceiptForAnUnfinishedWait() throws {
        let fake = Fake();install(fake);try register(threadA)
        let n = try note(threadA)
        _ = try call("delivery_record",["delivery_id":n.id,"state":"uncertain","receipt":["stage":"native_send_started","route":"codex_app_queue","queue_poll_result":"not_started","open_result":"not_started"]],bridge)
        _ = try call("delivery_record",["delivery_id":n.id,"state":"provider_accepted","receipt":["stage":"codex_queue_command_exited_zero","route":"codex_app_queue","queue_poll_result":"not_started","open_result":"not_started"]],bridge)
        coordinator.recordInterruptedCodexQueueFollowups()
        let row = try stored(n.id),receipt = try XCTUnwrap(row["transport_receipt"] as? [String:Any])
        XCTAssertEqual(receipt["queue_poll_result"] as? String,"service_restarted");XCTAssertEqual(row["push_state"] as? String,"provider_accepted")
        XCTAssertNil(row["acknowledged_at"])
        XCTAssertEqual(fake.sends,[],"A restart never sends the note again")
    }
    func testOnlyAppThreadsAreSelected() throws {
        let fake = Fake();install(fake);try register(threadA);try register(threadB)
        var inherited = enrollment("00000000-0000-4000-8000-000000000c13");inherited.nativeEndpoint = "/synthetic";coordinator.enrollments[inherited.installation] = inherited
        fake.threads = [threadA,inherited.sessionID]
        _ = coordinator.codexRoute.appThreads();Thread.sleep(forTimeInterval:0.05)
        let selected = try XCTUnwrap(coordinator.codexQueueSelection())
        XCTAssertEqual(selected.ids,[threadA])
        install(fake,enabled:false)
        XCTAssertNil(coordinator.codexQueueSelection())
    }
    /// H2: 889 sessions and 756 waiting notes, the live counts of 2 November 2026.
    func testAddedTimePerCommandAtLiveScale() throws {
        let fake = Fake();install(fake)
        let sessions = (0..<3).map { String(format:"00000000-0000-4000-8000-%012d",$0+1) }
        for session in sessions { try register(session) }
        let counts = [298,335,123]
        for (session,count) in zip(sessions,counts) { for index in 0..<count { _ = try note(session,"Waiting \(index)") } }
        for index in 0..<886 {
            var e = enrollment(String(format:"00000000-0000-4000-9000-%012d",index));e.projectIDs = []
            coordinator.enrollments[e.installation] = e
        }
        XCTAssertEqual(coordinator.enrollments.count,889)
        fake.threads = Set((0..<8).map { String(format:"00000000-0000-4000-9000-%012d",$0) }+[sessions[2]])
        // All 756 notes are older than the one-hour bound.
        fake.clock = Date().addingTimeInterval(7200);try activate(Date().addingTimeInterval(-3600))
        _ = coordinator.codexRoute.appThreads();Thread.sleep(forTimeInterval:0.05)
        let router = coordinator.router,bridge = self.bridge
        var sizes: [Int] = []
        let load: ([String:Any]) -> [String:Any]? = { params in
            sizes.append((params["native_session_ids"] as? [String])?.count ?? 0)
            return (try? router.handle(method:"delivery_pending",params:params,caller:bridge))?["data"] as? [String:Any]
        }
        func measure(_ turns: Int,_ body: () throws -> Void) rethrows -> Double {
            var total = 0.0
            for _ in 0..<turns { try body();let start = ProcessInfo.processInfo.systemUptime;XCTAssertEqual(coordinator.nativeDispatchDeliveries(load:load).count,0);total += ProcessInfo.processInfo.systemUptime-start }
            return total/Double(turns)*1000
        }
        // The live store on 2 November 2026 held 42,879 records, of which 5,964 deliveries.
        // Filler rows are 2 KiB each. The live average of 28 KiB would need 1.2 GB here.
        let body = String(repeating:"x",count:2048)
        try router.dbQueue.write { db in
            let statement = try db.makeStatement(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES ('filler-'||?1,?3,CASE WHEN ?1<5200 THEN 'delivery' ELSE 'filler' END,1,?2)")
            let data = "{\"state\":\"queued\",\"push_state\":\"unavailable\",\"created_at\":\"2026-01-01T00:00:00Z\",\"recipient_session_id\":\"filler-session\",\"pad\":\"\(body)\"}"
            for index in 0..<42000 { try statement.execute(arguments:[index,data,project!]) }
        }
        // A write before each pass empties the read cache, as a successful command does.
        var revision = 0
        let afterWrite = try measure(40) { revision += 1;_ = try call("task_edit",["project_id":project!,"task_id":taskID!,"expected_revision":try call("task_get",["project_id":project!,"task_id":taskID!])["revision"]!,"patch":["brief":"Synthetic \(revision)"]]) }
        let cached = measure(40) {}
        XCTAssertEqual(Set(sizes),[9],"The store read names only the nine app threads")
        // The earlier selection for contrast: all sessions, with no age bound.
        var oldTotal = 0.0
        for _ in 0..<3 {
            let ids = coordinator.enrollments.values.map(\.sessionID)
            _ = try call("task_edit",["project_id":project!,"task_id":taskID!,"expected_revision":try call("task_get",["project_id":project!,"task_id":taskID!])["revision"]!,"patch":["brief":"Synthetic old \(oldTotal)"]])
            let start = ProcessInfo.processInfo.systemUptime
            for begin in stride(from:0,to:ids.count,by:256) { _ = load(["native_session_ids":Array(ids[begin..<min(begin+256,ids.count)]),"native_dispatch_candidates":true]) }
            oldTotal += ProcessInfo.processInfo.systemUptime-start
        }
        print("codex-route-added-ms after_write=\(afterWrite) cached=\(cached) earlier_selection=\(oldTotal/3*1000)")
        XCTAssertLessThan(afterWrite,50,"Debug-build bound on the added time per command")
        // The window keeps a new note and leaves out notes behind 4,096 newer records.
        fake.clock = Date();try activate(Date().addingTimeInterval(-10800));install(fake)
        try activate(Date().addingTimeInterval(-10800))
        _ = coordinator.codexRoute.appThreads();Thread.sleep(forTimeInterval:0.05)
        let fresh = try note(sessions[2],"Fresh")
        XCTAssertEqual(coordinator.nativeDispatchDeliveries(load:load).compactMap { $0["id"] as? String },[fresh.id])
    }

    /// F3, F7, F11 at the point where the service builds the queue text.
    func testQueueTextEscapesMentionsAndStatesTheNoteTime() throws {
        let fake = Fake();install(fake);try register(threadA)
        let sent = try note(threadA)
        try start(sent.id,threadA,sent.message)
        let text = try XCTUnwrap(fake.contents.first)
        XCTAssertFalse(text.contains("$"));XCTAssertFalse(text.contains("@"));XCTAssertTrue(text.contains("\\u0024imagegen \\u0040plugin"))
        XCTAssertTrue(text.contains("Note created at: 2026-11-02T10:00:00Z."));XCTAssertTrue(text.contains("A repeated delivery ID is the same note."))
    }
    private func settleRefresh() { Thread.sleep(forTimeInterval:0.05) }
    /// F10: one pass when a refresh changes the set, and no loop.
    func testRefreshThatChangesTheSetRunsOnePass() throws {
        let fake = Fake();install(fake)
        final class Count: @unchecked Sendable { var value = 0 }
        let count = Count(),route = coordinator.codexRoute
        fake.threads = [threadA]
        XCTAssertEqual(route.appThreads(changed:{ count.value += 1 }),[],"The first pass has the old copy")
        settleRefresh();XCTAssertEqual(count.value,1)
        XCTAssertEqual(route.appThreads(changed:{ count.value += 1 }),[threadA])
        settleRefresh();XCTAssertEqual(count.value,1,"A fresh copy starts no read and no pass")
        fake.clock = fake.clock.addingTimeInterval(CodexQueueBounds.cacheSeconds)
        _ = route.appThreads(changed:{ count.value += 1 })
        settleRefresh();XCTAssertEqual(count.value,1,"The same set starts no pass")
        fake.clock = fake.clock.addingTimeInterval(CodexQueueBounds.cacheSeconds);fake.threads = [threadA,threadB]
        _ = route.appThreads(changed:{ count.value += 1 })
        settleRefresh();XCTAssertEqual(count.value,2)
    }
    /// F10: selection wires the refresh to a dispatch. With no listener the pass stays off.
    func testSelectionStartsARefreshAndKeepsNoLoop() throws {
        let fake = Fake();install(fake);try register(threadA)
        fake.threads = [threadA]
        XCTAssertNil(coordinator.codexQueueSelection(),"The old copy is empty")
        settleRefresh();coordinator.queue.sync {}
        XCTAssertEqual(coordinator.codexQueueSelection()?.ids,[threadA])
    }
    /// F10: one line per thread, with its cause. Unchanged inputs start no second read.
    func testEnrolledThreadOutsideTheSetIsLoggedOnce() throws {
        let fake = Fake();install(fake)
        final class Lines: @unchecked Sendable { var value: [String] = [] }
        let lines = Lines()
        let inner = coordinator.codexRoute.effects
        let route = CodexQueueRouteState(markerFile:root.appendingPathComponent("codex-queue-route.json"),effects:inner,log:{ lines.value.append($0) })
        fake.threads = [threadA]
        fake.omitted = [.init(id:threadB,stale:false),.init(id:"00000000-0000-4000-8000-000000000c13",stale:true)]
        let enrolled: Set<String> = [threadA,threadB,"00000000-0000-4000-8000-000000000c13"]
        _ = route.appThreads(enrolled:enrolled);settleRefresh()
        XCTAssertEqual(lines.value.count,2)
        XCTAssertTrue(lines.value.contains { $0.contains(threadB) && $0.contains("ranked past the newest 64 threads") })
        XCTAssertTrue(lines.value.contains { $0.contains("000000000c13") && $0.contains("no update in 14 days") })
        XCTAssertEqual(fake.omittedReads,1)
        fake.clock = fake.clock.addingTimeInterval(CodexQueueBounds.cacheSeconds)
        _ = route.appThreads(enrolled:enrolled);settleRefresh()
        XCTAssertEqual(lines.value.count,2);XCTAssertEqual(fake.omittedReads,1,"The same inputs read nothing")
        fake.clock = fake.clock.addingTimeInterval(CodexQueueBounds.cacheSeconds);fake.threads = [threadB]
        _ = route.appThreads(enrolled:enrolled);settleRefresh()
        XCTAssertEqual(fake.omittedReads,2);XCTAssertEqual(lines.value.count,2,"A thread gets one line per run")
    }
    /// F12: the rule, and a real process. No real Codex host or store is read.
    func testHostSignatureRule() throws {
        let hash = Data([1,2,3])
        let good: [String:Any] = [kSecCodeInfoIdentifier as String:"codex",kSecCodeInfoTeamIdentifier as String:"TEAM",kSecCodeInfoUnique as String:hash]
        XCTAssertTrue(CodexHostSignature.matches(good,fileHash:hash,identifier:"codex",team:"TEAM"))
        XCTAssertFalse(CodexHostSignature.matches(nil,fileHash:hash,identifier:"codex",team:"TEAM"))
        XCTAssertFalse(CodexHostSignature.matches(good,fileHash:nil,identifier:"codex",team:"TEAM"))
        XCTAssertFalse(CodexHostSignature.matches(good,fileHash:Data([9]),identifier:"codex",team:"TEAM"),"The file differs from the running code")
        XCTAssertFalse(CodexHostSignature.matches(good,fileHash:hash,identifier:"other",team:"TEAM"))
        XCTAssertFalse(CodexHostSignature.matches(good,fileHash:hash,identifier:"codex",team:"OTHER"))
        var noTeam = good;noTeam[kSecCodeInfoTeamIdentifier as String] = nil
        XCTAssertFalse(CodexHostSignature.matches(noTeam,fileHash:hash,identifier:"codex",team:"TEAM"))
        // A running binary named codex under an app path shape, with another signature.
        let directory = root.appendingPathComponent("Fake.app/Contents/MacOS");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let binary = directory.appendingPathComponent("codex"),other = directory.appendingPathComponent("other")
        try buildIdleProgram(at:binary,mark:"a");try buildIdleProgram(at:other,mark:"b")
        let process = Process();process.executableURL = binary;process.standardOutput = FileHandle.nullDevice;try process.run()
        defer { process.terminate();process.waitUntilExit() }
        Thread.sleep(forTimeInterval:0.05);XCTAssertTrue(process.isRunning)
        let host = CodexProcess(pid:process.processIdentifier,executable:binary.path,role:.appHost)
        XCTAssertFalse(CodexHostSignature.valid(host),"An ad hoc signature is not the bundled Codex identity")
        // The hash rule on a real process: the same file passes, another file does not.
        let identity = NativeCodeIdentity()
        var information = try XCTUnwrap(identity.signingInfo(process.processIdentifier));information[kSecCodeInfoTeamIdentifier as String] = "TEAM"
        let name = try XCTUnwrap(information[kSecCodeInfoIdentifier as String] as? String)
        XCTAssertTrue(CodexHostSignature.matches(information,fileHash:identity.executable(binary)?.cdhash,identifier:name,team:"TEAM"))
        XCTAssertFalse(CodexHostSignature.matches(information,fileHash:identity.executable(other)?.cdhash,identifier:name,team:"TEAM"))
    }

    /// B2: a service timer starts no Codex turn.
    func testWorkHealthRequestNeverTakesTheQueueBranchAndStaysUnchanged() throws {
        let fake = Fake();install(fake);try activate(Date().addingTimeInterval(-60));try register(threadA)
        let n = try note(threadA)
        var message = n.message;message["origin"] = "system";message["created_at"] = ISO8601DateFormatter().string(from:fake.clock)
        var delivery = n.delivery;delivery["native_relay"] = "work_health"
        XCTAssertEqual(NativeRelayOrigin.forDispatch(messageOrigin:"system",nativeRelay:"work_health"),.system,"The marker still selects the Claude relay")
        var pass = CodexQueuePass()
        XCTAssertFalse(coordinator.codexQueueAdmit(threadID:threadA,delivery:delivery,message:message,pass:&pass))
        XCTAssertEqual(pass.total,0,"It takes no place in the pass");XCTAssertTrue(pass.threads.isEmpty)
        let row = try stored(n.id)
        XCTAssertEqual(row["push_state"] as? String,"unavailable");XCTAssertEqual(row["revision"] as? Int,n.delivery["revision"] as? Int);XCTAssertNil(row["transport_receipt"])
        XCTAssertEqual(fake.sends,[])
        message["origin"] = "agent"
        XCTAssertTrue(coordinator.codexQueueAdmit(threadID:threadA,delivery:n.delivery,message:message,pass:&pass),"An agent note passes the same check")
    }
    func testOccupiedThreadKeepsTheDeliveryAndALaterDispatchSends() throws {
        let fake = Fake();install(fake);try register(threadA)
        let n = try note(threadA)
        fake.preflights = [.refused(.init(reason:.queueOccupied))]
        try start(n.id,threadA,n.message)
        let row = try stored(n.id)
        XCTAssertEqual(fake.sends,[]);XCTAssertEqual(row["push_state"] as? String,"unavailable");XCTAssertEqual(row["state"] as? String,n.delivery["state"] as? String)
        XCTAssertEqual(row["revision"] as? Int,n.delivery["revision"] as? Int);XCTAssertNil(row["transport_receipt"])
        XCTAssertNotNil(coordinator.codexRoute.retryAt[threadA]);XCTAssertFalse(coordinator.attemptedDeliveries.contains(n.id))
        fake.preflights = []
        try start(n.id,threadA,n.message)
        XCTAssertEqual(fake.sends,[threadA])
    }
    func testFailedFenceStatesItsTrueReason() throws {
        let fake = Fake();install(fake);try register(threadA)
        let n = try note(threadA),e = enrollment(threadA)
        func fence(_ id: String) -> CodexQueueReason? { coordinator.queue.sync { coordinator.codexQueueFence(deliveryID:id,enrollment:e) } }
        XCTAssertEqual(fence(UUID().uuidString.lowercased()),.fenceNotRecorded,"A store refusal is not a recipient problem")
        coordinator.enrollments[e.installation]?.revoked = true
        XCTAssertEqual(fence(n.id),.authorizationChanged);coordinator.enrollments[e.installation]?.revoked = nil
        coordinator.enrollments[e.installation]?.generation = "other"
        XCTAssertEqual(fence(n.id),.authorizationChanged);coordinator.enrollments[e.installation]?.generation = e.generation
        XCTAssertEqual(try stored(n.id)["push_state"] as? String,"unavailable")
        XCTAssertNil(fence(n.id));XCTAssertEqual(try stored(n.id)["push_state"] as? String,"uncertain")
    }
    /// Measures what the check sees when a file replaces the host's executable under the running process.
    func testHostFileReplacedUnderARunningProcess() throws {
        let directory = root.appendingPathComponent("Swap.app/Contents/MacOS");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let binary = directory.appendingPathComponent("codex"),next = directory.appendingPathComponent("codex.new")
        try buildIdleProgram(at:binary,mark:"a");try buildIdleProgram(at:next,mark:"b")
        let process = Process();process.executableURL = binary;process.standardOutput = FileHandle.nullDevice;try process.run()
        defer { process.terminate();process.waitUntilExit() }
        Thread.sleep(forTimeInterval:0.05);XCTAssertTrue(process.isRunning)
        let pid = process.processIdentifier,beforeFile = NativeCodeIdentity().executable(binary)?.cdhash
        let before = try XCTUnwrap(NativeCodeIdentity().signingInfo(pid))
        XCTAssertEqual(before[kSecCodeInfoUnique as String] as? Data,beforeFile)
        XCTAssertEqual(Darwin.rename(next.path,binary.path),0)
        let after = NativeCodeIdentity().signingInfo(pid),afterFile = NativeCodeIdentity().executable(binary)?.cdhash
        XCTAssertNotEqual(afterFile,beforeFile);XCTAssertTrue(process.isRunning)
        XCTAssertNil(after,"The validity check of the running process fails, so the route refuses until a new host runs")
    }
}

/// A small program, built here and signed ad hoc by the linker. A copy of an Apple tool is killed at start on this macOS, so a scan of one proves nothing.
func buildIdleProgram(at url: URL, mark: String = "x") throws {
    let source = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString+".c")
    try "#include <unistd.h>\nint main(void){(void)!write(1,\"\(mark)\",1);for(;;)pause();}\n".write(to:source,atomically:true,encoding:.utf8)
    let compiler = Process();compiler.executableURL = URL(fileURLWithPath:"/usr/bin/cc");compiler.arguments = ["-o",url.path,source.path]
    compiler.standardOutput = FileHandle.nullDevice;compiler.standardError = FileHandle.nullDevice
    try compiler.run();compiler.waitUntilExit()
    XCTAssertEqual(compiler.terminationStatus,0)
}
