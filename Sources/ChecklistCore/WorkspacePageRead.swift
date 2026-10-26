import Foundation
import GRDB

private struct WorkspaceTaskIdentity: Hashable {
    let project: SnapshotRecordIdentity
    let task: SnapshotRecordIdentity
    init(project: String,task: String) {
        self.project = SnapshotRecordIdentity(project)
        self.task = SnapshotRecordIdentity(task)
    }
}

extension CommandRouter {
    func workspaceCoverage(_ db: Database,projectsJSON: String) throws -> Int {
        // Separate exact project/global ranges let the covering events_scope
        // index supply coverage without the combined OR scan of event rows.
        try Int.fetchOne(db,sql:"""
            SELECT COALESCE(MAX(latest),0) FROM (
              SELECT (SELECT MAX(seq) FROM events WHERE project_id=p.value) latest FROM json_each(?) p
              UNION ALL SELECT MAX(seq) FROM events WHERE project_id IS NULL)
            """,arguments:[projectsJSON]) ?? 0
    }
    /// Owner workspace surfaces keep one bounded value, separate from the full
    /// snapshot index. An omitted row never means that the record was deleted.
    func workspacePage(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try workspacePage(db,p,c,sharedMetadata:nil)
    }
    private func workspacePage(_ db: Database,_ p: JSON,_ c: Caller,sharedMetadata: JSON?) throws -> JSON {
        try owner(c)
        if p["surface"] as? String == "overview" { return try overviewGroupsPage(db,p,c) }
        let surfaces = ["requests","human_tasks","epics","activity","epic_tasks","epic_candidates","triage_tasks","triage_candidates","worker_sessions","record","recent_reviews","completed_since"] + Self.needSurfaces
        let surface = try text(p,"surface",max:40)
        guard surfaces.contains(surface) else {throw CoreError("INVALID_INPUT","Choose a supported workspace surface.")}
        let projectIDs: [String]
        if p["project_id"] != nil {projectIDs = [try scope(db,p,c)]}
        else {projectIDs = try projects(db,c).filter {!bool($0,"archived")}.compactMap {$0["id"] as? String}}
        let projectsJSON = try jsonString(projectIDs)
        let query = try text(p,"text",max:4000,required:false)
        let recordID = try text(p,"record_id",max:4000,required:false)
        // CL-67: the owner digest lists tickets completed after `since` (the owner's last visit).
        let since = try text(p,"since",max:40,required:false)
        let sinceDate = since.isEmpty ? nil : ISO8601DateFormatter().date(from:since)
        if surface == "completed_since" && sinceDate == nil {throw CoreError("INVALID_INPUT","Give the digest start as an ISO 8601 time.")}
        let latest = try workspaceCoverage(db,projectsJSON:projectsJSON)
        let identity: JSON = ["surface":surface,"projects":projectIDs,"query":query,"record":recordID,"since":since,"closed":bool(p,"include_archived"),"locale":Locale.current.identifier,"authorization":try authorizationScope(db,c),"coverage":latest]
        let cursorScope = "workspace-page-v1:"+hash(Data(try jsonString(identity).utf8))
        let offset = try cursorSequence(db,p,caller:c,scope:cursorScope)
        let limit = min(max(int(p,"limit",default:50),1),100)
        var args: StatementArguments = ["projects":projectsJSON,"query":query,"record":recordID,"closed":bool(p,"include_archived") ? 1 : 0,"limit":limit+1,"offset":offset]
        let select: String
        let predicate: String
        let order: String
        if surface == "activity" {
            select = "SELECT e.id,e.project_id,e.entity_id,e.actor,e.kind,e.occurred_at,e.data FROM events e WHERE e.project_id IN (SELECT value FROM json_each(:projects)) AND (:query='' OR checklist_contains(e.kind,:query))"
            predicate = "";order = " ORDER BY e.seq DESC"
        } else {
            var filter = "r.project_id IN (SELECT value FROM json_each(:projects))"
            switch surface {
            case "requests":filter += " AND r.type='request' AND COALESCE(json_extract(r.data,'$.state'),'pending') NOT IN ('answered','canceled','\(LegacyStoredValue.canceled)','superseded','resolved') AND (:closed=1 OR COALESCE(json_extract(r.data,'$.owner_snoozed'),0)=0)"
            case "worker_sessions":filter="(r.project_id IN (SELECT value FROM json_each(:projects)) OR EXISTS (SELECT 1 FROM json_each(json_extract(r.data,'$.project_ids')) p WHERE p.value IN (SELECT value FROM json_each(:projects)))) AND r.type='session' AND json_extract(r.data,'$.role')='worker' AND (CASE WHEN COALESCE(json_extract(r.data,'$.state'),'') IN ('ended','revoked') THEN 1 ELSE 0 END)=:closed"
            case "human_tasks":filter += " AND r.type='task' AND COALESCE(json_extract(r.data,'$.archived'),0)=0 AND COALESCE(json_extract(r.data,'$.trashed'),0)=0 AND (json_extract(r.data,'$.planned_assignee')='human' OR json_extract(r.data,'$.planned_assignee.kind')='human' OR json_extract(r.data,'$.assignee')='human') AND NOT EXISTS (SELECT 1 FROM records s WHERE s.type='status' AND s.project_id=r.project_id AND s.id=json_extract(r.data,'$.status_id') AND json_extract(s.data,'$.category') IN ('done','canceled','\(LegacyStoredValue.canceled)'))"
            case "epics":filter += " AND r.type='group' AND json_extract(r.data,'$.kind')='epic' AND (:closed=1 OR COALESCE(json_extract(r.data,'$.archived'),0)=0)"
            case "epic_tasks","epic_candidates","triage_tasks","triage_candidates":
                guard !recordID.isEmpty else {throw CoreError("INVALID_INPUT","Select an Epic.")}
                let group = try record(db,recordID,type:"group")
                guard projectIDs.contains(where:{SnapshotRecordIdentity($0)==SnapshotRecordIdentity(group["project_id"] as? String ?? "")}),["epic","triage"].contains(group["kind"] as? String ?? "") else {throw CoreError("NOT_FOUND","This Epic is outside the selected scope.")}
                let groupProject = (try StoredRecord(group, family: "group").string("project_id"))
                args += ["groupProject":Data(groupProject.utf8)]
                guard group["kind"] as? String == (surface.hasPrefix("triage") ? "triage" : "epic") else {throw CoreError("INVALID_INPUT","Choose the corresponding container kind.")}
                filter += " AND r.project_id=CAST(:groupProject AS TEXT) AND r.type='task' AND COALESCE(json_extract(r.data,'$.trashed'),0)=0"
                if surface == "triage_candidates" {
                    let review=group["phase"] as? String == "review"
                    filter += " AND " + (review ? "" : "NOT ") + "EXISTS (SELECT 1 FROM records status WHERE status.type='status' AND status.project_id=r.project_id AND status.id=json_extract(r.data,'$.status_id') AND json_extract(status.data,'$.category')='review')"
                }
                if surface == "triage_tasks" || surface == "triage_candidates" {filter += (surface == "triage_candidates" ? " AND NOT" : " AND") + " EXISTS (SELECT 1 FROM records g,json_each(CASE WHEN json_array_length(json_extract(g.data,'$.members'))>0 THEN json_extract(g.data,'$.members') ELSE json_extract(g.data,'$.task_ids') END) m WHERE g.type='group' AND g.project_id=r.project_id AND g.id=:record AND (CASE WHEN m.type='object' THEN json_extract(m.value,'$.task_id') ELSE m.value END)=r.id)"}
                else {filter += " AND COALESCE(json_extract(r.data,'$.epic_id'),'')"+(surface == "epic_tasks" ? "=" : "<>")+":record COLLATE BINARY"}
                filter += " AND (CASE WHEN COALESCE(json_extract(r.data,'$.archived'),0)=1 OR EXISTS (SELECT 1 FROM records s WHERE s.type='status' AND s.project_id=r.project_id AND s.id=json_extract(r.data,'$.status_id') AND json_extract(s.data,'$.category') IN ('done','canceled','\(LegacyStoredValue.canceled)')) THEN 1 ELSE 0 END)=:closed"
            case _ where Self.needSurfaces.contains(surface):
                args += ["quietBefore":Date().timeIntervalSince1970 - Self.quietCheckpointSeconds,"todayStart":Calendar.current.startOfDay(for:Date()).timeIntervalSince1970]
                filter += " AND " + Self.needFilter(surface)
            // CL-67: the latest three verdicts of each project, so a busy project cannot hide another one.
            case "recent_reviews":filter += """
                 AND r.type='review' AND r.id IN (
                   SELECT id FROM (
                     SELECT id,ROW_NUMBER() OVER (PARTITION BY project_id ORDER BY checklist_timestamp(json_extract(data,'$.created_at')) DESC,id DESC) AS review_rank
                     FROM records WHERE type='review' AND project_id IN (SELECT value FROM json_each(:projects))
                   ) WHERE review_rank<=3)
                """
            case "completed_since":
                args += ["since":sinceDate!.timeIntervalSince1970]
                filter += " AND r.type='task' AND COALESCE(json_extract(r.data,'$.trashed'),0)=0 AND checklist_timestamp(json_extract(r.data,'$.completed_at'))>:since AND EXISTS (SELECT 1 FROM records s WHERE s.id=json_extract(r.data,'$.status_id') AND s.type='status' AND s.project_id=r.project_id AND json_extract(s.data,'$.category') IN ('done','completed'))"
            case "record":filter = "(r.project_id IN (SELECT value FROM json_each(:projects)) OR (r.type='project' AND r.id IN (SELECT value FROM json_each(:projects)))) AND r.id=:record AND r.type IN ('request','group','project')"
            default:break
            }
            filter += " AND (:query='' OR checklist_contains(COALESCE(json_extract(r.data,'$.title'),'')||' '||COALESCE(json_extract(r.data,'$.name'),'')||' '||COALESCE(json_extract(r.data,'$.label'),'')||' '||COALESCE(json_extract(r.data,'$.native_conversation_title'),'')||' '||COALESCE(json_extract(r.data,'$.key'),'')||' '||COALESCE(json_extract(r.data,'$.brief'),''),:query))"
            select = "SELECT "+Self.canonicalColumns(alias:"r")+" FROM records r WHERE "+filter
            predicate = ""
            if surface == "requests" {args += ["invalidDate":Date.distantPast.timeIntervalSince1970];order = " ORDER BY COALESCE(json_extract(r.data,'$.blocking'),0) DESC,(checklist_timestamp(json_extract(r.data,'$.created_at'))=:invalidDate),checklist_timestamp(json_extract(r.data,'$.created_at')),r.id"}
            else if surface == "epics" {order = " ORDER BY json_extract(r.data,'$.name') COLLATE checklist_human_order,r.id"}
            else if surface == "recent_reviews" {order = " ORDER BY checklist_timestamp(json_extract(r.data,'$.created_at')) DESC,r.id DESC"}
            else if surface == "completed_since" || surface == "needs_done_today" {order = " ORDER BY checklist_timestamp(json_extract(r.data,'$.completed_at')) DESC,r.id DESC"}
            else {order = " ORDER BY checklist_timestamp(json_extract(r.data,'$.updated_at')) DESC,r.id DESC"}
        }
        let total = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM ("+select+predicate+")",arguments:args) ?? 0
        let fetched = try Row.fetchAll(db,sql:select+predicate+order+" LIMIT :limit OFFSET :offset",arguments:args)
        let selectedRows = Array(fetched.prefix(limit))
        let cleanedCounts = surface == "activity" ? [:] : try workspaceCleanedOriginalCounts(db,rows:selectedRows)
        var rows: [JSON] = []
        for row in selectedRows {
            if surface == "activity" {
                rows.append(["id":row["id"] as String,"project_id":row["project_id"] as String,"entity_id":row["entity_id"] as String? ?? "","actor":row["actor"] as String,"kind":row["kind"] as String,"occurred_at":row["occurred_at"] as String,"data":jsonObject(row["data"])])
                continue
            }
            let envelope=try GRDBRecordEnvelopeAdapter.decode(row)
            let raw = envelope.object,type = envelope.type
            let taskKey = WorkspaceTaskIdentity(project:raw["project_id"] as? String ?? "",task:raw["id"] as? String ?? "")
            var value = type == "task" ? try selectedTaskProjection(db,task:raw,cleanedOriginalCount:cleanedCounts[taskKey] ?? 0) : contextRecord(raw,type:type,caller:c)
            let linkedProject = ["request", "review"].contains(type)
                ? try StoredRecord(raw, family: type).string("project_id") : ""
            if type == "request",let taskID = raw["task_id"] as? String,let task = try? scoped(db,taskID,linkedProject,type:"task") {
                value["task_key"] = task["key"];value["task_title"] = task["title"];value["selected_task"] = try selectedTaskProjection(db,task:task)
                if surface == "record" {value=try workspaceRequestDetail(db,value,task:task,caller:c)}
            }
            if type == "task",Self.needSurfaces.contains(surface),let work = try activeWork(db,task:raw) {value["active_work"] = work}
            if type == "review" {
                // A verdict row names its ticket and reviewer; the full review stays in the ticket.
                value = ["id":(try StoredRecord(raw, family: "record").requiredValue("id")),"project_id":(try StoredRecord(raw, family: "record").requiredValue("project_id")),
                    "task_id":raw["task_id"] ?? NSNull(),"gate":raw["gate"] ?? "review","verdict":raw["verdict"] ?? NSNull(),
                         "reviewer":raw["actor_display"] ?? raw["actor"] ?? NSNull(),"created_at":raw["created_at"] ?? NSNull()]
                if let taskID = raw["task_id"] as? String,let task = try? scoped(db,taskID,linkedProject,
                    type:"task") {value["task_key"] = task["key"];value["task_title"] = task["title"]}
            }
            if type == "session",let project=projectIDs.first {value["project_id"]=project;value["project_ids"]=projectIDs}
            if type == "project" {
                value["project_id"]=value["id"]
                value["detail_statuses"]=try records(db,type:"status",project:value["id"] as? String)
                value["detail_tags"]=try records(db,type:"tag",project:value["id"] as? String)
            }
            if type == "group" {
                let pid = (try StoredRecord(raw, family: "record").string("project_id")),gid = (try StoredRecord(raw, family: "record").string("id"))
                value["ticket_count"] = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE type='task' AND project_id=? AND json_extract(data,'$.epic_id')=? COLLATE BINARY AND COALESCE(json_extract(data,'$.trashed'),0)=0",arguments:[pid,gid]) ?? 0
                value["done_count"] = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records t JOIN records s ON s.type='status' AND s.project_id=t.project_id AND s.id=json_extract(t.data,'$.status_id') WHERE t.type='task' AND t.project_id=? AND json_extract(t.data,'$.epic_id')=? COLLATE BINARY AND COALESCE(json_extract(t.data,'$.trashed'),0)=0 AND json_extract(s.data,'$.category')='done'",arguments:[pid,gid]) ?? 0
            }
            rows.append(value)
        }
        // Sidebar metadata spans every owned project even when record rows are
        // scoped to one project. Keep that catalog separate from the SQL row
        // scope above; only the trusted owner may use this command.
        let metadata: JSON
        if let sharedMetadata {metadata = sharedMetadata}
        else {
            let needs = try ownerNeedsYouCounts(db)
            // Native pages need authenticated identity, not the provider/route
            // capability catalogs. Those remain available from service_info.
            let identityKeys: Set<String> = ["session_id","caller","name","version","build_id","build_number","store_incarnation","role","project_ids","read_version"]
            let service = try dispatch(db,method:"service_info",p:[:],c:c).filter {identityKeys.contains($0.key)}
            metadata = ["projects":try projects(db,c),"service":service,"needs_you_count":needs.requests + needs.tasks,
                        "content_cursor":try cursor(db,caller:c,scope:authorizationScope(db,c),sequence:latest)]
        }
        let page: JSON = ["workspace_version":1,"surface":surface,"record_id":recordID,"rows":rows,"total":total,"has_more":fetched.count>limit,
                "next_cursor":fetched.count>limit ? try cursor(db,caller:c,scope:cursorScope,sequence:offset+limit) : NSNull(),
                "previous_cursor":offset>0 ? try cursor(db,caller:c,scope:cursorScope,sequence:max(0,offset-limit)) : NSNull()]
        return page.merging(metadata) {_,shared in shared}
    }

