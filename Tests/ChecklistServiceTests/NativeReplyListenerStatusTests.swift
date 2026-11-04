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
        replies = root.appendingPathComponent("replies").path
        try FileManager.default.createDirectory(atPath:replies,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        coordinator = Coordinator(router:try CommandRouter(root:root.appendingPathComponent("store")),enrollmentFile:root.appendingPathComponent("connections.json"),startBackgroundWork:false)
    }
    override func tearDownWithError() throws {
        coordinator.queue.sync {}
        coordinator.queue.sync { coordinator.nativeListener?.releaseSocketFile();coordinator.nativeListener = nil }
        try FileManager.default.removeItem(at:root)
    }
    private func listener() throws -> [String:Any] {
        let result = try coordinator.router.handle(method:"service_info",params:[:],caller:owner)
        let data = result["data"] as? [String:Any] ?? result
        return try XCTUnwrap(data["native_reply_listener"] as? [String:Any])
    }

    private func requireSocketAddressSpace() throws {
        // Respect a caller-selected TMPDIR. A long restricted workspace cannot
        // provide the absolute <=103-byte sender address this transport needs.
        try XCTSkipIf((replies + "/\(getpid())-ffffffff.sock").utf8.count >= 104,
                      "The selected temporary root exceeds the Unix socket address limit; run this fixture in an authorized shorter root.")
    }

    func testServiceInfoReportsAFailedListenerInPlainWords() throws {
        try requireSocketAddressSpace()
        XCTAssertEqual(try listener()["state"] as? String,"not_started")
        XCTAssertEqual(chmod(replies,0o777),0)
        coordinator.startNativeReplies(directory:replies)
        XCTAssertNil(coordinator.queue.sync { coordinator.nativeListener })
        let info = try listener()
        XCTAssertEqual(info["state"] as? String,"failed")
        XCTAssertEqual(info["claude_relay"] as? String,"stopped")
        XCTAssertEqual(info["codex_queue_relay"] as? String,CodexQueueRelay.enabled ? "running" : "off")
        XCTAssertEqual(info["reason"] as? String,"Reply directory must be an existing same-user directory without group/world write access.")
        XCTAssertNil(info["reply_path_name"])
        let message = try XCTUnwrap(info["message"] as? String)
        XCTAssertTrue(message.contains("does not relay notes to Claude"),message)
        XCTAssertTrue(message.contains("Reply directory must be"),message)
        XCTAssertTrue(message.contains("Codex queue route does not use this listener and still runs"),message)
    }

    func testAFreePathReportsTheProcessIDName() throws {
        try requireSocketAddressSpace()
        coordinator.startNativeReplies(directory:replies)
        XCTAssertEqual(coordinator.queue.sync { coordinator.nativeListener?.path },replies + "/\(getpid()).sock")
        let info = try listener()
        XCTAssertEqual(info["state"] as? String,"listening")
        XCTAssertEqual(info["reply_path_name"] as? String,"process_id")
        XCTAssertEqual(info["message"] as? String,"The native reply listener is running.")
    }

    func testAStaleSocketStaysAndTheServiceReportsAFallbackName() throws {
        try requireSocketAddressSpace()
        let path = replies + "/\(getpid()).sock"
        // End the listener while retaining its socket file, producing a genuinely
        // stale path without removing anything outside this fixture.
        do { let stale = try NativeReplyListener(path:path); stale.releaseSocketFile() }
        XCTAssertEqual(chmod(path,0o600),0)
        var before = stat();XCTAssertEqual(lstat(path,&before),0)
        coordinator.startNativeReplies(directory:replies)
        let boundPath = try XCTUnwrap(coordinator.queue.sync { coordinator.nativeListener?.path })
        XCTAssertNotEqual(boundPath,path)
        var after = stat();XCTAssertEqual(lstat(path,&after),0)
        XCTAssertEqual(after.st_ino,before.st_ino)
        let info = try listener()
        XCTAssertEqual(info["state"] as? String,"listening")
        XCTAssertEqual(info["claude_relay"] as? String,"running")
        XCTAssertEqual(info["reply_path_name"] as? String,"fallback")
        XCTAssertTrue((info["message"] as? String ?? "").contains("fallback name"))
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
