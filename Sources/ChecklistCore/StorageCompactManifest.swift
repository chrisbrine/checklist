import Foundation

// Format 2 retains every descriptor, but interns content and prefix-compresses
// repeated paths/authority strings. Format 3 also prefix-compresses the sorted
// unavailable list (CL-387). Format 1 remains the original JSON array.
extension StorageSnapshotManifest {
    private enum CodingKeys: String, CodingKey {
        case format, kind, operationID, storeID, sourceRoot, schema, databaseSHA256, databaseSize
        case objects, unavailable, externalReferences, recordFamilies, tableRows, capturedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(Int.self, forKey: .format)
        guard [1, 2, 3].contains(format) else { throw StorageSnapshotFailure.incomplete }
        kind = try c.decode(String.self, forKey: .kind)
        operationID = try c.decode(String.self, forKey: .operationID)
        storeID = try c.decode(String.self, forKey: .storeID)
        sourceRoot = try c.decode(String.self, forKey: .sourceRoot)
        schema = try c.decode(Int.self, forKey: .schema)
        databaseSHA256 = try c.decode(String.self, forKey: .databaseSHA256)
        databaseSize = try c.decode(Int64.self, forKey: .databaseSize)
        objects = format == 1 ? try c.decode([StorageSnapshotMaterializedObject].self, forKey: .objects)
            : try c.decode(StorageSnapshotObjectTable.self, forKey: .objects).materialized()
        unavailable = format >= 3 ? try c.decode(StorageSnapshotAbsenceTable.self, forKey: .unavailable).materialized()
            : try c.decode([StorageSnapshotAbsence].self, forKey: .unavailable)
        externalReferences = try c.decode([String].self, forKey: .externalReferences)
        recordFamilies = try c.decodeIfPresent([String:Int].self, forKey: .recordFamilies)
        tableRows = try c.decodeIfPresent([String:Int].self, forKey: .tableRows)
        capturedAt = try c.decodeIfPresent(String.self, forKey: .capturedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        guard [1, 2, 3].contains(format) else { throw StorageSnapshotFailure.incomplete }
        try c.encode(format, forKey: .format); try c.encode(kind, forKey: .kind)
        try c.encode(operationID, forKey: .operationID); try c.encode(storeID, forKey: .storeID)
        try c.encode(sourceRoot, forKey: .sourceRoot); try c.encode(schema, forKey: .schema)
        try c.encode(databaseSHA256, forKey: .databaseSHA256); try c.encode(databaseSize, forKey: .databaseSize)
        if format == 1 { try c.encode(objects, forKey: .objects) }
        else { try c.encode(StorageSnapshotObjectTable(objects), forKey: .objects) }
        if format >= 3 { try c.encode(StorageSnapshotAbsenceTable(unavailable), forKey: .unavailable) }
        else { try c.encode(unavailable, forKey: .unavailable) }
        try c.encode(externalReferences, forKey: .externalReferences)
        try c.encodeIfPresent(recordFamilies, forKey: .recordFamilies); try c.encodeIfPresent(tableRows, forKey: .tableRows)
        try c.encodeIfPresent(capturedAt, forKey: .capturedAt)
    }
}

/// Each row is [reason index, bytes shared with the previous authority, the other bytes].
private struct StorageSnapshotAbsenceTable: Codable {
    struct Row: Codable {
        let reason: Int
        let bytes: Int
        let suffix: String
        init(_ reason: Int, _ bytes: Int, _ suffix: String) { self.reason = reason; self.bytes = bytes; self.suffix = suffix }
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            reason = try c.decode(Int.self); bytes = try c.decode(Int.self); suffix = try c.decode(String.self)
            guard c.isAtEnd else { throw StorageSnapshotFailure.incomplete }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer(); try c.encode(reason); try c.encode(bytes); try c.encode(suffix)
        }
    }
    let reasons: [String]
    let entries: [Row]

    init(_ absences: [StorageSnapshotAbsence]) {
        var indices: [String:Int] = [:], names: [String] = [], rows: [Row] = [], previous = Data()
        rows.reserveCapacity(absences.count)
        for absence in absences {
            let reason: Int
            if let known = indices[absence.reason] { reason = known }
            else { reason = names.count; indices[absence.reason] = reason; names.append(absence.reason) }
            let value = Data(absence.authority.utf8)
            var n = zip(previous, value).prefix { $0 == $1 }.count
            // Prefix length counts UTF-8 bytes and must end at a scalar boundary.
            while n < value.count && n > 0 && value[n] & 0xc0 == 0x80 { n -= 1 }
            rows.append(.init(reason, n, String(decoding: value.dropFirst(n), as: UTF8.self))); previous = value
        }
        reasons = names; entries = rows
    }

