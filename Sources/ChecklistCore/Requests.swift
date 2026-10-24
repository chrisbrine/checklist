import Foundation
import GRDB

extension CommandRouter {
    func requestWrite(_ db: Database,_ p: JSON,_ c: Caller,_ method: String) throws -> JSON {
        let pid = try scope(db,p,c,write:true)
        if method == "human_request_create" {
            try worker(c)
            var t = try task(db,p,pid)
            var r: JSON = ["id":uuid(),"project_id":pid,"task_id":t["id"]!,"title":"Needs your input","questions":[],"file_requests":[],"blocking":true,"state":"pending","requester":c.principal,"requester_session_id":c.sessionID ?? "human","requester_authorization_generation":try callerSessionGeneration(db,c,project:pid),"revision":1,"form_revision":1,"created_at":now(),"responses":[]]
            try applyRequestForm(db,request:&r,params:p)
            try validateCoveredAnswers(db,request:&r,params:p)
            try ensureSingleBlockingRequest(db,request:r)
            try bindHumanGate(db,request:&r,task:&t,params:p)
            r["form_identity"] = try requestFormIdentity(r)
            try save(db,r,type:"request")
            try event(db,caller:c,project:pid,entity:t["id"] as? String,kind:"human_request_created",data:["request_id":r["id"]!,"form_revision":1])
            return r
        }
        var r = try scoped(db,try text(p,"request_id"),pid,type:"request")
        try revision(p,r)
        guard r["state"] as? String == "pending" else { throw CoreError("REQUEST_CHANGED","This request is no longer pending.") }
        if method == "human_request_snooze" {
            try requireAgentEditAuthority(db,project:try record(db,pid,type:"project"),caller:c)
            // A personal inbox preference, with no due time, task transition or scheduled pickup.
            r["owner_snoozed"] = bool(p,"snoozed",default:true)
            r = revised(r); try save(db,r,type:"request")
            try event(db,caller:c,project:pid,entity:r["task_id"] as? String,kind:"human_request_visibility_changed",data:["request_id":r["id"]!,"snoozed":r["owner_snoozed"]!,"origin":c.isOwner ? "human_ui" : "agent"])
            return r
        }
        if method == "human_request_cancel" || method == "human_request_revise" {
            try requestEditor(db,request:r,caller:c)
            if method == "human_request_cancel" {
                try cancelHumanGate(db,request:r)
                r["state"] = "canceled"; r["cancellation_reason"] = try text(p,"reason",max:8000,required:false)
                r = revised(r); try save(db,r,type:"request")
                try event(db,caller:c,project:pid,entity:r["task_id"] as? String,kind:"human_request_canceled",data:["request_id":r["id"]!])
                return r
            }
            let patch = p["patch"] as? JSON ?? [:]
            guard !patch.isEmpty,Set(patch.keys).isSubset(of:Set(Self.requestFormKeys + ["review_request_id","target_manifest_id"])) else { throw CoreError("INVALID_INPUT","Revise only the request's form and exact target.") }
            var history = r["form_history"] as? [JSON] ?? []
            var old = requestForm(r)
            old["form_revision"] = int(r,"form_revision",default:1); old["form_identity"] = try requestFormIdentity(r); old["replaced_at"] = now(); old["reason"] = try text(p,"reason",max:8000,required:false)
            history.append(old)
            var candidate = r
            try applyRequestForm(db,request:&candidate,params:patch)
            try ensureSingleBlockingRequest(db,request:candidate)
            // Release and rebind inside the same store transaction. A failed new binding rolls
            // back both the old gate release and the form, so verification is never lost.
            try cancelHumanGate(db,request:r)
            var t = try scoped(db,r["task_id"] as! String,pid,type:"task")
            var binding: JSON = [:]
            if let explicit = patch["review_request_id"] as? String { binding["review_request_id"] = explicit }
            else if let existing = r["review_request_id"] as? String,patch["target_attachment_id"] == nil,patch["target_manifest_id"] == nil { binding["review_request_id"] = existing }
            if let mid = patch["target_manifest_id"] as? String { binding["target_manifest_id"] = mid }
            for key in ["review_request_id","target_manifest_id","gate","approval_question_id","gate_outcome","gate_verdict_id"] { candidate.removeValue(forKey:key) }
            try bindHumanGate(db,request:&candidate,task:&t,params:binding)
            candidate["form_history"] = history; candidate["form_revision"] = int(r,"form_revision",default:1)+1
            candidate["form_identity"] = try requestFormIdentity(candidate)
            candidate["owner_snoozed"] = false
            candidate = revised(candidate); try save(db,candidate,type:"request")
            try event(db,caller:c,project:pid,entity:r["task_id"] as? String,kind:"human_request_revised",data:["request_id":r["id"]!,"form_revision":candidate["form_revision"]!,"prior_form_identity":old["form_identity"]!,"form_identity":candidate["form_identity"]!])
            return candidate
        }
        try owner(c)
        let action = p["response"] as? String ?? p["action"] as? String ?? "answered"
        guard ["answered","send","clarification","clarify","cannot_do"].contains(action) else { throw CoreError("INVALID_INPUT","Choose Answer, Clarify or Cannot do.") }
        let currentIdentity = try requestFormIdentity(r)
        if let identity = p["form_identity"] as? String,identity != currentIdentity { throw CoreError("REQUEST_CHANGED","This answer belongs to an older form. Its draft has not been sent.") }
        let isAnswer = ["answered","send"].contains(action)
        if !isAnswer { _ = try text(p,"explanation",max:16000) }
        let answers = try validatedRequestAnswers(r,params:p,requireComplete:isAnswer)
        let files = try preparedHumanRequestFiles(r,params:p)
        let complete = isAnswer && !answers.contains { $0["result"] as? String == "not_checked" }
        if complete,let target = r["target_attachment_id"] as? String {
            if let mid = r["target_manifest_id"] as? String {
                let currentTask = try scoped(db,r["task_id"] as! String,pid,type:"task")
                _ = try validateManifestTarget(db,task:currentTask,manifestID:mid)
            }
            let artifact = try scoped(db,target,pid,type:"attachment")
            guard artifact["availability"] as? String == "available",artifact["sha256"] as? String == r["target_sha256"] as? String,p["target_sha256"] as? String == r["target_sha256"] as? String,let path = artifact["path"] as? String,objectBytesMatch(path,sha256:r["target_sha256"] as? String ?? "") else { throw CoreError("TARGET_CHANGED","Inspect the current original and submit its exact target hash. Your draft has not been sent.") }
        }
        // Gate answers are verdicts. Fence the observed task/directions before any
        // managed file import or response mutation; ordinary answers stay available.
        if complete,r["review_request_id"] != nil { try validateHumanGateDirection(db,request:r,params:p,caller:c) }
        let inspectedImages = try requestImageInspections(db, params:p, request:r, answers:answers, complete:complete)
        // File selection is evidence only of a selected file. It never manufactures a run/check result.
        var recordedFiles: [JSON] = []
        for var file in files {
            if complete,file["mode"] as? String == "managed" {
                var refs: [JSON] = []
                for path in strings(file,"paths") {
                    let attachment = try commitHumanAnswerImport(db,params:p,request:r,file:file,path:path,caller:c)
                    refs.append(["artifact_id":attachment["id"]!,"sha256":attachment["sha256"]!])
                }
                file["artifact_refs"] = refs
            }
            recordedFiles.append(file)
        }
        var response: JSON = ["id":uuid(),"origin":"human_ui","author_display":"You","source_session_id":"human","source_authorization_generation":"human","form_revision":int(r,"form_revision",default:1),"form_identity":currentIdentity,"answers":answers,"files":recordedFiles,"explanation":try text(p,"explanation",max:16000,required:false),"action":action,"complete":complete,"created_at":now()]
        response["inspected_images"] = inspectedImages
        if complete,var gate = try recordHumanGate(db,request:r,answers:answers,responseID:response["id"] as! String,params:p,caller:c) {
            gate["inspected_images"] = inspectedImages
            var checks = gate["checks"] as? [JSON] ?? []
            for i in checks.indices where checks[i]["label"] as? String == "Owner inspected exact original" { checks[i]["label"] = "Owner decision on exact original" }
            gate["checks"] = checks; try save(db,gate,type:"review")
            r["gate_outcome"] = gate["verdict"]; r["gate_verdict_id"] = gate["id"]
        }
        var responses = r["responses"] as? [JSON] ?? []; responses.append(response); r["responses"] = responses
        r["state"] = complete ? "answered" : "pending"; r["owner_snoozed"] = false; r = revised(r)
        let message = try notifyHumanResponse(db,request:r,response:response,caller:c)
        r["continuation_message_id"] = message["id"]
        r["continuation_deliveries"] = message["deliveries"] ?? []
        r["continuation_delivery"] = (message["deliveries"] as? [JSON] ?? []).isEmpty ? "available_for_current_handlers_or_next_pickup" : "queued_for_pickup"
        try save(db,r,type:"request")
        try event(db,caller:c,project:pid,entity:r["task_id"] as? String,kind:"human_request_answered",data:["request_id":r["id"]!,"complete":complete,"response_id":response["id"]!,"form_revision":int(r,"form_revision",default:1)])
        try db.execute(sql:"DELETE FROM metadata WHERE key=?",arguments:[try pendingStorageCommandKey(principal:c.principal,command:p["command_id"] as! String)])
        r["message"] = message
        let counts = try ownerNeedsYouCounts(db)
        r["needs_you_count"] = counts.requests + counts.tasks
        return r
    }

