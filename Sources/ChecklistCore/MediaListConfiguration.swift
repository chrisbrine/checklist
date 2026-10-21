import Foundation
import CoreFoundation

struct MediaListConfiguration {
    enum Key: Hashable { case field(MediaReviewID), title, order }
    enum Order: String { case ascending, descending, declaredChoiceOrder = "declared_choice_order" }
    struct Sort { let key: Key; let order: Order }
    let visibleColumns: [MediaReviewID]
    let groupBy: [MediaReviewID]
    let sort: [Sort]
    static func parse(_ raw: [String: Any], schema: MediaReviewSchema) throws -> Self {
        typealias V = MediaConfigurationValue
        try V.keys(raw, ["visible_columns", "group_by", "sort"], "list")
        let columns = try V.ids(raw["visible_columns"], max: 8, "list.visible_columns")
        let groups = try V.ids(raw["group_by"], max: 2, "list.group_by")
        let known = Set(schema.fields.map(\.id))
        guard Set(columns + groups).isSubset(of: known) else { throw MediaSchemaError.invalid("list", "unknown field") }
        let sort = try V.array(raw["sort"], max: 3, "list.sort").map { value -> Sort in
            let s = try V.object(value, "sort"); try V.keys(s, ["field_id", "key", "order"], "sort")
            let key: Key
            if let id = s["field_id"] {
                let id = try V.id(id, "sort.field_id")
                guard s["key"] == nil, known.contains(id) else { throw MediaSchemaError.invalid("sort", "ambiguous or unknown field") }; key = .field(id)
            } else {
                switch s["key"] as? String { case "title": key = .title; case "order": key = .order; default: throw MediaSchemaError.invalid("sort.key", "unknown key") }
            }
            guard let order = Order(rawValue: try V.text(s["order"] ?? "ascending",max:32,"sort.order")) else { throw MediaSchemaError.invalid("sort.order", "unknown order") }
            if order == .declaredChoiceOrder {
                guard case .field(let id) = key, schema.fields.contains(where: { $0.id == id && $0.kind == .choice }) else { throw MediaSchemaError.invalid("sort.order", "requires choice field") }
            }
            return Sort(key: key, order: order)
        }
        guard Set(sort.map(\.key)).count == sort.count else { throw MediaSchemaError.invalid("list.sort", "duplicate sort key") }
        return Self(visibleColumns: columns, groupBy: groups, sort: sort)
    }
    /// Flat headers/rows for a later paged adapter. Missing group values have their own final bucket.
    func project(_ rows: [MediaListItem], schema: MediaReviewSchema) throws -> [MediaListEntry] {
        guard rows.count <= 1_000, Set(rows.map(\.id)).count == rows.count else { throw MediaSchemaError.invalid("list.rows", "oversized or ambiguous IDs") }
        for row in rows {
            guard row.title.utf8.count <= 4_096, (0...1_000_000).contains(row.order), row.metadata.count <= 20 else { throw MediaSchemaError.invalid("list.row", "row bounds") }
            for (id, value) in row.metadata {
                let raw: Any
                switch value { case .text(let v): raw = v; case .number(let v): raw = v; case .boolean(let v): raw = v; case .choice(let v): raw = v.rawValue }
                guard try schema.validateValue(raw, fieldID: id) == value else {
                    throw MediaSchemaError.invalid("list.row.metadata." + id.rawValue, "metadata tag does not match declared field type")
                }
            }
        }
        func comparison(_ a: MediaMetadataValue?, _ b: MediaMetadataValue?, field: MediaReviewID, choiceOrder: Bool) -> Int {
            switch (a,b) {
            case (nil,nil): return 0
            case (nil,_): return 1
            case (_,nil): return -1
            case let (.text(a)?, .text(b)?): return Self.bytes(a,b)
            case let (.number(a)?, .number(b)?): return a == b ? 0 : (a < b ? -1 : 1)
            case let (.boolean(a)?, .boolean(b)?): return a == b ? 0 : (a ? 1 : -1)
            case let (.choice(a)?, .choice(b)?):
                if choiceOrder, let choices = schema.fields.first(where: { $0.id == field })?.choices, let i = choices.firstIndex(of:a), let j = choices.firstIndex(of:b) { return i == j ? 0 : (i < j ? -1 : 1) }
                return a == b ? 0 : (a < b ? -1 : 1)
            default: return 0 // Values were checked against one declared field above.
            }
        }
        let sorted = rows.sorted { a,b in
            for field in groupBy {
                let value = comparison(a.metadata[field],b.metadata[field],field:field,choiceOrder:true)
                if value != 0 { return value < 0 }
            }
            for sort in sort {
                let value: Int
                switch sort.key {
                case .field(let id):
                    // Missing values remain last even for descending display order.
                    if a.metadata[id] == nil || b.metadata[id] == nil {
                        let missing = comparison(a.metadata[id],b.metadata[id],field:id,choiceOrder:false)
                        if missing != 0 { return missing < 0 }
                    }
                    value = comparison(a.metadata[id],b.metadata[id],field:id,choiceOrder:sort.order == .declaredChoiceOrder)
                case .title: value = Self.bytes(a.title,b.title)
                case .order: value = a.order == b.order ? 0 : (a.order < b.order ? -1 : 1)
                }
                if value != 0 { return sort.order == .descending ? value > 0 : value < 0 }
            }
            return a.id < b.id
        }
        var entries: [MediaListEntry] = []
        func append(_ range: ArraySlice<MediaListItem>, level: Int) {
            guard level < groupBy.count else { entries += range.map(MediaListEntry.item); return }
            let field = groupBy[level]
            var start = range.startIndex
            while start < range.endIndex {
                let value = range[start].metadata[field]; var end = start + 1
                while end < range.endIndex && comparison(range[end].metadata[field],value,field:field,choiceOrder:true) == 0 { end += 1 }
                entries.append(.group(level:level,fieldID:field,value:value,itemCount:end-start))
                append(range[start..<end],level:level+1); start = end
            }
        }
        append(sorted[...],level:0); return entries
    }
    private static func bytes(_ a: String,_ b: String) -> Int { let a = Data(a.utf8),b = Data(b.utf8); return a == b ? 0 : (a.lexicographicallyPrecedes(b) ? -1 : 1) }
}
struct MediaListItem { let id: MediaReviewID; let title: String; let order: Int; let metadata: [MediaReviewID: MediaMetadataValue] }
enum MediaListEntry { case group(level: Int, fieldID: MediaReviewID, value: MediaMetadataValue?, itemCount: Int), item(MediaListItem) }

