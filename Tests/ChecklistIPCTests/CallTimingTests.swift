import XCTest
@testable import ChecklistIPC

final class CallTimingTests: XCTestCase {
    func testTimingTrailerPreservesSemanticEnvelopeAndMeasuresPhases() throws {
        let timing = ServiceCallTiming(received:ProcessInfo.processInfo.systemUptime - 0.02)
        timing.queued(since:ProcessInfo.processInfo.systemUptime - 0.01)
        timing.measure("bootstrap_verification_ms") { Thread.sleep(forTimeInterval:0.005) }
        timing.measure("execution_ms") { Thread.sleep(forTimeInterval:0.005) }
        let id = UUID().uuidString
        let result: [String:Any] = ["data":["id":"result","text":"quotes \" and braces {} and unicode é","_checklist":["retained":true]],"command_id":id]
        let decoded = try CommandReply.decode(timing.encode(result),method:"task_edit",commandID:id)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject:decoded["data"]!,options:[.sortedKeys]),try JSONSerialization.data(withJSONObject:result["data"]!,options:[.sortedKeys]))
        let fields = try XCTUnwrap(decoded["_checklist_timing"] as? [String:Any])
        XCTAssertEqual(Set(fields.keys),["queue_wait_ms","bootstrap_verification_ms","execution_ms","encoding_ms","total_ms","request_id","coordinator_queue_wait_ms","coordinator_dequeued_uptime_s","received_uptime_s","reply_ready_uptime_s"])
        XCTAssertNotNil((fields["request_id"] as? String).flatMap(UUID.init(uuidString:)))
        XCTAssertGreaterThanOrEqual((fields["queue_wait_ms"] as! Double),10)
        XCTAssertGreaterThanOrEqual((fields["bootstrap_verification_ms"] as! Double),5)
        XCTAssertGreaterThanOrEqual((fields["execution_ms"] as! Double),5)
        XCTAssertGreaterThanOrEqual((fields["encoding_ms"] as! Double),0)
        XCTAssertGreaterThanOrEqual((fields["total_ms"] as! Double),(fields["queue_wait_ms"] as! Double) + (fields["bootstrap_verification_ms"] as! Double) + (fields["execution_ms"] as! Double))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with:ServiceCallTiming().encode([:])))
    }
    func testTimingCannotTurnObservationOnlyReplyIntoMutationSuccess() throws {
        let id = UUID().uuidString
        let bytes = try ServiceCallTiming().encode(["data":["_checklist":["observation":true]],"command_id":id])
        XCTAssertThrowsError(try CommandReply.decode(bytes,method:"task_edit",commandID:id)) { error in
            XCTAssertEqual((error as? ChecklistError)?.details["reason"] as? String,"missing_mutation_result")
        }
    }
    func testFailureTimingDoesNotChangeRejection() throws {
        let bytes = try ServiceCallTiming().encode(["error":["code":"CONNECTION_REVOKED","message":"Disconnected"]])
        XCTAssertThrowsError(try CommandReply.decode(bytes,method:"service_info",commandID:nil)) { error in
            XCTAssertEqual((error as? ChecklistError)?.code,"CONNECTION_REVOKED")
        }
    }
    func testAdmissionAndQueueBoundariesAreSeparateFromServiceWork() throws {
        let now = ProcessInfo.processInfo.systemUptime
        let admission = ClientAdmissionTiming(listenerUptime: now - 0.05, identityStartedUptime: now - 0.04,
            identityFinishedUptime: now - 0.03, admittedUptime: now - 0.02, cacheHit: false)
        let timing = ServiceCallTiming(received: now - 0.01, admission: admission)
        timing.queued(since: now - 0.01)
        timing.queued(since: now - 0.005, phase: "worker_queue_wait_ms")
        let reply = try JSONSerialization.jsonObject(with: timing.encode(["data":[:]])) as! [String:Any]
        let fields = reply["_checklist_timing"] as! [String:Any]
        let coordinator = fields["coordinator_queue_wait_ms"] as! Double
        let worker = fields["worker_queue_wait_ms"] as! Double
        XCTAssertEqual(fields["queue_wait_ms"] as! Double, coordinator + worker, accuracy: 0.001)
        XCTAssertEqual(fields["received_uptime_s"] as! Double, now - 0.01)
        let observed = fields["admission"] as! [String:Any]
        XCTAssertEqual(observed["listener_uptime_s"] as! Double, now - 0.05)
        XCTAssertEqual(observed["cache_hit"] as? Bool, false)
    }

    func testQueueWaitEndsAtDequeueBeforeRequestDecodeAndTimingAllocation() throws {
        let now = ProcessInfo.processInfo.systemUptime
        let timing = ServiceCallTiming(received: now - 0.1)
        timing.queued(since: now - 0.1, until: now - 0.08)
        let reply = try JSONSerialization.jsonObject(with: timing.encode(["data":[:]])) as! [String:Any]
        let fields = reply["_checklist_timing"] as! [String:Any]
        XCTAssertEqual(fields["coordinator_queue_wait_ms"] as! Double, 20, accuracy: 0.001)
        XCTAssertEqual(fields["coordinator_dequeued_uptime_s"] as! Double, now - 0.08)
        XCTAssertGreaterThanOrEqual(fields["total_ms"] as! Double, 100)
    }

    private final class TimingPeer: NSObject, NSXPCListenerDelegate, ChecklistRPC {
        let listener = NSXPCListener.anonymous()
        var connections: [NSXPCConnection] = []
        override init() {super.init();listener.delegate=self;listener.resume()}
        func listener(_ listener: NSXPCListener,shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface=NSXPCInterface(with:ChecklistRPC.self);connection.exportedObject=self
            connections.append(connection);connection.resume();return true
        }
        func execute(_ request: Data,withReply reply: @escaping (Data)->Void) {
            reply(try! ServiceCallTiming().encode(["data":["fixture":true]]))
        }
        func stop() {listener.invalidate();connections.forEach {$0.invalidate()}}
    }
    func testAnonymousIPCReportsSetupAndSendSeparatelyWithoutChangingReply() throws {
        let peer = TimingPeer();defer {peer.stop()}
        let pipe = Pipe(),saved = dup(STDERR_FILENO)
        XCTAssertGreaterThanOrEqual(saved,0)
        dup2(pipe.fileHandleForWriting.fileDescriptor,STDERR_FILENO)
        defer {dup2(saved,STDERR_FILENO);close(saved)}
        let request = try JSONSerialization.data(withJSONObject:["method":"service_info","params":[:],"diagnostics_timing":true])
        let reply = try ChecklistClient(usesStoredCredential:false).requestOnce(request,replyTimeout:3,connection:NSXPCConnection(listenerEndpoint:peer.listener.endpoint))
        dup2(saved,STDERR_FILENO);try pipe.fileHandleForWriting.close()
        XCTAssertEqual((reply["data"] as? [String:Any])?["fixture"] as? Bool,true)
        let lines = String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).split(separator:"\n")
        let line = try XCTUnwrap(lines.first {$0.hasPrefix("ChecklistTiming ")})
        let fields = try JSONSerialization.jsonObject(with:Data(line.dropFirst("ChecklistTiming ".count).utf8)) as! [String:Any]
        let setup = try XCTUnwrap(fields["connection_setup_ms"] as? Double),send = try XCTUnwrap(fields["send_to_reply_ms"] as? Double)
        XCTAssertGreaterThanOrEqual(setup,0);XCTAssertGreaterThanOrEqual(send,0)
        XCTAssertEqual(setup+send,fields["round_trip_ms"] as! Double,accuracy:1)
        let service = try XCTUnwrap(fields["service"] as? [String:Any])
        let sent = try XCTUnwrap(fields["sent_uptime_s"] as? Double)
        let received = try XCTUnwrap(fields["reply_received_uptime_s"] as? Double)
        let resumed = try XCTUnwrap(fields["waiter_resumed_uptime_s"] as? Double)
        XCTAssertLessThanOrEqual(sent, service["received_uptime_s"] as! Double)
        XCTAssertLessThanOrEqual(service["reply_ready_uptime_s"] as! Double, received)
        XCTAssertLessThanOrEqual(received, resumed)
    }

    func testDiagnosticLogIsOneJSONLineWithoutProtocolStdout() throws {
        let pipe = Pipe()
        CallTimingLog.write(["scope":"test","total_ms":1.25],to:pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding:bytes,as:UTF8.self)
        XCTAssertTrue(text.hasPrefix("ChecklistTiming ")); XCTAssertEqual(text.filter {$0 == "\n"}.count,1)
        let object = try JSONSerialization.jsonObject(with:Data(text.dropFirst("ChecklistTiming ".count).utf8)) as? [String:Any]
        XCTAssertEqual(object?["total_ms"] as? Double,1.25)
    }

}
