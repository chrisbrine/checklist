import Foundation
import GRDB

/// Canonical full-row adapter. No query, reference lookup or authority decision here.
enum GRDBRecordEnvelopeAdapter {
    static func input(_ row: Row) throws -> EnvelopeRow {
        var columns: [String: EnvelopeSQLValue] = [:]
        for name in ["id", "project_id", "type", "revision", "data"] {
            guard row.columnNames.contains(name) else { throw failure(EnvelopeFailure(.missingSQLColumn)) }
            let value: DatabaseValue = row[name]
            if name == "revision" {
                guard case .int64(let revision) = value.storage else { throw failure(EnvelopeFailure(.sqlRevision)) }
                columns[name] = .integer(revision)
                continue
            }
            let witnessName = "_envelope_" + name + "_bytes"
            guard row.columnNames.contains(witnessName) else { throw failure(EnvelopeFailure(.missingSQLColumn)) }
            let witness: DatabaseValue = row[witnessName]
            switch value.storage {
            case .null:
                guard case .null = witness.storage else { throw textFailure(name) }
                columns[name] = .null
            case .int64(let integer): columns[name] = .integer(integer)
            case .double(let real): columns[name] = .real(real)
            case .string:
                // GRDB's TEXT contents have already crossed String(cString:).
                // Use only its storage kind; reconstruct complete length-aware
                // bytes from the same-query BLOB witness, preserving valid NUL.
                guard case .blob(let bytes) = witness.storage,
                      let text = String(data:bytes,encoding:.utf8),
                      Data(text.utf8) == bytes else { throw textFailure(name) }
                columns[name] = .text(text)
            case .blob(let data): columns[name] = .blob(data)
            }
        }
        do { return try EnvelopeRow(columns: columns) }
        catch let error as EnvelopeFailure { throw failure(error) }
    }

    static func decode(_ row: Row, expectedType: String? = nil) throws -> DecodedEnvelope {
        do { return try CanonicalEnvelope.decode(input(row), expectedType: expectedType) }
        catch let error as EnvelopeFailure { throw failure(error) }
    }

    /// Final JSON value supplied by existing guarded domain code. Do not default
    /// or coerce a missing/fractional revision before the envelope comparison.
    static func incoming(_ value: JSON, type: String) throws -> EnvelopeRow {
        do {
            guard let id = value["id"] as? String, !id.isEmpty else { throw EnvelopeFailure(.jsonIdentity) }
            let project: EnvelopeSQLValue
            if let rawProject = value["project_id"] {
                guard let text = rawProject as? String, !text.isEmpty else { throw EnvelopeFailure(.jsonProject) }
                project = .text(text)
            } else { project = .null }
            guard let rawRevision = value["revision"] as? NSNumber else { throw EnvelopeFailure(.jsonRevision) }
            let revision = try EnvelopeInteger.positiveExact(rawRevision.stringValue)
            return try EnvelopeRow(columns: ["id": .text(id), "project_id": project, "type": .text(type),
                "revision": .integer(revision), "data": .text(try jsonString(value))])
        } catch let error as EnvelopeFailure { throw failure(error) }
    }

    static func compareSave(incoming: EnvelopeRow, previous: Row?) throws -> DecodedEnvelope {
        do {
            return try CanonicalEnvelope.compareSave(incoming: incoming, previous: try previous.map(input))
        } catch let error as EnvelopeFailure { throw failure(error) }
    }

    static func failure(_ error: EnvelopeFailure) -> CoreError {
        CoreError("CANONICAL_RECORD_INVALID", error.publicProjection["message"]!, details: ["reason": error.reason.rawValue])
    }

    private static func textFailure(_ name: String) -> CoreError {
        let reason: EnvelopeFailure.Reason
        switch name {
        case "id": reason = .sqlIdentity
        case "project_id": reason = .sqlProject
        case "type": reason = .sqlType
        default: reason = .sqlData
        }
        return failure(EnvelopeFailure(reason))
    }
}