/// A request descriptor only: a later service resolves current owner decisions and read authority.
/// Constructing or showing one supplies neither bytes, approval nor material meaning.
struct MediaHistoricalExamples {
    enum Selection { case matching([MediaReviewID]), explicitTargets([MediaReviewID]) }
    let enabled: Bool
    let selection: Selection
    let pageSize: Int
    static func parse(_ raw: [String: Any], schema: MediaReviewSchema) throws -> Self {
        typealias V = MediaConfigurationValue
        try V.keys(raw,["enabled","match_fields","target_ids","page_size"],"examples")
        guard let enabled = raw["enabled"] as? Bool, let number = raw["enabled"] as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { throw MediaSchemaError.invalid("examples.enabled","expected Boolean") }
        guard raw["match_fields"] == nil || raw["target_ids"] == nil else { throw MediaSchemaError.invalid("examples","choose one selection") }
        let selection: Selection
        if raw["target_ids"] != nil { selection = .explicitTargets(try V.ids(raw["target_ids"],max:8,"examples.target_ids")) }
        else {
            let fields = try V.ids(raw["match_fields"],max:3,"examples.match_fields")
            guard Set(fields).isSubset(of:Set(schema.fields.map(\.id))) else { throw MediaSchemaError.invalid("examples.match_fields","unknown field") }
            selection = .matching(fields)
        }
        return Self(enabled:enabled,selection:selection,pageSize:try V.integer(raw["page_size"] ?? 8,min:1,max:8,"examples.page_size"))
    }
    func request(expanded: Bool, projectID: MediaReviewID, typeID: MediaReviewID) -> MediaHistoricalExampleRequest? {
        guard enabled,expanded else { return nil }
        return .init(projectID:projectID,typeID:typeID,selection:selection,pageSize:pageSize)
    }
}
struct MediaHistoricalExampleRequest {
    let projectID: MediaReviewID
    let typeID: MediaReviewID
    let selection: MediaHistoricalExamples.Selection
    let pageSize: Int
    let displayOnly = true
    let requiresCurrentAuthorization = true
    let historicalContextLabelRequired = true
}

/// Explicit adoption value, still without authority. The future publication writer must validate
/// its exact immutable target and context. These bytes join that item's basis, unlike display config.
struct MediaMaterialReference {
    let projectID: MediaReviewID
    let typeID: MediaReviewID
    let targetID: MediaReviewID
    let sha256: String
    let slotID: MediaReviewID
    init(projectID: MediaReviewID, typeID: MediaReviewID, targetID: MediaReviewID, sha256: String,
         slotID: MediaReviewID, kind: MediaSlotKind, schema: MediaReviewSchema) throws {
        guard schema.id == typeID, schema.slots.contains(where: { $0.id == slotID && $0.material && $0.kind == kind }),
              sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw MediaSchemaError.invalid("reference","expected exact target and compatible material slot") }
        self.projectID = projectID;self.typeID = typeID;self.targetID = targetID;self.sha256 = sha256;self.slotID = slotID
    }
    var basisContribution: Data {
        var bytes = Data()
        for value in ["checklist.media.material-reference.v1",projectID.rawValue,typeID.rawValue,targetID.rawValue,sha256,slotID.rawValue] {
            bytes.append(contentsOf:String(value.utf8.count).utf8);bytes.append(58);bytes.append(contentsOf:value.utf8)
        }
        return bytes
    }
}
