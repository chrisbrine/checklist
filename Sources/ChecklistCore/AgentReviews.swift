import Foundation
import ChecklistProviders
import GRDB
import Darwin

/// Only this fresh O_EXCL report can be discarded on its creating transaction's
/// rollback. Production dispatch retains the object gate until rollback ends,
/// so no backup can have inventoried it. This is not a general capture bypass.
private final class UncommittedReviewReport {
    private let directory: Int32
    private let name: String
    private let identity: stat
    init(root: URL, relative: String, bytes: Data) throws {
        let files = try StorageObjectFiles(root:root)
        try files.writeNew(relative,bytes:bytes)
        let (directory,name) = try files.parent(relative)
        var identity = stat()
        guard fstatat(directory,name,&identity,AT_SYMLINK_NOFOLLOW) == 0,identity.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(directory);throw StorageSnapshotFailure.io
        }
        self.directory = directory;self.name = name;self.identity = identity
    }
    deinit {Darwin.close(directory)}
    func rollback() {
        var current = stat()
        guard fstatat(directory,name,&current,AT_SYMLINK_NOFOLLOW) == 0,current.st_mode & S_IFMT == S_IFREG,
              current.st_dev == identity.st_dev,current.st_ino == identity.st_ino,current.st_size == identity.st_size,
              current.st_mtimespec.tv_sec == identity.st_mtimespec.tv_sec,current.st_mtimespec.tv_nsec == identity.st_mtimespec.tv_nsec else {return}
        if unlinkat(directory,name,0) == 0 {_ = fsync(directory)}
    }
}

