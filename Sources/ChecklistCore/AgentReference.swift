import Foundation
import GRDB

/// Display metadata is never service instruction text. Keep IDs in structured tool arguments.
public enum AgentReference {
    public static func sanitized(_ value: String, maximumCharacters: Int = 160, maximumUTF8Bytes: Int = 640) -> String {
        var scalars = String.UnicodeScalarView(), bytes = 0
        for scalar in value.unicodeScalars {
            if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format || scalar == "\u{2028}" || scalar == "\u{2029}" { continue }
            guard bytes + scalar.utf8.count <= maximumUTF8Bytes else { break }
            scalars.append(scalar); bytes += scalar.utf8.count
        }
        return String(String(scalars).prefix(maximumCharacters))
    }
    public static func quoted(_ value: String) -> String {
        let bytes = try! JSONSerialization.data(withJSONObject:sanitized(value), options:[.fragmentsAllowed,.withoutEscapingSlashes])
        // Keep display metadata literal when the same text passes through ordinary mention parsing.
        return String(decoding:bytes,as:UTF8.self).replacingOccurrences(of:"@",with:"\\u0040")
    }
    public static func text(key: String?, title: String, projectName: String? = nil) -> String {
        let key = sanitized(key ?? "",maximumCharacters:80,maximumUTF8Bytes:320)
        // Safe ordinary keys retain their familiar form. Hostile/custom keys are JSON strings too.
        let label = key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) } ? key : quoted(key)
        let reference = (label.isEmpty ? "" : label + " ") + quoted(title)
        return projectName.map { "project " + quoted($0) + ": " + reference } ?? reference
    }
    public static func text(_ record: [String:Any], projectName: String? = nil) -> String {
        text(key:record["key"] as? String,title:record["title"] as? String ?? record["name"] as? String ?? "",projectName:projectName)
    }
}

extension CommandRouter {
    func agentReference(_ db: Database, _ record: JSON) throws -> String {
        let project = try self.record(db,record["project_id"] as! String,type:"project")
        return AgentReference.text(record,projectName:project["name"] as? String)
    }
    func subject(_ db: Database, message: JSON) throws -> JSON {
        let pid = message["project_id"] as! String, project = try record(db,pid,type:"project")
        var source = project, kind = "project", subjectID = pid
        if let id = message["triage_id"] as? String ?? message["epic_id"] as? String {
            subjectID = id;kind = message["triage_id"] is String ? "triage" : "epic"
            source = (try? scoped(db,id,pid,type:"group")) ?? [:]
        } else if let id = message["task_id"] as? String {
            subjectID = id;kind = "ticket";source = (try? scoped(db,id,pid,type:"task")) ?? [:]
        }
        return ["kind":kind,"id":subjectID,"key":source["key"] ?? NSNull(),"title":source["title"] ?? source["name"] ?? "","project_id":pid,"project_name":project["name"] ?? ""]
    }
}
