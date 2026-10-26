import Foundation
import CoreFoundation
import GRDB

enum AcceptanceEvidence {
    static var schema: JSON {
        let text: JSON = ["type":"string","minLength":1,"maxLength":4000,"pattern":"\\S"]
        let sha: JSON = ["type":"string","pattern":"^[a-f0-9]{64}$"]
        func ref(_ kind: String,_ fields: JSON) -> JSON {
            var properties = fields;properties["kind"] = ["const":kind]
            return ["type":"object","required":Array(properties.keys).sorted(),"properties":properties,"additionalProperties":false]
        }
        let references = [ref("attachment",["attachment_id":text,"sha256":sha]),ref("check",["name":text]),ref("carried",["producer":text,"target":text,"sha256":sha]),ref("check_runner_report",["attachment_id":text,"sha256":sha,"build_id":text])]
        return ["type":"array","maxItems":100,"description":"Exactly one entry per current acceptance item. Plain items need valid evidence or a stated limitation; installed/native items need a non-contributor report for evidence_manifest.installed_build_id. Owner observations use the trusted app.","items":["type":"object","required":["item"],"properties":["item":["type":"integer","minimum":0,"maximum":99],"evidence_refs":["type":"array","maxItems":100,"items":["oneOf":references]],"limitation":["type":"string","minLength":1,"maxLength":16000,"pattern":"\\S"],"observation":["type":"string","enum":["installed","native","owner"]]],"additionalProperties":false]]
    }
}

