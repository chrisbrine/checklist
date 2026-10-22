import Foundation

/// Settings observations are not transport receipts or recipient acknowledgment.
public enum InboundSetting: String, Codable, Sendable, CaseIterable {
    case accept, hold, refuse
    var severity: Int { Self.allCases.firstIndex(of: self)! }
}

public struct ProviderSettingSource: Equatable, Sendable {
    public enum Scope: String, Sendable { case managed, session, user, project, local }
    public enum Reading: Equatable, Sendable {
        case value(InboundSetting), unset, missing, unreadable, invalid, unsupported
        public var label: String {
            switch self {
            case .value(let value): return value.rawValue
            case .unset: return "Unset (mode parity)"
            case .missing: return "File absent"
            case .unreadable: return "Unreadable"
            case .invalid: return "Invalid JSON or crossSessionInbound value"
            case .unsupported: return "Unsupported source"
            }
        }
    }
    public let scope: Scope
    public let path: String
    public let reading: Reading
    public init(_ scope: Scope, _ path: String, _ reading: Reading) {
        self.scope = scope; self.path = path; self.reading = reading
    }
}

public struct ClaudeReadinessInput: Sendable {
    public var sources: [ProviderSettingSource]
    public var missingInputs: [String]
    public var rulesSupported: Bool
    public var senderClass: String?
    public var recipientClass: String?
    public init(sources: [ProviderSettingSource], missingInputs: [String] = [], rulesSupported: Bool = false,
                senderClass: String? = nil, recipientClass: String? = nil) {
        self.sources = sources; self.missingInputs = missingInputs; self.rulesSupported = rulesSupported
        self.senderClass = senderClass; self.recipientClass = recipientClass
    }
}

public struct ClaudeMessageReadiness: Equatable, Sendable {
    public enum State: String, Sendable { case ready, hold, refuse, unknown }
    public let state: State
    public let observedDecision: InboundSetting?
    public let decidingSource: String
    public let missingInputs: [String]
    public var title: String {
        switch state {
        case .ready: return "Ready (settings observation only)"
        case .hold: return "Hold"
        case .refuse: return "Refuse"
        case .unknown: return "Unknown: live policy not observable"
        }
    }

    /// This key has a special rule: trusted scopes choose a base, repository
    /// scopes can only tighten it. Ordinary last-wins JSON merging is incorrect.
    public static func resolve(_ input: ClaudeReadinessInput) -> Self {
        var missing = input.missingInputs
        if !input.rulesSupported { missing.append("Live engine version and applicable settings rules") }
        for scope in [ProviderSettingSource.Scope.managed, .session, .user, .project, .local] where !input.sources.contains(where: { $0.scope == scope }) {
            missing.append("Unobserved \(scope.rawValue) source")
        }
        for source in input.sources {
            switch source.reading {
            case .missing, .unreadable, .unsupported: missing.append("\(source.path): \(source.reading.label)")
            default: break
            }
        }
        var decision: InboundSetting?
        var deciding = "Unset: sender/recipient permission-class parity"
        for scope in [ProviderSettingSource.Scope.managed, .session, .user] {
            guard let source = input.sources.last(where: { $0.scope == scope }) else { continue }
            switch source.reading {
            case .value(let value): decision = value
            case .invalid: decision = scope == .managed ? .refuse : .hold
            default: continue
            }
            deciding = source.path; break
        }
        if decision == nil {
            if let sender = input.senderClass, let recipient = input.recipientClass, !sender.isEmpty, !recipient.isEmpty {
                decision = sender == recipient ? .accept : .hold
            } else { missing.append("Recipient's current permission class (unset uses mode parity)") }
        }
        for source in input.sources where source.scope == .project || source.scope == .local {
            let restriction: InboundSetting?
            switch source.reading {
            case .value(let value): restriction = value
            case .invalid: restriction = .hold
            default: restriction = nil
            }
            if let restriction, restriction.severity > (decision?.severity ?? 0) {
                decision = restriction; deciding = source.path
            }
        }
        // A partial inspection can show a known restriction, never affirm readiness.
        if decision == .accept && input.sources.contains(where: { $0.reading == .invalid }) { missing.append("Invalid source cannot establish readiness") }
        let state: State = !missing.isEmpty || decision == nil ? .unknown : decision == .accept ? .ready : decision == .hold ? .hold : .refuse
        return Self(state: state, observedDecision: decision, decidingSource: deciding, missingInputs: missing)
    }
}

public struct ProviderReadinessObservation: Sendable {
    public let observedAt: Date
    public let userPath: String
    public let sources: [ProviderSettingSource]
    public let claude: ClaudeMessageReadiness
    public static let codexTitle = "Pickup only"
    public static let versionLimitation = "Live recipient engine version unavailable; a shell CLI version is not a Desktop recipient version."
    public static let codexExplanation = "Notes are available at the conversation's next Checklist MCP check. CLI queue/resume, notify and hooks are not a qualified native wake route. Queue acceptance is not recipient acknowledgment."
}
