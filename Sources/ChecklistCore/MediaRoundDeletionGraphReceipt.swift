import Foundation
import GRDB

extension CommandRouter {
    /// The byte executor already knows how to read and clean descriptor pages.
    /// Stage small pages ahead of the parent. Once the parent exists it
    /// protects bytes in backups, but file disposal waits for graph completion.
    func prepareMediaGraphReceipt(project: String, round: String, receiptID: String,
                                  audit: JSON, bytes: TicketObjectDeletionPlan) throws -> [MediaRoundDeletionGraph.Slice] {
        typealias Graph = MediaRoundDeletionGraph
        typealias Pages = TicketCleanupDescriptorPages
        let generation = uuid(), prefix = Pages.prefix(receiptID,generation)
        var slices: [Graph.Slice] = [], objects: [JSON] = [], used = 0, offset = 0
        func flush() throws {
            guard !objects.isEmpty else {return}
            let id = Pages.id(prefix,offset)
            let initial = try mediaRoundDeletionView(["cause":"media_round_delete","deletion":JSON(),"objects":objects])["files"] ?? [JSON]()
            let page: JSON = ["id":id,"project_id":project,"kind":Self.ticketObjectDeletionKind,"cause":Pages.cause,
                "state":Pages.cause,"revision":1,"page_parent":receiptID,"page_generation":generation,"page_offset":offset,
                "page_state":objects.contains {$0["state"] as? String == "pending"} ? "pending" : "completed",
                "cleanup_policy_version":2,"objects":objects,"media_initial_files":initial]
            slices.append(.init(kind:.descriptor,changes:[.init(id:id,data:try jsonString(page),revision:1,position:0)]))
            offset += objects.count
            objects = []
            used = 0
        }
        for object in bytes.objects {
            let size = try jsonString(object).utf8.count + 1
            guard size <= Pages.byteLimit else {throw Pages.invalid()}
            if objects.count >= 128 || used + size > Graph.journalChunkBytes {try flush()}
            objects.append(object)
            used += size
        }
        try flush()

        let kept = audit["kept_attachments"] as? [JSON] ?? []
        var auditHeader = audit
        if !kept.isEmpty {
            auditHeader["kept_attachments"] = [JSON]()
            auditHeader["kept_attachment_count"] = kept.count
            let prefix = Graph.keptPrefix + receiptID + ":"
            var keptOffset = 0, page: [JSON] = [], pageBytes = 0
            func flushKept() throws {
                guard !page.isEmpty else {return}
                let id = prefix + String(format:"%08d",keptOffset)
                slices.append(.init(kind:.audit,changes:[.init(id:id,data:try jsonString(page),revision:nil,position:0)]))
                keptOffset += page.count
                page = []
                pageBytes = 0
            }
            for attachment in kept {
                let size = try jsonString(attachment).utf8.count
                if page.count >= Graph.rowLimit || pageBytes + size > Graph.journalChunkBytes {try flushKept()}
                page.append(attachment)
                pageBytes += size
            }
            try flushKept()
        }

        var receipt = Self.ticketObjectDeletionReceipt(project:project,task:round,cause:"media_round_delete",plan:bytes,id:receiptID,
                                                        additionalFields:["round_id":round,"deletion":auditHeader])
        receipt["media_graph_cleanup_state"] = receipt["state"]
        receipt["state"] = "deleting"
        if !bytes.objects.isEmpty {
            receipt["objects"] = [JSON]()
            receipt["descriptor_page_generation"] = generation
            receipt["descriptor_page_prefix"] = prefix
            receipt["descriptor_count"] = bytes.objects.count
            receipt["descriptor_has_links"] = bytes.objects.contains {$0["kind"] as? String == "symlink"}
        }
        slices.append(.init(kind:.receipt,changes:[.init(id:receiptID,data:try jsonString(receipt),revision:1,position:0)]))
        return slices
    }

    func mediaGraphFirstReply(_ db: Database,_ result: JSON) throws -> JSON {
        guard let id = result[MediaRoundDeletionGraph.firstReceiptField] as? String else {return result}
        let receipt = try record(db,id,type:"storage_job")
        guard receipt["cause"] as? String == "media_round_delete", let state = receipt["media_graph_cleanup_state"] as? String else {
            throw StoreRecovery.required("media_deletion_graph_receipt_invalid")
        }
        var first = try mediaRoundDeletionView(mediaGraphReceiptAudit(db,receipt))
        first["cleanup_state"] = state
        if receipt["descriptor_page_generation"] != nil {
            var files: [JSON] = []
            var offset = 0
            let pages = try TicketCleanupDescriptorPages.rows(db,parent:receipt)
            while let raw = try pages.next() {
                let page = try GRDBRecordEnvelopeAdapter.decode(raw,expectedType:"storage_job").object
                let objects = try TicketCleanupDescriptorPages.activePage(page,parent:receipt,offset:offset)
                guard let initial = page["media_initial_files"] as? [JSON],initial.count == objects.count else {
                    throw StoreRecovery.required("media_deletion_graph_receipt_invalid")
                }
                files += initial
                offset += objects.count
            }
            guard offset == int(receipt,"descriptor_count",default:-1) else {throw TicketCleanupDescriptorPages.invalid()}
            first["files"] = files
        }
        return first
    }

    func mediaGraphReceiptAudit(_ db: Database,_ receipt: JSON) throws -> JSON {
        guard var audit = receipt["deletion"] as? JSON,
              let expected = audit.removeValue(forKey:"kept_attachment_count") as? Int else {return receipt}
        let id = try StoredRecord(receipt,family:"storage_job").string("id")
        let prefix = MediaRoundDeletionGraph.keptPrefix + id + ":"
        let rows = try Row.fetchCursor(db,sql:"SELECT key,CAST(value AS BLOB) bytes FROM metadata WHERE key>=? AND key<? ORDER BY key",
                                       arguments:[prefix,prefix + "~"])
        var kept: [JSON] = []
        while let row = try rows.next() {
            let key: String = row["key"], bytes: Data = row["bytes"]
            guard key == prefix + String(format:"%08d",kept.count),
                  let page = try JSONSerialization.jsonObject(with:bytes) as? [JSON], !page.isEmpty,
                  page.count <= MediaRoundDeletionGraph.rowLimit, page.count <= expected - kept.count else {
                throw StoreRecovery.required("media_deletion_graph_receipt_invalid")
            }
            kept += page
        }
        guard kept.count == expected else {throw StoreRecovery.required("media_deletion_graph_receipt_invalid")}
        audit["kept_attachments"] = kept
        var result = receipt
        result["deletion"] = audit
        return result
    }

}
