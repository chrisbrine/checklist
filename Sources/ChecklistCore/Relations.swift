import Foundation
import GRDB

extension CommandRouter {
    static let relationKinds: Set<String> = ["depends_on", "related_to", "parent_child", "duplicate_of", "follow_up_of"]

    func activeRelations(_ db: Database, project: String) throws -> [JSON] {
        try records(db, type: "relation", project: project).filter { $0["state"] as? String != "removed" }
    }

    /// The relation is authoritative; this array is a derived view, never another editable dependency store.
    func taskPrerequisites(_ db: Database, task: JSON) throws -> [JSON] {
        let pid = task["project_id"] as! String
        return projectedPrerequisites(task:task,relations:try activeRelations(db,project:pid),taskLookup:{try self.scoped(db,$0,pid,type:"task")},statusLookup:{try self.scoped(db,$0,pid,type:"status")})
    }

    /// Shared semantics for fresh database guards and a request-local read projection.
    func projectedPrerequisites(task: JSON, relations: [JSON], taskLookup: (String) throws -> JSON, statusLookup: (String) throws -> JSON) -> [JSON] {
        let tid = task["id"] as! String
        return relations.filter {
            $0["source_task_id"] as? String == tid && $0["relation"] as? String == "depends_on"
        }.map { edge -> JSON in
            var result: JSON = ["relation_id":edge["id"]!,"required":bool(edge,"required",default:true),"state":edge["state"] ?? "active","resolved":false,"satisfied":false]
            guard edge["state"] as? String != "unresolved", let targetID = edge["target_task_id"] as? String,
                  let target = try? taskLookup(targetID) else {
                let reference = edge["target_legacy_ref"] as? String ?? edge["original_target_task_id"] as? String ?? "unknown ticket"
                result["legacy_reference"] = reference;result["reason"] = "Unresolved prerequisite: \(reference).";return result
            }
            let status = try? statusLookup(target["status_id"] as? String ?? "")
            let category = bool(target,"purged") ? "purged" : status?["category"] as? String ?? "unknown"
            let satisfied = category == "done" && !bool(target,"trashed") && target["disposition"] as? String != "superseded"
            let key = target["key"] as? String ?? targetID
            let condition = bool(target,"purged") ? "purged" : bool(target, "trashed") ? "trashed" : (target["disposition"] as? String == "superseded" ? "superseded duplicate" : category)
            result["task_id"] = targetID;result["key"] = key;result["title"] = target["title"] ?? "";result["task_revision"] = target["revision"] ?? 1
            result["status_category"] = category;result["status_name"] = bool(target,"purged") ? "Purged ticket" : status?["name"] ?? "Unknown";result["resolved"] = true;result["satisfied"] = satisfied
            result["archived"] = bool(target,"archived");result["trashed"] = bool(target,"trashed");result["disposition"] = target["disposition"] ?? "open"
            if !satisfied { result["reason"] = "Prerequisite \(AgentReference.text(target)) must be Done (currently \(condition)). Canceled work does not satisfy a prerequisite." }
            return result
        }
    }

    func prerequisiteBlockers(_ prerequisites: [JSON]) -> [JSON] {
        prerequisites.filter { bool($0,"required",default:true) && !bool($0,"satisfied") }
    }

    func relationBlockers(_ db: Database, task: JSON) throws -> [JSON] {
        prerequisiteBlockers(try taskPrerequisites(db,task:task))
    }

    /// Prerequisites gate claim, pickup and completion. They never gate readiness or queueing: Draft means the brief needs
    /// refinement, and Triage planning orders Queued work by its prerequisites (owner decision, CL-133).
    func requirePrerequisitesSatisfied(_ db: Database, task: JSON) throws {
        let blockers = try relationBlockers(db, task: task)
        guard blockers.isEmpty else { throw CoreError("DEPENDENCY_UNSATISFIED", blockers.compactMap { $0["reason"] as? String }.joined(separator: " "), details: ["prerequisites": blockers]) }
        try requireNotSuperseded(task)
    }

