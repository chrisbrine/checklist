import Foundation
import GRDB

extension CommandRouter {
    func requiredEpicID(_ db: Database,project: String,value: Any?) throws -> String {
        do { return try requiredEpicID(value) }
        catch {
            let epics = try records(db,type:"group",project:project).filter {$0["kind"] as? String == "epic" && !bool($0,"archived")}.map { ["id":$0["id"]!,"key":$0["key"] ?? "","name":$0["name"] ?? ""] as JSON }
            let names = epics.map {AgentReference.text($0)}.joined(separator:", ")
            throw CoreError("EPIC_REQUIRED",epics.isEmpty ? "Create an Epic for this ticket before capturing it." : "Choose a primary Epic for this ticket. Available Epics: " + names,details:["epics":epics])
        }
    }

    func requiredEpicID(_ value: Any?) throws -> String {
        guard let id = value as? String,!id.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            throw CoreError("EPIC_REQUIRED","Choose a primary Epic for this ticket.")
        }
        return id
    }
}
