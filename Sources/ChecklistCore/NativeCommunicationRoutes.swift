/// Build-level native communication qualification. Enrollment, socket writes and
/// parent receipts cannot promote a child route. CL-5 is carried evidence for one
/// recorded Claude parent configuration only, not a current-recipient availability check.
/// Keep the route IDs and evidence requirements aligned with docs/integrations.md.
public enum NativeCommunicationRoutes {
    public enum Mode: String, Sendable {
        case recordedConfiguration = "recorded_versions_and_configuration_only"
        case explicitPickup = "explicit_checklist_pickup_and_acknowledgment_only"
        case hostRelay = "explicit_checklist_pickup_and_acknowledgment_with_host_relay_only"

        var label: String {
            switch self {
            case .recordedConfiguration: "Qualified for recorded configuration"
            case .explicitPickup: "Qualified for explicit Checklist pickup and acknowledgment"
            case .hostRelay: "Qualified for explicit Checklist pickup and acknowledgment with host relay"
            }
        }
    }

    public struct Route: Identifiable, Sendable {
        public let id: String
        public let provider: String
        public let direction: String
        public let title: String
        public let reason: String
        public let qualifiedVersions: [String: String]
        public let qualificationReceipts: [String]
        public let mode: Mode
        /// Source availability is separate from complete qualification; partial receipts may be retained.
        public let sourceEnabled: Bool
        public var status: String { qualified ? "qualified" : sourceEnabled ? "source_enabled" : "unavailable" }
        public var qualified: Bool { !qualifiedVersions.isEmpty && !qualificationReceipts.isEmpty }
        public var statusLabel: String { qualified ? mode.label : sourceEnabled ? "Source enabled; qualification incomplete" : "Unavailable" }

        init(id: String, provider: String, direction: String, title: String, reason: String,
             qualifiedVersions: [String: String] = [:], qualificationReceipts: [String] = [], mode: Mode = .recordedConfiguration, sourceEnabled: Bool = false) {
            self.id = id; self.provider = provider; self.direction = direction
            self.title = title; self.reason = reason
            self.mode = mode; self.sourceEnabled = sourceEnabled
            self.qualifiedVersions = qualifiedVersions; self.qualificationReceipts = qualificationReceipts
        }

        var serviceInfo: JSON {
            ["id": id, "provider": provider, "direction": direction, "title": title,
             "status": status, "qualified": qualified, "reason": reason,
             "qualified_versions": qualifiedVersions, "qualification_receipts": qualificationReceipts,
             "qualification_scope": qualified ? mode.rawValue : "none"]
        }
    }