    func requireNotSuperseded(_ task: JSON) throws {
        guard task["disposition"] as? String != "superseded" else {
            throw CoreError("TASK_SUPERSEDED", "This ticket is a preserved duplicate. Open its canonical ticket or explicitly reopen it before continuing.", details: ["duplicate_of_task_id": task["duplicate_of_task_id"] ?? ""])
        }
    }

    func requireQueueEligibility(_ db: Database, task: JSON) throws {
        guard !bool(task,"archived"),!bool(task,"trashed") else { throw CoreError("INVALID_TRANSITION","Restore this ticket before queueing it.") }
        guard task["active_attempt_id"] == nil,task["active_verification_request_id"] == nil else { throw CoreError("CLAIM_CONFLICT","Release or recover active work before queueing this ticket.") }
        try requireNotSuperseded(task)
    }

    func canonicalTaskID(_ db: Database, task: JSON) throws -> String {
        let pid = task["project_id"] as! String
        return try projectedCanonicalTaskID(task:task,taskLookup:{try self.scoped(db,$0,pid,type:"task")})
    }
    func projectedCanonicalTaskID(task: JSON, taskLookup: (String) throws -> JSON) throws -> String {
        var current = task, seen: Set<String> = []
        while let target = current["duplicate_of_task_id"] as? String {
            guard seen.insert(current["id"] as! String).inserted else { throw CoreError("RELATION_CYCLE", "Duplicate redirects contain a cycle.") }
            current = try taskLookup(target)
        }
        return current["id"] as! String
    }

    func relationTaskProjection(_ db: Database, task: JSON) throws -> JSON {
        let prerequisites = try taskPrerequisites(db,task:task)
        let category = (try? record(db, task["status_id"] as? String ?? "", type: "status"))?["category"] as? String ?? "unknown"
        return projectedRelationTask(task:task,prerequisites:prerequisites,category:category,canonicalID:try canonicalTaskID(db,task:task))
    }
    func projectedRelationTask(task: JSON, prerequisites: [JSON], category: String, canonicalID: String) -> JSON {
        let blockers = prerequisiteBlockers(prerequisites)
        let queueEligible = task["disposition"] as? String != "superseded" && !bool(task,"archived") && !bool(task,"trashed") && task["active_attempt_id"] == nil && task["active_verification_request_id"] == nil
        var result: JSON = ["prerequisites":prerequisites,"prerequisite_ids":prerequisites.compactMap {$0["task_id"] as? String},"required_prerequisite_ids":prerequisites.filter {bool($0,"required",default:true)}.compactMap {$0["task_id"] as? String},
                            "prerequisite_blockers": blockers, "prerequisites_satisfied": blockers.isEmpty,"queue_eligible":queueEligible,
                            "pickup_eligible": blockers.isEmpty && task["disposition"] as? String != "superseded" && task["readiness"] as? String == "ready" && ["queued", "blocked"].contains(category) && !bool(task, "archived") && !bool(task, "trashed") && task["active_attempt_id"] == nil && task["active_verification_request_id"] == nil,
                            "canonical_task_id": canonicalID]
        // A Draft stays visible as Draft; "blocked" means a Ready ticket waits for its prerequisites.
        if !blockers.isEmpty { result["blocked_reason"] = blockers.compactMap { $0["reason"] as? String }.joined(separator: " ") }
        result["effective_readiness"] = task["readiness"] as? String == "ready" && !blockers.isEmpty ? "blocked" : task["readiness"] ?? "draft"
        return result
    }

    func relationContext(_ db: Database, task: JSON) throws -> JSON {
        let pid = task["project_id"] as! String, tid = task["id"] as! String
        return ["relations": try activeRelations(db, project: pid).filter { $0["source_task_id"] as? String == tid || $0["target_task_id"] as? String == tid },
                "aliases": try records(db, type: "task_alias", project: pid).filter { $0["task_id"] as? String == tid },
                "eligibility": try relationTaskProjection(db, task: task)]
    }

