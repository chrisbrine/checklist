import XCTest
import Security
@testable import ChecklistIPC

final class ClientConnectionAdmissionTests: XCTestCase {
    private final class Listener: NSObject, NSXPCListenerDelegate {
        let listener = NSXPCListener.anonymous()
        let admission: ClientConnectionAdmission
        private let lock = NSLock()
        private var connections: [NSXPCConnection] = []
        private var factories = 0
        private var dispatched = 0
        var counts: (factories: Int, dispatched: Int) {
            lock.lock(); defer { lock.unlock() }; return (factories, dispatched)
        }

        init(_ admission: ClientConnectionAdmission) {
            self.admission = admission
            super.init(); listener.delegate = self; listener.resume()
        }
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            let accepted = admission.accept(connection) {
                self.lock.lock(); self.factories += 1; self.lock.unlock()
                return Spy { self.lock.lock(); self.dispatched += 1; self.lock.unlock() }
            }
            if accepted { lock.lock(); connections.append(connection); lock.unlock() }
            return accepted
        }
        func stop() {
            listener.invalidate()
            lock.lock(); let active = connections; connections.removeAll(); lock.unlock()
            active.forEach { $0.invalidate() }
        }
        func send(_ method: String, commandID: String? = nil) throws -> [String: Any] {
            var params: [String: Any] = [:]
            if let commandID { params["command_id"] = commandID }
            let bytes = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
            return try ChecklistClient(usesStoredCredential: false).requestOnce(bytes, replyTimeout: 3,
                connection: NSXPCConnection(listenerEndpoint: listener.endpoint))
        }
    }

    private final class Spy: NSObject, ChecklistRPC {
        let received: () -> Void
        init(_ received: @escaping () -> Void) { self.received = received }
        func execute(_ request: Data, withReply reply: @escaping (Data) -> Void) {
            received()
            let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any]
            var result: [String: Any] = ["data": ["id": "spy-result", "received": true]]
            if let id = (object?["params"] as? [String: Any])?["command_id"] { result["command_id"] = id }
            reply(try! JSONSerialization.data(withJSONObject: result))
        }
    }

    private func ownIdentity() throws -> ClientBuildIdentity {
        var code: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
        return try XCTUnwrap(ClientBuildIdentity.running(XCTUnwrap(code)))
    }

    func testOutdatedReadAndMutationReachRealClientWithoutUnknownOrDispatch() throws {
        let own = try ownIdentity()
        let old = ClientBuildIdentity(identifier: "org.checklist.checklist", cdhash: Data(repeating: 0x19, count: own.cdhash.count))
        let server = Listener(.init(currentClients: [own], checklistIdentifiers: [old.identifier], identitySource: { _ in old }))
        defer { server.stop() }
        let id = UUID().uuidString
        for (method, commandID) in [("service_info", nil), ("task_edit", id)] as [(String, String?)] {
            XCTAssertThrowsError(try server.send(method, commandID: commandID)) { failure in
                let error = failure as? ChecklistError
                XCTAssertEqual(error?.code, "CLIENT_OUTDATED")
                XCTAssertEqual(error?.details["command_id"] as? String, commandID)
                XCTAssertEqual(error?.details["command_outcome"] as? String, "rejected")
                XCTAssertEqual(error?.details["command_executed"] as? Bool, false)
            }
        }
        XCTAssertEqual(server.counts.factories, 0)
        XCTAssertEqual(server.counts.dispatched, 0)
    }

    func testCurrentProcessHashSetsExactRequirementAndDispatches() throws {
        let own = try ownIdentity()
        let admission = ClientConnectionAdmission(currentClients: [own], checklistIdentifiers: [])
        XCTAssertEqual(admission.requirement, "cdhash H\"" + own.cdhash.map { String(format: "%02x", $0) }.joined() + "\"")
        let server = Listener(admission); defer { server.stop() }
        let result = try server.send("service_info")
        XCTAssertEqual((result["data"] as? [String: Any])?["received"] as? Bool, true)
        XCTAssertEqual(server.counts.factories, 1)
        XCTAssertEqual(server.counts.dispatched, 1)
    }

    func testCurrentBranchStillRejectsMessageWhoseActualHashDiffers() throws {
        let own = try ownIdentity()
        let different = ClientBuildIdentity(identifier: own.identifier, cdhash: Data(repeating: 0x29, count: own.cdhash.count))
        let server = Listener(.init(currentClients: [different], checklistIdentifiers: [], identitySource: { _ in different }))
        defer { server.stop() }
        XCTAssertThrowsError(try server.send("service_info"))
        XCTAssertEqual(server.counts.factories, 1)
        XCTAssertEqual(server.counts.dispatched, 0, "The normal branch must set the per-message requirement.")
    }

    func testUnknownSignerIsRefusedWithoutConstructingOrDispatchingPeer() throws {
        let own = try ownIdentity()
        let unknown = ClientBuildIdentity(identifier: "unknown.signer", cdhash: Data(repeating: 0x39, count: own.cdhash.count))
        let server = Listener(.init(currentClients: [own], checklistIdentifiers: ["org.checklist.checklist"], identitySource: { _ in unknown }))
        defer { server.stop() }
        XCTAssertThrowsError(try server.send("service_info"))
        XCTAssertEqual(server.counts.factories, 0)
        XCTAssertEqual(server.counts.dispatched, 0)
    }
}