    /// Count cleanup facts once for the selected page, rather than scanning a
    /// project's attachment history separately for every displayed task. These
    /// values live only in this pinned read; no projected result is cached.
    private func workspaceCleanedOriginalCounts(_ db: Database,rows: [Row]) throws -> [WorkspaceTaskIdentity:Int] {
        let tasks = rows.filter {($0["type"] as String) == "task"}
        guard !tasks.isEmpty else {return [:]}
        let projects = tasks.map {$0["project_id"] as String}
        let ids = tasks.map {$0["id"] as String}
        let counts = try Row.fetchAll(db,sql:"SELECT project_id,json_extract(data,'$.task_id') task_id,COUNT(*) clean_count FROM records WHERE type='attachment' AND project_id IN (SELECT value FROM json_each(?)) AND json_extract(data,'$.task_id') IN (SELECT value FROM json_each(?)) AND json_extract(data,'$.availability')='original_cleaned' GROUP BY project_id,json_extract(data,'$.task_id') COLLATE BINARY",arguments:[try jsonString(projects),try jsonString(ids)])
        var result: [WorkspaceTaskIdentity:Int] = [:]
        for row in counts {result[WorkspaceTaskIdentity(project:row["project_id"] as String,task:row["task_id"] as String)] = row["clean_count"] as Int}
        return result
    }
    /// Overview groups by what needs the owner (CL-53). Each is an ordinary paged task surface with an
    /// exact total; together they derive from existing ticket, attempt and session records only.
    static let needSurfaces = ["needs_review","needs_pickup","needs_active","needs_quiet","needs_recovery","needs_done_today"]

