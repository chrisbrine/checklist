import Foundation
import GRDB
import CryptoKit
import SQLite3

/// A descriptor page is internal accounting. Its objects become authoritative
/// only after the logical receipt publishes their generation and exact count.
enum TicketCleanupDescriptorPages {
    static let cause = "descriptor_page"
    static let stageLimit = 64
    static let countLimit = 512
    static let byteLimit = 512 * 1024
    static let headerLimit = 512 * 1024

    static func prefix(_ receipt: String, _ generation: String) -> String {
        "ticket-byte-page:" + hash(Data(receipt.utf8)) + ":" + generation + ":"
    }
    static func id(_ prefix: String, _ offset: Int) -> String {prefix + String(format:"%016llx",Int64(offset))}
    static func invalid() -> CoreError {CoreError("CLEANUP_INVENTORY_LIMIT","The byte receipt's descriptor or authority header exceeds its continuation bound; bytes retained.")}

    static let inlineOverflowSQL = """
        json_extract(records.data,'$.descriptor_page_generation') IS NULL
        AND json_extract(records.data,'$.cause') IN ('task_purge','done_evidence','media_round_delete')
        AND (length(CAST(records.data AS BLOB))>\(TicketCleanupDeletionCohort.descriptorByteLimit)
             OR json_array_length(records.data,'$.objects')>\(TicketCleanupDeletionCohort.objectLimit))
        AND json_array_length(records.data,'$.objects')>0
        AND length(CAST(json_remove(records.data,'$.objects') AS BLOB))<=\(headerLimit)
        """

    static let activeSQL = """
        json_extract(page.data,'$.cause')='descriptor_page'
        AND json_extract(page.data,'$.page_parent')=parent.id COLLATE BINARY
        AND json_extract(page.data,'$.page_generation')=json_extract(parent.data,'$.descriptor_page_generation') COLLATE BINARY
        AND page.project_id=parent.project_id AND page.type='storage_job'
        AND page.id>=json_extract(parent.data,'$.descriptor_page_prefix')
        AND page.id<json_extract(parent.data,'$.descriptor_page_prefix')||'~'
        """
    static let readySQL = """
        json_valid(records.data) AND json_extract(records.data,'$.kind')='ticket_object_delete' AND (
            (\(inlineOverflowSQL)) OR
            (json_type(records.data,'$.descriptor_page_generation')='text' AND json_extract(records.data,'$.state')<>'deleting' AND EXISTS (
                SELECT 1 FROM records parent JOIN records page ON page.project_id=parent.project_id AND page.type='storage_job'
                WHERE parent.id=records.id AND \(activeSQL) AND
                (\(CommandRouter.ticketObjectDeletionReadySQL(data:"page.data",id:"page.id",cause:"json_extract(parent.data,'$.cause')",state:"json_extract(page.data,'$.page_state')")))
            )))
        """
    static func rows(_ db: Database, parent: JSON) throws -> RowCursor {
        let source = StoredRecord(parent,family:"storage_job")
        let receipt = try source.string("id"),generation = try source.string("descriptor_page_generation"),project = try source.string("project_id")
        let lower = prefix(receipt,generation),upper = lower + "~"
        guard parent["descriptor_page_prefix"] as? String == lower else {throw invalid()}
        return try Row.fetchCursor(db,sql:"SELECT " + CommandRouter.canonicalRecordColumns + " FROM records WHERE id>=? AND id<? AND project_id=? AND type='storage_job' ORDER BY id",arguments:[lower,upper,project])
    }
    static func activePage(_ page: JSON, parent: JSON, offset: Int) throws -> [JSON] {
        guard page["cause"] as? String == cause,page["page_parent"] as? String == parent["id"] as? String,
              page["page_generation"] as? String == parent["descriptor_page_generation"] as? String,
              page["project_id"] as? String == parent["project_id"] as? String,int(page,"page_offset",default:-1) == offset,
              let objects = page["objects"] as? [JSON],!objects.isEmpty,objects.count <= countLimit else {throw invalid()}
        let key = prefix(page["page_parent"] as! String,page["page_generation"] as! String)
        guard page["id"] as? String == id(key,offset) else {throw invalid()}
        return objects
    }

