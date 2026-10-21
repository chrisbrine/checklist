import XCTest
import Darwin
@testable import ChecklistBridges

final class ClaudeLocalBridgeTests: XCTestCase {
    func testCanonicalPermissionEnvelope() throws {
        for mode in [ClaudePermissionClass.bypass, .prompting] {
            let bytes = try ClaudeLocalBridge.envelope(content: "Test only", messageID: "message-1", sender: .init(replyAddress: "uds:/tmp/reply.sock", displayName: "Checklist test", permissionClass: mode))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let body = try XCTUnwrap(object["message"] as? [String: Any])
            XCTAssertTrue((body["content"] as? String)?.contains("from-mode=\"\(mode.rawValue)\"") == true)
            XCTAssertEqual(object["from"] as? String, "uds:/tmp/reply.sock")
            XCTAssertNil(object["token"])
        }
    }

    func testInvalidEnvelopeAndOversizeRejected() {
        XCTAssertThrowsError(try ClaudeLocalBridge.envelope(content: "x", messageID: "invalid\"id", sender: .init(replyAddress: "uds:/tmp/reply.sock", displayName: "Checklist", permissionClass: .prompting)))
        XCTAssertThrowsError(try ClaudeLocalBridge.envelope(content: "x", messageID: "id", sender: .init(replyAddress: "uds:/tmp/reply.sock", displayName: "\u{0}\u{202E}", permissionClass: .prompting)))
        XCTAssertThrowsError(try ClaudeLocalBridge.envelope(content: String(repeating: "a", count: ClaudeLocalBridge.maximumFrameBytes), messageID: "id", sender: .init(replyAddress: "uds:/tmp/reply.sock", displayName: "Checklist test", permissionClass: .prompting)))
    }

