import Foundation
import GRDB

/// Advisory supervision only. The durable state lives on tickets and correlated
/// messages, so export/backup retain it without creating another authority store.
extension CommandRouter {
    static let defaultWorkHealth: JSON = ["enabled": true, "inactivity_minutes": 20, "response_grace_minutes": 20]

    func workHealthSettings(_ project: JSON) -> JSON {
        var value = Self.defaultWorkHealth
        for (key, item) in project["work_health_settings"] as? JSON ?? [:] { value[key] = item }
        return value
    }
    func validateWorkHealthSettings(_ raw: Any) throws -> JSON {
        guard let value = raw as? JSON, Set(value.keys) == Set(Self.defaultWorkHealth.keys),
              let enabled = value["enabled"] as? NSNumber, CFGetTypeID(enabled) == CFBooleanGetTypeID() else {
            throw CoreError("INVALID_INPUT", "Work health requires enabled, inactivity_minutes and response_grace_minutes.")
        }
        for key in ["inactivity_minutes", "response_grace_minutes"] {
            guard let number = value[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.rounded() == number.doubleValue, (1...10080).contains(number.intValue) else {
                throw CoreError("INVALID_INPUT", "Health intervals must be whole minutes from 1 to 10080.")
            }
        }
        return value
    }
    private func healthTime(_ value: Any?) -> Date? {
        (value as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }
    private func healthStamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// Only changed substantive checkpoint text advances this clock. Reads,
    /// session heartbeats, repeated checkpoint text and scope edits do not.
    func recordHealthProgress(_ attempt: inout JSON, progress: String, at date: Date = Date()) {
        let digest = hash(Data(progress.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        let old = attempt["health_progress_digest"] as? String
            ?? (attempt["progress"] as? String).map { hash(Data($0.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) }
        if attempt["health_progress_at"] == nil { attempt["health_progress_at"] = attempt["last_checkpoint"] ?? attempt["started_at"] ?? healthStamp(date) }
        attempt["health_progress_digest"] = digest
        if !progress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, digest != old {
            attempt["health_progress_at"] = healthStamp(date); attempt["health_progress_digest"] = digest; attempt["health_progress_id"] = uuid()
        }
    }

    /// Exact task/attempt queries; no project message/event corpus is decoded.
    func workHealthTarget(_ db: Database, task: JSON) throws -> JSON {
        let pid = task["project_id"] as! String
        if let aid = task["active_attempt_id"] as? String,
           let attempt = try? scoped(db, aid, pid, type: "attempt"), attempt["state"] as? String == "active" {
            return ["kind": "attempt", "id": aid, "phase": attempt["phase"] ?? "implementation",
                    "session_id": attempt["session_id"] ?? "human", "generation": attempt["session_authorization_generation"] ?? "",
                    "started_at": attempt["started_at"] ?? NSNull()]
        }
        let groups = try scopedTaskGroups(db, task: task)
        let coordinators = groups.filter { !bool($0, "archived") && ($0["orchestration"] as? JSON)?["state"] as? String == "active" }
        // An ambiguous pair of orchestrators is visible and never guessed.
        if coordinators.count == 1, let group = coordinators.first, let orchestration = group["orchestration"] as? JSON,
           let id = orchestration["id"] as? String, !id.isEmpty, let sid = orchestration["session_id"] as? String, !sid.isEmpty,
           let phase = triagePhase(group) {
            return ["kind": "orchestration", "id": id, "triage_id": group["id"]!,
                    "phase": phase, "session_id": sid,
                    "generation": orchestration["session_authorization_generation"] ?? "", "started_at": orchestration["started_at"] ?? NSNull()]
        }
        return ["kind": "missing_handler", "id": "missing", "phase": "unknown", "session_id": "",
                "generation": "", "reason": coordinators.isEmpty ? "No current handler or active phase orchestrator." : coordinators.count > 1 ? "Multiple active phase orchestrators; choose a handler explicitly." : "Active orchestration has no complete durable phase/session identity; refresh the actual orchestration."]
    }
    private func sameHealthTarget(_ a: JSON, _ b: JSON) -> Bool {
        ["kind", "id", "phase", "session_id", "generation"].allSatisfy { (a[$0] as? String ?? "").utf8.elementsEqual((b[$0] as? String ?? "").utf8) }
    }
    private func healthProgress(_ db: Database, task: JSON, target: JSON) throws -> Date? {
        let pid = task["project_id"] as! String
        if target["kind"] as? String == "attempt" {
            // The accepted tree is capped at 32 descendants by work authority.
            // Include released accepted children too: their completed work is progress.
            let sql = """
                WITH RECURSIVE tree(id,data) AS (
                  SELECT id,data FROM records WHERE type='attempt' AND project_id=? AND id=?
                  UNION ALL SELECT a.id,a.data FROM records a JOIN tree p ON json_extract(a.data,'$.parent_attempt_id')=p.id
                  WHERE a.type='attempt' AND a.project_id=? AND json_extract(a.data,'$.task_id')=?
                ) SELECT data FROM tree
                """
            let latest = try Double.fetchOne(db, sql: "SELECT MAX(checklist_timestamp(COALESCE(json_extract(data,'$.health_progress_at'),json_extract(data,'$.last_checkpoint'),json_extract(data,'$.started_at')))) FROM (" + sql + ")", arguments: [pid, target["id"] as! String, pid, task["id"] as! String])
            return latest.map { Date(timeIntervalSince1970: $0) }
        }
        if let gid = target["triage_id"] as? String,
           let orchestration = try scoped(db, gid, pid, type: "group")["orchestration"] as? JSON {
            return healthTime(orchestration["health_progress_at"] ?? orchestration["started_at"])
        }
        return nil
    }
    private func healthProgressToken(_ db: Database, task: JSON, target: JSON) throws -> String {
        let pid = task["project_id"] as! String
        if target["kind"] as? String == "attempt" {
            // Select only this accepted tree: repeated checkpoint timestamps do not
            // change the token once the substantive clock has been initialized.
            let sql = """
                WITH RECURSIVE tree(id,data) AS (
                  SELECT id,data FROM records WHERE type='attempt' AND project_id=? AND id=?
                  UNION ALL SELECT a.id,a.data FROM records a JOIN tree p ON json_extract(a.data,'$.parent_attempt_id')=p.id
                  WHERE a.type='attempt' AND a.project_id=? AND json_extract(a.data,'$.task_id')=?
                ) SELECT json_group_array(json_array(id,COALESCE(json_extract(data,'$.health_progress_at'),json_extract(data,'$.last_checkpoint'),json_extract(data,'$.started_at')),json_extract(data,'$.health_progress_id'))) FROM (SELECT * FROM tree ORDER BY id)
                """
            return hash(Data((try String.fetchOne(db,sql:sql,arguments:[pid,target["id"] as! String,pid,task["id"] as! String]) ?? "").utf8))
        }
        if let gid = target["triage_id"] as? String, let o = try scoped(db,gid,pid,type:"group")["orchestration"] as? JSON {
            return hash(Data(try jsonString(["id":o["id"]!,"progress_id":o["health_progress_id"] ?? "","at":o["health_progress_at"] ?? o["started_at"] ?? ""]).utf8))
        }
        return "missing"
    }

    func workHealthView(_ db: Database, task: JSON, at date: Date = Date()) throws -> JSON {
        let pid = task["project_id"] as! String, target = try workHealthTarget(db, task: task)
        let settings = workHealthSettings(try record(db, pid, type: "project"))
        var value = task["work_health"] as? JSON ?? ["state": "pending_check"]
        value["settings"] = settings; value["current_target"] = target
        if !bool(settings, "enabled") { value["state"] = "paused" }
        if let prior = value["target"] as? JSON, !sameHealthTarget(prior, target) { value["reconciliation_needed"] = true }
        if let sid = target["session_id"] as? String, let session = try? scoped(db, sid, pid, type: "session") {
            value["session_state"] = session["state"] ?? "unknown"; value["last_seen"] = session["last_seen"] ?? NSNull()
        } else { value["session_state"] = target["session_id"] as? String == "human" ? "owner" : "unknown" }
        value["last_progress_at"] = try healthProgress(db, task: task, target: target).map(healthStamp) ?? NSNull()
        var waits: [JSON] = []
        if let aid = task["active_attempt_id"] as? String, let a = try? scoped(db, aid, pid, type: "attempt"), let resource = a["waiting_for_resource"] {
            waits.append(["kind": "resource", "reason": resource, "since": a["waiting_since"] ?? NSNull()])
        }
        let requests = try scopedTaskRows(db, type: "request", task: task, predicate: "json_extract(data,'$.state')='pending' AND json_extract(data,'$.blocking')=1", limit: 25)
        waits += requests.map { ["kind": "human", "request_id": $0["id"]!, "reason": $0["title"] ?? "Owner answer"] }
        let selected = try selectedTaskProjectionWithoutHealth(db, task: task)
        let blockers = selected["prerequisite_blockers"] as? [JSON] ?? []
        waits += blockers.prefix(25).map { ["kind": "dependency", "detail": $0] }
        let jobs = try scopedTaskRows(db, type: "source_execution", task: task, predicate: "json_extract(data,'$.state') IN ('queued','running')", limit: 25)
        value["running_jobs"] = jobs.map { job -> JSON in
            var row: JSON = [:]; for key in ["id", "state", "started_at", "timeout_seconds", "attempt_id"] { row[key] = job[key] }; return row
        }
        value["known_waits"] = waits
        if let mid = value["request_id"] as? String {
            let deliveries = try Row.fetchAll(db, sql: "SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='delivery' AND project_id=? AND json_extract(data,'$.message_id')=? LIMIT 33", arguments: [pid, mid]).map { try GRDBRecordEnvelopeAdapter.decode($0).object }
            value["deliveries"] = deliveries
            value["delivery_state"] = deliveries.first?["state"] ?? "saved_for_pickup"
        }
        // Health deliberately includes orchestrated/unclaimed members, beyond Active status.
        if !bool(selected,"active_attention") {
            value["state"] = "inactive"; value["attention"] = false; value.removeValue(forKey:"next_check_at")
        }
        value["native_wake"] = "unavailable; MCP pickup only, no model runtime"
        return value
    }

    /// Queue only this message's exact recipients; never load the project outbox.
    private func queueHealthDeliveries(_ db: Database, message: JSON, recipients: [JSON]) throws -> [JSON] {
        let pid = message["project_id"] as! String, mid = message["id"] as! String
        var deliveries = try Row.fetchAll(db, sql: "SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='delivery' AND project_id=? AND json_extract(data,'$.message_id')=? LIMIT 33", arguments:[pid,mid]).map { try GRDBRecordEnvelopeAdapter.decode($0).object }
        for recipient in recipients {
            let sid = recipient["session_id"] as! String, generation = recipient["authorization_generation"] as! String
            let session = try scoped(db,sid,pid,type:"session")
            guard session["role"] as? String == "worker", canReceive(session,project:pid), sessionGeneration(session) == generation else { throw CoreError("RECIPIENT_CHANGED", "Health recipient authorization changed before pickup queueing.") }
            if deliveries.contains(where: { $0["recipient_session_id"] as? String == sid && $0["recipient_authorization_generation"] as? String == generation }) { continue }
            let delivery: JSON = ["id":uuid(),"project_id":pid,"message_id":mid,"recipient_session_id":sid,"recipient_authorization_generation":generation,"recipient_role":recipient["recipient_role"] ?? "health_handler","state":"queued","push_state":"unavailable","push_reason":"System health requests have no qualified native wake; available on exact-session MCP pickup.","revision":1,"created_at":now()]
            try save(db,delivery,type:"delivery");deliveries.append(delivery)
        }
        return deliveries
    }

    private var healthActor: Caller { Caller(role: "owner", installation: "work-health-service", projectIDs: []) }
    @discardableResult private func healthNote(_ db: Database, task: JSON, body: String, target: JSON?, request: JSON? = nil) throws -> JSON {
        let pid = task["project_id"] as! String
        var message: JSON = ["id": uuid(), "project_id": pid, "task_id": task["id"]!, "kind": "work_health", "origin": "system",
                             "body": body, "author": "work-health-service", "author_display": "Checklist work health", "author_session_id": "service",
                             "requires_action": false, "revision": 1, "created_at": now()]
        if let request { message["health_request"] = request }
        try save(db, message, type: "message")
        var recipients: [JSON] = []
        if let target, let sid = target["session_id"] as? String, let session = try? scoped(db, sid, pid, type: "session"),
           canReceive(session, project: pid), sessionGeneration(session) == target["generation"] as? String {
            recipients = [["session_id": sid, "authorization_generation": sessionGeneration(session), "recipient_role": "health_handler"]]
        }
        let deliveries = try queueHealthDeliveries(db, message: message, recipients: recipients)
        try event(db, caller: healthActor, project: pid, entity: task["id"] as? String, kind: "work_health_note", data: ["message_id": message["id"]!])
        message["deliveries"] = deliveries
        return message
    }
    private func healthCoordinators(_ db: Database, task: JSON, excluding sid: String?) throws -> [JSON] {
        var seen = Set<String>()
        return try scopedTaskGroups(db, task: task).compactMap { group in
            guard !bool(group, "archived"), let o = group["orchestration"] as? JSON, o["state"] as? String == "active",
                  let id = o["session_id"] as? String, id != sid, seen.insert(id).inserted else { return nil }
            return ["session_id": id, "generation": o["session_authorization_generation"] ?? ""]
        }
    }
    private func healthOutcome(_ db: Database, task: JSON, request: inout JSON, outcome: String, body: String) throws {
        guard request["outcome"] == nil else { return }
        request["outcome"] = outcome; request["outcome_at"] = now()
        let note = try healthNote(db, task: task, body: body, target: nil)
        try notifyHealthCoordinators(db, task: task, request: request, note: note)
        request["outcome_note_id"] = note["id"]
    }

    private func notifyHealthCoordinators(_ db: Database, task: JSON, request: JSON, note: JSON) throws {
        let recipients = try healthCoordinators(db, task: task, excluding: (request["target"] as? JSON)?["session_id"] as? String)
        for target in recipients {
            guard let session = try? scoped(db, target["session_id"] as! String, task["project_id"] as! String, type: "session"),
                  canReceive(session, project: task["project_id"] as! String), sessionGeneration(session) == target["generation"] as? String else { continue }
            _ = try queueHealthDeliveries(db, message: note, recipients: [["session_id": session["id"]!, "authorization_generation": sessionGeneration(session), "recipient_role": "health_coordinator"]])
        }
    }

    /// Runs one bounded page on the service queue. Restarting resets only the scan
    /// position; all requests/deadlines/outcomes survive in the domain transaction.
    public func runWorkHealthChecks(at date: Date = Date()) throws -> [String: Any] {
        let lease = try storageAdmission.acquire(); defer { lease.finish() }
        return try ArchiveStorageGate.withExclusive(root: root) { _ in
            try dbQueue.writeWithoutTransaction { db in
                var result: JSON = [:]
                var nextPosition: Int64 = 0
                try withValidatedDomainTransaction(db) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT r.rowid AS position, \(Self.canonicalColumns(alias: "r"))
                    FROM records r JOIN records p ON p.id=r.project_id AND p.type='project'
                    WHERE r.type='task' AND r.rowid>? AND COALESCE(json_extract(p.data,'$.archived'),0)=0
                    AND COALESCE(json_extract(p.data,'$.work_health_settings.enabled'),1)=1
                    AND COALESCE(json_extract(r.data,'$.archived'),0)=0 AND COALESCE(json_extract(r.data,'$.trashed'),0)=0
                    AND (json_extract(r.data,'$.active_attempt_id') IS NOT NULL
                         OR EXISTS (SELECT 1 FROM records s WHERE s.id=json_extract(r.data,'$.status_id') AND s.type='status' AND s.project_id=r.project_id AND json_extract(s.data,'$.category')='active')
                         OR EXISTS (SELECT 1 FROM records g WHERE g.type='group' AND g.project_id=r.project_id AND json_extract(g.data,'$.kind')='triage' AND COALESCE(json_extract(g.data,'$.archived'),0)=0
                           AND EXISTS (SELECT 1 FROM json_each(CASE WHEN json_array_length(json_extract(g.data,'$.members'))>0 THEN json_extract(g.data,'$.members') ELSE json_extract(g.data,'$.task_ids') END) m WHERE (CASE WHEN m.type='object' THEN json_extract(m.value,'$.task_id') ELSE m.value END)=r.id)))
                    ORDER BY r.rowid LIMIT 100
                    """, arguments: [workHealthScanPosition])
                var inspected = 0, changed = 0
                for row in rows {
                    let task = try GRDBRecordEnvelopeAdapter.decode(row).object
                    // Advisory attention retains orchestration/sibling handling; it is not the Active filter.
                    if try bool(selectedTaskProjectionWithoutHealth(db, task: task), "active_attention") {
                        if try checkWorkHealth(db, task: task, at: date) { changed += 1 }; inspected += 1
                    }
                }
                nextPosition = rows.count < 100 ? 0 : (rows.last?["position"] as Int64? ?? 0)
                let enabled = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM records WHERE type='project' AND COALESCE(json_extract(data,'$.archived'),0)=0 AND COALESCE(json_extract(data,'$.work_health_settings.enabled'),1)=1") ?? 0
                result = ["scanned": rows.count, "inspected": inspected, "changed":changed, "has_more": rows.count == 100, "enabled": enabled > 0]
                return .commit
                }
                workHealthScanPosition = nextPosition
                return result
            }
        }
    }
    func checkWorkHealth(_ db: Database, task original: JSON, at date: Date) throws -> Bool {
        var task = original
        let project = try record(db, task["project_id"] as! String, type: "project"), settings = workHealthSettings(project)
        guard bool(settings, "enabled") else { return false }
        let target = try workHealthTarget(db, task: task), stamp = healthStamp(date)
        let progress = try healthProgress(db, task: task, target: target)
        let progressToken = try healthProgressToken(db, task: task, target: target)
        var health = task["work_health"] as? JSON ?? [:]
        let previous = health
        if let old = health["target"] as? JSON, !sameHealthTarget(old, target) { health = [:] }
        health["target"] = target
        let interval = TimeInterval(int(settings, "inactivity_minutes") * 60), grace = TimeInterval(int(settings, "response_grace_minutes") * 60)
        let configGeneration = project["work_health_generation"] as? String ?? "initial"
        let lastObserved = healthTime(health["observed_at"])
        // Backward wall-clock changes never produce negative or immediate timeouts.
        let rebased = lastObserved.map { date < $0 } ?? false
        if health.isEmpty || health["baseline_at"] == nil { health["baseline_at"] = healthStamp(max(progress ?? date, healthTime(project["work_health_changed_at"]) ?? .distantPast)) }
        if health["settings_generation"] as? String != configGeneration || rebased {
            if health["settings_generation"] != nil { health["baseline_at"] = stamp; health["next_check_at"] = healthStamp(date.addingTimeInterval(interval)) }
            if let mid = health["request_id"] as? String, var message = try? scoped(db, mid, task["project_id"] as! String, type: "message"), var request = message["health_request"] as? JSON, request["outcome"] == nil, health["state"] as? String == "awaiting_response" {
                request["deadline"] = healthStamp(date.addingTimeInterval(grace)); message["health_request"] = request; try save(db, revised(message), type: "message"); health["deadline"] = request["deadline"]; health["next_check_at"] = request["deadline"]
            }
            health["settings_generation"] = configGeneration
        }
        let baseline = max(healthTime(health["baseline_at"]) ?? date, min(progress ?? .distantPast, date))
        let due = healthTime(health["next_check_at"]) ?? baseline.addingTimeInterval(interval)
        if let mid = health["request_id"] as? String, var message = try? scoped(db, mid, task["project_id"] as! String, type: "message"), var request = message["health_request"] as? JSON, request["outcome"] == nil {
            if let progress, let sent = healthTime(request["requested_at"]), progress > sent || (request["progress_token"] as? String).map({ $0 != progressToken }) == true {
                try healthOutcome(db, task: task, request: &request, outcome: "progress_observed", body: "Work health resumed: substantive progress from the current attempt or accepted child answered check \(mid). Work authority is unchanged.")
                health.removeValue(forKey: "request_id"); health.removeValue(forKey: "deadline"); health["state"] = "current"; health["attention"] = false; health["baseline_at"] = healthStamp(progress); health["next_check_at"] = healthStamp(progress.addingTimeInterval(interval))
            } else if let deadline = healthTime(request["deadline"]), date >= deadline, health["state"] as? String != "no_response" {
                let note = try healthNote(db, task: task, body: "No response to work health check \(mid) by \(healthStamp(deadline)). Delivery is not acknowledgment or useful progress. The handler may be busy, waiting or unavailable; no abandonment, completion, release or reassignment is inferred.", target: nil)
                try notifyHealthCoordinators(db, task: task, request: request, note: note)
                health["state"] = "no_response"; health.removeValue(forKey: "next_check_at"); health["attention"] = true; health["no_response_note_id"] = note["id"]
            }
            message["health_request"] = request; try save(db, message, type: "message")
        } else if date >= max(due, baseline.addingTimeInterval(interval)) {
            let deadline = healthStamp(date.addingTimeInterval(grace))
            let request: JSON = ["target": target, "task_revision": int(task, "revision"), "acceptance_revision": int(task, "acceptance_revision"), "manifest_id": task["current_manifest_id"] ?? NSNull(), "requested_at": stamp, "last_progress_at": progress.map(healthStamp) ?? NSNull(), "progress_token": progressToken, "deadline": deadline]
            let note = try healthNote(db, task: task, body: "Work health check: does work continue? Last substantive progress: \(progress.map(healthStamp) ?? "not recorded"). Reply to this exact note with current progress or a known wait, or call work_health_respond with request_id from this note. Response due \(deadline). This is an advisory check, not a new claim. Native wake is unavailable; MCP pickup is queued when this exact session remains eligible.", target: target, request: request)
            health["request_id"] = note["id"]; health["deadline"] = deadline; health["next_check_at"] = deadline; health["state"] = "awaiting_response"; health["attention"] = target["kind"] as? String == "missing_handler"
        } else if health["request_id"] == nil {
            health["state"] = target["kind"] as? String == "missing_handler" ? "missing_handler" : "current"
            if target["kind"] as? String == "missing_handler" { health["attention"] = true }
            health["next_check_at"] = healthStamp(max(due, baseline.addingTimeInterval(interval)))
        }
        // No unchanged tick writes/events. observed_at anchors clock rollback only
        // when something meaningful in this advisory state actually changes.
        if try jsonString(health) != jsonString(previous) {
            health["observed_at"] = stamp; task["work_health"] = health
            try save(db, revised(task), type: "task")
            try event(db, caller: healthActor, project: task["project_id"] as? String, entity: task["id"] as? String, kind: "work_health_changed")
            return true
        }
        return false
    }

    func workHealthCommand(_ db: Database, _ p: JSON, _ c: Caller, _ method: String) throws -> JSON {
        try worker(c); let pid = try scope(db, p, c, write: method != "work_health_get"), task = try self.task(db, p, pid)
        if method == "work_health_get" { return try workHealthView(db, task: task) }
        try revision(p, task)
        let mid = try text(p, "request_id"), message = try scoped(db, mid, pid, type: "message")
        guard message["task_id"] as? String == task["id"] as? String, message["health_request"] != nil else { throw CoreError("INVALID_INPUT", "Select this ticket's correlated work health request.") }
        let reply: JSON = ["id": uuid(), "project_id": pid, "task_id": task["id"]!, "reply_to": mid, "body": try text(p, "progress"), "author_session_id": c.sessionID ?? "human", "author": c.principal, "origin": "agent", "kind": "reply", "revision": 1, "created_at": now()]
        try save(db, reply, type: "message")
        return try reconcileHealthReply(db, reply: reply, caller: c) ?? [:]
    }

    /// Both MCP replies and qualified native reply receipts use this seam. The
    /// exact current owner/phase/generation/material basis is checked in the writer.
    func reconcileHealthReply(_ db: Database, reply: JSON, caller: Caller) throws -> JSON? {
        guard let mid = reply["reply_to"] as? String, let pid = reply["project_id"] as? String,
              var message = try? scoped(db, mid, pid, type: "message"), var request = message["health_request"] as? JSON,
              let target = request["target"] as? JSON else { return nil }
        guard reply["author_session_id"] as? String == target["session_id"] as? String else { throw CoreError("FORBIDDEN", "Only the exact requested handler may answer this work health check.") }
        let sid = target["session_id"] as! String
        guard let session = try? scoped(db, sid, pid, type: "session"), canReceive(session, project: pid), sessionGeneration(session) == target["generation"] as? String else { throw CoreError("STALE_CLAIM", "The requested session generation is no longer eligible; use ordinary fresh claim/handoff recovery.") }
        if let outcome = request["outcome"] { return ["outcome": outcome, "request_id": mid, "replayed": true] }
        var task = try scoped(db, message["task_id"] as! String, pid, type: "task")
        let current = try workHealthTarget(db, task: task)
        var authorized = sameHealthTarget(target, current) && int(request, "acceptance_revision") == int(task, "acceptance_revision") && (request["manifest_id"] as? String) == (task["current_manifest_id"] as? String)
        if authorized, target["kind"] as? String == "orchestration" {
            let project = try record(db,pid,type:"project"), policy = effectivePolicy(project["policy"] as? JSON ?? [:],kind:"")
            let rule = (policy["roles"] as? JSON)?["coordinator"] as? JSON ?? [:]
            authorized = strings(rule,"providers").contains(session["provider"] as? String ?? "")
        }
        if authorized, target["kind"] as? String == "attempt" {
            let a = try scoped(db, target["id"] as! String, pid, type: "attempt")
            let handler = Caller(role: "worker", installation: session["installation"] as? String ?? "", projectIDs: [pid], sessionID: sid, workspace: session["workspace"] as? String, executionDomain: session["execution_domain"] as? String)
            authorized = a["incarnation"] as? String == incarnation && a["principal"] as? String == handler.principal
            if authorized { do { try requireLiveAncestry(db, attempt: a); try verifyPolicyAuthority(db, attempt: a, caller: handler) } catch { authorized = false } }
        }
        let outcome = authorized ? "resumed" : "fresh_claim_or_handoff_required"
        try healthOutcome(db, task: task, request: &request, outcome: outcome, body: authorized ? "Work health resumed after correlated reply to \(mid): \(reply["body"] as? String ?? ""). The same current handler and phase remain authorized; assignment and claim are retained." : "Late work health reply to \(mid) retained. Ownership, phase, material basis or authority changed; use ordinary fresh claim/handoff reconciliation. Newer work and assignments were preserved.")
        request["response_id"] = reply["id"]; message["health_request"] = request; try save(db, revised(message), type: "message")
        if authorized {
            var health = task["work_health"] as? JSON ?? [:]
            if health["request_id"] as? String == mid {
                let lastProgress = try healthProgress(db, task: task, target: current)
                let settings = workHealthSettings(try record(db, pid, type: "project"))
                let stillQuiet = Date().timeIntervalSince(lastProgress ?? .distantPast) >= TimeInterval(int(settings, "inactivity_minutes") * 60)
                health["state"] = "current"; health["attention"] = stillQuiet; health["response_without_new_progress"] = stillQuiet; health.removeValue(forKey: "request_id"); health.removeValue(forKey: "deadline")
                // A reply confirms continued handling, not substantive progress.
                // One new inactivity window is allowed; no repeated heartbeat can
                // silently keep advancing the substantive progress clock.
                health["baseline_at"] = now(); health["next_check_at"] = healthStamp(Date().addingTimeInterval(TimeInterval(int(settings, "inactivity_minutes") * 60)))
                health["last_response_id"] = reply["id"]; task["work_health"] = health; try save(db, revised(task), type: "task")
            }
        }
        return ["outcome": outcome, "request_id": mid, "response_id": reply["id"]!]
    }
}