    static func inlineGeneration(_ db: Database,row: Int64) throws -> String {
        // Read the immutable source in bounded chunks; a legacy receipt has
        // no limit on its total JSON length once it has already been committed.
        var opened: OpaquePointer?
        guard sqlite3_blob_open(db.sqliteConnection,"main","records","data",row,0,&opened) == SQLITE_OK,
              let blob = opened else {throw invalid()}
        defer {sqlite3_blob_close(blob)}
        let length = Int(sqlite3_blob_bytes(blob))
        var hasher = SHA256(),offset = 0,chunk = Data(count:byteLimit)
        while offset < length {
            let size = min(chunk.count,length - offset)
            try chunk.withUnsafeMutableBytes {buffer in
                guard sqlite3_blob_read(blob,buffer.baseAddress,Int32(size),Int32(offset)) == SQLITE_OK else {throw invalid()}
                let bytes = UnsafeRawBufferPointer(start:buffer.baseAddress,count:size)
                guard !bytes.contains(0) else {throw invalid()}
                hasher.update(bufferPointer:bytes)
            }
            offset += size
        }
        return StorageObjectFiles.hex(hasher.finalize())
    }

    static func adding(_ page: JSON, to parent: JSON, replacing old: JSON) throws -> JSON {
        var total = parent
        func number(_ object: JSON, _ key: String) -> Int64 {(object[key] as? NSNumber)?.int64Value ?? 0}
        func replacing(_ before: Int64,_ with: Int64,in value: Int64) throws -> Int64 {
            let (removed,underflow) = value.subtractingReportingOverflow(before)
            let (added,overflow) = removed.addingReportingOverflow(with)
            guard !underflow,!overflow,removed >= 0,added >= 0 else {throw invalid()}
            return added
        }
        for state in ["pending","removed","already_missing","retained"] {
            for suffix in ["_count","_bytes"] {
                let key = state + suffix
                total[key] = try replacing(number(old,key),number(page,key),in:number(total,key))
            }
        }
        let before = old["retained_reasons"] as? [String:JSON] ?? [:],after = page["retained_reasons"] as? [String:JSON] ?? [:]
        var reasons = total["retained_reasons"] as? [String:JSON] ?? [:]
        for reason in Set(before.keys).union(after.keys) {
            var value: JSON = [:]
            for key in ["count","bytes"] {value[key] = try replacing(number(before[reason] ?? [:],key),number(after[reason] ?? [:],key),in:number(reasons[reason] ?? [:],key))}
            reasons[reason] = number(value,"count") == 0 ? nil : value
        }
        total["retained_reasons"] = reasons
        return total
    }
}

struct TicketBytePageLinks {
    let holds: [Int:[String]]
    let pendingTargets: Set<String>
    let linksOnly: Bool

    func apply(_ objects: inout [JSON]) {
        for (offset,reasons) in holds where objects[offset]["state"] as? String == "pending" {
            objects[offset]["state"] = "retained";objects[offset]["reasons"] = reasons
        }
    }
}

struct TicketBytePageExecution {
    let parent: JSON
    let page: JSON
    let links: TicketBytePageLinks
}

struct TicketBytePageConversion {
    let parent: JSON
    let pages: [JSON]
    let generation: String
    let count: Int
    let activation: PreparedTicketObjectDeletionReceipt?
    var canActivate: Bool {activation != nil}
}

final class TicketBytePagePass: TicketCleanupPrepared {
    let fence: TicketCleanupFence
    let conversion: TicketBytePageConversion?
    let prepared: TicketCleanupPreparedDeletion?
    let row: Int64
    var conversionIndex = 0

    init(fence: TicketCleanupFence,conversion: TicketBytePageConversion,row: Int64) {
        self.fence = fence; self.conversion = conversion; self.row = row; prepared = nil
    }
    init(prepared: TicketCleanupPreparedDeletion,row: Int64) {
        fence = prepared.fence; self.prepared = prepared; self.row = row; conversion = nil
    }
}