    func testSyntheticSameUserRoundTripIsTransportOnly() throws {
        let directory = "/tmp/checklist-bridge-test-\(UUID().uuidString.lowercased())"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let listener = try NativeReplyListener(path: directory + "/inbox.sock")
        let receipt = try ClaudeLocalBridge.send(content: "synthetic", messageID: "transport-only", sender: .init(replyAddress: listener.address, displayName: "Synthetic peer", permissionClass: .prompting), endpoint: listener.path)
        XCTAssertEqual(receipt.status, "transport_written")
        XCTAssertEqual(receipt.peerPID, getpid())
        let received = try listener.receiveFrame()
        XCTAssertEqual(received.peerPID, 0, "A disconnected sender has no surviving Darwin peer PID; do not manufacture one.")
        XCTAssertEqual(received.peerUID, getuid())
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: received.data) as? [String: Any])
        XCTAssertEqual(frame["msg_id"] as? String, "transport-only")
    }

    func testLiveReplyCapturesKernelPID() throws {
        let directory = "/tmp/checklist-bridge-test-\(UUID().uuidString.lowercased())"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let listener = try NativeReplyListener(path: directory + "/inbox.sock")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(listener.path.utf8) + [0]) }
        let connected = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(connected, 0)
        let data = Data("{\"type\":\"user\",\"message\":{\"content\":\"synthetic\"}}\n".utf8)
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        XCTAssertEqual(count, data.count)
        let received = try listener.receiveFrame()
        XCTAssertEqual(received.peerPID, getpid())
        XCTAssertEqual(received.peerUID, getuid())
    }

    func testPeerMessageStatusParsesRecordedHoldShapeOnly() throws {
        // Field shape of Claude 2.1.299's hold notice, as recorded on 17 October 2026; identifiers replaced.
        let held: [String: Any] = ["type": "control", "action": "peer_message_status", "status": "held", "msgV": 1,
                                   "orig_msg_id": "00000000-0000-4000-8000-00000000000a",
                                   "msg_id": "00000000-0000-4000-8000-000000000001", "from": "uds:/tmp/cc-socks/1.sock",
                                   "reason": "Your message is held for the recipient user's approval before it reaches their Claude session (permission-mode parity)."]
        let status = try XCTUnwrap(ClaudePeerMessageStatus.parse(held))
        XCTAssertEqual(status.deliveryState, "held")
        XCTAssertEqual(status.originalMessageID, "00000000-0000-4000-8000-00000000000a")
        XCTAssertEqual(status.noticeID, "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(status.protocolVersion, 1)
        XCTAssertTrue(status.reason?.contains("permission-mode parity") == true)
        var longReason = held; longReason["reason"] = String(repeating: "r", count: 5000)
        XCTAssertEqual(ClaudePeerMessageStatus.parse(longReason)?.reason?.count, 300)
        // A reply, an unknown status word or another control action never becomes a delivery state.
        XCTAssertNil(ClaudePeerMessageStatus.parse(["type": "user", "message": ["content": "status held"]]))
        var unknown = held; unknown["status"] = "delivered"
        XCTAssertNil(ClaudePeerMessageStatus.parse(unknown))
        var otherAction = held; otherAction["action"] = "idle_notice"
        XCTAssertNil(ClaudePeerMessageStatus.parse(otherAction))
    }

    func testHostStatusCorrelatesOnlyExactEchoFromRecipientProcess() throws {
        let base: [String: Any] = ["type": "control", "action": "peer_message_status", "status": "held", "msg_id": "notice-own-id"]
        var lateA = base; lateA["orig_msg_id"] = "message-A"
        let notice = try XCTUnwrap(ClaudePeerMessageStatus.parse(lateA))
        XCTAssertTrue(notice.refers(to: "message-A", recipientPID: 80, notifierPID: 80))
        // A late notice for A never marks a newer write B to the same recipient process.
        XCTAssertFalse(notice.refers(to: "message-B", recipientPID: 80, notifierPID: 80))
        // The notice's own msg_id is not the sender's message.
        XCTAssertFalse(notice.refers(to: "notice-own-id", recipientPID: 80, notifierPID: 80))
        // Another process, or a sender closed before Darwin reported its PID, cannot claim it.
        XCTAssertFalse(notice.refers(to: "message-A", recipientPID: 80, notifierPID: 81))
        XCTAssertFalse(notice.refers(to: "message-A", recipientPID: 80, notifierPID: 0))
        // Without an echoed ID there is no fallback match.
        let unechoed = try XCTUnwrap(ClaudePeerMessageStatus.parse(base))
        XCTAssertFalse(unechoed.refers(to: "message-A", recipientPID: 80, notifierPID: 80))
    }

    func testReplyRoutingSelectsRecipientByKernelPeerOnly() {
        XCTAssertEqual(NativeReplyRouting.endpointPID("/tmp/cc-socks/80240.sock"), 80240)
        XCTAssertNil(NativeReplyRouting.endpointPID("/tmp/cc-socks/inbox.sock"))
        XCTAssertNil(NativeReplyRouting.endpointPID("/tmp/cc-socks/0.sock"))
        // The coordinator's delivery comes first, but the reply peer is the handler's process.
        let routes = [(sessionID: "coordinator", endpoint: "/tmp/cc-socks/111.sock"), (sessionID: "handler", endpoint: "/tmp/cc-socks/222.sock"),
                      (sessionID: "handler", endpoint: "/tmp/cc-socks/222.sock")]
        XCTAssertEqual(NativeReplyRouting.recipient(peerPID: 222, routes: routes), "handler")
        XCTAssertEqual(NativeReplyRouting.recipient(peerPID: 111, routes: routes), "coordinator")
        // No kernel PID, an unknown peer, or two sessions behind one process never select a recipient.
        XCTAssertNil(NativeReplyRouting.recipient(peerPID: 0, routes: routes))
        XCTAssertNil(NativeReplyRouting.recipient(peerPID: 333, routes: routes))
        XCTAssertNil(NativeReplyRouting.recipient(peerPID: 222, routes: routes + [(sessionID: "other", endpoint: "/tmp/cc-socks/222.sock")]))
    }

    func testReplyTextExcludesClaudeEnvelope() throws {
        // Content shape of the actual 2.1.299 SendMessage reply observed on 18 October 2026.
        let content = "<cross-session-message from=\"uds:/tmp/cc-socks/1.sock\" from-session=\"local_x\" from-name=\"CL-5\" from-mode=\"bypass\">\n"
            + "CHECKLIST_REPLY 5ba99b10-f835-4756-8575-623821763df4: Received test C.\n</cross-session-message>"
        let reply = try XCTUnwrap(NativeReplyRouting.reply(in: content))
        XCTAssertEqual(reply.messageID, "5ba99b10-f835-4756-8575-623821763df4")
        XCTAssertEqual(reply.body, "Received test C.")
        // Text inside the reply that mentions the tag stays; only the envelope's closing tag goes.
        let quoted = content.replacingOccurrences(of: "Received test C.", with: "Quote: </cross-session-message> end.")
        XCTAssertEqual(NativeReplyRouting.reply(in: quoted)?.body, "Quote: </cross-session-message> end.")
        XCTAssertNil(NativeReplyRouting.reply(in: "CHECKLIST_REPLY 5ba99b10-f835-4756-8575-623821763df4:\n</cross-session-message>"))
        XCTAssertNil(NativeReplyRouting.reply(in: "No marker here"))
    }

    func testSymlinkAndPublicSocketRejected() throws {
        let directory = "/tmp/checklist-bridge-test-\(UUID().uuidString.lowercased())"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let listener = try NativeReplyListener(path: directory + "/inbox.sock")
        let link = directory + "/alias.sock"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: listener.path)
        let sender = ClaudePeerSender(replyAddress: listener.address, displayName: "Test", permissionClass: .prompting)
        XCTAssertThrowsError(try ClaudeLocalBridge.send(content: "test", messageID: "id", sender: sender, endpoint: link))
        XCTAssertEqual(chmod(listener.path, 0o666), 0)
        XCTAssertThrowsError(try ClaudeLocalBridge.send(content: "test", messageID: "id", sender: sender, endpoint: listener.path))
    }
}
