import Foundation

/// Canonical input adapter. Preserve SQL storage kinds before decoding;
/// converting a REAL revision to Int64 at the caller would hide corruption.
enum EnvelopeSQLValue: Equatable {
    case null, integer(Int64), real(Double), text(String), blob(Data)

    static func == (left: Self, right: Self) -> Bool {
        switch (left, right) {
        case (.null, .null): return true
        case let (.integer(a), .integer(b)): return a == b
        case let (.real(a), .real(b)): return a == b
        case let (.text(a), .text(b)): return EnvelopeStorageIdentity.equal(a, b)
        case let (.blob(a), .blob(b)): return a == b
        default: return false
        }
    }
}

/// SQLite's unchanged BINARY identities distinguish canonically equivalent
/// Unicode encodings. Keep original UTF-8; never normalize opaque keys.
enum EnvelopeStorageIdentity {
    static func equal(_ left: String, _ right: String) -> Bool {
        left.utf8.elementsEqual(right.utf8)
    }
    static func equal(_ left: String?, _ right: String?) -> Bool {
        switch (left, right) {
        case (.none, .none): return true
        case let (.some(a), .some(b)): return equal(a, b)
        default: return false
        }
    }
}
struct EnvelopeRow: Equatable {
    let id: EnvelopeSQLValue
    let project: EnvelopeSQLValue
    let type: EnvelopeSQLValue
    let revision: EnvelopeSQLValue
    let data: EnvelopeSQLValue

    init(columns: [String: EnvelopeSQLValue]) throws {
        guard let id = columns["id"], let project = columns["project_id"],
              let type = columns["type"], let revision = columns["revision"],
              let data = columns["data"] else { throw EnvelopeFailure(.missingSQLColumn) }
        self.id = id; self.project = project; self.type = type
        self.revision = revision; self.data = data
    }
}

struct EnvelopeFailure: Error, Equatable {
    enum Reason: String {
        case missingSQLColumn, sqlIdentity, sqlProject, sqlType, sqlRevision, sqlData
        case jsonObject, duplicateEnvelopeField, jsonIdentity, jsonProject, jsonRevision
        case identityMismatch, projectMismatch, revisionMismatch, expectedTypeMismatch
        case unsupportedFamily, unsupportedPreviousFamily, ownershipShape
        case immutableType, immutableTaskProject, immutableMediaRevision, immutableBatchDisposition, revisionRegression
    }
    let reason: Reason
    init(_ reason: Reason) { self.reason = reason }
    // No original ids, type names, paths, payload or Foundation parsing errors.
    var publicProjection: [String: String] {
        ["code": "CANONICAL_RECORD_INVALID", "message": "This record cannot be used safely. Authorized diagnosis is required."]
    }
}

enum EnvelopeOwnership { case project, selfOwnedProject, global, session, hold }
struct EnvelopeFamily {
    let name: String
    let ownership: EnvelopeOwnership

    // Storage classification from the accepted catalog, plus this composed
    // project-owned managed-import job. These
    // are not task/state enums, workflow policy or a grant from a record name.
    static let catalog: [String: EnvelopeFamily] = {
        let projectOwned = ["attachment", "attempt", "batch", "batch_claim", "batch_disposition", "checkpoint", "cleanup_preview", "cleanup_job",
            "conversation", "delegation", "delivery", "direction_disposition", "finding", "finding_resolution",
            "group", "handoff", "manifest", "native_closure", "message", "ordinary_mention_plan", "policy_proposal", "policy_revision",
            "project_context_revision", "recipient_target", "relation", "request", "review", "review_request",
            "source_capture", "source_execution", "storage_job", "status", "tag", "task", "task_alias", "task_session",
            "taxonomy_revision", "triage_membership_exit", "triage_membership_interval"]
        var values = Dictionary(uniqueKeysWithValues: projectOwned.map { ($0, EnvelopeFamily(name: $0, ownership: .project)) })
        let exceptions: [(String, EnvelopeOwnership)] = [("project", .selfOwnedProject), ("profile", .global), ("session", .session), ("storage_hold", .hold)]
        for name in MediaRecordRegistry.families {
            values[name] = EnvelopeFamily(name: name, ownership: .project)
        }
        for (name, ownership) in exceptions {
            values[name] = EnvelopeFamily(name: name, ownership: ownership)
        }
        return values
    }()
}