extension CommandRouter {
    /// Public readers and backup share the same recorded descriptor order and
    /// require an exact active extent before treating a receipt as complete.
    static func visitTicketObjectDeletionObjects(_ db: Database, receipt: JSON, _ visit: (JSON) throws -> Void) throws {
        guard receipt["descriptor_page_generation"] is String else {
            guard let objects = receipt["objects"] as? [JSON] else {throw TicketCleanupDescriptorPages.invalid()}
            for object in objects {try visit(object)}
            return
        }
        var offset = 0
        let rows = try TicketCleanupDescriptorPages.rows(db,parent:receipt)
        while let row = try rows.next() {
            let page = try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"storage_job").object
            let objects = try TicketCleanupDescriptorPages.activePage(page,parent:receipt,offset:offset)
            for object in objects {try visit(object)}
            offset += objects.count
        }
        guard offset == int(receipt,"descriptor_count",default:-1) else {throw TicketCleanupDescriptorPages.invalid()}
    }

    func ticketObjectDeletionReceiptWithObjects(_ db: Database, receipt: JSON) throws -> JSON {
        guard receipt["descriptor_page_generation"] is String else {return receipt}
        var objects: [JSON] = []
        try Self.visitTicketObjectDeletionObjects(db,receipt:receipt) {objects.append($0)}
        var result = receipt
        for field in ["descriptor_page_generation","descriptor_page_prefix","descriptor_count","descriptor_has_links","descriptor_legacy_trash_binding"] {result.removeValue(forKey:field)}
        result["objects"] = objects
        return result
    }

    func prepareTicketBytePageConversion(_ db: Database, id: String, project: String, row: Int64) throws -> TicketBytePagePass {
        typealias Pages = TicketCleanupDescriptorPages
        // This is an exact generation of the inline receipt. A partial split
        // survives reopen and cannot be adopted by a different receipt body.
        guard let raw = try Row.fetchOne(db,sql:"""
            SELECT \(Self.canonicalRecordColumns),object_count FROM (
                SELECT id,project_id,type,revision,json_set(json_remove(data,'$.objects'),'$.objects',json('[]')) AS data,
                       json_array_length(data,'$.objects') AS object_count
                FROM records WHERE rowid=? AND id=? AND project_id=? AND type='storage_job'
                    AND json_valid(data) AND json_type(data,'$.objects')='array'
            )
            """,arguments:[row,id,project]) else {throw Pages.invalid()}
        let parent = try GRDBRecordEnvelopeAdapter.decode(raw,expectedType:"storage_job").object
        let total: Int = raw["object_count"]
        guard total > 0,try jsonString(parent).utf8.count <= Pages.headerLimit else {throw Pages.invalid()}
        let generation = try Pages.inlineGeneration(db,row:row)
        let prefix = Pages.prefix(id,generation)
        let staged = try Row.fetchCursor(db,sql:"SELECT \(Self.canonicalRecordColumns) FROM records WHERE id>=? AND id<? AND project_id=? AND type='storage_job' ORDER BY id",arguments:[prefix,prefix + "~",project])
        let descriptors = try Row.fetchCursor(db,sql:"SELECT object.key, CAST(object.value AS BLOB) AS bytes FROM records,json_each(records.data,'$.objects') object WHERE records.rowid=?",arguments:[row])
        var offset = 0,pages: [JSON] = [],hasLinks = false
        var paths = Set<String>()
        var scope = parent
        scope["descriptor_page_generation"] = generation
        func next(_ index: Int) throws -> (object: JSON,size: Int)? {
            guard let entry = try descriptors.next() else {return nil}
            let bytes: Data = entry["bytes"]
            guard entry["key"] as Int == index,bytes.count + 1 <= Pages.byteLimit,
                  let object = try JSONSerialization.jsonObject(with:bytes) as? JSON else {throw Pages.invalid()}
            let size = try jsonString(object).utf8.count + 1
            guard size <= Pages.byteLimit else {throw Pages.invalid()}
            if let path = object["relative_path"] as? String,!paths.insert(path).inserted {throw Pages.invalid()}
            return (object,size)
        }
        var lookahead = try next(0)
        while offset < total,pages.count < Pages.stageLimit {
            var entries: [JSON] = [],size = 0
            while let entry = lookahead,entries.count < Pages.countLimit,size + entry.size <= Pages.byteLimit {
                entries.append(entry.object);size += entry.size
                lookahead = try next(offset + entries.count)
            }
            guard !entries.isEmpty else {throw Pages.invalid()}
            hasLinks = hasLinks || entries.contains {$0["kind"] as? String == "symlink"}
            let key = Pages.id(prefix,offset)
            let pageState = entries.contains {$0["state"] as? String == "pending"} ? "pending" : "completed"
            if pages.isEmpty,let saved = try staged.next() {
                let page = try GRDBRecordEnvelopeAdapter.decode(saved,expectedType:"storage_job").object
                let prior = try Pages.activePage(page,parent:scope,offset:offset)
                guard page["page_state"] as? String == pageState,int(page,"revision") == 1,
                      int(page,"cleanup_policy_version") == int(parent,"cleanup_policy_version"),
                      try Data(jsonString(prior).utf8) == Data(jsonString(entries).utf8) else {throw Pages.invalid()}
            } else {
                pages.append(["id":key,"project_id":project,"kind":Self.ticketObjectDeletionKind,"cause":Pages.cause,
                              "state":"descriptor_page","revision":1,"page_parent":id,"page_generation":generation,"page_offset":offset,
                              "page_state":pageState,"cleanup_policy_version":int(parent,"cleanup_policy_version"),"objects":entries])
            }
            offset += entries.count
        }
        let complete = offset == total
        if complete,lookahead != nil {throw Pages.invalid()}
        if pages.isEmpty,try staged.next() != nil {throw Pages.invalid()}
        let activation: PreparedTicketObjectDeletionReceipt?
        if complete {
            guard let prior = try Row.fetchOne(db,sql:"SELECT \(Self.canonicalRecordColumns) FROM records WHERE rowid=? AND id=? AND project_id=? AND type='storage_job'",arguments:[row,id,project]) else {throw Pages.invalid()}
            var activated = parent
            activated["descriptor_legacy_trash_binding"] = parent["media_trash_directory"] != nil
            activated["descriptor_page_generation"] = generation
            activated["descriptor_page_prefix"] = prefix
            activated["descriptor_count"] = total
            activated["descriptor_has_links"] = hasLinks
            // Keep the ordinary full prior-envelope check on the reader. The
            // writer only fences and replaces the existing inline row.
            activation = try PreparedTicketObjectDeletionReceipt(revised(activated),previous:prior)
        } else {activation = nil}
        let fence = try TicketCleanupFence(db,inventory:TicketCleanupInventory(),project:project,ids:[id],fencesScanMetadata:false)
        return .init(fence:fence,conversion:.init(parent:parent,pages:pages,generation:generation,count:total,activation:activation),row:row)
    }

    func commitTicketBytePageConversion(_ db: Database, work: TicketBytePageConversion, index: Int) throws {
        let receipt = try StoredRecord(work.parent,family:"storage_job").string("id")
        try withValidatedDomainTransaction(db) {
            if index < work.pages.count {
                let page = work.pages[index],id = try StoredRecord(page,family:"descriptor_page").string("id")
                try self.save(db,page,type:"storage_job")
                for key in ["ticket-cleanup-backup-seen:","ticket-cleanup-copy-retry-seen:"] {
                    try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) SELECT ?,value FROM metadata WHERE key=?",arguments:[key + id,key + receipt])
                }
            } else {
                guard let activation = work.activation else {throw TicketCleanupDescriptorPages.invalid()}
                try commitPreparedTicketObjectDeletionReceipt(db,activation)
            }
            return .commit
        }
    }
}

