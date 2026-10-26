import Foundation
import GRDB

extension CommandRouter {
    static func canonicalColumns(alias:String)->String {
        ["id","project_id","type","revision","data"].map {alias+"."+$0+" AS "+$0}.joined(separator:",") + "," + ["id","project_id","type","data"].map {"CAST("+alias+"."+$0+" AS BLOB) AS _envelope_"+$0+"_bytes"}.joined(separator:",")
    }
    /// SQL predicates bind both project and opaque task identity before decoding.
    /// Callers supply only internal SQL fragments, never public column/order text.
    func scopedTaskRows(_ db: Database, type: String, task: JSON, predicate: String = "1", arguments: [DatabaseValueConvertible] = [], limit: Int? = nil, descending: Bool = false) throws -> [JSON] {
        let selected = try selectedTaskRecordIDs(db,type:type,task:task)
        let selection = selected == nil ? "" : "rowid IN (SELECT value FROM json_each(?)) AND "
        var sql = "SELECT "+Self.canonicalRecordColumns+" FROM records WHERE "+selection+"type=? AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY AND ("+predicate+") ORDER BY rowid"+(descending ? " DESC" : "")
        var args: [DatabaseValueConvertible] = try selected.map {[try jsonString($0)]} ?? []
        args += [type,Data((task["project_id"] as! String).utf8),Data((task["id"] as! String).utf8)]+arguments
        if let limit {sql += " LIMIT ?";args.append(limit)}
        return try Row.fetchAll(db,sql:sql,arguments:StatementArguments(args)).map {try GRDBRecordEnvelopeAdapter.decode($0).object}
    }
    func scopedTaskCount(_ db: Database, type: String, task: JSON, predicate: String = "1") throws -> Int {
        let selected = try selectedTaskRecordIDs(db,type:type,task:task)
        let selection = selected == nil ? "" : "rowid IN (SELECT value FROM json_each(?)) AND "
        var arguments: [DatabaseValueConvertible] = try selected.map {[try jsonString($0)]} ?? []
        arguments += [type,Data((task["project_id"] as! String).utf8),Data((task["id"] as! String).utf8)]
        return try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM records WHERE "+selection+"type=? AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY AND ("+predicate+")",arguments:StatementArguments(arguments)) ?? 0
    }
    func scopedTaskGroups(_ db: Database, task: JSON) throws -> [JSON] {
        let pid = task["project_id"] as! String,tid = task["id"] as! String
        return try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records g WHERE type='group' AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.kind')='triage' AND EXISTS (SELECT 1 FROM json_each(CASE WHEN json_array_length(json_extract(g.data,'$.members'))>0 THEN json_extract(g.data,'$.members') ELSE json_extract(g.data,'$.task_ids') END) m WHERE (CASE WHEN m.type='object' THEN json_extract(m.value,'$.task_id') ELSE m.value END)=CAST(? AS TEXT) COLLATE BINARY) ORDER BY rowid",arguments:[Data(pid.utf8),Data(tid.utf8)]).map {try GRDBRecordEnvelopeAdapter.decode($0).object}
    }
    /// Compact container membership is a reference, not the complete group
    /// outcome/history projection. It does not decode unrelated project tasks.
    func scopedContextGroup(_ source:JSON,task:JSON)->JSON {
        var result:JSON=[:]
        for key in ["id","project_id","kind","key","name","purpose","brief","revision","archived","phase","orchestration","created_at","updated_at"] {result[key]=source[key]}
        result["context_complete"]=false
        if source["kind"] as? String == "triage" {
            result["member_count"]=triageMemberIDs(source).count
            result["selected_member_ids"]=[task["id"]!]
            result["members_complete"]=false
            result["phase"]=triagePhase(source) ?? NSNull()
        }
        return result
    }
    func scopedContextEpic(_ db:Database,task:JSON)throws->Any {
        guard let id=task["epic_id"] as? String,let epic=try? scoped(db,id,task["project_id"] as! String,type:"group"),epic["kind"] as? String == "epic" else{return NSNull()}
        return scopedContextGroup(epic,task:task)
    }
    func scopedTaskRelations(_ db: Database, task: JSON) throws -> [JSON] {
        try Row.fetchAll(db,sql:"SELECT "+Self.canonicalRecordColumns+" FROM records WHERE type='relation' AND project_id=CAST(? AS TEXT) AND (json_extract(data,'$.source_task_id')=CAST(? AS TEXT) COLLATE BINARY OR json_extract(data,'$.target_task_id')=CAST(? AS TEXT) COLLATE BINARY) AND COALESCE(json_extract(data,'$.state'),'')<>'removed' ORDER BY rowid",arguments:[Data((task["project_id"] as! String).utf8),Data((task["id"] as! String).utf8),Data((task["id"] as! String).utf8)]).map {try GRDBRecordEnvelopeAdapter.decode($0).object}
    }
    func scopedRelationContext(_ db: Database, task: JSON) throws -> JSON {
        let pid = task["project_id"] as! String,tid = task["id"] as! String
        let relations = try scopedTaskRelations(db,task:task)
        let sources = relations.filter {SnapshotRecordIdentity($0["source_task_id"] as? String ?? "")==SnapshotRecordIdentity(tid)}
        let prerequisites = projectedPrerequisites(task:task,relations:sources,taskLookup:{try self.scoped(db,$0,pid,type:"task")},statusLookup:{try self.scoped(db,$0,pid,type:"status")})
        let category = (try? scoped(db,task["status_id"] as? String ?? "",pid,type:"status"))?["category"] as? String ?? "unknown"
        return ["relations":relations,"aliases":try scopedTaskRows(db,type:"task_alias",task:task),"eligibility":try projectedRelationTask(task:task,prerequisites:prerequisites,category:category,canonicalID:canonicalTaskID(db,task:task))]
    }
}
