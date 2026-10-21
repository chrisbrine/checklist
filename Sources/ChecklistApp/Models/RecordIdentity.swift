import Foundation

/// Identity of a preserved record ID, independent of human text equivalence.
/// Do not normalize or reinterpret the original value at presentation boundaries.
struct RecordIdentity: Hashable {
    let bytes: [UInt8]
    init(_ value: String) { bytes = Array(value.utf8) }
}

struct ScopedRecordIdentity: Hashable {
    let project: RecordIdentity
    let record: RecordIdentity
    init(projectID: String, id: String) {
        project = RecordIdentity(projectID)
        record = RecordIdentity(id)
    }
}

/// Keeps exact IDs before a String Set can discard canonically equivalent values.
/// Values are retained only for expansion persistence; no service authority lives here.
struct RecordIdentitySet: Equatable {
    private var valuesByID: [RecordIdentity: String] = [:]
    init(_ values: [String] = []) { for value in values { insert(value) } }
    var count: Int { valuesByID.count }
    var values: [String] { valuesByID.values.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) } }
    func contains(_ value: String) -> Bool { valuesByID[RecordIdentity(value)] != nil }
    mutating func insert(_ value: String) { valuesByID[RecordIdentity(value)] = value }
    mutating func remove(_ value: String) { valuesByID.removeValue(forKey: RecordIdentity(value)) }
    static func == (left: Self, right: Self) -> Bool { Set(left.valuesByID.keys) == Set(right.valuesByID.keys) }
}