extension CommandRouter {
    func capturedReviewInstructions(_ capture: JSON) throws -> [JSON] {
        let files = capture["files"] as? [JSON] ?? []
        guard !files.isEmpty else {return []}
        guard let captureID = capture["id"] as? String,let sourceHash = capture["sha256"] as? String else {throw CoreError("EVIDENCE_STALE","Captured project instructions have no immutable source identity.")}
        var entries: [String:JSON] = [:]
        for file in files {
            guard let path = file["path"] as? String,entries[path] == nil else {throw CoreError("EVIDENCE_STALE","Captured project instruction paths are ambiguous.")}
            entries[path] = file
        }
        return try files.filter {($0["path"] as? String ?? "").split(separator:"/").last == "AGENTS.md" && ["file","symlink"].contains($0["kind"] as? String ?? "")}.map { instruction in
            var ref = try capturedSourceInput(instruction["path"] as! String,entries:entries)
            ref["source_capture_id"] = captureID;ref["source_sha256"] = sourceHash
            return ref
        }
    }
    func reviewContract(_ db: Database, task: JSON, manifest: JSON) throws -> JSON {
        let project = try record(db,task["project_id"] as! String,type:"project")
        func requirement(_ id: String,_ body: String,_ kind: String) -> JSON { ["id":id,"text":body,"kind":kind,"sha256":hash(Data(body.utf8))] }
        let acceptance = strings(task,"acceptance").enumerated().map { requirement("acceptance:\($0.offset)",$0.element,"acceptance") }
        var requirements: [JSON] = []
        if let brief = project["brief"] as? String,!brief.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { requirements.append(requirement("project:brief",brief,"project_brief")) }
        for pin in applicableDecisions(project,task:task) { requirements.append(requirement("project:decision:"+(pin["id"] as? String ?? hash(Data((pin["body"] as? String ?? "").utf8))),pin["body"] as? String ?? "","approved_project_decision")) }
        let capture = (manifest["evidence"] as? JSON)?["source_capture"] as? JSON ?? [:]
        let instructions = try capturedReviewInstructions(capture)
        let rubric = try reviewRequirementState(db,task:task),snapshot = rubric["snapshot"] as! JSON
        requirements += try reviewRequirementRows(snapshot)
        // Current authority stays current; only the separately pinned rubric governs checks.
        let policy = effectivePolicy(project["policy"] as? JSON ?? [:],kind:task["kind"] as? String ?? "work").filter {$0.key != "review_requirements"}
        var contract: JSON = ["version":2,"review_requirements":snapshot,"review_requirements_state":rubric["state"]!,"task_id":task["id"]!,"manifest_id":manifest["id"]!,"acceptance_revision":int(task,"acceptance_revision",default:1),"acceptance":acceptance,"project_requirements":requirements,"project_instruction_refs":instructions,"review_policy":policy,"project_brief_revision":int(project,"brief_revision"),"project_decisions_revision":int(project,"decisions_revision")]
        contract["sha256"] = hash(Data((try jsonString(contract)).utf8));return contract
    }
    func exactAgentReview(_ db: Database,_ p: JSON,_ c: Caller) throws -> (JSON,JSON,JSON) {
        try worker(c);let pid = try scope(db,p,c),task = try self.task(db,p,pid),request = try scoped(db,try text(p,"review_request_id"),pid,type:"review_request")
        guard request["task_id"] as? String == task["id"] as? String,request["manifest_id"] as? String == p["target_manifest_id"] as? String,request["gate"] as? String == p["gate"] as? String,["queued","active","blocked"].contains(request["state"] as? String ?? ""),request["gate"] as? String != "human_approval" else { throw CoreError("REVIEW_TARGET_MISMATCH","Select the exact queued or active agent review request, gate and current target.") }
        return (task,request,try validateManifestTarget(db,task:task,manifestID:request["manifest_id"] as! String))
    }
    func agentReviewContext(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        let (task,request,manifest) = try exactAgentReview(db,p,c)
        var context = try compactTaskContext(db,task:task,caller:c)
        context["review_request"] = request;context["target_manifest"] = manifest;context["review_contract"] = try reviewContract(db,task:task,manifest:manifest)
        let capture = (manifest["evidence"] as? JSON)?["source_capture"] as? JSON
        context["source_relevance"] = capture?["relevance"] ?? ["mode":"whole"]
        context["acceptance_evidence"] = (manifest["evidence"] as? JSON)?["acceptance_evidence"] ?? []
        context["review_evidence_requirements"] = try reviewRequirementPreflight(db,params:p,task:task,manifest:manifest,caller:c)
        context["review_instruction"] = "Use a fresh non-contributor conversation. Assess every acceptance item and current project requirement, including applicable captured AGENTS.md and linked rules. Choose meaningful inspection/checks in your own session. After rework, carry input-valid passing acceptance/check cases with their original producer, target and hashes; distinguish them from new execution in your current reviewer-owned report. Run only failed, inconclusive or materially affected cases; a fixture-only repair does not require an all-green suite. Before broader checks, identify named cases and invalidating inputs or cite the applicable explicit effective project workflow/context instruction; Triage membership or sibling failure is no override. Carrying checks does not transfer an old verdict or approval; fresh target-bound gates remain required. Attach your own report/log/screenshots as managed hashed evidence. No service-run test or validation script is required. Claim the exact request before reviewing; preparation alone grants no authority. Refresh review_context after claim for the applied rubric contract. Its evidence_refs selection preflight validates real scoped bytes; classes never prove native or execution success."
        return context
    }
    func prepareAgentReview(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        let (task,request,manifest) = try exactAgentReview(db,p,c),pid = task["project_id"] as! String,project = try record(db,pid,type:"project")
        guard request["state"] as? String == "queued",task["active_attempt_id"] == nil,task["active_verification_request_id"] == nil else { throw CoreError("REVIEW_ALREADY_ACTIVE","Release the existing review before preparing another fresh reviewer.") }
        let provider = p["provider"] as? String ?? ProviderPolicyDefaults.defaultReviewProvider,policy = effectivePolicy(project["policy"] as? JSON ?? [:],kind:task["kind"] as? String ?? "work"),reviewers = strings((policy["roles"] as? JSON)?["reviewer"] as? JSON ?? [:],"providers")
        guard providerPlugins.plugin(provider, requiring: .workSession) != nil,strings(policy,"allowed_providers").contains(provider),reviewers.contains(provider) else { throw CoreError("POLICY_DENIED","The selected provider is not currently eligible for this project's review role.") }
        let selectors: JSON = ["project_id":pid,"task_id":task["id"]!,"review_request_id":request["id"]!,"target_manifest_id":manifest["id"]!,"gate":request["gate"]!]
        let root = project["root_path"] as? String ?? "",json = try jsonString(selectors)
        let instruction = agentReviewInstruction(provider:provider,task:task,root:root,json:json,reference:try agentReference(db,task))
        var response: JSON = ["task_id":task["id"]!,"key":task["key"] ?? "","title":task["title"] ?? "","project_name":project["name"] ?? "","provider":provider,"instruction":instruction,"review_request_id":request["id"]!,"target_manifest_id":manifest["id"]!,"review_contract":try reviewContract(db,task:task,manifest:manifest),"launch_available":false,"session_connected":false,"claim_acquired":false,"state":"prepared_copy","limitation":"Open a fresh conversation and paste this instruction. Native creation/connection/claim has not occurred."]
        if let url = providerPlugins.plugin(provider, requiring: .composer)?.composeURL(instruction:instruction,workspace:root) {
            response["compose_url"] = url.absoluteString;response["state"] = "prepared_composer"
            response["limitation"] = "Open the prepared fresh composer and press Send. A draft is not a created/connected reviewer or a review claim."
        }
        response["review_evidence_requirements"] = try reviewRequirementPreflight(db,params:[:],task:task,manifest:manifest,caller:c)
        return response
    }
    func agentReviewInstruction(provider: String,task: JSON,root: String,json: String,reference: String) -> String {
        return "Start a fresh independent \(providerPlugins.plugin(provider, requiring: .workSession)?.manifest.displayName ?? provider) reviewer conversation for ticket metadata \(reference). Do not reuse an implementation contributor or its delegated/prior identity. Work in \(root). Run \(cliCommand) connect --task \(task["id"]!) from that workspace. Discover checklist tools, then call review_context with this exact JSON: \(json). Read the complete brief, acceptance, findings, immutable target and current review_contract; fetch captured AGENTS.md and its linked project rules. Claim this exact request with phase review, current task revision, gate and manifest before review. Refresh review_context after claiming to obtain the applied requirement revision and contract SHA; pre-claim preparation is a preview. Assess every acceptance and project requirement critically; choose meaningful checks in your own session, attach your own hashed report/log/screenshots with attachment_add, and record review_assessment against the fresh contract SHA-256. No swift_test or validate-plan receipt is required. On rework, follow the case-level failed-only guidance in review_context: carry input-valid passes with original provenance, run only failed/inconclusive/materially affected checks, explain broader selection by named changed inputs or an applicable explicit effective project workflow/context instruction, and report carried versus newly executed evidence. A fixture-only repair needs no all-green rerun; no prior verdict or approval transfers and all fresh gates remain required. Report pass, changes or blocked honestly, preserving stable finding IDs. Preparing this prompt starts no turn and acquires no claim."
    }
    func addAgentReviewEvidence(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try worker(c);let pid = try scope(db,p,c,write:true),attempt = try claimAttempt(db,p,c,pid)
        guard attempt["phase"] as? String == "review",let mid = attempt["manifest_id"] as? String else {throw CoreError("INVALID_TRANSITION","Reviewer evidence requires the exact active review claim.")}
        try verifyPolicyAuthority(db,attempt:attempt,caller:c)
        let task = try scoped(db,attempt["task_id"] as! String,pid,type:"task");_ = try validateManifestTarget(db,task:task,manifestID:mid)
        let measures = try EvidenceMeasure.parse(p["measures"])
        let title = try text(p,"title",max:1000),body = try measuredReportBody(text(p,"body",max:65536),measures:measures),bytes = Data(body.utf8),id = uuid(),relative = "objects/" + pid + "/" + id + ".md"
        let report = try UncommittedReviewReport(root:root,relative:relative,bytes:bytes)
        db.afterNextTransaction(onCommit:{_ in},onRollback:{_ in report.rollback()})
        var artifact: JSON = ["id":id,"artifact_id":id,"project_id":pid,"task_id":task["id"]!,"name":title,"description":"Reviewer-authored evidence for exact target "+mid,"mode":"managed","path":relative,"sha256":hash(bytes),"size":bytes.count,"availability":"available","keep_original":false,"unlinked":false,"author":c.principal,"origin":c.isOwner ? "human_ui" : c.role,"review_attempt_id":attempt["id"]!,"target_manifest_id":mid,"revision":1,"created_at":now()]
        if p["measures"] != nil { artifact["measures"] = measures.map(\.json) }
        try save(db,artifact,type:"attachment");try event(db,caller:c,project:pid,entity:task["id"] as? String,kind:"review_evidence_added",data:["artifact_id":id,"manifest_id":mid,"attempt_id":attempt["id"]!])
        var response = artifact;if !c.isOwner {response.removeValue(forKey:"path")};return response
    }
    func validateReviewEvidence(_ db: Database, refs: [JSON], task: JSON, manifest: JSON, caller: Caller) throws -> (refs:[JSON],owned:Bool) {
        let pid = task["project_id"] as! String,evidence = manifest["evidence"] as? JSON ?? [:],targetArtifacts = (evidence["artifact_refs"] as? [JSON] ?? []) + acceptanceArtifactRefs(evidence)
        var validated: [JSON] = [],owned = false
        guard !refs.isEmpty,refs.count <= 100 else {throw CoreError("REVIEW_ASSESSMENT_INCOMPLETE","Assessments need reviewer-chosen evidence references.")}
        // Legacy CL-41 supplemental evidence retained on a review request of
        // this ticket and this exact target, is selectable and citable; it keeps its author.
        let supplemental = try records(db,type:"review_request",project:pid).filter {$0["task_id"] as? String == task["id"] as? String && $0["manifest_id"] as? String == manifest["id"] as? String}.flatMap {$0["supplemental_evidence_refs"] as? [JSON] ?? []}
        for ref in refs {
            let allowed: Set<String> = ref["artifact_id"] != nil ? ["artifact_id","sha256"] : (ref["source_capture_id"] != nil ? ["source_capture_id","sha256"] : ["decision_sha256"])
            guard Set(ref.keys) == allowed else {throw CoreError("INVALID_INPUT","Review evidence references have unsupported or missing fields.")}
            if let id = ref["artifact_id"] as? String {
                let artifact = try scoped(db,id,pid,type:"attachment"),isOwned = artifact["author"] as? String == caller.principal
                if let bound = artifact["review_attempt_id"] as? String {guard bound == task["active_attempt_id"] as? String,artifact["target_manifest_id"] as? String == manifest["id"] as? String else {throw CoreError("REVIEW_TARGET_MISMATCH","This reviewer evidence was recorded for another review attempt/target.")}}
                let isTarget = targetArtifacts.contains {$0["artifact_id"] as? String == id && $0["sha256"] as? String == ref["sha256"] as? String}
                let isSupplemental = supplemental.contains {$0["artifact_id"] as? String == id && $0["sha256"] as? String == ref["sha256"] as? String}
                guard artifact["task_id"] as? String == task["id"] as? String,isOwned || isTarget || isSupplemental,artifact["mode"] as? String == "managed",artifact["availability"] as? String == "available",artifact["sha256"] as? String == ref["sha256"] as? String,let path = artifact["path"] as? String,objectBytesMatch(path,sha256:ref["sha256"] as? String ?? "") else {throw CoreError("EVIDENCE_STALE","Review evidence must be an available hash-verified own review artifact or this exact submitted target.")}
                validated.append(["artifact_id":id,"sha256":artifact["sha256"]!,"role":isOwned ? "reviewer_artifact" : (isTarget ? "submitted_target" : "supplemental_evidence")]);owned = owned || isOwned
            } else {
                try findingEvidence(db,refs:[ref],task:task,manifestID:manifest["id"] as! String);validated.append(ref)
            }
        }
        return (validated,owned)
    }
    func validateReviewAssessment(_ db: Database, params: JSON, task: JSON, attempt: JSON, verdict: String, caller: Caller) throws -> JSON? {
        let target = try scoped(db,attempt["manifest_id"] as! String,task["project_id"] as! String,type:"manifest")
        try requirePlaytestAssessment(params:params,manifest:target,verdict:verdict)
        guard verdict == "pass" || params["review_assessment"] != nil else {return nil}
        let manifest = try validateManifestTarget(db,task:task,manifestID:attempt["manifest_id"] as! String),contract = try reviewContract(db,task:task,manifest:manifest)
        guard let input = params["review_assessment"] as? JSON,input["contract_sha256"] as? String == contract["sha256"] as? String,input["target_manifest_id"] as? String == manifest["id"] as? String else {throw CoreError("REVIEW_ASSESSMENT_REQUIRED","Read current review_context and assess its exact acceptance and project requirements before passing.")}
        guard Set(input.keys) == ["contract_sha256","target_manifest_id","acceptance","project_requirements","evidence_refs","instruction_coverage","all_applicable_project_requirements_assessed","additional_requirements"] else {throw CoreError("INVALID_INPUT","Review assessment contains unsupported or missing fields.")}
        var output: JSON = ["version":1,"contract_sha256":contract["sha256"]!,"target_manifest_id":manifest["id"]!,"contract":contract,"actor":caller.principal,"recorded_at":now()]
        let overall = try classifiedReviewEvidence(db,refs:input["evidence_refs"] as? [JSON] ?? [],task:task,manifest:manifest,attempt:attempt,caller:caller)
        guard verdict != "pass" || overall.owned else {throw CoreError("REVIEW_ASSESSMENT_INCOMPLETE","Attach your own managed hashed review report or chosen check artifact; an implementation contributor's file is not your review result.")}
        output["evidence_refs"] = overall.refs
        let rubricGaps = try reviewRequirementGapResult(snapshot:contract["review_requirements"] as! JSON,task:task,manifest:manifest,attempt:attempt,selectedCount:overall.refs.count,descriptors:overall.descriptors)
        if verdict == "pass",!(strings(rubricGaps,"missing_evidence_types").isEmpty) || int(rubricGaps,"ambiguous_reference_count") > 0 {
            throw CoreError("REVIEW_EVIDENCE_MISSING","Required selected evidence classes are missing before this verdict can be recorded.",details:rubricGaps)
        }
        output["review_evidence_requirements"] = rubricGaps
        for check in params["checks"] as? [JSON] ?? [] {
            let chosen = try validateReviewEvidence(db,refs:check["evidence_refs"] as? [JSON] ?? [],task:task,manifest:manifest,caller:caller)
            guard chosen.owned else {throw CoreError("REVIEW_ASSESSMENT_INCOMPLETE","A check reported as your result needs your own hashed log, result, report or screenshot evidence.")}
        }
        for section in ["acceptance","project_requirements"] {
            let requirements = contract[section] as? [JSON] ?? [],rows = input[section] as? [JSON] ?? []
            guard rows.count == requirements.count,Set(rows.compactMap {$0["requirement_id"] as? String}) == Set(requirements.compactMap {$0["id"] as? String}) else {throw CoreError("REVIEW_ASSESSMENT_INCOMPLETE","Assess every current \(section) item exactly once.")}
            output[section] = try rows.map { row -> JSON in
                guard Set(row.keys) == ["requirement_id","result","rationale","evidence_refs"] else {throw CoreError("INVALID_INPUT","Requirement assessments have unsupported or missing fields.")}
                let result = try text(row,"result",max:100),rationale = try text(row,"rationale",max:16000)
                guard ["pass","fail","blocked","not_applicable"].contains(result),verdict != "pass" || ["pass","not_applicable"].contains(result) else {throw CoreError("REVIEW_ASSESSMENT_INCOMPLETE","A passing review cannot leave an acceptance/project requirement failed or blocked.")}
                return ["requirement_id":row["requirement_id"]!,"result":result,"rationale":rationale,"evidence_refs":try validateReviewEvidence(db,refs:row["evidence_refs"] as? [JSON] ?? [],task:task,manifest:manifest,caller:caller).refs]
            }
        }
        let instructions = contract["project_instruction_refs"] as? [JSON] ?? [],coverage = input["instruction_coverage"] as? [JSON] ?? []
        let expectedCoverage = Set(try instructions.map {try jsonString($0)}),actualCoverage = Set(try coverage.map {try jsonString($0)})
        guard bool(input,"all_applicable_project_requirements_assessed"),coverage.count == instructions.count,actualCoverage == expectedCoverage else {throw CoreError("REVIEW_ASSESSMENT_INCOMPLETE","Inspect the exact captured project instructions and explicitly account for all applicable requirements.")}
        let additional = input["additional_requirements"] as? [JSON] ?? []
        guard additional.count <= 100,instructions.isEmpty || !additional.isEmpty else {throw CoreError("REVIEW_ASSESSMENT_INCOMPLETE","List the applicable requirements discovered in the captured project instructions and linked rules.")}
        output["additional_requirements"] = try additional.map {row -> JSON in
            guard Set(row.keys) == ["requirement","source","result","rationale","evidence_refs"] else {throw CoreError("INVALID_INPUT","Additional requirement assessments have unsupported or missing fields.")}
            let result = try text(row,"result",max:100)
            guard ["pass","fail","blocked","not_applicable"].contains(result),verdict != "pass" || ["pass","not_applicable"].contains(result) else {throw CoreError("REVIEW_ASSESSMENT_INCOMPLETE","Resolve failed or blocked project requirements before passing.")}
            return ["requirement":try text(row,"requirement",max:16000),"source":try text(row,"source",max:4000),"result":result,"rationale":try text(row,"rationale",max:16000),"evidence_refs":try validateReviewEvidence(db,refs:row["evidence_refs"] as? [JSON] ?? [],task:task,manifest:manifest,caller:caller).refs]
        }
        output["instruction_coverage"] = instructions;output["all_applicable_project_requirements_assessed"] = true
        return output
    }
}