    static func needFilter(_ surface: String) -> String {
        // Lookups compare with the columns' own storage collation (exact length-aware bytes), so SQLite uses the
        // primary key and the (project_id,type) index instead of scanning every record per ticket.
        let open = "r.type='task' AND COALESCE(json_extract(r.data,'$.trashed'),0)=0"
        let unarchived = open + " AND COALESCE(json_extract(r.data,'$.archived'),0)=0"
        let category = "(SELECT json_extract(s.data,'$.category') FROM records s WHERE s.id=json_extract(r.data,'$.status_id') AND s.type='status' AND s.project_id=r.project_id)"
        let attempt = "(SELECT a.data FROM records a WHERE a.id=json_extract(r.data,'$.active_attempt_id') AND a.type='attempt' AND a.project_id=r.project_id AND json_extract(a.data,'$.state')='active')"
        let working = "json_extract(r.data,'$.active_attempt_id') IS NOT NULL AND " + attempt + " IS NOT NULL"
        let session = "json_extract(" + attempt + ",'$.session_id')"
        // Ended, revoked or unknown sessions need recovery; the owner's own work has no agent session.
        let lostSession = "(" + session + "<>'human' AND COALESCE((SELECT json_extract(x.data,'$.state') FROM records x WHERE x.id=" + session + " AND x.type='session'),'unknown') IN ('ended','revoked','unknown'))"
        // Quiet: no checkpoint for 30 minutes (ReviewOutcomes.quietCheckpointSeconds); a resource wait is never quiet.
        let quiet = "(COALESCE(json_extract(r.data,'$.work_health.attention'),0)=1 OR (" + session + "<>'human' AND json_extract(" + attempt + ",'$.waiting_for_resource') IS NULL AND checklist_timestamp(COALESCE(json_extract(" + attempt + ",'$.last_checkpoint'),json_extract(" + attempt + ",'$.started_at')))<=:quietBefore))"
        // Unclaimed historical health does not remain actionable after release.
        // A member still handled by an active phase or sibling remains Active attention.
        // Build the scoped member set once. Correlating this lookup per ticket
        // let SQLite scan all project tasks before each group's json_each rows;
        // CROSS JOIN keeps each sibling an exact primary-key lookup instead.
        let unclaimedHealthActive = """
            (\(category)='active' OR (r.project_id,r.id) IN (
              SELECT g.project_id,CASE WHEN m.type='object' THEN json_extract(m.value,'$.task_id') ELSE m.value END
              FROM records g CROSS JOIN json_each(CASE WHEN json_array_length(json_extract(g.data,'$.members'))>0 THEN json_extract(g.data,'$.members') ELSE json_extract(g.data,'$.task_ids') END) m
              WHERE g.type='group' AND g.project_id IN (SELECT value FROM json_each(:projects))
              AND json_extract(g.data,'$.kind')='triage' AND COALESCE(json_extract(g.data,'$.archived'),0)=0
              AND (json_extract(g.data,'$.orchestration.state')='active' OR EXISTS (
                SELECT 1 FROM json_each(CASE WHEN json_array_length(json_extract(g.data,'$.members'))>0 THEN json_extract(g.data,'$.members') ELSE json_extract(g.data,'$.task_ids') END) sibling
                CROSS JOIN records t ON t.id=(CASE WHEN sibling.type='object' THEN json_extract(sibling.value,'$.task_id') ELSE sibling.value END) AND t.type='task' AND t.project_id=g.project_id
                LEFT JOIN records s ON s.id=json_extract(t.data,'$.status_id') AND s.type='status' AND s.project_id=t.project_id
                WHERE json_extract(t.data,'$.active_attempt_id') IS NOT NULL OR json_extract(s.data,'$.category')='active'))))
            """
        let ownerAssigned = "(COALESCE(json_extract(r.data,'$.planned_assignee'),'')='human' OR COALESCE(json_extract(r.data,'$.planned_assignee.kind'),'')='human' OR COALESCE(json_extract(r.data,'$.assignee'),'')='human')"
        let openPrerequisite = "EXISTS (SELECT 1 FROM records e WHERE e.project_id=r.project_id AND e.type='relation' AND json_extract(e.data,'$.source_task_id')=r.id AND json_extract(e.data,'$.relation')='depends_on' AND COALESCE(json_extract(e.data,'$.required'),1)=1 AND (COALESCE(json_extract(e.data,'$.state'),'active')='unresolved' OR NOT EXISTS (SELECT 1 FROM records pt JOIN records ps ON ps.id=json_extract(pt.data,'$.status_id') AND ps.type='status' AND ps.project_id=pt.project_id WHERE pt.id=json_extract(e.data,'$.target_task_id') AND pt.type='task' AND pt.project_id=r.project_id AND json_extract(ps.data,'$.category')='done' AND COALESCE(json_extract(pt.data,'$.trashed'),0)=0 AND COALESCE(json_extract(pt.data,'$.disposition'),'')<>'superseded')))"
        // A pending blocking owner request stops pickup, review and completion (Work.swift); such a ticket waits in Owner requests.
        let blockingRequest = "EXISTS (SELECT 1 FROM records q WHERE q.project_id=r.project_id AND q.type='request' AND json_extract(q.data,'$.task_id')=r.id AND COALESCE(json_extract(q.data,'$.state'),'pending')='pending' AND COALESCE(json_extract(q.data,'$.blocking'),0)=1)"
        let free = "json_extract(r.data,'$.active_attempt_id') IS NULL AND json_extract(r.data,'$.active_verification_request_id') IS NULL AND COALESCE(json_extract(r.data,'$.disposition'),'')<>'superseded' AND NOT " + blockingRequest + " AND NOT " + openPrerequisite
        // Ready for review: the same conditions as the app's eligible review request (ReviewProjection.eligibleReviewRequest).
        let queuedReview = "EXISTS (SELECT 1 FROM records rr WHERE rr.project_id=r.project_id AND rr.type='review_request' AND json_extract(rr.data,'$.task_id')=r.id AND json_extract(rr.data,'$.manifest_id')=json_extract(r.data,'$.current_manifest_id') AND json_extract(rr.data,'$.state')='queued' AND COALESCE(json_extract(rr.data,'$.gate'),'')<>'human_approval')"
        switch surface {
        case "needs_review": return unarchived + " AND " + category + "='review' AND COALESCE(json_extract(r.data,'$.pending_policy_revision'),0)=0 AND " + free + " AND " + queuedReview
        case "needs_pickup": return unarchived + " AND json_extract(r.data,'$.readiness')='ready' AND " + category + "='queued' AND NOT " + ownerAssigned + " AND " + free
        case "needs_active": return unarchived + " AND " + category + "='active' AND " + working + " AND NOT " + lostSession + " AND NOT " + quiet
        case "needs_quiet": return unarchived + " AND ((COALESCE(json_extract(r.data,'$.work_health.attention'),0)=1 AND NOT (" + working + ") AND " + unclaimedHealthActive + ") OR (" + working + " AND COALESCE(" + category + ",'')<>'blocked' AND NOT " + lostSession + " AND " + quiet + "))"
        case "needs_recovery": return unarchived + " AND (" + category + "='blocked' OR (" + working + " AND " + lostSession + "))"
        default: return open + " AND " + category + " IN ('done','completed') AND checklist_timestamp(json_extract(r.data,'$.completed_at'))>=:todayStart"
        }
    }

