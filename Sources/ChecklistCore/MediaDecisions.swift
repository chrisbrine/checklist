import Foundation
import CoreFoundation
import GRDB

extension CommandRouter {
    func mediaDecision(_ db: Database,_ p: JSON,_ c: Caller,project pid: String,method: String,validateOnly: Bool = false) throws -> JSON {
        if method == "media_suggest" { guard !c.isOwner else { throw CoreError("FORBIDDEN","Suggestions retain actual worker provenance.") } }
        else { try owner(c) }
        let round = try scoped(db,try text(p,"round_id"),pid,type:"media_round")
        try mediaObserve(db,p,round:round,caller:c);let manifest = try mediaObservedManifest(db,p,round:round)
        guard let selected = p["items"] as? [JSON],!selected.isEmpty,selected.count <= 200,Set(selected.compactMap {$0["item_id"] as? String}).count == selected.count else { throw CoreError("INVALID_INPUT","Select 1 to 200 distinct exact item bases.") }
        var input = p,adopted: JSON?
        if method == "media_adopt_suggestion" {
            guard selected.count == 1 else { throw CoreError("INVALID_INPUT","Adopt one exact suggestion at a time.") }
            adopted = try scoped(db,try text(p,"suggestion_id"),pid,type:"media_suggestion")
            guard adopted?["round_id"] as? String == round["id"] as? String,adopted?["item_id"] as? String == selected[0]["item_id"] as? String,adopted?["target_id"] as? String == selected[0]["target_id"] as? String,adopted?["review_basis_signature"] as? String == selected[0]["review_basis_signature"] as? String else { throw CoreError("MEDIA_BASIS_CHANGED","A suggestion must still name this exact current target and basis.") }
            for key in ["disposition","winner_id","none_fit","note","no_follow_up_reason"] { input[key] = adopted?[key] }
        }
        let disposition = try text(input,"disposition",max:32)
        guard ["accepted","needs_look","changes_requested","excluded"].contains(disposition) else { throw CoreError("INVALID_INPUT","Choose an explicit media disposition.") }
        if disposition == "excluded" { _ = try text(input,"note",max:4000) }
        for key in ["note","no_follow_up_reason"] where input[key] != nil { _ = try text(input,key,max:4000) }
        var validated: [(JSON,JSON,String?,Bool)] = []
        for entry in selected {
            let required: Set<String> = ["item_id","expected_revision","target_id","review_basis_signature"]
            guard required.isSubset(of:Set(entry.keys)),Set(entry.keys).isSubset(of:required.union(["winner_id","none_fit"])) else { throw CoreError("INVALID_INPUT","A decision needs the exact item revision, published target and basis.") }
            let item = try scoped(db,try text(entry,"item_id"),pid,type:"media_item");try mediaRevision(entry,item)
            guard item["round_id"] as? String == round["id"] as? String,let member = (manifest["items"] as! [JSON]).first(where:{$0["item_id"] as? String == item["id"] as? String}),member["target_id"] as? String == entry["target_id"] as? String,member["review_basis_signature"] as? String == entry["review_basis_signature"] as? String else { throw CoreError("MEDIA_BASIS_CHANGED","The published item target or basis changed.") }
            let target = try scoped(db,member["target_id"] as! String,pid,type:"media_item_target")
            guard bool(target,"publication_ready") else { throw CoreError("MEDIA_UNRESOLVED","Required material must be captured before deciding.") }
            let ids = strings(target,"candidate_ids")
            if method == "media_adopt_suggestion",entry["winner_id"] != nil || entry["none_fit"] != nil { throw CoreError("INVALID_INPUT","Adoption takes the exact suggestion choice; use a new owner decision to change it.") }
            for source in [input,entry] {
                if let raw = source["winner_id"],!(raw is String) { throw CoreError("INVALID_INPUT","A winner must be an exact candidate ID.") }
                if let raw = source["none_fit"] {
                    guard let n = raw as? NSNumber,CFGetTypeID(n) == CFBooleanGetTypeID() else { throw CoreError("INVALID_INPUT","none_fit must be a Boolean.") }
                }
            }
            if let local = entry["none_fit"] as? Bool,let common = input["none_fit"] as? Bool,local != common { throw CoreError("INVALID_INPUT","A selection has conflicting none-fit choices.") }
            let noneFit = method == "media_adopt_suggestion" ? bool(input,"none_fit") : (entry["none_fit"] as? Bool ?? bool(input,"none_fit"))
            let winner = method == "media_adopt_suggestion" ? input["winner_id"] as? String : entry["winner_id"] as? String ?? input["winner_id"] as? String
            if let explicit = entry["winner_id"] as? String,let common = input["winner_id"] as? String,explicit != common { throw CoreError("INVALID_INPUT","A selection has conflicting winner IDs.") }
            guard !noneFit || disposition == "changes_requested" else { throw CoreError("INVALID_INPUT","None fit is an explicit Changes requested action.") }
            if disposition == "changes_requested",ids.count > 1,!noneFit { throw CoreError("INVALID_INPUT","Best-of-N changes require explicit none_fit=true.") }
            if disposition == "accepted" {
                guard let winner,ids.contains(winner) else { throw CoreError("INVALID_INPUT","Acceptance names the exact single winning candidate.") }
            } else if winner != nil { throw CoreError("INVALID_INPUT","Only acceptance selects a winner.") }
            validated.append((item,target,winner,noneFit))
        }
        if validateOnly { return [:] }
        var results: [JSON] = []
        for (original,target,winner,noneFit) in validated {
            var fields: JSON = ["round_id":round["id"]!,"item_id":original["id"]!,"target_id":target["id"]!,"manifest_id":manifest["id"]!,"manifest_digest":manifest["digest"]!,"type_revision_id":target["type_revision_id"]!,"context_id":round["context_id"]!,"context_signature":target["context_signature"]!,"content_signature":target["content_signature"]!,"material_definition_signature":target["material_definition_signature"]!,"candidate_ids":target["candidate_ids"]!,"review_basis_signature":target["review_basis_signature"]!,"review_basis_base64":target["review_basis_base64"]!,"disposition":disposition]
            fields["item_revision"] = original["revision"]
            fields["selection_outcome"] = winner != nil ? "winner" : noneFit ? "none_fit" : "unselected"
            if noneFit { fields["none_fit"] = true }
            if let winner {
                fields["winner_id"] = winner
                fields["not_selected_candidate_ids"] = strings(target,"candidate_ids").filter {$0 != winner}
            }
            for key in ["note","no_follow_up_reason"] where input[key] != nil { fields[key] = try text(input,key,max:4000) }
            var refs = [mediaRef("media_round",round),mediaRef("media_item",original),mediaRef("media_item_target",target),mediaRef("media_round_manifest",manifest),["type":"media_review_context","id":round["context_id"]!,"revision":1],["type":"media_review_type_revision","id":target["type_revision_id"]!,"revision":1]]
            refs += strings(target,"candidate_ids").map {["type":"media_candidate","id":$0,"revision":1]}
            if let adopted { fields["adopted_suggestion_id"] = adopted["id"];refs.append(mediaRef("media_suggestion",adopted)) }
            if let prior = original["last_decision_id"] as? String,method != "media_suggest" { fields["supersedes_decision_id"] = prior;refs.append(["type":"media_owner_decision","id":prior,"revision":1]) }
            if let operationID = input["bulk_operation_id"] as? String {
                fields["bulk_operation_id"] = operationID;fields["bulk_chunk_id"] = input["bulk_chunk_id"];fields["bulk_command_id"] = input["bulk_command_id"]
                refs.append(["type":"media_bulk_operation","id":operationID,"revision":1])
            }
            let decision = mediaRecord(fields,project:pid,caller:c,references:refs)
            try mediaWrite(db,decision,type:method == "media_suggest" ? "media_suggestion" : "media_owner_decision");results.append(decision)
            if method != "media_suggest" {
                var item = original;item["last_decision_id"] = decision["id"];item["record_references"] = (item["record_references"] as! [JSON]) + [mediaRef("media_owner_decision",decision)]
                try mediaWrite(db,revised(item),type:"media_item")
            }
        };return ["decisions":results]
    }
}