    static let requestSupersedeKeys = ["supersedes_answer_id","supersede_reason"]
    func normalizedRequestText(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator:" ")
    }
    func validateCoveredAnswers(_ db: Database,request: inout JSON,params: JSON) throws {
        let questions = request["questions"] as? [JSON] ?? []
        let texts = Set(([request["title"] as? String ?? ""] + questions.compactMap {$0["prompt"] as? String}).map(normalizedRequestText).filter {!$0.isEmpty})
        let approval = questions.contains {$0["type"] as? String == "approval"}
        var matches: [JSON] = []
        for earlier in try records(db,type:"request",project:request["project_id"] as? String) {
            for response in earlier["responses"] as? [JSON] ?? [] where ["answered","send"].contains(response["action"] as? String ?? "") {
                // A response stays tied to the form the owner actually answered.
                guard let form = ((earlier["form_history"] as? [JSON] ?? []) + [earlier]).first(where: { int($0,"form_revision",default:1) == int(response,"form_revision",default:1) }) else { continue }
                let priorQuestions = form["questions"] as? [JSON] ?? []
                let responseAnswers = response["answers"] as? [JSON] ?? []
                let answeredQuestions = priorQuestions.filter { question in
                    guard let answer = responseAnswers.first(where: {$0["question_id"] as? String == question["id"] as? String}) else { return false }
                    switch question["type"] as? String ?? "text" {
                    case "text": return !(answer["text"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
                    case "choice": return !strings(answer,"option_ids").isEmpty || !(answer["custom_text"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
                    case "approval": return ["approved","changes_requested","declined"].contains(answer["result"] as? String ?? "")
                    case "check": return ["passed","failed","declined"].contains(answer["result"] as? String ?? "")
                    default: return false
                    }
                }
                guard !answeredQuestions.isEmpty else { continue }
                let titleMatch = texts.contains(normalizedRequestText(form["title"] as? String ?? ""))
                let matchingQuestions = answeredQuestions.filter {
                    texts.contains(normalizedRequestText($0["prompt"] as? String ?? "")) ||
                    (approval && earlier["task_id"] as? String == request["task_id"] as? String && $0["type"] as? String == "approval")
                }
                guard titleMatch || !matchingQuestions.isEmpty else { continue }
                let task = try scoped(db,earlier["task_id"] as! String,request["project_id"] as! String,type:"task")
                let coveredQuestions = titleMatch ? answeredQuestions : matchingQuestions
                let coveredIDs = Set(coveredQuestions.compactMap {$0["id"] as? String})
                let answers = responseAnswers.filter { coveredIDs.contains($0["question_id"] as? String ?? "") }
                let summary = String((try jsonString(["answers":answers,"files":response["files"] ?? [],"explanation":response["explanation"] ?? ""])).prefix(1000))
                matches.append(["request_id":earlier["id"]!,"answer_id":response["id"] ?? NSNull(),"task_id":task["id"]!,"key":task["key"] ?? "","title":form["title"] ?? "",
                    "matching_question_text":coveredQuestions.compactMap {$0["prompt"] as? String}.joined(separator:"; "),"answers":answers,"answer_summary":summary,"answered_at":response["created_at"] ?? ""])
            }
        }
        if params["supersedes_answer_id"] != nil || params["supersede_reason"] != nil {
            let id = try text(params,"supersedes_answer_id",max:4000),reason = try text(params,"supersede_reason",max:4000)
            guard matches.contains(where: {$0["answer_id"] as? String == id || $0["request_id"] as? String == id}) else { throw CoreError("INVALID_INPUT","supersedes_answer_id must name a matching earlier answer or its request.") }
            request["supersedes_answer_id"] = id; request["supersede_reason"] = reason
            return
        }
        guard matches.isEmpty else {
            let descriptions = matches.map { "Request \($0["request_id"]!), answer \($0["answer_id"]!), ticket \($0["task_id"]!) \($0["key"]!) \"\($0["title"]!)\": \($0["matching_question_text"]!); answer \($0["answer_summary"]!); answered \($0["answered_at"]!)." }
            throw CoreError("COVERED_BY_EARLIER_ANSWER","Earlier owner answers cover this request. " + descriptions.joined(separator:" ") + " Supply supersedes_answer_id and a non-empty supersede_reason explaining what changed.",details:["matches":matches])
        }
    }

    static let requestFormKeys = ["title","explanation","questions","file_requests","command","blocking","target_attachment_id"]
    func requestForm(_ r: JSON) -> JSON {
        var form: JSON = [:]
        for key in Self.requestFormKeys + ["target_sha256","review_request_id","target_manifest_id"] { if let value = r[key] { form[key] = value } }
        return form
    }
    func requestFormIdentity(_ r: JSON) throws -> String { hash(Data((try jsonString(requestForm(r))).utf8)) }
    func requestEditor(_ db: Database,request: JSON,caller: Caller) throws {
        try worker(caller)
        guard !caller.isOwner else { return }
        guard request["requester"] as? String == caller.principal,request["requester_session_id"] as? String == caller.sessionID,request["requester_authorization_generation"] as? String == (try callerSessionGeneration(db,caller,project:request["project_id"] as! String)) else { throw CoreError("FORBIDDEN","Only the current original requester or the owner can revise or cancel this request.") }
    }
    func ensureSingleBlockingRequest(_ db: Database,request: JSON) throws {
        if bool(request,"blocking"),try records(db,type:"request",project:request["project_id"] as? String).contains(where: {$0["id"] as? String != request["id"] as? String && $0["task_id"] as? String == request["task_id"] as? String && bool($0,"blocking") && $0["state"] as? String == "pending"}) { throw CoreError("BLOCKING_REQUEST_EXISTS","Revise the existing pending request instead of creating another blocker.") }
    }
    func applyRequestForm(_ db: Database,request: inout JSON,params: JSON) throws {
        for key in Self.requestFormKeys where params[key] != nil { request[key] = params[key] }
        request["title"] = try text(request,"title",max:4000)
        try requestBooleans(request,keys:["blocking"])
        _ = try text(request,"explanation",max:16000,required:false)
        guard request["questions"] is [JSON],request["file_requests"] is [JSON] else { throw CoreError("INVALID_INPUT","Questions and file requests must be typed lists.") }
        let questions = request["questions"] as! [JSON],files = request["file_requests"] as! [JSON]
        guard !questions.isEmpty || !files.isEmpty,questions.count <= 30,files.count <= 30 else { throw CoreError("INVALID_INPUT","Add at least one question or file request, with at most 30 of each.") }
        try uniqueRequestIDs(questions,key:"id"); try uniqueRequestIDs(files,key:"id")
        for q in questions {
            _ = try text(q,"prompt",max:4000)
            guard q["type"] == nil || q["type"] is String else { throw CoreError("INVALID_INPUT","Question type must be text.") }
            let type = q["type"] as? String ?? "text"
            guard ["text","choice","approval","check"].contains(type) else { throw CoreError("INVALID_INPUT","Unsupported question type.") }
            try requestBooleans(q,keys:["required","multiple","allow_custom"])
            if type == "choice" {
                guard let options = q["options"] as? [JSON],options.count <= 100,!options.isEmpty || bool(q,"allow_custom") else { throw CoreError("INVALID_INPUT","A choice needs options or a permitted custom answer.") }
                try uniqueRequestIDs(options,key:"id"); for option in options { _ = try text(option,"label",max:4000) }
            }
            if q["command"] != nil { try validateRequestCommand(q["command"]) }
        }
        for file in files {
            _ = try text(file,"prompt",max:4000)
            guard (file["kind"] == nil || file["kind"] is String),(file["selection"] == nil || file["selection"] is String),["file","directory","either"].contains(file["kind"] as? String ?? file["selection"] as? String ?? "either") else { throw CoreError("INVALID_INPUT","Choose a file, directory or either selection.") }
            try requestBooleans(file,keys:["required","multiple","optional_explanation"])
        }
        if request["command"] != nil { try validateRequestCommand(request["command"]) }
        if let value = params["target_attachment_id"] {
            if value is NSNull || (value as? String) == "" { request.removeValue(forKey:"target_attachment_id"); request.removeValue(forKey:"target_sha256") }
            else {
                guard let id = value as? String else { throw CoreError("INVALID_INPUT","The approval target must be an attachment ID.") }
                let attachment = try scoped(db,id,request["project_id"] as! String,type:"attachment")
                guard attachment["task_id"] as? String == request["task_id"] as? String,attachment["availability"] as? String == "available",attachment["mode"] as? String == "managed" else { throw CoreError("TARGET_CHANGED","Choose an available immutable attachment on this ticket.") }
                request["target_sha256"] = attachment["sha256"]
            }
        }
    }
    func uniqueRequestIDs(_ entries: [JSON],key: String) throws {
        let ids = try entries.map { try text($0,key,max:100) }
        guard Set(ids).count == entries.count else { throw CoreError("INVALID_INPUT","Form entries need unique IDs.") }
    }
    func requestBooleans(_ entry: JSON,keys: [String]) throws {
        for key in keys where entry[key] != nil { guard let number = entry[key] as? NSNumber,CFGetTypeID(number) == CFBooleanGetTypeID() else { throw CoreError("INVALID_INPUT","\(key) must be Boolean.") } }
    }
    func validateRequestCommand(_ raw: Any?) throws {
        guard let command = raw as? JSON else { throw CoreError("INVALID_INPUT","Run instructions must be a typed command description.") }
        _ = try text(command,"text",max:16000); _ = try text(command,"working_directory",max:4000); _ = try text(command,"expected_result",max:4000)
        _ = try text(command,"reason",max:4000,required:false)
    }
    func validatedRequestAnswers(_ request: JSON,params: JSON,requireComplete: Bool) throws -> [JSON] {
        guard params["answers"] == nil || params["answers"] is [JSON] else { throw CoreError("INVALID_INPUT","Answers must be a typed list.") }
        let answers = params["answers"] as? [JSON] ?? [],questions = request["questions"] as? [JSON] ?? []
        try uniqueRequestIDs(answers,key:"question_id")
        let allowed = Set(questions.compactMap {$0["id"] as? String})
        guard Set(answers.compactMap {$0["question_id"] as? String}).isSubset(of:allowed) else { throw CoreError("REQUEST_CHANGED","An answer does not belong to this form.") }
        var normalized: [JSON] = []
        for q in questions {
            guard var answer = answers.first(where: {$0["question_id"] as? String == q["id"] as? String}) else {
                if requireComplete && bool(q,"required",default:true) { throw incompleteRequestItem(q) }; continue
            }
            let type = q["type"] as? String ?? "text"
            if let claimedType = answer["type"] { guard claimedType as? String == type else { throw CoreError("INVALID_INPUT","An answer has the wrong question type.") } }
            let fields: Set<String> = type == "text" ? ["question_id","type","text","value"] : type == "choice" ? ["question_id","type","option_ids","value","custom_text"] : ["question_id","type","result","value"]
            guard Set(answer.keys).isSubset(of:fields) else { throw CoreError("INVALID_INPUT","This answer contains fields for a different question type.") }
            if type == "text" {
                let value = try requestAnswerString(answer,keys:["text","value"],max:16000)
                guard !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw incompleteRequestItem(q) }
                answer = ["question_id":q["id"]!,"text":value]
            } else if type == "choice" {
                if answer["option_ids"] != nil && !(answer["option_ids"] is [String]) { throw CoreError("INVALID_INPUT","Selected options must be a list of IDs.") }
                let value = try requestAnswerString(answer,keys:["value"],max:4000)
                let ids = answer["option_ids"] as? [String] ?? (value.isEmpty ? [] : [value])
                let custom = try requestAnswerString(answer,keys:["custom_text"],max:16000)
                let customPresent = !custom.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
                let options = Set((q["options"] as? [JSON] ?? []).compactMap {$0["id"] as? String})
                guard Set(ids).isSubset(of:options),Set(ids).count == ids.count,ids.count + (customPresent ? 1 : 0) <= (bool(q,"multiple") ? 100 : 1),!ids.isEmpty || customPresent,custom.isEmpty || (bool(q,"allow_custom") && customPresent) else { throw incompleteRequestItem(q) }
                answer = ["question_id":q["id"]!,"option_ids":ids,"custom_text":custom]
            } else {
                let result = try requestAnswerString(answer,keys:["result","value"],max:100)
                guard (type == "approval" ? ["approved","changes_requested","declined","not_checked"] : ["passed","failed","declined","not_checked"]).contains(result) else { throw incompleteRequestItem(q) }
                if requireComplete && result == "not_checked" {
                    let explanation = try requestAnswerString(params,keys:["explanation"],max:16000)
                    if explanation.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { throw incompleteRequestItem(q) }
                }
                answer = ["question_id":q["id"]!,"result":result]
            }
            normalized.append(answer)
        }
        return normalized
    }
    func incompleteRequestItem(_ item: JSON) -> CoreError {
        CoreError("ANSWER_INCOMPLETE","Complete “\(item["prompt"] as? String ?? item["id"] as? String ?? "Required item")” before sending.")
    }
    func requestAnswerString(_ input: JSON,keys: [String],max: Int) throws -> String {
        for key in keys where input[key] != nil { guard let value = input[key] as? String,value.utf8.count <= max else { throw CoreError("INVALID_INPUT","\(key) must be text within its size limit.") }; return value }
        return ""
    }
    func validatedRequestFiles(_ request: JSON,params: JSON,requireComplete: Bool,managedCopy: ((JSON,String) throws -> String)? = nil,observe: ((String,FileIdentity) -> Void)? = nil) throws -> [JSON] {
        guard params["files"] == nil || params["files"] is [JSON] else { throw CoreError("INVALID_INPUT","File answers must be a typed list.") }
        let files = params["files"] as? [JSON] ?? [],specs = request["file_requests"] as? [JSON] ?? []
        try uniqueRequestIDs(files,key:"file_request_id")
        guard Set(files.compactMap {$0["file_request_id"] as? String}).isSubset(of:Set(specs.compactMap {$0["id"] as? String})) else { throw CoreError("REQUEST_CHANGED","A file answer does not belong to this form.") }
        var result: [JSON] = []
        for spec in specs {
            let file = files.first {$0["file_request_id"] as? String == spec["id"] as? String}
            guard let file else { if requireComplete && bool(spec,"required",default:true) { throw incompleteRequestItem(spec) }; continue }
            guard let paths = file["paths"] as? [String],Set(paths).count == paths.count,paths.count <= (bool(spec,"multiple") ? 100 : 1) else { throw CoreError("INVALID_INPUT","File selections must be a unique list within the selection limit.") }
            if paths.isEmpty { if requireComplete && bool(spec,"required",default:true) { throw incompleteRequestItem(spec) }; continue }
            let mode = file["mode"] as? String ?? "reference"
            guard (file["mode"] == nil || file["mode"] is String),["reference","managed"].contains(mode) else { throw CoreError("INVALID_INPUT","Choose Reference or Managed copy.") }
            if file["path_sha256"] != nil && !(file["path_sha256"] is [String:String]) { throw CoreError("INVALID_INPUT","File identities must map paths to checksums.") }
            var hashes: [String:String] = [:]
            for path in paths {
                if mode == "managed",let managedCopy {
                    guard path.hasPrefix("/") else { throw CoreError("FILE_ACCESS_REQUIRED","Choose an absolute local file path.") }
                    let kind = spec["kind"] as? String ?? spec["selection"] as? String ?? "either"
                    var directory: ObjCBool = false
                    guard kind != "directory",!(FileManager.default.fileExists(atPath:canonical(path),isDirectory:&directory) && directory.boolValue) else { throw CoreError("ANSWER_INCOMPLETE","Directories can be referenced, while managed copies require files.") }
                    hashes[path] = try managedCopy(file,path)
                    continue
                }
                var directory: ObjCBool = false
                guard path.hasPrefix("/"),FileManager.default.fileExists(atPath:canonical(path),isDirectory:&directory) else { throw CoreError("FILE_ACCESS_REQUIRED","A selected original is unavailable. Relink it; your draft remains saved.") }
                let kind = spec["kind"] as? String ?? spec["selection"] as? String ?? "either"
                guard !(kind == "directory" && !directory.boolValue),!(kind == "file" && directory.boolValue),!(mode == "managed" && directory.boolValue) else { throw CoreError("ANSWER_INCOMPLETE","The selection has the wrong type. Directories can be referenced, while managed copies require files.") }
                if !directory.boolValue {
                    let resolved = canonical(path),before = FileIdentity(path:canonical(path))
                    guard let values = try? URL(fileURLWithPath:path).resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]),values.isRegularFile == true,(values.fileSize ?? 0) <= 500*1024*1024,let data = try? Data(contentsOf:URL(fileURLWithPath:path),options:.mappedIfSafe) else { throw CoreError("FILE_ACCESS_REQUIRED","A selected original cannot be read.") }
                    let digest = hash(data)
                    if let expected = (file["path_sha256"] as? [String:String])?[path],expected != digest { throw CoreError("SOURCE_CHANGED","A selected original changed. Relink it to inspect the new bytes; your draft remains saved.") }
                    guard let before,FileIdentity(path:resolved) == before,canonical(path) == resolved else { throw CoreError("SOURCE_CHANGED","A selected original changed while it was read. Your draft remains saved.") }
                    observe?(path,before)
                    hashes[path] = digest
                }
            }
            result.append(["file_request_id":spec["id"]!,"paths":paths,"mode":mode,"path_sha256":hashes,"explanation":try requestAnswerString(file,keys:["explanation"],max:16000)])
        }
        return result
    }
    func notifyHumanResponse(_ db: Database,request: JSON,response: JSON,caller: Caller) throws -> JSON {
        let pid = request["project_id"] as! String,tid = request["task_id"] as! String
        let task = try scoped(db,tid,pid,type:"task")
        var message = try messageWrite(db,["project_id":pid,"task_id":tid,"body":"Ticket metadata: \(try agentReference(db,task)). Human response saved for form \(int(request,"form_revision",default:1)): \(response["action"] as? String ?? "answered"). \(response["explanation"] as? String ?? "")","kind":"note"],caller,"message_send",purpose:.trustedHumanResponse)
        var deliveries = message["deliveries"] as? [JSON] ?? []
        if let sid = request["requester_session_id"] as? String,sid != "human",!deliveries.contains(where: {$0["recipient_session_id"] as? String == sid}),let session = try? scoped(db,sid,pid,type:"session"),canReceive(session,project:pid),request["requester_authorization_generation"] as? String == sessionGeneration(session) {
            let delivery: JSON = ["id":uuid(),"project_id":pid,"message_id":message["id"]!,"recipient_session_id":sid,"recipient_authorization_generation":sessionGeneration(session),"state":"queued","push_state":"unavailable","push_reason":"Available through authenticated MCP pickup; no native acknowledgment yet.","revision":1,"created_at":now()]
            try save(db,delivery,type:"delivery"); deliveries.append(delivery)
        }
        message["human_request_id"] = request["id"]; message["human_response_id"] = response["id"]; message["form_revision"] = int(request,"form_revision",default:1)
        message["deliveries"] = deliveries; message["delivery_status"] = deliveries.isEmpty ? "saved_for_pickup" : "queued"
        // Persist source links without embedding transient delivery projections in the message.
        var stored = message; stored.removeValue(forKey:"deliveries"); try save(db,stored,type:"message")
        return message
    }
}
