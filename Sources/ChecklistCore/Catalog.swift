import Foundation
import ChecklistProviders
import GRDB

extension CommandRouter {
    func toolCatalog(_ c: Caller) -> [JSON] {
        let common = ["project_id","command_id","expected_revision"]
        var fields: [String:[String]] = [
            "service_info":[],"project_list":["include_archived"],"project_resolve":["workspace_path"],"project_settings_get":[],"policy_get":["revision","task_id"],"taxonomy_get":["revision"],
            "session_attach_task":["task_id"],"session_register":["label","provider","workspace_path"],"session_update":["state","observation"],"session_list":["task_id",
                "include_ended","cursor","limit"],"session_inbox":["cursor","attempt_id","limit"],"assistant_inbox":["task_id","cursor","limit"],"assistant_projects":[],
            "task_create":["title","brief","acceptance","kind","planned_assignee","assignment_reason","tag_ids","epic_id","owner_request_ref"],"task_get":["task_id","key"],
                "task_list":["text","status_ids","archived","triage_id","epic_id","keys","fields","cursor","limit"],"task_context":["task_id","history_cursor","detail_level"],
                "task_edit":["task_id","patch"],"task_transition":["task_id","action","reason","target_status_id"],
            "work_claim":["task_id","phase","policy_revision","file_scopes","lane_scopes","review_request_id","target_manifest_id","gate"],"work_checkpoint":["attempt_id",
                "claim_token","progress","direction_cursor"],"work_release":["attempt_id","claim_token","reason","continuation","direction_cursor","final_report"],
                "work_submit":["attempt_id","claim_token","acceptance_revision","evidence_manifest","acceptance_evidence","direction_cursor","final_report"],
                "review_record":["attempt_id","claim_token","review_request_id","target_manifest_id","gate","verdict","checks","review_assessment","findings","finding_resolutions",
                "supersedes_verdict_id","direction_cursor","reason","blocked_on","check","final_report","release_set","hold_reason"],"review_request":["task_id",
                "target_manifest_id","gate","supersedes_request_id","reason","supplemental_evidence_refs"],"task_complete":["task_id","current_manifest_id","accepted_verdict_ids",
                "direction_cursor","target_status_id"],
            "message_send":["task_id","body","kind","recipient","reply_to","owner_request_ref","triage_id","epic_id","audience"],"message_delivery_list":["task_id","triage_id","message_id"],
                "message_ack":["delivery_id","stage","response_ref","reaction"],"history_list":["entity","task_id","triage_id","epic_id","conversation_id","cursor","limit"],
                "agent_resolve":["name","agent_profile_id","task_id"],"agent_message_send":["recipient_target","body","expects_reply","task_id","reply_to","owner_request_ref"],
                "human_request_create":["task_id","title","blocking","questions","file_requests","target_attachment_id","review_request_id","target_manifest_id"],
                "attachment_add":["task_id","source","path","name","expected_sha256","description","mode"],"attachment_list":["task_id","cursor","limit"],
                "attachment_read":["attachment_id","representation"],"attachment_cleanup_preview":["task_id"],"triage_list":["key","triage_id","fields"],"epic_list":["key"],
                "epic_delete":["epic_id"],"epic_create":["name","brief","description"],"triage_create":["name","purpose"],"triage_transition":["triage_id","group_id",
                "target_status_id","action","reason","expected_member_revisions"],"epic_edit":["group_id","epic_id","name","brief","description"],"triage_edit":["group_id",
                "triage_id","name","purpose"],"group_membership":["group_id","task_id","action","expected_task_revision","from_epic_id","from_epic_revision","handling_phase","exit_milestone"]]
        let workflowFields: [String:[String]] = [
            "work_scope_adjust":["attempt_id","claim_token","file_scopes","lane_scopes"],
            "work_delegate":["attempt_id","claim_token","child_session_id","file_scopes","lane_scopes","brief"],
            "work_child_accept":["delegation_id"],
            "work_handoff_offer":["attempt_id","claim_token","target_session_id","summary"],
            "work_handoff_accept":["offer_id"],
            "work_takeover":["task_id","reason","policy_revision","file_scopes","lane_scopes"],
            "source_review_execute":["attempt_id","claim_token","tool","args"],
            "review_context":["task_id","review_request_id","target_manifest_id","gate","evidence_refs"],
            "review_prepare":["task_id","review_request_id","target_manifest_id","gate","provider"],
            "codex_thread_start":["task_id","host_outcome","thread_id","host_detail"],
            "review_evidence_add":["attempt_id","claim_token","title","body","measures"],
            "policy_preview":["policy","mode"],"policy_propose":["policy","mode"],
            "policy_acknowledge":["attempt_id","claim_token","task_id","reason"],
            "task_link":["task_id","relation","target_task_id","action","relation_id","required"],
            "relation_list":["task_id"],
            "human_request_revise":["request_id","patch","reason"],"human_request_cancel":["request_id","reason"],
            // Agents make project changes (owner decision 2026-10-18); requireAgentEditAuthority enforces the project switch.
            "policy_apply":["policy","mode","proposal_id","digest","reason"],
            "project_edit":["name","key_prefix","icon","accent","brief","pinned_decisions","default_view","alert_override","capture_defaults"],
            "project_archive":["archived","reason"],
            "project_settings_save":["name","key_prefix","icon","accent","brief","pinned_decisions","default_view","alert_override","capture_defaults","policy","mode",
                "policy_proposal_id","policy_digest","reason"],
            "status_create":["name","color","category","sort_order"],"status_edit":["status_id","name","color","category","sort_order"],
            "status_retire":["status_id","remap_target_status_id","expected_task_revisions"],
            "tag_create":["name","color","sort_order"],"tag_edit":["tag_id","name","color","sort_order"],"tag_retire":["tag_id"],
            "task_archive":["task_id","action","reason","cleanup","cleanup_preview_id","undo"]
        ]
        if c.role != "assistant" { fields["project_create"] = ["name","key_prefix","root_path","icon","accent"] }
        fields["work_recover"] = ["task_id","attempt_id","action","reason","observation_refs","file_state_refs","source_execution_ids","expected_source_execution_revisions"]
        fields["finding_waive"] = ["finding_id","reason"]
        fields["direction_waive"] = ["message_id","reason"]
        fields["project_icon_import"] = ["path"]
        fields["project_icon_clear"] = []
        fields["attachment_update"] = ["attachment_id","action","description"]
        fields["attachment_read_release"] = ["read_hold_id"]
        fields["relation_import"] = ["relations","aliases"]
        fields["human_request_snooze"] = ["request_id","snoozed"]
        fields["diagnostics_summary"] = []
        if c.role != "assistant" {
            fields["import_preview"] = ["path","source_format","source_namespace","epic_id"]
            fields["import_commit"] = ["path","source_format","source_namespace","epic_id","preview_digest"]
            fields["import_rollback"] = ["receipt_id"]
            fields["import_receipt_get"] = ["receipt_id"]
        }
        if c.role != "assistant" { fields["backup_create"] = ["qualification_name","reason"] }
        let batchFields: [String:[String]] = [
            "review_batch_inputs":["triage_id"],"batch_prepare":["triage_id","phase","tasks","checks"],"batch_claim":["batch_id","policy_revision"],
            "batch_discard":["batch_id","reason"],"batch_get":["batch_id"],"batch_list":["triage_id"],
            "batch_release":["batch_id","members","reason","final_report"],"batch_submit":["batch_id","members"],"batch_review_record":["batch_id","members"],
            "batch_complete_passing":["batch_id"],"batch_retriage_remaining":["batch_id","name","purpose"]
        ]
        fields["triage_orchestrate"] = ["triage_id","action","progress","reason","name"]
        fields["source_execution_get"] = ["execution_id"]
        fields["work_health_get"] = ["task_id"]
        fields["work_health_respond"] = ["task_id","request_id","progress"]
        fields.merge(batchFields) { _,new in new }
        fields["task_context"]! += ["context_revision_id"]
        fields["work_checkpoint"]! += ["direction_ids"]
        fields["message_send"]! += ["correction_of","content"]
        fields["task_create"]! += ["starter_fields"]
        if c.isOwner { fields["task_purge_preview"] = ["task_id"];fields["task_purge"] = ["task_id","preview_digest"] }
        if c.role != "assistant" {
            fields["message_send"]!.append("mention_target")
            fields["message_mentions_prepare"] = ["task_id","body","reply_to","selections"]
        }
        fields["triage_transition"]! += ["expected_direction_cursors"]
        fields["batch_complete_passing"]! += ["expected_direction_cursors"]
        fields["triage_create"]! += ["phase"]
        fields["triage_edit"]! += ["archived","phase"]
        fields["epic_edit"]! += ["archived"]
        fields.merge(workflowFields) { _,new in new }
        for method in ["project_edit","project_settings_save"] { fields[method]!.append("work_health_settings") }
        fields["work_checkpoint"]! += ["file_scopes","lane_scopes","waiting_for_resource"]
        fields["review_record"]! += ["retain_cited_files"]
        // Review outcomes and attempt records (Triage 3fd2303d).
        fields["review_record"]! += ["inspected_images"]
        fields["review_draft_save"] = fields["review_record"]!
        fields["review_draft_submit"] = ["task_id","attempt_id","direction_cursor"]
        fields["finding_severity_set"] = ["finding_id","severity","reason"]
        fields["release_set_complete"] = ["release_set","expected_task_revisions"]
        fields["task_bulk_edit"] = ["tasks","changes","preview"]
        fields["task_bulk_undo"] = ["original_command_id","tasks","preview","reason"]
        fields["work_claim"]! += ["direction_cursor"]
        fields["human_request_create"]! += ["explanation","command"] + Self.requestSupersedeKeys
        if c.isOwner { fields["task_get"]! += ["include_completion_eligibility"]; fields["task_list"]! += ["view"]; fields["task_context"]! += ["selected_context_cursor","records_family","cursor"] }
        if c.isOwner {
            fields["workspace_page"] = ["surface","record_id","text","cursor","limit","include_archived"]
        }
        fields["project_settings_save"]! += ["ticket_cleanup"]
        fields["ticket_cleanup_receipts"] = ["receipt_id","section","cursor","limit"]
        fields["archive_storage_settings"] = ["settings_revision","archive_storage"]
        fields["cleanup_job_list"] = ["task_id"]
        for command in ["cleanup_job_get","cleanup_job_cancel","cleanup_job_retry"] {fields[command] = ["cleanup_job_id"]}
        let reader: Set<String> = ["service_info","project_list","project_resolve","project_settings_get","policy_get","taxonomy_get","session_list","task_create","task_get",
            "task_list","task_context","message_send","message_ack","message_delivery_list","history_list","agent_resolve","agent_message_send","attachment_list","attachment_read",
            "attachment_add","review_batch_inputs"]
        let assistants = reader.union(["assistant_projects","assistant_inbox"])
        var allowed = c.role == "assistant" ? assistants : Set(fields.keys).subtracting(["assistant_inbox","assistant_projects"])
        if c.role == "assistant" {
            let readable = c.assistantGrants.filter { c.projectIDs.contains($0.key) && $0.value["read"] == true }
            if readable.isEmpty { allowed = ["service_info","project_list","assistant_projects"] }
            if !readable.contains(where: {$0.value["create_drafts_on_request"] == true}) { allowed.remove("task_create") }
            if !readable.contains(where: {$0.value["post_notes_on_request"] == true}) { allowed.subtract(["message_send","agent_resolve","agent_message_send","attachment_add"]) }
            if !readable.contains(where: {$0.value["receive_messages"] == true}) { allowed.subtract(["assistant_inbox","message_ack"]) }
        }
        return allowed.sorted().compactMap { name in
            guard let extra = fields[name] else { return nil }
            return catalogEntry(name: name, extra: extra, caller: c, common: common)
        }
    }
    func catalogEntry(name: String, extra: [String], caller c: Caller, common: [String]) -> JSON {
        var properties: JSON = [:]
        let keys = Set(extra + (name == "project_create" ? ["command_id"] : (name == "service_info" || name == "project_list" || name == "assistant_projects" ? [] : common)))
        for key in keys {
            if ["limit","expected_revision","expected_task_revision","from_epic_revision","policy_revision","acceptance_revision","revision","settings_revision",
                "sort_order"].contains(key) { properties[key] = ["type":"integer","minimum":0] }
            else if ["archived","blocking","expects_reply","include_archived","include_ended","required","include_completion_eligibility","cleanup","preview","undo",
                "retain_cited_files","snoozed"].contains(key) { properties[key] = ["type":"boolean"] }
            else if key == "ticket_cleanup" { properties[key] = Self.ticketCleanupSchema }
            else if key == "command_id" { properties[key] = ["type":"string","format":"uuid","maxLength":4000,
                "description":"A new random UUID for each distinct command. Reuse the same UUID only to retry the same command with the same input."] }
            else if ["keys","fields"].contains(key) { properties[key] = ["type":"array","items":["type":"string"],"maxItems":200] }
            else if key == "pinned_decisions" { properties[key] = ["type":"array","maxItems":25] }
            else if name == "message_send" && key == "audience" { properties[key] = ["type":"string","enum":Self.ticketAudienceValues,"default":"all",
                "description":"Ordinary ticket notes only (CL-248): all (default) sends to the ticket holder with its accepted subagents and to the Triage orchestrator; holder sends only to the holder and its subagents; orchestrator sends only to the Triage orchestrator. Cannot be combined with recipient. Owner directions, Human Request answers, verdict, takeover, handoff and work-health notices always reach both roles."] }
            else if name == "message_send" && key == "content" { properties[key] = ["type":"object","description":"Optional rich content v1 companion to body (docs/conversation-content.md): schema_version 1 and 1-32 blocks (markdown, table, chart, html, media). body must equal the block fallbacks joined with two line feeds. Presentation only; it records no answer, verdict or approval.","required":["schema_version","blocks"],"properties":["schema_version":["type":"integer","enum":[1]],"blocks":["type":"array","minItems":1,"maxItems":32,"items":["type":"object"]]],"additionalProperties":false] }
            else if ["work_health_settings","default_view","capture_defaults","expected_task_revisions","expected_source_execution_revisions"].contains(key) { properties[key] = ["type":"object"] }
            else if key == "selections" { properties[key] = Self.ordinaryMentionSelectionsSchema }
            else if key == "evidence_refs" { properties[key] = ["type":"array","maxItems":100] }
            else if key == "acceptance_evidence" { properties[key] = AcceptanceEvidence.schema }
            else if key == "measures" { properties[key] = EvidenceMeasure.schema }
            else if key == "supplemental_evidence_refs" { properties[key] = ["type":"array","maxItems":50] }
            else if key == "inspected_images" { properties[key] = ["type":"array","maxItems":ImageInspectionIdentity.maximumImages,"items":["type":"object",
                "required":["artifact_id","sha256","target_manifest_id"],"properties":["artifact_id":["type":"string"],"sha256":["type":"string"],
                "target_manifest_id":["type":"string"]],"additionalProperties":false],
                "description":"Explicit image inspection marks for this exact attachment/hash/manifest. A pass on image artifacts requires every candidate image; viewing " +
                "or opening does not create a mark."] }
            else if key == "final_report" { properties[key] = ["type":"string","maxLength":Self.finalReportLimit,
                "description":"Optional final report on this attempt (agent text, at most 64,000 bytes). It is stored on the attempt and shown on the ticket; it is never " +
                "an owner note or direction."] }
            else if name == "history_list" && key == "entity" { properties[key] = ["type":"string","enum":c.role == "assistant" ? ["project"] : ["project","backup"],
                "description":"Read the scoped project entity or backup receipts; mutually exclusive with task/group/conversation selectors."] }
            else if key == "host_outcome" { properties[key] = ["type":"string","enum":Self.codexThreadOutcomes.sorted()] }
            else if key == "blocked_on" { properties[key] = ["type":"string","enum":["implementation","reviewer"]] }
            else if key == "verdict" { properties[key] = ["type":"string","enum":Self.reviewVerdicts.sorted()] }
            else if key == "severity" { properties[key] = ["type":"string","enum":Self.findingSeverities.sorted()] }
            else if ["questions","file_requests","checks","findings","finding_resolutions","file_scopes","lane_scopes","acceptance","accepted_verdict_ids","tag_ids",
                "status_ids","args","tasks","submissions","verdicts","members","direction_ids","submission_receipt_ids","observation_refs","file_state_refs",
                "source_execution_ids","relations","aliases"].contains(key) { properties[key] = ["type":"array","maxItems":200] }
            else if key == "expected_direction_cursors" { properties[key] = ["type":"object","maxProperties":1000,"additionalProperties":["type":"string"]] }
            else if key == "expected_member_revisions" { properties[key] = ["type":"object","maxProperties":1000,"additionalProperties":["type":"integer","minimum":1]] }
            else if key == "reaction" { properties[key] = ["type":"string","enum":Self.noteReactions.sorted()] }
            else if key == "starter_fields" { properties[key] = ["type":"object",
                "description":"Optional starter fields. Bug: reproduction, expected, actual. Playtest: build, platform, clip (a link or file name; attach the file itself " +
                "with attachment_add).","properties":["reproduction":["type":"string","maxLength":16000],"expected":["type":"string","maxLength":4000],
                "actual":["type":"string","maxLength":4000],"build":["type":"string","maxLength":500],"platform":["type":"string","maxLength":200],"clip":["type":"string",
                "maxLength":2000]],"additionalProperties":false] }
            else if key == "recipient" { properties[key] = ["type":"object","properties":["kind":["type":"string","enum":["session"]],"session_id":["type":"string",
                "minLength":1,"maxLength":4000,"pattern":"\\S"]],"required":["kind","session_id"],"additionalProperties":false] }
            else if key == "view" { properties[key] = ["type":"object","properties":["surface":["type":"string","enum":["tickets","overview","archived","trash"]],
                "status_filter":["type":"string","maxLength":4000],"tag_filter":["type":"string","maxLength":4000],"tag_ids":["type":"array","items":["type":"string",
                "minLength":1,"maxLength":4000],"maxItems":100,"uniqueItems":true],"tag_mode":["type":"string","enum":["any","all","none"]],"planned_assignee":["type":"string",
                "minLength":1,"maxLength":4000],"actual_assignee":["type":"string","minLength":1,"maxLength":4000],"epic_id":["type":"string","minLength":1,"maxLength":4000],
                "triage_id":["type":"string","minLength":1,"maxLength":4000],"group_by":["type":"string","enum":["status","epic","none"]],"order_by":["type":"string",
                "enum":["manual","priority","updated_desc"]]],"required":["surface","status_filter","tag_filter","group_by","order_by"],"additionalProperties":false] }
            else if ["patch","source","evidence_manifest","owner_request_ref","planned_assignee","policy","command","response_ref","review_assessment","archive_storage",
                "changes"].contains(key) { properties[key] = ["type":"object"] }
            else { properties[key] = ["type":"string","maxLength":key == "body" || key == "brief" ? 65536 : 4000] }
        }
        if name == "task_edit" { properties["patch"] = ["type":"object",
            "description":"Fields to change: title, brief, acceptance, kind (work|bug|asset|playtest|question), readiness (draft|ready), priority " +
            "(none|low|normal|high|urgent), order, planned_assignee, assignment_reason, epic_id, tag_ids, starter_fields (Bug: reproduction, expected, " +
            "actual; Playtest: build, platform, clip; replaces the whole set). readiness=ready needs a non-empty brief; open prerequisites do not block " +
            "it."] }
        if name == "work_submit" { properties["evidence_manifest"] = ["type":"object",
            "description":"Immutable source, artifact or decision evidence. Optional measures record named upper budgets; they are advisory. Playtest tickets can " +
            "include a hashed playtest_bundle; its files join artifact_refs and bind to the exact build.","properties":["measures":EvidenceMeasure.schema,
            "playtest_bundle":PlaytestBundle.schema,"installed_build_id":["type":"string","minLength":1,"maxLength":4000]]] }
        if name == "batch_submit" { properties["members"] = ["type":"array","maxItems":200,"items":["type":"object",
            "properties":["acceptance_evidence":AcceptanceEvidence.schema]],
            "description":"Every active member supplies its own work_submit claim, acceptance_revision, evidence_manifest, direction_cursor and acceptance_evidence. " +
            "Any uncovered item refuses the entire batch before source copying or submission."] }
        if ["policy_apply","project_settings_save"].contains(name) { properties["policy"] = ["type":"object",
            "description":"The complete project policy (read policy_get first, change only what you need): routing_preset, allowed_providers (enabled qualified plugin " +
            "IDs from service_info), roles {coordinator, implementer, reviewer: {providers, preferred_provider, preferred_models}}, required_gates, " +
            "task_kind_overrides, review_batch_policy, lane_capacities, allow_human_decision_evidence, review_requirements, " +
            "agent_rule_changes (owner-only switch)."] }
        if name == "ticket_cleanup_receipts" {
            properties["section"] = ["type":"string","enum":["items","objects","source_build_cache"]]
            properties["limit"] = ["type":"integer","minimum":1,"maximum":50]
        }
        var required: [String] = []
        if !Self.readMethods.contains(name) { required.append("command_id") }
        if name == "policy_apply" && !c.isOwner { required.append("reason") }
        if name == "project_create" { required.append("name") }
        if !["service_info","project_list","assistant_projects","assistant_inbox","project_resolve","project_create"].contains(name) && !(c.isOwner && ["task_list",
            "task_context"].contains(name)) { required.append("project_id") }
        if name == "batch_claim" { required.append("policy_revision");properties["policy_revision"] = ["type":"integer","minimum":1,"maximum":Int.max,
            "description":"Required positive policy_revision returned by batch_prepare."] }
        if name == "epic_delete" { required += ["epic_id","expected_revision"] }
        if name == "task_create" { required += ["title","epic_id"];properties["epic_id"] = ["type":"string","minLength":1,"maxLength":4000,"pattern":"\\S",
            "description":"Required primary Epic in this project."] }
        if name == "batch_discard" { required += ["batch_id","expected_revision","reason"] }
        if name == "triage_transition" { required += ["expected_revision","expected_member_revisions"] }
        if name == "task_bulk_edit" { required += ["tasks","changes"];properties["changes"] = Self.ticketBulkChangesSchema;properties["tasks"] = Self.ticketBulkTasksSchema }
        if name == "task_bulk_undo" { required += ["tasks","original_command_id"];properties["tasks"] = Self.ticketBulkTasksSchema }
        if name == "message_delivery_list" { required += ["message_id"] }
        if name == "message_mentions_prepare" { required += ["task_id","body"] }
        var schema: JSON = ["type":"object","properties":properties,"required":required,"additionalProperties":false]
        if name == "triage_transition" {
            schema["allOf"] = [["oneOf":[["required":["triage_id"],"not":["required":["group_id"]]],["required":["group_id"],"not":["required":["triage_id"]]]]],
                ["oneOf":[["required":["target_status_id"],"not":["required":["action"]]],["required":["action"],"not":["required":["target_status_id"]]]]]]
        }
        return ["name":name,"description":description(name),"inputSchema":schema,"annotations":["readOnlyHint":Self.readMethods.contains(name),"idempotentHint":true,"openWorldHint":false]]
    }

