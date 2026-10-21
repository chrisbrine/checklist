import Foundation
import CoreFoundation
import GRDB

/// Optional observations, never completion gates. Names and units identify a series;
/// changing either starts a different series rather than implying a unit conversion.
struct EvidenceMeasure {
    let name: String
    let unit: String
    let limit: Double
    let before: Double
    let after: Double
    var overLimit: Bool { after > limit }
    var json: JSON { ["name":name,"unit":unit,"limit":limit,"before":before,"after":after] }

    static func parse(_ raw: Any?) throws -> [Self] {
        guard let raw else { return [] }
        guard let rows = raw as? [JSON],rows.count <= 100 else { throw CoreError("INVALID_INPUT","Measures must be a list of at most 100 named numeric observations.") }
        var names = Set<String>()
        return try rows.map { row in
            guard Set(row.keys) == ["name","unit","limit","before","after"] else { throw CoreError("INVALID_INPUT","Each measure needs exactly name, unit, limit, before and after.") }
            let name = try text(row,"name",max:200),unit = try text(row,"unit",max:80)
            guard name == name.trimmingCharacters(in:.whitespacesAndNewlines),unit == unit.trimmingCharacters(in:.whitespacesAndNewlines),
                  !name.unicodeScalars.contains(where:CharacterSet.controlCharacters.union(.newlines).contains),!unit.unicodeScalars.contains(where:CharacterSet.controlCharacters.union(.newlines).contains),names.insert(name).inserted else {
                throw CoreError("INVALID_INPUT","Measure names must be unique, with nonblank single-line names and units and no surrounding whitespace.")
            }
            func number(_ key: String) throws -> Double {
                guard let n = row[key] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else { throw CoreError("INVALID_INPUT","Measure \(key) must be a finite JSON number, not a boolean or text.") }
                if !["d","f"].contains(String(cString:n.objCType)),String(format:"%.0f",locale:Locale(identifier:"en_US_POSIX"),n.doubleValue) != n.stringValue {
                    throw CoreError("INVALID_INPUT","Measure \(key) loses integer precision. Scale the value and its unit explicitly.")
                }
                return n.doubleValue
            }
            return try Self(name:name,unit:unit,limit:number("limit"),before:number("before"),after:number("after"))
        }
    }

    static var schema: JSON {
        ["type":"array","maxItems":100,"items":["type":"object","properties":["name":["type":"string","minLength":1,"maxLength":200],"unit":["type":"string","minLength":1,"maxLength":80],"limit":["type":"number"],"before":["type":"number"],"after":["type":"number"]],"required":["name","unit","limit","before","after"],"additionalProperties":false]]
    }
}

extension CommandRouter {
    /// Presentation history is separate from the selected ticket's current
    /// actionable records. Loading a comparison cannot grant historical authority.
    func evidenceMeasureHistory(_ db: Database,task: JSON,caller: Caller) throws -> JSON {
        let manifests = try scopedTaskRows(db,type:"manifest",task:task,limit:2,descending:true).reversed().map { contextRecord($0,type:"manifest",caller:caller) }
        let attempts = try scopedTaskRows(db,type:"attempt",task:task,predicate:"json_extract(data,'$.phase')='review'",limit:13,descending:true)
        let ids = try jsonString(attempts.prefix(12).compactMap { $0["id"] as? String })
        let reports = try scopedTaskRows(db,type:"attachment",task:task,predicate:"json_type(data,'$.measures')='array' AND json_extract(data,'$.review_attempt_id') IN (SELECT value FROM json_each(?))",arguments:[ids],limit:101,descending:true)
        return ["manifests":manifests,"attempts":attempts.prefix(12).reversed().map { contextRecord($0,type:"attempt",caller:caller) },"attachments":reports.prefix(100).reversed().map { contextRecord($0,type:"attachment",caller:caller) },"truncated":attempts.count > 12 || reports.count > 100]
    }

    func normalizedEvidenceMeasures(_ evidence: inout JSON) throws {
        if evidence["measures"] != nil { evidence["measures"] = try EvidenceMeasure.parse(evidence["measures"]).map(\.json) }
    }

    /// Reviewer report bytes include the same structured observations as the metadata,
    /// so the report's ordinary immutable SHA-256 covers the measurements too.
    func measuredReportBody(_ body: String, measures: [EvidenceMeasure]) throws -> String {
        guard !measures.isEmpty else { return body }
        return body + "\n\nRecorded measures (upper limits; advisory):\n" + (try jsonString(measures.map(\.json))) + "\n"
    }

    func evidenceMeasuresContext(_ db: Database,task: JSON) throws -> JSON {
        let manifests = try scopedTaskRows(db,type:"manifest",task:task,limit:101,descending:true)
        let reports = try scopedTaskRows(db,type:"attachment",task:task,predicate:"json_type(data,'$.measures')='array'",limit:101,descending:true)
        let current = task["current_manifest_id"] as? String
        var snapshots: [JSON] = []
        for manifest in manifests.prefix(100) {
            let measures = (manifest["evidence"] as? JSON)?["measures"] as? [JSON] ?? []
            if !measures.isEmpty { snapshots.append(["source":"submission","manifest_id":manifest["id"]!,"source_id":manifest["id"]!,"created_at":manifest["created_at"] ?? "","measures":measures]) }
        }
        for report in reports.prefix(100) {
            guard let mid = report["target_manifest_id"] as? String,report["review_attempt_id"] is String else { continue }
            snapshots.append(["source":"review_report","manifest_id":mid,"source_id":report["id"]!,"name":report["name"] ?? "","author":report["author"] ?? "","review_attempt_id":report["review_attempt_id"]!,"sha256":report["sha256"] ?? "","created_at":report["created_at"] ?? "","measures":report["measures"] ?? []])
        }
        let warnings = snapshots.filter { $0["manifest_id"] as? String == current }.flatMap { snapshot -> [JSON] in
            ((try? EvidenceMeasure.parse(snapshot["measures"])) ?? []).filter(\.overLimit).map { measure in
                ["name":measure.name,"unit":measure.unit,"after":measure.after,"limit":measure.limit,"source_id":snapshot["source_id"]!,"manifest_id":snapshot["manifest_id"]!]
            }
        }
        return ["snapshots":snapshots,"warnings":warnings,"truncated":manifests.count > 100 || reports.count > 100,"advisory_only":true]
    }
}
