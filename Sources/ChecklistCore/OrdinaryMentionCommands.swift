import CoreFoundation
import Foundation
import GRDB

extension CommandRouter {
    static var ordinaryMentionSelectionsSchema: JSON {
        let identifier: JSON = ["type": "string", "minLength": 1, "maxLength": 4000]
        let ticket: JSON = [
            "type": "object", "required": ["kind", "task_id"], "additionalProperties": false,
            "properties": ["kind": ["const": "ticket"], "task_id": identifier],
        ]
        let session: JSON = [
            "type": "object", "required": ["kind", "session_id", "authorization_generation"], "additionalProperties": false,
            "properties": ["kind": ["const": "session"], "session_id": identifier, "authorization_generation": identifier],
        ]
        let selection: JSON = [
            "type": "object", "required": ["start", "end", "target"], "additionalProperties": false,
            "properties": [
                "start": ["type": "integer", "minimum": 0, "maximum": 65536],
                "end": ["type": "integer", "minimum": 1, "maximum": 65536],
                "target": ["oneOf": [ticket, session]],
            ],
        ]
        return ["type": "array", "maxItems": 50, "items": selection]
    }

    // Public preparation is a durable idempotent command. It never sends a note.
    func ordinaryMentionPrepareCommand(_ db: Database, _ p: JSON, _ caller: Caller) throws -> JSON {
        try worker(caller)
        let allowed: Set<String> = ["command_id", "project_id", "task_id", "body", "reply_to", "selections", "expected_revision"]
        guard Set(p.keys).isSubset(of: allowed) else { throw CoreError("INVALID_INPUT", "Unsupported mention preparation fields.") }
        let pid = try scope(db, p, caller, write: true)
        let tid = try text(p, "task_id", max: 100)
        let task = try scoped(db, tid, pid, type: "task")
        let body = try text(p, "body", max: 65536)
        let reply = p["reply_to"] != nil ? try text(p, "reply_to", max: 100) : nil
        // Also authorizes zero-token and ambiguous requests before reading matches.
        try ordinaryMentionPreparationScope(db, project: pid, taskID: tid, replyTo: reply, caller: caller)
        let tokens = try publicMentionTokens(body)
        let selections = try publicMentionSelections(p["selections"], tokens: tokens)
        let pool: [ScopedMentionProjection.Candidate]
        if tokens.isEmpty { pool = [] } else { pool = try ordinaryMentionChoicePool(db, project: pid, queries: tokens.map(\.query), caller: caller) }
        var tokenResults: [JSON] = []
        var references: [JSON] = []
        var unresolved = false
        for token in tokens {
            let matches = pool.filter { publicMentionMatches($0, query: token.query) }
            let selected = selections.first { $0.start == token.start && $0.end == token.end }
            let chosen: ScopedMentionProjection.Target?
            if let selected {
                guard matches.contains(where: { $0.target == selected.target }) else {
                    throw CoreError("RECIPIENT_CHANGED", "This exact selection no longer matches the current scoped token. Resolve it again.")
                }
                chosen = selected.target
            } else {
                chosen = matches.count == 1 ? matches[0].target : nil
            }
            let candidates = try matches.map { try publicMentionChoice(db, project: pid, target: $0.target) }
            var result: JSON = [
                "start": token.start, "end": token.end, "query": token.query,
                "candidates": candidates, "state": chosen == nil ? (matches.isEmpty ? "not_found" : "ambiguous") : "resolved",
            ]
            if let chosen {
                let reference = ordinaryMentionTargetJSON(chosen)
                references.append(reference)
                result["target"] = reference
            } else {
                unresolved = true
            }
            tokenResults.append(result)
        }
        let output: JSON = [
            "state": unresolved ? "needs_selection" : (tokens.isEmpty ? "untagged" : "prepared"),
            "body_sha256": hash(Data(body.utf8)), "parser": OrdinaryMentionTokens.version,
            "tokens": tokenResults, "delivery_capability": "pickup_only", "push_available": false,
        ]
        guard !unresolved, !tokens.isEmpty else { return output }  // never a partial route
        return try finishPublicMentionPreparation(
            db, project: pid, task: task, reply: reply,
            references: references, tokenResults: tokenResults, output: output, caller: caller)
    }