extension CommandRouter {
    func prepareTicketBytePageExecution(_ db: Database, parent: JSON, row: Int64) throws -> TicketBytePagePass? {
        typealias Pages = TicketCleanupDescriptorPages
        let header = StoredRecord(parent,family:"storage_job")
        let receiptID = try header.string("id"),project = try header.string("project_id")
        let generation = try ticketCleanupBackupGenerationRow(db)
        let readiness = Self.ticketObjectDeletionReadySQL(data:"page.data",id:"page.id",cause:"?",state:"json_extract(page.data,'$.page_state')")
        let cause = try header.string("cause")
        // The cause appears three times in the shared readiness expression.
        let prefix = Pages.prefix(receiptID,try header.string("descriptor_page_generation"))
        guard parent["descriptor_page_prefix"] as? String == prefix else {throw Pages.invalid()}
        let rows = try Row.fetchCursor(db,sql:"""
            SELECT \(Self.canonicalRecordColumns), (\(readiness)) AS page_ready
            FROM records page WHERE id>=? AND id<? AND project_id=? AND type='storage_job' ORDER BY id
            """,arguments:[cause,cause,cause,prefix,prefix + "~",project])
        let hasLinks = bool(parent,"descriptor_has_links")
        var observations: [JSON] = [],ready: [(id: String, offset: Int)] = []
        var offset = 0,linkBytes = 0
        while let raw = try rows.next() {
            let page = try GRDBRecordEnvelopeAdapter.decode(raw,expectedType:"storage_job").object
            let original = try Pages.activePage(page,parent:parent,offset:offset)
            if raw["page_ready"] as Bool {
                ready.append((try StoredRecord(page,family:"descriptor_page").string("id"),offset))
                if !hasLinks {break}
            }
            if hasLinks {
                var working = parent
                working["state"] = page["page_state"];working["objects"] = original
                try rearmTicketObjectCopyFailures(db,receipt:&working,backupGenerationRow:generation,markerID:page["id"] as? String)
                for object in working["objects"] as? [JSON] ?? [] {
                    // Avoid retaining other pages' full descriptor payloads.
                    var projection = object.filter {["state","relative_path","kind","sha256","link_target","last_failure"].contains($0.key)}
                    if strings(object,"reasons").contains("ambiguous_identity") {projection["reasons"] = ["ambiguous_identity"]}
                    linkBytes += 256 + projection.values.reduce(0) {$0 + (($1 as? String)?.utf8.count ?? 0)}
                    guard linkBytes <= TicketCleanupBatchInventory.byteLimit else {
                        throw CoreError("CLEANUP_INVENTORY_LIMIT","The byte receipt's cross-page link graph exceeds its read budget; bytes retained.")
                    }
                    observations.append(projection)
                }
            }
            offset += original.count
        }
        if hasLinks,offset != int(parent,"descriptor_count",default:-1) {throw Pages.invalid()}
        let originalStates = observations.map {$0["state"] as? String}
        let pendingTargets = hasLinks ? Self.retainTicketObjectDeletionLinkTargets(&observations) : []
        // A changed pending link can make its capture uncertain. Its exact
        // final check must happen before any file in any page can be removed.
        let linksOnly = observations.contains {$0["kind"] as? String == "symlink" && $0["state"] as? String == "pending"}
        var selected: (page: JSON, receipt: JSON, links: TicketBytePageLinks, reactivated: Bool)?
        for entry in ready {
            let page = try record(db,entry.id,type:"storage_job")
            var receipt = parent
            receipt["state"] = page["page_state"];receipt["objects"] = page["objects"]
            let reactivated = receipt["state"] as? String == "completed"
            try rearmTicketObjectCopyFailures(db,receipt:&receipt,backupGenerationRow:generation,markerID:page["id"] as? String)
            if reactivated {receipt["state"] = "pending"}
            if cause == "task_purge" {receipt["cleanup_policy_version"] = 2}
            let objects = try StoredRecord(receipt,family:"descriptor_page").objects("objects")
            let holds = hasLinks ? Dictionary(uniqueKeysWithValues:objects.indices.compactMap {index -> (Int,[String])? in
                let projected = entry.offset + index
                guard originalStates[projected] == "pending",observations[projected]["state"] as? String == "retained" else {return nil}
                return (index,strings(observations[projected],"reasons"))
            }) : [:]
            guard !holds.isEmpty || objects.contains(where:{object in
                object["state"] as? String == "pending" && (!linksOnly || object["kind"] as? String == "symlink") &&
                    !pendingTargets.contains(object["relative_path"] as? String ?? "")
            }) else {continue}
            let links = TicketBytePageLinks(holds:holds,pendingTargets:pendingTargets,linksOnly:linksOnly)
            selected = (page,receipt,links,reactivated)
            break
        }
        guard let selected else {
            if !ready.isEmpty {throw Pages.invalid()}
            return nil
        }
        let receipt = selected.receipt
        let inventory = Self.isLegacyDoneEvidenceDeletion(receipt) ? TicketCleanupInventory() : try ticketCleanupInventory(db,receipt:receipt)
        let graph = Self.isLegacyDoneEvidenceDeletion(receipt) ? [] : try ticketCleanupDeletionReferences(db,receipt:receipt,inventory:inventory)
        let historicalOwners = cause == "done_evidence" ? Set((receipt["owned_record_fingerprints"] as? [String:String] ?? [:]).keys.map {Data($0.utf8)}) : []
        let references = try TicketObjectDeletionReferenceIndex(graph,tokens:inventory.tokens,historicalOwners:historicalOwners)
        var backup: StorageBackupRetentionIndex? = Self.isLegacyDoneEvidenceDeletion(receipt) ? nil : observeTicketCleanupBackupRetentionIndex(db,objects:(receipt["objects"] as? [JSON] ?? []).filter {$0["state"] as? String == "pending"})
        let mediaComplete = (try? ticketCleanupValidateMediaAuthority(db)) != nil
        let pageID = try StoredRecord(selected.page,family:"descriptor_page").string("id")
        let fence = try TicketCleanupFence(db,inventory:inventory,project:project,ids:[receiptID,pageID,try header.string("task_id"),project])
        var prepared = try prepareTicketObjectDeletionCandidates(db,receipt:receipt,reactivated:selected.reactivated,backupGenerationRow:generation,references:references,backup:&backup,mediaComplete:mediaComplete,fence:fence,pageLinks:selected.links)
        prepared.page = .init(parent:parent,page:selected.page,links:selected.links)
        return .init(prepared:prepared,row:row)
    }