    func relationRead(_ db: Database, _ p: JSON, _ c: Caller) throws -> JSON {
        let pid = try scope(db, p, c)
        if p["task_id"] != nil { return try relationContext(db, task: task(db, p, pid)) }
        return ["relations": try activeRelations(db, project: pid), "aliases": try records(db, type: "task_alias", project: pid)]
    }

    func validateRelation(_ db: Database, _ edge: JSON, project: String) throws {
        let kind = try text(edge, "relation", max: 40)
        guard Self.relationKinds.contains(kind) else { throw CoreError("INVALID_INPUT", "Choose depends_on, related_to, parent_child, duplicate_of or follow_up_of.") }
        if let value = edge["required"] { guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw CoreError("INVALID_INPUT", "A relation's required value must be boolean.") } }
        let sourceID = try text(edge, "source_task_id", max: 100)
        _ = try scoped(db, sourceID, project, type: "task")
        guard let targetID = edge["target_task_id"] as? String else {
            guard ["unresolved", "removed"].contains(edge["state"] as? String ?? ""), !(try text(edge, "target_legacy_ref", max: 4000)).isEmpty else { throw CoreError("INVALID_INPUT", "An unresolved relation needs its original legacy reference.") }
            return
        }
        _ = try scoped(db, targetID, project, type: "task")
        guard sourceID != targetID else { throw CoreError("RELATION_CYCLE", "A ticket cannot link to itself.") }
        if edge["state"] as? String == "removed" { return }
        let existing = try activeRelations(db, project: project).filter { $0["id"] as? String != edge["id"] as? String }
        guard !existing.contains(where: { old in
            guard old["relation"] as? String == kind, let a = old["source_task_id"] as? String, let b = old["target_task_id"] as? String else { return false }
            return (a == sourceID && b == targetID) || (kind == "related_to" && a == targetID && b == sourceID)
        }) else { throw CoreError("RELATION_EXISTS", "These tickets already have this relation.") }
        if ["depends_on", "parent_child", "duplicate_of"].contains(kind) {
            var adjacency: [String: [String]] = [:]
            for old in existing where old["relation"] as? String == kind {
                if let a = old["source_task_id"] as? String, let b = old["target_task_id"] as? String { adjacency[a, default: []].append(b) }
            }
            if kind == "duplicate_of" {
                for t in try records(db, type: "task", project: project) {
                    if let target = t["duplicate_of_task_id"] as? String { adjacency[t["id"] as! String, default: []].append(target) }
                }
                let source = try scoped(db, sourceID, project, type: "task")
                guard source["duplicate_of_task_id"] == nil || source["duplicate_of_task_id"] as? String == targetID else { throw CoreError("ALIAS_CONFLICT", "Reopen this duplicate before selecting a different canonical ticket.") }
            }
            var pending = [targetID], seen: Set<String> = []
            while let next = pending.popLast() {
                guard next != sourceID else { throw CoreError("RELATION_CYCLE", "This \(kind) link would create a cycle.") }
                if seen.insert(next).inserted { pending += adjacency[next] ?? [] }
            }
        }
    }

    func markDuplicate(_ db: Database, task: inout JSON, edge: JSON, caller: Caller, createAlias: Bool = true) throws {
        guard task["active_attempt_id"] == nil, task["active_verification_request_id"] == nil else { throw CoreError("CLAIM_CONFLICT", "Release or recover active work before marking this ticket as a duplicate.") }
        task["disposition"] = "superseded"; task["duplicate_of_task_id"] = edge["target_task_id"]
        if createAlias {
            let alias: JSON = ["id": uuid(), "project_id": task["project_id"]!, "task_id": task["id"]!, "namespace": "duplicate_redirect", "alias": task["key"]!, "target_task_id": edge["target_task_id"]!, "relation_id": edge["id"]!, "state": "active", "revision": 1, "created_at": now()]
            try save(db, alias, type: "task_alias")
        }
        try recordTicketStatusAction(db, task: task, caller: caller, operation: .individual)
    }

    // Removing a link alone cannot undo an already superseded disposition. Reopen is explicit.
    func reopenRelationDisposition(_ db: Database, task: inout JSON, caller: Caller) throws {
        guard task["disposition"] as? String == "superseded" else { return }
        let pid = task["project_id"] as! String, tid = task["id"] as! String
        task["disposition"] = "open"; task.removeValue(forKey: "duplicate_of_task_id")
        for var edge in try activeRelations(db, project: pid) where edge["source_task_id"] as? String == tid && edge["relation"] as? String == "duplicate_of" {
            edge["state"] = "removed"; edge["removed_at"] = now(); try save(db, revised(edge), type: "relation")
        }
        for var alias in try records(db, type: "task_alias", project: pid) where alias["task_id"] as? String == tid && alias["namespace"] as? String == "duplicate_redirect" && alias["state"] as? String == "active" {
            alias["state"] = "retired"; try save(db, revised(alias), type: "task_alias")
        }
        try event(db, caller: caller, project: pid, entity: tid, kind: "duplicate_reopened")
    }

    func taskLink(_ db: Database, _ p: JSON, _ c: Caller) throws -> JSON {
        try worker(c); let pid = try scope(db, p, c, write: true)
        var source = try task(db, p, pid); try revision(p, source)
        let action = p["action"] as? String ?? "add"
        guard ["add", "remove"].contains(action) else { throw CoreError("INVALID_INPUT", "Choose add or remove.") }
        if action == "remove" {
            let kind = p["relation"] as? String ?? "", targetID = p["target_task_id"] as? String ?? ""
            if !targetID.isEmpty { _ = try scoped(db, targetID, pid, type: "task") }
            guard var edge = try activeRelations(db, project: pid).first(where: { edge in
                if let id = p["relation_id"] as? String {
                    return edge["id"] as? String == id && edge["source_task_id"] as? String == source["id"] as? String &&
                        (kind.isEmpty || edge["relation"] as? String == kind) && (targetID.isEmpty || edge["target_task_id"] as? String == targetID)
                }
                return edge["source_task_id"] as? String == source["id"] as? String && edge["target_task_id"] as? String == targetID && edge["relation"] as? String == kind ||
                kind == "related_to" && edge["source_task_id"] as? String == targetID && edge["target_task_id"] as? String == source["id"] as? String && edge["relation"] as? String == kind
            }) else { throw CoreError("NOT_FOUND", "This active relation is unavailable.") }
            edge["state"] = "removed"; edge["removed_at"] = now(); try save(db, revised(edge), type: "relation")
            source = revised(source); try save(db, source, type: "task")
            try event(db, caller: c, project: pid, entity: source["id"] as? String, kind: "relation_removed", data: ["relation_id": edge["id"]!])
            return ["relation": edge, "task": try taskProjection(db, source)]
        }
        let kind = try text(p, "relation", max: 40), targetID = try text(p, "target_task_id", max: 100)
        _ = try scoped(db, targetID, pid, type: "task")
        let edge: JSON = ["id": uuid(), "project_id": pid, "source_task_id": source["id"]!, "target_task_id": targetID,
                          "relation": kind, "required": bool(p, "required", default: true), "state": "active", "revision": 1, "created_at": now()]
        try validateRelation(db, edge, project: pid)
        if kind == "duplicate_of" { try markDuplicate(db, task: &source, edge: edge, caller: c) }
        try save(db, edge, type: "relation"); source = revised(source); try save(db, source, type: "task")
        try event(db, caller: c, project: pid, entity: source["id"] as? String, kind: "relation_added", data: ["relation_id": edge["id"]!, "relation": kind, "target_task_id": targetID])
        return ["relation": edge, "task": try taskProjection(db, source)]
    }

    // Data-only relation import into already mapped tickets. No source access, identity guessing or work authority transfer.
    func relationImport(_ db: Database, _ p: JSON, _ c: Caller) throws -> JSON {
        let pid = try scope(db, p, c, write: true), project = try record(db, pid, type: "project"); try requireAgentEditAuthority(db,project:project,caller:c); try revision(p, project)
        guard (p["relations"] == nil || p["relations"] is [JSON]), (p["aliases"] == nil || p["aliases"] is [JSON]) else { throw CoreError("INVALID_INPUT", "Relation import needs arrays of relation and alias records.") }
        let edges = p["relations"] as? [JSON] ?? [], aliases = p["aliases"] as? [JSON] ?? []
        guard edges.count <= 1000, aliases.count <= 1000 else { throw CoreError("INVALID_INPUT", "Import at most 1000 relations and aliases per command.") }
        var imported: [JSON] = [], importedAliases: [JSON] = []
        for raw in edges {
            var edge = raw; let id = try text(edge, "id", max: 100)
            guard UUID(uuidString: id) != nil, (try? record(db, id)) == nil else { throw CoreError("IDENTITY_CONFLICT", "An imported relation ID is invalid or already in use.") }
            edge["project_id"] = pid; edge["revision"] = max(int(edge, "revision", default: 1), 1); edge["created_at"] = edge["created_at"] ?? now()
            let state = edge["state"] as? String ?? "active"
            guard ["active", "unresolved", "removed"].contains(state) else { throw CoreError("INVALID_INPUT", "Unsupported imported relation state.") }
            edge["state"] = state
            if let targetID = edge["target_task_id"] as? String {
                if let existing = try? record(db, targetID) {
                    guard existing["project_id"] as? String == pid, (try? scoped(db, targetID, pid, type: "task")) != nil else { throw CoreError("NOT_FOUND", "An imported target is outside this project.") }
                } else {
                    edge["original_target_task_id"] = targetID; edge["target_legacy_ref"] = edge["target_legacy_ref"] ?? targetID
                    edge.removeValue(forKey: "target_task_id"); edge["state"] = state == "removed" ? "removed" : "unresolved"
                }
            }
            try validateRelation(db, edge, project: pid)
            if edge["relation"] as? String == "duplicate_of", edge["state"] as? String == "active" {
                var source = try scoped(db, try text(edge, "source_task_id"), pid, type: "task")
                try markDuplicate(db, task: &source, edge: edge, caller: c, createAlias: false); try save(db, revised(source), type: "task")
            }
            edge["imported_by"] = c.principal; edge["import_origin"] = c.isOwner ? "human_ui" : "agent"
            if !c.isOwner { edge["origin"] = "agent"; edge["author"] = c.principal }
            try save(db, edge, type: "relation"); imported.append(edge)
        }
        for raw in aliases {
            var alias = raw; let id = try text(alias, "id", max: 100), value = try text(alias, "alias", max: 4000)
            guard UUID(uuidString: id) != nil, (try? record(db, id)) == nil else { throw CoreError("IDENTITY_CONFLICT", "An imported alias ID is invalid or already in use.") }
            _ = try scoped(db, try text(alias, "task_id", max: 100), pid, type: "task")
            let namespace = try text(alias, "namespace", max: 200)
            guard !(try records(db, type: "task_alias", project: pid).contains { $0["namespace"] as? String == namespace && $0["alias"] as? String == value && $0["task_id"] as? String != alias["task_id"] as? String }) else { throw CoreError("ALIAS_CONFLICT", "This source alias already identifies another ticket. Resolve it explicitly.") }
            if let target = alias["target_task_id"] as? String { _ = try scoped(db, target, pid, type: "task") }
            alias["project_id"] = pid; alias["revision"] = max(int(alias, "revision", default: 1), 1); alias["created_at"] = alias["created_at"] ?? now()
            alias["imported_by"] = c.principal; alias["import_origin"] = c.isOwner ? "human_ui" : "agent"
            if !c.isOwner { alias["origin"] = "agent"; alias["author"] = c.principal }
            try save(db, alias, type: "task_alias"); importedAliases.append(alias)
        }
        try save(db, revised(project), type: "project")
        try event(db, caller: c, project: pid, entity: pid, kind: "relations_imported", data: ["relation_ids": imported.compactMap { $0["id"] }, "alias_ids": importedAliases.compactMap { $0["id"] }])
        return ["relations": imported, "aliases": importedAliases, "unresolved": imported.filter { $0["state"] as? String == "unresolved" }]
    }
}
