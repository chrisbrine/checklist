import Foundation
import CoreFoundation

/// Closed portable values; no source access, evaluation or authorization.
enum MediaConfigurationValue {
    static func object(_ raw: Any?, _ path: String) throws -> [String: Any] {
        guard let value = raw as? [String: Any] else { throw MediaSchemaError.invalid(path, "expected object") }; return value
    }
    static func keys(_ value: [String: Any], _ allowed: Set<String>, _ path: String) throws {
        guard Set(value.keys).isSubset(of: allowed) else { throw MediaSchemaError.invalid(path, "unknown field") }
    }
    static func array(_ raw: Any?, max: Int, _ path: String) throws -> [Any] {
        guard let raw else { return [] }
        guard let value = raw as? [Any], value.count <= max else { throw MediaSchemaError.invalid(path, "expected bounded array") }; return value
    }
    static func integer(_ raw: Any?, min: Int = 0, max: Int, _ path: String) throws -> Int {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue.rounded() == n.doubleValue, n.doubleValue >= Double(min), n.doubleValue <= Double(max) else { throw MediaSchemaError.invalid(path, "expected bounded integer") }; return n.intValue
    }
    static func text(_ raw: Any?, max: Int, _ path: String) throws -> String {
        guard let s = raw as? String, !s.isEmpty, s.utf8.count <= max else { throw MediaSchemaError.invalid(path, "expected bounded text") }; return s
    }
    static func id(_ raw: Any?, _ path: String) throws -> MediaReviewID { try MediaReviewID(text(raw, max: 256, path)) }
    static func ids(_ raw: Any?, max: Int, _ path: String) throws -> [MediaReviewID] {
        let result = try array(raw, max: max, path).map { try id($0, path) }
        guard Set(result).count == result.count else { throw MediaSchemaError.invalid(path, "duplicate ID") }; return result
    }
}