struct DecodedEnvelope {
    let id: String
    let projectID: String?
    let type: String
    let revision: Int64
    let object: [String: Any]
    let original: EnvelopeRow
}
enum EnvelopeInspection {
    case known(DecodedEnvelope)
    // Diagnosis-only data, never an authorized runtime record or new-write class.
    case unclassifiedOriginal(EnvelopeRow)
}

enum CanonicalEnvelope {
    static func inspectPreservingUnknown(_ row: EnvelopeRow) throws -> EnvelopeInspection {
        let type = try sqlText(row.type, failure: .sqlType)
        guard EnvelopeFamily.catalog[type] != nil else { return .unclassifiedOriginal(row) }
        return .known(try decode(row))
    }

    /// Pure: no database handle, lookup, callback, query, repair or grant check.
    static func decode(_ row: EnvelopeRow, expectedType: String? = nil) throws -> DecodedEnvelope {
        let id = try sqlText(row.id, failure: .sqlIdentity)
        let type = try sqlText(row.type, failure: .sqlType)
        guard expectedType.map({ EnvelopeStorageIdentity.equal($0, type) }) ?? true else { throw EnvelopeFailure(.expectedTypeMismatch) }
        guard let family = EnvelopeFamily.catalog[type], EnvelopeStorageIdentity.equal(family.name, type) else { throw EnvelopeFailure(.unsupportedFamily) }
        let sqlProject: String?
        switch row.project {
        case .null: sqlProject = nil
        case .text(let project) where !project.isEmpty: sqlProject = project
        default: throw EnvelopeFailure(.sqlProject)
        }
        guard case .integer(let revision) = row.revision, revision > 0 else { throw EnvelopeFailure(.sqlRevision) }
        guard case .text(let raw) = row.data else { throw EnvelopeFailure(.sqlData) }
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { throw EnvelopeFailure(.jsonObject) }
            object = decoded
        } catch { throw EnvelopeFailure(.jsonObject) }
        let fields = try EnvelopeJSONFields.topLevel(raw)
        guard let jsonID = object["id"] as? String, !jsonID.isEmpty else { throw EnvelopeFailure(.jsonIdentity) }
        guard EnvelopeStorageIdentity.equal(id, jsonID) else { throw EnvelopeFailure(.identityMismatch) }
        let jsonProject: String?
        if let value = object["project_id"] {
            guard let project = value as? String, !project.isEmpty else { throw EnvelopeFailure(.jsonProject) }
            jsonProject = project
        } else { jsonProject = nil }
        guard EnvelopeStorageIdentity.equal(sqlProject, jsonProject) else { throw EnvelopeFailure(.projectMismatch) }
        guard let token = fields["revision"] else { throw EnvelopeFailure(.jsonRevision) }
        let jsonRevision = try EnvelopeInteger.positiveExact(token)
        // Validate both original token and parsed payload. A rounded Foundation
        // Double must not be returned as if it were the exact source integer.
        guard let number = object["revision"] as? NSNumber,
              try EnvelopeInteger.positiveExact(number.stringValue) == jsonRevision else { throw EnvelopeFailure(.jsonRevision) }
        guard revision == jsonRevision else { throw EnvelopeFailure(.revisionMismatch) }
        switch family.ownership {
        case .project: guard sqlProject != nil else { throw EnvelopeFailure(.ownershipShape) }
        case .selfOwnedProject: guard EnvelopeStorageIdentity.equal(sqlProject, Optional(id)) else { throw EnvelopeFailure(.ownershipShape) }
        case .global: guard sqlProject == nil else { throw EnvelopeFailure(.ownershipShape) }
        case .session:
            guard sqlProject != nil else { throw EnvelopeFailure(.ownershipShape) }
            // Historical anchor-only sessions and revoked empty grants remain
            // valid. This checks shape, never grant/liveness/authority.
            if let rawGrants = object["project_ids"] {
                guard let grants = rawGrants as? [String], grants.allSatisfy({ !$0.isEmpty }) else { throw EnvelopeFailure(.ownershipShape) }
            }
        case .hold:
            if object["kind"] as? String == "reader" { guard sqlProject != nil else { throw EnvelopeFailure(.ownershipShape) } }
            else if object["kind"] as? String == "media_reference" {
                guard sqlProject != nil,let owner = object["owner_id"] as? String,!owner.isEmpty,
                      let kind = object["owner_kind"] as? String,["media_intake","media_draft_item","media_target"].contains(kind),
                      let attachment = object["attachment_id"] as? String,!attachment.isEmpty,
                      object["expires_at"] == nil else { throw EnvelopeFailure(.ownershipShape) }
            }
            else if object["kind"] as? String == "backup" { guard sqlProject == nil else { throw EnvelopeFailure(.ownershipShape) } }
            else { throw EnvelopeFailure(.ownershipShape) }
        }
        return .init(id: id, projectID: sqlProject, type: type, revision: revision, object: object, original: row)
    }

    /// Incoming and previous full rows are both checked; malformed/unknown
    /// originals are never overwritten to make validation pass.
    static func compareSave(incoming: EnvelopeRow, previous: EnvelopeRow?) throws -> DecodedEnvelope {
        let next = try decode(incoming)
        guard let previous else { return next }
        let priorType = try sqlText(previous.type, failure: .sqlType)
        guard EnvelopeFamily.catalog[priorType] != nil else { throw EnvelopeFailure(.unsupportedPreviousFamily) }
        let prior = try decode(previous)
        guard EnvelopeStorageIdentity.equal(prior.id, next.id) else { throw EnvelopeFailure(.identityMismatch) }
        guard EnvelopeStorageIdentity.equal(prior.type, next.type) else { throw EnvelopeFailure(.immutableType) }
        if next.type == "task", !EnvelopeStorageIdentity.equal(prior.projectID, next.projectID) { throw EnvelopeFailure(.immutableTaskProject) }
        if next.type == "batch_disposition" || MediaRecordRegistry.immutableFamilies.contains(next.type) {
            guard let before = try? JSONSerialization.data(withJSONObject:prior.object,options:[.sortedKeys]),
                  let after = try? JSONSerialization.data(withJSONObject:next.object,options:[.sortedKeys]),before == after else {
                throw EnvelopeFailure(next.type == "batch_disposition" ? .immutableBatchDisposition : .immutableMediaRevision)
            }
        }
        guard next.revision >= prior.revision else { throw EnvelopeFailure(.revisionRegression) }
        return next
    }

    private static func sqlText(_ value: EnvelopeSQLValue, failure: EnvelopeFailure.Reason) throws -> String {
        guard case .text(let text) = value, !text.isEmpty else { throw EnvelopeFailure(failure) }
        return text
    }
}

