import Foundation
import GRDB

/// Request-local SQL selection. Only LIMITed canonical task rows cross the JSON
/// decoding boundary; count/search predicates stay inside the authorized query.
extension CommandRouter {
    func ownerNeedsYouCounts(_ db: Database) throws -> (requests: Int, tasks: Int) {
        // Global owner counts need only these two small record families. A
        // covering-index rowid pass avoids loading unrelated retained payloads.
        let requests = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE rowid IN (SELECT rowid FROM records INDEXED BY records_scope WHERE type='request') AND COALESCE(json_extract(data,'$.state'),'') NOT IN ('answered','canceled','\(LegacyStoredValue.canceled)','superseded','resolved')") ?? 0
        let tasks = try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records t LEFT JOIN records s ON s.id=json_extract(t.data,'$.status_id') AND s.project_id=t.project_id AND s.type='status' WHERE t.rowid IN (SELECT rowid FROM records INDEXED BY records_scope WHERE type='task') AND COALESCE(json_extract(t.data,'$.archived'),0)=0 AND COALESCE(json_extract(t.data,'$.trashed'),0)=0 AND COALESCE(json_extract(s.data,'$.category'),'') NOT IN ('done','completed','canceled','\(LegacyStoredValue.canceled)') AND (json_extract(t.data,'$.planned_assignee')='human' OR json_extract(t.data,'$.planned_assignee.kind')='human' OR json_extract(t.data,'$.assignee')='human')") ?? 0
        return (requests,tasks)
    }

    static func installTicketSearchFunctions(_ db: Database) {
        // Registered by prepareDatabase on every connection, never persisted DDL.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        // SQLite serializes each connection. Repeated date strings across the
        // Overview's count/order queries need one parse, with a bounded cache.
        var timestamps: [String:Double] = [:]
        db.add(function: DatabaseFunction("checklist_timestamp", argumentCount: 1) { values in
            let value = String.fromDatabaseValue(values[0]) ?? ""
            if let cached = timestamps[value] {return cached}
            let result = (fractional.date(from:value) ?? standard.date(from:value) ?? .distantPast).timeIntervalSince1970
            if value.utf8.count <= 64 {
                if timestamps.count >= 1024 {timestamps.removeAll(keepingCapacity:true)}
                timestamps[value] = result
            }
            return result
        })
        // Locale is intentionally not marked deterministic and is cursor-bound.
        db.add(collation: DatabaseCollation("checklist_display_label") { left, right in
            left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        })
        db.add(collation: DatabaseCollation("checklist_human_order") { left, right in left.localizedStandardCompare(right) })
        db.add(function: DatabaseFunction("checklist_key_fold", argumentCount: 1) { values in
            (String.fromDatabaseValue(values[0]) ?? "").folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX"))
        })
        db.add(function: DatabaseFunction("checklist_contains", argumentCount: 2) { values in
            guard let haystack = String.fromDatabaseValue(values[0]), let needle = String.fromDatabaseValue(values[1]) else { return false }
            return haystack.localizedCaseInsensitiveContains(needle)
        })
    }

    func ticketView(_ p: JSON, _ c: Caller) throws -> JSON? {
        guard let value = p["view"] else { return nil }
        try owner(c)
        guard let view = value as? JSON,
              Set(["surface", "status_filter", "tag_filter", "group_by", "order_by"]).isSubset(of: Set(view.keys)),
              Set(view.keys).isSubset(of: Set(["surface", "status_filter", "tag_filter", "group_by", "order_by", "tag_ids", "tag_mode", "planned_assignee", "actual_assignee", "epic_id", "triage_id"])),
              ["tickets", "overview", "archived", "trash"].contains(view["surface"] as? String ?? ""),
              ["status", "epic", "none"].contains(view["group_by"] as? String ?? ""),
              ["manual", "priority", "updated_desc"].contains(view["order_by"] as? String ?? ""),
              let status = view["status_filter"] as? String, let tag = view["tag_filter"] as? String,
              status.utf8.count <= 4000, tag.utf8.count <= 4000 else {
            throw CoreError("INVALID_INPUT", "Use a complete supported Tickets view.")
        }
        try validateTicketFacets(view)
        return view
    }