    // Every page outcome and the receipt summary/revision publish together.
    // No client can see a mixed revision or a fabricated moved file outcome.
    func saveTicketBytePage(_ db: Database, receipt: JSON, execution: TicketBytePageExecution, generation: Int64? = nil) throws -> JSON {
        typealias Pages = TicketCleanupDescriptorPages
        let id = try StoredRecord(receipt,family:"storage_job").string("id")
        let pageID = try StoredRecord(execution.page,family:"descriptor_page").string("id")
        let objects = try StoredRecord(receipt,family:"descriptor_page").objects("objects")
        var parent = try record(db,id,type:"storage_job")
        var page = try record(db,pageID,type:"storage_job")
        let old = try Pages.activePage(page,parent:parent,offset:int(execution.page,"page_offset"))
        guard objects.count == old.count else {throw Pages.invalid()}
        let summary = Self.ticketObjectDeletionSummary(objects)
        parent["summary"] = try Pages.adding(summary,to:try StoredRecord(parent,family:"storage_job").object("summary"),replacing:Self.ticketObjectDeletionSummary(old))
        parent["state"] = int(parent["summary"] as? JSON ?? [:],"pending_count") > 0 ? "pending" : "completed"
        for key in ["media_trash_directory","media_trash_source_root","checked_at","cleanup_policy_version"] {
            if let value = receipt[key] {parent[key] = value}
        }
        page["cleanup_policy_version"] = receipt["cleanup_policy_version"]
        page["objects"] = objects
        page["page_state"] = int(summary,"pending_count") > 0 ? "pending" : "completed"
        guard try jsonString(page).utf8.count <= TicketCleanupInventory.rowByteLimit else {throw Pages.invalid()}
        try save(db,revised(page),type:"storage_job")
        parent = revised(parent)
        try save(db,parent,type:"storage_job")
        if let generation {
            try db.execute(sql:"INSERT OR REPLACE INTO metadata(key,value) VALUES (?, '1'), (?,?)",arguments:["ticket-cleanup-copy-retry-seen:" + pageID,"ticket-cleanup-backup-seen:" + pageID,String(generation)])
        }
        var result = parent
        result["page_state"] = page["page_state"];result["objects"] = objects
        return result
    }
}