extension CommandRouter {
    /// Submission coverage is an evidence index, not a review verdict. Recheck in the
    /// transaction even when preparation already refused uncovered source-copy plans.
    func normalizedAcceptanceEvidence(_ db: Database,params: JSON,evidence: JSON,task: JSON,attempt: JSON,caller: Caller) throws -> [JSON]? {
        guard !caller.isOwner else { return nil }
        let acceptance = strings(task,"acceptance")
        guard !acceptance.isEmpty else { return [] }
        let raw: [JSON]
        if let value = params["acceptance_evidence"] {
            guard let entries = value as? [JSON],entries.count <= 100 else { throw CoreError("INVALID_INPUT","acceptance_evidence must contain at most 100 item objects.") };raw = entries
        } else { raw = [] }
        var indexed: [Int:JSON] = [:]
        for entry in raw {
            guard Set(entry.keys).isSubset(of:["item","evidence_refs","limitation","observation"]),let item = entry["item"] as? NSNumber,CFGetTypeID(item) != CFBooleanGetTypeID(),item.doubleValue.rounded() == item.doubleValue,item.doubleValue >= 0,item.doubleValue < Double(acceptance.count),indexed[item.intValue] == nil else { throw CoreError("INVALID_INPUT","Each acceptance evidence item needs a unique 0-based index within the ticket's acceptance list.") }
            indexed[item.intValue] = entry
        }
        let pid = (try StoredRecord(task, family: "AcceptanceEvidence").string("project_id")),contributors = try contributionHistory(db,attempt:attempt)
        var normalized: [JSON] = [],missing: [JSON] = []
        for (index,itemText) in acceptance.enumerated() {
            let entry = indexed[index] ?? [:]
            var refs: [JSON] = [],validCount = 0,reportCount = 0,reasons: [String] = []
            let observation = entry["observation"] as? String
            if entry["observation"] != nil,observation == nil || !["installed","native","owner"].contains(observation!) { throw CoreError("INVALID_INPUT","observation must be installed, native or owner.") }
            let limitation = entry["limitation"] == nil ? "" : try text(entry,"limitation",max:16000)
            let installed = observation == "installed" || observation == "native"
            let inputs: [JSON]
            if let value = entry["evidence_refs"] { guard let list = value as? [JSON],list.count <= 100 else { throw CoreError("INVALID_INPUT","evidence_refs must contain at most 100 reference objects.") };inputs = list } else { inputs = [] }
            let needsBuild = installed || inputs.contains {$0["kind"] as? String == "check_runner_report"}
            let build = evidence["installed_build_id"] as? String ?? ""
            if needsBuild,build.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { reasons.append("evidence_manifest.installed_build_id is required") }
            for input in inputs {
                let kind = try text(input,"kind",max:40)
                var ref: JSON = ["kind":kind],reason: String?
                let fields: [String:Set<String>] = ["attachment":["kind","attachment_id","sha256"],"check":["kind","name"],"carried":["kind","producer","target","sha256"],"check_runner_report":["kind","attachment_id","sha256","build_id"]]
                guard let allowed = fields[kind],Set(input.keys) == allowed else { throw CoreError("INVALID_INPUT","Acceptance evidence references need exactly the fields of their kind.") }
                switch kind {
                case "attachment","check_runner_report":
                    let id = try text(input,"attachment_id",max:200),sha = try acceptanceEvidenceHash(input)
                    ref["attachment_id"] = id;ref["sha256"] = sha
                    let attachment = try? scoped(db,id,pid,type:"attachment")
                    if attachment?["task_id"] as? String != task["id"] as? String || attachment?["mode"] as? String != "managed" || attachment?["availability"] as? String != "available" || attachment?["sha256"] as? String != sha { reason = "attachment is not an available managed original of this ticket with the exact hash" }
                    else if let path = attachment?["path"] as? String,objectBytesMatch(path,sha256:sha) {} else { reason = "attachment bytes are missing or changed" }
                    if kind == "check_runner_report" {
                        let reportBuild = try text(input,"build_id",max:4000);ref["build_id"] = reportBuild
                        if reportBuild != build { reason = "report build \(reportBuild) does not match submitted build \(build)" }
                        else if !(attachment?["description"] as? String ?? "").contains(reportBuild) { reason = "report attachment description does not name build \(build)" }
                        if let author = attachment?["author"] as? String {
                            let session = try records(db,type:"session",project:pid).first { ($0["installation"] as? String ?? "") + ":" + ($0["id"] as? String ?? "") == author }
                            if let session {
                                if implementationContributor(contributors,principal:author,installation:session["installation"] as? String,sessionID:session["id"] as? String) { reason = "report was added by a contributor" }
                            } else { reason = "report must be added by a non-contributor session" }
                        } else { reason = "report has no session author" }
                        if reason == nil { reportCount += 1 }
                    }
                case "check":
                    let name = try text(input,"name",max:4000);ref["name"] = name
                    let checks = evidence["checks"] as? [JSON] ?? []
                    let matches = checks.filter { ($0["name"] as? String ?? $0["label"] as? String) == name }
                    if matches.count != 1 || !["passed","failed","not_run"].contains(matches.first?["result"] as? String ?? "") { reason = "check \(name) needs one recorded result in evidence_manifest.checks" }
                case "carried":
                    ref["producer"] = try text(input,"producer",max:4000);ref["target"] = try text(input,"target",max:4000);ref["sha256"] = try acceptanceEvidenceHash(input)
                default: throw CoreError("INVALID_INPUT","Unknown acceptance evidence reference kind.")
                }
                if let reason { reasons.append(reason) } else { validCount += 1 }
                refs.append(ref)
            }
            // A supplied invalid reference is never stored as verified coverage, even when
            // another reference or a limitation would otherwise cover the plain item.
            if reasons.isEmpty,observation != "owner",installed && reportCount == 0 { reasons.append("\(observation!) observation needs a non-contributor check-runner report for build \(build)") }
            if reasons.isEmpty,observation != "owner",!installed,validCount == 0,limitation.isEmpty { reasons.append("no evidence or limitation") }
            let covered = reasons.isEmpty
            var row: JSON = ["item":index,"item_text":itemText,"evidence_refs":refs,"coverage":["covered":covered,"reason":observation == "owner" ? "owner checks in the trusted app" : installed ? "non-contributor check-runner report" : "evidence or stated limitation"]]
            if !limitation.isEmpty { row["limitation"] = limitation };if let observation { row["observation"] = observation }
            normalized.append(row)
            if !covered { missing.append(["item":index+1,"text":String(itemText.prefix(80)),"reason":reasons.joined(separator:"; ")]) }
        }
        guard missing.isEmpty else {
            let summary = try missing.map { row in
                let record = StoredRecord(row, family: "acceptance_evidence")
                let item = try record.requiredValue("item")
                let text = try record.requiredValue("text")
                let reason = try record.requiredValue("reason")
                return "\(item): \(text) — \(reason)"
            }.joined(separator:"; ")
            throw CoreError("ACCEPTANCE_EVIDENCE_MISSING","Uncovered acceptance items: " + summary,details:["uncovered_items":missing])
        }
        return normalized
    }
    func acceptanceArtifactRefs(_ evidence: JSON) -> [JSON] {
        (evidence["acceptance_evidence"] as? [JSON] ?? []).flatMap {$0["evidence_refs"] as? [JSON] ?? []}.compactMap { ref in
            guard ["attachment","check_runner_report"].contains(ref["kind"] as? String ?? ""),let id = ref["attachment_id"] as? String,let sha = ref["sha256"] as? String else { return nil }
            return ["artifact_id":id,"sha256":sha]
        }
    }
    private func acceptanceEvidenceHash(_ ref: JSON) throws -> String {
        let sha = try text(ref,"sha256",max:64)
        guard sha.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else { throw CoreError("INVALID_INPUT","Evidence sha256 must be 64 lowercase hexadecimal characters.") };return sha
    }
}