    func validateInput(_ method: String,_ p: JSON,_ c: Caller) throws {
        if method == "task_get" { _ = try ownerCompletionEligibilityRequested(p,caller:c) }
        if method == "task_context", ["ui","ui_records","ui_history"].contains(p["detail_level"] as? String ?? "") || p["selected_context_cursor"] != nil {try owner(c)}
        if method == "task_list" { _ = try ticketView(p,c) }
        if method == "changes_wait" { _ = try ownerChangeCoverageRequested(p,c) }
        if method == "message_send" { _ = try explicitMessageRecipient(p); _ = try ticketAudience(p) }
        if c.isOwner { return }
        if method == "tool_catalog" { guard p.isEmpty else { throw CoreError("INVALID_INPUT","tool_catalog takes no arguments.") }; return }
        guard let tool = toolCatalog(c).first(where: {$0["name"] as? String == method}),let schema = tool["inputSchema"] as? JSON,let properties = schema["properties"] as? JSON else { throw CoreError("FORBIDDEN","This command is not available to this connection role.") }
        guard Set(p.keys).isSubset(of:Set(properties.keys)) else { throw CoreError("INVALID_INPUT","Unknown fields are not accepted by this command.") }
        for key in strings(schema,"required") where !(method == "task_create" && key == "epic_id") { guard p[key] != nil else { throw CoreError("INVALID_INPUT","\(key) is required.") } }
        for (key,value) in p {
            if method == "task_create",key == "epic_id",!(value is String) {continue} // Scoped EPIC_REQUIRED choices come from taskCreate.
            let spec = properties[key] as? JSON ?? [:]; let type = spec["type"] as? String ?? ""
            let valid: Bool
            switch type { case "string": valid = value is String; case "array":valid = value is [Any]; case "object":valid = value is JSON; case "boolean":valid = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false; case "integer":valid = (value as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.rounded() == $0.doubleValue } ?? false; default:valid = false }
            guard valid else { throw CoreError("INVALID_INPUT","\(key) has the wrong type.") }
            if let value = value as? String,value.utf8.count > int(spec,"maxLength",default:65536) { throw CoreError("INVALID_INPUT","\(key) exceeds its text limit.") }
            if let values = value as? [Any],values.count > int(spec,"maxItems",default:200) { throw CoreError("INVALID_INPUT","\(key) contains too many entries.") }
        }
        if method == "task_edit",let patch = p["patch"] as? JSON {
            guard Set(patch.keys).isSubset(of:["title","brief","acceptance","kind","readiness","priority","order","planned_assignee","assignment_reason","epic_id","tag_ids","starter_fields"]) else { throw CoreError("INVALID_INPUT","Task patches contain unsupported fields.") }
        }
    }
    func description(_ method: String) -> String {
        switch method {
        case "project_create":return "Create a project for this verified native conversation's actual unregistered workspace only. Omit root_path or use that same canonical folder. Commits worker enrollment/grant with the project; retry identical input with the same command_id to recover its receipt. Assistants cannot create projects."
        case "work_recover":return "Revoke a stopped attempt with explicit observation_refs and file_state_refs, action=confirm_stopped_revoke and reason. Name every unresolved source execution and its expected revision. Agent recovery is labeled as agent action; timeouts never prove a stop. Requires allowed agent_rule_changes."
        case "finding_waive","direction_waive":return "Record a reasoned waiver with caller provenance. Agent callers create agent waivers, never owner approvals. Requires allowed agent_rule_changes."
        case "project_icon_import":return "Import a PNG, JPEG or WebP up to 5 MiB from inside the caller's enrolled workspace. Requires current project revision and allowed agent_rule_changes."
        case "backup_create":return "Create a verified full-store backup in the published backups folder. Optional qualification_name selects a named subfolder there (letters, numbers, underscore, hyphen; at most 64 characters). No arbitrary destination. Requires allowed agent_rule_changes in this enrolled project and records agent provenance. Restore remains owner-only."
        case "diagnostics_summary":return "Read aggregate diagnostics for the selected project only. Contains no file destination or record content. Agent callers require allowed agent_rule_changes."
        case "ticket_cleanup_receipts":return "Read bounded project-scoped automatic cleanup summaries. Supply receipt_id and page items, objects or source_build_cache with section, cursor and limit. Removed pathname bytes are not measured physical disk savings."
        case "work_health_get":return "Read advisory work health, exact handler or the Triage orchestrator, substantive progress, separate liveness, known waits, correlated request/deadline, delivery and next check. Timeout changes no workflow authority."
        case "work_health_respond":return "Answer this exact request_id with current progress or a known wait and current task expected_revision. Rechecks session generation, current attempt/phase and material revisions. Late replies retain newer ownership and require ordinary fresh claim/handoff when authority changed. A reply is not substantive progress or a new claim."
        case "human_request_create":return "Create an owner input request with flat task_id, title, explanation, questions, file_requests, blocking (Boolean), command, target_attachment_id, review_request_id and target_manifest_id fields. No request_spec wrapper. Questions require id and prompt; type=text|choice|approval|check (default text), required (default true), multiple, allow_custom, options=[{id,label}] for choice, optional command. Files require id and prompt; kind (or selection)=file|directory|either. At least one question or file, at most 30 each. command={text,working_directory,expected_result,reason?} describes instructions, never executes them. Exact human gate binding requires one approval question and its managed attachment target. Earlier answered approvals on this ticket or normalized title/question matches in this project refuse with COVERED_BY_EARLIER_ANSWER and matching answers. Continue only with supersedes_answer_id naming a matched answer/request and supersede_reason explaining what changed."
        case "human_request_revise":return "Revise a pending owner request with request_id, expected_revision, a non-empty patch and optional reason. patch accepts title, explanation, questions, file_requests, blocking, command, target_attachment_id, review_request_id and target_manifest_id, using the same form types as human_request_create. Preserve old form history and atomically validate/rebind any exact human gate. There is no human_request_edit or request_spec wrapper."
        case "task_bulk_edit":return "Preview or atomically apply one permitted change to up to 200 revision-checked tickets. Preview defaults true and reports every blocked row; apply (preview=false) changes nothing if any row conflicts. Retry an explicitly selected eligible subset with a new command ID. Status cancel/reopen require changes.reason (up to 4,000 bytes), recorded on every ticket. Status actions keep Triage membership; Done or cancel removes the ticket from its Triage. The returned command receipt supports guarded bulk Undo."
        case "task_bulk_undo":return "Preview or atomically compensate a bulk edit from this connection's original_command_id and current ticket revisions. Undo preserves newer field changes and refuses advanced ownership/review or active claims. Status compensation records a reason naming the original command, plus optional reason (combined limit 4,000 bytes). It adds history, never restores claims or cleaned files. Receipts expire under normal command-journal retention."
        case "service_info":return "Read this build's supported capabilities and current authenticated session. Native push is separately qualified."
        case "agent_resolve":return "Resolve an exact named agent in the enrolled project; duplicate names require disambiguation."
        case "agent_message_send":return "Save a message to a freshly resolved opaque recipient target. Stored pickup is not model acknowledgment."
        case "message_delivery_list":return "Read current delivery metadata for one ticket note with project_id, task_id and message_id, or one ticket-free Triage note with triage_id and message_id. Each delivery shows recipient_role (handler, registered_child, triage_orchestrator) and its copy label. Available to the sender, current handler and any agent with project read scope. Returns exact delivery/recipient/generation, state, push state, timestamps and native_closure_ref when fenced; no note bodies, inbox contents or credentials. No recipient yet returns saved_for_pickup with no invented delivery."
        case "message_ack":return "Record this exact recipient's explicit acknowledgment, optionally with one reaction: thumbs_up (seen, no reply needed), thumbs_down (no), done, looking or question. Reading an inbox is not acknowledgment; a reaction never addresses a direction or completes a ticket."
        case "message_mentions_prepare":return "Parse and resolve ordinary ticket-note tags in project scope. Ambiguity requires exact selection; a prepared token binds this body and current recipients, and sends nothing. Pickup is not acknowledgment."
        case "message_send":return "Cite tickets, Triages and Epics as KEY \"Title\" (their name for groups), with project name when needed. Keep stable IDs in tool arguments. Optional triage_id or epic_id names the note subject; triage_id with no task_id is a Triage note to that Triage's orchestrator or an exact recipient. Omit recipient to reach the ticket holder (with its accepted subagents) and the Triage orchestrator, one copy each and none for you; audience=holder|orchestrator narrows an ordinary note. Save a scoped ticket/project coordination note with honest delivery receipts. Routine coordination between actual involved Checklist sessions has standing authorization; no per-message human permission is needed within their existing project/task/Triage grants. Omit recipient for current handlers/pickup, or use exactly recipient={\"kind\":\"session\",\"session_id\":\"<verified scoped session>\"}. Malformed explicit routes are rejected. Inspect returned deliveries for the intended recipient; saved/queued is not acknowledgment and grants no work role or new access."
        case "task_create":return "Capture a ticket with title and required primary epic_id in Queued status with Draft readiness. Choose an existing Epic or create one for this concrete ticket first. Draft means the brief still needs refinement. When the brief states a concrete outcome (acceptance items help), mark it Ready with task_edit patch readiness=ready; open prerequisites do not prevent Ready. Assistant captures never assign work."
        case "task_edit":return "Edit ticket fields (see patch). Metadata edits, including readiness, keep Triage membership. Draft = needs refinement; Ready = refined. Prerequisites never block Ready; they gate claim, pickup and completion. A superseded duplicate cannot become Ready."
        case "task_transition":return "Individually mark a ticket's status, including its current status. Triage membership stays; Done or Canceled removes the ticket from its Triage. Notes and metadata edits never change membership. Queue works while prerequisites are open. Cancel and reopen require a reason; active work needs work_release, work_takeover or verified-stop recovery first. Reopen returns to Queued. Protected work/review/Done states require their real workflow commands."
        case "task_purge_preview":return "Owner-only current impact preview for a trashed ticket. Lists removed records, exclusive bytes queued for deletion, retained byte reasons and known backup observations. Existing backups and exports are never changed."
        case "task_purge":return "Permanently remove a trashed ticket through the trusted owner app channel only, with expected_revision and preview_digest from its current purge preview. Keeps a minimal ticket reference and shared records. Active work and pending owner requests refuse. Queues exclusive managed originals, previews and captured source for durable post-commit deletion with a receipt. Shared, held, external, workspace and backup-referenced bytes stay. Existing backups/exports stay unchanged."
        case "task_archive":return "Archive, unarchive, trash or restore one ticket (action). Agents may do this unless the owner limited the project to app-only changes. Active work, children and verification must be released or recovered after a verified stop first. undo=true unarchive refuses after original cleanup. Archive cleanup of managed files stays an app action."
        case "policy_apply":return "Change this project's rules (who may coordinate, implement and review; gates; batch policy; lanes; review requirements). Agents may apply rule changes unless the owner set agent_rule_changes=owner_only; send the complete policy from policy_get with your change and a reason. The change is recorded with agent provenance. Only the owner can change agent_rule_changes itself. Removing a provider revokes its active claims' service authority. An agent that holds active work in this project can apply changes only with mode=future_attempts, so it never revises its own active contract."
        case "policy_propose":return "Validate a complete policy and save a proposal with its preview and digest. Agents normally use policy_apply directly; a proposal is useful when a change should be reviewed first."
        case "project_settings_save":return "Save project settings atomically: name, key prefix, icon, accent, brief, pinned decisions, default view, alert override, capture defaults and, optionally, the policy. An agent that changes the policy must include reason. Agents may save settings unless the owner limited the project to app-only changes. Agent brief or decision changes notify active tickets with an agent note, not an owner direction."
        case "project_edit":return "Edit project fields (same fields as project_settings_save without policy). Agents may edit unless the owner limited the project to app-only changes. Only the owner moves the workspace root, because it sets which files agents may change."
        case "project_archive":return "Archive (archived=true) or restore (archived=false) this project. Agents may do this unless the owner limited the project to app-only changes."
        case "status_create","status_edit":return "Create or edit a project status: name, color, category (queued, active, review, blocked, parked, done, canceled) and sort_order. Agents may change statuses unless the owner limited the project to app-only changes."
        case "status_retire":return "Retire a status. Tickets that use it must move first, or supply remap_target_status_id (same category) with expected_task_revisions for every affected ticket."
        case "tag_create","tag_edit","tag_retire":return "Create, edit or retire a project tag (name, color, sort_order). Agents may change tags unless the owner limited the project to app-only changes."
        case "review_batch_inputs":return "Read the review-ready members of one Triage: triage_id/key/name/revision, phase review, tasks with current task_id/key/expected_revision, exact review_request_id/target_manifest_id/gate and recorded contributor_session_ids, plus not_ready reasons. Select the oldest ready request per ticket; explain additional requests in not_ready. Pass tasks unchanged and triage_revision as batch_prepare.expected_revision; optional file_scopes/lane_scopes default empty. This read grants no work authority."
        case "batch_prepare":return "Freeze an exact set of current Triage members (1 to 200) for one phase: tasks=[{task_id, expected_revision, file_scopes:[{path, access:\"write\"|\"read\"}], lane_scopes}]. Preparation runs every member's real claim checks (readiness, prerequisites, policy, scope conflicts) and then rolls them back. Only original top-level Implementation members in one frozen batch held by the exact same principal/session/generation/domain/incarnation may share frozen canonical writes. Review and lane rules remain unchanged; every outside attempt sees the retained active write union. Review entries also require review_request_id, target_manifest_id and gate; review_batch_inputs returns ready entries unchanged, with optional key (must match) and informational contributor_session_ids. File/lane scopes default empty. Stored contributor independence still applies. A batch keeps its own phase and guards; a Triage has no phase. Claim the result with batch_claim."
        case "triage_transition":return "Atomically apply one status to EVERY current Triage member using exact group and per-ticket revisions. A Triage has no phase, so members in any status are accepted. Status changes keep membership; Done uses each ticket's actual completion gates, and Done or Cancel removes the ticket from the Triage. Any blocker rejects the entire action. Empty and already-uniform ordinary selections are truthful no-ops."
        case "batch_claim":return "Atomically claim the complete prepared frozen set. Supply the required positive integer policy_revision returned by batch_prepare. Missing or malformed values return INVALID_INPUT; a corrected request can reuse the same still-valid preparation with a new command_id. For unknown-outcome retries, retain the original command_id and identical input. Ordinary grouped claims retain current Triage membership; exact revisions, authority, reservations and review independence still apply. Membership moves as for work_claim: the orchestrator's batch claim moves each ticket into its Triage, and an individual work_claim also keeps a ticket in its orchestrated Triage, so a batch claim is not needed to keep work grouped. Same-holder original Implementation attempts may share only frozen member writes; other batches/sessions, children and transfers gain no exemption. Discarded preparations return BATCH_DISCARDED; prepare afresh."
        case "batch_discard":return "Discard a never-claimed preparation with its exact expected_revision and a nonblank reason. Eligible scoped workers or the owner may do this planning action. Retains the frozen snapshot/digest and an audited disposition; changes no tickets, membership, orchestration or claims. Refuses any batch ever claimed, even after full release/completion. Discarded preparations remain visible with lifecycle and reason and cannot be claimed (BATCH_DISCARDED); prepare afresh. No timed expiry."
        case "batch_release":return "Atomically release selected live claims of this exact frozen batch with a required non-empty reason and optional final_report. Retain every current Triage membership; unselected claims remain unchanged. Implementation returns to Queued; review stays in Review and returns its request to eligible reviewers."
        case "batch_submit":return "Atomically submit every remaining live implementation claim of this exact frozen batch once each, with its own claim, acceptance_revision, evidence_manifest, direction_cursor and acceptance_evidence map. Released members are omitted. Every acceptance item needs evidence or a limitation; installed/native items need a non-contributor check-runner report bound to installed_build_id. Uncovered items refuse all members before source capture. Phase completion removes handled tickets from current Triages."
        case "batch_review_record":return "Atomically continue every remaining live review claim of this exact frozen batch once each with ordinary gates. Released members are omitted. Each verdict closes review and moves Triage membership as review_record does: implementation-side returns (evidence_missing, not_run, blocked_on=implementation) and reject move the ticket back to its return Triage while that Triage has an orchestrator, and the return notice reaches the holder and that orchestrator; reviewer-side blocked keeps membership; Done removes the ticket from its Triage."
        case "work_claim":return "For an automatically returned implementation claim, the exact original holder calls this at the current revision without scopes to pick up a fresh token; other sessions cannot pick it up. Atomically claim one Ready task or exact independent review request. Any eligible AI may claim an unclaimed ticket; an agent planned assignee is only a preference. The claim moves the ticket to Active (implementation) or keeps it in Review (review). To replace a current holder, use work_takeover. A claim refuses with DEPENDENCY_UNSATISFIED while a required prerequisite is not Done; check prerequisite_blockers and pickup_eligible first. Coordinator default: keep at most10 distinct implementation tickets in flight through review/rework until Done or explicit deferral/release; finish an inherited cohort before new pickup. Review finished implementations and complete passing tickets independently before replacements. Explicit project workflow may override this guidance; it is not a server-enforced claim or reviewer-subagent limit. A separate non-contributor reviewer subagent may share the native host/provider; the author and recorded prior/delegated contributor identities cannot review their own work. A ticket is in at most one Triage. When you orchestrate a Triage, your claim moves the ticket into it (from a plan or another orchestrator's Triage); a claim by a session that orchestrates no Triage keeps the ticket in an orchestrated Triage and removes it only from a plan."
        case "review_record":return "Record pass, reject, blocked, evidence_missing or not_run for your exact review claim. On a playtest bundle, pass/reject must supply review_assessment with pass or fail per acceptance item. Optional retain_cited_files=true marks only cited bundle files Keep original; other files follow normal archive policy and existing holds. Every verdict ends your review claim. Reject returns the ticket to Queued for rework. evidence_missing (with reason), not_run (with check and reason), and blocked with blocked_on=implementation (with reason) close the old review and return to the eligible implementing session as Active, or Queued if unavailable. The holder calls work_claim without scopes at the current revision to pick up its fresh token, then submits a fresh target. blocked_on=reviewer (the default) keeps Review and queues the same request for any eligible reviewer. not_run is not a fail. Neither satisfies a gate, and neither records findings. Findings default to severity blocking; severity advice stays visible and does not block completion, and a pass may add only advice. same_cause_as links a finding to an earlier finding of this ticket. A failed check may carry failure_cause defect, environment or other_ticket (with cause_task_id). final_report stores your report on the attempt. When the project policy enables release_set_holds, a pass may name release_set and hold_reason: the ticket waits, accepted, until release_set_complete. A pass on the last open required gate marks the ticket Done when every completion check holds (no open findings, owner directions, blocking human requests or prerequisites); the result's completion says completed or what it waits for, so do not call task_complete after it. Status changes keep Triage membership: a verdict that returns work (reject, evidence_missing, not_run, blocked_on=implementation) moves the ticket back to its return Triage while that Triage has an orchestrator, and its notice reaches the holder and that orchestrator; Done removes the ticket from its Triage."
        case "work_takeover":return "Take over a ticket that another session has claimed, without its permission: task_id, the task's expected_revision, a reason and optional file_scopes/lane_scopes (default: the earlier scopes). You need the same eligibility as a claim in that phase (review keeps contributor independence; owner-assigned tickets stay with the owner). The earlier claim and its delegated children end at once, and each earlier holder receives a note with you as the new holder and your reason. Returns your attempt and claim_token. Refused while a service-run source execution is active."
        case "review_prepare":return "Prepare a fresh independent reviewer composer or honest copy instruction for the exact current target. No model, native conversation, connection or claim is started."
        case "codex_thread_start":return "Start a visible ticket conversation in the owner's Codex app through your own Codex host tool codex_app.create_thread, without the owner pressing Send (owner direction, 22 October 2026). Without host_outcome, returns the scoped prompt (host_request) and the composer fallback; nothing starts. After the host call, call again with host_outcome created and the host-returned thread_id, or unavailable, refused or failed with host_detail. Records that exact outcome on the ticket. The new thread attaches itself through connect --task; this command never claims, assigns or attaches, and never starts a model, app-server or CLI runtime. On any outcome other than created, use the returned fallback: the owner presses Send in the prepared composer."
        case "review_context":return "Read the exact target, source_relevance (whole or scoped read/write and additional paths plus project instructions), per-item acceptance_evidence map, current acceptance and project review requirements for a fresh non-contributor review. Reviewer-chosen hashed artifacts support the assessment; no service test receipt is required. After rework, carry input-valid passing acceptance/check cases with original provenance and report them separately from new execution. Run only failed, inconclusive or materially affected cases; fixture-only repairs do not require an all-green suite. Before broader checks, name invalidating case inputs or cite an applicable explicit effective project workflow/context instruction; Triage membership or sibling failure is no override. Fresh target-bound gates and a current reviewer-owned assessment remain required."
        case "source_review_execute":return "Unavailable: service execution of submitted code is disabled without a qualified sandbox. Reviewers choose checks in their own sessions and attach hashed evidence."
        case "task_complete":return "Complete a ticket only after its current immutable target and all pinned gates pass. A passing review on the last open gate already marks the ticket Done; use this command when a later change (for example a resolved finding or a Done prerequisite) makes completion possible. Done always removes the ticket from its Triage."
        case "triage_orchestrate":return "Start, checkpoint, finish or take over the orchestration of a Triage by the actual connected Codex or Claude conversation. start without triage_id creates the caller's Triage (optional name; default \"<Provider> · <short session id>\"); start with a plan (a Triage with no orchestrator) makes the caller its orchestrator. One conversation orchestrates at most one Triage per project: a second start or takeover returns TRIAGE_ORCHESTRATOR_CONFLICT. The orchestrator's own work_claim, batch_claim, review claim, work_takeover and handoff acceptance move a ticket into its Triage. A claim by a session that orchestrates no Triage keeps the ticket in an orchestrated Triage and removes it only from a plan; a claim by another orchestrator moves the ticket into that orchestrator's Triage. start, takeover and checkpoint deliver the saved notes of this Triage and its tickets to the orchestrator, each once and at most 50 per call (saved_notes_delivered, saved_note_delivery_has_more); while saved_note_delivery_has_more is true, checkpoint again to receive the next ones. finish ends orchestration with a reason: a Triage with tickets becomes a plan, and an empty Triage archives with its history kept. A verified resumed conversation can finish its own earlier record with a reason. Takeover requires a reason and coordinator eligibility, ends the prior orchestration with history and a notice, and keeps every member and claim. Identity comes from the authenticated caller, never a supplied name/session ID. No model is launched."
        case "triage_create":return "Create a Triage: the work list of one orchestrator conversation, with 0 or more tickets. A Triage has no phase; each ticket's status gives its phase, and a phase input is ignored. A Triage with no orchestrator is a plan (for example \"Pass 5\"); write the member order in purpose, prerequisites first. A ticket is in at most one Triage. An orchestrating conversation usually creates its own Triage with triage_orchestrate start. A plan that loses its last ticket archives automatically."
        case "epic_delete":return "Delete a mistaken active or archived Epic only if it never held a ticket and has no references. Requires epic_id, expected_revision and allowed agent_rule_changes. Removes its own events, retaining one project-level deletion entry with agent provenance. Refuses current/historical membership, unproved legacy history, references, stale revision or denied authority. Read epic_list first."
        case "epic_list":return "List project Epics with stable IDs, key and name; optional key is exact and case-insensitive, with ambiguity refused. Cite KEY \"Name\" in reports; use IDs in tool arguments."
        case "epic_create","epic_edit","triage_edit":return "Create or edit a project group. The service assigns immutable Epic PREFIX-E<n> and Triage PREFIX-T<n> keys from separate project counters. Results include key and name. Cite KEY \"Name\" in notes and reports; use IDs in tool arguments."
        case "session_inbox":return "Read current recipient deliveries and messages, each with subject {kind,id,key,title,project_id,project_name}. Cite KEY \"Title\" in notes, checkpoints, final reports and messages; IDs remain tool arguments."
        case "task_list":return "List project tickets. Optional triage_id selects current Triage members; epic_id selects a primary Epic; keys selects exact case-insensitive ticket keys (at most 200, empty selects none). Filters combine with AND and text, status_ids and archived before paging. Optional fields returns only named top-level row fields plus id, key and revision; empty fields returns all. Unknown fields refuse with INVALID_INPUT and sorted valid names. Page metadata stays outside rows. Owner view defaults remain unchanged."
        case "triage_list":return "Optional triage_id selects exactly one scoped Triage. Optional fields returns only named top-level row fields plus id, key and revision; empty fields returns all. Unknown fields refuse with INVALID_INPUT and sorted valid names. Returns key and name. Optional key is exact and case-insensitive; ambiguous keys are refused. Cite KEY \"Name\" in reports; use IDs for tool arguments. Read each Triage's orchestrator (null for a plan), plan state, member_counts_by_status, current members, derived member status and phase (a history label on older Triages only). Active attention includes work in progress or membership in an actively orchestrated Triage."
        case "group_membership":return "Explicitly add, update, remove or move project-scoped membership: action=add|remove with group_id, task_id and the group's expected_revision (each add raises it by one, so add members one call at a time per group). A Triage accepts tickets in any status and has no phase. A ticket is in at most one Triage, so an add moves it: from a plan, or from an orchestrated Triage when the caller orchestrates one of the two Triages or is the owner. Only the orchestrator or the owner adds tickets to a Triage that has an orchestrator (TRIAGE_ORCHESTRATED); any eligible agent edits plans. Status changes keep membership; a ticket leaves when Done or canceled, when another orchestrator handles it, or when removed. A plan that empties archives with its history kept. Epics persist as subprojects."
        case "work_checkpoint":return "Cite ticket and group references as KEY \"Title\" in progress and final_report, with IDs only for tool arguments. Record progress on your active claim. waiting_for_resource names a shared resource (for example an engine lock or a build queue) that the work waits for; the ticket shows the wait, and waiting time does not count as a quiet claim. A checkpoint without it ends the wait. No retry, schedule or model launch is added."
        case "review_evidence_add":return "Create your own managed, hashed title/body report on the exact active review attempt and target. Optional measures=[{name,unit,limit,before,after}] use finite numbers and upper limits. The report bytes include these measures; warnings are advisory and never pass or fail a gate."
        case "work_submit":return "Submit your implementation claim with target-appropriate immutable evidence and acceptance_evidence: one 0-based item entry per acceptance item, each with evidence_refs or a stated limitation. Installed/native observations require a non-contributor check_runner_report attachment for evidence_manifest.installed_build_id; owner observations keep the trusted app path. Uncovered items refuse submission before source capture. Source captures with file scopes stale only for read/write scopes, additional paths and project instruction changes; unscoped and legacy captures retain whole-project staleness; optional evidence_manifest.measures records named upper budgets. A Playtest can supply evidence_manifest.playtest_bundle with exact hashed build, scenario, state_files, screenshots and log references; all join the existing artifact_refs. New builds require newly attached run evidence; the ticket moves to Review with one review request per required gate. Optional final_report stores your final report on this attempt (agent text, shown on the ticket). Submission keeps the ticket in its implementing Triage and records that Triage as its return Triage."
        case "work_release":return "Release your claim with a reason and optional continuation; the ticket returns to Queued (a review claim returns its request). Optional final_report stores your final report on this attempt. The ticket keeps its Triage membership."
        case "review_request":return "Queue an independent review of the task's current target for one required gate. To start another round on the same target, name supersedes_request_id and a reason. Only a retained legacy evidence_requested request can take supplemental_evidence_refs ({artifact_id, sha256}) on the unchanged target. New evidence_missing verdicts return to implementation and require work_submit with a fresh target. A review request keeps the ticket's Triage membership, also for a new target or another round; a ticket leaves its Triage only when Done or canceled, when another orchestrator handles it, or when removed."
        case "review_draft_save":return "Save a draft verdict on your own active review claim before you must stop (for example at a tool limit). Same input as review_record; the complete verdict is validated as a dry run and nothing else changes. The claim stays active, and a new save replaces the draft. The coordinator can submit it with review_draft_submit; the verdict then names you as its reviewer."
        case "review_draft_submit":return "Submit the saved draft verdict of another session's active review claim: task_id, attempt_id, your direction_cursor and optional expected_revision (of the attempt). Only the owner or the session that orchestrates an active Triage holding the ticket can submit. The target, review contract and the draft reviewer's independence are checked again. The verdict names the draft's reviewer as its author and you as submitted_by; you never become the reviewer. The verdict moves Triage membership as review_record does."
        case "finding_severity_set":return "Change an open finding's severity between blocking and advice (older severities count as blocking) with a reason. Allowed for the finding's reviewer, the current reviewer of its gate, or the owner. The change and its reason stay in the finding's severity_history."
        case "release_set_complete":return "Complete every ticket held for one release set (a passing verdict named it under the release_set_holds policy). Each ticket passes its normal fresh completion checks; the set completes together or not at all, and a refusal names each ticket that is not ready. Optional expected_task_revisions maps task IDs to revisions."
        default:return method.replacingOccurrences(of:"_",with:" ").capitalized + " in the authenticated project scope."
        }
    }
    func pendingNativeDeliveries(_ db: Database, _ p: JSON) throws -> JSON {
        let includeAcknowledged = bool(p,"include_acknowledged")
        let nativeSessions: [String]?
        if let value = p["native_session_ids"] {
            guard let ids = value as? [String],ids.count <= 4096,
                  ids.allSatisfy({!$0.isEmpty && $0.utf8.count <= 4000}),!includeAcknowledged else {
                throw CoreError("INVALID_INPUT","Native dispatch needs bounded exact session IDs, without acknowledged history.")
            }
            nativeSessions = ids
        } else {nativeSessions = nil}
        // Native dispatch can reach only current enrolled endpoints. Narrow its
        // read before expanding retained messages/tickets. General pending/history
        // reads keep their previous scope. This is not a grant or cached verdict.
        let nativeSelection = try nativeSessions.map {try jsonString($0)}
        let nativeCandidates = bool(p,"native_dispatch_candidates")
        guard !nativeCandidates || nativeSessions != nil else {throw CoreError("INVALID_INPUT","Native candidates require exact session selection.")}
        let deliveries = try readSnapshotCache.records(db,key:["pending-deliveries",includeAcknowledged ? "all":"open",nativeSelection,nativeCandidates ? "candidates":"pending"]) {
            var sql = "SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type='delivery'"
            var arguments = StatementArguments()
            if !includeAcknowledged {
                sql += " AND CASE WHEN json_valid(data) THEN COALESCE(json_extract(data,'$.state') NOT IN ('acknowledged','addressed'),1) ELSE 1 END"
            }
            if let nativeSelection {
                // Bind bytes to preserve NUL and Unicode identity. Every duplicate
                // recipient key is considered; canonical/session checks still run.
                sql += " AND CASE WHEN json_valid(data) THEN EXISTS (SELECT 1 FROM json_each(records.data) recipient JOIN json_each(CAST(? AS TEXT)) selected ON " +
                    "CAST(recipient.value AS BLOB)=CAST(selected.value AS BLOB) WHERE recipient.key='recipient_session_id' AND recipient.type='text') ELSE 1 END"
                arguments += [Data(nativeSelection.utf8)]
            }
            if nativeCandidates {
                sql += " AND CASE WHEN json_valid(data) THEN EXISTS (SELECT 1 FROM json_each(records.data) WHERE key='push_state' AND type='text' AND CAST(value AS " +
                    "BLOB)=CAST('unavailable' AS BLOB)) ELSE 1 END"
            }
            return try Row.fetchAll(db,sql:sql + " ORDER BY rowid",arguments:arguments)
        }
        let selectedSessions = nativeSessions.map {Set($0.map {Data($0.utf8)})}
        let eligible = try deliveries.filter { d in
            if nativeCandidates && d["push_state"] as? String != "unavailable" {return false}
            if let selectedSessions,let sid = d["recipient_session_id"] as? String,!selectedSessions.contains(Data(sid.utf8)) {return false}
            if bool(p,"include_acknowledged") { return true }; let session = try record(db,(try StoredRecord(d, family: "delivery").string("recipient_session_id")),type:"session");
                return canReceive(session,project:(try StoredRecord(d, family: "delivery").string("project_id"))) && d["recipient_authorization_generation"] as? String == sessionGeneration(session) }
        return ["deliveries":try eligible.map { d -> JSON in var d = d; var message = try record(db,(try StoredRecord(d, family: "delivery").string("message_id")),type:"message");
            let subject = try subject(db,message:message);message["subject"] = subject;d["subject"] = subject
            if let tid = message["task_id"] as? String { d["ticket"] = try scoped(db,tid,(try StoredRecord(message, family: "message").string("project_id")),type:"task") }
            d["message"] = message; d["session"] = try record(db,(try StoredRecord(d, family: "delivery").string("recipient_session_id")),type:"session"); return d }]
    }

