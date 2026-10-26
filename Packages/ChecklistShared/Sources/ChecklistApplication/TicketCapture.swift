import Foundation
import ChecklistDomain

/// Decoded capture intent. Opaque legacy optional fields stay in the Core adapter
/// until their own codec extraction is qualified against the frozen wire vectors.
public struct TicketCaptureInput: Equatable, Sendable {
    public let title: String
    public let kind: TicketKind
    public let requestedKey: String?
    public let tagIDs: [String]

    public init(title: String, kind: TicketKind, requestedKey: String? = nil, tagIDs: [String] = []) {
        self.title = title
        self.kind = kind
        self.requestedKey = requestedKey
        self.tagIDs = tagIDs
    }
}

/// An observation supplied by the persistence adapter *inside* its command transaction.
/// The adapter supplies authenticated scope, validated Epic/tags and generated identity/time.
public struct TicketCaptureState: Equatable, Sendable {
    public let projectID: String
    public let keyPrefix: String
    public let nextNumber: Int
    public let existingKeys: Set<String>
    public let queuedStatusID: String
    public let ticketID: String
    public let timestamp: String

    public init(projectID: String, keyPrefix: String, nextNumber: Int, existingKeys: Set<String>,
                queuedStatusID: String, ticketID: String, timestamp: String) {
        self.projectID = projectID
        self.keyPrefix = keyPrefix
        self.nextNumber = nextNumber
        self.existingKeys = existingKeys
        self.queuedStatusID = queuedStatusID
        self.ticketID = ticketID
        self.timestamp = timestamp
    }
}

/// A plan, not a commit receipt. Only the service transaction may publish it.
public struct TicketCaptureResult: Equatable, Sendable {
    public let input: TicketCaptureInput
    public let state: TicketCaptureState
    public let key: String
    public let nextNumber: Int
    public var readiness: String { "draft" }
    public var statusCategory: TicketStatusCategory { .queued }
}

public enum TicketCaptureFailure: Error, Equatable, Sendable {
    case invalidTitle, keyConflict
}

public enum TicketCapture {
    public static func validateTitle(_ title: String) throws {
        guard title.utf8.count <= 2000,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TicketCaptureFailure.invalidTitle
        }
    }

    public static func plan(_ input: TicketCaptureInput, state: TicketCaptureState) throws -> TicketCaptureResult {
        try validateTitle(input.title)
        let key = input.requestedKey ?? "\(state.keyPrefix)-\(state.nextNumber)"
        guard !state.existingKeys.contains(key) else { throw TicketCaptureFailure.keyConflict }
        return TicketCaptureResult(input: input, state: state, key: key, nextNumber: state.nextNumber + 1)
    }
}
