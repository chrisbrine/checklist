import Foundation
import CoreFoundation
import GRDB
import ImageIO

extension ReviewRequirement {
    var jsonValue: JSON {
        ["checks":checks.map {["id":$0.id.text,"text":$0.text]},"reject_bar":rejectBar,
         "required_evidence_types":ReviewRequirementEvidenceType.allCases.filter {requiredEvidenceTypes.contains($0)}.map(\.rawValue)]
    }
}

extension CommandRouter {
    func reviewIDEqual(_ lhs: Any?,_ rhs: Any?) -> Bool {
        guard let lhs = lhs as? String,let rhs = rhs as? String else {return false}
        return lhs.utf8.elementsEqual(rhs.utf8)
    }
    func reviewRequirementRevision(_ raw: Any?) throws -> Int {
        guard let number = raw as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = Int(number.stringValue),value > 0 else {
            throw CoreError("REVIEW_REQUIREMENT_STALE","A positive exact policy revision is required.")
        }
        return value
    }
    func canonicalReviewRequirements(_ raw: Any?) throws -> JSON {
        do {
            _ = try ReviewRequirementConfiguration.parse(raw)
            guard let value = raw as? JSON else {return [:]}
            var result: JSON = [:]
            if let base = value["default"] {result["default"] = try ReviewRequirement.parse(base).jsonValue}
            if let overrides = value["kind_overrides"] as? [JSON] {
                result["kind_overrides"] = try ReviewRequirementKind.allCases.compactMap { kind -> JSON? in
                    guard let entry = overrides.first(where: {$0["kind"] as? String == kind.rawValue}) else {return nil}
                    return ["kind":kind.rawValue,"requirement":try ReviewRequirement.parse(try StoredRecord(entry, family: "review requirement").requiredValue("requirement")).jsonValue]
                }
            }
            return result
        } catch {throw CoreError("INVALID_INPUT","Use complete bounded review requirements with supported evidence types.")}
    }
    func currentReviewRequirementSnapshot(project: JSON,task: JSON) throws -> JSON {
        guard let projectID = project["id"] as? String,reviewIDEqual(task["project_id"],projectID),
              let kind = ReviewRequirementKind(rawValue:task["kind"] as? String ?? "") else {
            throw CoreError("REVIEW_REQUIREMENT_STALE","Review requirements need the exact project and ticket kind.")
        }
        let rawPolicy = project["policy"] as? JSON ?? [:],revision = try reviewRequirementRevision(project["policy_revision"])
        let identity = try ReviewRequirementPolicyIdentity(projectID:projectID,revision:revision,digest:hash(Data(try jsonString(rawPolicy).utf8)))
        let resolved = try ReviewRequirementConfiguration.parse(rawPolicy["review_requirements"]).resolve(policy:identity,kind:kind)
        return ["version":1,"project_id":projectID,"task_kind":kind.rawValue,"policy_revision":revision,
                "policy_sha256":identity.digest,"requirement":resolved.requirement.jsonValue,"sha256":resolved.digest]
    }
    func pinReviewRequirement(_ db: Database,project: JSON,task: JSON) throws -> JSON {
        let retained = try retainPolicy(db,project:project),snapshot = try currentReviewRequirementSnapshot(project:project,task:task)
        guard let policy = retained["policy"] as? JSON,reviewIDEqual(retained["project_id"],project["id"]),
              try reviewRequirementRevision(retained["policy_revision"]) == reviewRequirementRevision(snapshot["policy_revision"]),
              hash(Data(try jsonString(policy).utf8)) == snapshot["policy_sha256"] as? String else {
            throw CoreError("REVIEW_REQUIREMENT_STALE","The retained policy revision does not match this review claim.")
        }
        return snapshot
    }
    func reviewRequirementState(_ db: Database,task: JSON) throws -> JSON {
        let taskRecord = try StoredTaskRecord(task)
        let pid = taskRecord.projectID,project = try record(db,taskRecord.projectID,type:"project")
        if let aid = task["active_attempt_id"] as? String {
            let attempt = try scoped(db,aid,pid,type:"attempt")
            if attempt["phase"] as? String == "review",attempt["state"] as? String == "active" {
                guard reviewIDEqual(attempt["project_id"],pid),reviewIDEqual(attempt["task_id"],task["id"]),
                      reviewIDEqual(attempt["manifest_id"],task["current_manifest_id"]),
                      let snapshot = attempt["review_requirement_snapshot"] as? JSON else {
                    throw CoreError("REVIEW_REQUIREMENT_RECLAIM_REQUIRED","This legacy review has no applied requirement snapshot. Preserve its evidence, release and claim a fresh review.")
                }
                let keys: Set<String> = ["version","project_id","task_kind","policy_revision","policy_sha256","requirement","sha256"]
                guard Set(snapshot.keys) == keys,try reviewRequirementRevision(snapshot["version"]) == 1,
                      reviewIDEqual(snapshot["project_id"],pid),reviewIDEqual(snapshot["task_kind"],task["kind"]) else {
                    throw CoreError("REVIEW_REQUIREMENT_STALE","The applied review requirement identity changed.")
                }
                let revision = try reviewRequirementRevision(snapshot["policy_revision"])
                let rawPolicy = try retainedReviewRequirementPolicy(db,projectID:pid,revision:revision)
                var original = project;original["policy"] = rawPolicy;original["policy_revision"] = revision
                let expected = try currentReviewRequirementSnapshot(project:original,task:task)
                guard hash(Data(try jsonString(snapshot).utf8)) == hash(Data(try jsonString(expected).utf8)) else {
                    throw CoreError("REVIEW_REQUIREMENT_STALE","The applied requirement does not match its immutable policy revision.")
                }
                return ["state":"applied","snapshot":snapshot,"latest_policy_revision":try StoredRecord(project, family: "project").requiredValue("policy_revision")]
            }
        }
        return ["state":"preview","snapshot":try currentReviewRequirementSnapshot(project:project,
            task:task),"latest_policy_revision":try StoredRecord(project, family: "project").requiredValue("policy_revision")]
    }
    private func retainedReviewRequirementPolicy(_ db: Database,projectID pid: String,revision: Int) throws -> JSON {
        let retained = try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns +
            " FROM records WHERE type='policy_revision' AND project_id=CAST(? AS TEXT) AND json_type(data,'$.policy_revision') IN " +
            "('integer','real') AND json_extract(data,'$.policy_revision')=? LIMIT 2",
            arguments:[Data(pid.utf8),revision]).map {try GRDBRecordEnvelopeAdapter.decode($0,
            expectedType:"policy_revision").object}
        guard retained.count == 1,let rawPolicy = retained[0]["policy"] as? JSON,
              reviewIDEqual(retained[0]["project_id"],pid) else {
            throw CoreError("REVIEW_REQUIREMENT_STALE","The applied policy revision is unavailable; do not guess it from current settings.")
        }
        return rawPolicy
    }

    func reviewRequirementRows(_ snapshot: JSON) throws -> [JSON] {
        let rule = try ReviewRequirement.parse(try StoredRecord(snapshot, family: "review requirement snapshot").requiredValue("requirement"))
        var rows: [JSON] = rule.checks.map {
            ["id":"project:review-check:"+hash(Data($0.id.text.utf8)),"text":$0.text,
             "kind":"review_check","sha256":hash(Data($0.text.utf8))]
        }
        rows.append(["id":"project:review-reject-bar","text":rule.rejectBar,"kind":"review_reject_bar","sha256":hash(Data(rule.rejectBar.utf8))])
        return rows
    }
    func reviewRequirementScope(task: JSON,manifest: JSON,attempt: JSON) throws -> ReviewRequirementEvidenceScope {
        let taskRecord = try StoredTaskRecord(task)
        let attemptRecord = try StoredAttemptRecord(attempt)
        let manifestID = try StoredRecord(manifest, family: "manifest").string("id")
        return try .init(projectID:ReviewRequirementID(taskRecord.projectID),taskID:ReviewRequirementID(taskRecord.id),
                         manifestID:ReviewRequirementID(manifestID),reviewAttemptID:ReviewRequirementID(attemptRecord.id))
    }
    /// The only service adapter to pure descriptors: existing scope/ownership/hash
    /// validation runs first, followed by exact-byte identities and actual bytes.
    func classifiedReviewEvidence(_ db: Database,refs: [JSON],task: JSON,manifest: JSON,attempt: JSON,caller: Caller) throws
        -> (refs:[JSON],owned:Bool,descriptors:[ReviewRequirementEvidenceDescriptor]) {
        let taskRecord = try StoredTaskRecord(task)
        let validated = try validateReviewEvidence(db,refs:refs,task:task,manifest:manifest,caller:caller)
        let scope = try reviewRequirementScope(task:task,manifest:manifest,attempt:attempt)
        var descriptors: [ReviewRequirementEvidenceDescriptor] = []
        for ref in refs {
            if let id = ref["artifact_id"] as? String {
                let artifact = try scoped(db,id,taskRecord.projectID,type:"attachment")
                guard reviewIDEqual(artifact["id"],id),reviewIDEqual(artifact["project_id"],task["project_id"]),
                      reviewIDEqual(artifact["task_id"],task["id"]),let path = artifact["path"] as? String else {throw CoreError("EVIDENCE_STALE","Selected evidence bytes or exact identity changed.")}
                // Types need the bytes only up to 16 MiB. A larger object that this command hashed
                // before the writer (CL-71) is not read again; it has no evidence type.
                let bytes: Data, classified: Bool
                if let size = verifiedObjectSize(path,sha256:ref["sha256"] as? String ?? ""),size > 16 * 1024 * 1024 { bytes = Data(); classified = false }
                else {
                    classified = true
                    guard let read = try? managedRead(path,family:"objects",maximum:500 * 1024 * 1024),
                        hash(read) == ref["sha256"] as? String else {throw CoreError("EVIDENCE_STALE",
                        "Selected evidence bytes or exact identity changed.")}
                    bytes = read
                }
                var types = Set<ReviewRequirementEvidenceType>()
                if classified,bytes.count <= 1024 * 1024,String(data:bytes,encoding:.utf8) != nil {types.insert(.textRecord)}
                if classified,reviewIDEqual(artifact["author"],caller.principal),reviewIDEqual(artifact["review_attempt_id"],attempt["id"]),
                   reviewIDEqual(artifact["target_manifest_id"],manifest["id"]),bytes.count <= 65536,
                   String(data:bytes,encoding:.utf8) != nil {types.insert(.reviewerReport)}
                if classified,bytes.count <= 16 * 1024 * 1024,let image = CGImageSourceCreateWithData(bytes as CFData,nil),
                   CGImageSourceGetCount(image) > 0,let properties = CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [CFString:Any],
                   let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                   width.doubleValue > 0,height.doubleValue > 0,width.doubleValue * height.doubleValue <= 64_000_000,
                   CGImageSourceCreateImageAtIndex(image,0,nil) != nil {types.insert(.image)}
                if !types.isEmpty {
                    descriptors.append(try .init(scope:scope,reference:.init(namespace:.artifact,id:ReviewRequirementID(id)),digest:hash(bytes),types:types))
                }
            } else if let id = ref["source_capture_id"] as? String {
                let source = (manifest["evidence"] as? JSON)?["source_capture"] as? JSON ?? [:]
                guard reviewIDEqual(source["id"],id),source["sha256"] as? String == ref["sha256"] as? String else {
                    throw CoreError("REVIEW_TARGET_MISMATCH","Selected source identity differs from the validated exact target.")
                }
                descriptors.append(try .init(scope:scope,reference:.init(namespace:.sourceCapture,
                    id:ReviewRequirementID(id)),digest:try StoredRecord(ref, family: "evidence reference").string("sha256"),
                    types:[.sourceCapture]))
            }
        }
        return (validated.refs,validated.owned,descriptors)
    }
    func reviewRequirementGapSummary(_ db: Database,task: JSON,manifest: JSON,attempt: JSON,
                                    selected: [JSON],caller: Caller) throws -> JSON {
        let state = try reviewRequirementState(db,task:task)
        let snapshot = try StoredRecord(state, family: "review requirement state").object("snapshot")
        let classified = selected.isEmpty ? nil : try classifiedReviewEvidence(db,refs:selected,task:task,manifest:manifest,attempt:attempt,caller:caller)
        return try reviewRequirementGapResult(snapshot:snapshot,task:task,manifest:manifest,attempt:attempt,
                                              selectedCount:selected.count,descriptors:classified?.descriptors ?? [])
    }
    func reviewRequirementGapResult(snapshot: JSON,task: JSON,manifest: JSON,attempt: JSON,
                                    selectedCount: Int,descriptors: [ReviewRequirementEvidenceDescriptor]) throws -> JSON {
        let rule = try ReviewRequirement.parse(try StoredRecord(snapshot, family: "review requirement snapshot").requiredValue("requirement"))
        let gaps = ReviewRequirementEvidenceGaps.project(rule,scope:try reviewRequirementScope(task:task,manifest:manifest,attempt:attempt),selected:descriptors)
        return ["state":"selected_validated","policy_revision":try StoredRecord(snapshot, family: "review requirement snapshot").requiredValue("policy_revision"),
            "requirement_sha256":try StoredRecord(snapshot, family: "review requirement snapshot").requiredValue("sha256"),
                "required_evidence_types":ReviewRequirementEvidenceType.allCases.filter {rule.requiredEvidenceTypes.contains($0)}.map(\.rawValue),
                "missing_evidence_types":gaps.missing.map(\.rawValue),"selected_reference_count":selectedCount,
                "ambiguous_reference_count":gaps.ambiguousReferences.count,"qualification":"Byte/provenance classes only; never execution success, native observation or approval."]
    }
    func reviewRequirementPreflight(_ db: Database,params: JSON,task: JSON,manifest: JSON,caller: Caller) throws -> JSON {
        let state = try reviewRequirementState(db,task:task)
        let snapshot = try StoredRecord(state, family: "review requirement state").object("snapshot")
        let rule = try ReviewRequirement.parse(try StoredRecord(snapshot, family: "review requirement snapshot").requiredValue("requirement"))
        let required = ReviewRequirementEvidenceType.allCases.filter {rule.requiredEvidenceTypes.contains($0)}.map(\.rawValue)
        guard let raw = params["evidence_refs"] else {
            return ["state":state["state"] as? String == "preview" ? "claim_required" : "selection_required",
                    "required_evidence_types":required,"missing_evidence_types":required,"availability_evaluated":false]
        }
        guard let refs = raw as? [JSON],refs.count <= 100 else {throw CoreError("INVALID_INPUT","Select at most 100 evidence references.")}
        guard let aid = task["active_attempt_id"] as? String else {throw CoreError("REVIEW_CLAIM_REQUIRED","Claim this exact review before validating selected evidence.")}
        let attempt = try scoped(db,aid,try StoredTaskRecord(task).projectID,type:"attempt")
        guard state["state"] as? String == "applied",reviewIDEqual(attempt["principal"],caller.principal),
              reviewIDEqual(attempt["manifest_id"],manifest["id"]) else {throw CoreError("FORBIDDEN","Only this exact active reviewer selects its review evidence.")}
        return try reviewRequirementGapSummary(db,task:task,manifest:manifest,attempt:attempt,selected:refs,caller:caller)
    }
}