extension CommandRouter {
    /// Receipts are separate immutable records. The operation itself never changes,
    /// including after partial success or a refresh of only its unresolved chunks.
    func mediaBulkRelated(_ db: Database,operation: JSON,type: String,field: String) throws -> [JSON] {
        // At most five chunks/successors can belong to a 1,000-item operation.
        // Filter before decoding instead of reading all retained project history.
        let rows = try Row.fetchAll(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE type=CAST(? AS TEXT) AND project_id=CAST(? AS TEXT) AND json_extract(data,'$." + field + "')=CAST(? AS TEXT) COLLATE BINARY ORDER BY rowid LIMIT 6",arguments:[Data(type.utf8),Data((operation["project_id"] as! String).utf8),Data((operation["id"] as! String).utf8)])
        guard rows.count <= 5 else { throw CoreError("MEDIA_CAPTURE_INCOMPLETE","A bounded bulk operation has excess related records.") }
        return try rows.map {try GRDBRecordEnvelopeAdapter.decode($0,expectedType:type).object}
    }
    func mediaBulkReceipts(_ db: Database,operation: JSON) throws -> [JSON] {
        try mediaBulkRelated(db,operation:operation,type:"media_bulk_chunk",field:"operation_id")
    }
    func mediaBulkSuccessors(_ db: Database,operation: JSON) throws -> [JSON] {
        try mediaBulkRelated(db,operation:operation,type:"media_bulk_operation",field:"supersedes_operation_id")
    }
    func mediaBulkView(_ db: Database,operation: JSON) throws -> JSON {
        let receipts = try mediaBulkReceipts(db,operation:operation)
        let successors = try mediaBulkSuccessors(db,operation:operation)
        var result = operation,committed: [String] = [],failed: [String] = [],uncommitted: [String] = [],superseded: [String] = []
        result["chunk_results"] = (operation["chunks"] as! [JSON]).map { chunk -> JSON in
            var row = chunk
            let ids = (chunk["items"] as! [JSON]).map {$0["item_id"] as! String}
            let replacements = successors.filter { !Set(ids).isDisjoint(with:strings($0,"selected_item_ids")) }
            if let receipt = receipts.first(where:{$0["id"] as? String == chunk["id"] as? String}) {
                row["receipt"] = receipt;row["state"] = receipt["state"]
                if receipt["state"] as? String == "committed" { committed += ids }
                else if replacements.isEmpty { failed += ids }
            } else { row["state"] = "uncommitted";if replacements.isEmpty { uncommitted += ids } }
            if !replacements.isEmpty {
                row["state"] = "superseded";superseded += ids
                row["successor_operation_ids"] = replacements.map {$0["id"]!}
            }
            return row
        }
        result["committed_item_ids"] = committed;result["failed_item_ids"] = failed
        result["uncommitted_item_ids"] = uncommitted;result["superseded_item_ids"] = superseded
        result["counts"] = ["selected":strings(operation,"selected_item_ids").count,"committed":committed.count,"failed":failed.count,"uncommitted":uncommitted.count,"superseded":superseded.count]
        return result
    }
    func mediaBulkCommand(_ db: Database,method: String,p: JSON,c: Caller,project pid: String) throws -> JSON {
        try owner(c)
        if method == "media_bulk_prepare" {
            guard let selected = p["items"] as? [JSON],!selected.isEmpty,selected.count <= 1000,
                  Set(selected.compactMap {$0["item_id"] as? String}).count == selected.count else {
                throw CoreError("INVALID_INPUT","Freeze 1 to 1,000 distinct exact item selections, in their original order.")
            }
            // Validate every chunk before persisting the operation; this writes nothing.
            var chunks: [JSON] = []
            for offset in stride(from:0,to:selected.count,by:200) {
                let members = Array(selected[offset..<min(offset+200,selected.count)])
                var input = p;input["items"] = members
                _ = try mediaDecision(db,input,c,project:pid,method:"media_decide",validateOnly:true)
                chunks.append(["id":uuid(),"command_id":uuid(),"items":members])
            }
            let round = try scoped(db,try text(p,"round_id"),pid,type:"media_round")
            let manifest = try mediaObservedManifest(db,p,round:round)
            let action = p.filter {["disposition","winner_id","none_fit","note","no_follow_up_reason"].contains($0.key)}
            var refs = [mediaRef("media_round",round),mediaRef("media_round_manifest",manifest),["type":"media_review_context","id":round["context_id"]!,"revision":1]]
            for entry in selected {
                refs.append(["type":"media_item","id":entry["item_id"]!])
                refs.append(["type":"media_item_target","id":entry["target_id"]!,"revision":1])
            }
            var fields: JSON = ["round_id":round["id"]!,"manifest_id":manifest["id"]!,"context_id":round["context_id"]!,"selection":selected,"selected_item_ids":selected.map {$0["item_id"]!},"action":action,"chunks":chunks,"prepare_command_id":p["command_id"]!]
            // The original observation is retained, not recreated from a changed filter
            // or current round at apply time. A different owner scope cannot replay it.
            fields["intent"] = p.filter {!["command_id","project_id","supersedes_operation_id"].contains($0.key)}
            fields["intent_digest"] = try MediaCanonical.signature(fields["intent"]!)
            if p["supersedes_operation_id"] != nil {
                let prior = try scoped(db,try text(p,"supersedes_operation_id"),pid,type:"media_bulk_operation")
                guard prior["round_id"] as? String == round["id"] as? String,
                      try MediaCanonical.bytes(prior["action"]!) == MediaCanonical.bytes(action) else {
                    throw CoreError("INVALID_INPUT","A remainder refresh retains the original round and intended action.")
                }
                let view = try mediaBulkView(db,operation:prior)
                let eligible = Set(strings(view,"failed_item_ids") + strings(view,"uncommitted_item_ids"))
                let ids = Set(selected.map {$0["item_id"] as! String})
                guard ids.isSubset(of:eligible) else { throw CoreError("MEDIA_BULK_COMMITTED","Refresh only failed or uncommitted original chunks; reconcile committed receipts first.") }
                for chunk in prior["chunks"] as! [JSON] {
                    let members = Set((chunk["items"] as! [JSON]).map {$0["item_id"] as! String})
                    guard members.isDisjoint(with:ids) || members.isSubset(of:ids) else { throw CoreError("INVALID_INPUT","Refresh complete unresolved chunks, preserving their original selected set.") }
                }
                fields["supersedes_operation_id"] = prior["id"];refs.append(mediaRef("media_bulk_operation",prior))
                refs += try mediaBulkReceipts(db,operation:prior).map {mediaRef("media_bulk_chunk",$0)}
            }
            let operation = mediaRecord(fields,project:pid,caller:c,references:refs)
            try mediaWrite(db,operation,type:"media_bulk_operation")
            return try mediaBulkView(db,operation:operation)
        }
        guard method == "media_bulk_apply" else { throw CoreError("UNSUPPORTED_METHOD","Internal bulk command is unavailable.") }
        let operation = try scoped(db,try text(p,"operation_id"),pid,type:"media_bulk_operation")
        let chunkID = try text(p,"chunk_id")
        guard let chunk = (operation["chunks"] as! [JSON]).first(where:{$0["id"] as? String == chunkID}) else { throw CoreError("INVALID_INPUT","Use an original chunk ID from this operation.") }
        guard p["command_id"] as? String == chunk["command_id"] as? String else { throw CoreError("IDEMPOTENCY_CONFLICT","Reconcile or retry this chunk with its original command_id.") }
        guard !(try mediaBulkReceipts(db,operation:operation)).contains(where:{$0["id"] as? String == chunkID}) else { throw CoreError("MEDIA_BULK_COMMITTED","The chunk already has an immutable receipt. Read it; a failed chunk needs a refreshed operation.") }
        let selected = chunk["items"] as! [JSON],ids = selected.map {$0["item_id"] as! String}
        guard !(try mediaBulkSuccessors(db,operation:operation)).contains(where:{!Set(ids).isDisjoint(with:strings($0,"selected_item_ids"))}) else {
            throw CoreError("MEDIA_BULK_SUPERSEDED","This remainder has a refreshed operation. The original intent cannot be applied again.")
        }
        var input = operation["intent"] as! JSON;input["items"] = selected
        var failure: CoreError?
        do { _ = try mediaDecision(db,input,c,project:pid,method:"media_decide",validateOnly:true) }
        catch let error as CoreError where ["REVISION_CONFLICT","MEDIA_CONTEXT_CHANGED","MEDIA_CONTEXT_ATTENTION","MEDIA_MANIFEST_CHANGED","MEDIA_BASIS_CHANGED","MEDIA_UNRESOLVED"].contains(error.code) { failure = error }
        var decisions: [JSON] = []
        if failure == nil {
            input["bulk_operation_id"] = operation["id"];input["bulk_chunk_id"] = chunkID;input["bulk_command_id"] = p["command_id"]
            decisions = try mediaDecision(db,input,c,project:pid,method:"media_decide")["decisions"] as! [JSON]
        }
        var fields: JSON = ["operation_id":operation["id"]!,"round_id":operation["round_id"]!,"command_id":p["command_id"]!,"selected_item_ids":ids,"state":failure == nil ? "committed" : "failed","decision_ids":decisions.map {$0["id"]!},"committed_item_ids":failure == nil ? ids : [],"failed_item_ids":failure == nil ? [] : ids,"uncommitted_item_ids":[String]()]
        if let failure { fields["error"] = ["code":failure.code] }
        var refs = [mediaRef("media_bulk_operation",operation)] + decisions.map {mediaRef("media_owner_decision",$0)}
        refs += selected.map {["type":"media_item_target","id":$0["target_id"]!,"revision":1]}
        var receipt = mediaRecord(fields,project:pid,caller:c,references:refs);receipt["id"] = chunkID
        try mediaWrite(db,receipt,type:"media_bulk_chunk")
        return ["id":chunkID,"chunk":receipt,"decisions":decisions]
    }
}
