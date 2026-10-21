import Foundation
import GRDB

/// Additive JSON enrichment, under the bootstrap object gate and one SQL transaction.
/// Old readers/writers accept these fields; rerun after an old writer creates a group.
enum GroupKeys {
    static func counter(_ kind: String) -> String { kind == "triage" ? "next_triage_number" : "next_epic_number" }
    static func marker(_ kind: String) -> String { kind == "triage" ? "T" : "E" }
    static func next(_ project: JSON, groups: [JSON], kind: String) throws -> Int {
        var number = max(1,int(project,counter(kind),default:1))
        for group in groups where group["kind"] as? String == kind {
            guard let key = group["key"] as? String, let range = key.range(of:"-" + marker(kind),options:[.backwards,.caseInsensitive]),let used = Int(key[range.upperBound...]),used > 0 else { continue }
            guard used < Int.max else { throw CoreError("CAPACITY_EXCEEDED","The project group number range is exhausted.") }
            number = max(number,used + 1)
        }
        guard number < Int.max else { throw CoreError("CAPACITY_EXCEEDED","The project group number range is exhausted.") }
        return number
    }
    static func backfill(_ db: Database) throws {
        let projects = try Row.fetchAll(db,sql:"SELECT " + CommandRouter.canonicalRecordColumns + " FROM records WHERE type='project'").map {try GRDBRecordEnvelopeAdapter.decode($0,expectedType:"project").object}
        func save(_ value: JSON) throws {
            try db.execute(sql:"UPDATE records SET data=CAST(? AS TEXT),revision=? WHERE id=CAST(? AS TEXT)",arguments:[Data(try jsonString(value).utf8),int(value,"revision"),Data((value["id"] as! String).utf8)])
        }
        for var project in projects {
            let groups = try Row.fetchAll(db,sql:"SELECT " + CommandRouter.canonicalRecordColumns + " FROM records WHERE type='group' AND project_id=CAST(? AS TEXT)",arguments:[Data((project["id"] as! String).utf8)]).map {try GRDBRecordEnvelopeAdapter.decode($0,expectedType:"group").object}
            let original = try jsonString(project)
            for kind in ["triage","epic"] {
                var number = try next(project,groups:groups,kind:kind)
                let missing = groups.filter {$0["kind"] as? String == kind && ($0["key"] as? String ?? "").isEmpty}.sorted {
                    let a = $0["created_at"] as? String ?? "", b = $1["created_at"] as? String ?? ""
                    return a.utf8.elementsEqual(b.utf8) ? ($0["id"] as! String).utf8.lexicographicallyPrecedes(($1["id"] as! String).utf8) : a.utf8.lexicographicallyPrecedes(b.utf8)
                }
                for var group in missing {
                    guard number < Int.max else { throw CoreError("CAPACITY_EXCEEDED","The project group number range is exhausted.") }
                    group["key"] = "\(project["key_prefix"] as? String ?? "TASK")-\(marker(kind))\(number)"
                    group["revision"] = int(group,"revision") + 1
                    try save(group);number += 1
                }
                project[counter(kind)] = number
            }
            if try jsonString(project) != original { project["revision"] = int(project,"revision") + 1;try save(project) }
        }
    }
}
