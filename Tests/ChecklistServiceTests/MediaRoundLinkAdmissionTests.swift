import Foundation
import os
import XCTest
import ChecklistIPC
@testable import ChecklistCore
@testable import ChecklistService

final class MediaRoundLinkAdmissionTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let router: CommandRouter
        let coordinator: Coordinator
        let connection = NSXPCConnection(machServiceName: "org.checklist.synthetic.unconnected")
        let peer: Peer
        let owner = Caller(role: "owner", installation: "round-link-owner", projectIDs: [])
        let project: String
        let session = uuid()
        let installation = "round-link-worker"
        let credential = "round-link-fixture"
        let registration: JSON
        let round: JSON

        init() throws {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(uuid())
            let router = try CommandRouter(root: root)
            let coordinator = Coordinator(router: router, enrollmentFile: root.appendingPathComponent("connections.json"),
                                          startBackgroundWork: false)
            self.root = root
            self.router = router
            self.coordinator = coordinator
            coordinator.workHealthFailures = 2
            peer = Peer(coordinator: coordinator, connection: connection)
            func setup(_ method: String, _ fields: JSON, caller: Caller) throws -> JSON {
                let params = fields.merging(["command_id": uuid()]) { original, _ in original }
                return try XCTUnwrap(router.handle(method: method, params: params, caller: caller)["data"] as? JSON)
            }
            project = try XCTUnwrap(setup("project_create", ["name": "Link admission", "root_path": root.path],
                                          caller: owner)["id"] as? String)
            let generation = "current"
            registration = try setup("session_register", ["project_id": project, "project_ids": [project],
                "session_id": session, "installation": installation + "/" + generation, "provider": "codex",
                "role": "worker", "workspace": root.path], caller: owner)
            coordinator.enrollments[installation] = Enrollment(installation: installation, name: "Link admission",
                provider: "codex", role: "worker", projectIDs: [project], sessionID: session, workspace: root.path,
                profileID: nil, tokenDigest: ChecklistCore.hash(Data(credential.utf8)), generation: generation)
            let worker = Caller(role: "worker", installation: installation + "/" + generation, projectIDs: [project],
                                sessionID: session, workspace: root.path)
            let type = try setup("media_type_adopt_starter", ["project_id": project, "expected_revision": 1,
                                  "starter": "generic"], caller: worker)
            round = try setup("media_round_create", ["project_id": project, "type_id": try XCTUnwrap(type["id"]),
                              "title": "Draft"], caller: worker)
        }

        func close() {
            coordinator.queue.sync {}
            coordinator.mediaRoundLinkQueue.sync {}
            coordinator.queue.sync { coordinator.storageWake?.cancel() }
            coordinator.storageQueue.sync {}
            coordinator.queue.sync { coordinator.storageWake?.cancel() }
            connection.invalidate()
            try? router.closeStore()
            try? FileManager.default.removeItem(at: root)
        }

        func request(overrides: JSON = [:], timed: Bool = false) throws -> JSON {
            let params: JSON = ["project_id": project, "round_id": try XCTUnwrap(round["id"]),
                               "task_id": NSNull(), "expected_revision": try XCTUnwrap(round["revision"]),
                               "command_id": uuid()]
            return ["method": "media_round_link_task", "installation": installation, "credential": credential,
                    "workspace": root.path, "diagnostics_timing": timed,
                    "params": params.merging(overrides) { _, replacement in replacement }]
        }

        func submit(_ request: JSON, receive: @escaping @Sendable (Data) -> Void) throws {
            peer.execute(try JSONSerialization.data(withJSONObject: request), withReply: receive)
        }

        func inlineReply(_ request: JSON) -> Data {
            coordinator.queue.sync {
                // The previous peer route executed the router on this queue.
                var reply: JSON
                do { reply = try coordinator.execute(request, connection: connection) }
                catch { reply = ["error": Peer.publicError(error)] }
                reply["write_admission"] = router.writeAdmissionStatus
                return Peer.responseBytes(reply, timing: nil)
            }
        }
    }

    func testObjectGateWaitLeavesStatusAndAuthenticationResponsive() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let occupied = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holder = DispatchQueue(label: "test.media-link-object-gate")
        let root = fixture.root
        holder.async {
            do {
                try ArchiveStorageGate.withExclusive(root: root) { _ in
                    occupied.signal()
                    _ = release.wait(timeout: .now() + 12)
                }
            } catch { XCTFail("Could not hold the object gate: \(error)") }
        }
        defer { release.signal(); holder.sync {} }
        guard occupied.wait(timeout: .now() + 4) == .success else { return XCTFail("Object gate was not acquired") }

        let link = expectation(description: "Committed round link")
        let status = expectation(description: "Unenrolled status")
        let authenticated = expectation(description: "Authenticated service info")
        let finished = OSAllocatedUnfairLock(initialState: false)
        let linkRequest = try fixture.request(timed: true)
        let params = try XCTUnwrap(linkRequest["params"] as? JSON)
        let command = try XCTUnwrap(params["command_id"] as? String)
        try fixture.submit(linkRequest) { bytes in
            let reply = (try? JSONSerialization.jsonObject(with: bytes)) as? JSON
            XCTAssertEqual(reply?["command_id"] as? String, command)
            XCTAssertEqual((reply?["data"] as? JSON)?["revision"] as? Int, 2)
            let timing = reply?["_checklist_timing"] as? JSON
            for phase in ["worker_queue_wait_ms", "media_preparation_ms", "object_gate_wait_ms",
                          "storage_writer_queue_ms", "domain_transaction_ms"] {
                XCTAssertNotNil(timing?[phase] as? Double, phase)
            }
            finished.withLock { $0 = true }
            link.fulfill()
        }
        try fixture.submit(["method": "service_info", "params": [:]]) { bytes in
            let reply = (try? JSONSerialization.jsonObject(with: bytes)) as? JSON
            XCTAssertEqual((reply?["data"] as? JSON)?["name"] as? String, "Checklist")
            status.fulfill()
        }
        try fixture.submit(["method": "service_info", "params": [:], "installation": fixture.installation,
                            "credential": fixture.credential, "workspace": fixture.root.path]) { [session = fixture.session] bytes in
            let reply = (try? JSONSerialization.jsonObject(with: bytes)) as? JSON
            XCTAssertEqual((reply?["data"] as? JSON)?["session_id"] as? String, session)
            authenticated.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [status, authenticated], timeout: 3), .completed)
        XCTAssertFalse(finished.withLock { $0 })
        release.signal()
        wait(for: [link], timeout: 6)
    }

    func testQueuedLinkMatchesInlineReplayAndRefusals() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let command = uuid()
        let original = try fixture.request(overrides: ["command_id": command])
        _ = fixture.inlineReply(original)
        let generated = try (1...8).map { offset in
            try fixture.request(overrides: offset.isMultiple(of: 2)
                ? ["expected_revision": offset + 2] : ["round_id": uuid()])
        }
        let changed = try fixture.request(overrides: ["command_id": command, "expected_revision": 2])
        for request in [original, changed] + generated {
            let baseline = fixture.inlineReply(request)
            let reply = expectation(description: "Queued result matches inline result")
            try fixture.submit(request) { data in
                XCTAssertEqual(data, baseline)
                reply.fulfill()
            }
            wait(for: [reply], timeout: 5)
        }
    }

    func testQueuedLinkRechecksSessionGenerationBeforeWriting() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let occupied = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        fixture.coordinator.mediaRoundLinkQueue.async {
            occupied.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        defer { release.signal() }
        guard occupied.wait(timeout: .now() + 4) == .success else { return XCTFail("Link queue was not held") }
        let refusal = expectation(description: "Changed registration refuses")
        try fixture.submit(fixture.request()) { bytes in
            let reply = (try? JSONSerialization.jsonObject(with: bytes)) as? JSON
            XCTAssertEqual((reply?["error"] as? JSON)?["code"] as? String, "CONNECTION_REVOKED")
            XCTAssertNotNil(reply?["write_admission"])
            refusal.fulfill()
        }
        fixture.coordinator.queue.sync {}
        _ = try fixture.router.handle(method: "session_update", params: ["project_id": fixture.project,
            "session_id": fixture.session, "command_id": uuid(), "provider": "claude",
            "expected_revision": try XCTUnwrap(fixture.registration["revision"])], caller: fixture.owner)
        release.signal()
        wait(for: [refusal], timeout: 5)
    }
}
