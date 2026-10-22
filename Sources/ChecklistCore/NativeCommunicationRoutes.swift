/// Build-level native communication qualification. Enrollment, socket writes and
/// parent receipts cannot promote a child route. CL-5 is carried evidence for one
/// recorded Claude parent configuration only, not a current-recipient availability check.
/// Keep the route IDs and evidence requirements aligned with docs/integrations.md.
public enum NativeCommunicationRoutes {
    public struct Route: Identifiable, Sendable {
        public let id: String
        public let provider: String
        public let direction: String
        public let title: String
        public let reason: String
        public let qualifiedVersions: [String: String]
        public let qualificationReceipts: [String]
        public var status: String { qualified ? "qualified" : "unavailable" }
        public var qualified: Bool { !qualifiedVersions.isEmpty && !qualificationReceipts.isEmpty }
        public var statusLabel: String { qualified ? "Qualified for recorded configuration" : "Unavailable" }

        init(id: String, provider: String, direction: String, title: String, reason: String,
             qualifiedVersions: [String: String] = [:], qualificationReceipts: [String] = []) {
            self.id = id; self.provider = provider; self.direction = direction
            self.title = title; self.reason = reason
            self.qualifiedVersions = qualifiedVersions; self.qualificationReceipts = qualificationReceipts
        }

        var serviceInfo: JSON {
            ["id": id, "provider": provider, "direction": direction, "title": title,
             "status": status, "qualified": qualified, "reason": reason,
             "qualified_versions": qualifiedVersions, "qualification_receipts": qualificationReceipts,
             "qualification_scope": qualified ? "recorded_versions_and_configuration_only" : "none"]
        }
    }

    public static let summary = "Messages are available when agents check Checklist. Claude parent delivery is qualified only for its recorded versions and configuration. Codex wake-up, child delivery and parent relay remain unavailable."
    public static let all: [Route] = [
        Route(id: "codex_idle_wake", provider: "codex", direction: "service_to_session", title: "Codex idle wake-up", reason: "No qualified native desktop wake route; authenticated MCP pickup does not wake a conversation."),
        Route(id: "claude_idle_wake", provider: "claude", direction: "service_to_session", title: "Claude parent idle wake-up", reason: "CL-5 observed an exact parent recipient and correlated native reply in a bypass conversation with crossSessionInbound=accept. This is carried build-19 evidence, not a check of the current recipient or host version.", qualifiedVersions: ["engine": "claude-code 2.1.299", "desktop_app": "2.42304.0", "peer_protocol": "1", "checklist_build": "801d716c6c99cf40 (19)"], qualificationReceipts: ["CL-5:note_C", "CL-5:note_D_idle"]),
        Route(id: "codex_child_inbound", provider: "codex", direction: "to_child", title: "Codex direct delivery to child", reason: "No exact native child receipt and acknowledgment for this route."),
        Route(id: "codex_child_outbound", provider: "codex", direction: "from_child", title: "Codex direct delivery from child", reason: "No exact native child sender and recipient round-trip qualification."),
        Route(id: "claude_child_inbound", provider: "claude", direction: "to_child", title: "Claude direct delivery to child", reason: "No exact native child receipt and acknowledgment for this route."),
        Route(id: "claude_child_outbound", provider: "claude", direction: "from_child", title: "Claude direct delivery from child", reason: "No exact native child sender and recipient round-trip qualification."),
        Route(id: "codex_parent_relay_inbound", provider: "codex", direction: "to_child_via_parent", title: "Codex parent relay to child", reason: "Every native hop and exact child acknowledgment remain unqualified; parent acceptance is insufficient."),
        Route(id: "codex_parent_relay_outbound", provider: "codex", direction: "from_child_via_parent", title: "Codex child relay through parent", reason: "Exact child origin, every native hop and final recipient acknowledgment remain unqualified."),
        Route(id: "claude_parent_relay_inbound", provider: "claude", direction: "to_child_via_parent", title: "Claude parent relay to child", reason: "Every native hop and exact child acknowledgment remain unqualified; parent acceptance is insufficient."),
        Route(id: "claude_parent_relay_outbound", provider: "claude", direction: "from_child_via_parent", title: "Claude child relay through parent", reason: "Exact child origin, every native hop and final recipient acknowledgment remain unqualified.")
    ]
    public static var serviceInfo: [[String: Any]] { all.map(\.serviceInfo) }
}