enum MediaIntakeInput: String { case selectedFiles = "selected_files", tsv, explicitMetadata = "explicit_metadata" }
enum MediaIntakeValueSource { case column(MediaReviewID), stem, sourceIndex, stemToken(delimiter: String, index: Int) }
struct MediaIntakeAssignment { let fieldID: MediaReviewID; let source: MediaIntakeValueSource }
struct MediaIntakePlan {
    let input: MediaIntakeInput
    let assignments: [MediaIntakeAssignment]
    static func parse(_ raw: [String: Any], schema: MediaReviewSchema) throws -> Self {
        typealias V = MediaConfigurationValue
        try V.keys(raw, ["input", "assignments", "candidate_grouping"], "intake")
        guard let input = MediaIntakeInput(rawValue: try V.text(raw["input"], max: 32, "intake.input")) else { throw MediaSchemaError.invalid("intake.input", "unsupported input") }
        if let grouping = raw["candidate_grouping"] {
            guard let grouping = grouping as? String, grouping == "explicit_preview_only" else { throw MediaSchemaError.invalid("intake.candidate_grouping", "requires explicit preview") }
        }
        let assignments = try V.array(raw["assignments"], max: 20, "intake.assignments").map { value -> MediaIntakeAssignment in
            let a = try V.object(value, "assignment"); try V.keys(a, ["field_id", "source"], "assignment")
            let id = try V.id(a["field_id"], "assignment.field_id")
            guard schema.fields.contains(where: { $0.id == id }) else { throw MediaSchemaError.invalid("assignment.field_id", "unknown field") }
            let s = try V.object(a["source"], "source"), kind = try V.text(s["kind"], max: 32, "source.kind")
            let source: MediaIntakeValueSource
            switch kind {
            case "column": try V.keys(s, ["kind", "column_id"], "source"); source = .column(try V.id(s["column_id"], "source.column_id"))
            case "stem": try V.keys(s, ["kind"], "source"); source = .stem
            case "source_index": try V.keys(s, ["kind"], "source"); source = .sourceIndex
            case "stem_token":
                try V.keys(s, ["kind", "delimiter", "index"], "source")
                let delimiter = try V.text(s["delimiter"], max: 32, "source.delimiter")
                guard !delimiter.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw MediaSchemaError.invalid("source.delimiter", "control delimiter") }
                source = .stemToken(delimiter: delimiter, index: try V.integer(s["index"], max: 63, "source.index"))
            default: throw MediaSchemaError.invalid("source.kind", "unsupported finite mapping")
            }
            if input != .selectedFiles { switch source { case .stem, .stemToken: throw MediaSchemaError.invalid("source", "stem mapping requires selected-file metadata"); default: break } }
            return MediaIntakeAssignment(fieldID: id, source: source)
        }
        guard Set(assignments.map(\.fieldID)).count == assignments.count else { throw MediaSchemaError.invalid("intake.assignments", "ambiguous field assignment") }
        return Self(input: input, assignments: assignments)
    }
    func map(_ rows: [MediaIntakeSourceRow], schema: MediaReviewSchema) throws -> [MediaIntakeMappedRow] {
        guard rows.count <= 1_000, Set(rows.map(\.id)).count == rows.count else { throw MediaSchemaError.invalid("rows", "oversized or duplicate row identities") }
        return try rows.map { row in
            try row.validate()
            var metadata: [MediaReviewID: MediaMetadataValue] = [:], errors: [MediaIntakeDiagnostic] = []
            for a in assignments {
                let raw: Any?
                switch a.source {
                case .column(let id):
                    let matches = row.columns.filter { $0.id == id }
                    if matches.count > 1 { errors.append(.init(fieldID: a.fieldID, reason: .ambiguousColumn)); continue }
                    raw = matches.first?.value
                case .stem: raw = row.stem
                case .sourceIndex: raw = row.sourceIndex
                case let .stemToken(delimiter, index):
                    let tokens = row.stem.map { Self.tokens($0, delimiter: delimiter) } ?? []
                    raw = index < tokens.count ? tokens[index] : nil
                }
                guard let raw, !(raw is NSNull), (raw as? String)?.isEmpty != true else { errors.append(.init(fieldID: a.fieldID, reason: .missingValue)); continue }
                do {
                    guard let field = schema.fields.first(where: { $0.id == a.fieldID }) else { throw MediaSchemaError.invalid("field", "unknown field") }
                    let value: Any
                    if let s = raw as? String, field.kind == .number {
                        guard let n = Double(s), n.isFinite else { throw MediaSchemaError.invalid("value", "invalid numeric literal") }; value = n
                    } else if let s = raw as? String, field.kind == .boolean {
                        guard s == "true" || s == "false" else { throw MediaSchemaError.invalid("value", "invalid Boolean literal") }; value = s == "true"
                    } else if case .sourceIndex = a.source, field.kind == .shortText || field.kind == .longText { value = String(row.sourceIndex) }
                    else { value = raw }
                    metadata[a.fieldID] = try schema.validateValue(value, fieldID: a.fieldID)
                } catch { errors.append(.init(fieldID: a.fieldID, reason: .invalidValue)) }
            }
            for field in schema.fields where field.required && metadata[field.id] == nil && !errors.contains(where: { $0.fieldID == field.id }) { errors.append(.init(fieldID: field.id, reason: .missingValue)) }
            return MediaIntakeMappedRow(id: row.id, metadata: metadata, diagnostics: errors)
        }
    }
    private static func tokens(_ stem: String, delimiter: String) -> [String] {
        let bytes = Array(stem.utf8), separator = Array(delimiter.utf8)
        var result: [String] = [], start = 0, index = 0
        while index + separator.count <= bytes.count {
            if bytes[index..<(index + separator.count)].elementsEqual(separator) {
                result.append(String(decoding: bytes[start..<index], as: UTF8.self)); index += separator.count; start = index
            } else { index += 1 }
        }
        result.append(String(decoding: bytes[start...], as: UTF8.self)); return result
    }
}
struct MediaIntakeColumn { let id: MediaReviewID; let value: Any }
struct MediaIntakeSourceRow {
    let id: MediaReviewID
    let sourceIndex: Int
    let stem: String?
    let columns: [MediaIntakeColumn]
    func validate() throws {
        guard (0..<1_000).contains(sourceIndex), stem == nil || stem!.utf8.count <= 4_096, columns.count <= 64 else { throw MediaSchemaError.invalid("row", "input bounds exceeded") }
        for column in columns {
            guard column.value is NSNull || column.value is NSNumber || (column.value as? String).map({ $0.utf8.count <= 65_536 }) == true else { throw MediaSchemaError.invalid("row.column", "expected bounded scalar") }
        }
    }
    /// Literal TSV: no CSV quoting/formulas. Stable row IDs come from the caller, never content deduplication.
    static func tsv(_ text: String, rowIDs: [MediaReviewID]) throws -> [Self] {
        guard text.utf8.count <= 4 * 1_024 * 1_024 else { throw MediaSchemaError.invalid("tsv", "input byte limit") }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty, lines.count <= 1_001 else { throw MediaSchemaError.invalid("tsv", "row limit") }
        func cells(_ line: String) -> [String] { (line.hasSuffix("\r") ? String(line.dropLast()) : line).components(separatedBy: "\t") }
        let header = try cells(lines.removeFirst()).map { try MediaReviewID($0) }
        guard !header.isEmpty, header.count <= 64, rowIDs.count == lines.count, Set(rowIDs).count == rowIDs.count else { throw MediaSchemaError.invalid("tsv", "header or row identities invalid") }
        return try lines.enumerated().map { index, line in
            let values = cells(line)
            guard values.count <= header.count else { throw MediaSchemaError.invalid("tsv.row", "unmapped extra columns") }
            let row = Self(id: rowIDs[index], sourceIndex: index, stem: nil, columns: header.enumerated().map { .init(id: $0.element, value: $0.offset < values.count ? values[$0.offset] : "") })
            try row.validate(); return row
        }
    }
}
struct MediaIntakeDiagnostic: Equatable {
    enum Reason: String { case missingValue, ambiguousColumn, invalidValue }
    let fieldID: MediaReviewID
    let reason: Reason
}
struct MediaIntakeMappedRow { let id: MediaReviewID; let metadata: [MediaReviewID: MediaMetadataValue]; let diagnostics: [MediaIntakeDiagnostic] }

