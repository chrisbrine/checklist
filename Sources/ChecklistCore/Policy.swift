import ChecklistDomain
import Foundation
import ChecklistProviders
import GRDB

extension CommandRouter {
    static let policyKinds = TicketKind.wireValues
    static let policyRoles = WorkflowRole.wireValues
    static let policyGates = ["review", "human_approval"]
    static let passingReviewDefault = "complete_passing_independently"
    /// Owner decision 2026-10-18: AI agents edit project rules by default; the owner can limit a project to app-only changes.
    static let ruleChangeModes = ["allowed", "owner_only"]

    func effectiveReviewBatchPolicy(_ policy: JSON) -> String {
        policy["review_batch_policy"] as? String ?? Self.passingReviewDefault
    }

    /// Preferences explain selection; they never launch a model or confer session grants.
    func effectivePolicy(_ raw: JSON, kind: String) -> JSON {
        var policy = raw
        let preset = raw["routing_preset"] as? String ?? "shared"
        let allowed = raw["allowed_providers"] as? [String] ?? providerPlugins.workProviders
        var roles: JSON = [:]
        for role in Self.policyRoles {
            let selected = ProviderPolicyDefaults.providers(role:role,preset:preset,allowed:allowed)
            roles[role] = ["providers":selected, "preferred_provider":selected.first.map { $0 as Any } ?? NSNull(), "preferred_models":[]] as JSON
        }
        for (key, value) in raw["roles"] as? JSON ?? [:] { roles[key] = value }
        policy["routing_preset"] = preset; policy["allowed_providers"] = allowed
        policy["required_gates"] = raw["required_gates"] ?? ["review"]
        policy["review_batch_policy"] = effectiveReviewBatchPolicy(raw)
        policy["task_kind_overrides"] = raw["task_kind_overrides"] ?? []
        policy["allow_human_decision_evidence"] = raw["allow_human_decision_evidence"] ?? false
        policy["agent_rule_changes"] = raw["agent_rule_changes"] ?? "allowed"
        // CL-45: release-set holds are an explicit project override; without it passing tickets complete independently.
        policy["release_set_holds"] = raw["release_set_holds"] ?? false
        if let override = (raw["task_kind_overrides"] as? [JSON] ?? []).first(where: { $0["kind"] as? String == kind }) {
            for (key, value) in override["roles"] as? JSON ?? [:] { roles[key] = value }
            if let gates = override["required_gates"] { policy["required_gates"] = gates }
            if let decision = override["allow_human_decision_evidence"] { policy["allow_human_decision_evidence"] = decision }
        }
        policy["roles"] = roles
        return policy
    }

