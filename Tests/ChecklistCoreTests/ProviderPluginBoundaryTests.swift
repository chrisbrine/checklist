import XCTest
import ChecklistProviders
@testable import ChecklistCore

extension CoreTests {
    private struct SyntheticProvider: ChecklistProviderPlugin {
        let manifest = ProviderPluginManifest(pluginID:"example.synthetic",version:"1.0.0",providerID:"synthetic",displayName:"Synthetic fixture",capabilities:[.workSession,.pickup,.correlatedReply])
    }
    func testProviderPluginFixtureDiscoveryNeverGrantsWorkOrPolicyEligibility() throws {
        router = nil
        router = try CommandRouter(root:directory,providerPlugins:ProviderPluginRegistry(ProviderPluginRegistry.bundled.registrations + [.init(plugin:SyntheticProvider())]))
        let info = try call("service_info"), plugins = info["provider_plugins"] as! [JSON]
        XCTAssertEqual(plugins.last?["provider_id"] as? String,"synthetic")
        XCTAssertEqual(plugins.last?["availability"] as? String,"disabled")
        let workspace=directory.appendingPathComponent("synthetic-workspace")
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let project = try call("project_create",["name":"Synthetic scope","key_prefix":"SYN","root_path":workspace.path]),pid = project["id"] as! String
        let ticket = try ready(project,task(project)),sid = UUID().uuidString
        _ = try call("session_register",["project_id":pid,"session_id":sid,"provider":"synthetic","role":"worker","installation":"synthetic"])
        let worker = Caller(role:"worker",installation:"synthetic",projectIDs:[pid],sessionID:sid,workspace:workspace.path)
        assertCode("POLICY_DENIED") { _ = try self.call("work_claim",["project_id":pid,"task_id":ticket["id"]!,"expected_revision":ticket["revision"]!],worker) }
        assertCode("INVALID_INPUT") { _ = try self.router.normalizedPolicy(["allowed_providers":["synthetic"]]) }
    }
    func testProviderDisablePreservesClaimsMessagesGrantsAndReplyCorrelationForRecovery() throws {
        let fixture = try nativeHandlerFixture()
        let message = try call("message_send",["project_id":fixture.pid,"task_id":fixture.task["id"]!,"body":"Pending plugin upgrade reply","expects_reply":true])
        let beforeTask = try call("task_get",["project_id":fixture.pid,"task_id":fixture.task["id"]!])
        let before = try call("snapshot")
        let registry = try ProviderPluginRegistry(ProviderPluginRegistry.bundled.registrations.map { .init(plugin:$0.plugin) })
        router = nil;router = try CommandRouter(root:directory,providerPlugins:registry)
        let after = try call("snapshot")
        for family in ["sessions","attempts","messages","deliveries"] {
            let previous = before[family] as? [JSON] ?? [],current = after[family] as? [JSON] ?? []
            XCTAssertEqual(try JSONSerialization.data(withJSONObject:previous,options:.sortedKeys),try JSONSerialization.data(withJSONObject:current,options:.sortedKeys),family)
        }
        XCTAssertFalse(router.canReceive(["role":"worker","provider":"claude","project_id":fixture.pid],project:fixture.pid))
        assertCode("POLICY_DENIED") { _ = try self.router.dbQueue.read { db in
            let project = try self.router.record(db,fixture.pid,type:"project"),task = try self.router.record(db,fixture.task["id"] as! String,type:"task")
            try self.router.validatePolicySelection(db,project:project,task:task,caller:fixture.worker,phase:"implementation",policy:[:])
        } }
        router = nil;router = try CommandRouter(root:directory)
        let inbox = try call("session_inbox",["project_id":fixture.pid],fixture.worker)["deliveries"] as! [JSON]
        XCTAssertTrue(inbox.contains { $0["message_id"] as? String == message["id"] as? String })
        let task = try call("task_get",["project_id":fixture.pid,"task_id":fixture.task["id"]!])
        XCTAssertEqual(task["active_attempt_id"] as? String,beforeTask["active_attempt_id"] as? String)
    }
    func testNativePeerDisableDoesNotConsumeReplyWhilePickupRemainsQualified() throws {
        let fixture = try nativeHandlerFixture()
        let message = try call("message_send",["project_id":fixture.pid,"task_id":fixture.task["id"]!,"body":"Pending native reply","expects_reply":true])
        let registrations = ProviderPluginRegistry.bundled.registrations.map { registration in
            ProviderPluginRegistration(plugin:registration.plugin,enabled:registration.enabled,
                qualifiedCapabilities:registration.qualifiedCapabilities.subtracting([.nativePeer]))
        }
        router = nil;router = try CommandRouter(root:directory,providerPlugins:ProviderPluginRegistry(registrations))
        let bridge = Caller(role:"owner",installation:"native-bridge",projectIDs:[])
        let input: JSON = ["project_id":fixture.pid,"reply_to":message["id"]!,"recipient_session_id":fixture.sid,"body":"Synthetic reply"]
        assertCode("ADAPTER_UNAVAILABLE") { _ = try self.call("native_reply_record",input,bridge) }
        let inbox = try call("session_inbox",["project_id":fixture.pid],fixture.worker)["deliveries"] as! [JSON]
        XCTAssertEqual(inbox.count,1);XCTAssertEqual(inbox.first?["state"] as? String,"queued")
        XCTAssertFalse(try router.dbQueue.read { db in bool(try self.router.record(db,message["id"] as! String,type:"message"),"reply_used") })
        router = nil;router = try CommandRouter(root:directory)
        let reply = try call("native_reply_record",input,bridge)
        XCTAssertEqual(reply["reply_to"] as? String,message["id"] as? String)
    }

}