    func materialized() throws -> [StorageSnapshotAbsence] {
        var previous = Data(), absences: [StorageSnapshotAbsence] = []
        absences.reserveCapacity(entries.count)
        for row in entries {
            guard reasons.indices.contains(row.reason), row.bytes >= 0, row.bytes <= previous.count else { throw StorageSnapshotFailure.incomplete }
            var value = Data(previous.prefix(row.bytes)); value.append(contentsOf: row.suffix.utf8)
            guard let authority = String(data: value, encoding: .utf8) else { throw StorageSnapshotFailure.incomplete }
            absences.append(.init(authority: authority, reason: reasons[row.reason])); previous = value
        }
        return absences
    }
}

private struct StorageSnapshotObjectTable: Codable {
    struct Prefix: Codable {
        let bytes: Int
        let suffix: String
        init(_ bytes: Int, _ suffix: String) { self.bytes = bytes; self.suffix = suffix }
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            bytes = try c.decode(Int.self); suffix = try c.decode(String.self)
            guard c.isAtEnd else { throw StorageSnapshotFailure.incomplete }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer(); try c.encode(bytes); try c.encode(suffix)
        }
    }
    let strings: [Prefix]
    // [SHA string index, size], one row per distinct content.
    let contents: [[Int64]]
    // [path, kind, expected SHA or -1, expected size or -1, executable 0/1,
    //  link target or -1, content index, authority string indices...].
    let entries: [[Int64]]

    init(_ objects: [StorageSnapshotMaterializedObject]) {
        var unique: Set<Data> = []
        for object in objects {
            let d = object.descriptor
            for s in [d.relativePath, d.kind, object.sha256] + d.authorities + [d.expectedSHA256, d.linkTarget].compactMap({ $0 }) {
                unique.insert(Data(s.utf8))
            }
        }
        let values = unique.sorted { $0.lexicographicallyPrecedes($1) }
        let indices = Dictionary(uniqueKeysWithValues: values.enumerated().map { ($0.element, Int64($0.offset)) })
        func index(_ value: String) -> Int64 { indices[Data(value.utf8)]! }
        var previous = Data(), prefixes: [Prefix] = []
        for value in values {
            var n = zip(previous, value).prefix { $0 == $1 }.count
            // Prefix length counts UTF-8 bytes and must end at a scalar boundary.
            while n < value.count && n > 0 && value[n] & 0xc0 == 0x80 { n -= 1 }
            prefixes.append(.init(n, String(decoding: value.dropFirst(n), as: UTF8.self))); previous = value
        }
        strings = prefixes
        var contentIndices: [String:[Int64:Int64]] = [:], contentRows: [[Int64]] = [], rows: [[Int64]] = []
        for object in objects {
            let d = object.descriptor
            let content: Int64
            if let prior = contentIndices[object.sha256]?[object.size] { content = prior }
            else {
                content = Int64(contentRows.count); contentRows.append([index(object.sha256), object.size])
                contentIndices[object.sha256, default: [:]][object.size] = content
            }
            rows.append([index(d.relativePath), index(d.kind), d.expectedSHA256.map(index) ?? -1,
                         d.expectedSize ?? -1, d.executable ? 1 : 0, d.linkTarget.map(index) ?? -1, content] + d.authorities.map(index))
        }
        contents = contentRows; entries = rows
    }

    func materialized() throws -> [StorageSnapshotMaterializedObject] {
        guard entries.count <= StorageSnapshotBudget.objectLimit, contents.count <= entries.count,
              strings.count <= StorageSnapshotBudget.objectLimit * 8 else { throw StorageSnapshotFailure.limit }
        var values: [String] = [], previous = Data(), total = 0
        for prefix in strings {
            guard prefix.bytes >= 0, prefix.bytes <= previous.count else { throw StorageSnapshotFailure.incomplete }
            let bytes = previous.prefix(prefix.bytes) + Data(prefix.suffix.utf8)
            total += bytes.count
            guard total <= 512 * 1_048_576, let value = String(data: bytes, encoding: .utf8) else { throw StorageSnapshotFailure.limit }
            values.append(value); previous = bytes
        }
        func value(_ index: Int64) throws -> String {
            guard index >= 0, index < values.count else { throw StorageSnapshotFailure.incomplete }
            return values[Int(index)]
        }
        func optional(_ index: Int64) throws -> String? { index == -1 ? nil : try value(index) }
        var used: Set<Int64> = []
        let result = try entries.map { row -> StorageSnapshotMaterializedObject in
            guard row.count >= 7, row[3] >= -1, [0, 1].contains(row[4]), row[6] >= 0, row[6] < contents.count else { throw StorageSnapshotFailure.incomplete }
            let content = contents[Int(row[6])]
            guard content.count == 2, content[1] >= 0 else { throw StorageSnapshotFailure.incomplete }
            used.insert(row[6])
            let d = try StorageSnapshotObject(relativePath: value(row[0]), kind: value(row[1]), expectedSHA256: optional(row[2]),
                expectedSize: row[3] == -1 ? nil : row[3], executable: row[4] == 1, linkTarget: optional(row[5]), authorities: row.dropFirst(7).map(value))
            return try .init(descriptor: d, sha256: value(content[0]), size: content[1])
        }
        guard used.count == contents.count else { throw StorageSnapshotFailure.incomplete }
        return result
    }
}