    /// One statement of the CL-386 result, shared by the route summary and the work health view.
    public static let relayQualification = "Observed on Desktop 4.4212.0 / engine 2.1.309 / Checklist 253 with a bypass recipient and crossSessionInbound=accept, past the app wake count; other versions, modes and settings are unqualified."
    public static let workHealthWake = "A work health request relays at most once per progress state, never during a known wait, at most 3 times per attempt and once per session in 20 minutes, to its handler only, when that session has a verified native endpoint; otherwise MCP pickup; no model runtime. A Codex app thread has no such endpoint and never gets this request by its queue relay, because a service timer starts no Codex turn: the request stays on session_inbox pickup. " + relayQualification
    public static let summary = "Messages are available when agents check Checklist. Claude parent delivery is qualified only for its recorded versions and configuration. Recorded Codex child/host relay and linked Claude Desktop child routes are qualified for explicit Checklist pickup and acknowledgment only. The Codex app thread relay is source enabled: the loaded-thread, unloaded-thread and later-note recovery checks passed, but the route stays unqualified until a loaded-thread recheck on the current Codex version and a recipient acknowledgment bound to the current enrollment after an app restart. The CL-434 reconnect has no passing installed run yet; docs/codex-host-restart.md records its results. Autonomous child push/wake, Claude parent relay and Codex child closure remain unavailable; untested modes are unqualified. " + workHealthWake + " A relay write alone does not prove a started turn."
    // Private originals stay outside the product. Publish redacted aliases and immutable report references.
    private static let codexVersions = ["checklist_build": "d9ef8900fed26778 (111)", "codex_cli": "0.159.0", "desktop_app": "not established; no desktop endpoint qualified"]
    private static let claudeVersions = ["checklist_build": "d9ef8900fed26778 (111)", "receipt_read_build": "60394b4fa961cb6b (112); historical receipts only", "desktop_app": "3.1623.0", "engine": "2.1.304", "peer_protocol": "1"]
    private static let codexReport = "CL-83:codex-child-report; attachment=e20676fe-a4e0-486d-8aa8-78eee940b82d; sha256=8991dca45f0a3be87ca21fa9a640cfd2d30f2642178ae447c529ff09fbae4650"
    private static let claudeReport = "CL-83:claude-child-report; attachment=15d8b2ff-e222-45f6-8b5b-9708b259781c; sha256=8746c94cbd3bc302f3b31bf3c01aa62c71d1eddb4bc51f730059de9a12f93ef8"
    private static let claudeParentage = "CL-83:claude-host-parentage; attachment=9cfc8395-2193-4e8e-9407-a919fbb89d24; sha256=625e8a65cd916613915f69780c8cd5baa5d6842453e46c019380159b1891904d"
    public static let all: [Route] = [
        Route(id: "codex_idle_wake", provider: "codex", direction: "service_to_session", title: "Codex idle wake-up", reason: "Source enabled; qualification incomplete. Three cases passed. Loaded thread: build 273 with Codex 0.166.0-alpha.5.1. Unloaded-thread open: build 289 (exact-marker reply at 14:05:45), and again on build 291 (91b23bf52628646c) on 4 November 2026 after a real Codex app restart: at 16:46:29 PDT, route=codex_app_queue, source=vscode, queue_poll_result=pending_after_20s, open_result=exited_zero, open_exit_status=0, result=provider_accepted; the turn started at 16:46:52 and wrote the exact marker. Later-note recovery (CL-416): on build 291, one item waited with no turn for 40 s; the later note at 16:55:35 PDT got route=codex_app_queue, source=vscode, queue_poll_result=queue_occupied, reason_code=queue_occupied, open_result=exited_zero, open_exit_status=0, result=refused (no second item) while the waiting item existed; the turn at 16:55:38 ran only the waiting item. The next dispatch pass after that turn relayed the later note as its own queue item: at 16:56:33 PDT, 58 s after the note, queue_poll_result=removed, open_result=not_needed, result=provider_accepted; the thread ran that turn at 16:56:30-16:56:38 and wrote the note's marker. On build 292, a non-contributor check runner repeated both cases: the first-item note got queue_poll_result=pending_after_20s, open_result=exited_zero, result=provider_accepted; the later note got the same refused receipt at 17:50:18 PDT and the next dispatch pass relayed it as its own item at 17:51:05 PDT (queue_poll_result=removed, open_result=not_needed, result=provider_accepted). The service keeps only the latest route_receipt of a delivery (CL-440), so it no longer shows the refused receipts; saved delivery snapshots hold them: build 291 sha256=9d63f15bcd091ea9eecc849466b6430fd60ed8d4c02eed6380263b3b5d63b380, build 292 sha256=3aa32159dee6cfbaaf995147995577c3bc1b5ef024c495cd6ce8db58679266e0. The build 291 cases used ChatGPT 26.1029.61003 with codex-cli 0.166.0-alpha.6. This route is not fully qualified. The loaded-thread case has no recheck on these versions, and a provider update invalidates a result until a recheck. No case recorded a recipient acknowledgment bound to the message and the thread's current enrollment generation: after the app restart, the thread's MCP service_info returned NATIVE_SESSION_MISMATCH. The CL-434 reconnect has no passing installed run yet; docs/codex-host-restart.md records its results. A marker reply proves a started turn, not an acknowledgment. The service refuses exec, mcp and subagent threads and a thread that a codex exec holds.", qualificationReceipts: ["CL-413:loaded-thread; checklist_build=273", "CL-417:unloaded-thread; checklist_build=289; message_id=c54829df-7d89-40a3-9486-e6396b02aa9c", "CL-417:unloaded-thread; checklist_build=291; message_id=445ded0f-bf72-427d-96fb-30d5422e1d50", "CL-417:later-note-recovery; checklist_build=291; message_id=321dfa67-caac-4e1f-9d40-b50f66ffeca5", "CL-417:unloaded-thread; checklist_build=292; message_id=ebe09471-90db-4385-9b3b-33f791fe5223", "CL-417:later-note-recovery; checklist_build=292; message_id=0ca0ee01-6cd9-49c0-817b-eaed7d9718d8"], sourceEnabled: true),
        Route(id: "claude_idle_wake", provider: "claude", direction: "service_to_session", title: "Claude parent idle wake-up", reason: "CL-5 observed an exact parent recipient and correlated native reply in a bypass conversation with crossSessionInbound=accept. CL-386 repeated this past the app wake count. \(relayQualification) These are carried results, not a check of the current recipient or host version.", qualifiedVersions: ["engine": "claude-code 2.1.299", "desktop_app": "2.42304.0", "peer_protocol": "1", "checklist_build": "801d716c6c99cf40 (19)", "relay_engine": "claude-code 2.1.309", "relay_desktop_app": "4.4212.0", "relay_checklist_build": "ec8f218ab59776f9 (253)"], qualificationReceipts: ["CL-5:note_C", "CL-5:note_D_idle", "CL-386:relay-past-cap", "CL-386:relay-past-cap-health"]),
        Route(id: "codex_child_inbound", provider: "codex", direction: "to_child", title: "Codex direct delivery to child", reason: "Explicit child CLI pickup and the child’s own service acknowledgment on build 111 / codex-cli 0.159.0. Native child push/wake and untested idle/busy modes remain unavailable.", qualifiedVersions: codexVersions, qualificationReceipts: ["CL-83:codex-direct-child-inbound; sha256=625d644b98f44de6d59fed0bb0b52f53920a0db807331b3a90c04b67bab4f410", codexReport], mode: .explicitPickup),
        Route(id: "codex_child_outbound", provider: "codex", direction: "from_child", title: "Codex direct delivery from child", reason: "Actual child origin and selected enrolled recipient’s own service acknowledgment on build 111 / codex-cli 0.159.0. No autonomous push/wake or untested mode is qualified.", qualifiedVersions: codexVersions, qualificationReceipts: ["CL-83:codex-direct-child-outbound; sha256=4228cd1fec1e44bb93c95ce1d47b39499207c5704f6607d280bbd4fc2c58c19c", codexReport], mode: .explicitPickup),
        Route(id: "claude_child_inbound", provider: "claude", direction: "to_child", title: "Claude direct delivery to child", reason: "Linked Claude Desktop child B’s exact acknowledgment: exchange on build 111, Desktop 3.1623.0 / engine 2.1.304 / peer 1; historical receipt read on build 112, not a fresh exchange. Explicit Checklist pickup/acknowledgment only; autonomous push/wake, other child classes and untested modes remain unavailable.", qualifiedVersions: claudeVersions, qualificationReceipts: ["CL-83:claude-linked-child-inbound", claudeReport, claudeParentage], mode: .explicitPickup),
        Route(id: "claude_child_outbound", provider: "claude", direction: "from_child", title: "Claude direct delivery from child", reason: "Linked Claude Desktop child B’s verified origin and exact parent acknowledgment: exchange on build 111, Desktop 3.1623.0 / engine 2.1.304 / peer 1; historical receipt read on build 112. Explicit Checklist pickup/acknowledgment only; no fresh build-112 exchange, autonomous push/wake or other child class is qualified.", qualifiedVersions: claudeVersions, qualificationReceipts: ["CL-83:claude-linked-child-outbound", claudeReport, claudeParentage], mode: .explicitPickup),
        Route(id: "codex_parent_relay_inbound", provider: "codex", direction: "to_child_via_parent", title: "Codex parent relay to child", reason: "Explicit parent CLI pickup → supported host followup_task → child-authored correlated Checklist acknowledgment on build 111 / codex-cli 0.159.0. Parent acknowledgment alone is insufficient. No automatic service-to-host relay or native child wake is qualified.", qualifiedVersions: codexVersions, qualificationReceipts: ["CL-83:codex-relay-inbound-parent-pickup; sha256=7870c4e5e4a518a7a6cdc302d452fbb2c8bfa4b6f860ebdb65a6c99c54a7d4dc", "CL-83:codex-relay-inbound-child-ack; sha256=4a56368ca3b8df12eb09354e0e47d8bd969323301ff119bba90b182bbf2cd319", codexReport], mode: .hostRelay),
        Route(id: "codex_parent_relay_outbound", provider: "codex", direction: "from_child_via_parent", title: "Codex child relay through parent", reason: "Actual child host send_message → parent Checklist forward → exact enrolled recipient acknowledgment on build 111 / codex-cli 0.159.0. Service author is parent; separate host evidence proves child origin. Automatic relay and native wake remain unavailable.", qualifiedVersions: codexVersions, qualificationReceipts: ["CL-83:codex-relay-outbound-child-origin; sha256=bbf440eeb58e67df98c0aabb80a6db4e154ec76ae897bd3fd117f97ac36899f4", "CL-83:codex-relay-outbound-recipient-ack; sha256=d64d8a2a1a0d56b790bbe493b02616c9dd0ad983d8f2233135c1441e99ca4d92", codexReport], mode: .hostRelay),
        Route(id: "claude_parent_relay_inbound", provider: "claude", direction: "to_child_via_parent", title: "Claude parent relay to child", reason: "Every native hop and exact child acknowledgment remain unqualified; parent acceptance is insufficient."),
        Route(id: "claude_parent_relay_outbound", provider: "claude", direction: "from_child_via_parent", title: "Claude child relay through parent", reason: "Exact child origin, every native hop and final recipient acknowledgment remain unqualified.")
    ]
    public static var serviceInfo: [[String: Any]] { all.map(\.serviceInfo) }
}
