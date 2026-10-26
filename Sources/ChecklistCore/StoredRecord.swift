import ChecklistDomain

/// A checked view of an open stored record, retaining unknown fields and legacy optional values.
/// Mandatory fields are checked only when the consumer requests them.
struct StoredRecord {
    let value: JSON
    let family: String

    init(_ value: JSON, family: String) {
        self.value = value
        self.family = family
    }

    /// Presence-only access for legacy fields whose dynamic value remains intentionally open.
    func requiredValue(_ key: String) throws -> Any {
        guard let result = value[key] else { throw invalidRecord() }
        return result
    }

    func string(_ key: String) throws -> String {
        guard let result = value[key] as? String else { throw invalidRecord() }
        return result
    }

    func object(_ key: String) throws -> JSON {
        guard let result = value[key] as? JSON else { throw invalidRecord() }
        return result
    }

    func objects(_ key: String) throws -> [JSON] {
        guard let result = value[key] as? [JSON] else { throw invalidRecord() }
        return result
    }

    private func invalidRecord() -> CoreError {
        // Do not expose stored content, field values or caller-supplied labels in the error.
        CoreError("CANONICAL_RECORD_INVALID", "A stored record is malformed.")
    }
}

struct StoredTaskRecord {
    let id: String
    let projectID: String
    let value: JSON

    init(_ value: JSON) throws {
        let record = StoredRecord(value, family: "task")
        id = try record.string("id")
        projectID = try record.string("project_id")
        self.value = value
    }

    var rawKind: String? { value["kind"] as? String }
    var kind: TicketKind? { rawKind.flatMap(TicketKind.init(rawValue:)) }
    var statusID: String? { value["status_id"] as? String }
}

struct StoredAttemptRecord {
    let id: String
    let projectID: String
    let taskID: String
    let value: JSON

    init(_ value: JSON) throws {
        let record = StoredRecord(value, family: "attempt")
        id = try record.string("id")
        projectID = try record.string("project_id")
        taskID = try record.string("task_id")
        self.value = value
    }

    var rawPhase: String? { value["phase"] as? String }
    var phase: AttemptPhase? { rawPhase.flatMap(AttemptPhase.init(rawValue:)) }
}
