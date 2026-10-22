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
        public var status: String { qualified ? "qualified" : "unavailable" }
        public var qualified: Bool { !qualifiedVersions.isEmpty && !qualificationReceipts.isEmpty }
        public var statusLabel: String { qualified ? mode.label : "Unavailable" }

        init(id: String, provider: String, direction: String, title: String, reason: String,
             qualifiedVersions: [String: String] = [:], qualificationReceipts: [String] = [], mode: Mode = .recordedConfiguration) {
            self.id = id; self.provider = provider; self.direction = direction
            self.title = title; self.reason = reason
            self.mode = mode
            self.qualifiedVersions = qualifiedVersions; self.qualificationReceipts = qualificationReceipts
        }

        var serviceInfo: JSON {
            ["id": id, "provider": provider, "direction": direction, "title": title,
             "status": status, "qualified": qualified, "reason": reason,
             "qualified_versions": qualifiedVersions, "qualification_receipts": qualificationReceipts,
             "qualification_scope": qualified ? mode.rawValue : "none"]
        }
    }

    public static let summary = "Messages are available when agents check Checklist. Claude parent delivery is qualified only for its recorded versions and configuration. Recorded Codex child/host relay and linked Claude Desktop child routes are qualified for explicit Checklist pickup and acknowledgment only. Autonomous child push/wake, Claude parent relay and Codex child closure remain unavailable; untested modes are unqualified."
    // Private originals stay outside the product. Publish redacted aliases and immutable report references.
    private static let codexVersions = ["checklist_build": "d9ef8900fed26778 (111)", "codex_cli": "0.159.0", "desktop_app": "not established; no desktop endpoint qualified"]
    private static let claudeVersions = ["checklist_build": "d9ef8900fed26778 (111)", "receipt_read_build": "60394b4fa961cb6b (112); historical receipts only", "desktop_app": "3.1623.0", "engine": "2.1.304", "peer_protocol": "1"]
    private static let codexReport = "CL-83:codex-child-report; attachment=e20676fe-a4e0-486d-8aa8-78eee940b82d; sha256=8991dca45f0a3be87ca21fa9a640cfd2d30f2642178ae447c529ff09fbae4650"
    private static let claudeReport = "CL-83:claude-child-report; attachment=15d8b2ff-e222-45f6-8b5b-9708b259781c; sha256=8746c94cbd3bc302f3b31bf3c01aa62c71d1eddb4bc51f730059de9a12f93ef8"
    private static let claudeParentage = "CL-83:claude-host-parentage; attachment=9cfc8395-2193-4e8e-9407-a919fbb89d24; sha256=625e8a65cd916613915f69780c8cd5baa5d6842453e46c019380159b1891904d"
    public static let all: [Route] = [
        Route(id: "codex_idle_wake", provider: "codex", direction: "service_to_session", title: "Codex idle wake-up", reason: "No qualified native desktop wake route; authenticated MCP pickup does not wake a conversation."),
        Route(id: "claude_idle_wake", provider: "claude", direction: "service_to_session", title: "Claude parent idle wake-up", reason: "CL-5 observed an exact parent recipient and correlated native reply in a bypass conversation with crossSessionInbound=accept. This is carried build-19 evidence, not a check of the current recipient or host version.", qualifiedVersions: ["engine": "claude-code 2.1.299", "desktop_app": "2.42304.0", "peer_protocol": "1", "checklist_build": "801d716c6c99cf40 (19)"], qualificationReceipts: ["CL-5:note_C", "CL-5:note_D_idle"]),
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