    func bridge(_ db: Database,_ p: JSON,_ c: Caller,_ method: String) throws -> JSON {
        try owner(c); guard c.installation == "native-bridge" else { throw CoreError("FORBIDDEN","This command is reserved for the bundled delivery service.") }
        if method == "delivery_pending" { return try pendingNativeDeliveries(db,p) }
        if method == "delivery_record" {
            var d = try record(db,try text(p,"delivery_id"),type:"delivery")
            let state = try text(p,"state"); if state == "uncertain",!(try deliveryCurrent(db,d)) { throw CoreError("RECIPIENT_CHANGED",
                "The recipient authorization changed before native submission.") }; guard ["transport_written","held","failed","uncertain","provider_accepted",
                "unavailable"].contains(state) else { throw CoreError("INVALID_INPUT","A bridge cannot fabricate recipient acknowledgment.") }
            // Actual transport evidence is retained independently from recipient acknowledgment.
            d["push_state"] = state; d["transport_receipt"] = p["receipt"] ?? [:]
            if !["acknowledged","addressed"].contains(d["state"] as? String ?? "") { d["state"] = ["held":"held_for_approval","failed":"unavailable",
                "uncertain":"delivery_uncertain","provider_accepted":"provider_accepted","unavailable":"unavailable"][state] ?? "queued" }
            d = revised(d); try save(db,d,type:"delivery"); try event(db,caller:c,project:d["project_id"] as? String,entity:d["message_id"] as? String,kind:"delivery_recorded",
                data:["state":state]); return d
        }
        let pid = try text(p,"project_id"); var original = try scoped(db,try text(p,"reply_to"),pid,type:"message"); let sid = try text(p,"recipient_session_id");
            let session = try scoped(db,sid,pid,type:"session")
        guard try records(db,type:"delivery",
            project:pid).contains(where: {
                $0["message_id"] as? String == original["id"] as? String && $0["recipient_session_id"] as? String == sid &&
                $0["recipient_authorization_generation"] as? String == sessionGeneration(session)
            }) else { throw CoreError("FORBIDDEN","The native reply does not match this recipient delivery.") }
        guard original["reply_recipient_authorization_generation"] as? String == sessionGeneration(session),bool(original,"reply_allowed"),!bool(original,"reply_used"),
            original["reply_recipient_session_id"] as? String == sid,canReceive(session,project:pid) else { throw CoreError("FORBIDDEN",
            "This exact native reply allowance is absent, used or revoked.") }
        if session["role"] as? String == "assistant",(session["assistant_grants"] as? [String:[String:Bool]])?[pid]?["post_notes_on_request"] != true { throw CoreError("FORBIDDEN",
            "This assistant's current grant does not permit requested replies.") }
        guard providerPlugins.plugin(session["provider"] as? String ?? "", requiring: .nativePeer) != nil else {
            throw CoreError("ADAPTER_UNAVAILABLE",
                "This provider has no enabled qualified native reply adapter. The saved note and reply allowance remain available for recovery or authenticated pickup.")
        }
        original["reply_used"] = true; try save(db,revised(original),type:"message")
        for var delivery in try records(db,type:"delivery",
            project:pid) where delivery["message_id"] as? String == original["id"] as? String && delivery["recipient_session_id"] as? String == sid {
            delivery["state"] = "acknowledged"; delivery["acknowledged_at"] = now(); delivery["acknowledgment_evidence"] = p["source_evidence"] ?? [:]; try save(db,revised(delivery),type:"delivery") }
        var reply: JSON = ["id":uuid(),"project_id":pid,"body":try text(p,"body"),"origin":"agent","kind":"reply","author":"native:"+sid,"author_session_id":sid,
            "author_display":session["label"] ?? "Native agent","reply_to":original["id"]!,"source_evidence":p["source_evidence"] ?? [:],
            "verification_source":"same_user_native_peer","revision":1,"created_at":now()]
        for key in ["task_id","conversation_id","triage_id","epic_id"] { if let value = original[key] { reply[key] = value } }
        try save(db,reply,type:"message"); if let health = try reconcileHealthReply(db,reply:reply,caller:c) { reply["health_reconciliation"] = health }; try event(db,caller:c,
            project:pid,entity:original["task_id"] as? String ?? original["conversation_id"] as? String,kind:"native_reply_received",data:["reply_id":reply["id"]!]); return reply
    }
}
