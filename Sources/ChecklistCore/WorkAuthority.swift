import Foundation
import ChecklistProviders
import GRDB
import Darwin

extension CommandRouter {
    func validateScopeInputs(_ params: JSON) throws {
        for key in ["file_scopes","lane_scopes"] { if params[key] != nil && !(params[key] is [JSON]) { throw CoreError("INVALID_INPUT","\(key) must contain scope objects.") } }
    }
    // Resolve symlinks and volume case rules before comparing reservations, including paths not created yet.
    func reservationKey(_ path: String) -> String {
        var ancestor = URL(fileURLWithPath:(path as NSString).expandingTildeInPath).standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath:ancestor.path),ancestor.path != "/" { missing.insert(ancestor.lastPathComponent,at:0);ancestor.deleteLastPathComponent() }
        let existing: String
        if let physical = ancestor.path.withCString({realpath($0,nil)}) { existing = String(cString:physical);free(physical) } else {existing = canonical(ancestor.path)}
        let resolved = missing.reduce(URL(fileURLWithPath:existing)) {$0.appendingPathComponent($1)}.path.precomposedStringWithCanonicalMapping
        let sensitive = (try? URL(fileURLWithPath:existing).resourceValues(forKeys:[.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? true
        return sensitive ? resolved : resolved.lowercased()
    }
    // Use physical parent coordinates for aliases, retaining the final declared link.
    func declaredScopePath(_ path: String,root: String) -> String {
        let url = URL(fileURLWithPath:path.hasPrefix("/") ? path : URL(fileURLWithPath:root).appendingPathComponent(path).path).standardizedFileURL
        return URL(fileURLWithPath:reservationKey(url.deletingLastPathComponent().path)).appendingPathComponent(url.lastPathComponent).path.precomposedStringWithCanonicalMapping
    }
    func normalizedWorkScopes(_ db: Database, project: JSON, fileScopes: [JSON], laneScopes: [JSON]) throws -> (files:[JSON],lanes:[JSON]) {
        guard fileScopes.count <= 200,laneScopes.count <= 32 else { throw CoreError("INVALID_INPUT","Too many work scopes.") }
        let root = project["root_path"] as? String ?? ""
        var files: [JSON] = [],lanes: [JSON] = []
        for input in fileScopes {
            let raw = try text(input,"path",max:4096),access = input["access"] as? String ?? "read"
            guard ["read","write"].contains(access),!root.isEmpty else { throw CoreError("INVALID_INPUT","File scopes need an enrolled root and read/write access.") }
            let path = canonical(raw.hasPrefix("/") ? raw : URL(fileURLWithPath:root).appendingPathComponent(raw).path),key = reservationKey(path)
            guard containsPath(reservationKey(root),key) else { throw CoreError("ROOT_MISMATCH","Work scopes must remain inside this project’s canonical root.") }
            guard !files.contains(where: {$0["canonical_key"] as? String == key}) else { throw CoreError("INVALID_INPUT","Duplicate canonical file scope.") }
            let alias = input["declared_path"] as? String ?? raw
            let declared = declaredScopePath(alias,root:root)
            files.append(["path":key,"canonical_key":key,"declared_path":declared,"access":access])
        }
        for input in laneScopes {
            let name = try text(input,"lane_id",max:100),units = int(input,"units",default:1)
            guard name.range(of:"^[A-Za-z0-9_.-]+$",options:.regularExpression) != nil,units > 0,units <= 32,!lanes.contains(where: {$0["lane_id"] as? String == name}) else { throw CoreError("INVALID_INPUT","Use unique named lanes with 1–32 units.") }
            lanes.append(["lane_id":name,"units":units])
        }
        return (files,lanes)
    }
    func activeDescendants(_ db: Database, attempt: JSON) throws -> [JSON] {
        let project = attempt["project_id"] as? String
        // Retained completed attempts cannot be active descendants. Select candidates
        // in SQLite before canonical decoding, then retain the graph checks below.
        // json_each considers every duplicate/escaped state key; Foundation's final
        // value still decides eligibility. Malformed JSON remains fail-closed.
        let all = try readSnapshotCache.records(db,key:["active-descendant-candidates",project]) {
            var sql = "SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='attempt'"
            var arguments = StatementArguments()
            if let project {sql += " AND project_id=CAST(? AS TEXT)";arguments += [Data(project.utf8)]}
            sql += " AND CASE WHEN json_valid(data) THEN EXISTS (SELECT 1 FROM json_each(records.data) WHERE key='state' AND type='text' AND CAST(value AS BLOB)=CAST('active' AS BLOB)) ELSE 1 END ORDER BY rowid"
            return try Row.fetchAll(db,sql:sql,arguments:arguments)
        }
        var parents = Set([attempt["id"] as! String]),result: [JSON] = []
        while true {
            let added = all.filter { row in row["state"] as? String == "active" && !parents.contains(row["id"] as? String ?? "") && parents.contains(row["parent_attempt_id"] as? String ?? "") }
            if added.isEmpty { break }; result += added;parents.formUnion(added.compactMap {$0["id"] as? String})
        }
        return result
    }
    func requireNoWritableChildren(_ db: Database, attempt: JSON) throws {
        guard !(try activeDescendants(db,attempt:attempt)).contains(where: { !(($0["file_scopes"] as? [JSON] ?? []).filter {$0["access"] as? String == "write"}).isEmpty || !(($0["lane_scopes"] as? [JSON]) ?? []).isEmpty }) else { throw CoreError("CHILD_WRITERS_ACTIVE","Every writable descendant must release or have explicit verified recovery before this operation.") }
    }
    func validateWorkReservations(_ db: Database, candidate: JSON, excluding: Set<String> = [],batchContext: BatchClaimContext? = nil) throws {
        let pid = candidate["project_id"] as! String,project = try record(db,pid,type:"project")
        let files = candidate["file_scopes"] as? [JSON] ?? [],lanes = candidate["lane_scopes"] as? [JSON] ?? []
        guard files.contains(where: {$0["access"] as? String == "write"}) || !lanes.isEmpty else {return}
        let others = try records(db,type:"attempt").filter {$0["state"] as? String == "active" && !excluding.contains($0["id"] as? String ?? "") && $0["id"] as? String != candidate["id"] as? String}
        for scope in files where scope["access"] as? String == "write" {
            let path = reservationKey(scope["path"] as! String)
            for other in others {
                for reserved in other["file_scopes"] as? [JSON] ?? [] where reserved["access"] as? String == "write" {
                    let old = reserved["canonical_key"] as? String ?? reservationKey(reserved["path"] as! String)
                    if containsPath(path,old) || containsPath(old,path) {
                        if try sharesFrozenBatchWrite(db,candidate,other,path:path,reserved:old,context:batchContext) { continue }
                        throw CoreError("SCOPE_CONFLICT","Canonical write scope \(path) conflicts between \(try reservationTicketLabel(db,candidate)) and \(candidate["project_id"] as? String == other["project_id"] as? String ? try reservationTicketLabel(db,other) : "another project ticket").",details:try reservationConflictDetails(db,candidate,other,path:path,reserved:old))
                    }
                }
            }
        }
        let capacities = (project["policy"] as? JSON)?["lane_capacities"] as? JSON ?? [:]
        for lane in lanes {
            let name = lane["lane_id"] as! String,capacity = int(capacities,name,default:1)
            let parent = try (candidate["parent_attempt_id"] as? String).map {try record(db,$0,type:"attempt")}
            let effectiveCapacity = parent.map { ($0["lane_scopes"] as? [JSON] ?? []).filter {$0["lane_id"] as? String == name}.reduce(0) {$0+int($1,"units",default:1)} } ?? capacity
            let used = others.filter { $0["project_id"] as? String == pid && (parent == nil ? $0["parent_attempt_id"] == nil : $0["parent_attempt_id"] as? String == candidate["parent_attempt_id"] as? String) }.reduce(0) { sum,other in sum + (other["lane_scopes"] as? [JSON] ?? []).filter {$0["lane_id"] as? String == name}.reduce(0) {$0+int($1,"units",default:1)} }
            guard used + int(lane,"units",default:1) <= effectiveCapacity else { throw CoreError("LANE_FULL","The \(name) lane has no remaining capacity.") }
        }
    }
    func requireLiveAncestry(_ db: Database, attempt: JSON) throws {
        var cursor = attempt
        while let id = cursor["parent_attempt_id"] as? String {
            let pid = attempt["project_id"] as! String,parent = try scoped(db,id,pid,type:"attempt")
            guard parent["state"] as? String == "active",parent["incarnation"] as? String == incarnation,let sid = parent["session_id"] as? String,let session = try? scoped(db,sid,pid,type:"session"),canReceive(session,project:pid),parent["session_authorization_generation"] as? String == sessionGeneration(session),!bool(parent,"policy_authority_revoked"),parent["pending_policy_revision"] == nil else { throw CoreError("STALE_CLAIM","Delegated write authority needs the complete live, current ancestor chain. Read-only survivors cannot regain writes from an ended parent.") }
            cursor = parent
        }
    }
    func adjustWorkScopes(_ db: Database, params: JSON, attempt: inout JSON) throws {
        try requireLiveAncestry(db,attempt:attempt)
        try validateScopeInputs(params)
        try requireNoSourceExecutions(db,attempt:attempt)
        let pid = attempt["project_id"] as! String,project = try record(db,pid,type:"project")
        let scopes = try normalizedWorkScopes(db,project:project,fileScopes:params["file_scopes"] as? [JSON] ?? attempt["file_scopes"] as? [JSON] ?? [],laneScopes:params["lane_scopes"] as? [JSON] ?? attempt["lane_scopes"] as? [JSON] ?? [])
        // Narrowing and expansion share one transaction; no child can lose its enclosing authority.
        let children = try activeDescendants(db,attempt:attempt)
        for child in children {
            for path in child["file_scopes"] as? [JSON] ?? [] where path["access"] as? String == "write" {
                guard scopes.files.contains(where: {$0["access"] as? String == "write" && containsPath($0["canonical_key"] as! String,path["canonical_key"] as! String)}) else { throw CoreError("CHILD_WRITERS_ACTIVE","Resolve the affected child before narrowing its writable scope.") }
            }
        }
        for child in children where child["parent_attempt_id"] as? String == attempt["id"] as? String {
            for lane in child["lane_scopes"] as? [JSON] ?? [] {
                let name = lane["lane_id"] as! String
                let delegated = children.filter {$0["parent_attempt_id"] as? String == attempt["id"] as? String}.reduce(0) {sum,row in sum + (row["lane_scopes"] as? [JSON] ?? []).filter {$0["lane_id"] as? String == name}.reduce(0) {$0+int($1,"units",default:1)}}
                let retained = scopes.lanes.filter {$0["lane_id"] as? String == name}.reduce(0) {$0+int($1,"units",default:1)}
                guard retained >= delegated else { throw CoreError("CHILD_WRITERS_ACTIVE","Resolve the affected child before reducing its reserved lane capacity.") }
            }
        }
        var updated = attempt;updated["file_scopes"] = scopes.files;updated["lane_scopes"] = scopes.lanes
        var exempt = Set(children.compactMap {$0["id"] as? String});var cursor = attempt
        while let parent = cursor["parent_attempt_id"] as? String { exempt.insert(parent);cursor = try record(db,parent,type:"attempt") }
        if let parent = attempt["parent_attempt_id"] as? String { let bound = try record(db,parent,type:"attempt");try requireBoundedScopes(scopes.files,lanes:scopes.lanes,parent:bound) }
        try validateWorkReservations(db,candidate:updated,excluding:exempt);attempt = updated
    }
    func requireBoundedScopes(_ files: [JSON],lanes: [JSON],parent: JSON) throws {
        let parentFiles = parent["file_scopes"] as? [JSON] ?? []
        for file in files {
            guard parentFiles.contains(where: { scope in (scope["access"] as? String == "write" || file["access"] as? String == "read") && containsPath(scope["canonical_key"] as! String,file["canonical_key"] as! String) }) else { throw CoreError("SCOPE_CONFLICT","A delegated scope must fit entirely inside the parent’s current reservation.") }
        }
        for lane in lanes { guard (parent["lane_scopes"] as? [JSON] ?? []).contains(where: {$0["lane_id"] as? String == lane["lane_id"] as? String && int($0,"units",default:1) >= int(lane,"units",default:1)}) else { throw CoreError("SCOPE_CONFLICT","A delegated lane must fit inside its parent reservation.") } }
    }
    func eligibleWorkSession(_ db: Database, id: String, project: String) throws -> JSON {
        let session = try scoped(db,id,project,type:"session")
        guard session["role"] as? String == "worker",canReceive(session,project:project),providerPlugins.plugin((session["provider"] as? String ?? "").lowercased(), requiring: .workSession) != nil,let domain = session["execution_domain"] as? String,!domain.isEmpty,let installation = session["installation"] as? String,!installation.isEmpty else { throw CoreError("UNVERIFIED_SESSION","Select an existing native host-bound worker session.") }
        return session
    }
    func workAuthority(_ db: Database,_ p: JSON,_ c: Caller,_ method: String) throws -> JSON {
        try worker(c);let pid = try scope(db,p,c,write:true)
        try validateScopeInputs(p)
        if method == "work_takeover" { return try takeOverWork(db,p,c,pid) }
        if method == "work_child_accept" || method == "work_handoff_accept" {
            let isChild = method == "work_child_accept",id = try text(p,isChild ? "delegation_id" : "offer_id")
            var offer = try scoped(db,id,pid,type:isChild ? "delegation" : "handoff")
            guard offer["state"] as? String == "offered",offer["target_session_id"] as? String == c.sessionID,offer["target_generation"] as? String == (try callerSessionGeneration(db,c,project:pid)),offer["target_domain"] as? String == c.executionDomain else { throw CoreError("STALE_CLAIM","This exact native session no longer owns the offered authority.") }
            var parent = try scoped(db,offer["attempt_id"] as! String,pid,type:"attempt")
            guard parent["state"] as? String == "active",parent["incarnation"] as? String == incarnation else { throw CoreError("STALE_CLAIM","The original authority is no longer live.") }
            let origin = try scoped(db,parent["session_id"] as! String,pid,type:"session")
            guard parent["session_authorization_generation"] as? String == sessionGeneration(origin),canReceive(origin,project:pid) else { throw CoreError("STALE_CLAIM","The original session authority was revoked.") }
            try requireLiveAncestry(db,attempt:parent)
            let originalCaller = Caller(role:"worker",installation:origin["installation"] as? String ?? "",projectIDs:[pid],sessionID:origin["id"] as? String,workspace:origin["workspace"] as? String,executionDomain:origin["execution_domain"] as? String)
            try verifyPolicyAuthority(db,attempt:parent,caller:originalCaller)
            var targetTask = try scoped(db,parent["task_id"] as! String,pid,type:"task");targetTask.removeValue(forKey:"planned_assignee")
            try validatePolicySelection(db,project:try record(db,pid,type:"project"),task:targetTask,caller:c,phase:"implementation",policy:try attemptPolicy(db,parent))
            if !isChild { try requireNoWritableChildren(db,attempt:parent);try requireNoSourceExecutions(db,attempt:parent) }
            if isChild {
                var rootAttempt = parent
                while let rootID = rootAttempt["parent_attempt_id"] as? String { rootAttempt = try scoped(db,rootID,pid,type:"attempt") }
                guard try activeDescendants(db,attempt:rootAttempt).count < 32 else { throw CoreError("CAPACITY_EXCEEDED","The active delegation tree is limited to 32 descendants.") }
            }
            var a = parent;a["id"] = uuid();a["principal"] = c.principal;a["installation"] = c.installation;a["session_id"] = c.sessionID!;a["session_authorization_generation"] = try callerSessionGeneration(db,c,project:pid);a["execution_domain"] = c.executionDomain!;a["actor_display"] = author(db,c);a["started_at"] = now();a["revision"] = 1
            for key in ["progress","last_checkpoint","token_hash"] + Self.attemptOwnRecordKeys { a.removeValue(forKey:key) }
            if isChild { a["parent_attempt_id"] = parent["id"];a["file_scopes"] = offer["file_scopes"];a["lane_scopes"] = offer["lane_scopes"];try requireBoundedScopes(a["file_scopes"] as? [JSON] ?? [],lanes:a["lane_scopes"] as? [JSON] ?? [],parent:parent) }
            else { a["handoff_from_attempt_id"] = parent["id"];a["handoff_context"] = offer["summary"];parent["state"] = "handed_off";parent.removeValue(forKey:"token_hash");try save(db,revised(parent),type:"attempt") }
            var ancestors = Set([parent["id"] as! String]);var ancestor = parent
            while let id = ancestor["parent_attempt_id"] as? String { ancestors.insert(id);ancestor = try scoped(db,id,pid,type:"attempt") }
            try validateWorkReservations(db,candidate:a,excluding:ancestors)
            let token = uuid()+uuid();a["token_hash"] = hash(Data(token.utf8));try save(db,a,type:"attempt")
            if !isChild && a["parent_attempt_id"] == nil {
                var t = try scoped(db,a["task_id"] as! String,pid,type:"task");t["active_attempt_id"] = a["id"]
                if t["planned_assignee"] != nil { t["planned_assignee"] = ["kind":"agent","session_id":c.sessionID!,"provider":(try scoped(db,c.sessionID!,pid,type:"session"))["provider"] ?? ""];t["assignment_reason"] = offer["summary"];t["assignment_provenance"] = ["actor":c.principal,"origin":"accepted_handoff","at":now(),"handoff_id":offer["id"]!] }
                try save(db,revised(t),type:"task")
            }
            offer["state"] = "accepted";offer["accepted_attempt_id"] = a["id"];try save(db,revised(offer),type:isChild ? "delegation" : "handoff");try event(db,caller:c,project:pid,entity:a["task_id"] as? String,kind:method,data:["attempt_id":a["id"]!]);a.removeValue(forKey:"token_hash");a["claim_token"] = token;let task = try scoped(db,a["task_id"] as! String,pid,type:"task");a["context"] = try compactTaskContext(db,task:task,caller:c);a["direction_cursor"] = (a["context"] as? JSON)?["direction_cursor"];return a
        }
        var a = try claimAttempt(db,p,c,pid)
        try requireLiveAncestry(db,attempt:a)
        try verifyPolicyAuthority(db,attempt:a,caller:c)
        if method == "work_scope_adjust" { try adjustWorkScopes(db,params:p,attempt:&a);a = revised(a);try save(db,a,type:"attempt");try event(db,caller:c,project:pid,entity:a["task_id"] as? String,kind:"work_scopes_adjusted");a.removeValue(forKey:"token_hash");return a }
        guard a["phase"] as? String == "implementation" else { throw CoreError("INVALID_TRANSITION","Only implementation authority may delegate or hand off.") }
        let isChild = method == "work_delegate",target = try eligibleWorkSession(db,id:try text(p,isChild ? "child_session_id" : "target_session_id"),project:pid)
        guard target["id"] as? String != a["session_id"] as? String else { throw CoreError("INVALID_INPUT","Select a different actual session.") }
        var task = try scoped(db,a["task_id"] as! String,pid,type:"task");let project = try record(db,pid,type:"project");task.removeValue(forKey:"planned_assignee")
        let recipient = Caller(role:"worker",installation:target["installation"] as! String,projectIDs:[pid],sessionID:target["id"] as? String,workspace:target["workspace"] as? String,executionDomain:target["execution_domain"] as? String)
        try validatePolicySelection(db,project:project,task:task,caller:recipient,phase:"implementation",policy:try attemptPolicy(db,a))
        var offer: JSON = ["id":uuid(),"project_id":pid,"task_id":a["task_id"]!,"attempt_id":a["id"]!,"target_session_id":target["id"]!,"target_generation":sessionGeneration(target),"target_domain":target["execution_domain"]!,"state":"offered","revision":1,"created_at":now()]
        if isChild {
            guard (try activeDescendants(db,attempt:a)).count < 32 else { throw CoreError("CAPACITY_EXCEEDED","This attempt already has 32 active descendants.") }
            let scopes = try normalizedWorkScopes(db,project:try record(db,pid,type:"project"),fileScopes:p["file_scopes"] as? [JSON] ?? [],laneScopes:p["lane_scopes"] as? [JSON] ?? [])
            try requireBoundedScopes(scopes.files,lanes:scopes.lanes,parent:a);offer["file_scopes"] = scopes.files;offer["lane_scopes"] = scopes.lanes
        } else { try requireNoWritableChildren(db,attempt:a);try requireNoSourceExecutions(db,attempt:a);offer["summary"] = try text(p,"summary",max:32000) }
        try save(db,offer,type:isChild ? "delegation" : "handoff");try event(db,caller:c,project:pid,entity:a["task_id"] as? String,kind:method,data:["offer_id":offer["id"]!]);return offer
    }
}

extension CommandRouter {
    /// Owner decision (19 October 2026): any eligible agent takes over a claimed ticket
    /// without the holder's permission. The old claim and its delegated children end at
    /// once (their tokens stop working), contributors stay recorded for review
    /// independence, and each earlier holder gets a note with the new holder and reason.
    func takeOverWork(_ db: Database,_ p: JSON,_ c: Caller,_ pid: String) throws -> JSON {
        guard let sid = c.sessionID else { throw CoreError("FORBIDDEN","A paired work session is required.") }
        var t = try task(db,p,pid); try revision(p,t)
        let reason = try text(p,"reason",max:4000)
        guard let oldID = t["active_attempt_id"] as? String else { throw CoreError("INVALID_TRANSITION","This ticket has no active claim. Claim it with work_claim.") }
        var old = try scoped(db,oldID,pid,type:"attempt")
        guard old["state"] as? String == "active",old["task_id"] as? String == t["id"] as? String else { throw CoreError("STALE_CLAIM","The current claim is no longer live. Read the ticket again.") }
        guard old["session_id"] as? String != sid else { throw CoreError("INVALID_INPUT","This session already holds the claim.") }
        try requireNoSourceExecutions(db,attempt:old)
        let phase = old["phase"] as? String ?? "implementation", project = try record(db,pid,type:"project")
        if let pr = p["policy_revision"],(pr as? NSNumber)?.intValue != int(project,"policy_revision",default:1) { throw CoreError("POLICY_CHANGED","Refresh the current workflow rules before taking over.") }
        let session = try scoped(db,sid,pid,type:"session")
        guard session["role"] as? String == "worker",!["revoked","ended"].contains(session["state"] as? String ?? ""),providerPlugins.plugin((session["provider"] as? String ?? "").lowercased(), requiring: .workSession) != nil else { throw CoreError("POLICY_DENIED","This enrolled provider is not enabled for work in this build.") }
        let assignee = t["planned_assignee"] as? String ?? (t["planned_assignee"] as? JSON)?["kind"] as? String
        if phase == "implementation",assignee == "human" { throw CoreError("POLICY_DENIED","This task is assigned to the owner.") }
        let policy = effectivePolicy(project["policy"] as? JSON ?? [:],kind:t["kind"] as? String ?? "work")
        try validatePolicySelection(db,project:project,task:t,caller:c,phase:phase,policy:policy)
        if phase == "review" {
            guard let mid = old["manifest_id"] as? String else { throw CoreError("REVIEW_TARGET_MISMATCH","The review claim has no target.") }
            try validateContributorIndependence(manifest:try validateManifestTarget(db,task:t,manifestID:mid),caller:c)
        }
        // End the earlier claim tree; history keeps every attempt.
        let children = try activeDescendants(db,attempt:old)
        for var child in children { child["state"] = "taken_over";child["taken_over_reason"] = reason;child.removeValue(forKey:"token_hash");try save(db,revised(child),type:"attempt") }
        var a = old;a["id"] = uuid();a["principal"] = c.principal;a["installation"] = c.installation;a["session_id"] = sid;a["session_authorization_generation"] = try callerSessionGeneration(db,c,project:pid);a["actor_display"] = author(db,c);a["started_at"] = now();a["revision"] = 1;a["incarnation"] = incarnation
        if let domain = c.executionDomain { a["execution_domain"] = domain } else { a.removeValue(forKey:"execution_domain") }
        for key in ["progress","last_checkpoint","token_hash","pending_policy_revision","policy_authority_revoked","handoff_from_attempt_id","handoff_context"] + Self.attemptOwnRecordKeys { a.removeValue(forKey:key) }
        a["takeover_from_attempt_id"] = oldID;a["takeover_reason"] = reason;if let progress = old["progress"] { a["takeover_context"] = progress }
        if phase == "implementation" { a["policy_revision"] = project["policy_revision"] ?? 1;a["policy_snapshot"] = policy }
        if p["file_scopes"] != nil || p["lane_scopes"] != nil {
            let scopes = try normalizedWorkScopes(db,project:project,fileScopes:p["file_scopes"] as? [JSON] ?? [],laneScopes:p["lane_scopes"] as? [JSON] ?? [])
            a["file_scopes"] = scopes.files;a["lane_scopes"] = scopes.lanes
        }
        old["state"] = "taken_over";old["taken_over_reason"] = reason;old["taken_over_by_attempt_id"] = a["id"];old["taken_over_by_session_id"] = sid;old.removeValue(forKey:"token_hash");try save(db,revised(old),type:"attempt")
        try validateWorkReservations(db,candidate:a)
        let token = uuid()+uuid();a["token_hash"] = hash(Data(token.utf8));try save(db,a,type:"attempt")
        t["active_attempt_id"] = a["id"]
        if (t["planned_assignee"] as? JSON)?["kind"] as? String == "agent" { t["planned_assignee"] = ["kind":"agent","session_id":sid,"provider":session["provider"] ?? ""];t["assignment_reason"] = reason;t["assignment_provenance"] = ["actor":c.principal,"origin":"takeover","at":now(),"attempt_id":a["id"]!] }
        t = revised(t);try save(db,t,type:"task")
        try event(db,caller:c,project:pid,entity:t["id"] as? String,kind:"work_taken_over",data:["attempt_id":a["id"]!,"from_attempt_id":oldID,"from_session_id":old["session_id"] ?? "","phase":phase,"reason":reason])
        // Tell every earlier holder; a closed holder keeps the note in the ticket history.
        let body = "Ticket metadata: \(try agentReference(db,t)). \(AgentReference.quoted(author(db,c))) took over this ticket's \(phase) claim. Reason: \(reason)\nYour claim on this ticket ended: stop changing files for it and do not submit or record a verdict. Post anything useful as a note on this ticket."
        var holders: [String] = []
        for attempt in [old] + children { if let holder = attempt["session_id"] as? String,holder != sid,holder != "human",!holders.contains(holder) { holders.append(holder) } }
        var notices: [JSON] = []
        for holder in holders {
            guard let target = try? scoped(db,holder,pid,type:"session"),canReceive(target,project:pid) else { continue }
            notices.append(try messageWrite(db,["project_id":pid,"task_id":t["id"]!,"body":body,"recipient":["kind":"session","session_id":holder]],c,"message_send"))
        }
        if notices.isEmpty { notices.append(try messageWrite(db,["project_id":pid,"task_id":t["id"]!,"body":body],c,"message_send")) }
        a.removeValue(forKey:"token_hash");a["claim_token"] = token;a["task"] = try taskProjection(db,t);a["context"] = try compactTaskContext(db,task:t,caller:c)
        a["takeover_notices"] = notices.map { ["message_id":$0["id"] ?? NSNull(),"deliveries":$0["deliveries"] ?? []] as JSON }
        return a
    }
}

extension CommandRouter {
    func contributionHistory(_ db: Database, attempt: JSON) throws -> [JSON] {
        try records(db,type:"attempt",project:attempt["project_id"] as? String).filter {$0["task_id"] as? String == attempt["task_id"] as? String && $0["phase"] as? String == "implementation"}.map { row in
            var identity: JSON = ["attempt_id":row["id"]!,"principal":row["principal"]!,"session_id":row["session_id"]!,"session_authorization_generation":row["session_authorization_generation"] ?? ""]
            for key in ["execution_domain","installation","parent_attempt_id"] { if let value = row[key] { identity[key] = value } };return identity
        }
    }
    func validateContributorIndependence(manifest: JSON, caller: Caller) throws {
        // The native host authenticates the connection; it may run several genuinely
        // separate workers. Review independence concerns the actual contributors,
        // including prior/delegated identities, rather than every worker in that host.
        let author: JSON = ["principal":manifest["author_principal"] ?? NSNull(),"installation":manifest["author_installation"] ?? NSNull(),"session_id":manifest["author_session_id"] ?? NSNull()]
        if implementationContributor([author] + (manifest["contributors"] as? [JSON] ?? []),principal:caller.principal,installation:caller.installation,sessionID:caller.sessionID) { throw CoreError("REVIEW_INDEPENDENCE","A registered implementation contributor cannot independently review this target.") }
    }
    func implementationContributor(_ contributors: [JSON],principal: String,installation: String?,sessionID: String?) -> Bool {
        contributors.contains { $0["principal"] as? String == principal || (installation != nil && $0["installation"] as? String == installation) || (sessionID != nil && $0["session_id"] as? String == sessionID) }
    }
}
