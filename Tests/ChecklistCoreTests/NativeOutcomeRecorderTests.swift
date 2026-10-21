import XCTest
import GRDB
@testable import ChecklistCore

/// CL-80: a native write that the service cannot record is logged with its delivery ID,
/// and the delivery shows the result of a bounded retry or delivery_uncertain.
extension CoreTests {
    private final class FailureInjector {
        var failing: (String, [String: Any]) -> Error? = { _, _ in nil }
        var calls: [(method: String, command: String)] = []
        var log: [String] = []
    }

    private func recorder(_ injector: FailureInjector) -> NativeOutcomeRecorder {
        let bridge = Caller(role: "owner", installation: "native-bridge", projectIDs: [])
        return NativeOutcomeRecorder(handle: { [router] method, params in
            injector.calls.append((method, params["command_id"] as? String ?? ""))
            if let error = injector.failing(method, params) { throw error }
            return try router!.handle(method: method, params: params, caller: bridge)
        }, log: { injector.log.append($0) }, pause: { _ in })
    }

    private func nativeNote(_ f: (pid: String, task: JSON, sid: String, worker: Caller)) throws -> (note: JSON, delivery: String) {
        let note = try call("message_send", ["project_id": f.pid, "task_id": f.task["id"]!, "body": "Synthetic native outcome note", "expects_reply": true])
        let id = (note["deliveries"] as! [JSON])[0]["id"] as! String
        let bridge = Caller(role: "owner", installation: "native-bridge", projectIDs: [])
        _ = try call("delivery_record", ["delivery_id": id, "state": "uncertain", "receipt": ["stage": "native_send_started"]], bridge)
        return (note, id)
    }

    private func delivery(_ id: String) throws -> JSON { try router.dbQueue.read { try router.record($0, id, type: "delivery") } }

    func testNativeWriteRetriesStorageFailureWithTheSameCommandID() throws {
        let f = try nativeHandlerFixture(), (_, id) = try nativeNote(f), injector = FailureInjector()
        var failures = 1
        injector.failing = { _, _ in
            guard failures > 0 else { return nil }
            failures -= 1; return DatabaseError(resultCode: .SQLITE_BUSY, message: "database is locked")
        }
        let outcome = recorder(injector).record("delivery_record", params: ["delivery_id": id, "state": "transport_written", "receipt": ["bytes": 12]], deliveryID: id)
        XCTAssertEqual(outcome, .recorded(attempts: 2))
        XCTAssertEqual(injector.calls.count, 2)
        XCTAssertEqual(Set(injector.calls.map(\.command)).count, 1, "a retry must reuse the original command ID")
        XCTAssertEqual(try delivery(id)["push_state"] as? String, "transport_written")
    }

    /// Finding 47eba94b: a failure that a later retry recovers is still logged with its delivery ID.
    func testRecoveredFailureIsLoggedForEachNativeWrite() throws {
        let f = try nativeHandlerFixture(), bridge = Caller(role: "owner", installation: "native-bridge", projectIDs: [])
        for method in ["delivery_record", "delivery_host_status", "native_reply_record"] {
            let (note, id) = try nativeNote(f), injector = FailureInjector()
            if method == "delivery_host_status" { _ = try call("delivery_record", ["delivery_id": id, "state": "transport_written", "receipt": ["bytes": 12]], bridge) }
            var failures = 1
            injector.failing = { called, _ in
                guard called == method, failures > 0 else { return nil }
                failures -= 1; return DatabaseError(resultCode: .SQLITE_BUSY, message: "database is locked")
            }
            let params: JSON
            switch method {
            case "delivery_record": params = ["delivery_id": id, "state": "transport_written", "receipt": ["bytes": 12]]
            case "delivery_host_status": params = ["delivery_id": id, "status": "held", "receipt": ["host_status": "held"]]
            default: params = ["project_id": f.pid, "reply_to": note["id"]!, "recipient_session_id": f.sid, "body": "Synthetic answer", "source_evidence": ["native_peer_pid": 1]]
            }
            XCTAssertEqual(recorder(injector).record(method, params: params, deliveryID: id), .recorded(attempts: 2), method)
            let lines = injector.log.filter { $0.contains(id) }
            XCTAssertEqual(lines.count, 1, method)
            XCTAssertTrue(lines.first?.contains("attempt 1 of 3 failed (SQLITE_5)") == true, method)
            XCTAssertFalse(lines.first?.contains("Synthetic answer") == true, "the log never carries a note body")
        }
    }

