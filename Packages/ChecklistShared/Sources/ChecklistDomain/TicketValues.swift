/// Stable wire values, shared by validation, policy and presentation.
public enum TicketKind: String, Codable, CaseIterable, Sendable {
    case work, bug, asset, playtest, question
    public static var wireValues: [String] { allCases.map(\.rawValue) }
}

/// These are semantic categories, not editable project status names.
public enum TicketStatusCategory: String, Codable, CaseIterable, Sendable {
    case queued, active, review, blocked, parked, done, canceled
    public static var wireValues: [String] { allCases.map(\.rawValue) }
}

public enum AttemptPhase: String, Codable, CaseIterable, Sendable {
    case implementation, review
    public static var wireValues: [String] { allCases.map(\.rawValue) }
    public var workflowRole: WorkflowRole { self == .review ? .reviewer : .implementer }
}

/// Policy roles do not authenticate a caller or grant work authority.
public enum WorkflowRole: String, Codable, CaseIterable, Sendable {
    case coordinator, implementer, reviewer
    public static var wireValues: [String] { allCases.map(\.rawValue) }
}

/// Authentication remains the service's responsibility.
public enum CallerRole: String, Codable, CaseIterable, Sendable {
    case owner, worker, reviewer, assistant
    public static var wireValues: [String] { allCases.map(\.rawValue) }
}