/// Value-only resume planning, not a capture receipt. Successful targets are never remapped or merged.
struct FrozenMediaIntake {
    enum Capture: Equatable { case uncaptured, failed, captured(MediaReviewID) }
    struct Row { let source: MediaIntakeSourceRow; let mapped: MediaIntakeMappedRow; let mappingRevision: Int; var capture: Capture }
    let id: MediaReviewID
    let revision: Int
    private(set) var rows: [Row]
    init(id: MediaReviewID, plan: MediaIntakePlan, sources: [MediaIntakeSourceRow], schema: MediaReviewSchema) throws {
        self.id = id; revision = 1
        rows = try zip(sources, plan.map(sources, schema: schema)).map { Row(source: $0.0, mapped: $0.1, mappingRevision: 1, capture: .uncaptured) }
    }
    private init(id: MediaReviewID, revision: Int, rows: [Row]) { self.id = id; self.revision = revision; self.rows = rows }
    var remainingRowIDs: [MediaReviewID] { rows.filter { if case .captured = $0.capture { return false }; return true }.map { $0.source.id } }
    mutating func record(_ capture: Capture, rowID: MediaReviewID) throws {
        guard let index = rows.firstIndex(where: { $0.source.id == rowID }) else { throw MediaSchemaError.invalid("row_id", "unknown row") }
        if case .captured = rows[index].capture { guard rows[index].capture == capture else { throw MediaSchemaError.invalid("capture", "captured row is immutable") }; return }
        if case .captured = capture, !rows[index].mapped.diagnostics.isEmpty { throw MediaSchemaError.invalid("capture", "mapping errors remain") }
        rows[index].capture = capture
    }
    func revising(plan: MediaIntakePlan, schema: MediaReviewSchema) throws -> Self {
        guard revision < Int.max else { throw MediaSchemaError.invalid("revision", "overflow") }
        let pending = rows.filter { if case .captured = $0.capture { return false }; return true }
        var byID = Dictionary(uniqueKeysWithValues: try plan.map(pending.map(\.source), schema: schema).map { ($0.id, $0) })
        return Self(id: id, revision: revision + 1, rows: rows.map { row in
            guard let value = byID.removeValue(forKey: row.source.id) else { return row }
            return Row(source: row.source, mapped: value, mappingRevision: revision + 1, capture: .uncaptured)
        })
    }
}
