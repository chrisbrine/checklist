import XCTest
import ChecklistIPC
@testable import ChecklistApp

@MainActor final class LongOperationReplyTests: XCTestCase {
    private let commandID = UUID().uuidString
    private let operationID = UUID().uuidString
    private let projectID = UUID().uuidString

    private func operation(method: String = "backup_create", state: String = "queued") -> [String: Any] {
        ["operation_id": operationID, "command_id": commandID, "method": method,
         "state": state, "status_method": "operation_get"]
    }
    private func accepted(method: String = "backup_create") -> [String: Any] {
        ["command_id": commandID, "command_outcome": "accepted", "data": operation(method: method)]
    }
    private var params: [String: Any] { ["command_id": commandID, "project_id": projectID] }
    private var queued: [String: Any] {
        ["command_id": commandID, "command_outcome": "queued", "data": [
            "command_id": commandID, "queued": true, "state": "queued", "status_method": "command_status"]]
    }
    private var result: [String: Any] { ["command_id": commandID, "data": ["backup_id": "synthetic-backup"]] }

    func testOperationWaitsForOriginalResultAndPreservesIdentityAndScope() async throws {
        var calls = 0, observations: [Bool] = []
        let reply = try await QueuedCommandReply.resolve(accepted(), method: "backup_create", params: params, pause: 0,
            transport: { [self] method, values in
                calls += 1; XCTAssertEqual(method, "operation_get")
                XCTAssertEqual(values["operation_id"] as? String, operationID)
                XCTAssertEqual(values["project_id"] as? String, projectID)
                XCTAssertNil(values["command_id"])
                var status = operation(state: calls == 1 ? "running" : "succeeded")
                if calls > 1 { status["result"] = result }
                return ["data": status]
            }, queued: { [self] identity, active in XCTAssertEqual(identity, commandID); observations.append(active) })
        XCTAssertEqual(calls, 2); XCTAssertEqual(observations, [true, false])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: reply, options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: result, options: .sortedKeys))
    }

    func testLongReadWithServiceGeneratedCommandIdentityResolvesNormally() async throws {
        let reply = try await QueuedCommandReply.resolve(accepted(method: "attachment_cleanup_preview"),
            method: "attachment_cleanup_preview", params: ["project_id": projectID], pause: 0,
            transport: { [self] _, _ in
                var status = operation(method: "attachment_cleanup_preview", state: "succeeded")
                status["result"] = ["data": ["preview_id": "synthetic-preview"]]
                return ["data": status]
            })
        XCTAssertEqual((reply["data"] as? [String: Any])?["preview_id"] as? String, "synthetic-preview")
    }

    func testOperationFailureReturnsOriginalErrorAndCommandIdentity() async throws {
        do {
            _ = try await QueuedCommandReply.resolve(accepted(), method: "backup_create", params: params, pause: 0,
                transport: { [self] _, _ in
                    var status = operation(state: "failed")
                    status["error"] = ["code": "BACKUP_FAILED", "message": "Synthetic disk full", "details": ["stage": "copy"]]
                    return ["data": status]
                })
            XCTFail("A failed operation cannot complete a native mutation")
        } catch let error as ChecklistError {
            XCTAssertEqual(error.code, "BACKUP_FAILED")
            XCTAssertEqual(error.details["command_id"] as? String, commandID)
            XCTAssertEqual(error.details["stage"] as? String, "copy")
            XCTAssertFalse(CommandReply.shouldRetainPending(after:error),"An actual terminal rejection remains definitive")
        }
    }

    func testCancellationKeepsOriginalRecoveryAndClearsWaitingIndicator() async throws {
        var observations: [Bool] = []
        let waiting = Task { [self] in
            try await QueuedCommandReply.resolve(accepted(), method: "backup_create", params: params,
                pause: 10_000_000_000, transport: { _, _ in XCTFail("Canceled wait must stop before status read"); return [:] },
                queued: { _, active in observations.append(active) })
        }
        await Task.yield(); waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Canceled operation wait completed") }
        catch { XCTAssertTrue(error is CancellationError); XCTAssertTrue(CommandReply.shouldRetainPending(after: error)) }
        XCTAssertEqual(observations, [true, false])
    }

    func testBackupFIFOCanYieldOperationDirectlyOrInsideAppliedResult() async throws {
        for direct in [true, false] {
            var methods: [String] = []
            let reply = try await QueuedCommandReply.resolve(queued, method: "backup_create", params: params, pause: 0,
                transport: { [self] method, _ in
                    methods.append(method)
                    if method == "command_status" {
                        return direct ? ["data": operation()] : ["data": ["state": "applied", "result": accepted()]]
                    }
                    var status = operation(state: "succeeded"); status["result"] = result
                    return ["data": status]
                })
            XCTAssertEqual(methods, ["command_status", "operation_get"])
            XCTAssertEqual((reply["data"] as? [String: Any])?["backup_id"] as? String, "synthetic-backup")
        }
    }

    func testBackupRetryKeepsOriginalCommandAndResolvesOperationAcceptance() async throws {
        var methods: [String] = []
        _ = try await QueuedCommandReply.resolve(queued, method: "backup_create", params: params, pause: 0,
            transport: { [self] method, values in
                methods.append(method)
                if method == "command_status" { return ["data": ["state": "applied", "retry_original": true]] }
                if method == "backup_create" {
                    XCTAssertEqual(values["command_id"] as? String, commandID)
                    XCTAssertEqual(values["project_id"] as? String, projectID)
                    return accepted()
                }
                var status = operation(state: "succeeded"); status["result"] = result
                return ["data": status]
            })
        XCTAssertEqual(methods, ["command_status", "backup_create", "operation_get"])
    }

    func testMismatchedStatusAndAcknowledgmentAsFinalResultRetainRecovery() async throws {
        for mismatch in [true, false] {
            do {
                _ = try await QueuedCommandReply.resolve(accepted(), method: "backup_create", params: params, pause: 0,
                    transport: { [self] _, _ in
                        var status = operation(state: "succeeded")
                        if mismatch { status["operation_id"] = UUID().uuidString }
                        status["result"] = accepted()
                        return ["data": status]
                    })
                XCTFail("Invalid terminal status completed a mutation")
            } catch let error as ChecklistError {
                XCTAssertEqual(error.code, "OUTCOME_UNKNOWN")
                XCTAssertEqual(error.details["command_id"] as? String, commandID)
                XCTAssertTrue(CommandReply.shouldRetainPending(after: error))
            }
        }
    }
    func testStatusReadRejectionRetainsAcceptedOriginalForBothJournals() async throws {
        for isOperation in [true,false] {
            for throwsError in [true,false] {
                do {
                    _ = try await QueuedCommandReply.resolve(isOperation ? accepted() : queued,method:"backup_create",params:params,pause:0,
                        transport:{ [self] _,_ in
                            if throwsError {throw ChecklistError("STORAGE_DRAINING","Synthetic status read refused",details:["command_outcome":"rejected","operation_id":operationID])}
                            return ["error":["code":"CONNECTION_REVOKED","message":"Synthetic status read denied","details":["command_outcome":"rejected","operation_id":operationID]]]
                        })
                    XCTFail("A rejected observation is not a rejected original command")
                } catch let error as ChecklistError {
                    XCTAssertEqual(error.code,throwsError ? "STORAGE_DRAINING" : "CONNECTION_REVOKED")
                    XCTAssertEqual(error.details["command_id"] as? String,commandID)
                    XCTAssertEqual(error.details["command_outcome"] as? String,"unknown")
                    XCTAssertEqual(error.details["operation_id"] as? String,operationID)
                    XCTAssertEqual(error.details["status_method"] as? String,isOperation ? "operation_get" : "command_status")
                    XCTAssertTrue(CommandReply.shouldRetainPending(after:error))
                }
            }
        }
    }

    func testStatusTransportCancellationKeepsRecoveryAndWaitingIndicatorHonest() async throws {
        var observations: [Bool] = []
        do {
            _ = try await QueuedCommandReply.resolve(accepted(),method:"backup_create",params:params,pause:0,
                transport:{ _,_ in throw CancellationError() },queued:{ _,active in observations.append(active) })
            XCTFail("Canceled observation cannot complete accepted work")
        } catch {XCTAssertTrue(error is CancellationError);XCTAssertTrue(CommandReply.shouldRetainPending(after:error))}
        XCTAssertEqual(observations,[true,false])
    }

}
