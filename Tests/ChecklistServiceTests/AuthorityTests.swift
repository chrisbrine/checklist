import XCTest
import CryptoKit
@testable import ChecklistCore
import ChecklistIPC
@testable import ChecklistService

/// Exercise the service's real caller/router boundary without starting a listener,
/// observing host sessions, reading live enrollments or touching the keychain.
final class AuthorityTests: XCTestCase {
    private var root: URL!
    private var coordinator: Coordinator!
    private var connection: NSXPCConnection!
    private var project: String!
    private let credential = "synthetic-service-test-credential"
    private let owner = Caller(role: "owner", installation: "service-test-owner", projectIDs: [])

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let router = try CommandRouter(root: root.appendingPathComponent("store"))
        let result = try router.handle(method: "project_create", params: ["command_id": UUID().uuidString,
            "name": "Service authority fixture", "key_prefix": "SA", "root_path": root.path], caller: owner)
        project = try XCTUnwrap((result["data"] as? [String: Any])?["id"] as? String)
        coordinator = Coordinator(router: router, enrollmentFile: root.appendingPathComponent("connections.json"), startBackgroundWork: false)
        // Never resumed: it cannot connect to any service and has no verified peer.
        connection = NSXPCConnection(machServiceName: "org.checklist.synthetic.unconnected")
    }
    override func tearDownWithError() throws {
        connection?.invalidate(); connection = nil
        // finish(runHooks:) plans the storage wake on storageQueue and installs it on queue.
        // Drain both advisory/storage work (and one replan) before deleting its store.
        if let coordinator {
            for _ in 0..<2 { coordinator.workHealthQueue.sync {}; coordinator.storageQueue.sync {}; coordinator.queue.sync {} }
            coordinator.queue.sync { coordinator.storageWake?.cancel(); coordinator.workHealthWake?.cancel() }
        }
        coordinator = nil
        if let root { try FileManager.default.removeItem(at: root) }
    }
    private func enrollment() -> Enrollment {
        Enrollment(installation: "synthetic", name: "Synthetic", provider: "codex", role: "worker",
            projectIDs: [project], sessionID: "service-test-session", workspace: root.path, profileID: nil,
            tokenDigest: SHA256.hash(data: Data(credential.utf8)).map { String(format: "%02x", $0) }.joined(), generation: "test-generation")
    }
    private func register(_ e: Enrollment) throws {
        _ = try coordinator.router.handle(method: "session_register", params: ["command_id": UUID().uuidString,
            "project_id": project!, "project_ids": e.projectIDs, "session_id": e.sessionID,
            "installation": e.installation + "/" + e.generation, "provider": e.provider, "role": e.role,
            "workspace": root.path], caller: owner)
        coordinator.enrollments[e.installation] = e
    }
    private func request(_ method: String = "task_list") -> [String: Any] {
        ["method": method, "installation": "synthetic", "credential": credential, "workspace": root.path,
         "params": method == "service_info" ? [:] : ["project_id": project!, "command_id": UUID().uuidString]]
    }
    private func rejects(_ code: String, _ body: () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? ChecklistError)?.code, code, file: file, line: line)
        }
    }
    func testNativeDispatchSelectsOnlyCurrentEndpointSessionsBeforeProjection() throws {
        var projected = 0
        XCTAssertTrue(coordinator.nativeDispatchDeliveries { _ in projected += 1;return nil }.isEmpty)
        XCTAssertEqual(projected,0,"An empty native route set must not expand the outbox")
        var current = enrollment();current.nativeEndpoint = "/synthetic/endpoint"
        var revoked = current;revoked.installation = "revoked";revoked.sessionID = "revoked-session";revoked.revoked = true
        var pickup = enrollment();pickup.installation = "pickup";pickup.sessionID = "pickup-session"
        coordinator.enrollments = [current.installation:current,revoked.installation:revoked,pickup.installation:pickup]
        let rows = coordinator.nativeDispatchDeliveries(endpointAvailable:{_ in true}) {params in
            projected += 1
            XCTAssertEqual(params["native_dispatch_candidates"] as? Bool,true)
            XCTAssertEqual(params["native_session_ids"] as? [String],[current.sessionID])
            return ["deliveries":[["id":"eligible-delivery"]]]
        }
        XCTAssertEqual(rows.first?["id"] as? String,"eligible-delivery")
        XCTAssertEqual(projected,1)
        XCTAssertTrue(coordinator.nativeDispatchDeliveries(endpointAvailable:{_ in false}) { _ in XCTFail("An absent endpoint cannot be projected");return nil }.isEmpty)
        current.revoked = true;coordinator.enrollments[current.installation] = current
        XCTAssertTrue(coordinator.nativeDispatchDeliveries { _ in XCTFail("A revoked route cannot be projected");return nil }.isEmpty)
    }

    func testOwnerFlagCannotMintHumanAuthority() throws {
        var input = request(); input["owner_channel"] = true
        rejects("OWNER_CHANNEL_REQUIRED") { try coordinator.caller(input, connection: connection) }
        XCTAssertFalse(coordinator.owner(connection))
    }
    func testAnonymousDiscoveryHasNoProjectOrSessionAuthority() throws {
        let caller = try coordinator.caller(["method": "service_info"], connection: connection)
        XCTAssertEqual(caller.role, "worker"); XCTAssertTrue(caller.projectIDs.isEmpty); XCTAssertNil(caller.sessionID)
        rejects("SETUP_REQUIRED") { try coordinator.caller(request(), connection: connection) }
    }
    func testCommittedWorkerRetainsExactScopedAuthority() throws {
        let e = enrollment(); try register(e)
        let caller = try coordinator.caller(request(), connection: connection)
        XCTAssertEqual(caller.role, "worker"); XCTAssertEqual(caller.projectIDs, [project!])
        XCTAssertEqual(caller.sessionID, e.sessionID); XCTAssertEqual(caller.installation, "synthetic/test-generation")
        XCTAssertEqual(caller.workspace, root.path)
    }
    func testCredentialWorkspaceAndRevocationFailClosed() throws {
        var e = enrollment(); try register(e)
        var wrong = request(); wrong["credential"] = credential + "wrong"
        rejects("SETUP_REQUIRED") { try coordinator.caller(wrong, connection: connection) }
        wrong = request(); wrong["workspace"] = root.deletingLastPathComponent().path
        rejects("WORKSPACE_MISMATCH") { try coordinator.caller(wrong, connection: connection) }
        e.revoked = true; e.ownerRevoked = true; coordinator.enrollments[e.installation] = e
        rejects("CONNECTION_REVOKED") { try coordinator.caller(request(), connection: connection) }
    }
    func testPreparedOrMismatchedRegistrationCannotAuthenticate() throws {
        var e = enrollment(); coordinator.enrollments[e.installation] = e
        rejects("CONNECTION_REPAIR_REQUIRED") { try coordinator.caller(request(), connection: connection) }
        try register(e); e.generation = "uncommitted-generation"; coordinator.enrollments[e.installation] = e
        rejects("CONNECTION_REPAIR_REQUIRED") { try coordinator.caller(request(), connection: connection) }
    }
    func testPairingRequiresOwnerBeforePersistence() throws {
        try register(enrollment())
        rejects("FORBIDDEN") { try coordinator.route(request("connection_pair"), connection: connection) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.enrollmentFile.path))
        XCTAssertEqual(coordinator.enrollments.count, 1)
    }
    func testBootstrapAndProjectCreationRejectUnverifiedPeer() throws {
        for method in ["connection_bootstrap", "project_create"] {
            var input = request(method)
            input["params"] = ["provider": "codex", "native_session_id": "forged", "workspace": root.path]
            input["native_context"] = input["params"]
            rejects("NATIVE_CLIENT_REQUIRED") { try coordinator.route(input, connection: connection) }
        }
        XCTAssertTrue(coordinator.enrollments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.enrollmentFile.path))
    }
    func testProjectCreationRequiresNativeContextBeforeEnrollment() throws {
        rejects("NATIVE_SESSION_REQUIRED") { try coordinator.route(request("project_create"), connection: connection) }
        XCTAssertTrue(coordinator.enrollments.isEmpty)
    }
    func testAutomaticEnrollmentCannotBorrowManualCredential() throws {
        var e = enrollment(); try register(e); e.automatic = true
        coordinator.enrollments[e.installation] = e
        rejects("NATIVE_SESSION_REQUIRED") { try coordinator.caller(request(), connection: connection) }
    }
    private func peerReply(_ object:[String:Any]) throws -> [String:Any] {
        let completed = expectation(description:"Peer reply")
        var result: [String:Any] = [:]
        Peer(coordinator:coordinator,connection:connection).execute(try JSONSerialization.data(withJSONObject:object)) { bytes in
            result = (try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any] ?? [:]
            completed.fulfill()
        }
        wait(for:[completed],timeout:5)
        // Read hooks enqueue after reply delivery. Drain after that work item.
        let drained = expectation(description:"Coordinator drained")
        coordinator.queue.asyncAfter(deadline:.now()+0.02) {drained.fulfill()}
        wait(for:[drained],timeout:5)
        return result
    }
    func testPeerReportsOptInTimingOnSuccessAndRefusal() throws {
        try register(enrollment())
        var input = request("service_info"); input["diagnostics_timing"] = true
        let first = try peerReply(input)
        XCTAssertNotNil(first["data"],String(describing:first))
        let timing = try XCTUnwrap(first["_checklist_timing"] as? [String:Any])
        XCTAssertEqual(Set(timing.keys),["queue_wait_ms","bootstrap_verification_ms","execution_ms","encoding_ms","total_ms","request_id","route_lifecycle_ms","route_current_session_ms"])
        XCTAssertTrue(timing.filter {$0.key != "request_id"}.values.allSatisfy {($0 as? Double).map {$0.isFinite && $0 >= 0} == true})
        XCTAssertGreaterThan(timing["bootstrap_verification_ms"] as! Double,0)
        XCTAssertGreaterThan(timing["execution_ms"] as! Double,0)
        input["owner_channel"] = true
        let refused = try peerReply(input)
        XCTAssertEqual((refused["error"] as? [String:Any])?["code"] as? String,"OWNER_CHANNEL_REQUIRED")
        XCTAssertNotNil(refused["_checklist_timing"])
        XCTAssertNil(try peerReply(request("service_info"))["_checklist_timing"])
    }
    func testRepeatedPeerReadDoesNotRetainRevokedEnrollmentAuthority() throws {
        var e = enrollment(); try register(e)
        let first = try peerReply(request("service_info"))
        XCTAssertNotNil(first["data"],String(describing:first))
        e.revoked = true; e.ownerRevoked = true
        coordinator.queue.sync {coordinator.enrollments[e.installation] = e}
        let result = try peerReply(request("service_info"))
        XCTAssertEqual((result["error"] as? [String:Any])?["code"] as? String,"CONNECTION_REVOKED")
    }
    func testPureReadDoesNotRunMutationHooksAndWritesStillWake() throws {
        try register(enrollment())
        var wakes = 0
        coordinator.waiters[UUID()] = {wakes += 1}
        XCTAssertNotNil(try peerReply(request("service_info"))["data"])
        XCTAssertEqual(wakes,0,"Pure reads do not signal changes or rescan all native deliveries")
        XCTAssertNil(coordinator.workHealthWake)
        coordinator.queue.sync {
            Peer(coordinator:coordinator,connection:connection).finish(["data":["changed":true]],runHooks:true,reply:{_ in})
        }
        XCTAssertEqual(wakes,1,"Mutation hooks remain active")
        XCTAssertTrue(Peer.requiresAfterCommand("message_send"))
        XCTAssertTrue(Peer.requiresAfterCommand("attachment_read"),"Availability repairs and managed leases keep hooks")
        XCTAssertFalse(Peer.requiresAfterCommand("tool_catalog"))
        coordinator.workHealthWake?.cancel()
    }

    func testBootstrapRechecksCurrentRegistrationAfterFreshCredentialRead() throws {
        let sid = UUID().uuidString, domain = "synthetic-recheck-domain"
        let digest = SHA256.hash(data:Data("codex|\(sid)|\(project!)".utf8)).map {String(format:"%02x",$0)}.joined()
        var e = Enrollment(installation:"auto-codex-" + digest.prefix(40),name:"Synthetic worker",provider:"codex",role:"worker",
                           projectIDs:[project],sessionID:sid,workspace:root.path,profileID:nil,
                           tokenDigest:SHA256.hash(data:Data(credential.utf8)).map {String(format:"%02x",$0)}.joined(),generation:"recheck-generation")
        e.automatic = true;e.nativeSessionID = sid;e.nativeExecutionDomain = domain
        _ = try coordinator.router.handle(method:"session_register",params:["command_id":UUID().uuidString,"project_id":project!,
            "project_ids":[project!],"session_id":sid,"installation":e.installation + "/" + e.generation,"provider":"codex",
            "role":"worker","workspace":root.path,"execution_domain":domain],caller:owner)
        coordinator.enrollments[e.installation] = e
        let native = Coordinator.VerifiedNativeWorkspace(provider:"codex",session:sid,process:getpid(),executionDomain:domain,workspace:root.path)
        var reads = 0
        for _ in 0..<2 {
            let result = try coordinator.bootstrapVerifiedWorkspace([:],native:native,readCredential:{ _ in reads += 1;return self.credential })
            XCTAssertFalse(result.changed)
        }
        XCTAssertEqual(reads,2,"Each bootstrap must freshly read its credential")
        rejects("CONNECTION_REPAIR_REQUIRED") {
            try self.coordinator.bootstrapVerifiedWorkspace([:],native:native,readCredential:{ _ in
                let session = try XCTUnwrap(self.coordinator.router.connectionSession(sessionID:sid,project:self.project,caller:self.owner))
                _ = try self.coordinator.router.handle(method:"session_update",params:["command_id":UUID().uuidString,"project_id":self.project!,"session_id":sid,"expected_revision":session["revision"]!,"state":"revoked"],caller:self.owner)
                return self.credential
            })
        }
    }

    func testNativeBootstrapReadsArchivedAndRestoredProjectReasonsWithoutWriteAccess() throws {
        let sid = UUID().uuidString, domain = "synthetic-native-domain"
        let digest = SHA256.hash(data:Data("codex|\(sid)|\(project!)".utf8)).map {String(format:"%02x",$0)}.joined()
        var e = Enrollment(installation:"auto-codex-" + digest.prefix(40),name:"Synthetic native worker",provider:"codex",role:"worker",
                           projectIDs:[project],sessionID:sid,workspace:root.path,profileID:nil,
                           tokenDigest:SHA256.hash(data:Data(credential.utf8)).map {String(format:"%02x",$0)}.joined(),generation:"archive-test-generation")
        e.automatic = true;e.nativeSessionID = sid;e.nativeExecutionDomain = domain
        _ = try coordinator.router.handle(method:"session_register",params:["command_id":UUID().uuidString,"project_id":project!,
            "project_ids":[project!],"session_id":sid,"installation":e.installation + "/" + e.generation,"provider":"codex",
            "role":"worker","workspace":root.path,"execution_domain":domain],caller:owner)
        coordinator.enrollments[e.installation] = e
        let native = Coordinator.VerifiedNativeWorkspace(provider:"codex",session:sid,process:getpid(),executionDomain:domain,workspace:root.path)
        let worker = Caller(role:"worker",installation:e.installation + "/" + e.generation,projectIDs:[project],sessionID:sid,workspace:root.path,executionDomain:domain)
        func call(_ method: String,_ params: [String:Any]) throws -> [String:Any] {
            var params = params;params["project_id"] = project!
            if !CommandRouter.readMethods.contains(method) {params["command_id"] = UUID().uuidString}
            return try coordinator.router.handle(method:method,params:params,caller:worker)["data"] as! [String:Any]
        }
        for reason: String? in ["  Native project reason: café\nSecond line.  ",nil,""," \n\t"] {
            for archived in [true,false] {
                let current = try call("project_settings_get",[:])
                var params: [String:Any] = ["expected_revision":current["revision"]!,"archived":archived]
                if let reason {params["reason"] = reason}
                _ = try call("project_archive",params)
                let before = try call("project_settings_get",[:])
                let reply = try coordinator.bootstrapVerifiedWorkspace([:],native:native,readCredential:{ installation in
                    XCTAssertEqual(installation,e.installation);return self.credential
                })
                XCTAssertEqual((reply.reply["data"] as? [String:Any])?["project_id"] as? String,project)
                XCTAssertFalse(reply.changed,"A reconnect must not rotate the grant or repair registration")
                let history = try call("history_list",["entity":"project"])
                let event = try XCTUnwrap((history["events"] as! [[String:Any]]).last {$0["kind"] as? String == "project_updated"})
                let data = try XCTUnwrap(event["data"] as? [String:Any])
                XCTAssertEqual(data["reason"] as? String,reason.flatMap {$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil : $0})
                XCTAssertEqual(data["origin"] as? String,"agent");XCTAssertEqual(event["actor"] as? String,worker.principal)
                XCTAssertEqual(try call("project_settings_get",[:])["revision"] as? Int,before["revision"] as? Int)
                XCTAssertEqual(try call("project_settings_get",[:])["archived"] as? Bool,archived)
                if archived {
                    XCTAssertThrowsError(try call("project_edit",["expected_revision":before["revision"]!,"name":"Must remain archived"])) {
                        XCTAssertEqual(($0 as? CoreError)?.code,"PROJECT_ARCHIVED")
                    }
                    let restrictions: [(inout Enrollment) -> Void] = [
                        {$0.projectIDs = []},{$0.revoked = true},{$0.ownerRevoked = true},
                        {$0.role = "assistant"},{$0.automatic = false},{$0.nativeExecutionDomain = "other-host"}]
                    for restrict in restrictions {
                        var invalid = e;restrict(&invalid);coordinator.enrollments[e.installation] = invalid
                        rejects("PROJECT_ARCHIVED") {try self.coordinator.bootstrapVerifiedWorkspace([:],native:native,readCredential:{_ in XCTFail("Invalid grants must not reach credentials");return nil})}
                    }
                    coordinator.enrollments[e.installation] = e
                    rejects("CONNECTION_REPAIR_REQUIRED") {try self.coordinator.bootstrapVerifiedWorkspace([:],native:native,readCredential:{_ in "wrong-credential"})}
                    let denied = Caller(role:"worker",installation:"foreign",projectIDs:[],sessionID:sid,workspace:root.path)
                    XCTAssertThrowsError(try coordinator.router.handle(method:"history_list",params:["project_id":project!,"entity":"project"],caller:denied)) {
                        XCTAssertEqual(($0 as? CoreError)?.code,"FORBIDDEN")
                    }
                    let foreign = Coordinator.VerifiedNativeWorkspace(provider:"codex",session:UUID().uuidString,process:getpid(),executionDomain:domain,workspace:root.path)
                    rejects("PROJECT_ARCHIVED") {try self.coordinator.bootstrapVerifiedWorkspace([:],native:foreign,readCredential:{_ in XCTFail("No new grant or keychain read");return nil})}
                }
            }
        }
    }

}