    func normalizedPolicy(_ input: JSON) throws -> JSON {
        let keys: Set<String> = ["routing_preset", "allowed_providers", "roles", "required_gates", "task_kind_overrides", "review_batch_policy", "lane_capacities", "assistant_relay_grants", "coordinator_session_id", "allow_human_decision_evidence", "review_requirements", "agent_rule_changes", "release_set_holds"]
        guard Set(input.keys).isSubset(of: keys) else { throw CoreError("INVALID_INPUT", "Policy contains unsupported settings.") }
        if let mode = input["agent_rule_changes"] { guard let mode = mode as? String, Self.ruleChangeModes.contains(mode) else { throw CoreError("INVALID_INPUT", "agent_rule_changes is allowed or owner_only.") } }
        if let preset = input["routing_preset"] { guard let preset = preset as? String, ProviderPolicyDefaults.presets.contains(preset) else { throw CoreError("INVALID_INPUT", "Choose a supported routing preset.") } }
        if let batch = input["review_batch_policy"] { guard let batch = batch as? String, [Self.passingReviewDefault, "hold_passing_for_batch"].contains(batch) else { throw CoreError("INVALID_INPUT", "Choose independent completion or an explicit batch hold.") } }
        if let raw = input["release_set_holds"] { guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw CoreError("INVALID_INPUT", "release_set_holds must be explicitly enabled with a boolean.") } }
        if input["coordinator_session_id"] != nil { _ = try text(input,"coordinator_session_id",max:200) }
        if let raw = input["allow_human_decision_evidence"] { guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw CoreError("INVALID_INPUT", "Human decision evidence must be explicitly enabled with a boolean.") } }
        var result = effectivePolicy(input, kind: "")
        result["review_requirements"] = try canonicalReviewRequirements(input["review_requirements"])
        let allowed = strings(result,"allowed_providers")
        guard !allowed.isEmpty, allowed.count <= 128, Set(allowed).count == allowed.count, Set(allowed).isSubset(of: Set(providerPlugins.workProviders)) else { throw CoreError("INVALID_INPUT", "Only enabled, compatible and qualified work-provider plugins can participate.") }
        if input["allowed_providers"] != nil, input["allowed_providers"] as? [String] == nil { throw CoreError("INVALID_INPUT", "allowed_providers must be an array.") }
        func gates(_ value: Any?) throws -> [String] {
            guard let values = value as? [String], values.count <= Self.policyGates.count, Set(values).count == values.count, Set(values).isSubset(of: Set(Self.policyGates)) else { throw CoreError("INVALID_INPUT", "This build supports review and human_approval gates.") }
            return values
        }
        func roleRules(_ value: Any?, partial: Bool) throws -> JSON {
            guard let rules = value as? JSON, Set(rules.keys).isSubset(of: Set(Self.policyRoles)), partial || Set(rules.keys) == Set(Self.policyRoles) else { throw CoreError("INVALID_INPUT", "Use coordinator, implementer and reviewer role rules.") }
            for (_, rawRule) in rules {
                guard let rule = rawRule as? JSON, Set(rule.keys).isSubset(of: ["providers", "preferred_provider", "preferred_models"]), let providers = rule["providers"] as? [String], !providers.isEmpty, Set(providers).count == providers.count, Set(providers).isSubset(of: Set(allowed)) else { throw CoreError("POLICY_DENIED", "Role providers must stay inside participating project providers.") }
                if let preferred = rule["preferred_provider"], !(preferred is NSNull) { guard let preferred = preferred as? String, providers.contains(preferred) else { throw CoreError("INVALID_INPUT", "A preferred provider must already be eligible for that role.") } }
                if let models = rule["preferred_models"] { guard let models = models as? [String], models.count <= 8, Set(models).count == models.count, models.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 160 }) else { throw CoreError("INVALID_INPUT", "Model preferences must be at most eight bounded names.") } }
            }
            return rules
        }
        result["required_gates"] = try gates(result["required_gates"])
        result["roles"] = try roleRules(result["roles"], partial:false)
        if let rawRoles = input["roles"] { _ = try roleRules(rawRoles,partial:true) }
        guard let overrides = result["task_kind_overrides"] as? [JSON], overrides.count <= Self.policyKinds.count else { throw CoreError("INVALID_INPUT", "Provide at most one override per task kind.") }
        var kinds = Set<String>()
        for override in overrides {
            guard Set(override.keys).isSubset(of: ["kind", "roles", "required_gates", "allow_human_decision_evidence"]), let kind = override["kind"] as? String, Self.policyKinds.contains(kind), kinds.insert(kind).inserted, override["roles"] != nil || override["required_gates"] != nil || override["allow_human_decision_evidence"] != nil else { throw CoreError("INVALID_INPUT", "Each task kind has at most one nonempty bounded override.") }
            if let rules = override["roles"] { let value = try roleRules(rules,partial:true); guard !value.isEmpty else { throw CoreError("INVALID_INPUT", "An override must change a role or gates.") } }
            if let value = override["required_gates"] { _ = try gates(value) }
            if let value = override["allow_human_decision_evidence"] { guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw CoreError("INVALID_INPUT","A task-kind decision-evidence override must be a boolean.") } }
        }
        if let capacities = input["lane_capacities"] {
            guard let capacities = capacities as? JSON, capacities.count <= 16 else { throw CoreError("INVALID_INPUT", "At most sixteen named lane capacities are allowed.") }
            for (name, value) in capacities {
                guard name.range(of:"^[a-z][a-z0-9_-]{0,79}$",options:.regularExpression) != nil, let count = value as? NSNumber, CFGetTypeID(count) != CFBooleanGetTypeID(), count.doubleValue.rounded() == count.doubleValue, (1...32).contains(count.intValue) else { throw CoreError("INVALID_INPUT", "Lane capacities are whole numbers from 1 through 32.") }
            }
        }
        // Retain the disabled legacy future-assistant record without making it an authority control.
        if let legacy = input["assistant_relay_grants"] { guard let grants = legacy as? [String:Bool], grants.values.allSatisfy({ !$0 }) else { throw CoreError("FORBIDDEN", "Assistant enrollment is deferred and cannot be enabled through project policy.") } }
        return result
    }

    /// Agents make most project changes. The owner can always change them; an enrolled worker session can while the project
    /// allows agent changes (the default). Only the owner can switch that permission itself. Agent changes keep agent provenance.
    func requireAgentEditAuthority(_ db: Database, project: JSON, caller: Caller, proposedPolicy: JSON? = nil) throws {
        if caller.isOwner { return }
        try worker(caller)
        let pid = (try StoredRecord(project, family: "project").string("id"))
        guard let sid = caller.sessionID, let session = try? scoped(db,sid,pid,type:"session"), session["role"] as? String == "worker", !["revoked", "ended"].contains(session["state"] as? String ?? "") else { throw CoreError("FORBIDDEN", "An actual enrolled worker session is required to change this project.") }
        let current = effectivePolicy(project["policy"] as? JSON ?? [:],kind:"")["agent_rule_changes"] as? String ?? "allowed"
        guard current == "allowed" else { throw CoreError("HUMAN_CHANNEL_REQUIRED", "The owner limited changes in this project to the app.") }
        if let proposedPolicy, (proposedPolicy["agent_rule_changes"] as? String ?? "allowed") != current { throw CoreError("HUMAN_CHANNEL_REQUIRED", "Only the owner can change whether agents may change this project.") }
    }

    func validatePolicySelection(_ db: Database, project: JSON, task: JSON, caller: Caller, phase: String, policy: JSON) throws {
        guard !caller.isOwner else { return }
        guard let sid = caller.sessionID else { throw CoreError("FORBIDDEN", "An actual enrolled worker session is required.") }
        let session = try scoped(db,sid,(try StoredRecord(project, family: "project").string("id")),type:"session")
        let provider = session["provider"] as? String ?? ""
        let current = effectivePolicy(project["policy"] as? JSON ?? [:],kind:task["kind"] as? String ?? "work")
        let role = (AttemptPhase(rawValue: phase) ?? .implementation).workflowRole.rawValue
        let rule = (current["roles"] as? JSON)?[role] as? JSON ?? [:]
        guard session["role"] as? String == "worker", !["revoked", "ended"].contains(session["state"] as? String ?? ""), providerPlugins.plugin(provider, requiring: .workSession) != nil, strings(current,"allowed_providers").contains(provider), strings(rule,"providers").contains(provider) else { throw CoreError("POLICY_DENIED", "The current project policy does not grant this provider the requested role.",details:["policy_revision":project["policy_revision"] ?? 1,"role":role,"eligible_providers":strings(rule,"providers"),"external_process_stopped":false]) }
        // An agent planned assignee is a preference, not a lock: any eligible AI may claim an
        // unclaimed ticket (owner decision, 19 October 2026). Owner-assigned tickets stay
        // with the owner in work_claim, and review keeps contributor independence.
    }

    func validateTaskPolicyAssignment(_ db: Database, project: JSON, task: inout JSON, input: JSON, caller: Caller) throws {
        guard let value = input["planned_assignee"] ?? (input["kind"] != nil ? task["planned_assignee"] : nil) else { return }
        try validateAssignment(value)
        guard let assignment = value as? JSON, assignment["kind"] as? String == "agent" else { return }
        guard Set(assignment.keys).isSubset(of:["kind","provider","session_id"]) else { throw CoreError("INVALID_INPUT","Agent assignments select an existing eligible provider or actual worker session; assistant/profile metadata cannot assign work.") }
        let policy = effectivePolicy(project["policy"] as? JSON ?? [:],kind:task["kind"] as? String ?? "work")
        let eligible = strings((policy["roles"] as? JSON)?["implementer"] as? JSON ?? [:],"providers")
        var provider = assignment["provider"] as? String
        if let sid = assignment["session_id"] as? String {
            let session = try scoped(db,sid,(try StoredRecord(project, family: "project").string("id")),type:"session")
            guard session["role"] as? String == "worker", !["revoked", "ended"].contains(session["state"] as? String ?? "") else { throw CoreError("FORBIDDEN", "Only a currently enrolled worker can be assigned.") }
            if let requested = provider, requested != session["provider"] as? String { throw CoreError("POLICY_DENIED", "Assignment provider does not match its actual session.") }
            provider = session["provider"] as? String
        }
        guard let provider, providerPlugins.plugin(provider, requiring: .workSession) != nil, eligible.contains(provider) else { throw CoreError("POLICY_DENIED", "A task exception cannot expand project or task-kind role eligibility.",details:["eligible_providers":eligible]) }
        guard input["planned_assignee"] != nil else { return }
        let reason = try text(input,"assignment_reason",max:2000)
        task["assignment_reason"] = reason
        task["assignment_provenance"] = ["actor":caller.principal,"origin":caller.isOwner ? "human_ui" : "agent","at":now(),"policy_revision":project["policy_revision"] ?? 1]
    }

    func policyPreview(_ db: Database, project: JSON, policy: JSON, mode: String) throws -> JSON {
        guard ["future_attempts", "checkpoint_active"].contains(mode) else { throw CoreError("INVALID_INPUT", "Choose future attempts or checkpoint active work.") }
        let pid = (try StoredRecord(project, family: "project").string("id"))
        if mode == "checkpoint_active",
           try jsonString(canonicalReviewRequirements((project["policy"] as? JSON)?["review_requirements"])) != jsonString(canonicalReviewRequirements(policy["review_requirements"])) {
            throw CoreError("REVIEW_REQUIREMENT_RECONCILIATION_UNSUPPORTED","Use future work rounds for review-requirement changes. Same-gate active reconciliation requires a fresh explicit review path.")
        }
        // CL-248: coordinator_session_id is retired and routes nothing. An unchanged stored
        // value stays readable as history; a new or changed value is refused.
        if let sid = policy["coordinator_session_id"], (try? jsonString(["v":sid])) != (try? jsonString(["v":(project["policy"] as? JSON)?["coordinator_session_id"] ?? NSNull()])) {
            throw CoreError("INVALID_INPUT", "coordinator_session_id is retired: the Triage orchestrator now receives ticket communications. Remove the field; an old stored value stays readable as history.")
        }
        let tasks = try records(db,type:"task",project:pid).filter { !bool($0,"archived") && !bool($0,"trashed") }
        let attempts = try records(db,type:"attempt",project:pid).filter { $0["state"] as? String == "active" }
        var affected: [JSON] = [], deniedClaims: [JSON] = [], submittedRounds: [JSON] = []
        for task in tasks {
            let kind = task["kind"] as? String ?? "work", before = effectivePolicy(project["policy"] as? JSON ?? [:],kind:kind), after = effectivePolicy(policy,kind:kind)
            if try jsonString(before) != jsonString(after) {
                let category = try taskProjection(db,task)["status_category"] as? String ?? ""
                if ["done","canceled"].contains(category) { continue }
                let role = (after["roles"] as? JSON)?["implementer"] as? JSON ?? [:]
                affected.append(["task_id":task["id"]!,"key":task["key"] ?? "","title":task["title"] ?? "","revision":task["revision"]!,"status_category":category,"active":task["active_attempt_id"] != nil,"current_manifest_id":task["current_manifest_id"] ?? NSNull(),"before_gates":strings(before,"required_gates"),"after_gates":strings(after,"required_gates"),"eligible_implementers":strings(role,"providers"),"completion_contract":mode == "future_attempts" ? "existing_round_preserved" : "explicit_reconciliation_required"])
                for role in Self.policyRoles {
                    let old = strings((before["roles"] as? JSON)?[role] as? JSON ?? [:],"providers"), new = strings((after["roles"] as? JSON)?[role] as? JSON ?? [:],"providers"), denied = old.filter { !new.contains($0) }
                    if !denied.isEmpty { deniedClaims.append(["task_id":task["id"]!,"key":task["key"] ?? "","title":task["title"] ?? "","role":role,"denied_providers":denied,"eligible_providers":new]) }
                }
                if let mid = task["current_manifest_id"] as? String { submittedRounds.append(["task_id":task["id"]!,"key":task["key"] ?? "","title":task["title"] ?? "","manifest_id":mid,"reconciliation_required":mode == "checkpoint_active"]) }
            }
        }
        var active: [JSON] = []
        for attempt in attempts {
            guard let task = tasks.first(where: { $0["id"] as? String == attempt["task_id"] as? String }) else { continue }
            let effective = effectivePolicy(policy,kind:task["kind"] as? String ?? "work"), role = attempt["phase"] as? String == "review" ? "reviewer" : "implementer"
            let eligible = strings((effective["roles"] as? JSON)?[role] as? JSON ?? [:],"providers")
            let session = try? scoped(db,attempt["session_id"] as? String ?? "",pid,type:"session")
            let denied = session.map { !eligible.contains($0["provider"] as? String ?? "") } ?? false
            active.append(["attempt_id":attempt["id"]!,"revision":attempt["revision"]!,"task_id":task["id"]!,"key":task["key"] ?? "","title":task["title"] ?? "","role":role,"authority_revoked":denied,"acknowledgment_required":mode == "checkpoint_active","external_process_stopped":false])
        }
        var preview: JSON = ["project_id":pid,"project_revision":project["revision"]!,"policy_revision":project["policy_revision"] ?? 1,"mode":mode,"policy":policy,"affected_tasks":affected,"queued_task_ids":affected.filter { $0["status_category"] as? String == "queued" }.compactMap { $0["task_id"] as? String },"denied_future_claims":deniedClaims,"active_rounds":active,"submitted_rounds":submittedRounds,"warning":"Service revocation does not stop external processes or release filesystem reservations."]
        preview["digest"] = hash(Data((try jsonString(preview)).utf8)); return preview
    }

    func policyCommand(_ db: Database,_ p: JSON,_ c: Caller,_ method: String) throws -> JSON {
        try worker(c); let pid = try scope(db,p,c,write:true), project = try record(db,pid,type:"project")
        if method == "policy_acknowledge" { return try acknowledgePolicy(db,p,c,project:project) }
        if method == "policy_apply" {
            try revision(p,project)
            let reason: String? = c.isOwner ? p["reason"] as? String : try text(p,"reason",max:2000)
            let policy: JSON, mode: String
            if let proposalID = p["proposal_id"] as? String {
                let proposal = try scoped(db,proposalID,pid,type:"policy_proposal")
                guard proposal["state"] as? String == "proposed", proposal["digest"] as? String == p["digest"] as? String else { throw CoreError("POLICY_CHANGED", "Apply the unchanged preview and digest.") }
                policy = proposal["policy"] as? JSON ?? [:]; mode = proposal["mode"] as? String ?? "future_attempts"
                try requireAgentEditAuthority(db,project:project,caller:c,proposedPolicy:policy)
                let fresh = try policyPreview(db,project:project,policy:policy,mode:mode)
                guard fresh["digest"] as? String == proposal["digest"] as? String else { throw CoreError("REVISION_CONFLICT", "The project or affected work changed after preview. Refresh the preview; the draft is preserved.") }
                var applied = proposal; applied["state"] = "applied"; try save(db,revised(applied),type:"policy_proposal")
            } else {
                guard let raw = p["policy"] as? JSON else { throw CoreError("INVALID_INPUT", "A policy or unchanged proposal is required.") }
                policy = try normalizedPolicy(raw); mode = p["mode"] as? String ?? "future_attempts"
                try requireAgentEditAuthority(db,project:project,caller:c,proposedPolicy:policy)
                _ = try policyPreview(db,project:project,policy:policy,mode:mode)
            }
            return try applyPolicy(db,project:project,policy:policy,mode:mode,caller:c,reason:reason)
        }
        guard let raw = p["policy"] as? JSON else { throw CoreError("INVALID_INPUT", "A complete policy object is required.") }
        let policy = try normalizedPolicy(raw), mode = p["mode"] as? String ?? "future_attempts"
        var preview = try policyPreview(db,project:project,policy:policy,mode:mode)
        if method == "policy_propose" {
            preview["id"] = uuid(); preview["revision"] = 1; preview["state"] = "proposed"; preview["proposed_by"] = c.principal; preview["created_at"] = now()
            try save(db,preview,type:"policy_proposal"); try event(db,caller:c,project:pid,entity:preview["id"] as? String,kind:"policy_proposed")
        }
        return preview
    }

    func applyPolicy(_ db: Database, project: JSON, policy: JSON, mode: String, caller: Caller, reason: String? = nil) throws -> JSON {
        try requireAgentEditAuthority(db,project:project,caller:caller,proposedPolicy:policy)
        let pid = (try StoredRecord(project, family: "project").string("id"))
        // An agent never revises the contract of work it currently holds; its rule changes apply to future attempts.
        if !caller.isOwner, mode == "checkpoint_active", let sid = caller.sessionID,
           try records(db,type:"attempt",project:pid).contains(where: { $0["state"] as? String == "active" && $0["session_id"] as? String == sid }) {
            throw CoreError("POLICY_DENIED","An agent that holds active work in this project can change rules only for future attempts. Use mode future_attempts or release the work first.")
        }
        _ = try retainPolicy(db,project:project)
        let number = int(project,"policy_revision",default:1) + 1
        var updated = project; updated["policy"] = policy; updated["policy_revision"] = number; updated["policy_apply_mode"] = mode
        updated = revised(updated); try save(db,updated,type:"project"); _ = try retainPolicy(db,project:updated)
        let attempts = try records(db,type:"attempt",project:pid).filter { $0["state"] as? String == "active" }
        for var attempt in attempts {
            let task = try scoped(db,(try StoredRecord(attempt, family: "attempt").string("task_id")),pid,type:"task"), effective = effectivePolicy(policy,kind:task["kind"] as? String ?? "work")
            let phase = AttemptPhase(rawValue: attempt["phase"] as? String ?? "") ?? .implementation
            let role = phase.workflowRole.rawValue
            let rule = (effective["roles"] as? JSON)?[role] as? JSON ?? [:]
            if let session = try? scoped(db,attempt["session_id"] as? String ?? "",pid,type:"session"), !strings(rule,"providers").contains(session["provider"] as? String ?? "") { attempt["policy_authority_revoked"] = true; attempt["filesystem_recovery_warning"] = "Authority revoked. Verify the external process before releasing its reservations." }
            if mode == "checkpoint_active" {
                attempt["pending_policy_snapshot"] = effective; attempt["pending_policy_revision"] = number
                attempt["pending_policy_checkpoint_revision"] = int(attempt,"revision") + 1
                attempt["pending_policy_checkpoint_id"] = try records(db,type:"checkpoint",project:pid).last(where: { $0["attempt_id"] as? String == attempt["id"] as? String })?["id"] ?? NSNull()
            }
            if mode == "checkpoint_active" || bool(attempt,"policy_authority_revoked") {
                try save(db,revised(attempt),type:"attempt")
                var note: JSON = ["project_id":pid,"task_id":task["id"]!,"body":"Ticket metadata: \(try agentReference(db,task)). Project workflow revision \(number) was applied to attempt \(attempt["id"] as? String ?? ""). \(bool(attempt,"policy_authority_revoked") ? "Your service work authority was revoked; the external process and reservations have not been stopped or released." : "Checkpoint and explicitly acknowledge the revised completion contract before submitting or recording a verdict.")","kind":"control"]
                if let sid = attempt["session_id"] as? String, sid != "human", let session = try? scoped(db,sid,pid,type:"session"), canReceive(session,project:pid) { note["recipient"] = ["kind":"session","session_id":sid] }
                _ = try messageWrite(db,note,caller,"message_send")
            }
        }
        if mode == "checkpoint_active" {
            for var task in try records(db,type:"task",project:pid) where task["active_attempt_id"] != nil || task["current_manifest_id"] != nil {
                if bool(task,"archived") || bool(task,"trashed") { continue }
                let category = try taskProjection(db,task)["status_category"] as? String ?? ""
                if ["done", "canceled"].contains(category) { continue }
                task["pending_policy_revision"] = number; task["pending_policy_snapshot"] = effectivePolicy(policy,kind:task["kind"] as? String ?? "work")
                try save(db,revised(task),type:"task")
            }
        }
        try event(db,caller:caller,project:pid,entity:pid,kind:"policy_updated",data:["mode":mode,"policy_revision":number,"external_processes_stopped":false,"origin":caller.isOwner ? "human_ui" : "agent","reason":reason.map { $0 as Any } ?? NSNull()]); return updated
    }

    func verifyPolicyAuthority(_ db: Database, attempt: JSON, caller: Caller, requireAcknowledgment: Bool = true) throws {
        if requireAcknowledgment, attempt["pending_policy_revision"] != nil { throw CoreError("POLICY_ACK_REQUIRED", "Checkpoint and explicitly acknowledge the revised policy before submission or verdict.",details:["policy_revision":attempt["pending_policy_revision"]!]) }
        if requireAcknowledgment, bool(attempt,"policy_authority_revoked") { throw CoreError("POLICY_DENIED", "Service work authority was revoked. External process status and reservations require explicit recovery.") }
        if requireAcknowledgment {
            let pid = (try StoredRecord(attempt, family: "attempt").string("project_id")), project = try record(db,pid,type:"project")
            var task = try scoped(db,(try StoredRecord(attempt, family: "attempt").string("task_id")),pid,type:"task")
            if attempt["parent_attempt_id"] != nil { task.removeValue(forKey:"planned_assignee") }
            try validatePolicySelection(db,project:project,task:task,caller:caller,phase:attempt["phase"] as? String ?? "implementation",policy:try attemptPolicy(db,attempt))
        }
    }

    func acknowledgePolicy(_ db: Database,_ p: JSON,_ c: Caller,project: JSON) throws -> JSON {
        let pid = (try StoredRecord(project, family: "project").string("id"))
        var attempt: JSON?, task: JSON
        if p["attempt_id"] != nil {
            var active = try claimAttempt(db,p,c,pid)
            try verifyPolicyAuthority(db,attempt:active,caller:c,requireAcknowledgment:false)
            guard let snapshot = active["pending_policy_snapshot"] as? JSON, active["pending_policy_revision"] != nil else { throw CoreError("INVALID_TRANSITION", "This attempt has no pending policy reconciliation.") }
            let checkpoint = try records(db,type:"checkpoint",project:pid).last(where: { $0["attempt_id"] as? String == active["id"] as? String && $0["principal"] as? String == c.principal })
            guard active["last_checkpoint"] != nil, int(active,"revision") > int(active,"pending_policy_checkpoint_revision"), let checkpointID = checkpoint?["id"] as? String, checkpointID != active["pending_policy_checkpoint_id"] as? String else { throw CoreError("CHECKPOINT_REQUIRED", "Save a fresh checkpoint after the policy change before acknowledging the changed completion contract.") }
            task = try scoped(db,(try StoredRecord(active, family: "attempt").string("task_id")),pid,type:"task")
            try validatePolicySelection(db,project:project,task:task,caller:c,phase:active["phase"] as? String ?? "implementation",policy:snapshot)
            active["policy_snapshot"] = snapshot; active["policy_revision"] = active["pending_policy_revision"]
            active.removeValue(forKey:"pending_policy_snapshot"); active.removeValue(forKey:"pending_policy_revision"); active.removeValue(forKey:"pending_policy_checkpoint_revision"); active.removeValue(forKey:"pending_policy_checkpoint_id"); active["policy_acknowledged_at"] = now()
            active = revised(active); try save(db,active,type:"attempt"); attempt = active
        } else {
            try owner(c); task = try self.task(db,p,pid); try revision(p,task)
            guard task["active_attempt_id"] == nil else { throw CoreError("CLAIM_CONFLICT", "The active handler must checkpoint and acknowledge its own completion contract, or the owner must explicitly recover the attempt first.") }
        }
        guard let snapshot = task["pending_policy_snapshot"] as? JSON ?? attempt?["policy_snapshot"] as? JSON, let number = task["pending_policy_revision"] ?? attempt?["policy_revision"] else { throw CoreError("INVALID_TRANSITION", "The task has no pending completion-contract reconciliation.") }
        _ = try text(p,"reason",max:2000)
        task["completion_policy_snapshot"] = snapshot; task["completion_policy_revision"] = number
        task["completion_policy_manifest_id"] = task["current_manifest_id"] ?? NSNull()
        task.removeValue(forKey:"pending_policy_snapshot"); task.removeValue(forKey:"pending_policy_revision")
        if let mid = task["current_manifest_id"] as? String {
            let requests = try records(db,type:"review_request",project:pid).filter { $0["task_id"] as? String == task["id"] as? String && $0["manifest_id"] as? String == mid }
            for gate in strings(snapshot,"required_gates") where !requests.contains(where: { $0["gate"] as? String == gate && $0["state"] as? String != "superseded" }) {
                try save(db,["id":uuid(),"project_id":pid,"task_id":task["id"]!,"key":task["key"] ?? "","title":task["title"] ?? "","manifest_id":mid,"gate":gate,"state":"queued","revision":1,"created_at":now()],type:"review_request")
            }
        }
        task = revised(task); try save(db,task,type:"task")
        try event(db,caller:c,project:pid,entity:task["id"] as? String,kind:"policy_acknowledged",data:["policy_revision":number,"reason":p["reason"]!])
        var result: JSON = ["task":try taskProjection(db,task)]
        if var attempt { attempt.removeValue(forKey:"token_hash"); result["attempt"] = attempt }; return result
    }
}