/// Exact decimal token arithmetic for revision only. No Double/intValue
/// conversion; integral1.0/1e0 are accepted, fractions/overflow/Boolean are not.
enum EnvelopeInteger {
    static func positiveExact(_ text: String) throws -> Int64 {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes[0] != 45, bytes[0] != 43 else { throw EnvelopeFailure(.jsonRevision) }
        var mantissa = bytes, exponent = 0
        if let marker = bytes.firstIndex(where: { $0 == 101 || $0 == 69 }) {
            mantissa = Array(bytes[..<marker])
            var digits = Array(bytes[(marker + 1)...]), negative = false
            if digits.first == 45 || digits.first == 43 { negative = digits.removeFirst() == 45 }
            guard !digits.isEmpty else { throw EnvelopeFailure(.jsonRevision) }
            for digit in digits {
                guard (48...57).contains(digit) else { throw EnvelopeFailure(.jsonRevision) }
                let step = exponent.multipliedReportingOverflow(by: 10)
                let sum = step.partialValue.addingReportingOverflow(Int(digit - 48))
                guard !step.overflow, !sum.overflow, sum.partialValue <= bytes.count + 20 else { throw EnvelopeFailure(.jsonRevision) }
                exponent = sum.partialValue
            }
            if negative { exponent = -exponent }
        }
        var digits: [UInt8] = [], fractionCount = 0, afterPoint = false
        for byte in mantissa {
            if byte == 46, !afterPoint { afterPoint = true; continue }
            guard (48...57).contains(byte) else { throw EnvelopeFailure(.jsonRevision) }
            digits.append(byte); if afterPoint { fractionCount += 1 }
        }
        digits = Array(digits.drop(while: { $0 == 48 }))
        guard !digits.isEmpty else { throw EnvelopeFailure(.jsonRevision) }
        let scale = exponent - fractionCount
        if scale >= 0 {
            guard digits.count <= 19, scale <= 19 - digits.count else { throw EnvelopeFailure(.jsonRevision) }
            digits.append(contentsOf: repeatElement(48, count: scale))
        } else {
            let remove = -scale
            guard remove < digits.count, digits.suffix(remove).allSatisfy({ $0 == 48 }) else { throw EnvelopeFailure(.jsonRevision) }
            digits.removeLast(remove)
        }
        guard let exact = Int64(String(decoding: digits, as: UTF8.self)), exact > 0 else { throw EnvelopeFailure(.jsonRevision) }
        return exact
    }
}

