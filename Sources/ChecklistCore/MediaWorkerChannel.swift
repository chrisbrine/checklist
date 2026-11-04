import ChecklistContracts
import Foundation
import GRDB

/// Worker preparation and reporting share canonical media records with the owner
/// channel. This allowlist never grants publication, context adoption or decisions.
extension CommandRouter {
    static let mediaWorkerMethods = MediaWorkerContract.methods
    static let mediaWorkerReads = MediaWorkerContract.readMethods

    func executeMediaWorkerChannel(method: String,params p: JSON,caller c: Caller) throws -> JSON {
        guard c.role == "worker",Self.mediaWorkerMethods.contains(method) else {
            throw CoreError("FORBIDDEN","An enrolled worker media command is required.")
        }
        if !Self.mediaWorkerReads.contains(method) {
            let result = try executeMediaCommand(method:method,params:p,caller:c,workerChannel:true)
            // CL-419: a type command answers a closed projection; owner adoption records stay private.
            if method.hasPrefix("media_type_") { return mediaWorkerTypeChange(result) }
            // CL-420: a round closure or successor answers a closed round projection.
            return ["media_round_cancel","media_round_archive","media_round_finish","media_round_successor","media_round_link_task"].contains(method) ? mediaWorkerRoundChange(result) : result
        }
        // CL-320: safe worker projections read one pooled snapshot, so they answer
        // during a backup's writer lease; authority is checked inside that snapshot.
        let admission = try storageAdmission.acquire();defer {admission.finish()}
        return try readForPreparation { db in
            let project = try self.mediaAccess(db,p,c)
            switch method {
            case "media_type_list":
                let rows = try Row.fetchAll(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE project_id=CAST(? AS TEXT) AND type='media_review_type' AND json_extract(data,'$.enabled')=1 ORDER BY id COLLATE BINARY LIMIT 9",arguments:[Data(project.utf8)])
                guard rows.count <= 8 else {throw CoreError("CAPACITY_EXCEEDED","The project exceeds its enabled media type bound.")}
                return ["types":try rows.map {try self.mediaWorkerType(db,GRDBRecordEnvelopeAdapter.decode($0,expectedType:"media_review_type").object,project:project)}]
            case "media_type_get":
                return try self.mediaWorkerType(db,self.scoped(db,text(p,"type_id"),project,type:"media_review_type"),project:project)
            case "media_rework_preview":
                return try self.mediaReworkPreview(db,p,c,project:project,agent:true)
            case "media_intake_get":
                let intake = try self.scoped(db,text(p,"intake_id"),project,type:"media_intake")
                guard intake["author"] as? String == c.principal else {
                    throw CoreError("FORBIDDEN","A worker reads only its own intake plan and selected source paths.")
                }
                return try self.mediaIntakeView(db,intake:intake)
            default:
                let round = try self.scoped(db,text(p,"round_id"),project,type:"media_round")
                if method == "media_decision_list" { return try self.mediaWorkerDecisions(db,round:round,p:p,c:c) }
                return try self.mediaWorkerRound(db,round:round,p:p,c:c)
            }
        }
    }

    /// The Draft definition and its caller-bound token let the same agent adopt what it created or revised.
    private func mediaWorkerTypeChange(_ type: JSON) -> JSON {
        var result: JSON = [:]
        for key in ["id","project_id","title","state","enabled","revision","starter_id","draft_revision_id","adopted_revision_id","observed_type_token","replayed"] {
            result[key] = type[key]
        }
        if let draft = type["draft_revision"] as? JSON {
            result["draft_revision"] = ["id":draft["id"] ?? NSNull(),"schema":draft["schema"] ?? NSNull(),"rubric":draft["rubric"] ?? ""]
        }
        return result
    }

    private func mediaWorkerRoundChange(_ round: JSON) -> JSON {
        var result: JSON = [:]
        for key in ["id","project_id","type_id","title","state","revision","closure","cancellation_reason","predecessor_round_id",
                    "predecessor_manifest_id","successor","canceled_by","archived_by","closed_by","task_id","task","last_result_sent","replayed"] {
            result[key] = round[key]
        }
        return result
    }

    private func mediaWorkerType(_ db: Database,_ type: JSON,project: String) throws -> JSON {
        let revision = try mediaWorkerAdoptedType(db,type,project:project)
        let stored = StoredRecord(type,family:"media_review_type"),adopted = StoredRecord(revision,family:"media_review_type_revision")
        return ["id":try stored.requiredValue("id"),"project_id":project,"title":try stored.requiredValue("title"),
            "revision":try stored.requiredValue("revision"),"type_revision_id":try adopted.requiredValue("id"),
            "schema":try adopted.object("schema"),"rubric":try adopted.string("rubric")]
    }

    private func mediaWorkerAdoptedType(_ db: Database,_ type: JSON,project: String) throws -> JSON {
        guard bool(type,"enabled"),type["state"] as? String != "retired",
              let id = type["adopted_revision_id"] as? String,
              (type["adoptions"] as? [JSON] ?? []).contains(where:{$0["type_revision_id"] as? String == id}) else {
            throw CoreError("MEDIA_TYPE_NOT_ADOPTED","The owner must enable and adopt the media type before worker preparation.")
        }
        return try scoped(db,id,project,type:"media_review_type_revision")
    }

    /// Run before source access and again against the pinned preparation snapshot.
    /// Intake author checks and exact confirmed-plan checks remain in CL-113.
    func mediaWorkerWriteAccess(_ db: Database,method: String,p: JSON,c: Caller,project: String) throws {
        guard c.role == "worker",Self.mediaWorkerMethods.contains(method),!Self.mediaWorkerReads.contains(method) else {
            throw CoreError("FORBIDDEN","Workers prepare Drafts or add suggestions; owner actions require the native owner channel.")
        }
        if MediaWorkerContract.settingMethods.contains(method) {
            // CL-419 (owner, 3 November 2026): media types and publication are agent setting
            // changes under the project's agent_rule_changes switch, like every other agent change.
            try requireAgentEditAuthority(db,project:record(db,project,type:"project"),caller:c)
            if method == "media_round_create" {
                _ = try mediaWorkerAdoptedType(db,scoped(db,text(p,"type_id"),project,type:"media_review_type"),project:project)
            }
            return
        }
        if method == "media_suggest" || method == "media_follow_up_record" {return}
        let round: JSON
        if method == "media_intake_preview" {
            round = try scoped(db,text(p,"round_id"),project,type:"media_round")
        } else {
            let intake = try scoped(db,text(p,"intake_id"),project,type:"media_intake")
            guard intake["author"] as? String == c.principal else {throw CoreError("FORBIDDEN","A worker changes only its own intake.")}
            round = try scoped(db,StoredRecord(intake,family:"media_intake").string("round_id"),project,type:"media_round")
        }
        guard round["state"] as? String == "draft" else {throw CoreError("MEDIA_ROUND_NOT_DRAFT","Worker file intake requires a Draft round.")}
        _ = try mediaWorkerAdoptedType(db,scoped(db,StoredRecord(round,family:"media_round").string("type_id"),project,type:"media_review_type"),project:project)
    }

    /// Explicitly selected decision fields only. Owner principals, session identity,
    /// context-source bodies and canonical owner-channel observations stay private.
    func mediaWorkerDecision(_ decision: JSON) -> JSON {
        var result: JSON = [:]
        for key in ["id","project_id","round_id","item_id","target_id","disposition","winner_id","none_fit","note","created_at","supersedes_decision_id","withdraws_decision_id"] {
            result[key] = decision[key]
        }
        result["decision_id"] = decision["id"];result["decided_at"] = decision["created_at"]
        return result
    }

    func mediaWorkerRound(_ db: Database,round: JSON,p: JSON,c: Caller) throws -> JSON {
        let project = try StoredRecord(round,family:"media_round").string("project_id")
        var query: JSON = ["project_id":project,"round_id":try StoredRecord(round,family:"media_round").requiredValue("id"),"limit":p["limit"] ?? 100]
        query["cursor"] = p["cursor"]
        let page = try mediaListQuery(db,method:"media_item_page",p:query,c:c,project:project)
        var result: JSON = [:]
        for key in ["id","project_id","type_id","title","state","revision","origin","created_at"] {result[key] = round[key]}
        result["task_id"] = round["task_id"]
        result["task"] = try mediaRoundTask(db,round:round) ?? NSNull()
        result["last_result_sent"] = round["last_result_sent"]
        if round["origin"] as? String == "agent" {
            result["author"] = round["author"];result["author_session_id"] = round["author_session_id"]
        }
        result["observed_context_token"] = try mediaToken(db,round:round,caller:c)
        result["context_attention"] = !strings(round,"attention_ids").isEmpty
        // CL-350: closure counts and the Needs look items stay readable after Close.
        result["closure"] = round["closure"]
        let followUps = mediaFollowUpIndex(try mediaReworkLinks(db,round:round))
        if let id = round["manifest_id"] as? String {
            let manifest = try scoped(db,id,project,type:"media_round_manifest")
            result["manifest"] = ["id":id,"digest":try StoredRecord(manifest,family:"media_round_manifest").requiredValue("digest")]
        } else {result["manifest"] = JSON()}
        // CL-419: an agent publication selects the same prospective basis as the owner's preview.
        let parts = ["draft","open"].contains(round["state"] as? String ?? "") ? try mediaRoundParts(db,round) : nil
        let items = try (page["rows"] as? [JSON] ?? []).map { row -> JSON in
            let target = try scoped(db,StoredRecord(row,family:"media item page").string("target_id"),project,type:"media_item_target")
            let selected = StoredRecord(row,family:"media item page"),stored = StoredRecord(target,family:"media_item_target")
            var value: JSON = ["id":try selected.requiredValue("id"),"item_id":try selected.requiredValue("id"),
                "revision":try selected.requiredValue("revision"),"expected_revision":try selected.requiredValue("revision"),
                "title":try stored.string("title"),"metadata":try stored.object("metadata"),"target_id":try stored.requiredValue("id"),
                "review_basis_signature":try stored.requiredValue("review_basis_signature"),"candidate_ids":try stored.requiredValue("candidate_ids"),
                "publication_ready":try stored.requiredValue("publication_ready"),"disposition":try selected.requiredValue("disposition"),
                "task":row["task"] ?? NSNull()]
            value["task_id"] = row["task_id"]
            if let (type,context) = parts {
                let item = try scoped(db,try selected.string("id"),project,type:"media_item")
                let draft = try scoped(db,StoredRecord(item,family:"media_item").string("draft_target_id"),project,type:"media_item_target")
                let shape = StoredRecord(try mediaShapeForTarget(db,item:item,target:draft,typeRevision:type,context:context),family:"media_item_target")
                value["publication_preview"] = ["target_id":try StoredRecord(draft,family:"media_item_target").requiredValue("id"),
                    "review_basis_signature":try shape.requiredValue("review_basis_signature"),"publication_ready":try shape.requiredValue("publication_ready")]
            }
            if let id = row["decision_id"] as? String,!id.isEmpty {
                let decision = try scoped(db,id,project,type:"media_owner_decision")
                value["decision"] = mediaWorkerDecision(decision)
                for key in ["winner_id","none_fit","note"] {value[key] = decision[key]}
                value["decision_id"] = id;value["decided_at"] = decision["created_at"]
                value["follow_up"] = try mediaFollowUpView(db,index:followUps,decisionID:id,project:project)
            }
            value["agent_suggestions"] = try mediaItemSuggestions(db,project:project,itemID:try selected.string("id"),target:target,round:round)
                .filter {!bool($0,"stale")}.map(mediaCurrentSuggestionView)
            return value
        }
        result["items"] = items;result["rows"] = items
        for key in ["total","counts","snapshot","has_more","next_cursor","requires_current_observation"] {result[key] = page[key]}
        return result
    }

    private func mediaWorkerDecisions(_ db: Database,round: JSON,p: JSON,c: Caller) throws -> JSON {
        let project = try StoredRecord(round,family:"media_round").string("project_id")
        let roundID = try StoredRecord(round,family:"media_round").string("id")
        let limit = try MediaConfigurationValue.integer(p["limit"] ?? 100,min:1,max:100,"limit")
        let identity: JSON = ["method":"media_decision_list","project_id":project,"round_id":roundID,
            "scope":try authorizationScope(db,c),"workspace":c.workspace ?? "",
            "generation":try callerSessionGeneration(db,c,project:project)]
        let scope = try MediaCanonical.signature(identity)
        let after = try cursorSequence(db,p,caller:c,scope:scope)
        let records = try Row.fetchAll(db,sql:"SELECT rowid AS media_position," + Self.canonicalRecordColumns +
            " FROM records WHERE project_id=CAST(? AS TEXT) AND type='media_owner_decision' AND rowid>?" +
            " AND json_extract(data,'$.round_id')=CAST(? AS TEXT) COLLATE BINARY ORDER BY rowid LIMIT ?",
            arguments:[Data(project.utf8),after,Data(roundID.utf8),limit + 1])
        let selected = Array(records.prefix(limit))
        let rows = try selected.map {try GRDBRecordEnvelopeAdapter.decode($0,expectedType:"media_owner_decision").object}
        let cursor = try cursor(db,caller:c,scope:scope,sequence:selected.last.map {$0["media_position"] as Int} ?? after)
        return ["round_id":roundID,"rows":rows.map(mediaWorkerDecision),"has_more":records.count > limit,
            "cursor":cursor,"next_cursor":cursor]
    }

    /// Bounded owner display of actual worker suggestions, separate from decisions.
    func mediaItemSuggestions(_ db: Database,project: String,itemID: String,target: JSON,round: JSON) throws -> [JSON] {
        try Row.fetchAll(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE project_id=CAST(? AS TEXT) AND type='media_suggestion'" +
            " AND json_extract(data,'$.item_id')=CAST(? AS TEXT) COLLATE BINARY ORDER BY rowid DESC LIMIT 100",
            arguments:[Data(project.utf8),Data(itemID.utf8)]).map { row in
                try mediaSuggestionView(db,suggestion:GRDBRecordEnvelopeAdapter.decode(row,expectedType:"media_suggestion").object,
                    project:project,target:target,round:round)
            }
    }

    func mediaSuggestionView(_ db: Database,suggestion original: JSON,project: String,target: JSON,round: JSON) throws -> JSON {
        var suggestion = original
        if let sessionID = suggestion["author_session_id"] as? String,
           let session = try? scoped(db,sessionID,project,type:"session") {
            suggestion["source_label"] = sessionThreadLabel(session)
        } else {suggestion["source_label"] = "Recorded worker"}
        suggestion["author_display"] = suggestion["source_label"]
        suggestion["source"] = suggestion["source"] ?? "agent"
        suggestion["dismissed"] = mediaSuggestionDismissal(suggestion,target:target,round:round)
        suggestion["display_only"] = true
        suggestion["stale"] = !mediaSuggestionCurrent(suggestion,target:target)
        return suggestion
    }

    /// Current card advice never exposes the owner's identity or grants decision authority.
    func mediaCurrentSuggestionView(_ suggestion: JSON) -> JSON {
        ["id":suggestion["id"] ?? NSNull(),"disposition":suggestion["disposition"] ?? NSNull(),
         "note":suggestion["note"] ?? "","author_display":suggestion["author_display"] ?? "Recorded worker",
         "source":suggestion["source"] ?? "agent"]
    }
}