    /// Every Overview group's first page in one command. Rows, totals and page
    /// cursors match singles; shared catalogs/identity/coverage occur once.
    static let overviewGroupLimits: [(surface: String, limit: Int)] = [("requests",5),("human_tasks",1),("needs_review",5),("needs_pickup",5),
        ("needs_active",5),("needs_quiet",5),("needs_recovery",5),("needs_done_today",5),("recent_reviews",60),("completed_since",20)]
    private func overviewGroupsPage(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        var groups: JSON = [:]
        var metadata: JSON?
        for (surface,limit) in Self.overviewGroupLimits {
            var sub: JSON = ["surface":surface,"limit":limit]
            if let project = p["project_id"] { sub["project_id"] = project }
            if surface == "completed_since" { sub["since"] = p["since"] ?? NSNull() }
            if surface == "completed_since" && (p["since"] as? String ?? "").isEmpty { continue }
            var page = try workspacePage(db,sub,c,sharedMetadata:metadata)
            if metadata == nil {metadata = page.filter {Self.overviewSharedFields.contains($0.key)}}
            for key in Self.overviewSharedFields {page.removeValue(forKey:key)}
            groups[surface] = page
        }
        let page: JSON = ["workspace_version":1,"surface":"overview","record_id":"","groups":groups,"rows":[JSON](),"total":0,"has_more":false,
                          "next_cursor":NSNull(),"previous_cursor":NSNull()]
        return page.merging(metadata ?? [:]) {_,shared in shared}
    }
    private static let overviewSharedFields: Set<String> = ["projects","service","content_cursor","needs_you_count"]