    func testLostWriteResultMarksDeliveryUncertain() throws {
        let f = try nativeHandlerFixture(), (_, id) = try nativeNote(f), injector = FailureInjector()
        injector.failing = { method, params in
            method == "delivery_record" && params["state"] as? String == "transport_written" ? CoreError("OUTCOME_UNKNOWN", "Storage could not establish this command's committed outcome.") : nil
        }
        let outcome = recorder(injector).record("delivery_record", params: ["delivery_id": id, "state": "transport_written", "receipt": ["bytes": 12]], deliveryID: id, routeGeneration: "route-1")
        XCTAssertEqual(outcome, .markedUncertain)
        XCTAssertEqual(injector.calls.filter { $0.method == "delivery_record" }.count, NativeOutcomeRecorder.attemptLimit + 1)
        let current = try delivery(id)
        XCTAssertEqual(current["state"] as? String, "delivery_uncertain")
        XCTAssertEqual((current["transport_receipt"] as? JSON)?["stage"] as? String, "write_result_record_failed")
        XCTAssertEqual((current["transport_receipt"] as? JSON)?["route_generation"] as? String, "route-1")
        XCTAssertTrue(injector.log.contains { $0.contains(id) })
    }

    func testLostHostStatusMarksDeliveryUncertain() throws {
        let f = try nativeHandlerFixture(), (_, id) = try nativeNote(f), injector = FailureInjector()
        let bridge = Caller(role: "owner", installation: "native-bridge", projectIDs: [])
        _ = try call("delivery_record", ["delivery_id": id, "state": "transport_written", "receipt": ["bytes": 12]], bridge)
        injector.failing = { method, _ in method == "delivery_host_status" ? DatabaseError(resultCode: .SQLITE_IOERR) : nil }
        let outcome = recorder(injector).record("delivery_host_status", params: ["delivery_id": id, "status": "held", "receipt": ["host_status": "held"]], deliveryID: id)
        XCTAssertEqual(outcome, .markedUncertain)
        let current = try delivery(id)
        XCTAssertEqual(current["state"] as? String, "delivery_uncertain")
        XCTAssertEqual((current["transport_receipt"] as? JSON)?["stage"] as? String, "host_status_record_failed")
        XCTAssertEqual((current["transport_receipt"] as? JSON)?["host_status"] as? String, "held")
        XCTAssertNil(current["host_status"], "the lost host notice is not invented")
        XCTAssertTrue(injector.log.contains { $0.contains(id) })
    }

    func testLostNativeReplyMarksDeliveryUncertain() throws {
        let f = try nativeHandlerFixture(), (note, id) = try nativeNote(f), injector = FailureInjector()
        injector.failing = { method, _ in method == "native_reply_record" ? DatabaseError(resultCode: .SQLITE_FULL) : nil }
        let input: JSON = ["project_id": f.pid, "reply_to": note["id"]!, "recipient_session_id": f.sid, "body": "Synthetic answer", "source_evidence": ["native_peer_pid": 1]]
        XCTAssertEqual(recorder(injector).record("native_reply_record", params: input, deliveryID: id), .markedUncertain)
        let current = try delivery(id)
        XCTAssertEqual(current["state"] as? String, "delivery_uncertain")
        XCTAssertEqual((current["transport_receipt"] as? JSON)?["stage"] as? String, "native_reply_record_failed")
        let message = try router.dbQueue.read { try router.record($0, note["id"] as! String, type: "message") }
        XCTAssertFalse(bool(message, "reply_used"), "no reply was recorded, so the allowance stays unused")
        XCTAssertTrue(injector.log.contains { $0.contains(id) })
    }

    func testRefusedNativeReplyIsLoggedAndNotRetried() throws {
        let f = try nativeHandlerFixture(), (note, id) = try nativeNote(f), injector = FailureInjector()
        let input: JSON = ["project_id": f.pid, "reply_to": note["id"]!, "recipient_session_id": f.sid, "body": "Synthetic answer", "source_evidence": ["native_peer_pid": 1]]
        XCTAssertEqual(recorder(injector).record("native_reply_record", params: input, deliveryID: id), .recorded(attempts: 1))
        XCTAssertEqual(recorder(injector).record("native_reply_record", params: input, deliveryID: id), .refused(code: "FORBIDDEN"))
        XCTAssertEqual(injector.calls.filter { $0.method == "native_reply_record" }.count, 2)
        XCTAssertEqual(try delivery(id)["state"] as? String, "acknowledged")
        XCTAssertTrue(injector.log.contains { $0.contains(id) && $0.contains("FORBIDDEN") })
    }

    func testFailedFallbackIsLoggedAsLostAndKeepsTheSendFence() throws {
        let f = try nativeHandlerFixture(), (_, id) = try nativeNote(f), injector = FailureInjector()
        injector.failing = { _, _ in DatabaseError(resultCode: .SQLITE_BUSY) }
        XCTAssertEqual(recorder(injector).record("delivery_record", params: ["delivery_id": id, "state": "transport_written"], deliveryID: id), .lost)
        let lines = injector.log.filter { $0.contains(id) }
        XCTAssertEqual(lines.filter { $0.contains("attempt") && $0.contains("failed (SQLITE_5)") }.count, 2 * NativeOutcomeRecorder.attemptLimit, "the write and its fallback log every failed attempt")
        XCTAssertEqual(lines.filter { !$0.contains(": attempt ") }.count, 2, "one outcome line for the lost write and one for the failed fallback")
        // The uncertainty fence written before native I/O remains the honest state.
        XCTAssertEqual(try delivery(id)["state"] as? String, "delivery_uncertain")
    }
}
