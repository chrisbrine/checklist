import Foundation
import CoreFoundation
import GRDB

/// A playtest is one immutable part of the ordinary submission manifest. File
/// bytes, authorization, export and cleanup remain owned by task attachments.
struct PlaytestBundle {
    let build: JSON
    let scenario: JSON
    let stateFiles: [JSON]
    let screenshots: [JSON]
    let log: JSON
    var runFiles: [JSON] { stateFiles + screenshots + [log] }
    var files: [JSON] { [scenario, ["artifact_id":build["artifact_id"]!,"sha256":build["sha256"]!]] + runFiles }
    var json: JSON { ["build":build,"scenario":scenario,"state_files":stateFiles,"screenshots":screenshots,"log":log] }

    static func parse(_ raw: Any?,stored: Bool = false) throws -> Self {
        guard let value = raw as? JSON else { throw CoreError("INVALID_INPUT","A playtest bundle must be an object.") }
        let fields: Set<String> = ["build","scenario","state_files","screenshots","log"]
        guard Set(value.keys) == (stored ? fields.union(["id","version","sha256"]) : fields) else { throw CoreError("INVALID_INPUT","A playtest bundle needs exactly build, scenario, state_files, screenshots and log; stored bundle IDs cannot be resubmitted.") }
        func ref(_ raw: Any?) throws -> JSON {
            guard let r = raw as? JSON,Set(r.keys) == ["artifact_id","sha256"] else { throw CoreError("INVALID_INPUT","Bundle files must name an immutable artifact_id and sha256.") }
            let id = try text(r,"artifact_id",max:200),sha = try text(r,"sha256",max:64)
            guard sha.utf8.count == 64,sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CoreError("INVALID_INPUT","Bundle hashes must be lowercase SHA-256 hex digests.") }
            return ["artifact_id":id,"sha256":sha]
        }
        func refs(_ key: String) throws -> [JSON] {
            guard let rows = value[key] as? [JSON],!rows.isEmpty,rows.count <= 100 else { throw CoreError("INVALID_INPUT","A playtest bundle needs 1 to 100 \(key).") }
            return try rows.map { try ref($0) }
        }
        guard let build = value["build"] as? JSON,Set(build.keys) == ["artifact_id","sha256","build_id","version","platform"] else { throw CoreError("INVALID_INPUT","The exact build needs artifact_id, sha256, build_id, version and platform.") }
        var exactBuild = try ref(["artifact_id":build["artifact_id"] ?? NSNull(),"sha256":build["sha256"] ?? NSNull()])
        for key in ["build_id","version","platform"] { exactBuild[key] = try text(build,key,max:key == "platform" ? 200 : 500) }
        let bundle = try Self(build:exactBuild,scenario:ref(value["scenario"]),stateFiles:refs("state_files"),screenshots:refs("screenshots"),log:ref(value["log"]))
        let ids = bundle.files.compactMap { $0["artifact_id"] as? String }
        guard ids.count <= 100,Set(ids).count == ids.count else { throw CoreError("INVALID_INPUT","Use distinct files for every bundle role, at most 100 files including the build and scenario.") }
        if stored {
            guard let id = value["id"] as? String,UUID(uuidString:id) != nil,(value["version"] as? Int) == 1,
                  value["sha256"] as? String == hash(Data(try jsonString(bundle.json.merging(["id":id,"version":1]) { _,new in new }).utf8)) else { throw CoreError("EVIDENCE_STALE","The recorded playtest bundle identity or digest changed.") }
        }
        return bundle
    }

    static var schema: JSON {
        let ref: JSON = ["type":"object","properties":["artifact_id":["type":"string","minLength":1,"maxLength":200],"sha256":["type":"string","pattern":"^[a-f0-9]{64}$"]],"required":["artifact_id","sha256"],"additionalProperties":false]
        var build = ref
        var fields = build["properties"] as! JSON
        for key in ["build_id","version","platform"] { fields[key] = ["type":"string","minLength":1,"maxLength":key == "platform" ? 200 : 500] }
        build["properties"] = fields;build["required"] = ["artifact_id","sha256","build_id","version","platform"]
        return ["type":"object","properties":["build":build,"scenario":ref,"state_files":["type":"array","minItems":1,"maxItems":100,"items":ref],"screenshots":["type":"array","minItems":1,"maxItems":100,"items":ref],"log":ref],"required":["build","scenario","state_files","screenshots","log"],"additionalProperties":false]
    }
}

