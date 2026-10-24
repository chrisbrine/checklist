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
        XCTAssertEqual(Set(fields.keys),["queue_wait_ms","bootstrap_verification_ms","execution_ms","encoding_ms","total_ms","request_id"])
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