extension TicketBytePagePass {
    func validatePageJournal(_ db: Database) throws {
        let receipt: JSON, generation: String
        if let conversion {receipt = conversion.parent;generation = conversion.generation}
        else if let page = prepared?.page {receipt = page.parent;generation = try StoredRecord(receipt,family:"storage_job").string("descriptor_page_generation")}
        else {throw TicketCleanupDescriptorPages.invalid()}
        let id = try StoredRecord(receipt,family:"storage_job").string("id")
        let prefix = TicketCleanupDescriptorPages.prefix(id,generation)
        if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM ticket_cleanup_changes WHERE kind=0 AND id>=? AND id<?)",arguments:[Data(prefix.utf8),Data((prefix + "~").utf8)]) == true {
            throw CoreError("CLEANUP_CONCURRENT_WRITE","The staged byte descriptor pages changed; bytes retained.")
        }
    }

    func logWriterHold(seconds: TimeInterval,committed: Bool) {
        if let conversion,let id = conversion.parent["id"] as? String {
            let stages = conversion.pages
            if conversionIndex < stages.count {
                StoragePhaseTiming.writerHold(operation:"ticket_byte_page_stage",command:id,pass:int(stages[conversionIndex],"page_offset"),seconds:seconds,committed:committed)
            } else {
                StoragePhaseTiming.writerHold(operation:"ticket_byte_page_activate",command:id,pass:conversion.count,seconds:seconds,committed:committed)
            }
        } else if let page = prepared?.page,let id = page.parent["id"] as? String {
            StoragePhaseTiming.writerHold(operation:"ticket_byte_page_execute",command:id,pass:int(page.page,"page_offset"),seconds:seconds,committed:committed)
        }
    }
}
