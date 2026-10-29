import XCTest
import Security
@testable import ChecklistIPC

final class ClientConnectionAdmissionTests: XCTestCase {
    private final class Listener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
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

    /// Fake signature reader and kernel key: counts full checks and can hold one open.
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var key: ClientExecutableKey?
        private var reads = 0
        var identity: ClientBuildIdentity?
        var slowRead: Int?
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        init(_ identity: ClientBuildIdentity?) { self.identity = identity }
        var current: ClientExecutableKey? {
            get { lock.lock(); defer { lock.unlock() }; return key }
            set { lock.lock(); key = newValue; lock.unlock() }
        }
        var signatureReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
        func read(_ connection: NSXPCConnection) -> ClientBuildIdentity? {
            lock.lock(); reads += 1; let number = reads; lock.unlock()
            if number == slowRead { entered.signal(); release.wait() }
            return identity
        }
        func admission(current: [ClientBuildIdentity], identifiers: Set<String> = []) -> ClientConnectionAdmission {
            .init(currentClients: current, checklistIdentifiers: identifiers, identitySource: read, keySource: { _ in self.current })
        }
    }

    private func key(inode: UInt64 = 7, modified: Int = 1, size: Int64 = 100, cdhash: UInt8 = 1, path: String = "/Applications/Checklist.app/Contents/MacOS/checklist") -> ClientExecutableKey {
        .init(path: path, device: 1, inode: inode, modified: [modified, 0, modified, 0], size: size, kernelCDHash: Data(repeating: cdhash, count: 20))
    }

    func testRepeatClientIsAdmittedFromCacheWithoutSignatureRead() throws {
        let probe = Probe(try ownIdentity()); probe.current = key()
        let server = Listener(probe.admission(current: [try ownIdentity()])); defer { server.stop() }
        for _ in 0..<3 {
            XCTAssertEqual((try server.send("service_info")["data"] as? [String: Any])?["received"] as? Bool, true)
        }
        XCTAssertEqual(probe.signatureReads, 1, "Only the first client of an unchanged executable reads its signature.")
        XCTAssertEqual(server.counts.factories, 3)
        XCTAssertEqual(server.counts.dispatched, 3)
    }

    func testChangedExecutableIsVerifiedAgain() throws {
        let probe = Probe(try ownIdentity())
        let server = Listener(probe.admission(current: [try ownIdentity()])); defer { server.stop() }
        let changes = [key(), key(inode: 8), key(modified: 2), key(size: 101), key(cdhash: 2), key(path: "/tmp/moved/checklist"), key()]
        for (index, changed) in changes.enumerated() {
            probe.current = changed
            _ = try server.send("service_info")
            XCTAssertEqual(probe.signatureReads, min(index + 1, 6), "change \(index)")
        }
        XCTAssertEqual(server.counts.dispatched, changes.count)
    }

    func testForeignAndUnsignedClientsStayRefusedOnRepeat() throws {
        let own = try ownIdentity()
        let foreign = Probe(ClientBuildIdentity(identifier: "unknown.signer", cdhash: Data(repeating: 0x39, count: own.cdhash.count)))
        foreign.current = key()
        let refused = Listener(foreign.admission(current: [own], identifiers: ["org.checklist.checklist"])); defer { refused.stop() }
        for _ in 0..<2 { XCTAssertThrowsError(try refused.send("service_info")) }
        XCTAssertEqual(foreign.signatureReads, 1, "A cached foreign identity is still classified and refused.")
        XCTAssertEqual(refused.counts.factories, 0)
        XCTAssertEqual(refused.counts.dispatched, 0)

        let unsigned = Probe(nil); unsigned.current = key()
        let server = Listener(unsigned.admission(current: [own])); defer { server.stop() }
        for _ in 0..<2 { XCTAssertThrowsError(try server.send("service_info")) }
        XCTAssertEqual(unsigned.signatureReads, 2, "A failed read is never cached.")
        XCTAssertEqual(server.counts.factories, 0)
    }

    func testSlowFirstCheckDoesNotHoldUpCachedClients() throws {
        let own = try ownIdentity()
        let probe = Probe(own); probe.slowRead = 2
        let server = Listener(probe.admission(current: [own])); defer { server.stop() }
        probe.current = key(inode: 1)
        _ = try server.send("service_info")
        probe.current = key(inode: 2)
        let slow = DispatchSemaphore(value: 0)
        let slowResult = UncheckedBox()
        DispatchQueue.global().async { slowResult.value = try? server.send("service_info"); slow.signal() }
        XCTAssertEqual(probe.entered.wait(timeout: .now() + 3), .success)
        probe.current = key(inode: 1)
        let started = Date()
        let cached = try server.send("service_info")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "A cached client must not wait for another executable's first check.")
        XCTAssertEqual((cached["data"] as? [String: Any])?["received"] as? Bool, true)
        XCTAssertEqual(slow.wait(timeout: .now()), .timedOut, "The slow first check is still open.")
        probe.release.signal()
        XCTAssertEqual(slow.wait(timeout: .now() + 3), .success)
        XCTAssertEqual((slowResult.value?["data"] as? [String: Any])?["received"] as? Bool, true)
        XCTAssertEqual(probe.signatureReads, 2)
    }

    private final class UncheckedBox: @unchecked Sendable { var value: [String: Any]? }

    func testProcessKeyReadsKernelFactsForRunningClient() throws {
        let first = try XCTUnwrap(ClientExecutableKey.process(getpid()))
        XCTAssertEqual(first, ClientExecutableKey.process(getpid()))
        XCTAssertEqual(first.kernelCDHash?.count, 20)
        XCTAssertFalse(first.path.isEmpty)
        XCTAssertNil(ClientExecutableKey.process(-1))
    }
}