/// JSONSerialization first validates the complete object. This small lexical
/// pass preserves the original envelope number token and detects duplicated
/// envelope keys, including escaped spellings, without recursively validating
/// unrelated counters/objects or choosing a last duplicate identity.
private enum EnvelopeJSONFields {
    static func topLevel(_ raw: String) throws -> [String: String] {
        let bytes = Array(raw.utf8)
        var index = 0, result: [String: String] = [:]
        func whitespace() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        func stringEnd() throws {
            guard index < bytes.count, bytes[index] == 34 else { throw EnvelopeFailure(.jsonObject) }
            index += 1
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 92 { guard index < bytes.count else { throw EnvelopeFailure(.jsonObject) }; index += 1 }
                else if byte == 34 { return }
            }
            throw EnvelopeFailure(.jsonObject)
        }
        func valueEnd() throws {
            guard index < bytes.count else { throw EnvelopeFailure(.jsonObject) }
            if bytes[index] == 34 { try stringEnd(); return }
            if bytes[index] == 123 || bytes[index] == 91 {
                var depth = 0
                repeat {
                    guard index < bytes.count else { throw EnvelopeFailure(.jsonObject) }
                    let byte = bytes[index]
                    if byte == 34 { try stringEnd(); continue }
                    if byte == 123 || byte == 91 { depth += 1 }
                    if byte == 125 || byte == 93 { depth -= 1 }
                    index += 1
                } while depth > 0
            } else {
                while index < bytes.count, ![9, 10, 13, 32, 44, 125].contains(bytes[index]) { index += 1 }
            }
        }
        whitespace(); guard index < bytes.count, bytes[index] == 123 else { throw EnvelopeFailure(.jsonObject) }; index += 1
        while true {
            whitespace(); guard index < bytes.count else { throw EnvelopeFailure(.jsonObject) }
            if bytes[index] == 125 { return result }
            let start = index; try stringEnd()
            guard let key = try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed]) as? String else { throw EnvelopeFailure(.jsonObject) }
            whitespace(); guard index < bytes.count, bytes[index] == 58 else { throw EnvelopeFailure(.jsonObject) }; index += 1
            whitespace(); let valueStart = index; try valueEnd()
            if ["id", "project_id", "revision"].contains(key) {
                guard result[key] == nil else { throw EnvelopeFailure(.duplicateEnvelopeField) }
                result[key] = String(decoding: bytes[valueStart..<index], as: UTF8.self)
            }
            whitespace(); guard index < bytes.count else { throw EnvelopeFailure(.jsonObject) }
            if bytes[index] == 125 { return result }
            guard bytes[index] == 44 else { throw EnvelopeFailure(.jsonObject) }; index += 1
        }
    }
}
