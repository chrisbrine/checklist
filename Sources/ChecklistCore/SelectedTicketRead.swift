import Foundation
import GRDB

extension CommandRouter {
    private func selectedContextScope(_ db: Database, project: String, task: String, caller: Caller) throws -> String {
        let latest = try Int.fetchOne(db,sql:"SELECT COALESCE(MAX(seq),0) FROM events WHERE project_id=CAST(? AS TEXT) OR project_id IS NULL",arguments:[Data(project.utf8)]) ?? 0
        let identity: JSON = ["project":project,"task":task,"authorization":try authorizationScope(db,caller),"generation":try callerSessionGeneration(db,caller,project:project),"coverage":latest]
        return "selected-ticket-context-v1:" + hash(Data(try jsonString(identity).utf8))
    }
    private func selectedMemberIDs(_ group: JSON) -> [String] {
        let explicit = (group["members"] as? [JSON] ?? []).compactMap {$0["task_id"] as? String}
        var seen = Set<SnapshotRecordIdentity>()
        return (explicit.isEmpty ? strings(group,"task_ids") : explicit).filter {seen.insert(SnapshotRecordIdentity($0)).inserted}
    }
    /// Reuse projection semantics while decoding only this task's dependency
    /// sources/tags and the actual triages containing it, not project corpora.
    func selectedTaskProjection(_ db: Database, task: JSON) throws -> JSON {
        let pid = task["project_id"] as! String,tid = task["id"] as! String
        let status = try? scoped(db,task["status_id"] as? String ?? "",pid,type:"status")
        let edges = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='relation' AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.source_task_id')=CAST(? AS TEXT) COLLATE BINARY AND COALESCE(json_extract(data,'$.state'),'')<>'removed' ORDER BY rowid",arguments:[Data(pid.utf8),Data(tid.utf8)]).map {try GRDBRecordEnvelopeAdapter.decode($0).object}
        let prerequisites = projectedPrerequisites(task:task,relations:edges,taskLookup:{try self.scoped(db,$0,pid,type:"task")},statusLookup:{try self.scoped(db,$0,pid,type:"status")})
        let relation = projectedRelationTask(task:task,prerequisites:prerequisites,category:status?["category"] as? String ?? "unknown",canonicalID:try canonicalTaskID(db,task:task))
        let tags = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='tag' AND project_id=CAST(? AS TEXT) AND id IN (SELECT value FROM json_each(?)) ORDER BY rowid",arguments:[Data(pid.utf8),try jsonString(strings(task,"tag_ids"))]).map {try GRDBRecordEnvelopeAdapter.decode($0).object}
        let attention = try projectedTaskAttention(task,statusLookup:{try self.scoped(db,$0,pid,type:"status")}) {
            let triages = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records g WHERE type='group' AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.kind')='triage' AND COALESCE(json_extract(data,'$.archived'),0)=0 AND EXISTS (SELECT 1 FROM json_each(CASE WHEN json_array_length(json_extract(g.data,'$.members'))>0 THEN json_extract(g.data,'$.members') ELSE json_extract(g.data,'$.task_ids') END) member WHERE (CASE WHEN member.type='object' THEN json_extract(member.value,'$.task_id') ELSE member.value END)=CAST(? AS TEXT) COLLATE BINARY) ORDER BY rowid",arguments:[Data(pid.utf8),Data(tid.utf8)])
            for row in triages {
                let group = try GRDBRecordEnvelopeAdapter.decode(row).object
                if try self.projectedTriageAttention(group,memberIDs:selectedMemberIDs(group),taskLookup:{try self.scoped(db,$0,pid,type:"task")},statusLookup:{try self.scoped(db,$0,pid,type:"status")}) {return true}
            }
            return false
        }
        var result = assembledTaskProjection(task,status:status,activeAttention:attention,tags:tags,relation:relation)
        result["cleaned_original_count"] = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE type='attachment' AND project_id=? AND json_extract(data,'$.task_id')=? AND json_extract(data,'$.availability')='original_cleaned'",arguments:[pid,tid]) ?? 0
        return result
    }
    /// Authoritative selected-ticket display data, separate from global snapshot
    /// and complete review authority. Only bounded selected rows are decoded.
    func selectedTicketRead(_ db: Database, _ p: JSON, _ c: Caller) throws -> JSON {
        try owner(c)
        var scopedInput = p
        if scopedInput["project_id"] == nil {
            let selected = try record(db,try text(p,"task_id"),type:"task")
            scopedInput["project_id"] = selected["project_id"]
        }
        let pid = try scope(db,scopedInput,c), task = try self.task(db,scopedInput,pid), tid = task["id"] as! String
        // Offset history depends on this conversation's membership, not unrelated
        // project events. Current work/review authority keeps its separate scope.
        let history = try Row.fetchOne(db,sql:"SELECT COUNT(*) AS total,COALESCE(MAX(rowid),0) AS frontier FROM records WHERE type='message' AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY",arguments:[Data(pid.utf8),Data(tid.utf8)])!
        let messageCount: Int = history["total"], messageFrontier: Int = history["frontier"]
        let readScope = "selected-ticket-ui-v2:" + hash(Data(try jsonString(["project":pid,"task":tid,"locale":Locale.current.identifier,"authorization":authorizationScope(db,c),"generation":callerSessionGeneration(db,c,project:pid),"message_count":messageCount,"message_frontier":messageFrontier]).utf8))
        var input: JSON = [:]; if let cursor = p["history_cursor"] {input["cursor"] = cursor}
        let offset = try cursorSequence(db,input,caller:c,scope:readScope)
        let notes = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='message' AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY ORDER BY checklist_timestamp(json_extract(data,'$.created_at')) DESC,rowid DESC LIMIT 51 OFFSET ?",arguments:[Data(pid.utf8),Data(tid.utf8),offset])
        let messages = chronologicalMessages(try Array(notes.prefix(50)).map {try GRDBRecordEnvelopeAdapter.decode($0).object})
        let messageIDs = try jsonString(messages.compactMap {$0["id"] as? String})
        let deliveries = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='delivery' AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.message_id') IN (SELECT value FROM json_each(?)) ORDER BY rowid",arguments:[Data(pid.utf8),messageIDs]).map {try GRDBRecordEnvelopeAdapter.decode($0).object}
        var collections: JSON = ["messages":try noteRevisionProjection(db,messages:SnapshotMessageProjection.hydrate(messages,loadDeliveries:{deliveries}),project:pid)]
        var counts: JSON = [:]
        for (name,type,limit) in [("attachments","attachment",50),("attempts","attempt",25),("requests","request",25)] {
            collections[name] = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type=? AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY ORDER BY rowid DESC LIMIT ?",arguments:[type,Data(pid.utf8),Data(tid.utf8),limit]).reversed().map {contextRecord(try GRDBRecordEnvelopeAdapter.decode($0).object,type:type,caller:c)}
            counts[name] = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE type=? AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY",arguments:[type,Data(pid.utf8),Data(tid.utf8)]) ?? 0
        }
        counts["messages"] = messageCount
        // The active attempt must be present even after a long prior history.
        if let activeID = task["active_attempt_id"] as? String {
            let active = try scoped(db,activeID,pid,type:"attempt")
            var attempts = collections["attempts"] as? [JSON] ?? []
            if !attempts.contains(where:{SnapshotRecordIdentity($0["id"] as? String ?? "")==SnapshotRecordIdentity(activeID)}) {attempts.append(contextRecord(active,type:"attempt",caller:c))}
            collections["attempts"] = attempts
        }
        collections["events"] = try Row.fetchAll(db,sql:"SELECT id,project_id,entity_id,actor,kind,occurred_at,data FROM events WHERE project_id=CAST(? AS TEXT) AND entity_id=CAST(? AS TEXT) COLLATE BINARY ORDER BY seq DESC LIMIT 50",arguments:[Data(pid.utf8),Data(tid.utf8)]).map {row -> JSON in ["id":row["id"] as String,"project_id":pid,"entity_id":tid,"actor":row["actor"] as String,"kind":row["kind"] as String,"occurred_at":row["occurred_at"] as String,"data":jsonObject(row["data"])]}
        let sessionIDs = try jsonString((collections["attempts"] as? [JSON] ?? []).compactMap {$0["session_id"] as? String})
        collections["sessions"] = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='session' AND id IN (SELECT value FROM json_each(?)) ORDER BY rowid",arguments:[sessionIDs]).map { row -> JSON in
            let source = try GRDBRecordEnvelopeAdapter.decode(row).object;var value: JSON = [:]
            for key in ["id","label","provider","state","role","updated_at"] {value[key]=source[key] ?? ""}
            return value
        }
        // Explicit references, not pretend complete membership lists.
        collections["groups"] = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records g WHERE type='group' AND project_id=CAST(? AS TEXT) AND (id=CAST(? AS TEXT) OR (json_extract(data,'$.kind')='triage' AND EXISTS (SELECT 1 FROM json_each(CASE WHEN json_array_length(json_extract(g.data,'$.members'))>0 THEN json_extract(g.data,'$.members') ELSE json_extract(g.data,'$.task_ids') END) member WHERE (CASE WHEN member.type='object' THEN json_extract(member.value,'$.task_id') ELSE member.value END)=CAST(? AS TEXT) COLLATE BINARY))) ORDER BY rowid",arguments:[Data(pid.utf8),Data((task["epic_id"] as? String ?? "").utf8),Data(tid.utf8)]).map {row -> JSON in
            let source = try GRDBRecordEnvelopeAdapter.decode(row).object;var value: JSON = ["id":row["id"] as String,"project_id":pid,"selected_task_member":true,"members_complete":false]
            for key in ["key","name","kind","phase","purpose","revision"] {value[key]=source[key] ?? ""}
            return value
        }
        for (name,type) in [("statuses","status"),("tags","tag")] {collections[name] = try records(db,type:type,project:pid)}
        let project = try record(db,pid,type:"project")
        let more = notes.count > 50
        return ["ui_version":1,"task":try selectedTaskProjection(db,task:task),"project":projectProjection(project,caller:c),
            "collections":collections,"counts":counts,"full_record_loaded":false,"has_more_messages":more,
            "context_cursor":try cursor(db,caller:c,scope:selectedContextScope(db,project:pid,task:tid,caller:c),sequence:0),
            "next_history_cursor":more ? try cursor(db,caller:c,scope:readScope,sequence:offset+50) : NSNull(),
            "previous_history_cursor":offset>0 ? try cursor(db,caller:c,scope:readScope,sequence:max(0,offset-50)) : NSNull(),
            "service":try dispatch(db,method:"service_info",p:[:],c:c)]
    }
}