    func taskPage(_ db: Database, _ p: JSON, _ c: Caller) throws -> JSON {
        let view = try ticketView(p, c)
        let allProjects = view != nil && p["project_id"] == nil
        let projectIDs: [String]
        if allProjects { try owner(c); projectIDs = try projects(db,c).filter { !bool($0,"archived") }.compactMap { $0["id"] as? String } }
        else {
            if !c.isOwner, let requested = p["project_id"] as? String,
               !c.projectIDs.contains(where: { SnapshotRecordIdentity($0) == SnapshotRecordIdentity(requested) }) {
                throw CoreError("FORBIDDEN", "This project is outside the exact connection grant.")
            }
            projectIDs = [try scope(db,p,c)]
        }
        let projectJSON = try jsonStringArray(projectIDs)
        let triage = try listGroup(db,p,key:"triage_id",projects:projectIDs,kind:"triage")
        let epic = try listGroup(db,p,key:"epic_id",projects:projectIDs,kind:"epic")
        var keys: [String] = []
        if let raw = p["keys"] {
            guard let values = raw as? [String],values.count <= 200,values.allSatisfy({!$0.isEmpty && $0.utf8.count <= 4000}) else { throw CoreError("INVALID_INPUT","keys must be an array of at most 200 non-empty ticket keys.") }
            keys = Array(Set(values.map {$0.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX"))})).sorted()
        }
        let fields = try listFields(db,p,projects:projectIDs,type:"task",known:Self.taskListFields)
        let query = view == nil ? p["text"] as? String ?? "" : (p["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.utf8.count <= 4000 else { throw CoreError("INVALID_INPUT", "Search text is too long.") }
        let limit = min(max(int(p,"limit",default:200),1),200)
        // Separate project-prefix ranges allow the existing covering events_scope
        // index to serve this private cursor generation; no new persisted index.
        let latest = try Int.fetchOne(db,sql:"""
        SELECT COALESCE(MAX(latest),0) FROM (
          SELECT MAX(seq) latest FROM events WHERE project_id IS NULL
          UNION ALL
          SELECT MAX(seq) latest FROM events WHERE project_id IN (SELECT value FROM json_each(?))
        )
        """,arguments:[projectJSON]) ?? 0
        let generations = try projectIDs.map { try callerSessionGeneration(db,c,project:$0) }
        let identity: JSON = ["projects":projectIDs,"view":view ?? NSNull(),"text":query,
            "archived":bool(p,"archived"),"status_ids":strings(p,"status_ids"),"limit":limit,
            "triage_id":triage?["id"] ?? NSNull(),"epic_id":epic?["id"] ?? NSNull(),"keys":p["keys"] == nil ? NSNull() : keys,"fields":fields.sorted(),
            "locale":Locale.current.identifier,"authorization":try authorizationScope(db,c),"generations":generations]
        let queryKey = hash(Data(try jsonString(identity).utf8))
        // Sequence stores the private offset, never a public event sequence.
        let cursorScope = "task-page-v1:" + queryKey + ":" + String(latest)
        let offset = try cursorSequence(db,p,caller:c,scope:cursorScope)
        guard offset >= 0 else { throw CoreError("CURSOR_RESET", "Refresh this Tickets view.") }
        var arguments: StatementArguments = ["projects":projectJSON,"query":query,
            "closed":view?["surface"] as? String == "archived" ? 1 : 0,
            "trashed":view?["surface"] as? String == "trash" ? 1 : 0,
            "archived":bool(p,"archived") ? 1 : 0,"statuses":try jsonStringArray(strings(p,"status_ids")),
            "status":view?["status_filter"] as? String ?? "all","tag":view?["tag_filter"] as? String ?? "all"]
        arguments += try ticketFacetArguments(view)
        arguments += ["listTriage":triage == nil ? 0 : 1,"listMembers":try jsonStringArray(triage.map {triageMemberIDs($0)} ?? []),"listEpic":epic?["id"] as? String ?? "","listHasKeys":p["keys"] == nil ? 0 : 1,"listKeys":try jsonStringArray(keys)]
        let ordering = ticketRowOrder(view: view)
        let sql = ticketSelectionSQL(ownerView:view != nil,includeTriages:!["overview","trash"].contains(view?["surface"] as? String ?? ""),rowOrdering:ordering)
        arguments += ["limit":limit + 1,"offset":offset]
        // The page window and final hydrated SELECT both expose the same
        // `matching` alias. Qualify every ordering input before the canonical
        // envelope join introduces another data/id/project_id column.
        let groupOrder = view == nil ? "" : ticketGroupOrder(view!,prefix:"matching.")
        let unitOrder = view == nil ? "" : "matching.unit_class, matching.triage_label COLLATE checklist_human_order, matching.group_id COLLATE BINARY, matching.unit_kind, CASE WHEN matching.unit_class=0 THEN checklist_timestamp(json_extract(matching.data,'$.updated_at')) END DESC, CASE WHEN matching.unit_class=0 THEN matching.id END DESC, "
        let pageOrder = unitOrder + groupOrder + ticketRowOrder(view:view,prefix:"matching.")
        // One materialization supplies the window, truthful distinct task counts,
        // and selected Triage summaries. Empty pages still return their totals.
        let result = try Row.fetchAll(db,sql:ticketWindowSQL(selection:sql,ownerView:view != nil,ordering:pageOrder),arguments:arguments)
        let count = (result.first?["matched_total"] as Int?) ?? 0
        let fetched = result.filter { ($0["page_present"] as Int?) != nil }
        let selected = Array(fetched.prefix(limit))
        var seenIDs = Set<SnapshotRecordIdentity>()
        let selectedTasks = selected.filter { row in
            guard let id = row["id"] as String? else { return false }
            return seenIDs.insert(SnapshotRecordIdentity(id)).inserted
        }
        let taskRows = listProjection(try projectTicketPage(db,rows:selectedTasks,projectJSON:projectJSON,ownerView:view != nil),fields:fields)
        let hasMore = fetched.count > limit
        let next: Any = hasMore ? try cursor(db,caller:c,scope:cursorScope,sequence:offset + limit) : NSNull()
        let previous: Any = offset > 0 ? try cursor(db,caller:c,scope:cursorScope,sequence:max(0,offset-limit)) : NSNull()
        guard view != nil else { return ["tasks":taskRows,"total":count,"has_more":hasMore,"next_cursor":next,"previous_cursor":previous] }
        let scopedCount = (result.first?["scoped_total"] as Int?) ?? 0
        var page: JSON = ["query_key":queryKey,"content_cursor":try cursor(db,caller:c,scope:try authorizationScope(db,c),sequence:latest),
            "tasks":taskRows,"scoped_count":scopedCount,"matched_count":count,"has_more":hasMore,"next_cursor":next,"previous_cursor":previous]
        let summaries = try ticketTriageSummaries(db,units:selected)
        page["triages"] = summaries
        page["ordinary_ids"] = selected.filter { ($0["unit_class"] as Int) == 1 }.compactMap { $0["id"] as String? }
        // Small taxonomy/sidebar metadata is distinct from the full snapshot index.
        // Owner sidebar lists all owned projects even when one Tickets project is selected.
        page["projects"] = try projects(db,c)
        for (name,type) in [("statuses","status"),("tags","tag")] {
            page[name] = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type=? AND project_id IN (SELECT value FROM json_each(?)) ORDER BY rowid",arguments:[type,projectJSON]).map {try GRDBRecordEnvelopeAdapter.decode($0).object}
        }
        page["epics"] = try Row.fetchAll(db,sql:"SELECT id,project_id,json_extract(data,'$.name') name,json_extract(data,'$.key') key FROM records WHERE type='group' AND json_extract(data,'$.kind')='epic' AND project_id IN (SELECT value FROM json_each(?)) ORDER BY rowid",arguments:[projectJSON]).map {["id":$0["id"] as String,"project_id":$0["project_id"] as String,"key":$0["key"] as String? ?? "","name":$0["name"] as String? ?? ""]}
        page["filter_triages"] = try Row.fetchAll(db,sql:"SELECT id,project_id,json_extract(data,'$.name') name,json_extract(data,'$.key') key FROM records WHERE type='group' AND json_extract(data,'$.kind')='triage' AND project_id IN (SELECT value FROM json_each(?)) ORDER BY rowid",arguments:[projectJSON]).map {["id":$0["id"] as String,"project_id":$0["project_id"] as String,"key":$0["key"] as String? ?? "","name":$0["name"] as String? ?? ""]}
        // Global sidebar badges do not force the full requests/tasks corpus into memory.
        let needs = try ownerNeedsYouCounts(db)
        page["outstanding_request_count"] = needs.requests
        page["human_task_count"] = needs.tasks
        let preview = try overviewRequestPreview(db,projectJSON:projectJSON,query:query,surface:view?["surface"] as? String ?? "tickets")
        page["overview_requests"] = preview["requests"]
        page["overview_request_count"] = preview["count"]
        page["service"] = try dispatch(db,method:"service_info",p:[:],c:c)
        return ["schema_version":1,"tickets_page":page]
    }

    private func ticketRowOrder(view: JSON?, prefix: String = "") -> String {
        if view?["order_by"] as? String == "updated_desc" { return "checklist_timestamp(json_extract(\(prefix)data,'$.updated_at')) DESC, \(prefix)id DESC" }
        if view?["order_by"] as? String == "priority" { return "CASE json_extract(\(prefix)data,'$.priority') WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'normal' THEN 2 WHEN 'low' THEN 3 ELSE 4 END, COALESCE(json_extract(\(prefix)data,'$.order'),1), COALESCE(json_extract(\(prefix)data,'$.created_at'),''), \(prefix)id" }
        return view == nil ? "\(prefix)storage_order" : "COALESCE(json_extract(\(prefix)data,'$.order'),1), COALESCE(json_extract(\(prefix)data,'$.created_at'),''), \(prefix)id"
    }

    private func ticketDisplayCategory(prefix: String = "") -> String {
        "CASE WHEN \(prefix)category IN ('done','completed') THEN 'done' WHEN \(prefix)category IN ('canceled','\(LegacyStoredValue.canceled)') THEN 'canceled' WHEN json_extract(\(prefix)data,'$.readiness')='draft' AND \(prefix)category='queued' THEN 'draft' ELSE \(prefix)category END"
    }
    private func ticketDisplayLabel(prefix: String = "") -> String {
        let category = ticketDisplayCategory(prefix:prefix)
        return "CASE WHEN (" + category + ")='draft' AND COALESCE(json_extract(\(prefix)data,'$.archived'),0)=0 THEN 'Drafts' ELSE CASE WHEN COALESCE(json_extract(\(prefix)data,'$.archived'),0)=1 THEN 'Archived · ' ELSE '' END || CASE WHEN (" + category + ")='draft' THEN 'Draft' WHEN (" + category + ")='done' THEN CASE WHEN COALESCE(json_extract(\(prefix)status_data,'$.name'),'')='' OR lower(json_extract(\(prefix)status_data,'$.name')) IN ('done','completed') THEN 'Done' ELSE 'Done · '||json_extract(\(prefix)status_data,'$.name') END WHEN (" + category + ")='canceled' THEN CASE WHEN COALESCE(json_extract(\(prefix)status_data,'$.name'),'')='' OR lower(json_extract(\(prefix)status_data,'$.name')) IN ('canceled','\(LegacyStoredValue.canceled)') THEN 'Canceled' ELSE 'Canceled · '||json_extract(\(prefix)status_data,'$.name') END ELSE COALESCE(json_extract(\(prefix)status_data,'$.name'),\(prefix)category) END END"
    }
    private var ticketDisplayRank: String {
        "CASE (" + ticketDisplayCategory() + ") WHEN 'active' THEN 0 WHEN 'in_progress' THEN 1 WHEN 'working' THEN 2 WHEN 'review' THEN 3 WHEN 'ready' THEN 4 WHEN 'queued' THEN 5 WHEN 'blocked' THEN 6 WHEN 'parked' THEN 7 WHEN 'draft' THEN 8 WHEN 'done' THEN 9 WHEN 'completed' THEN 10 WHEN 'canceled' THEN 11 WHEN '\(LegacyStoredValue.canceled)' THEN 12 ELSE 99 END"
    }
    private func ticketGroupOrder(_ view: JSON, prefix: String = "") -> String {
        if view["group_by"] as? String == "none" { return "" }
        if view["group_by"] as? String == "epic" {
            return "COALESCE((SELECT json_extract(e.data,'$.name') FROM records e WHERE e.type='group' AND e.id=json_extract(\(prefix)data,'$.epic_id') AND e.project_id=\(prefix)project_id),'No Epic') COLLATE checklist_display_label, "
        }
        let label = ticketDisplayLabel(prefix:prefix)
        return "COALESCE((SELECT group_rank FROM status_group_ranks r WHERE r.display_label=(" + label + ") COLLATE checklist_display_label),99), " + label + " COLLATE checklist_display_label, "
    }

    private func overviewRequestPreview(_ db: Database, projectJSON: String, query: String, surface: String) throws -> JSON {
        guard surface == "overview" else { return ["requests":[JSON](),"count":0] }
        let selection = """
        FROM records r JOIN records p ON p.id=r.project_id AND p.type='project'
        LEFT JOIN records t ON t.id=json_extract(r.data,'$.task_id') AND t.project_id=r.project_id AND t.type='task'
        WHERE r.type='request' AND r.project_id IN (SELECT value FROM json_each(:projects))
          AND COALESCE(json_extract(r.data,'$.state'),'') NOT IN ('answered','canceled','\(LegacyStoredValue.canceled)','superseded','resolved')
          AND (:query='' OR checklist_contains(COALESCE(json_extract(r.data,'$.title'),'')||' '||COALESCE(json_extract(t.data,'$.key'),'')||' '||COALESCE(json_extract(p.data,'$.name'),''),:query))
        """
        let args: StatementArguments = ["projects":projectJSON,"query":query]
        let count = try Int.fetchOne(db,sql:"SELECT COUNT(*) " + selection,arguments:args) ?? 0
        let rows = try Row.fetchAll(db,sql:"SELECT \(Self.canonicalColumns(alias:"r")),json_extract(t.data,'$.key') task_key,json_extract(p.data,'$.name') project_name " + selection + " ORDER BY r.rowid LIMIT 3",arguments:args)
        let preview: [JSON] = try rows.map { row in
            var request = try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"request").object; request["task_key"] = row["task_key"] as String? ?? ""; request["project_name"] = row["project_name"] as String? ?? ""
            return request
        }
        return ["requests":preview,"count":count]
    }

    private func jsonStringArray(_ values: [String]) throws -> String {
        String(decoding:try JSONSerialization.data(withJSONObject:values),as:UTF8.self)
    }

    /// Record identity joins use the columns' own storage collation; Unicode equivalence is
    /// reserved for human search, never an identity or scope comparison.
    private func ticketSelectionSQL(ownerView: Bool, includeTriages: Bool, rowOrdering: String) -> String {
        let ownerCTEs = """
        , memberships AS MATERIALIZED (
          SELECT DISTINCT g.id gid,g.project_id,
            CASE WHEN j.type='object' THEN json_extract(j.value,'$.task_id') ELSE j.value END tid
          FROM records g,json_each(CASE WHEN json_array_length(json_extract(g.data,'$.members'))>0 THEN json_extract(g.data,'$.members') ELSE json_extract(g.data,'$.task_ids') END) j
          WHERE g.type='group' AND json_extract(g.data,'$.kind')='triage' AND g.project_id IN (SELECT value FROM json_each(:projects))
        ), triages AS MATERIALIZED (
          SELECT g.id,g.project_id,g.revision,g.data,
            (COALESCE(json_extract(g.data,'$.orchestration.state'),'')='active' OR EXISTS (
              SELECT 1 FROM memberships m JOIN records t ON t.id=m.tid AND t.project_id=m.project_id AND t.type='task'
              LEFT JOIN records s ON s.id=json_extract(t.data,'$.status_id') AND s.project_id=t.project_id AND s.type='status'
              WHERE m.gid=g.id AND (json_extract(t.data,'$.active_attempt_id') IS NOT NULL OR json_extract(s.data,'$.category')='active'))) active
          FROM records g WHERE g.type='group' AND json_extract(g.data,'$.kind')='triage' AND g.project_id IN (SELECT value FROM json_each(:projects))
        ), notes AS MATERIALIZED (
          SELECT project_id,CAST(note_rows.tid AS TEXT) COLLATE BINARY tid,group_concat(body,' ') body FROM (
            SELECT project_id,json_extract(data,'$.task_id') tid,COALESCE(json_extract(data,'$.body'),'') body
            FROM records WHERE type='message' AND :query<>'' AND project_id IN (SELECT value FROM json_each(:projects)) ORDER BY rowid
          ) note_rows GROUP BY project_id,note_rows.tid
        )
        """
        // Compatibility attention feeds health/context only; Active facets use category.
        let attention = ownerView ? "(json_extract(t.data,'$.active_attempt_id') IS NOT NULL OR json_extract(s.data,'$.category')='active' OR EXISTS (SELECT 1 FROM memberships m JOIN triages g ON g.id=m.gid AND g.project_id=m.project_id WHERE m.tid=t.id AND m.project_id=t.project_id AND COALESCE(json_extract(g.data,'$.archived'),0)=0 AND g.active))" : "0"
        let surface = ownerView ? "(:trashed=1 OR closed=:closed)" : "COALESCE(json_extract(data,'$.archived'),0)=:archived"
        let facets = ownerView ? """
        (:status='all' OR (:status<>'active' AND status_id=:status COLLATE BINARY) OR category=:status COLLATE BINARY
          OR (:status='archived' AND COALESCE(json_extract(data,'$.archived'),0)=1)
          OR (:status='done' AND category IN ('done','completed')) OR (:status='canceled' AND category IN ('canceled','\(LegacyStoredValue.canceled)'))
          OR (:status='draft' AND json_extract(data,'$.readiness')='draft' AND NOT closed)
          OR (:status='ready' AND json_extract(data,'$.readiness')='ready' AND category='queued'))
        AND (:tag='all' OR EXISTS (SELECT 1 FROM json_each(json_extract(data,'$.tag_ids')) WHERE value=:tag COLLATE BINARY))
        AND \(ticketFacetSQL)
        """ : "(json_array_length(:statuses)=0 OR status_id IN (SELECT value FROM json_each(:statuses)))"
        let textExpression = ownerView ? "COALESCE(json_extract(f.data,'$.title'),'')||' '||COALESCE(json_extract(f.data,'$.key'),'')||' '||COALESCE(json_extract(f.data,'$.brief'),'')||' '||f.project_name||CASE WHEN n.body IS NULL THEN '' ELSE ' '||n.body END" : "COALESCE(json_extract(f.data,'$.title'),'')||' '||COALESCE(json_extract(f.data,'$.brief'),'')||' '||COALESCE(json_extract(f.data,'$.key'),'')"
        let groupMatch = ownerView && includeTriages ? "OR EXISTS (SELECT 1 FROM memberships m JOIN triages g ON g.id=m.gid AND g.project_id=m.project_id WHERE m.tid=f.id AND m.project_id=f.project_id AND (:closed=1 OR COALESCE(json_extract(g.data,'$.archived'),0)=0) AND checklist_contains(COALESCE(json_extract(g.data,'$.key'),'')||' '||COALESCE(json_extract(g.data,'$.name'),'')||' '||COALESCE(json_extract(g.data,'$.purpose'),'')||' '||f.project_name,:query))" : ""
        let units = ownerView ? """
        , visible_triages AS MATERIALIZED (
          SELECT g.* FROM triages g WHERE \(includeTriages ? "1" : "0") AND (:closed=1 OR COALESCE(json_extract(g.data,'$.archived'),0)=0)
            AND EXISTS (SELECT 1 FROM memberships m JOIN surface f ON f.id=m.tid AND f.project_id=m.project_id WHERE m.gid=g.id)
            AND (EXISTS (SELECT 1 FROM memberships m JOIN matching f ON f.id=m.tid AND f.project_id=m.project_id WHERE m.gid=g.id)
              OR (:query<>'' AND checklist_contains(COALESCE(json_extract(g.data,'$.key'),'')||' '||COALESCE(json_extract(g.data,'$.name'),'')||' '||COALESCE(json_extract(g.data,'$.purpose'),'')||' '||COALESCE((SELECT json_extract(p.data,'$.name') FROM records p WHERE p.id=g.project_id AND p.type='project'),''),:query)))
        ), ordinary_rows AS MATERIALIZED (
          SELECT f.*, (\(ticketDisplayLabel())) display_label FROM matching f
            WHERE NOT EXISTS (SELECT 1 FROM memberships m JOIN visible_triages g ON g.id=m.gid AND g.project_id=m.project_id WHERE m.tid=f.id AND m.project_id=f.project_id)
        ), ranked_ordinary AS (
          SELECT o.*,row_number() OVER (PARTITION BY display_label COLLATE checklist_display_label ORDER BY \(rowOrdering)) group_position FROM ordinary_rows o
        ), status_group_ranks AS (
          SELECT display_label, (\(ticketDisplayRank)) group_rank FROM ranked_ordinary WHERE group_position=1
        ), list_units AS (
          SELECT NULL id,g.project_id,NULL data,0 storage_order,NULL status_data,'' category,NULL status_id,'' project_name,0 closed,0 attention,
            0 unit_class,g.id group_id,COALESCE(json_extract(g.data,'$.name'),'') triage_label,0 unit_kind FROM visible_triages g
          UNION ALL
          SELECT f.*,0 unit_class,g.id group_id,COALESCE(json_extract(g.data,'$.name'),'') triage_label,1 unit_kind
            FROM matching f JOIN memberships m ON m.tid=f.id AND m.project_id=f.project_id JOIN visible_triages g ON g.id=m.gid AND g.project_id=m.project_id
          UNION ALL
          SELECT f.id,f.project_id,f.data,f.storage_order,f.status_data,f.category,f.status_id,f.project_name,f.closed,f.attention,
            1 unit_class,'' group_id,'' triage_label,1 unit_kind FROM ordinary_rows f
        )
        """ : ""
        return """
        WITH input AS (SELECT :projects,:query,:closed,:archived,:statuses,:status,:tag,:filterTags,:tagMode,:planned,:actual,:epic,:triage,:trashed), authorized AS (SELECT value id FROM json_each(:projects))
        \(ownerView ? ownerCTEs : "")
        , base AS (
          SELECT t.id,t.project_id,t.data,t.rowid storage_order,s.data status_data,
            COALESCE(json_extract(s.data,'$.category'),'') category,json_extract(t.data,'$.status_id') status_id,
            COALESCE(json_extract(p.data,'$.name'),'') project_name,
            (COALESCE(json_extract(t.data,'$.archived'),0)=1 OR COALESCE(json_extract(s.data,'$.category'),'') IN ('done','completed','canceled','\(LegacyStoredValue.canceled)')) closed,
            COALESCE(\(attention),0) attention
          FROM records t JOIN authorized a ON t.project_id=a.id
          JOIN records p ON p.id=t.project_id AND p.type='project'
          LEFT JOIN records s ON s.id=json_extract(t.data,'$.status_id') AND s.project_id=t.project_id AND s.type='status'
          WHERE t.type='task' AND COALESCE(json_extract(t.data,'$.purged'),0)=0 AND COALESCE(json_extract(t.data,'$.trashed'),0)=:trashed
            AND (:listTriage=0 OR t.id IN (SELECT value FROM json_each(:listMembers)))
            AND (:listEpic='' OR json_extract(t.data,'$.epic_id')=:listEpic COLLATE BINARY)
            AND (:listHasKeys=0 OR checklist_key_fold(json_extract(t.data,'$.key')) IN (SELECT value FROM json_each(:listKeys)))
        ), surface AS MATERIALIZED (SELECT * FROM base WHERE \(surface)), facets AS (SELECT * FROM surface WHERE \(facets)),
        matching AS MATERIALIZED (SELECT f.* FROM facets f \(ownerView ? "LEFT JOIN notes n ON n.project_id=f.project_id AND n.tid=f.id" : "")
          WHERE :query='' OR checklist_contains(\(textExpression),:query) \(groupMatch))
        \(units)
        """
    }

    private func projectTicketPage(_ db: Database, rows: [Row], projectJSON: String, ownerView: Bool) throws -> [JSON] {
        guard !rows.isEmpty else { return [] }
        let ids = rows.map { $0["id"] as String }, idsJSON = try jsonStringArray(ids)
        let relations = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='relation' AND project_id IN (SELECT value FROM json_each(?)) AND json_extract(data,'$.source_task_id') IN (SELECT value FROM json_each(?)) AND COALESCE(json_extract(data,'$.state'),'')<>'removed' ORDER BY rowid",arguments:[projectJSON,idsJSON]).map {try GRDBRecordEnvelopeAdapter.decode($0).object}
        let tags = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='tag' AND project_id IN (SELECT value FROM json_each(?)) ORDER BY rowid",arguments:[projectJSON]).map {try GRDBRecordEnvelopeAdapter.decode($0).object}
        // The cache belongs to this one authenticated read transaction. Missing
        // records still use scoped(), and failures stay deferred until requested.
        var values: [TicketPageLookupKey:Result<JSON,Error>] = [:]
        func seed(_ value: JSON, type: String) {
            guard let id = value["id"] as? String,let pid = value["project_id"] as? String else { return }
            values[TicketPageLookupKey(project:pid,type:type,id:id)] = .success(value)
        }
        for row in rows {seed(try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"task").object,type:"task")}
        for row in try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='status' AND project_id IN (SELECT value FROM json_each(?)) ORDER BY rowid",arguments:[projectJSON]) {
            seed(try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"status").object,type:"status")
        }
        func lookup(_ id: String,_ project: String,_ type: String) throws -> JSON {
            let key = TicketPageLookupKey(project:project,type:type,id:id)
            if let value = values[key] { return try value.get() }
            let value = Result { try self.scoped(db,id,project,type:type) }
            values[key] = value
            return try value.get()
        }
        func preloadTasks(_ taskIDs: [String], project: String) throws {
            var seen = Set<SnapshotRecordIdentity>()
            let missing = taskIDs.filter { seen.insert(SnapshotRecordIdentity($0)).inserted && values[TicketPageLookupKey(project:project,type:"task",id:$0)] == nil }
            guard !missing.isEmpty else { return }
            for row in try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='task' AND project_id=? AND id IN (SELECT value FROM json_each(?)) ORDER BY rowid",arguments:[project,try jsonStringArray(missing)]) {
                seed(try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"task").object,type:"task")
            }
        }
        for project in Set(rows.map {SnapshotRecordIdentity($0["project_id"] as String)}) {
            let pid = rows.first {SnapshotRecordIdentity($0["project_id"] as String)==project}!["project_id"] as String
            try preloadTasks(relations.filter {SnapshotRecordIdentity($0["project_id"] as? String ?? "")==project}.compactMap {$0["target_task_id"] as? String},project:pid)
        }
        var groupsByProject: [SnapshotRecordIdentity:[JSON]] = [:]
        var groupResults: [TicketPageLookupKey:Result<Bool,Error>] = [:]
        func groupAttention(_ task: JSON, project: String) throws -> Bool {
            let projectKey = SnapshotRecordIdentity(project)
            if groupsByProject[projectKey] == nil {
                let selectedIDs = rows.filter {SnapshotRecordIdentity($0["project_id"] as String)==projectKey}.map {$0["id"] as String}
                // Retain the existing triageMemberIDs/contains semantics and
                // storage order. Only groups relevant to this page need tasks.
                let groups = try self.records(db,type:"group",project:project).filter {
                    $0["kind"] as? String == "triage" && !bool($0,"archived")
                    && self.triageMemberIDs($0).contains(where: {selectedIDs.contains($0)})
                }
                try preloadTasks(groups.flatMap {self.triageMemberIDs($0)},project:project)
                groupsByProject[projectKey] = groups
            }
            for group in groupsByProject[projectKey] ?? [] where self.triageMemberIDs(group).contains(task["id"] as! String) {
                let key = TicketPageLookupKey(project:project,type:"group",id:group["id"] as! String)
                let value: Result<Bool,Error>
                if let cached = groupResults[key] { value = cached }
                else {
                    value = Result { try self.projectedTriageAttention(group,taskLookup:{try lookup($0,project,"task")},statusLookup:{try lookup($0,project,"status")}) }
                    groupResults[key] = value
                }
                if try value.get() { return true }
            }
            return false
        }
        return try rows.map { row in
            let task = try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"task").object, pid = task["project_id"] as! String
            let status = try lookup(task["status_id"] as? String ?? "",pid,"status")
            let prerequisites = projectedPrerequisites(task:task,relations:relations.filter {SnapshotRecordIdentity($0["project_id"] as? String ?? "")==SnapshotRecordIdentity(pid) && SnapshotRecordIdentity($0["source_task_id"] as? String ?? "")==SnapshotRecordIdentity(task["id"] as? String ?? "")},taskLookup:{try lookup($0,pid,"task")},statusLookup:{try lookup($0,pid,"status")})
            let relation = projectedRelationTask(task:task,prerequisites:prerequisites,category:status["category"] as? String ?? "unknown",canonicalID:try projectedCanonicalTaskID(task:task,taskLookup:{try lookup($0,pid,"task")}))
            let wanted = Set(strings(task,"tag_ids").map(SnapshotRecordIdentity.init))
            let selectedTags = tags.filter {SnapshotRecordIdentity($0["project_id"] as? String ?? "")==SnapshotRecordIdentity(pid) && wanted.contains(SnapshotRecordIdentity($0["id"] as? String ?? ""))}
            // Shared semantics retain active-attempt/status short circuits and
            // the original order of deferred Triage failures.
            let attention = ownerView ? (row["attention"] as Bool) : (try projectedTaskAttention(task,statusLookup:{try lookup($0,pid,"status")},groupAttention:{try groupAttention(task,project:pid)}))
            return try withStatusReason(db,task:assembledTaskProjection(task,status:status.isEmpty ? nil : status,activeAttention:attention,tags:selectedTags,relation:relation))
        }
    }

    private func ticketWindowSQL(selection: String, ownerView: Bool, ordering: String) -> String {
        let stream = ownerView ? "list_units" : "matching"
        let groups = ownerView ? """
        , selected_groups AS (SELECT DISTINCT group_id FROM page_candidates WHERE unit_class=0),
        group_stats AS MATERIALIZED (
          SELECT g.id summary_group_id,g.project_id summary_project_id,g.data summary_data,
            g.revision summary_revision,g.active summary_active,
            COUNT(DISTINCT m.tid) summary_member_count,COUNT(DISTINCT f.id) summary_matching_count,
            COUNT(DISTINCT json_extract(t.data,'$.status_id')) summary_status_count,
            (SELECT json_extract(t.data,'$.status_id') FROM memberships x JOIN records t
              ON t.id=x.tid AND t.project_id=x.project_id AND t.type='task' WHERE x.gid=g.id LIMIT 1) summary_uniform_status_id,
            SUM(CASE WHEN t.id IS NULL THEN 1 ELSE 0 END) summary_missing_count
          FROM selected_groups x JOIN visible_triages g ON g.id=x.group_id
          JOIN memberships m ON m.gid=g.id AND m.project_id=g.project_id
          LEFT JOIN records t ON t.id=m.tid AND t.project_id=m.project_id AND t.type='task'
          LEFT JOIN matching f ON f.id=m.tid AND f.project_id=m.project_id
          GROUP BY g.id
        )
        """ : ""
        let scopedTotal = ownerView ? ",(SELECT COUNT(*) FROM surface) scoped_total" : ""
        return selection + """
        , page_candidates AS MATERIALIZED (
          SELECT 1 page_present,* FROM \(stream) matching ORDER BY \(ordering) LIMIT :limit OFFSET :offset
        ), totals AS (SELECT (SELECT COUNT(*) FROM matching) matched_total\(scopedTotal))
        \(groups)
        SELECT matching.*,canonical.type,canonical.revision,CAST(canonical.id AS BLOB) AS _envelope_id_bytes,CAST(canonical.project_id AS BLOB) AS _envelope_project_id_bytes,CAST(canonical.type AS BLOB) AS _envelope_type_bytes,CAST(canonical.data AS BLOB) AS _envelope_data_bytes,totals.*\(ownerView ? ",g.*" : "") FROM totals
        LEFT JOIN page_candidates matching ON 1
        LEFT JOIN records canonical ON canonical.id=matching.id AND canonical.project_id=matching.project_id AND canonical.type='task'
        \(ownerView ? "LEFT JOIN group_stats g ON g.summary_group_id=matching.group_id COLLATE BINARY" : "")
        ORDER BY \(ordering)
        """
    }

    private func ticketTriageSummaries(_ db: Database, units: [Row]) throws -> [JSON] {
        var seen = Set<SnapshotRecordIdentity>()
        let rows = units.filter { row in
            guard let id = row["summary_group_id"] as String? else { return false }
            return seen.insert(SnapshotRecordIdentity(id)).inserted
        }
        let groupIDs = rows.map { $0["summary_group_id"] as String }
        let sourceRows=try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='group' AND id IN (SELECT value FROM json_each(?))",arguments:[try jsonStringArray(groupIDs)])
        var sources:[SnapshotRecordIdentity:JSON]=[:]
        for row in sourceRows {let source=try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"group").object;sources[SnapshotRecordIdentity(source["id"] as! String)]=source}
        var byID: [SnapshotRecordIdentity:JSON] = [:]
        for row in rows {
            guard (row["summary_missing_count"] as Int) == 0 else { throw CoreError("NOT_FOUND", "A current Triage member is not available in this project.") }
            let gid = row["summary_group_id"] as String, pid = row["summary_project_id"] as String
            guard let source=sources[SnapshotRecordIdentity(gid)],SnapshotRecordIdentity(source["project_id"] as? String ?? "")==SnapshotRecordIdentity(pid) else {throw CoreError("NOT_FOUND","This selected Triage is no longer available.")}
            let members = units.filter { ($0["group_id"] as String?).map(SnapshotRecordIdentity.init) == SnapshotRecordIdentity(gid) && ($0["unit_kind"] as Int) == 1 }.compactMap {$0["id"] as String?}
            let count = row["summary_member_count"] as Int, uniform = (row["summary_status_count"] as Int) == 1
            let status: JSON? = uniform ? try scoped(db,row["summary_uniform_status_id"] as String? ?? "",pid,type:"status") : nil
            var result: JSON = ["id":gid,"project_id":pid,"revision":row["summary_revision"] as Int,"kind":"triage","member_count":count,"matching_count":row["summary_matching_count"] as Int,
                "page_member_ids":members,"members_complete":false,"active_attention":row["summary_active"] as Bool,
                "status_state":uniform ? "uniform" : "mixed","status_id":status?["id"] ?? NSNull(),"status_name":status?["name"] ?? "Mixed","status_category":status?["category"] ?? "mixed"]
            for key in ["key","name","purpose","phase","archived"] { result[key] = source[key] ?? (key=="archived" ? false : "") }
            // Display only: a bounded coordinator identity, never member work authority.
            if let orchestration = source["orchestration"] as? JSON {
                var display: JSON = [:]
                for key in ["state", "actor_display", "session_id"] { display[key] = orchestration[key] as? String ?? "" }
                result["orchestration"] = display
            }
            byID[SnapshotRecordIdentity(gid)] = result
        }
        return groupIDs.compactMap { byID[SnapshotRecordIdentity($0)] }
    }
}

/// Every new lookup key preserves opaque identity bytes, separately from display
/// labels and the existing shared attention helper's membership behavior.
private struct TicketPageLookupKey: Hashable {
    let project: SnapshotRecordIdentity
    let type: String
    let id: SnapshotRecordIdentity
    init(project: String, type: String, id: String) {
        self.project = SnapshotRecordIdentity(project); self.type = type; self.id = SnapshotRecordIdentity(id)
    }
}
