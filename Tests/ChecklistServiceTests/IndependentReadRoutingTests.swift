import Foundation
import GRDB
import XCTest
import ChecklistIPC
@testable import ChecklistCore
@testable import ChecklistService

final class IndependentReadRoutingTests: XCTestCase {
    private let owner = Caller(role:"owner",installation:"read-fixture-owner",projectIDs:[])
    private let credential = "saved-read-fixture"
    private let installation = "read-fixture"

    private func setup(_ router: CommandRouter, root: URL) throws -> Enrollment {
        let project = try XCTUnwrap((router.handle(method:"project_create",params:[
            "command_id":uuid(),"name":"Independent reads fixture","root_path":root.path
        ],caller:owner)["data"] as? JSON)?["id"] as? String)
        let enrollment = Enrollment(installation:installation,name:"Original",provider:"codex",role:"worker",
            projectIDs:[project],sessionID:uuid(),workspace:root.path,profileID:nil,
            tokenDigest:ChecklistCore.hash(Data(credential.utf8)),generation:uuid())
        var registration = registration(enrollment)
        registration["command_id"] = uuid()
        _ = try router.handle(method:"session_register",params:registration,caller:owner)
        return enrollment
    }

    private func registration(_ enrollment: Enrollment) -> JSON {
        ["project_id":enrollment.projectIDs[0],"project_ids":enrollment.projectIDs,"session_id":enrollment.sessionID,
         "installation":enrollment.installation+"/"+enrollment.generation,"provider":enrollment.provider,
         "role":enrollment.role,"workspace":enrollment.workspace!]
    }