    private func finishPublicMentionPreparation(
        _ db: Database, project pid: String, task: JSON,
        reply: String?, references: [JSON], tokenResults: [JSON], output initial: JSON, caller: Caller
    ) throws -> JSON {
        var output = initial
        let plan = try prepareOrdinaryMentionReferences(
            db, project: pid, taskID: try StoredTaskRecord(task).id,
            replyTo: reply, references: references, caller: caller)
        let token = try StoredRecord(plan, family: "ordinary_mention_plan").string("mention_target")
        var stored = try scoped(db, token, pid, type: "ordinary_mention_plan")
        stored["public_body_sha256"] = output["body_sha256"]
        stored["public_parser"] = OrdinaryMentionTokens.version
        stored["public_bindings"] = try tokenResults.map { value -> JSON in
            [
                "start": try StoredRecord(value, family: "mention_binding").requiredValue("start"), "end": try StoredRecord(value, family: "mention_binding").requiredValue("end"),
                "query": try StoredRecord(value, family: "mention_binding").requiredValue("query"),
                "target": try StoredRecord(value, family: "mention_binding").requiredValue("target"),
            ]
        }
        try save(db, stored, type: "ordinary_mention_plan")
        output["mention_target"] = token
        output["references"] = plan["references"]
        output["expires_at"] = plan["expires_at"]
        return output
    }

    // Invoked only in Communication's ordinary-note branch, before consuming the
    // plan. Protected owner directions/answers/reply allowances are unchanged.
    func validateOrdinaryMentionBody(_ db: Database, project: String, body: String, mentionTarget: String?) throws {
        let tokens = try publicMentionTokens(body)
        guard let mentionTarget else {
            guard tokens.isEmpty else { throw CoreError("MENTION_PREPARATION_REQUIRED", "Resolve all tagged targets before sending this exact note.") }
            return
        }
        let plan = try scoped(db, mentionTarget, project, type: "ordinary_mention_plan")
        // The carried internal typed seam creates no public token. Only the new
        // public command creates public_* fields, and always binds exact text.
        guard plan["public_body_sha256"] != nil else { return }
        guard let expected = plan["public_body_sha256"] as? String,
            expected.utf8.elementsEqual(hash(Data(body.utf8)).utf8),
            plan["public_parser"] as? String == OrdinaryMentionTokens.version
        else {
            throw CoreError("RECIPIENT_CHANGED", "The note text changed after mention preparation. Resolve this draft again.")
        }
    }

    private func publicMentionTokens(_ body: String) throws -> [OrdinaryMentionTokens.Token] {
        do { return try OrdinaryMentionTokens.parse(body) } catch {
            throw CoreError("MENTION_SYNTAX", "Use @token or @{exact label}; escape a literal @ with a backslash. At most fifty tags are allowed.")
        }
    }

    private struct PublicMentionSelection {
        let start: Int
        let end: Int
        let target: ScopedMentionProjection.Target
    }
    private func publicMentionMatches(_ candidate: ScopedMentionProjection.Candidate, query: String) -> Bool {
        let exact = ScopedMentionProjection.ExactText(query)
        if candidate.aliases.contains(.ticketKey(exact)) || candidate.aliases.contains(.workerName(exact)) { return true }
        if case .session(let id, _) = candidate.target { return id == exact }
        return false
    }
    private func publicMentionSelections(_ input: Any?, tokens: [OrdinaryMentionTokens.Token]) throws -> [PublicMentionSelection] {
        guard let input else { return [] }
        guard let values = input as? [JSON], values.count <= 50 else { throw CoreError("INVALID_INPUT", "Mention selections must be a bounded array.") }
        var result: [PublicMentionSelection] = []
        for value in values {
            guard Set(value.keys) == ["start", "end", "target"], let target = value["target"] as? JSON else {
                throw CoreError("INVALID_INPUT", "Each selection requires exactly start, end and target.")
            }
            let start = try publicMentionOffset(value["start"])
            let end = try publicMentionOffset(value["end"])
            guard tokens.contains(where: { $0.start == start && $0.end == end }),
                !result.contains(where: { $0.start == start && $0.end == end })
            else {
                throw CoreError("RECIPIENT_CHANGED", "Mention selection spans must each name one current exact token.")
            }
            result.append(.init(start: start, end: end, target: try ordinaryMentionReference(target)))
        }
        return result
    }
    private func publicMentionOffset(_ input: Any?) throws -> Int {
        guard let number = input as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
            number.doubleValue >= 0, number.doubleValue <= 65536
        else { throw CoreError("INVALID_INPUT", "Mention offsets are nonnegative integer UTF-8 offsets.") }
        return number.intValue
    }

    private func publicMentionChoice(_ db: Database, project: String, target: ScopedMentionProjection.Target) throws -> JSON {
        var result: JSON = ["target": ordinaryMentionTargetJSON(target), "project_id": project]
        switch target {
        case .ticket(let id):
            let task = try scoped(db, String(decoding: id.bytes, as: UTF8.self), project, type: "task")
            result["key"] = task["key"]
            result["title"] = task["title"]
        case .session(let id, _):
            let session = try scoped(db, String(decoding: id.bytes, as: UTF8.self), project, type: "session")
            result["label"] = session["label"]
            result["provider"] = session["provider"]
        }
        return result
    }
}
