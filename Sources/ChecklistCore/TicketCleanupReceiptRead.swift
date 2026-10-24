import Foundation
import GRDB

/// Read projections only. Never rewrite a pass or load its descriptor corpus.
extension CommandRouter {
    func ticketCleanupReceiptPage(_ db: Database,_ p: JSON,_ c: Caller,_ pid: String) throws -> JSON {
        let limit = min(max(int(p,"limit",default:50),1),50)
        let id = p["receipt_id"] as? String
        let section = p["section"] as? String ?? "items"
        guard ["items","objects","source_build_cache"].contains(section),id != nil || p["section"] == nil else {
            throw CoreError("INVALID_INPUT","Select a receipt before paging items, objects or source_build_cache.")
        }
        // Sealed offsets expire after 24 hours and bind the exact grant/session,
        // store incarnation, query and current outcome revisions.
        let generation: String
        if let id {
            guard let row = try Row.fetchOne(db,sql:"SELECT revision,json_extract(data,'$.cause') cause FROM records WHERE id=? AND project_id=? AND type='storage_job'",arguments:[id,pid]),row["cause"] as String? == "ticket_cleanup_pass" else {throw CoreError("NOT_FOUND","No cleanup pass with this ID.")}
            let revisions = try Row.fetchAll(db,sql:"SELECT j.id,j.revision FROM records r,json_each(r.data,'$.items') i JOIN records j ON j.id=json_extract(i.value,'$.byte_deletion_receipt_id') AND j.project_id=r.project_id AND j.type='storage_job' WHERE r.id=? ORDER BY i.key",arguments:[id])
            generation = String(row["revision"] as Int) + ":" + hash(Data(try jsonString(revisions.map {["id":$0["id"] as String,"revision":$0["revision"] as Int]}).utf8))
        } else {
            generation = String(try Int64.fetchOne(db,sql:"SELECT COALESCE(MAX(rowid),0) FROM records WHERE project_id=? AND type='storage_job' AND json_extract(data,'$.cause')='ticket_cleanup_pass'",arguments:[pid]) ?? 0)
        }
        let identity: JSON = ["project":pid,"receipt":id ?? "","section":section,"limit":limit,"generation":generation,
            "authorization":try authorizationScope(db,c),"session":try callerSessionGeneration(db,c,project:pid)]
        let scope = "cleanup-receipts-v1:" + hash(Data(try jsonString(identity).utf8))
        let offset = try cursorSequence(db,p,caller:c,scope:scope)
        guard offset >= 0 else {throw CoreError("CURSOR_RESET","Refresh cleanup receipts.")}
        var result: JSON
        var values: [JSON] = []
        var more = false
        if let id {
            result = try ticketCleanupReceiptSummary(db,id:id,project:pid)
            let sql: String
            if section == "objects" {
                sql = "SELECT json_object('byte_deletion_receipt_id',j.id,'item_index',i.key,'object_index',o.key,'object',json(o.value)) value FROM records r,json_each(r.data,'$.items') i JOIN records j ON j.id=json_extract(i.value,'$.byte_deletion_receipt_id') AND j.project_id=r.project_id AND j.type='storage_job',json_each(j.data,'$.objects') o WHERE r.id=? ORDER BY i.key,o.key LIMIT ? OFFSET ?"
            } else {
                sql = "SELECT i.value value FROM records r,json_each(r.data,'$.\(section)') i WHERE r.id=? ORDER BY i.key LIMIT ? OFFSET ?"
            }
            let rows = try Row.fetchAll(db,sql:sql,arguments:[id,limit+1,offset])
            for row in rows.prefix(limit) {
                var item = jsonObject(row["value"] as String)
                if section == "items",let linked = item["byte_deletion_receipt_id"] as? String {
                    // Current byte facts, with exact descriptors on the objects page.
                    item["byte_deletion"] = try ticketCleanupByteSummary(db,id:linked,project:pid)
                }
                if try jsonString(values + [item]).utf8.count > 220 * 1024 {more = true;break}
                values.append(item)
            }
            more = more || rows.count > values.count
            result[section] = values
        } else {
            let rows = try Row.fetchAll(db,sql:"SELECT id FROM records WHERE type='storage_job' AND project_id=? AND json_extract(data,'$.cause')='ticket_cleanup_pass' ORDER BY rowid DESC LIMIT ? OFFSET ?",arguments:[pid,limit+1,offset])
            for row in rows.prefix(limit) {
                let value = try ticketCleanupReceiptSummary(db,id:row["id"],project:pid)
                if try jsonString(values + [value]).utf8.count > 220 * 1024 {more = true;break}
                values.append(value)
            }
            more = more || rows.count > values.count
            result = ["receipts":values,"first_pass_receipt_id":try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["ticket-cleanup-first:" + pid]) as Any? ?? NSNull()]
        }
        guard !more || !values.isEmpty else {throw CoreError("RESULT_TOO_LARGE","A cleanup entry exceeds the receipt page budget.")}
        result["has_more"] = more
        result["next_cursor"] = more ? try cursor(db,caller:c,scope:scope,sequence:offset+values.count) : NSNull()
        result["limit"] = limit
        return result
    }

    private func ticketCleanupByteSummary(_ db: Database,id: String,project: String) throws -> JSON {
        guard let text = try String.fetchOne(db,sql:"SELECT json_object('id',id,'state',json_extract(data,'$.state'),'summary',json_extract(data,'$.summary')) FROM records WHERE id=? AND project_id=? AND type='storage_job'",arguments:[id,project]) else {throw CoreError("NOT_FOUND","The linked byte receipt is unavailable in this project.")}
        return jsonObject(text)
    }

    private func ticketCleanupReceiptSummary(_ db: Database,id: String,project: String) throws -> JSON {
        let text = try String.fetchOne(db,sql:"SELECT json_object('id',id,'project_id',project_id,'revision',revision,'kind',json_extract(data,'$.kind'),'origin',json_extract(data,'$.origin'),'state',json_extract(data,'$.state'),'settings',json_extract(data,'$.settings'),'created_at',json_extract(data,'$.created_at'),'cause',json_extract(data,'$.cause'),'selected_bytes',json_extract(data,'$.selected_bytes'),'item_count',COALESCE(json_array_length(data,'$.items'),0),'source_build_cache_count',COALESCE(json_array_length(data,'$.source_build_cache'),0)) FROM records WHERE id=? AND project_id=? AND type='storage_job'",arguments:[id,project])!
        var result = jsonObject(text)
        let counts = try Row.fetchAll(db,sql:"SELECT json_extract(i.value,'$.action') action,json_extract(i.value,'$.reason') reason,COUNT(*) count FROM records r,json_each(r.data,'$.items') i WHERE r.id=? GROUP BY action,reason",arguments:[id])
        var actions: [String:Int] = [:],reasons: [String:Int] = [:]
        for row in counts {
            let count: Int = row["count"]
            actions[row["action"] as String? ?? "unknown",default:0] += count
            if let reason: String = row["reason"] {reasons[reason,default:0] += count}
        }
        result["action_counts"] = actions;result["reason_counts"] = reasons
        var summary = Self.ticketObjectDeletionSummary([]),retained: [String:JSON] = [:]
        let rows = try Row.fetchAll(db,sql:"SELECT j.id,j.project_id,j.type,json_extract(j.data,'$.summary') summary FROM records r,json_each(r.data,'$.items') i LEFT JOIN records j ON j.id=json_extract(i.value,'$.byte_deletion_receipt_id') WHERE r.id=? AND json_type(i.value,'$.byte_deletion_receipt_id')='text'",arguments:[id])
        for row in rows {
            guard row["project_id"] as String? == project,row["type"] as String? == "storage_job",let text: String = row["summary"] else {throw CoreError("NOT_FOUND","The linked byte receipt is unavailable in this project.")}
            let part = jsonObject(text)
            for state in ["pending","removed","already_missing","retained"] {
                for suffix in ["_count","_bytes"] {
                    let key = state+suffix
                    summary[key] = ((summary[key] as? NSNumber)?.int64Value ?? 0)+((part[key] as? NSNumber)?.int64Value ?? 0)
                }
            }
            for (reason,raw) in part["retained_reasons"] as? JSON ?? [:] {
                let part = raw as? JSON ?? [:],prior = retained[reason] ?? [:]
                retained[reason] = ["count":int(prior,"count")+int(part,"count"),"bytes":((prior["bytes"] as? NSNumber)?.int64Value ?? 0)+((part["bytes"] as? NSNumber)?.int64Value ?? 0)]
            }
        }
        summary["retained_reasons"] = retained;result["summary"] = summary
        result["bytes_state"] = int(summary,"pending_count") > 0 ? "pending" : "completed"
        return result
    }
}