    private func request(_ method: String,_ enrollment: Enrollment,credential: String? = nil,params: JSON = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject:["method":method,"installation":enrollment.installation,
            "credential":credential ?? self.credential,"workspace":enrollment.workspace!,"params":params])
    }

    @discardableResult
    private func request(_ bytes: Data, through peer: Peer, _ assertReply: @escaping (JSON) -> Void) -> XCTestExpectation {
        let response = expectation(description:"Independent peer reply")
        peer.execute(bytes) { bytes in
            assertReply((try? JSONSerialization.jsonObject(with:bytes)) as? JSON ?? [:])
            response.fulfill()
        }
        return response
    }

    private func fixture(_ body: (URL, URL, CommandRouter, Enrollment) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(uuid())
        let path = root.appendingPathComponent("connections.json")
        let router = try CommandRouter(root:root)
        defer {try? router.closeStore();try? FileManager.default.removeItem(at:root)}
        try body(root,path,router,setup(router,root:root))
    }

    func testPersistedEnrollmentAuthenticatesReadsWhileQueueWriterAndGateAreHeld() throws {
        try fixture {root,path,router,enrollment in
            let original = Coordinator(router:router,enrollmentFile:path,startBackgroundWork:false)
            original.enrollments[installation] = enrollment
            try original.saveEnrollments()
            let restarted = Coordinator(router:router,enrollmentFile:path,startBackgroundWork:false)
            let connection = NSXPCConnection(machServiceName:"org.checklist.synthetic.unconnected")
            defer {connection.invalidate()}
            let peer = Peer(coordinator:restarted,connection:connection)

            let enteredQueue = DispatchSemaphore(value:0), enteredWriter = DispatchSemaphore(value:0)
            let releaseQueue = DispatchSemaphore(value:0), releaseWriter = DispatchSemaphore(value:0)
            let storage = DispatchQueue(label:"test.read-held-storage")
            restarted.queue.async {
                enteredQueue.signal()
                _ = releaseQueue.wait(timeout:.now() + .seconds(15))
            }
            storage.async {
                do {
                    try ArchiveStorageGate.withExclusive(root:root) { _ in
                        try router.dbQueue.writeWithoutTransaction { db in
                            try db.inTransaction(.immediate) {
                                enteredWriter.signal()
                                _ = releaseWriter.wait(timeout:.now() + .seconds(15))
                                return .rollback
                            }
                        }
                    }
                } catch {XCTFail("Could not reserve the writer: \(error)")}
            }
            defer {releaseWriter.signal();releaseQueue.signal();storage.sync {};restarted.queue.sync {}}
            guard enteredQueue.wait(timeout:.now()+5) == .success,
                  enteredWriter.wait(timeout:.now()+5) == .success else {return XCTFail("Resources were not held")}

            let scoped = try request(request("project_settings_get",enrollment,
                params:["project_id":enrollment.projectIDs[0]]),through:peer) {
                XCTAssertNotNil($0["data"],"Persisted enrollment refused: \($0)")
            }
            let status = try request(request("service_info",enrollment),through:peer) {
                XCTAssertEqual(($0["data"] as? JSON)?["session_id"] as? String,enrollment.sessionID)
            }
            let changes = try request(request("changes_wait",enrollment),through:peer) {
                XCTAssertEqual(($0["error"] as? JSON)?["code"] as? String,"FORBIDDEN","Unexpected worker change reply: \($0)")
            }
            let ownerChanges = try router.handleIndependentRead(method:"changes_wait",params:[:],caller:owner)
            XCTAssertEqual((ownerChanges["data"] as? JSON)?["changed"] as? Bool,true)
            wait(for:[scoped,status,changes],timeout:5)
        }
    }

    func testSameKeyReplacementKeepsCommittedReadAuthorityThroughRollbackAndCommit() throws {
        enum FixtureFailure: Error {case rollback}
        try fixture {_,path,router,original in
            let coordinator = Coordinator(router:router,enrollmentFile:path,startBackgroundWork:false)
            coordinator.enrollments[installation] = original
            let connection = NSXPCConnection(machServiceName:"org.checklist.synthetic.unconnected")
            defer {connection.invalidate()}
            let peer = Peer(coordinator:coordinator,connection:connection)
            let oldStatus = try request("service_info",original)
            let replacementCredential = "replacement-read-fixture"

            for shouldCommit in [false,true] {
                let staged = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
                let committed = DispatchSemaphore(value:0), publish = DispatchSemaphore(value:0)
                defer {release.signal();publish.signal();coordinator.queue.sync {}}
                let finished = expectation(description:"Registration settles")
                let command = uuid()
                let installation = original.installation
                let replacementGeneration = uuid()
                var next = original
                next.generation = replacementGeneration
                next.name = "Replacement"
                next.tokenDigest = ChecklistCore.hash(Data(replacementCredential.utf8))
                let replacement = next
                let owner = self.owner
                let registration = registration(replacement)
                let registrationBytes = try JSONSerialization.data(withJSONObject:registration)
                coordinator.queue.async {
                    coordinator.beginStagingEnrollment(installation)
                    defer {coordinator.finishStagingEnrollment(installation);finished.fulfill()}
                    do {
                        _ = try router.commitConnectionRegistration(intent:["command_id":command],caller:owner,preparePersistence:{ intent in
                            var prepared = replacement
                            prepared.pairingCommandID = intent.commandID
                            prepared.pairingIntentDigest = intent.digest
                            prepared.pairingPrincipal = owner.principal
                            coordinator.enrollments[installation] = prepared
                            staged.signal()
                            guard release.wait(timeout:.now()+10) == .success, shouldCommit else {throw FixtureFailure.rollback}
                            let registration = try XCTUnwrap(JSONSerialization.jsonObject(with:registrationBytes) as? JSON)
                            return ConnectionRegistrationPreparation(sessionParameters:registration,installation:installation,mcpExecutable:"/fixture/checklist")
                        },rollback:{
                            coordinator.enrollments[installation] = original
                        })
                        XCTAssertTrue(shouldCommit)
                        committed.signal()
                        _ = publish.wait(timeout:.now()+10)
                    } catch FixtureFailure.rollback {XCTAssertFalse(shouldCommit)}
                    catch {XCTFail("Unexpected registration failure: \(error)")}
                }
                guard staged.wait(timeout:.now()+5) == .success else {
                    release.signal();wait(for:[finished],timeout:5);return XCTFail("Replacement was not staged")
                }
                let incumbent = request(oldStatus,through:peer) {
                    XCTAssertEqual(($0["data"] as? JSON)?["session_id"] as? String,original.sessionID)
                }
                let uncommitted = try request(request("project_settings_get",replacement,credential:replacementCredential,
                    params:["project_id":replacement.projectIDs[0]]),through:peer) {
                    XCTAssertEqual(($0["error"] as? JSON)?["code"] as? String,"SETUP_REQUIRED")
                }
                let listing = try XCTUnwrap(coordinator.connectionList(owner,readsOnly:true)["data"] as? JSON)
                XCTAssertEqual((listing["connections"] as? [JSON])?.map {$0["generation"] as? String},[original.generation])
                wait(for:[incumbent,uncommitted],timeout:5)
                release.signal()
                if shouldCommit {
                    guard committed.wait(timeout:.now()+5) == .success else {return XCTFail("Replacement did not commit")}
                    let committedBeforePublication = try request(request("project_settings_get",replacement,credential:replacementCredential,
                        params:["project_id":replacement.projectIDs[0]]),through:peer) {
                        XCTAssertNotNil($0["data"],"Committed replacement refused before publisher returned: \($0)")
                    }
                    let listing = try XCTUnwrap(coordinator.connectionList(owner,readsOnly:true)["data"] as? JSON)
                    XCTAssertEqual((listing["connections"] as? [JSON])?.map {$0["generation"] as? String},[replacement.generation])
                    wait(for:[committedBeforePublication],timeout:5)
                    publish.signal()
                }
                wait(for:[finished],timeout:5)

                let current = shouldCommit ? replacement : original
                let token = shouldCommit ? replacementCredential : credential
                let settled = try request(request("project_settings_get",current,credential:token,
                    params:["project_id":current.projectIDs[0]]),through:peer) {
                    XCTAssertNotNil($0["data"],"Current enrollment refused: \($0)")
                }
                wait(for:[settled],timeout:5)
                let settledListing = try XCTUnwrap(coordinator.connectionList(owner,readsOnly:true)["data"] as? JSON)
                XCTAssertEqual((settledListing["connections"] as? [JSON])?.map {$0["generation"] as? String},[current.generation])
            }
        }
    }

    func testMissingReadPoolKeepsUnboundStatusAndReopensForScopedReads() throws {
        CommandRouter.disableReaderPoolForTesting = true
        defer {CommandRouter.disableReaderPoolForTesting = false}
        try fixture {_,path,router,enrollment in
            let coordinator = Coordinator(router:router,enrollmentFile:path,startBackgroundWork:false)
            coordinator.enrollments[installation] = enrollment
            let connection = NSXPCConnection(machServiceName:"org.checklist.synthetic.unconnected")
            defer {connection.invalidate()}
            let peer = Peer(coordinator:coordinator,connection:connection)
            let unbound = request(Data(#"{"method":"service_info","params":{}}"#.utf8),through:peer) {
                XCTAssertEqual(($0["data"] as? JSON)?["read_state"] as? String,"reader_opening")
            }
            let scopedBytes = try request("project_settings_get",enrollment,params:["project_id":enrollment.projectIDs[0]])
            let unavailable = request(scopedBytes,through:peer) {
                XCTAssertEqual(($0["error"] as? JSON)?["code"] as? String,"READ_LANE_UNAVAILABLE")
            }
            wait(for:[unbound,unavailable],timeout:5)

            CommandRouter.disableReaderPoolForTesting = false
            router.readerPool.retryOpen()
            let opened = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in router.readers != nil },object:nil)
            wait(for:[opened],timeout:5)
            let recovered = request(scopedBytes,through:peer) {XCTAssertNotNil($0["data"],String(describing:$0))}
            wait(for:[recovered],timeout:5)
        }
    }

    func testReadLaneAndSerialRouteApplyTheSameAuthorizationChecks() throws {
        try fixture {_,path,router,enrollment in
            let coordinator = Coordinator(router:router,enrollmentFile:path,startBackgroundWork:false)
            coordinator.enrollments[installation] = enrollment
            let connection = NSXPCConnection(machServiceName:"org.checklist.synthetic.unconnected")
            defer {connection.invalidate()}
            let project = enrollment.projectIDs[0]
            let cases = [credential,"unknown"].flatMap { token in
                [enrollment.workspace!,"/different-fixture"].flatMap { workspace in
                    [project,uuid()].map { scope in (token,workspace,scope) }
                }
            }
            for method in ["project_settings_get","service_info","changes_wait"] {
                for (token,workspace,scope) in cases {
                    let parameters: JSON = method == "changes_wait" ? [:] : ["project_id":scope]
                    let object: JSON = ["method":method,"installation":installation,"workspace":workspace,
                                        "credential":token,"params":parameters]
                    func projection(_ body: () throws -> JSON) -> NSDictionary {
                        do {return try (body()["data"] as? NSDictionary) ?? [:]}
                        catch {return ["error_code":Peer.publicError(error)["code"] as? String ?? ""] as NSDictionary}
                    }
                    let legacy = projection {try coordinator.execute(object,connection:connection)}
                    let current = projection {try coordinator.readRequest(object,method:method,peerPID:connection.processIdentifier,timing:nil)}
                    if method == "changes_wait", let legacyChanged = legacy["changed"] as? Bool {
                        // Successful change replies seal a fresh nonce each time.
                        XCTAssertEqual(current["changed"] as? Bool,legacyChanged)
                    } else {XCTAssertEqual(current,legacy,"\(method), \(token), \(workspace), \(scope)")}
                }
            }
        }
    }
}
