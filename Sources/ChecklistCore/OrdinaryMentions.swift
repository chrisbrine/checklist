// PRIVATE SERVICE OVERLAY. No public resolver/parser/UI/native route is exposed.
import Foundation
import GRDB

struct OrdinaryMentionRoute {
    let messageID: String?
    let mode: String
    let references: [JSON]
    let recipients: [JSON]
}

extension CommandRouter {
    private typealias Mention = ScopedMentionProjection

    private func mentionString(_ value: Mention.ExactText) -> String {
        String(decoding: value.bytes, as: UTF8.self)
    }
    private func mentionEqual(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (.some(let a), .some(let b)): return a.utf8.elementsEqual(b.utf8)
        case (.none, .none): return true
        default: return false
        }
    }
    private func mentionTransaction(_ db: Database) throws {
        guard db.isInsideTransaction else { throw CoreError("TRANSACTION_REQUIRED", "Ordinary mention preparation and delivery require the service transaction.") }
    }
    private func mentionRecipient(_ session: JSON, project: String) -> Mention.Recipient? {
        let enrolled = strings(session, "project_ids").contains { mentionEqual($0, project) }
            || mentionEqual(session["project_id"] as? String, project)
        guard enrolled, session["role"] as? String == "worker", canReceive(session, project: project),
              let sid = session["id"] as? String, let generation = session["authorization_generation"] as? String,
              !sid.isEmpty, !generation.isEmpty else { return nil }
        return .init(projectID: .init(project), sessionID: .init(sid), authorizationGeneration: .init(generation))
    }
    private func mentionCaller(_ db: Database, caller: Caller, project: String) throws {
        try worker(caller)
        guard !caller.isOwner else { return }
        guard caller.projectIDs.contains(where: { mentionEqual($0, project) }), let sid = caller.sessionID,
              let session = try? scoped(db, sid, project, type: "session"), mentionRecipient(session, project: project) != nil else {
            throw CoreError("FORBIDDEN", "Ordinary mentions require this exact currently enrolled worker and project.")
        }
    }

    // Only actual current attempts/accepted children; the project coordinator is
    // deliberately retained only by the separate protected direction contract.
    func ordinaryHandlerRecipients(_ db: Database, task: JSON) throws -> [JSON] {
        let pid = task["project_id"] as! String, tid = task["id"] as! String
        guard let rootID = task["active_attempt_id"] as? String,
              let root = try? scoped(db, rootID, pid, type: "attempt"), root["state"] as? String == "active" else { return [] }
        let attempts = [root] + (try activeDescendants(db, attempt: root))
        var result: [JSON] = [], seen: Set<Mention.Recipient> = []
        for attempt in attempts {
            guard let sid = attempt["session_id"] as? String, let aid = attempt["id"] as? String,
                  mentionEqual(attempt["project_id"] as? String, pid), mentionEqual(attempt["task_id"] as? String, tid),
                  mentionEqual(aid, rootID) || attempt["parent_attempt_id"] != nil,
                  let session = try? scoped(db, sid, pid, type: "session"),
                  let route = mentionRecipient(session, project: pid),
                  mentionEqual(attempt["session_authorization_generation"] as? String, mentionString(route.authorizationGeneration)),
                  seen.insert(route).inserted else { continue }
            result.append(["project_id": pid, "session_id": sid, "attempt_id": aid,
                           "recipient_role": mentionEqual(aid, rootID) ? "handler" : "registered_child",
                           "display_name": session["label"] ?? "Worker",
                           "authorization_generation": mentionString(route.authorizationGeneration)])
        }
        return result.sorted { ($0["session_id"] as! String).utf8.lexicographicallyPrecedes(($1["session_id"] as! String).utf8) }
    }

    private func mentionMatches(_ lookups: [Mention.Lookup], target: Mention.Target, aliases: [Mention.Lookup]) -> Bool {
        lookups.contains { lookup in
            if case .reference(let reference) = lookup { return reference == target }
            return aliases.contains(lookup)
        }
    }
    private func mentionCandidates(_ db: Database, project: String, lookups: [Mention.Lookup]) throws -> [Mention.Candidate] {
        let pid = Mention.ExactText(project)
        var result: [Mention.Candidate] = []
        for session in try records(db, type: "session", project: project) {
            guard let route = mentionRecipient(session, project: project) else { continue }
            let aliases: [Mention.Lookup] = (session["label"] as? String).map { [.workerName(.init($0))] } ?? []
            let target = Mention.Target.session(route.sessionID, authorizationGeneration: route.authorizationGeneration)
            guard mentionMatches(lookups, target: target, aliases: aliases) else { continue }
            result.append(.init(projectID: pid, aliases: aliases,
                                target: target, recipients: [route]))
        }
        for task in try records(db, type: "task", project: project) {
            guard mentionEqual(task["project_id"] as? String, project), !bool(task, "trashed"),
                  let tid = task["id"] as? String, let key = task["key"] as? String else { continue }
            let target = Mention.Target.ticket(.init(tid)), aliases = [Mention.Lookup.ticketKey(.init(key))]
            guard mentionMatches(lookups, target: target, aliases: aliases) else { continue }
            let recipients = try ordinaryHandlerRecipients(db, task: task).map { detail in
                Mention.Recipient(projectID: pid, sessionID: .init(detail["session_id"] as! String),
                                  authorizationGeneration: .init(detail["authorization_generation"] as! String))
            }
            result.append(.init(projectID: pid, aliases: aliases, target: target, recipients: recipients))
        }
        return result
    }

    private func mentionTargetJSON(_ target: Mention.Target) -> JSON {
        switch target {
        case .ticket(let id): return ["kind": "ticket", "task_id": mentionString(id)]
        case .session(let id, let generation):
            return ["kind": "session", "session_id": mentionString(id), "authorization_generation": mentionString(generation)]
        }
    }
    private func mentionLookupJSON(_ lookup: Mention.Lookup) -> JSON {
        switch lookup {
        case .ticketKey(let key): return ["kind": "ticket_key", "key": mentionString(key)]
        case .workerName(let name): return ["kind": "worker_name", "name": mentionString(name)]
        case .reference(let target): return mentionTargetJSON(target)
        }
    }
    // Decoding only our stored typed plan, never parsing @-text or granting identity.
    private func mentionLookup(_ value: JSON) throws -> Mention.Lookup {
        switch value["kind"] as? String {
        case "ticket_key" where Set(value.keys) == ["kind", "key"]:
            return .ticketKey(.init(try text(value, "key", max: 4000)))
        case "worker_name" where Set(value.keys) == ["kind", "name"]:
            return .workerName(.init(try text(value, "name", max: 4000)))
        case "ticket" where Set(value.keys) == ["kind", "task_id"]:
            return .reference(.ticket(.init(try text(value, "task_id", max: 4000))))
        case "session" where Set(value.keys) == ["kind", "session_id", "authorization_generation"]:
            return .reference(.session(.init(try text(value, "session_id", max: 4000)),
                                      authorizationGeneration: .init(try text(value, "authorization_generation", max: 4000))))
        default: throw CoreError("RECIPIENT_CHANGED", "This mention plan is invalid; select the targets again.")
        }
    }
    private func mentionProjection(_ db: Database, project: String, task: JSON, messageID: String,
                                   replyTo: String?, lookups: [Mention.Lookup], caller: Caller) throws -> Mention.Projection {
        let handlers = try ordinaryHandlerRecipients(db, task: task).filter { !mentionEqual($0["session_id"] as? String, caller.sessionID) }
        let current = handlers.map { Mention.Recipient(projectID: .init(project), sessionID: .init($0["session_id"] as! String),
                                                       authorizationGeneration: .init($0["authorization_generation"] as! String)) }
        let context = Mention.Context(projectID: .init(project), taskID: .init(task["id"] as! String), messageID: .init(messageID))
        switch Mention.project(context: context, form: replyTo == nil ? .topLevel : .reply,
                               currentHandlers: current, tags: lookups, candidates: try mentionCandidates(db, project: project, lookups: lookups)) {
        case .success(let result): return result
        case .failure(.missingMention(let lookup)):
            throw CoreError("MENTION_NOT_FOUND", "This target has no current eligible match in this project.", details: ["lookup": mentionLookupJSON(lookup)])
        case .failure(.ambiguousMention(let lookup, let targets)):
            throw CoreError("MENTION_AMBIGUOUS", "Choose an exact target; no recipient was selected.", details: ["lookup": mentionLookupJSON(lookup), "candidates": targets.map(mentionTargetJSON)])
        case .failure:
            throw CoreError("RECIPIENT_CHANGED", "Recipient snapshots disagree; refresh the mention selection.")
        }
    }
    private func mentionSnapshot(_ projection: Mention.Projection) -> JSON {
        ["project_id": mentionString(projection.context.projectID), "task_id": mentionString(projection.context.taskID),
         "message_id": mentionString(projection.context.messageID), "targets": projection.taggedTargets.map(mentionTargetJSON),
         "recipients": projection.recipients.map { ["project_id": mentionString($0.projectID), "session_id": mentionString($0.sessionID),
                                                    "authorization_generation": mentionString($0.authorizationGeneration)] }]
    }
    private func ordinaryReplyScope(_ db: Database, project: String, taskID: String, replyTo: String?) throws {
        guard let replyTo else { return }
        let original = try scoped(db, replyTo, project, type: "message")
        guard mentionEqual(original["task_id"] as? String, taskID), original["conversation_id"] == nil,
              original["reply_sender_session_id"] as? String != "human" else {
            throw CoreError("INVALID_INPUT", "Mention plans apply only to ordinary replies in the same ticket, outside protected owner reply routes.")
        }
    }

    // Internal typed preparation seam. A future discovered UI/tool adapter may
    // call it; this overlay exposes no new public resolver command or catalog.
    func prepareOrdinaryMentions(_ db: Database, projectID: String, taskID: String, replyTo: String?,
                                 lookups: [ScopedMentionProjection.Lookup], caller: Caller) throws -> JSON {
        try mentionTransaction(db); try worker(caller)
        let pid = try scope(db, ["project_id": projectID], caller, write: true)
        try mentionCaller(db, caller: caller, project: pid)
        let task = try scoped(db, taskID, pid, type: "task")
        guard mentionEqual(task["project_id"] as? String, pid), !lookups.isEmpty, lookups.count <= 50 else {
            throw CoreError("INVALID_INPUT", "Select between one and fifty same-project mentions.")
        }
        for lookup in lookups { _ = try mentionLookup(mentionLookupJSON(lookup)) }
        try ordinaryReplyScope(db, project: pid, taskID: taskID, replyTo: replyTo)
        let mid = uuid(), projection = try mentionProjection(db, project: pid, task: task, messageID: mid, replyTo: replyTo, lookups: lookups, caller: caller)
        let snapshot = mentionSnapshot(projection), token = uuid() + uuid()
        var plan: JSON = ["id": token, "project_id": pid, "task_id": taskID, "message_id": mid,
                          "principal": caller.principal, "sender_session_id": caller.sessionID ?? "human",
                          "sender_generation": try callerSessionGeneration(db, caller, project: pid),
                          "sender_authorization_scope": try authorizationScope(db, caller), "incarnation": incarnation,
                          "lookups": lookups.map(mentionLookupJSON), "snapshot": snapshot,
                          "snapshot_sha256": hash(Data(try jsonString(snapshot).utf8)), "used": false,
                          "expires_at": Date().timeIntervalSince1970 + 300, "revision": 1, "created_at": now()]
        if let replyTo { plan["reply_to"] = replyTo }
        try save(db, plan, type: "ordinary_mention_plan")
        return ["mention_target": token, "expires_at": plan["expires_at"]!, "references": snapshot["targets"]!,
                "delivery_capability": "pickup_only", "push_available": false]
    }

    func ordinaryMessageRoute(_ db: Database, project: String, task: JSON, replyTo: String?,
                              mentionTarget: String?, caller: Caller) throws -> OrdinaryMentionRoute {
        try mentionTransaction(db); try mentionCaller(db, caller: caller, project: project)
        let tid = task["id"] as! String
        let handlers = try ordinaryHandlerRecipients(db, task: task)
        guard let mentionTarget else {
            return .init(messageID: nil, mode: "handlers", references: [],
                         recipients: handlers.filter { !mentionEqual($0["session_id"] as? String, caller.sessionID) })
        }
        var plan = try scoped(db, mentionTarget, project, type: "ordinary_mention_plan")
        guard mentionEqual(plan["project_id"] as? String, project), mentionEqual(plan["task_id"] as? String, tid),
              mentionEqual(plan["principal"] as? String, caller.principal),
              mentionEqual(plan["sender_session_id"] as? String, caller.sessionID ?? "human"),
              mentionEqual(plan["sender_generation"] as? String, try callerSessionGeneration(db, caller, project: project)),
              mentionEqual(plan["sender_authorization_scope"] as? String, try authorizationScope(db, caller)),
              mentionEqual(plan["incarnation"] as? String, incarnation), mentionEqual(plan["reply_to"] as? String, replyTo),
              !bool(plan, "used"), (plan["expires_at"] as? Double ?? 0) > Date().timeIntervalSince1970,
              let mid = plan["message_id"] as? String, let values = plan["lookups"] as? [JSON], !values.isEmpty, values.count <= 50 else {
            throw CoreError("RECIPIENT_CHANGED", "This exact mention plan is no longer current for this sender and ticket.")
        }
        try ordinaryReplyScope(db, project: project, taskID: tid, replyTo: replyTo)
        let projection: Mention.Projection
        do {
            projection = try mentionProjection(db, project: project, task: task, messageID: mid, replyTo: replyTo,
                                               lookups: values.map(mentionLookup), caller: caller)
        } catch let error as CoreError where ["MENTION_NOT_FOUND", "MENTION_AMBIGUOUS"].contains(error.code) {
            throw CoreError("RECIPIENT_CHANGED", "The selected mention changed; resolve it again before sending.")
        }
        let snapshot = mentionSnapshot(projection)
        guard mentionEqual(plan["snapshot_sha256"] as? String, hash(Data(try jsonString(snapshot).utf8))) else {
            throw CoreError("RECIPIENT_CHANGED", "Current handlers or exact mention recipients/generations changed; resolve again.")
        }
        let details: [JSON] = projection.recipients.map { recipient in
            let sid = mentionString(recipient.sessionID), generation = mentionString(recipient.authorizationGeneration)
            var detail = handlers.first { mentionEqual($0["session_id"] as? String, sid) && mentionEqual($0["authorization_generation"] as? String, generation) }
                ?? ["session_id": sid, "recipient_role": "mention"]
            detail["project_id"] = project; detail["authorization_generation"] = generation
            return detail
        }
        plan["used"] = true; plan["used_at"] = now(); try save(db, revised(plan), type: "ordinary_mention_plan")
        return .init(messageID: mid, mode: replyTo == nil ? "tagged_top_level" : "tagged_reply",
                     references: projection.taggedTargets.map { target in var value = mentionTargetJSON(target); value["project_id"] = project; return value },
                     recipients: details)
    }

    // Exact re-read at queue boundary, within handle's one transaction. Protected
    // direction/human-answer queueing is unchanged. No process/liveness assertion.
    func queueOrdinaryDeliveries(_ db: Database, message: JSON, recipients: [JSON]) throws -> [JSON] {
        try mentionTransaction(db)
        let pid = message["project_id"] as! String, mid = message["id"] as! String
        // A new note must not decode the project's entire retained outbox.
        // Malformed JSON remains selected so canonical validation still refuses it.
        let rows = try Row.fetchAll(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='delivery' AND project_id=CAST(? AS TEXT) AND CASE WHEN json_valid(data) THEN json_type(data,'$.message_id')='text' AND json_extract(data,'$.message_id')=CAST(? AS TEXT) COLLATE BINARY ELSE 1 END ORDER BY rowid",arguments:[Data(pid.utf8),Data(mid.utf8)])
        var deliveries = try rows.map {try GRDBRecordEnvelopeAdapter.decode($0,expectedType:"delivery").object}
        for recipient in recipients {
            let sid = try text(recipient, "session_id", max: 4000), generation = try text(recipient, "authorization_generation", max: 4000)
            let session = try scoped(db, sid, pid, type: "session")
            guard let current = mentionRecipient(session, project: pid),
                  current == Mention.Recipient(projectID: .init(pid), sessionID: .init(sid), authorizationGeneration: .init(generation)) else {
                throw CoreError("RECIPIENT_CHANGED", "This recipient lost its exact project/session authorization before delivery.")
            }
            if deliveries.contains(where: { mentionEqual($0["recipient_session_id"] as? String, sid) && mentionEqual($0["recipient_authorization_generation"] as? String, generation) }) { continue }
            var delivery: JSON = ["id": uuid(), "project_id": pid, "message_id": mid, "recipient_session_id": sid,
                                  "recipient_authorization_generation": generation, "recipient_role": recipient["recipient_role"] ?? "recipient",
                                  "recipient_display": recipient["display_name"] ?? session["label"] ?? "Worker", "state": "queued",
                                  "push_state": "unavailable", "push_reason": "Native push is unqualified; available on recipient MCP pickup.",
                                  "revision": 1, "created_at": now()]
            if let aid = recipient["attempt_id"] { delivery["recipient_attempt_id"] = aid }
            try save(db, delivery, type: "delivery"); deliveries.append(delivery)
        }
        return deliveries
    }
// Append inside extension CommandRouter in the source-cleared v2
// OrdinaryMentions.swift. No prior method body changes.
    func ordinaryMentionPreparationScope(_ db: Database, project: String, taskID: String,
                                          replyTo: String?, caller: Caller) throws {
        try mentionTransaction(db)
        try mentionCaller(db, caller: caller, project: project)
        let task = try scoped(db, taskID, project, type: "task")
        guard mentionEqual(task["project_id"] as? String, project) else { throw CoreError("FORBIDDEN", "Select a ticket in this exact project.") }
        try ordinaryReplyScope(db, project: project, taskID: taskID, replyTo: replyTo)
    }

    // One raw token collects both namespaces, plus an actual exact session ID.
    // No CL-like naming convention selects a ticket over a worker label.
    func ordinaryMentionChoicePool(_ db: Database, project: String, queries: [String],
                                  caller: Caller) throws -> [ScopedMentionProjection.Candidate] {
        try mentionTransaction(db)
        try mentionCaller(db, caller: caller, project: project)
        let exactQueries = Set(queries.map { Mention.ExactText($0) })
        var lookups: [Mention.Lookup] = exactQueries.flatMap { [.ticketKey($0), .workerName($0)] }
        for session in try records(db, type: "session", project: project) {
            if let route = mentionRecipient(session, project: project), exactQueries.contains(route.sessionID) {
                lookups.append(.reference(.session(route.sessionID, authorizationGeneration: route.authorizationGeneration)))
            }
        }
        var choices: [ScopedMentionProjection.Candidate] = []
        for candidate in try mentionCandidates(db, project: project, lookups: lookups) {
            if let previous = choices.first(where: { $0.target == candidate.target }) {
                guard Set(previous.recipients) == Set(candidate.recipients) else {
                    throw CoreError("RECIPIENT_CHANGED", "Mention snapshots disagree; resolve them again.")
                }
            } else { choices.append(candidate) }
        }
        return choices.sorted {
            let a = (try? jsonString(mentionTargetJSON($0.target))) ?? ""
            let b = (try? jsonString(mentionTargetJSON($1.target))) ?? ""
            return a.utf8.lexicographicallyPrecedes(b.utf8)
        }
    }

    func ordinaryMentionTargetJSON(_ target: ScopedMentionProjection.Target) -> JSON { mentionTargetJSON(target) }
    func ordinaryMentionReference(_ value: JSON) throws -> ScopedMentionProjection.Target {
        guard ["ticket", "session"].contains(value["kind"] as? String ?? ""),
              case .reference(let target) = try mentionLookup(value) else {
            throw CoreError("INVALID_INPUT", "Select an exact ticket or current worker session reference.")
        }
        return target
    }
    func prepareOrdinaryMentionReferences(_ db: Database, project: String, taskID: String, replyTo: String?,
                                          references: [JSON], caller: Caller) throws -> JSON {
        try prepareOrdinaryMentions(db, projectID: project, taskID: taskID, replyTo: replyTo,
                                    lookups: references.map { .reference(try ordinaryMentionReference($0)) }, caller: caller)
    }


}