extension CommandRouter {
    func normalizePlaytestBundle(_ db: Database,evidence: inout JSON,task: JSON) throws {
        guard evidence["playtest_bundle"] != nil else { return }
        guard task["kind"] as? String == "playtest",evidence["kind"] as? String != "decision" else { throw CoreError("INVALID_INPUT","Playtest bundles belong to Playtest tickets with artifact or source evidence.") }
        let bundle = try PlaytestBundle.parse(evidence["playtest_bundle"])
        let history = try scopedTaskRows(db,type:"manifest",task:task,predicate:"json_type(data,'$.evidence.playtest_bundle')='object'",limit:1001)
        guard history.count <= 1000 else { throw CoreError("EVIDENCE_HISTORY_LIMIT","The playtest history exceeds the bounded reuse check. Keep the existing evidence and use a new Playtest ticket.") }
        let runIDs = Set(bundle.runFiles.compactMap { $0["artifact_id"] as? String })
        for prior in history {
            guard let raw = (prior["evidence"] as? JSON)?["playtest_bundle"] else { continue }
            let previous = try PlaytestBundle.parse(raw,stored:true)
            if try jsonString(previous.build) != jsonString(bundle.build),!runIDs.isDisjoint(with:previous.runFiles.compactMap { $0["artifact_id"] as? String }) {
                throw CoreError("PLAYTEST_BUILD_CHANGED","This build needs a new playtest bundle with newly attached state, screenshots and log. Earlier run files remain bound to their recorded build.")
            }
        }
        var refs = evidence["artifact_refs"] as? [JSON] ?? []
        if evidence["artifact_refs"] != nil && !(evidence["artifact_refs"] is [JSON]) { throw CoreError("INVALID_INPUT","artifact_refs must be a list.") }
        for ref in bundle.files {
            if let existing = refs.first(where: { $0["artifact_id"] as? String == ref["artifact_id"] as? String }) {
                guard existing["sha256"] as? String == ref["sha256"] as? String else { throw CoreError("EVIDENCE_STALE","A bundle file conflicts with its submitted artifact hash.") }
            } else { refs.append(ref) }
        }
        var stored = bundle.json;stored["id"] = uuid();stored["version"] = 1
        stored["sha256"] = hash(Data(try jsonString(stored).utf8))
        evidence["playtest_bundle"] = stored;evidence["artifact_refs"] = refs
    }

    func validatePlaytestBundleTarget(evidence: JSON,task: JSON) throws {
        guard let raw = evidence["playtest_bundle"] else { return }
        guard task["kind"] as? String == "playtest" else { throw CoreError("EVIDENCE_STALE","The playtest target no longer belongs to a Playtest ticket.") }
        let bundle = try PlaytestBundle.parse(raw,stored:true),refs = evidence["artifact_refs"] as? [JSON] ?? []
        for ref in bundle.files {
            guard refs.contains(where: { $0["artifact_id"] as? String == ref["artifact_id"] as? String && $0["sha256"] as? String == ref["sha256"] as? String }) else { throw CoreError("EVIDENCE_STALE","A playtest file is missing from its exact submitted target.") }
        }
    }

    /// A completed playtest verdict uses the existing acceptance assessment. It
    /// may not replace per-item pass/fail results with a free-text overall result.
    func requirePlaytestAssessment(params: JSON,manifest: JSON,verdict: String) throws {
        guard (manifest["evidence"] as? JSON)?["playtest_bundle"] != nil,["pass","reject"].contains(verdict) else { return }
        guard let assessment = params["review_assessment"] as? JSON,let rows = assessment["acceptance"] as? [JSON],rows.allSatisfy({ ["pass","fail"].contains($0["result"] as? String ?? "") }) else { throw CoreError("REVIEW_ASSESSMENT_REQUIRED","A playtest verdict needs a pass or fail for each acceptance item in review_assessment. Use blocked or evidence_missing when it cannot be assessed.") }
    }

    func retainCitedPlaytestFiles(_ db: Database,params: JSON,task: JSON,attempt: JSON,assessment: JSON?,verdict: String) throws -> [JSON]? {
        guard params["retain_cited_files"] != nil else { return nil }
        guard let flag = params["retain_cited_files"] as? NSNumber,CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw CoreError("INVALID_INPUT","retain_cited_files must be a boolean.") }
        guard flag.boolValue else { return nil }
        let pid = task["project_id"] as! String,manifest = try scoped(db,attempt["manifest_id"] as! String,pid,type:"manifest")
        guard let raw = (manifest["evidence"] as? JSON)?["playtest_bundle"],let assessment,["pass","reject"].contains(verdict) else { throw CoreError("INVALID_INPUT","Retaining cited files requires an assessed pass or reject on an exact playtest bundle.") }
        let bundle = try PlaytestBundle.parse(raw,stored:true)
        let cited = Self.referencedValues(assessment,key:"artifact_id").union(Self.referencedValues(params["checks"] ?? [],key:"artifact_id"))
        var retained: [JSON] = []
        for ref in bundle.files where cited.contains(ref["artifact_id"] as! String) {
            var file = try scoped(db,ref["artifact_id"] as! String,pid,type:"attachment")
            guard file["task_id"] as? String == task["id"] as? String,file["sha256"] as? String == ref["sha256"] as? String,file["mode"] as? String == "managed",file["availability"] as? String == "available" else { throw CoreError("EVIDENCE_STALE","A cited playtest original is unavailable or changed.") }
            if !bool(file,"keep_original") { file["keep_original"] = true;try save(db,revised(file),type:"attachment") }
            retained.append(ref)
        }
        return retained
    }
}