extension CommandRouter {
    /// Explicit work/review expansion. This is a bounded selected-task read, not
    /// the owner corpus. Any omitted record keeps the review consumer fail closed.
    func selectedTicketRecords(_ db: Database, _ p: JSON, _ c: Caller) throws -> JSON {
        try owner(c)
        var input = p
        if input["project_id"] == nil {input["project_id"] = try record(db,try text(p,"task_id"),type:"task")["project_id"]}
        let pid = try scope(db,input,c), task = try self.task(db,input,pid), tid = task["id"] as! String
        guard let observed = p["selected_context_cursor"] as? String else {throw CoreError("CONTEXT_CURSOR_REQUIRED","Read the selected ticket before expanding its work/review records.")}
        _ = try cursorSequence(db,["cursor":observed],caller:c,scope:selectedContextScope(db,project:pid,task:tid,caller:c))
        var collections: JSON = [:], counts: JSON = [:], historyCounts: JSON = [:]
        var complete = true
        let current = task["current_manifest_id"] as? String ?? ""
        let manifest = current.isEmpty ? nil : try scoped(db,current,pid,type:"manifest")
        let currentAttempt = manifest?["attempt_id"] as? String ?? ""
        let artifactIDs = ((manifest?["evidence"] as? JSON)?["artifact_refs"] as? [JSON] ?? []).compactMap {$0["artifact_id"] as? String}
        let families = [("manifests","manifest"),("review_requests","review_request"),("reviews","review"),("findings","finding"),("finding_resolutions","finding_resolution"),("attempts","attempt"),("attachments","attachment"),("requests","request"),("source_executions","source_execution"),("task_aliases","task_alias"),("task_sessions","task_session")]
        for (name,type) in families {
            // Current authority is independent of the size of historical work.
            // History has its own replaceable cursor page below, never an
            // ever-growing array or a false claim that older rows disappeared.
            let predicate: String
            var args: [DatabaseValueConvertible] = [type,Data(pid.utf8),Data(tid.utf8)]
            switch type {
            case "manifest":predicate="id=CAST(? AS TEXT)";args.append(Data(current.utf8))
            case "review_request","review":predicate="json_extract(data,'$.manifest_id')=CAST(? AS TEXT) COLLATE BINARY";args.append(Data(current.utf8))
            case "finding":predicate="json_extract(data,'$.state')='open'"
            case "finding_resolution":predicate="json_extract(data,'$.finding_id') IN (SELECT id FROM records WHERE type='finding' AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY AND json_extract(data,'$.state')='open')";args += [Data(pid.utf8),Data(tid.utf8)]
            case "attempt":predicate="json_extract(data,'$.state')='active' OR id=CAST(? AS TEXT)";args.append(Data(currentAttempt.utf8))
            case "attachment":predicate="id IN (SELECT value FROM json_each(?))";args.append(try jsonString(artifactIDs))
            case "request":predicate="COALESCE(json_extract(data,'$.state'),'pending') NOT IN ('answered','canceled','\(LegacyStoredValue.canceled)','superseded','resolved')"
            case "source_execution":predicate="json_extract(data,'$.state') IN ('queued','running','interrupted') OR json_extract(data,'$.process_stop_unverified')=1"
            case "task_alias":predicate="COALESCE(json_extract(data,'$.state'),'active')='active'"
            case "task_session":
                predicate="EXISTS (SELECT 1 FROM records s WHERE s.type='session' AND s.id=json_extract(records.data,'$.session_id') AND json_extract(s.data,'$.role')='worker' AND COALESCE(json_extract(s.data,'$.state'),'') NOT IN ('ended','revoked') AND COALESCE(json_extract(s.data,'$.authorization_generation'),'unqualified-legacy')=json_extract(records.data,'$.session_authorization_generation') COLLATE BINARY AND json_extract(s.data,'$.execution_domain') IS json_extract(records.data,'$.execution_domain') AND (s.project_id=records.project_id OR EXISTS (SELECT 1 FROM json_each(json_extract(s.data,'$.project_ids')) WHERE value=records.project_id)))"
            default:predicate="1"
            }
            let base=" FROM records WHERE type=? AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY AND ("+predicate+")"
            let rows = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+base+" ORDER BY rowid DESC LIMIT 201",arguments:StatementArguments(args))
            collections[name] = try Array(rows.prefix(200)).reversed().map {row -> JSON in
                let value = try GRDBRecordEnvelopeAdapter.decode(row).object
                return type == "task_session" ? try taskSessionProjection(db,value) : contextRecord(value,type:type,caller:c)
            }
            counts[name] = try Int.fetchOne(db,sql:"SELECT COUNT(*)"+base,arguments:StatementArguments(args)) ?? 0
            historyCounts[name] = try scopedTaskCount(db,type:type,task:task)
            if rows.count > 200 {complete = false}
        }
        let directions = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='message' AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY AND json_extract(data,'$.origin')='human_ui' AND json_extract(data,'$.requires_action')=1 AND COALESCE(json_extract(data,'$.addressed'),0)=0 AND \(Self.unretractedDirectionSQL()) ORDER BY rowid LIMIT 201",arguments:[Data(pid.utf8),Data(tid.utf8)])
        collections["messages"] = try Array(directions.prefix(200)).map {contextRecord(try GRDBRecordEnvelopeAdapter.decode($0).object,type:"message",caller:c)}
        if directions.count > 200 {complete = false}
        let relations = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='relation' AND project_id=CAST(? AS TEXT) AND (json_extract(data,'$.source_task_id')=CAST(? AS TEXT) COLLATE BINARY OR json_extract(data,'$.target_task_id')=CAST(? AS TEXT) COLLATE BINARY) AND COALESCE(json_extract(data,'$.state'),'')<>'removed' ORDER BY rowid LIMIT 201",arguments:[Data(pid.utf8),Data(tid.utf8),Data(tid.utf8)])
        collections["relations"] = try Array(relations.prefix(200)).map {try GRDBRecordEnvelopeAdapter.decode($0).object}
        if relations.count > 200 {complete = false}
        // Point-load only linked task labels/revisions. Picking another task uses
        // task_list explicitly; no all-project candidate corpus is implicit here.
        var relatedIDs = (collections["relations"] as? [JSON] ?? []).flatMap {[$0["source_task_id"] as? String,$0["target_task_id"] as? String].compactMap {$0}}
        relatedIDs.append(tid)
        if let canonical = task["duplicate_of_task_id"] as? String {relatedIDs.append(canonical)}
        var related: [JSON] = [], seen = Set<SnapshotRecordIdentity>()
        for id in relatedIDs where seen.insert(SnapshotRecordIdentity(id)).inserted {
            if let linked = try? scoped(db,id,pid,type:"task") {related.append(try selectedTaskProjection(db,task:linked))}
        }
        collections["tasks"] = related
        var sessionIDs:[String]=[]
        for family in ["attempts","task_sessions","requests","reviews"] {
            for value in collections[family] as? [JSON] ?? [] {
                for key in ["session_id","reviewer_session_id","requester_session_id"] {if let id=value[key] as? String {sessionIDs.append(id)}}
            }
        }
        if let assignee=(task["planned_assignee"] as? JSON)?["session_id"] as? String {sessionIDs.append(assignee)}
        let sessionJSON=try jsonString(sessionIDs)
        let sessionScope=" FROM records WHERE type='session' AND id IN (SELECT value FROM json_each(?)) AND (project_id=CAST(? AS TEXT) OR EXISTS (SELECT 1 FROM json_each(json_extract(data,'$.project_ids')) WHERE value=CAST(? AS TEXT) COLLATE BINARY))"
        let sessions = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+sessionScope+" ORDER BY rowid DESC LIMIT 201",arguments:[sessionJSON,Data(pid.utf8),Data(pid.utf8)])
        collections["sessions"] = try Array(sessions.prefix(200)).map {row -> JSON in
            let source = try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"session").object
            var result:JSON=["project_id":pid,"project_ids":[pid]]
            for key in ["id","label","provider","role","state","native_conversation_title","updated_at","authorization_generation"] {result[key]=source[key] ?? ""}
            return result
        }
        if sessions.count > 200 {complete = false}
        counts["sessions"] = try Int.fetchOne(db,sql:"SELECT COUNT(*)"+sessionScope,arguments:[sessionJSON,Data(pid.utf8),Data(pid.utf8)]) ?? 0
        let rosterRef:JSON=["method":"workspace_page","surface":"worker_sessions","project_id":pid]
        collections["evidence_measure_history"] = try evidenceMeasureHistory(db,task:task,caller:c)
        collections["review_target_history"] = try reviewTargetHistory(db,task:task,caller:c)
        return ["ui_records_version":1,"task_id":tid,"project_id":pid,"task_revision":task["revision"] ?? 1,
            "collections":collections,"counts":counts,"history_counts":historyCounts,"current_scope_only":true,"worker_roster_ref":rosterRef,"complete":complete,"service":try dispatch(db,method:"service_info",p:[:],c:c)]
    }

    func selectedTicketHistory(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try owner(c)
        var input=p
        if input["project_id"] == nil {input["project_id"]=try record(db,try text(p,"task_id"),type:"task")["project_id"]}
        let pid=try scope(db,input,c),task=try self.task(db,input,pid),tid=task["id"] as! String
        guard let observed=p["selected_context_cursor"] as? String else {throw CoreError("CONTEXT_CURSOR_REQUIRED","Read this selected ticket before its history.")}
        _=try cursorSequence(db,["cursor":observed],caller:c,scope:selectedContextScope(db,project:pid,task:tid,caller:c))
        let family=try text(p,"records_family",max:40)
        guard ["attachment","attempt","manifest","review_request","review","finding","finding_resolution","request","source_execution","task_session","task_alias"].contains(family) else {throw CoreError("INVALID_INPUT","Choose a supported ticket history family.")}
        let historyScope="selected-record-history-v1:"+family+":"+(try selectedContextScope(db,project:pid,task:tid,caller:c))
        let offset=try cursorSequence(db,p,caller:c,scope:historyScope)
        let rows=try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type=? AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY ORDER BY rowid DESC LIMIT 51 OFFSET ?",arguments:[family,Data(pid.utf8),Data(tid.utf8),offset])
        return ["workspace_version":1,"surface":"record_history","record_id":tid,"rows":try rows.prefix(50).map {contextRecord(try GRDBRecordEnvelopeAdapter.decode($0,expectedType:family).object,type:family,caller:c)},
                "total":try scopedTaskCount(db,type:family,task:task),"has_more":rows.count>50,
                "next_cursor":rows.count>50 ? try cursor(db,caller:c,scope:historyScope,sequence:offset+50) : NSNull(),
                "previous_cursor":offset>0 ? try cursor(db,caller:c,scope:historyScope,sequence:max(0,offset-50)) : NSNull(),
                "projects":[projectProjection(try record(db,pid,type:"project"),caller:c)],"service":try dispatch(db,method:"service_info",p:[:],c:c),
                "content_cursor":try cursor(db,caller:c,scope:authorizationScope(db,c))]
    }
}
