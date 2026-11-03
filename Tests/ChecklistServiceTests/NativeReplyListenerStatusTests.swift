import XCTest
import Darwin
@testable import ChecklistCore
import ChecklistBridges
@testable import ChecklistService

/// The real router and store. The reply folder is temporary, so nothing reaches /tmp/cc-socks.
final class NativeReplyListenerStatusTests: XCTestCase {
    private var root: URL!
    private var replies: String!
    private var coordinator: Coordinator!
    private let owner = Caller(role:"owner",installation:"listener-test-owner",projectIDs:[])

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        replies = "/tmp/cl415s-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(atPath:replies,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        coordinator = Coordinator(router:try CommandRouter(root:root.appendingPathComponent("store")),enrollmentFile:root.appendingPathComponent("connections.json"),startBackgroundWork:false)
    }
    override func tearDownWithError() throws {
        coordinator.queue.sync {}
        coordinator.queue.sync { coordinator.nativeListener?.removeSocketFile();coordinator.nativeListener = nil }
        try FileManager.default.removeItem(at:root)
        try FileManager.default.removeItem(atPath:replies)
    }
    private func listener() throws -> [String:Any] {
        let result = try coordinator.router.handle(method:"service_info",params:[:],caller:owner)
        let data = result["data"] as? [String:Any] ?? result
        return try XCTUnwrap(data["native_reply_listener"] as? [String:Any])
    }

    func testServiceInfoReportsAFailedListenerInPlainWords() throws {
        XCTAssertEqual(try listener()["state"] as? String,"not_started")
        let path = replies + "/\(getpid()).sock"
        try Data("keep".utf8).write(to:URL(fileURLWithPath:path))
        coordinator.startNativeReplies(directory:replies)
        XCTAssertNil(coordinator.queue.sync { coordinator.nativeListener })
        let info = try listener()
        XCTAssertEqual(info["state"] as? String,"failed")
        XCTAssertEqual(info["claude_relay"] as? String,"stopped")
        XCTAssertEqual(info["codex_queue_relay"] as? String,CodexQueueRelay.enabled ? "running" : "off")
        XCTAssertEqual(info["reason"] as? String,"Refusing to replace an existing reply path: it is not a socket.")
        let message = try XCTUnwrap(info["message"] as? String)
        XCTAssertTrue(message.contains("does not relay notes to Claude"),message)
        XCTAssertTrue(message.contains("it is not a socket"),message)
        XCTAssertTrue(message.contains("Codex queue route does not use this listener and still runs"),message)
        try FileManager.default.removeItem(atPath:path)
    }

    func testAStaleSocketDoesNotStopTheListener() throws {
        let path = replies + "/\(getpid()).sock"
        let descriptor = socket(AF_UNIX,SOCK_STREAM,0)
        var address = sockaddr_un();address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of:&address.sun_path) { $0.copyBytes(from:path.utf8) }
        let bound = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(descriptor,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(bound,0);XCTAssertEqual(chmod(path,0o600),0);close(descriptor)
        coordinator.startNativeReplies(directory:replies)
        XCTAssertNotNil(coordinator.queue.sync { coordinator.nativeListener })
        let info = try listener()
        XCTAssertEqual(info["state"] as? String,"listening")
        XCTAssertEqual(info["claude_relay"] as? String,"running")
        XCTAssertNil(info["reason"])
    }

    func testAPagePassesTheListenerStateToTheApp() throws {
        coordinator.router.nativeReplyListenerStatus = .init(state:.failed,reason:"Synthetic.",codexQueueRelayEnabled:true)
        let project = try coordinator.router.handle(method:"project_create",params:["name":"Listener fixture","key_prefix":"LF","root_path":root.path,"command_id":UUID().uuidString],caller:owner)
        let id = try XCTUnwrap(((project["data"] as? [String:Any]) ?? project)["id"] as? String)
        let page = try coordinator.router.handle(method:"workspace_page",params:["project_id":id,"surface":"epics"],caller:owner)
        let body = page["data"] as? [String:Any] ?? page
        let service = try XCTUnwrap(body["service"] as? [String:Any])
        XCTAssertEqual((service["native_reply_listener"] as? [String:Any])?["state"] as? String,"failed")
    }
}
