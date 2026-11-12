import Foundation
import GRDB

/// Advisory supervision only. The durable state lives on tickets and correlated
/// messages, so export/backup retain it without creating another authority store.
extension CommandRouter {
    // Return a fresh value; JSON contains Any and must not be stored as shared state.
    static var defaultWorkHealth: JSON { ["enabled": true, "inactivity_minutes": 20, "response_grace_minutes": 20] }

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
        let pid = (try StoredRecord(task, family: "task").string("project_id"))
        if let aid = task["active_attempt_id"] as? String, let attempt = healthActiveAttempt(db, task: task, project: pid) {
            return ["kind": "attempt", "id": aid, "phase": attempt["phase"] ?? "implementation",
                    "session_id": attempt["session_id"] ?? "human", "generation": attempt["session_authorization_generation"] ?? "",
                    "started_at": attempt["started_at"] ?? NSNull()]
        }
        let groups = try scopedTaskGroups(db, task: task)
        let coordinators = groups.filter { !bool($0, "archived") && ($0["orchestration"] as? JSON)?["state"] as? String == "active" }
        // An ambiguous pair of orchestrators is visible and never guessed.
        if coordinators.count == 1, let group = coordinators.first, let orchestration = group["orchestration"] as? JSON,
           let id = orchestration["id"] as? String, !id.isEmpty, let sid = orchestration["session_id"] as? String, !sid.isEmpty,
           let phase = Optional(((try? scoped(db, task["status_id"] as? String ?? "", group["project_id"] as? String ?? "", type: "status"))?["category"] as? String) == "review" ? "review" : "implementation") {
            return ["kind": "orchestration", "id": id, "triage_id": (try StoredRecord(group, family: "record").requiredValue("id")),
                    "phase": phase, "session_id": sid,
                    "generation": orchestration["session_authorization_generation"] ?? "", "started_at": orchestration["started_at"] ?? NSNull()]
        }
        return ["kind": "missing_handler", "id": "missing", "phase": "unknown", "session_id": "",
                "generation": "", "reason": coordinators.isEmpty ? "No current handler or active phase orchestrator." : coordinators.count > 1 ? "Multiple active phase orchestrators; choose a handler explicitly." : "Active orchestration has no complete durable phase/session identity; refresh the actual orchestration."]
    }
    private func healthActiveAttempt(_ db: Database, task: JSON, project pid: String) -> JSON? {
        guard let aid = task["active_attempt_id"] as? String, let attempt = try? scoped(db, aid, pid, type: "attempt"),
              attempt["state"] as? String == "active" else { return nil }
        return attempt
    }
    /// CL-414: no one holds a Queued, Parked or Blocked ticket with no active attempt, so no work can be late.
    /// Returns that status category. A Review ticket keeps its check: its orchestrator handles it.
    private func healthUnheldCategory(_ db: Database, task: JSON) throws -> String? {
        let pid = try StoredRecord(task, family: "task").string("project_id")
        guard let category = (try? scoped(db, task["status_id"] as? String ?? "", pid, type: "status"))?["category"] as? String,
              Self.unheldHealthCategories.contains(category) else { return nil }
        return healthActiveAttempt(db, task: task, project: pid) == nil ? category : nil
    }
    private static let unheldHealthCategories: Set<String> = ["queued", "parked", "blocked"]
    private func sameHealthTarget(_ a: JSON, _ b: JSON) -> Bool {
        ["kind", "id", "phase", "session_id", "generation"].allSatisfy { (a[$0] as? String ?? "").utf8.elementsEqual((b[$0] as? String ?? "").utf8) }
    }
    private func healthProgress(_ db: Database, task: JSON, target: JSON) throws -> Date? {
        try healthProgressReading(db, task: task, target: target).at
    }
    /// The newest substantive clock, and which clock it is: `ticket_attempt` or `triage_checkpoint` (CL-412).
    private func healthProgressReading(_ db: Database, task: JSON, target: JSON) throws -> (at: Date?, clock: String?) {
        let pid = (try StoredRecord(task, family: "task").string("project_id"))
        if target["kind"] as? String == "attempt" {
            // The accepted tree is capped at 32 descendants by work authority.
            // Include released accepted children too: their completed work is progress.
            let sql = """
                WITH RECURSIVE tree(id,data) AS (
                  SELECT id,data FROM records WHERE type='attempt' AND project_id=? AND id=? AND CASE WHEN json_valid(data) THEN 1 ELSE 0 END
                  UNION ALL SELECT a.id,a.data FROM records a JOIN tree p ON CASE WHEN json_valid(a.data) THEN json_extract(a.data,'$.parent_attempt_id') END=p.id
                  WHERE a.type='attempt' AND a.project_id=? AND CASE WHEN json_valid(a.data) THEN json_extract(a.data,'$.task_id') END=?
                ) SELECT data FROM tree
                """
            let latest = try Double.fetchOne(db,
                sql: "SELECT MAX(checklist_timestamp(COALESCE(json_extract(data,'$.health_progress_at'),json_extract(data,'$.last_checkpoint'),json_extract(data,'$.started_at')))) FROM (" + sql +
                    ")", arguments: [pid, (try StoredRecord(target, family: "health_target").string("id")), pid, (try StoredRecord(task, family: "task").string("id"))])
            return (latest.map { Date(timeIntervalSince1970: $0) }, "ticket_attempt")
        }
        if let gid = target["triage_id"] as? String,
           let orchestration = try scoped(db, gid, pid, type: "group")["orchestration"] as? JSON {
            let triage = healthTime(orchestration["health_progress_at"] ?? orchestration["started_at"])
            // Every attempt of this ticket, whatever its state. The same clock fields as above, so a repeated checkpoint does not advance it.
            // json_valid guard: one malformed attempt record cannot roll back the health page.
            let own = try Double.fetchOne(db,
                sql: "SELECT MAX(checklist_timestamp(COALESCE(json_extract(data,'$.health_progress_at'),json_extract(data,'$.last_checkpoint'),json_extract(data,'$.started_at')))) FROM records WHERE type='attempt' AND project_id=? AND CASE WHEN json_valid(data) THEN json_extract(data,'$.task_id') END=?",
                arguments: [pid, (try StoredRecord(task, family: "task").string("id"))]).map { Date(timeIntervalSince1970: $0) }
            if let own, own >= triage ?? .distantPast { return (own, "ticket_attempt") }
            return (triage, "triage_checkpoint")
        }
        return (nil, nil)
    }
    /// CL-412: for kind orchestration this stays the Triage checkpoint alone. Progress of the ticket
    /// answers a request through the time in checkWorkHealth; a changed token would permit a new relay.
    private func healthProgressToken(_ db: Database, task: JSON, target: JSON) throws -> String {
        let pid = (try StoredRecord(task, family: "task").string("project_id"))
        if target["kind"] as? String == "attempt" {
            // Select only this accepted tree: repeated checkpoint timestamps do not
            // change the token once the substantive clock has been initialized.
            let sql = """
                WITH RECURSIVE tree(id,data) AS (
                  SELECT id,data FROM records WHERE type='attempt' AND project_id=? AND id=? AND CASE WHEN json_valid(data) THEN 1 ELSE 0 END
                  UNION ALL SELECT a.id,a.data FROM records a JOIN tree p ON CASE WHEN json_valid(a.data) THEN json_extract(a.data,'$.parent_attempt_id') END=p.id
                  WHERE a.type='attempt' AND a.project_id=? AND CASE WHEN json_valid(a.data) THEN json_extract(a.data,'$.task_id') END=?
                ) SELECT json_group_array(json_array(id,COALESCE(json_extract(data,'$.health_progress_at'),json_extract(data,'$.last_checkpoint'),json_extract(data,'$.started_at')),json_extract(data,'$.health_progress_id'))) FROM (SELECT * FROM tree ORDER BY id)
                """
            return hash(Data((try String.fetchOne(db,sql:sql,arguments:[pid,(try StoredRecord(target, family: "health_target").string("id")),pid,(try StoredRecord(task,
                family: "task").string("id"))]) ?? "").utf8))
        }
        if let gid = target["triage_id"] as? String, let o = try scoped(db,gid,pid,type:"group")["orchestration"] as? JSON {
            return hash(Data(try jsonString(["id":(try StoredRecord(o, family: "record").requiredValue("id")),"progress_id":o["health_progress_id"] ?? "",
                "at":o["health_progress_at"] ?? o["started_at"] ?? ""]).utf8))
        }
        return "missing"
    }

    /// The one known-wait read for work_health_get and the relay check (CL-389).
    private func healthKnownWaits(_ db: Database, task: JSON, selected: JSON) throws -> [JSON] {
        let pid = (try StoredRecord(task, family: "task").string("project_id"))
        var waits: [JSON] = []
        if let aid = task["active_attempt_id"] as? String, let a = try? scoped(db, aid, pid, type: "attempt"), let resource = a["waiting_for_resource"] {
            waits.append(["kind": "resource", "reason": resource, "since": a["waiting_since"] ?? NSNull()])
        }
        if let reported = (task["work_health"] as? JSON)?["reported_wait"] as? JSON { waits.append(["kind": "reported", "reason": reported["reason"] ?? "", "since": reported["since"] ?? NSNull()]) }
        let requests = try scopedTaskRows(db, type: "request", task: task, predicate: "json_extract(data,'$.state')='pending' AND json_extract(data,'$.blocking')=1", limit: 25)
        waits += try requests.map { ["kind": "human", "request_id": (try StoredRecord($0, family: "record").requiredValue("id")), "reason": $0["title"] ?? "Owner answer"] }
        let blockers = selected["prerequisite_blockers"] as? [JSON] ?? []
        waits += blockers.prefix(25).map { ["kind": "dependency", "detail": $0] }
        return waits
    }
    func workHealthView(_ db: Database, task: JSON, at date: Date = Date(), selectedProjection: JSON? = nil) throws -> JSON {
        let pid = (try StoredRecord(task, family: "task").string("project_id")), target = try workHealthTarget(db, task: task)
        let settings = workHealthSettings(try record(db, pid, type: "project"))
        var value = task["work_health"] as? JSON ?? ["state": "pending_check"]
        value["settings"] = settings; value["current_target"] = target
        if !bool(settings, "enabled") { value["state"] = "paused" }
        if let prior = value["target"] as? JSON, !sameHealthTarget(prior, target) { value["reconciliation_needed"] = true }
        if let sid = target["session_id"] as? String, let session = try? scoped(db, sid, pid, type: "session") {
            value["session_state"] = session["state"] ?? "unknown"; value["last_seen"] = session["last_seen"] ?? NSNull()
        } else { value["session_state"] = target["session_id"] as? String == "human" ? "owner" : "unknown" }
        let reading = try healthProgressReading(db, task: task, target: target)
        value["last_progress_at"] = reading.at.map(healthStamp) ?? NSNull()
        value["last_progress_clock"] = reading.at == nil ? NSNull() : reading.clock ?? NSNull()
        let selected = try selectedProjection ?? selectedTaskHealthFacts(db,task:task)
        let waits = try healthKnownWaits(db, task: task, selected: selected)
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
        // Health deliberately includes orchestrated/unclaimed members, beyond Active status, but not a Queued, Parked or Blocked ticket with no attempt (CL-414).
        if try !bool(selected,"active_attention") || healthUnheldCategory(db, task: task) != nil {
            value["state"] = "inactive"; value["attention"] = false; value.removeValue(forKey:"next_check_at")
        }
        value["native_wake"] = NativeCommunicationRoutes.workHealthWake
        return value
    }

    /// Queue only this message's exact recipients; never load the project outbox.
    /// One relayed turn per session in this interval, whichever ticket asks (CL-389).
    static let healthRelayInterval: TimeInterval = 1200
    /// Relayed requests for one attempt, even when each follows new progress (CL-389).
    static let maximumHealthRelays = 3
    private func claimHealthRelay(_ db: Database, session: String, at date: Date) throws -> Bool {
        let key = "work-health-relay:" + session
        if let raw = try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key=?", arguments: [key]), let last = healthTime(raw),
           date >= last, date.timeIntervalSince(last) < Self.healthRelayInterval { return false }
        try db.execute(sql: "INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [key, healthStamp(date)])
        return true
    }
    private func queueHealthDeliveries(_ db: Database, message: JSON, recipients: [JSON], at date: Date = Date()) throws -> [JSON] {
        let pid = (try StoredRecord(message, family: "message").string("project_id")), mid = (try StoredRecord(message, family: "message").string("id"))
        var deliveries = try Row.fetchAll(db, sql: "SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='delivery' AND project_id=? AND json_extract(data,'$.message_id')=? LIMIT 33", arguments:[pid,mid]).map { try GRDBRecordEnvelopeAdapter.decode($0).object }
        for recipient in recipients {
            let sid = (try StoredRecord(recipient, family: "recipient").string("session_id")), generation = (try StoredRecord(recipient, family: "recipient").string("authorization_generation"))
            let session = try scoped(db,sid,pid,type:"session")
            guard session["role"] as? String == "worker", canReceive(session,project:pid), sessionGeneration(session) == generation else { throw CoreError("RECIPIENT_CHANGED", "Health recipient authorization changed before pickup queueing.") }
            if deliveries.contains(where: { $0["recipient_session_id"] as? String == sid && $0["recipient_authorization_generation"] as? String == generation }) { continue }
            var delivery: JSON = ["id":uuid(),"project_id":pid,"message_id":mid,"recipient_session_id":sid,"recipient_authorization_generation":generation,"recipient_role":recipient["recipient_role"] ?? "health_handler","state":"queued","push_state":"unavailable","push_reason":"This work health notice waits for exact-session MCP pickup.","revision":1,"created_at":now()]
            // Only a request chosen for the relay, and only to its handler. Outcome and no-response notices and the
            // orchestrator's copy must not start a turn; the orchestrator cannot answer this request.
            if (message["health_request"] as? JSON)?["native_relay"] as? Bool == true, recipient["recipient_role"] as? String ?? "health_handler" == "health_handler",
               try claimHealthRelay(db, session: sid, at: date) {
                delivery["native_relay"] = "work_health"; delivery["push_reason"] = "Relayed once when this session has a verified native endpoint. A Codex app thread has none and gets no queue relay, because a service timer starts no Codex turn. Otherwise it waits for exact-session MCP pickup."
            }
            copyRoleLabel(recipient, into: &delivery)
            try save(db,delivery,type:"delivery");deliveries.append(delivery)
        }
        return deliveries
    }

    private var healthActor: Caller { Caller(role: "owner", installation: "work-health-service", projectIDs: []) }
    @discardableResult private func healthNote(_ db: Database, task: JSON, body: String, target: JSON?, request: JSON? = nil, at date: Date = Date()) throws -> JSON {
        let pid = (try StoredRecord(task, family: "task").string("project_id"))
        var message: JSON = ["id": uuid(), "project_id": pid, "task_id": (try StoredRecord(task, family: "record").requiredValue("id")), "kind": "work_health", "origin": "system",
                             "body": body, "author": "work-health-service", "author_display": "Checklist work health", "author_session_id": "service",
                             "requires_action": false, "revision": 1, "created_at": now()]
        if let request { message["health_request"] = request }
        try save(db, message, type: "message")
        var recipients: [JSON] = []
        if let target, let sid = target["session_id"] as? String, let session = try? scoped(db, sid, pid, type: "session"),
           canReceive(session, project: pid), sessionGeneration(session) == target["generation"] as? String {
            recipients = [["session_id": sid, "authorization_generation": sessionGeneration(session), "recipient_role": "health_handler"]]
        }
        // CL-248: work-health notices always reach both roles: the current holder and the Triage orchestrator.
        let current = try workHealthTarget(db, task: task)
        if target == nil, current["kind"] as? String == "attempt", let sid = current["session_id"] as? String,
           let session = try? scoped(db, sid, pid, type: "session"), session["role"] as? String == "worker",
           canReceive(session, project: pid), sessionGeneration(session) == current["generation"] as? String {
            recipients.append(["session_id": sid, "authorization_generation": sessionGeneration(session), "recipient_role": "health_handler"])
        }
        if let group = try ticketOrchestratedTriage(db, task: task), let copy = triageOrchestratorRecipient(db, group: group),
           !recipients.contains(where: { $0["session_id"] as? String == copy["session_id"] as? String }) {
            recipients.append(copy)
        }
        let deliveries = try queueHealthDeliveries(db, message: message, recipients: recipients, at: date)
        try event(db, caller: healthActor, project: pid, entity: task["id"] as? String, kind: "work_health_note", data: ["message_id": (try StoredRecord(message,
            family: "record").requiredValue("id"))])
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
    /// CL-414: ends an open check on a Queued, Parked or Blocked ticket with no attempt and clears its advisory state.
    /// Status, claims and Triage membership stay. The outcome note stays on pickup.
    private func endUnheldWorkHealth(_ db: Database, task original: JSON, category: String) throws -> Bool {
        var task = original
        guard var health = task["work_health"] as? JSON else { return false }
        let previous = health, pid = try StoredRecord(task, family: "task").string("project_id")
        if let mid = health["request_id"] as? String, var message = try? scoped(db, mid, pid, type: "message"),
           var request = message["health_request"] as? JSON, request["outcome"] == nil {
            try healthOutcome(db, task: task, request: &request, outcome: "ticket_\(category)", body: "Work health check \(mid) ended: this ticket is \(category.capitalized) and no one holds it, so no check applies. Work authority is unchanged.")
            message["health_request"] = request; try save(db, revised(message), type: "message")
            // A relay that the bridge did not write starts no turn for an ended request.
            let rows = try Row.fetchAll(db, sql: "SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='delivery' AND project_id=? AND json_extract(data,'$.message_id')=? LIMIT 33", arguments: [pid, mid])
            for var delivery in try rows.map({ try GRDBRecordEnvelopeAdapter.decode($0).object }) where delivery["native_relay"] != nil && delivery["push_state"] as? String == "unavailable" {
                delivery.removeValue(forKey: "native_relay"); delivery["push_reason"] = "This work health request ended before its relay. It waits for exact-session MCP pickup."
                try save(db, revised(delivery), type: "delivery")
            }
        }
        for key in ["request_id", "deadline", "next_check_at", "reported_wait", "reported_wait_overdue", "response_without_new_progress"] { health.removeValue(forKey: key) }
        health["state"] = "inactive"; health["attention"] = false
        guard try jsonString(health) != jsonString(previous) else { return false }
        health["observed_at"] = healthStamp(Date()); task["work_health"] = health
        try save(db, revised(task), type: "task")
        try event(db, caller: healthActor, project: pid, entity: task["id"] as? String, kind: "work_health_changed")
        return true
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
        let pid = try StoredRecord(task, family: "task").string("project_id")
        for target in recipients {
            let sid = try StoredRecord(target, family: "health_target").string("session_id")
            guard let session = try? scoped(db, sid, pid, type: "session"),
                  canReceive(session, project: pid), sessionGeneration(session) == target["generation"] as? String else { continue }
            _ = try queueHealthDeliveries(db, message: note, recipients: [["session_id": (try StoredRecord(session, family: "record").requiredValue("id")),
                "authorization_generation": sessionGeneration(session), "recipient_role": "health_coordinator"]])
        }
    }

    /// Prepare the page and progress clocks without the object gate or writer.
    /// Restarting resets only the scan position; durable requests stay in SQL.
    public func runWorkHealthChecks(at date: Date = Date()) throws -> [String: Any] {
        let lease = try storageAdmission.acquire(); defer { lease.finish() }
        workHealthPreparationLock.lock();defer {workHealthPreparationLock.unlock()}
        var configuration = Configuration();configuration.readonly = true
        configuration.prepareDatabase {db in
            try SchemaMigrations.installStorageCollation(db);Self.installTicketSearchFunctions(db)
        }
        // Never fall back to a long read on the writer if the ordinary pool is
        // unavailable or occupied by a cleanup deadline scan.
        let observer = try DatabaseQueue(path:root.appendingPathComponent("checklist.sqlite").path,configuration:configuration)
        defer {try? observer.close()}
        let fence = WorkHealthPreparationChanges()
        let (position,version) = try dbQueue.writeWithoutTransaction {db in
            var version: Int64 = 0
            try db.inSavepoint {version = try fence.install(db);return .commit}
            return (workHealthScanPosition,version)
        }
        defer {try? dbQueue.writeWithoutTransaction {try fence.remove($0)}}
        let page = try observer.read {db in try autoreleasepool {
            let result = try prepareWorkHealthPage(db,after:position)
            try workHealthPreparationProbe?()
            return result
        }}
        return try ArchiveStorageGate.withExclusive(root: root) { _ in
            try dbQueue.writeWithoutTransaction { db in
                var result: JSON = [:],advance = false
                try withValidatedDomainTransaction(db) {
                    guard let changes = try fence.read(db,version:version) else {
                        // Keep the cursor and use the ordinary 30-second health
                        // wake, rather than rescanning immediately under traffic.
                        result = ["scanned":0,"inspected":0,"changed":0,"has_more":false,"enabled":true,"deferred":true]
                        return .commit
                    }
                    var inspected = 0,changed = 0,processed = 0,refused = 0
                    for item in page.items {
                        guard try workHealthPreparationIsCurrent(db,changes:changes,dependencies:item.dependencies) else {refused += 1;continue}
                        processed += 1
                        switch item.action {
                        case .unheld(let category):
                            if try endUnheldWorkHealth(db,task:item.task,category:category) {changed += 1}
                        case .inspect(let progress):
                            if try checkWorkHealth(db,task:item.task,at:date,prepared:progress) {changed += 1}
                            inspected += 1
                        case .skip:break
                        }
                    }
                    // A known stale item is revisited on the next sweep. Even
                    // a full stale page must yield to quiet tickets after it.
                    advance = true
                    result = ["scanned":page.items.count,"inspected":inspected,"changed":changed,"has_more":page.hasMore,"enabled":page.enabled,"deferred_count":refused]
                    if processed == 0 && refused > 0 {result["deferred"] = true}
                    return .commit
                }
                if advance {workHealthScanPosition = page.nextPosition}
                return result
            }
        }
    }

    private func prepareWorkHealthPage(_ db: Database,after position: Int64) throws -> WorkHealthPreparedPage {
        let pageLimit = 10
        let rows = try Row.fetchAll(db, sql: """
                    WITH triage_members AS MATERIALIZED (
                        SELECT g.project_id,
                               CASE WHEN m.type='object' THEN json_extract(m.value,'$.task_id') ELSE m.value END AS task_id
                        FROM records g, json_each(CASE WHEN json_array_length(json_extract(g.data,'$.members'))>0 THEN json_extract(g.data,'$.members') ELSE json_extract(g.data,'$.task_ids') END) m
                        WHERE g.rowid IN (SELECT rowid FROM records INDEXED BY records_scope WHERE type='group')
                          AND json_extract(g.data,'$.kind')='triage' AND COALESCE(json_extract(g.data,'$.archived'),0)=0
                    )
                    SELECT r.rowid AS position, \(Self.canonicalColumns(alias: "r"))
                    FROM records r JOIN records p ON p.id=r.project_id AND p.type='project'
                    WHERE r.rowid IN (SELECT rowid FROM records INDEXED BY records_scope WHERE type='task') AND r.rowid>? AND COALESCE(json_extract(p.data,'$.archived'),0)=0
                    AND COALESCE(json_extract(p.data,'$.work_health_settings.enabled'),1)=1
                    AND COALESCE(json_extract(r.data,'$.archived'),0)=0 AND COALESCE(json_extract(r.data,'$.trashed'),0)=0
                    AND (json_extract(r.data,'$.active_attempt_id') IS NOT NULL
                         OR EXISTS (SELECT 1 FROM records s WHERE s.id=json_extract(r.data,'$.status_id') AND s.type='status' AND s.project_id=r.project_id AND json_extract(s.data,'$.category')='active')
                         OR EXISTS (SELECT 1 FROM triage_members m WHERE m.project_id=r.project_id AND m.task_id=r.id)
                         OR (json_extract(r.data,'$.work_health.request_id') IS NOT NULL AND EXISTS (SELECT 1 FROM records s WHERE s.id=json_extract(r.data,'$.status_id') AND s.type='status' AND s.project_id=r.project_id AND json_extract(s.data,'$.category') IN ('queued','parked','blocked'))))
                    ORDER BY r.rowid LIMIT ?
                    """, arguments: [position,pageLimit])
        var dependencyRows = 0,dependencyBytes = 0
        let items = try rows.map {row -> WorkHealthPreparedPage.Item in
            let task = try GRDBRecordEnvelopeAdapter.decode(row).object
            let action: WorkHealthPreparedPage.Action
            if let category = try healthUnheldCategory(db,task:task) {action = .unheld(category)}
            // Advisory attention retains orchestration/sibling handling.
            else if try selectedTaskActiveAttention(db,task:task) {
                let target = try workHealthTarget(db,task:task)
                action = .inspect(WorkHealthPreparedProgress(target:target,
                    reading:try healthProgressReading(db,task:task,target:target),
                    token:try healthProgressToken(db,task:task,target:target)))
            } else {action = .skip}
            var dependencies = try prepareWorkHealthDependencies(db,task:task,action:action)
            if dependencyRows + dependencies.ids.count > 32768 || dependencyBytes + dependencies.bytes > 4*1024*1024 {
                dependencies.refuse()
            } else {dependencyRows += dependencies.ids.count;dependencyBytes += dependencies.bytes}
            return .init(task:task,action:action,dependencies:dependencies)
        }
        let enabled = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM records WHERE rowid IN (SELECT rowid FROM records INDEXED BY records_scope WHERE type='project') AND COALESCE(json_extract(data,'$.archived'),0)=0 AND COALESCE(json_extract(data,'$.work_health_settings.enabled'),1)=1") ?? 0
        return .init(items:items,nextPosition:rows.count < pageLimit ? 0 : (rows.last?["position"] as Int64? ?? 0),hasMore:rows.count == pageLimit,enabled:enabled > 0)
    }

    private func prepareWorkHealthDependencies(_ db: Database,task: JSON,action: WorkHealthPreparedPage.Action) throws -> WorkHealthPreparationDependencies {
        var dependencies = WorkHealthPreparationDependencies()
        let pid = try StoredRecord(task,family:"task").string("project_id"),tid = try StoredRecord(task,family:"task").string("id")
        dependencies.include(tid);dependencies.include(task["status_id"] as? String);dependencies.include(task["active_attempt_id"] as? String)
        dependencies.selectedTasks.insert(.init(project:Data(pid.utf8),id:Data(tid.utf8)))
        dependencies.includeProject(pid,facts:try workHealthPreparationProjectFacts(record(db,pid,type:"project")))
        if case .inspect(let progress) = action {
            dependencies.attemptTasks.insert(.init(project:Data(pid.utf8),id:Data(tid.utf8)))
            if progress.target["kind"] as? String == "attempt" {dependencies.include(progress.target["id"] as? String)}
        }
        // Triage attention may depend on a sibling's status/active attempt.
        // Keep those exact identities without retaining their payloads.
        for group in try scopedTaskGroups(db,task:task) where !bool(group,"archived") {
            let groupID = try StoredRecord(group,family:"group").string("id")
            dependencies.include(groupID)
            try visitWorkHealthPreparationMembers(db,group:Data(groupID.utf8),project:Data(pid.utf8)) {member in
                dependencies.include(member)
                guard dependencies.complete else {return false}
                if let sibling = try? scoped(db,String(decoding:member,as:UTF8.self),pid,type:"task") {
                    dependencies.include(sibling["status_id"] as? String)
                }
                return dependencies.complete
            }
            if !dependencies.complete {break}
        }
        return dependencies
    }
    func checkWorkHealth(_ db: Database, task original: JSON, at date: Date, prepared: WorkHealthPreparedProgress? = nil) throws -> Bool {
        var task = original
        let project = try record(db, (try StoredRecord(task, family: "task").string("project_id")), type: "project"), settings = workHealthSettings(project)
        guard bool(settings, "enabled") else { return false }
        let target = try prepared?.target ?? workHealthTarget(db, task: task), stamp = healthStamp(date)
        let reading = try prepared?.reading ?? healthProgressReading(db, task: task, target: target), progress = reading.at
        let progressToken = try prepared?.token ?? healthProgressToken(db, task: task, target: target)
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
            if let mid = health["request_id"] as? String, var message = try? scoped(db, mid, (try StoredRecord(task, family: "task").string("project_id")), type: "message"),
                var request = message["health_request"] as? JSON, request["outcome"] == nil, health["state"] as? String == "awaiting_response" {
                request["deadline"] = healthStamp(date.addingTimeInterval(grace)); message["health_request"] = request; try save(db, revised(message), type: "message"); health["deadline"] = request["deadline"]; health["next_check_at"] = request["deadline"]
            }
            health["settings_generation"] = configGeneration
        }
        // New progress ends a wait named in a reply.
        let waitSince = healthTime((health["reported_wait"] as? JSON)?["since"])
        if health["reported_wait"] != nil, (health["reported_wait"] as? JSON)?["progress_token"] as? String != progressToken || (waitSince != nil && (progress ?? .distantPast) > waitSince!) {
            health.removeValue(forKey: "reported_wait"); health.removeValue(forKey: "reported_wait_overdue"); health.removeValue(forKey: "response_without_new_progress"); health["attention"] = false; task["work_health"] = health
        }
        let baseline = max(healthTime(health["baseline_at"]) ?? date, min(progress ?? .distantPast, date))
        let due = healthTime(health["next_check_at"]) ?? baseline.addingTimeInterval(interval)
        if let mid = health["request_id"] as? String, var message = try? scoped(db, mid, (try StoredRecord(task, family: "task").string("project_id")), type: "message"),
            var request = message["health_request"] as? JSON, request["outcome"] == nil {
            if let progress, let sent = healthTime(request["requested_at"]), progress > sent || (request["progress_token"] as? String).map({ $0 != progressToken }) == true {
                try healthOutcome(db, task: task, request: &request, outcome: "progress_observed", body: "Work health resumed: substantive progress from \(reading.clock == "triage_checkpoint" ? "the Triage checkpoint" : "the ticket's own attempt") answered check \(mid). Work authority is unchanged.")
                health.removeValue(forKey: "request_id"); health.removeValue(forKey: "deadline"); health.removeValue(forKey: "reported_wait"); health["state"] = "current"; health["attention"] = false; health["baseline_at"] = healthStamp(progress); health["next_check_at"] = healthStamp(progress.addingTimeInterval(interval))
            } else if let deadline = healthTime(request["deadline"]), date >= deadline, health["state"] as? String != "no_response" {
                let note = try healthNote(db, task: task, body: "No response to work health check \(mid) by \(healthStamp(deadline)). Delivery is not acknowledgment or useful progress. The handler may be busy, waiting or unavailable; no abandonment, completion, release or reassignment is inferred.", target: nil)
                try notifyHealthCoordinators(db, task: task, request: request, note: note)
                health["state"] = "no_response"; health.removeValue(forKey: "next_check_at"); health["attention"] = true; health["no_response_note_id"] = note["id"]
            }
            message["health_request"] = request; try save(db, message, type: "message")
        // A wait named in a reply stops further requests until new progress (CL-414).
        } else if health["reported_wait"] == nil, date >= max(due, baseline.addingTimeInterval(interval)) {
            let deadline = healthStamp(date.addingTimeInterval(grace))
            // CL-389: a request relays only for new progress, never during a known wait, and at most three times per attempt.
            let relayTarget = target["id"] as? String, relayCount = health["relay_target"] as? String == relayTarget ? int(health, "relay_count", default: 0) : 0
            let relayed = try target["session_id"] != nil && health["relayed_progress_token"] as? String != progressToken && relayCount < Self.maximumHealthRelays && healthKnownWaits(db, task: task, selected: selectedTaskHealthFacts(db,task:task)).isEmpty
            var request: JSON = ["target": target, "task_revision": int(task, "revision"), "acceptance_revision": int(task, "acceptance_revision"), "manifest_id": task["current_manifest_id"] ?? NSNull(), "requested_at": stamp, "last_progress_at": progress.map(healthStamp) ?? NSNull(), "progress_clock": progress == nil ? NSNull() : reading.clock ?? NSNull(), "progress_token": progressToken, "deadline": deadline]
            if relayed { request["native_relay"] = true }
            let note = try healthNote(db, task: task, body: "Work health check: does work continue? Last substantive progress: \(progress.map { healthStamp($0) + (reading.clock == "triage_checkpoint" ? " (the Triage checkpoint)" : " (the ticket's own attempt)") } ?? "not recorded"). Reply to this exact note with current progress, or call work_health_respond with request_id from this note and known_wait for a known wait. Response due \(deadline). This is an advisory check, not a new claim. It is also available on MCP pickup while this exact session remains eligible.", target: target, request: request, at: date)
            if (note["deliveries"] as? [JSON])?.contains(where: { $0["native_relay"] != nil }) == true { health["relayed_progress_token"] = progressToken; health["relay_target"] = relayTarget ?? NSNull(); health["relay_count"] = relayCount + 1 }
            health["request_id"] = note["id"]; health["deadline"] = deadline; health["next_check_at"] = deadline; health["state"] = "awaiting_response"; health["attention"] = target["kind"] as? String == "missing_handler"
        } else if health["request_id"] == nil {
            health["state"] = target["kind"] as? String == "missing_handler" ? "missing_handler" : "current"
            if target["kind"] as? String == "missing_handler" { health["attention"] = true }
            // CL-414: a named wait stops requests, not visibility. Past one interval with no progress, it raises attention.
            if health["reported_wait"] != nil {
                // A pause or a clock rebase moves the baseline, so the interval starts again from there.
                let overdueAt = max(waitSince ?? baseline, baseline).addingTimeInterval(interval)
                health["next_check_at"] = healthStamp(overdueAt)
                if date >= overdueAt { health["attention"] = true; health["reported_wait_overdue"] = true }
            } else { health["next_check_at"] = healthStamp(max(due, baseline.addingTimeInterval(interval))) }
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
        // A known wait answers the check by itself; the check text offers it with no progress (CL-414).
        guard p["progress"] != nil || p["known_wait"] != nil else { throw CoreError("INVALID_INPUT", "Answer with progress, known_wait or both.") }
        let knownWait: String? = try p["known_wait"] == nil ? nil : text(p, "known_wait", max: 200)
        let body = try p["progress"] == nil ? "Known wait: " + (knownWait ?? "") : text(p, "progress")
        let reply: JSON = ["id": uuid(), "project_id": pid, "task_id": (try StoredRecord(task, family: "record").requiredValue("id")), "reply_to": mid, "body": body,
            "author_session_id": c.sessionID ?? "human", "author": c.principal, "origin": "agent", "kind": "reply", "revision": 1, "created_at": now()]
        let result = try reconcileHealthReply(db, reply: reply, caller: c) ?? [:]
        // CL-414: a repeat of an answered check that no longer applies changes nothing.
        if result["stale"] as? Bool == true { return ["outcome": "stale_request", "request_id": mid, "replayed": true] }
        try save(db, reply, type: "message")
        // A named wait stops further requests until new progress. A replayed answer with no wait clears it.
        if result["outcome"] as? String == "resumed" {
            var current = try scoped(db, (try StoredRecord(task, family: "record").string("id")), pid, type: "task"), health = current["work_health"] as? JSON ?? [:]
            let before = health["reported_wait"] != nil
            if let knownWait {
                health["reported_wait"] = ["reason": knownWait, "since": now(), "request_id": mid, "progress_token": try healthProgressToken(db, task: current, target: workHealthTarget(db, task: current))] as JSON
                health["next_check_at"] = healthStamp(Date().addingTimeInterval(TimeInterval(int(workHealthSettings(try record(db, pid, type: "project")), "inactivity_minutes") * 60)))
            } else { health.removeValue(forKey: "reported_wait"); health.removeValue(forKey: "reported_wait_overdue") }
            if before || knownWait != nil { current["work_health"] = health; try save(db, revised(current), type: "task") }
        }
        return result
    }

    /// Both MCP replies and qualified native reply receipts use this seam. The
    /// exact current owner/phase/generation/material basis is checked in the writer.
    func reconcileHealthReply(_ db: Database, reply: JSON, caller: Caller) throws -> JSON? {
        guard let mid = reply["reply_to"] as? String, let pid = reply["project_id"] as? String,
              var message = try? scoped(db, mid, pid, type: "message"), var request = message["health_request"] as? JSON,
              let target = request["target"] as? JSON else { return nil }
        guard reply["author_session_id"] as? String == target["session_id"] as? String else { throw CoreError("FORBIDDEN", "Only the exact requested handler may answer this work health check.") }
        let sid = (try StoredRecord(target, family: "health_target").string("session_id"))
        guard let session = try? scoped(db, sid, pid, type: "session"), canReceive(session, project: pid), sessionGeneration(session) == target["generation"] as? String else { throw CoreError("STALE_CLAIM", "The requested session generation is no longer eligible; use ordinary fresh claim/handoff recovery.") }
        var task = try scoped(db, (try StoredRecord(message, family: "message").string("task_id")), pid, type: "task")
        let current = try workHealthTarget(db, task: task)
        if let outcome = request["outcome"] {
            var replay: JSON = ["outcome": outcome, "request_id": mid, "replayed": true]
            // CL-414: a repeat of "resumed" acts only for the target that it answered. A newer holder or a newer check is not its to change.
            if outcome as? String == "resumed" {
                let open = (task["work_health"] as? JSON)?["request_id"] as? String
                if !sameHealthTarget(target, current) || int(request, "acceptance_revision") != int(task, "acceptance_revision") || (request["manifest_id"] as? String) != (task["current_manifest_id"] as? String) || (open != nil && open != mid) { replay["stale"] = true }
            }
            return replay
        }
        var authorized = sameHealthTarget(target, current) && int(request, "acceptance_revision") == int(task, "acceptance_revision") && (request["manifest_id"] as? String) == (task["current_manifest_id"] as? String)
        if authorized, target["kind"] as? String == "orchestration" {
            let project = try record(db,pid,type:"project"), policy = effectivePolicy(project["policy"] as? JSON ?? [:],kind:"")
            let rule = (policy["roles"] as? JSON)?["coordinator"] as? JSON ?? [:]
            authorized = strings(rule,"providers").contains(session["provider"] as? String ?? "")
        }
        if authorized, target["kind"] as? String == "attempt" {
            let a = try scoped(db, (try StoredRecord(target, family: "health_target").string("id")), pid, type: "attempt")
            let handler = Caller(role: "worker", installation: session["installation"] as? String ?? "", projectIDs: [pid], sessionID: sid, workspace: session["workspace"] as? String, executionDomain: session["execution_domain"] as? String)
            authorized = a["incarnation"] as? String == incarnation && a["principal"] as? String == handler.principal
            if authorized {
                do {
                    try requireLiveAncestry(db, attempt: a)
                    try verifyPolicyAuthority(db, attempt: a, caller: handler)
                } catch let error as CoreError where error.code == "CANONICAL_RECORD_INVALID" {
                    // Corruption is not a change of authority: roll back the reply and outcome.
                    throw error
                } catch { authorized = false }
            }
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
        return ["outcome": outcome, "request_id": mid, "response_id": (try StoredRecord(reply, family: "record").requiredValue("id"))]
    }
}