    /// The active attempt of a listed ticket: who works, in which phase, and how recent its checkpoint is.
    private func activeWork(_ db: Database, task: JSON) throws -> JSON? {
        guard let attemptID = task["active_attempt_id"] as? String, let pid = task["project_id"] as? String,
              let attempt = try? scoped(db,attemptID,pid,type:"attempt"), attempt["state"] as? String == "active" else { return nil }
        let sessionID = attempt["session_id"] as? String ?? ""
        let session = sessionID == "human" ? nil : try? record(db,sessionID,type:"session")
        var work: JSON = ["attempt_id":attemptID,"phase":attempt["phase"] ?? "implementation","session_id":sessionID,
                          "last_checkpoint":attempt["last_checkpoint"] ?? attempt["started_at"] ?? NSNull(),
                          "session_state":sessionID == "human" ? "owner" : session?["state"] ?? "unknown"]
        if let session { work["session_label"] = session["native_conversation_title"] ?? session["label"] ?? NSNull(); work["provider"] = session["provider"] ?? NSNull() }
        if let resource = attempt["waiting_for_resource"] { work["waiting_for_resource"] = resource }
        return work
    }

    private func workspaceRequestDetail(_ db:Database,_ source:JSON,task:JSON,caller:Caller)throws->JSON {
        var result=source
        let pid=(try StoredRecord(task, family: "task").string("project_id")),rid=(try StoredRecord(source, family: "record").string("id"))
        let messages=try scopedTaskRows(db,type:"message",task:task,predicate:"json_extract(data,'$.human_request_id')=CAST(? AS TEXT) COLLATE BINARY",arguments:[Data(rid.utf8)],limit:25,descending:true)
        let ids=try jsonString(messages.compactMap{$0["id"] as? String})
        let deliveries=try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='delivery' AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.message_id') IN (SELECT value FROM json_each(?)) ORDER BY rowid DESC LIMIT 201",arguments:[Data(pid.utf8),ids]).map {try deliveryReceiptProjection(db,GRDBRecordEnvelopeAdapter.decode($0,expectedType:"delivery").object)}
        result["detail_messages"]=messages.map {message in
            var value=contextRecord(message,type:"message",caller:caller)
            value["deliveries"]=deliveries.prefix(200).filter {SnapshotRecordIdentity($0["message_id"] as? String ?? "")==SnapshotRecordIdentity(message["id"] as? String ?? "")}
            return value
        }
        var sessionIDs=deliveries.prefix(200).compactMap{$0["recipient_session_id"] as? String}
        if let requester=source["requester_session_id"] as? String {sessionIDs.append(requester)}
        let sessionJSON=try jsonString(sessionIDs)
        result["detail_sessions"]=try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='session' AND id IN (SELECT value FROM json_each(?)) AND (project_id=CAST(? AS TEXT) OR EXISTS (SELECT 1 FROM json_each(json_extract(data,'$.project_ids')) WHERE value=CAST(? AS TEXT) COLLATE BINARY)) LIMIT 201",arguments:[sessionJSON,Data(pid.utf8),Data(pid.utf8)]).map {contextRecord(try GRDBRecordEnvelopeAdapter.decode($0,expectedType:"session").object,type:"session",caller:caller)}
        if let attachmentID=source["target_attachment_id"] as? String,let attachment=try? scoped(db,attachmentID,pid,type:"attachment") {result["detail_attachments"]=[contextRecord(attachment,type:"attachment",caller:caller)]}
        else {result["detail_attachments"]=[] as [JSON]}
        do { result["image_review"] = try requestImageReviewContext(db,request:source,task:task,caller:caller) }
        catch { result["image_review"] = ["problem":"The exact image set is unavailable. Refresh this request before approving."] }
        result["detail_receipts_complete"]=deliveries.count<=200 && messages.count<25
        return result
    }

}
