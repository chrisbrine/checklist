import Foundation
import GRDB

/// Removal owns structural children, never the dependencies of a predecessor,
/// adopted example, shared type, project instruction or linked ticket.
struct MediaRoundDeletionPlan {
    let version: Int64
    let project: String
    let round: String
    let predecessor: String?
    let records: [PurgeRow]
    let history: MediaRoundDeletionHistory
    let historyProgress: Int?
    let bytes: TicketObjectDeletionPlan
    let audit: JSON
    let keptAttachments: [JSON]
    let handoffOnlyIDs: Set<Data>
    let fence: MediaRoundDeletionFence
    let recordSizes: [Data:Int]
    let batchGraph: Bool

    func graphWitness(_ id: String) throws -> MediaRoundDeletionFence.Record {
        guard let witness = fence.records[Data(id.utf8)] else {
            throw MediaRoundDeletionFence.changed("planned_record_missing",type:"record",id:Data(id.utf8))
        }
        return witness
    }
}

extension CommandRouter {
    static let mediaDeletionWriterBudget: TimeInterval = 0.4
    /// Existing reader expiry wakes maintenance. A released/expired lease can
    /// resume this receipt once; active leases keep it out of the ready queue.
    /// New leases are checked too, rather than trusting a saved deadline.
    static let mediaRoundDeletionReaderObjectReadySQL = """
        json_extract(object.value,'$.state')='retained'
        AND EXISTS(SELECT 1 FROM json_each(object.value,'$.reasons') reason WHERE reason.value='reader_lease')
        AND NOT EXISTS(SELECT 1 FROM json_each(object.value,'$.reasons') reason WHERE reason.type!='text' OR (reason.value NOT IN ('reader_lease','backup_authority','remaining_record','backup_required','backup_copy_unavailable','backup_authority_unavailable') AND reason.value NOT GLOB 'backup_index_error:*' AND reason.value NOT GLOB 'backup_copy_unverified:*'))
        AND json_type(object.value,'$.reader_hold_ids')='array'
        AND NOT EXISTS(SELECT 1 FROM records h INDEXED BY records_scope
            WHERE h.type='storage_hold' AND h.id IN (SELECT value FROM json_each(object.value,'$.reader_hold_ids'))
            AND json_extract(h.data,'$.state')='active'
            AND (COALESCE(json_type(h.data,'$.expires_at'),'missing') NOT IN ('integer','real')
                OR json_extract(h.data,'$.expires_at')>(julianday('now')-2440587.5)*86400.0))
        """
    static let mediaRoundDeletionReaderReadySQL = """
        json_extract(records.data,'$.cause')='media_round_delete'
        AND json_extract(records.data,'$.state')='completed'
        AND EXISTS(SELECT 1 FROM json_each(records.data,'$.objects') object WHERE \(mediaRoundDeletionReaderObjectReadySQL))
        """

    func mediaRoundDeletionReaderHoldIDs(_ db: Database,object: JSON) throws -> [String] {
        guard let relative = object["relative_path"] as? String else {return []}
        var needles = Set(strings(object,"owner_ids").map {Data($0.utf8)})
        for path in [relative,root.appendingPathComponent(relative).path,object["stored_path"] as? String ?? "",object["sha256"] as? String ?? ""] where !path.isEmpty {needles.insert(Data(path.utf8))}
        let values = try jsonString(needles.map {String(decoding:$0,as:UTF8.self)})
        return try String.fetchAll(db,sql:"SELECT h.id FROM records h INDEXED BY records_scope WHERE h.type='storage_hold' AND json_extract(h.data,'$.state')='active' AND COALESCE(json_extract(h.data,'$.kind'),'') NOT IN ('media_reference','backup') AND (COALESCE(json_type(h.data,'$.expires_at'),'missing') NOT IN ('integer','real') OR json_extract(h.data,'$.expires_at')>?) AND EXISTS(SELECT 1 FROM json_tree(h.data) token WHERE (token.type='text' AND CAST(token.atom AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?))) OR (typeof(token.key)='text' AND CAST(token.key AS BLOB) IN (SELECT CAST(value AS BLOB) FROM json_each(?)))) ORDER BY CAST(h.id AS BLOB)",arguments:[Date().timeIntervalSince1970,values,values])
    }

    func mediaRoundDeletionReaderCanResume(_ db: Database,receipt: String,object: JSON) throws -> Bool {
        guard let path = object["relative_path"] as? String else {return false}
        return try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM records,json_each(records.data,'$.objects') object WHERE records.id=CAST(? AS TEXT) AND json_extract(object.value,'$.relative_path')=CAST(? AS TEXT) AND " + Self.mediaRoundDeletionReaderObjectReadySQL + ")",arguments:[Data(receipt.utf8),Data(path.utf8)]) == true
    }

    func mediaRoundDeletionView(_ receipt: JSON) throws -> JSON {
        guard receipt["cause"] as? String == "media_round_delete",var result = receipt["deletion"] as? JSON else {
            throw CoreError("NOT_FOUND","No media round deletion receipt exists in this project.")
        }
        result["byte_deletion_receipt_id"] = receipt["id"]
        result["cleanup_state"] = receipt["state"]
        // Earlier CL-446 receipts predate ticket-preserving deletion. Their
        // empty kept set is known; no unrecorded timing is invented.
        if result["kept_attachments"] == nil {result["kept_attachments"] = [JSON]()}
        result["files"] = (receipt["objects"] as? [JSON] ?? []).map { object -> JSON in
            let state = object["state"] as? String ?? "retained"
            var reasons = strings(object,"reasons"),status = "kept"
            if state == "removed",bool(object,"moved_to_trash") {status = "moved";reasons = ["moved_to_trash"]}
            else if state == "pending" {status = "held";reasons = [object["last_failure"] as? String ?? "pending_cleanup"]}
            else if state == "already_missing" {reasons = ["already_missing"]}
            else if reasons.contains(where:{Self.ticketObjectDeletionRetryReasons.contains($0) || $0.hasPrefix("backup_") || ["reader_lease","media_owner"].contains($0)}) {status = "held"}
            if reasons.isEmpty {reasons = ["identity_unavailable"]}
            var file: JSON = ["status":status,"reason":reasons[0],"reasons":reasons,"representation":object["representation"] ?? "original"]
            file["relative_path"] = object["relative_path"]
            return file
        }
        return result
    }

    func mediaRoundDeletionGet(_ db: Database,_ p: JSON,project: String) throws -> JSON {
        let rid = try text(p,"round_id")
        let key = DeletionGraph.key(try MediaRoundDeletionHistory.progressKey(project:project,round:rid))
        if let progress = try DeletionGraph.load(db,key,as:DeletionGraph.Progress.self) {
            try progress.validate(project:project,round:rid)
            if progress.phase != .staging {return progress.view}
        }
        guard let row = try Row.fetchOne(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE project_id=CAST(? AS TEXT) AND type='storage_job' AND json_extract(data,'$.cause')='media_round_delete' AND json_extract(data,'$.round_id')=CAST(? AS TEXT) ORDER BY rowid DESC LIMIT 1",arguments:[Data(project.utf8),Data(rid.utf8)]) else {
            throw CoreError("NOT_FOUND","No media round deletion receipt exists in this project.")
        }
        let receipt = try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"storage_job").object
        return try mediaRoundDeletionView(mediaGraphReceiptAudit(db,ticketObjectDeletionReceiptWithObjects(db,receipt:receipt)))
    }

    /// All graph work and preview hashing happen on a separate read-only
    /// snapshot. A narrow changed-row fence preserves unrelated service writes,
    /// including eventless/same-revision edits outside the deletion graph.
    func executeMediaRoundDelete(_ p: JSON,_ c: Caller,command: String,digest: String,expectedAuthorizationGeneration: String?) throws -> JSON {
        var preparation: TimeInterval = 0, phases: [String:Double] = [:]
        var historyLimit = MediaRoundDeletionHistory.passLimit
        var interruptedGraph: String?
        do {
            while true {
                do {
                    if let result = try autoreleasepool(invoking: {
                        try executeMediaRoundDeletionPass(p,c,command:command,digest:digest,
                            expectedAuthorizationGeneration:expectedAuthorizationGeneration,historyLimit:historyLimit,
                            preparation:&preparation,phases:&phases)
                    }) {return result}
                    interruptedGraph = nil
                } catch let budget as MediaRoundDeletionWriterBudget {
                    switch budget {
                    case .history, .graph("media_round_graph_hide"), .graph("media_round_history_pass"):
                        guard historyLimit > 1 else {throw Self.mediaDeletionBudgetError()}
                        historyLimit /= 2
                    case .graph(let phase):
                        guard interruptedGraph != phase else {throw Self.mediaDeletionBudgetError()}
                        interruptedGraph = phase
                    }
                }
            }
        } catch let pending as MediaRoundDeletionImportRecovery.Pending {
            let operation = Self.commandOperationID(principal:c.principal,command:command)
            guard commandOperations.isExecuting(operation) else {
                throw CoreError("MEDIA_IMPORT_RECOVERY_PENDING", "Round deletion can continue after managed import recovery.")
            }
            // The preparation journal is already closed. Register on the same
            // writer that settles imports, rechecking witnesses to avoid a lost wake.
            let ids = try jsonString(pending.imports)
            try dbQueue.writeWithoutTransaction { db in
                if let expectedAuthorizationGeneration {
                    _ = try self.backupWriteAuthorization(db,params:p,caller:c,expectedGeneration:expectedAuthorizationGeneration)
                }
                let live = try Data.fetchAll(db,sql:"""
                    SELECT CAST(r.id AS BLOB) FROM json_each(?) i CROSS JOIN records r ON r.id=CAST(i.value AS TEXT)
                    WHERE r.type='storage_job' AND json_extract(r.data,'$.kind')='attachment_import'
                        AND \(MediaRoundDeletionImportRecovery.needsReceiptSQL("r.data"))
                    """, arguments:[ids])
                self.commandOperations.mediaImportWaits.park(operation,imports:Set(live),failures:self.managedImportRecoveryFailures)
            }
            throw MediaRoundDeletionAdmissionDeferred()
        }
    }

    private static func mediaDeletionBudgetError() -> CoreError {
        CoreError("CLEANUP_INVENTORY_LIMIT","A round deletion pass exceeded its writer budget. Read deletion progress before resuming.")
    }

    func withMediaRoundDeletionWrite<T>(_ body: () throws -> T) throws -> T {
        // Legacy synchronous callers already hold a reservation. An accepted
        // operation reserves a writer only for this one bounded step.
        guard Thread.current.threadDictionary[commandOperations.contextKey] != nil else {return try body()}
        guard let result = try backupWrites.withImmediateAccess(body) else {throw MediaRoundDeletionAdmissionDeferred()}
        return result
    }

    private func executeMediaRoundDeletionPass(_ p: JSON,_ c: Caller,command: String,digest: String,
                                               expectedAuthorizationGeneration: String?,historyLimit: Int,
                                               preparation: inout TimeInterval,phases: inout [String:Double]) throws -> JSON? {
        let passStarted = ProcessInfo.processInfo.systemUptime
        var writerTiming: (operation: String, pass: Int, seconds: TimeInterval)?
        var committed = false
        var writerStep = "fence"
        var journalClosed = false
        defer {
            if let timing = writerTiming {
                StoragePhaseTiming.writerHold(operation:timing.operation,command:command,pass:timing.pass,seconds:timing.seconds,
                                              committed:committed,elapsedSeconds:ProcessInfo.processInfo.systemUptime - passStarted,
                                              interruptedStep:committed ? nil : writerStep)
                mediaRoundDeletionWriterProbe?(timing.operation,timing.seconds,committed)
            }
        }
        var configuration = Configuration();configuration.readonly = true
        configuration.qos = .utility
        configuration.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        let observer = try DatabaseQueue(path:root.appendingPathComponent("checklist.sqlite").path,configuration:configuration)
        defer {try? observer.close()}
        let changes = MediaRoundDeletionChanges()
        let (writerVersion,preparationProject) = try withMediaRoundDeletionWrite {
            try dbQueue.writeWithoutTransaction {db in
                let project = try self.mediaAccess(db,p,c,write:true)
                let version = try changes.install(db),key = Data(project.utf8)
                self.mediaRoundDeletionPreparations[key,default:[]].insert(changes.name)
                return (version,key)
            }
        }
        defer {
            // TEMP schema and in-memory bookkeeping only. A backup may have
            // taken admission while the reader was preparing the pass.
            try? dbQueue.writeWithoutTransaction {db in
                self.mediaRoundDeletionPreparations[preparationProject]?.remove(changes.name)
                if self.mediaRoundDeletionPreparations[preparationProject]?.isEmpty == true {self.mediaRoundDeletionPreparations.removeValue(forKey:preparationProject)}
                if !committed || !journalClosed {try changes.remove(db)}
            }
        }
        var plan: MediaRoundDeletionPlan?,replay: JSON?
        var existingGraph: (GraphDeletionContext,DeletionGraph.Progress,DeletionGraph.Work?)?
        var resumeHistory: MediaGraphResumeHistory?
        var graphContext: GraphDeletionContext?
        try observer.read {db in
            let project = try self.mediaAccess(db,p,c,write:true)
            try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:c)
            if let row = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[c.principal,command]) {
                guard row["digest"] as String == digest else {throw CoreError("IDEMPOTENCY_CONFLICT","This command ID has a different intent.")}
                var result = jsonObject(row["result"])
                if Self.isPrunedResult(result) {throw Self.expiredCommandError(command)}
                result = try self.mediaGraphFirstReply(db,result)
                result["replayed"] = true;replay = result;return
            }
            try self.requireAgentEditAuthority(db,project:self.record(db,project,type:"project"),caller:c)
            let round = try text(p,"round_id")
            let historyKey = try MediaRoundDeletionHistory.progressKey(project:project,round:round)
            let context = GraphDeletionContext(params:p,caller:c,expectedAuthorizationGeneration:expectedAuthorizationGeneration,
                                               command:command,digest:digest,project:project,round:round,
                                               historyKey:historyKey,observer:observer,changes:changes,writerVersion:writerVersion)
            graphContext = context
            if let progress = try DeletionGraph.load(db,context.key,as:DeletionGraph.Progress.self) {
                try progress.validate(project:project,round:round)
                if progress.phase != .staging {
                    _ = try text(p,"reason",max:4000)
                    try self.mediaRevision(p,["revision":progress.revision])
                }
                let work: DeletionGraph.Work?
                if progress.phase == .deleting {
                    let saved = try self.loadMediaDeletionGraph(db,progress,context:context)
                    resumeHistory = try self.validateMediaDeletionGraphResume(db,progress:progress,work:saved,
                                                                             historyKey:historyKey,historyLimit:historyLimit)
                    work = saved
                } else { work = nil }
                existingGraph = (context,progress,work)
                return
            }
            plan = try self.prepareMediaRoundDeletion(db,p,c,project:project,command:command,historyLimit:historyLimit)
            try self.mediaRoundDeletionPreparationProbe?()
        }
        if let replay {return replay}
        if let (context,progress,work) = existingGraph {
            if progress.phase == .staging {
                try discardStagedMediaDeletionGraph(context,progress:progress)
                return nil
            }
            if let work, let resumeHistory {
                try scrubResumedMediaGraphHistory(context,progress:progress,work:work,history:resumeHistory)
                return nil
            }
            return try continueMediaDeletionGraph(context,progress:progress,work:work)
        }
        guard let plan, let graphContext else {throw MediaRoundDeletionFence.changed("plan_unavailable",type:"media_round",id:Data((try text(p,"round_id")).utf8))}
        preparation += plan.audit["preparation_seconds"] as? Double ?? 0
        for (phase, seconds) in plan.audit["preparation_timings"] as? [String:Double] ?? [:] {phases[phase,default:0] += seconds}
        var audit = plan.audit
        audit["preparation_seconds"] = preparation;audit["preparation_timings"] = phases
        if plan.batchGraph && !plan.history.more {
            do {return try startMediaDeletionGraph(graphContext,plan:plan,audit:audit)}
            catch let error as CoreError where error.code == "MEDIA_CONTEXT_CHANGED" {
                throw Self.mediaDeletionTiming(error,audit:audit)
            }
        }
        let historyWrites = try plan.history.prepareWrites()
        let final: (receipt: PreparedTicketObjectDeletionReceipt, reply: JSON, encoded: String, ownedRows: String?)?
        if plan.history.more {final = nil}
        else {
            let id = uuid()
            let fields: JSON = ["round_id":plan.round,"deletion":audit,"parent_principal":c.principal,"parent_command_id":command,"intent_digest":digest]
            let receipt = Self.ticketObjectDeletionReceipt(project:plan.project,task:plan.round,cause:"media_round_delete",plan:plan.bytes,id:id,additionalFields:fields)
            let reply = try mediaRoundDeletionView(receipt)
            let ownedRows = plan.history.continuing ? try jsonString(plan.records.map { row in
                guard let observed = plan.fence.records[row.key] else {
                    throw MediaRoundDeletionFence.changed("planned_record_missing",type:row.type,id:row.key)
                }
                return observed.position
            }.sorted()) : nil
            final = (try PreparedTicketObjectDeletionReceipt(receipt),reply,try jsonString(reply),ownedRows)
        }
        let progressKey = try MediaRoundDeletionHistory.progressKey(project:plan.project,round:plan.round)
        let pass = (plan.historyProgress ?? 0) + 1
        let operation = plan.history.continuing ? "media_round_history_pass" : "media_round_deletion_commit"
        do {return try ArchiveStorageGate.withExclusive(root:root) {_ in
            try self.withMediaRoundDeletionWrite {
                try self.dbQueue.writeWithoutTransaction {db -> JSON? in
                    let started = ProcessInfo.processInfo.systemUptime
                    defer {writerTiming = (operation,pass,ProcessInfo.processInfo.systemUptime-started)}
                    var result: JSON?
                    func apply() throws {
                        try self.withValidatedDomainTransaction(db) {
                            let project = try self.mediaAccess(db,p,c,write:true)
                            if let expectedAuthorizationGeneration {
                                _ = try self.backupWriteAuthorization(db,params:p,caller:c,expectedGeneration:expectedAuthorizationGeneration)
                            }
                            try self.requirePendingCommandIntent(db,command:command,digest:digest,caller:c)
                            if let row = try Row.fetchOne(db,sql:"SELECT digest,result FROM commands WHERE principal=? AND command_id=?",arguments:[c.principal,command]) {
                                guard row["digest"] as String == digest else {throw CoreError("IDEMPOTENCY_CONFLICT","This command ID has a different intent.")}
                                var replay = jsonObject(row["result"])
                                if Self.isPrunedResult(replay) {throw Self.expiredCommandError(command)}
                                replay = try self.mediaGraphFirstReply(db,replay)
                                replay["replayed"] = true;result = replay;return .commit
                            }
                            try self.requireAgentEditAuthority(db,project:self.record(db,project,type:"project"),caller:c)
                            guard EnvelopeStorageIdentity.equal(project,plan.project) else {throw MediaRoundDeletionFence.changed("project_scope",type:"project",id:Data(plan.project.utf8))}
                            if try observer.read({try Int64.fetchOne($0,sql:"PRAGMA data_version")!}) != plan.version {
                                try plan.fence.validate(db,changes:changes,writerVersion:writerVersion)
                                try plan.history.validateResultDependents(db,journal:changes.name,removed:plan.history.more ? [] : Set(plan.records.map(\.key)))
                            }
                            let current = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[progressKey])
                            guard current == plan.historyProgress.map(String.init) else {throw MediaRoundDeletionFence.changed("history_progress",type:"media_round",id:Data(plan.round.utf8))}
                            if plan.history.continuing {
                                // The fence is closed and no other writer can enter this transaction.
                                // The remaining observers still journal these changes for their own fences.
                                try changes.remove(db)
                                journalClosed = true
                            }
                            if plan.history.more {
                                writerStep = "history"
                                try plan.history.apply(db,writes:historyWrites)
                                try db.execute(sql:"INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[progressKey,String(pass)])
                                writerStep = "commit"
                                guard ProcessInfo.processInfo.systemUptime - started < Self.mediaDeletionWriterBudget else {
                                    throw MediaRoundDeletionWriterBudget.history
                                }
                                return .commit
                            }
                            guard let final else {throw MediaRoundDeletionFence.changed("plan_unavailable",type:"media_round",id:Data(plan.round.utf8))}
                            writerStep = "byte_receipt"
                            // The content-free first outcome remains replayable while
                            // this durable receipt exists, under ordinary pruning rules.
                            let backup = try plan.bytes.objects.isEmpty ? nil : self.ticketCleanupBackupGenerationRow(db)
                            try self.commitPreparedTicketObjectDeletionReceipt(db,final.receipt)
                            if let backup {try self.markTicketObjectDeletionBackupGeneration(db,receipt:final.receipt.id,generation:backup)}
                            writerStep = "kept_attachments"
                            for attachment in plan.keptAttachments {try self.save(db,attachment,type:"attachment")}
                            writerStep = "graph"
                            if let ownedRows = final.ownedRows {
                                // The snapshot fence covers each row's position, exact identity,
                                // type, project and content. Delete those positions directly.
                                try db.execute(sql:"DELETE FROM records WHERE rowid IN (SELECT value FROM json_each(?))",arguments:[ownedRows])
                                guard db.changesCount == plan.records.count else {
                                    throw MediaRoundDeletionFence.changed("owned_record_delete",type:"media_round",id:Data(plan.round.utf8))
                                }
                            } else {
                                for row in plan.records {
                                    try db.execute(sql:"DELETE FROM records WHERE id=CAST(? AS TEXT) AND project_id=CAST(? AS TEXT) AND type=CAST(? AS TEXT)",arguments:[Data(row.id.utf8),Data(project.utf8),Data(row.type.utf8)])
                                    guard db.changesCount == 1 else {throw MediaRoundDeletionFence.changed("owned_record_delete",type:row.type,id:Data(row.id.utf8))}
                                }
                            }
                            writerStep = "retirement"
                            try plan.history.apply(db,writes:historyWrites)
                            if plan.historyProgress != nil {try db.execute(sql:"DELETE FROM metadata WHERE key=?",arguments:[progressKey])}
                            try CommandOperationPurgeEpoch.advance(db,project:project)
                            try self.event(db,caller:c,project:project,entity:plan.round,kind:"media_round_deleted",data:audit)
                            try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[c.principal,command,digest,final.encoded])
                            result = final.reply
                            writerStep = "commit"
                            guard ProcessInfo.processInfo.systemUptime - started < Self.mediaDeletionWriterBudget else {
                                throw MediaRoundDeletionWriterBudget.history
                            }
                            return .commit
                        }
                    }
                    guard try Self.withPruneStepBudget(db,seconds:Self.mediaDeletionWriterBudget,{try apply();return true}) == true else {
                        throw MediaRoundDeletionWriterBudget.history
                    }
                    committed = true
                    return result
                }
            }
        }} catch let error as CoreError where error.code == "MEDIA_CONTEXT_CHANGED" {
            throw Self.mediaDeletionTiming(error,audit:audit)
        }
    }

    private static func mediaDeletionTiming(_ error: CoreError,audit: JSON) -> CoreError {
        var details = error.details
        details["preparation_seconds"] = audit["preparation_seconds"]
        details["preparation_timings"] = audit["preparation_timings"]
        return CoreError(error.code,error.message,details:details)
    }

    private func prepareMediaRoundDeletion(_ db: Database,_ p: JSON,_ c: Caller,project: String,command: String,historyLimit: Int) throws -> MediaRoundDeletionPlan {
        let started = ProcessInfo.processInfo.systemUptime
        let timing = StoragePhaseTiming(operation:"media_round_graph_prepare",command:command,
                                       uptime:{ProcessInfo.processInfo.systemUptime})
        var result = "failed"
        timing.record("graph_selection")
        defer {timing.record(result,terminal:true)}
        let version = try Int64.fetchOne(db,sql:"PRAGMA data_version")!
        let rid = try text(p,"round_id"),round = try scoped(db,rid,project,type:"media_round")
        let progressKey = try MediaRoundDeletionHistory.progressKey(project:project,round:rid)
        let progressValue = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[progressKey])
        let progress = progressValue.flatMap(Int.init)
        if progressValue != nil {
            guard let progress,progress > 0,progress < Int.max else {throw StoreRecovery.required("media_deletion_history_progress_invalid")}
        }
        try mediaRevision(p,round)
        let reason = try text(p,"reason",max:4000)
        guard ["closed","canceled","archived"].contains(round["state"] as? String ?? "") else {
            throw CoreError("MEDIA_ROUND_NOT_CLOSED","Finish or cancel the round before deleting it. Draft and Open rounds cannot be deleted.")
        }
        let hiddenSuccessors = try DeletionGraph.successorPrefix(project:project,predecessor:rid)
        if let successor = try String.fetchOne(db,sql:"""
            SELECT id FROM records WHERE project_id=CAST(? AS TEXT) AND type='media_round'
              AND json_extract(data,'$.predecessor_round_id')=CAST(? AS TEXT) COLLATE BINARY
            UNION ALL SELECT value FROM metadata WHERE key GLOB ?
            ORDER BY id COLLATE BINARY LIMIT 1
            """,arguments:[Data(project.utf8),Data(rid.utf8),hiddenSuccessors + "*"]) {
            throw CoreError("MEDIA_ROUND_REFERENCED","Delete the successor round before deleting its predecessor.",details:["record_id":successor,"record_type":"media_round"])
        }
        // Retain only the selected structural graph. The existing corpus stream
        // validates unrelated envelopes without retaining their private payloads.
        var selected: [Data:PurgeRow] = [:], selectedSizes: [Data:Int] = [:], selectedBytes = 0
        func add(_ value: JSON,type: String) throws {
            let id = try StoredRecord(value,family:type).string("id")
            guard selected[Data(id.utf8)] == nil else {return}
            let size = try jsonString(value).utf8.count
            selectedBytes += size
            guard size <= TicketCleanupInventory.rowByteLimit,selectedBytes <= TicketCleanupInventory.byteLimit,selected.count < 100_000 else {
                throw CoreError("CLEANUP_INVENTORY_LIMIT","The round's owned records exceed 100,000 rows, 4 MiB per row or 16 MiB total; nothing was removed.")
            }
            guard EnvelopeStorageIdentity.equal(value["project_id"] as? String,project) else {throw CoreError("MEDIA_CAPTURE_INCOMPLETE","A round-owned record has foreign scope.")}
            selected[Data(id.utf8)] = .init(id:id,type:type,project:project,value:value)
            selectedSizes[Data(id.utf8)] = size
        }
        _ = try mediaRoundOwnedHistory(db,round:round) { original in
            var value = original
            let type = try StoredRecord(value,family:"media history").string("record_type")
            value.removeValue(forKey:"record_type");try add(value,type:type)
        }
        let mediaIDs = Set(selected.keys),itemIDs = Set(selected.values.filter {$0.type == "media_item"}.map(\.key))
        let scopedSources = try Row.fetchCursor(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE project_id=CAST(? AS TEXT) AND type='media_review_context' AND json_type(data,'$.round_id') IS NULL AND EXISTS(SELECT 1 FROM json_each(records.data,'$.item_ids') i WHERE i.value IN (SELECT value FROM json_each(?)))",arguments:[Data(project.utf8),try jsonString(itemIDs.sorted(by:{$0.lexicographicallyPrecedes($1)}).map {String(decoding:$0,as:UTF8.self)})])
        while let raw = try scopedSources.next() {
            let source = try GRDBRecordEnvelopeAdapter.decode(raw,expectedType:"media_review_context")
            if Set(strings(source.object,"item_ids").map {Data($0.utf8)}).isSubset(of:itemIDs) {try add(source.object,type:source.type)}
        }
        var ownerIDs = Set<Data>(),attachmentIDs = Set<Data>()
        for row in selected.values {
            if let id = row.value["attachment_owner_id"] as? String {ownerIDs.insert(Data(id.utf8))}
            if row.type == "media_candidate" {
                for ref in row.value["record_references"] as? [JSON] ?? [] where ref["type"] as? String == "attachment" {
                    if let id = ref["id"] as? String {attachmentIDs.insert(Data(id.utf8))}
                }
            }
        }
        // Published successors get new anchors for borrowed candidates. Only
        // anchors exclusive to this structural graph belong to its removal;
        // shared predecessor anchors and their attachments stay independent.
        let mediaKeys = try jsonString(mediaIDs.map {String(decoding:$0,as:UTF8.self)})
        let ownerKeys = try jsonString(ownerIDs.map {String(decoding:$0,as:UTF8.self)})
        let borrowed = try Data.fetchAll(db,sql:"SELECT DISTINCT CAST(json_extract(data,'$.attachment_owner_id') AS BLOB) FROM records WHERE project_id=CAST(? AS TEXT) AND type IN ('media_intake','media_item_target') AND id NOT IN (SELECT value FROM json_each(?)) AND json_extract(data,'$.attachment_owner_id') IN (SELECT value FROM json_each(?))",arguments:[Data(project.utf8),mediaKeys,ownerKeys])
        ownerIDs.subtract(borrowed)
        for rawID in ownerIDs.sorted(by:{$0.lexicographicallyPrecedes($1)}) {
            let id = String(decoding:rawID,as:UTF8.self)
            let value = try scoped(db,id,project,type:"storage_job")
            guard value["kind"] as? String == "media_attachment_owner" else {throw CoreError("MEDIA_CAPTURE_INCOMPLETE","A round capture owner is unavailable.")}
            try add(value,type:"storage_job")
        }
        let anchors = try jsonString(ownerIDs.sorted(by:{$0.lexicographicallyPrecedes($1)}).map {String(decoding:$0,as:UTF8.self)})
        let storage = try Row.fetchCursor(db,sql:"SELECT " + Self.canonicalRecordColumns + " FROM records WHERE project_id=CAST(? AS TEXT) AND ((type='storage_hold' AND json_extract(data,'$.kind')='media_reference' AND json_extract(data,'$.owner_id') IN (SELECT value FROM json_each(?))) OR (type='storage_job' AND json_extract(data,'$.kind')='attachment_import' AND json_extract(data,'$.attachment_owner_id') IN (SELECT value FROM json_each(?))))",arguments:[Data(project.utf8),anchors,anchors])
        while let raw = try storage.next() {
            let e = try GRDBRecordEnvelopeAdapter.decode(raw);try add(e.object,type:e.type)
            if e.type == "storage_job",let id = e.object["attachment_id"] as? String,
               try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM records WHERE id=CAST(? AS TEXT) AND type='attachment')",arguments:[Data(id.utf8)]) == true {attachmentIDs.insert(Data(id.utf8))}
        }
        var handoffOnlyIDs = Set<Data>(),observedIDs = Set<Data>()
        var handoffBytes = 0
        let predecessor = round["predecessor_round_id"] as? String
        if let predecessorID = predecessor,
           let handoff = round["done_task_cleanup"] as? JSON,handoff["state"] as? String == "handed_off",
           let taskID = handoff["task_id"] as? String,!taskID.isEmpty,
           let handedIDs = handoff["attachment_ids"] as? [String],!handedIDs.isEmpty {
            // The handoff lists captures on its target ticket. Original capture
            // owners belong to intakes; successor targets only borrow references.
            let handoffs = try Row.fetchCursor(db,sql:"""
                WITH predecessor_intakes AS MATERIALIZED (
                    SELECT json_extract(i.data,'$.attachment_owner_id') AS owner_id,
                           min(i.id COLLATE BINARY) AS intake_id
                    FROM records predecessor CROSS JOIN records i
                    WHERE predecessor.id=CAST(? AS TEXT) AND predecessor.type='media_round'
                      AND predecessor.project_id=CAST(? AS TEXT)
                      AND i.type='media_intake' AND i.project_id=predecessor.project_id
                      AND json_extract(i.data,'$.round_id')=predecessor.id COLLATE BINARY
                      AND json_type(i.data,'$.attachment_owner_id')='text'
                    GROUP BY owner_id COLLATE BINARY
                )
                SELECT CAST(a.id AS BLOB) AS id,octet_length(a.data) AS size,
                       CAST(owner.id AS BLOB) AS owner_id,CAST(intake.intake_id AS BLOB) AS intake_id,
                       CAST(job.id AS BLOB) AS import_id
                FROM json_each(?) member
                CROSS JOIN records a ON a.id=member.value COLLATE BINARY
                LEFT JOIN records job ON json_type(a.data,'$.attachment_owner_id') IS NULL
                    AND json_type(a.data,'$.storage_job_id')='text'
                    AND job.id=json_extract(a.data,'$.storage_job_id') COLLATE BINARY
                    AND job.type='storage_job' AND job.project_id=a.project_id
                    AND json_extract(job.data,'$.kind')='attachment_import'
                    AND json_extract(job.data,'$.state') IN ('committed','settled','repair_required')
                    AND json_extract(job.data,'$.settled_reason') IS NOT 'canceled_media_staging'
                    AND json_extract(job.data,'$.attachment_owner_kind')='media_intake'
                    AND json_type(job.data,'$.attachment_owner_id')='text'
                    AND json_extract(job.data,'$.attachment_id')=a.id COLLATE BINARY
                JOIN records owner ON owner.id=CASE
                    WHEN json_type(a.data,'$.attachment_owner_id')='text' THEN json_extract(a.data,'$.attachment_owner_id')
                    ELSE json_extract(job.data,'$.attachment_owner_id') END COLLATE BINARY
                    AND owner.type='storage_job' AND owner.project_id=a.project_id
                    AND json_extract(owner.data,'$.kind')='media_attachment_owner'
                    AND json_extract(owner.data,'$.owner_kind')='media_intake'
                JOIN predecessor_intakes intake ON intake.owner_id=owner.id COLLATE BINARY
                WHERE a.project_id=CAST(? AS TEXT) AND a.type='attachment'
                  AND json_extract(a.data,'$.mode')='managed'
                  AND json_extract(a.data,'$.task_id')=CAST(? AS TEXT) COLLATE BINARY
                  AND json_extract(a.data,'$.media_cleanup_round_id')=CAST(? AS TEXT) COLLATE BINARY
                """,arguments:[Data(predecessorID.utf8),Data(project.utf8),try jsonString(handedIDs),
                               Data(project.utf8),Data(taskID.utf8),Data(rid.utf8)])
            while let row = try handoffs.next() {
                let id: Data = row["id"]
                guard handoffOnlyIDs.insert(id).inserted else {continue}
                if attachmentIDs.insert(id).inserted {
                    let size: Int = row["size"]
                    handoffBytes += size
                    guard attachmentIDs.count <= 100_000,size <= TicketCleanupInventory.rowByteLimit,
                          selectedBytes + handoffBytes <= TicketCleanupInventory.byteLimit else {
                        throw CoreError("CLEANUP_INVENTORY_LIMIT","The successor's ticket handoff exceeds the selected attachment or payload limit; nothing was removed.")
                    }
                }
                let owner: Data = row["owner_id"],intake: Data = row["intake_id"]
                observedIDs.formUnion([id,Data(predecessorID.utf8),owner,intake])
                if let job: Data = row["import_id"] {observedIDs.insert(job)}
            }
        }
        var keptAttachments: [JSON] = [],keptAudit: [JSON] = []
        for rawID in attachmentIDs.sorted(by:{$0.lexicographicallyPrecedes($1)}) {
            let id = String(decoding:rawID,as:UTF8.self)
            let attachment = try scoped(db,id,project,type:"attachment")
            if predecessor != nil,EnvelopeStorageIdentity.equal(attachment["media_cleanup_round_id"] as? String,rid),
               !handoffOnlyIDs.contains(rawID) {
                // Candidate references alone do not prove ownership. Own
                // captures reach this path via a selected owner or exact import.
                let owner = (attachment["attachment_owner_id"] as? String).map {Data($0.utf8)}
                let job = (attachment["storage_job_id"] as? String).flatMap {selected[Data($0.utf8)]}
                let ownedCapture = owner.map(ownerIDs.contains) ?? (job?.value["kind"] as? String == "attachment_import" &&
                    EnvelopeStorageIdentity.equal(job?.value["attachment_id"] as? String,id))
                if !ownedCapture {
                    continue
                }
            }
            if attachment["task_id"] != nil {
                guard let taskID = attachment["task_id"] as? String,!taskID.isEmpty else {throw CoreError("MEDIA_CAPTURE_INCOMPLETE","A captured attachment has malformed ticket ownership; nothing was removed.")}
                let task = try scoped(db,taskID,project,type:"task")
                let status = try scoped(db,try StoredRecord(task,family:"task").string("status_id"),project,type:"status")
                guard ["done","canceled"].contains(status["category"] as? String ?? "") else {
                    throw CoreError("MEDIA_ROUND_REFERENCED","An open ticket still owns a captured attachment; nothing was removed.",details:["record_id":id,"record_type":"attachment","task_id":taskID])
                }
                let ticketWitnesses = [Data(taskID.utf8),Data((try StoredRecord(status,family:"status").string("id")).utf8)]
                observedIDs.formUnion(ticketWitnesses)
                observedIDs.insert(rawID)
                keptAttachments.append(attachment)
                keptAudit.append(["attachment_id":id,"task_id":taskID,"task_key":try StoredRecord(task,family:"task").string("key"),"status":"kept","reason":"kept_with_ticket"])
                continue
            }
            try add(attachment,type:"attachment")
        }
        let removed = selected.values.sorted {$0.key.lexicographicallyPrecedes($1.key)},owned = Set(selected.keys)
        // Active capture anchors/import jobs leave with the round. Preserve
        // their IDs as explicitly historical provenance on the ticket attachment,
        // rather than keeping dangling live ownership references.
        for index in keptAttachments.indices {
            var attachment = keptAttachments[index]
            var history: JSON = ["format":1,"state":"round_deleted","round_id":rid]
            var detached = false,captureDetached = false
            for (field,historical) in [("attachment_owner_id","owner_id"),("storage_job_id","import_job_id"),("media_cleanup_round_id","round_id")] {
                guard let id = attachment[field] as? String,owned.contains(Data(id.utf8)) else {continue}
                detached = true;history[historical] = id;attachment.removeValue(forKey:field)
                if field != "media_cleanup_round_id" {captureDetached = true}
                if field == "attachment_owner_id",let owner = selected[Data(id.utf8)] {history["owner_kind"] = owner.value["owner_kind"]}
            }
            // A later adopting round must not overwrite the original capture's
            // already detached provenance with its own use of that attachment.
            let needsHistory = attachment["media_capture_history"] == nil
            if captureDetached || needsHistory {attachment["media_capture_history"] = history}
            if detached || needsHistory {attachment = revised(attachment)}
            keptAttachments[index] = attachment
        }
        var tasks = Set(removed.filter {$0.type == "media_item"}.compactMap {$0.value["task_id"] as? String}.map {Data($0.utf8)})
        if let task = round["task_id"] as? String {tasks.insert(Data(task.utf8))}
        tasks.formUnion(keptAttachments.compactMap {$0["task_id"] as? String}.map {Data($0.utf8)})
        let attachments = removed.filter {$0.type == "attachment"}.map {row -> (String,JSON) in
            var value = row.value;value["media_cleanup_round_id"] = rid;return (row.type,value)
        }
        let keptObjects = try ticketObjectDeletionObjects(db,owned:keptAttachments.map {("attachment",$0)})
        let keptPaths = Set(keptObjects.compactMap {$0["relative_path"] as? String}.map {Data($0.utf8)})
        let importObjects = try mediaRoundDeletionImportObjects(db,jobs:removed.filter {$0.type == "storage_job" && $0.value["kind"] as? String == "attachment_import"}.map(\.value)).filter {object in
            guard let path = object["relative_path"] as? String else {return true}
            return !keptPaths.contains(Data(path.utf8))
        }
        var objects = try ticketObjectDeletionObjects(db,owned:attachments).filter {object in
            guard let path = object["relative_path"] as? String else {return true}
            return !keptPaths.contains(Data(path.utf8))
        }
        var positions: [Data:Int] = [:]
        for (index,object) in objects.enumerated() {if let path = object["relative_path"] as? String {positions[Data(path.utf8)] = index}}
        for object in importObjects {
            if let path = object["relative_path"] as? String,let index = positions[Data(path.utf8)] {
                var merged = objects[index]
                merged["owner_ids"] = Array(Set(strings(merged,"owner_ids") + strings(object,"owner_ids"))).sorted()
                var reasons = Set(strings(merged,"reasons") + strings(object,"reasons"))
                if merged["sha256"] as? String != object["sha256"] as? String || (merged["size"] as? NSNumber) != (object["size"] as? NSNumber) {reasons.insert("ambiguous_identity")}
                if !reasons.isEmpty {merged["state"] = "retained";merged["reasons"] = reasons.sorted()}
                objects[index] = merged
            } else {
                if let path = object["relative_path"] as? String {positions[Data(path.utf8)] = objects.count}
                objects.append(object)
            }
        }
        let paths = Set(objects.flatMap {[$0["relative_path"] as? String,$0["stored_path"] as? String,($0["relative_path"] as? String).map {root.appendingPathComponent($0).path}].compactMap {$0}}.map {Data($0.utf8)})
        let needles = owned.union(paths)
        let holdDigests = Set(objects.compactMap {$0["sha256"] as? String}.map {Data($0.utf8)})
        let retainedAttachments = Set(keptAttachments.compactMap {($0["id"] as? String).map {Data($0.utf8)}})
        let supplementalBytes = try (keptAttachments + objects).reduce(0) {$0 + (try jsonString($1)).utf8.count}
        let batchGraph = removed.count + keptAttachments.count > DeletionGraph.rowLimit ||
            selectedBytes + supplementalBytes > DeletionGraph.byteLimit || objects.count > DeletionGraph.rowLimit
        let graphFinished = ProcessInfo.processInfo.systemUptime
        timing.record("reference_and_history_scan",rowsRead:removed.count + keptAttachments.count)
        let deletionTasks = tasks
        let handoffAttachments = handoffOnlyIDs
        @Sendable func observeReferences(_ snapshot: Database,partition: TicketCleanupRowRange? = nil,budget: MediaRoundDeletionReferenceBudget) throws -> MediaRoundDeletionReferences {
            try self.mediaRoundDeletionReferences(snapshot,owned:owned,retainedAttachments:retainedAttachments,
                                                  handoffOnlyIDs:handoffAttachments,needles:needles,holdDigests:holdDigests,
                                                  deletionTasks:deletionTasks,partition:partition,budget:budget)
        }
        var referenced = MediaRoundDeletionReferences(),referencesSeconds: TimeInterval = 0
        var parallelHistory: (MediaRoundDeletionHistory,TimeInterval)?
        let parallelBudget = MediaRoundDeletionReferenceBudget()
        let ranges = try TicketCleanupRowRange.split(db,count:MediaRoundDeletionReadWork.partitions)
        if let pieces = try MediaRoundDeletionReadWork.perform(db,read:{snapshot,index in
            let began = ProcessInfo.processInfo.systemUptime
            if index < ranges.count {
                let selection = try observeReferences(snapshot,partition:ranges[index],budget:parallelBudget)
                return .references(selection,ProcessInfo.processInfo.systemUptime-began)
            }
            let history = try MediaRoundDeletionHistory.select(snapshot,project:project,owned:owned,progressKey:progressKey,continuing:progress != nil,writerLimit:historyLimit,ordinaryLimit:DeletionGraph.rowLimit,ordinaryBytes:DeletionGraph.byteLimit,projectFinal:batchGraph)
            return .history(history,ProcessInfo.processInfo.systemUptime-began)
        }) {
            for piece in pieces {
                switch piece {
                case .references(let rows,let seconds):
                    referenced.merge(rows)
                    referencesSeconds = max(referencesSeconds,seconds)
                case .history(let history,let seconds):parallelHistory = (history,seconds)
                }
            }
        } else {
            let began = ProcessInfo.processInfo.systemUptime
            referenced = try observeReferences(db,budget:MediaRoundDeletionReferenceBudget())
            referencesSeconds = ProcessInfo.processInfo.systemUptime - began
        }
        var remaining = keptAttachments.map {attachment -> JSON in var value = attachment;value["record_type"] = "attachment";return value}
        remaining.append(contentsOf:referenced.rows)
        observedIDs.formUnion(referenced.ids)
        let referencesFinished = ProcessInfo.processInfo.systemUptime
        let history = try parallelHistory?.0 ?? MediaRoundDeletionHistory.select(db,project:project,owned:owned,progressKey:progressKey,continuing:progress != nil,writerLimit:historyLimit,ordinaryLimit:DeletionGraph.rowLimit,ordinaryBytes:DeletionGraph.byteLimit,projectFinal:batchGraph)
        timing.record("byte_cleanup",rowsRead:referenced.rowsRead)
        if history.continuing && !history.more {
            let liveImports = removed.filter { row in
                row.type == "storage_job" && row.value["kind"] as? String == "attachment_import"
                    && MediaRoundDeletionImportRecovery.receiptStates.contains(row.value["state"] as? String ?? "")
            }.map(\.id)
            if !liveImports.isEmpty {
                result = "waiting_for_import_recovery"
                throw MediaRoundDeletionImportRecovery.Pending(imports:liveImports)
            }
        }
        let historySelected = ProcessInfo.processInfo.systemUptime
        // The record reference scan and fence also apply to an empty round.
        // Interim passes change no files. With zero file descriptors, the final
        // graph commit has no byte authority to establish either.
        var cleanup = TicketObjectDeletionPlan(objects:[])
        if !history.more,!objects.isEmpty {
            cleanup = try ticketObjectDeletionPlan(db,owned:attachments,remaining:remaining,candidateObjects:objects)
        }
        for index in cleanup.objects.indices where strings(cleanup.objects[index],"reasons").contains("reader_lease") {
            cleanup.objects[index]["reader_hold_ids"] = try mediaRoundDeletionReaderHoldIDs(db,object:cleanup.objects[index])
        }
        let cleanupFinished = ProcessInfo.processInfo.systemUptime
        timing.record("fence_observation")
        let counts = removed.reduce(into:[String:Int]()) {$0[$1.type,default:0] += 1}
        observedIDs.formUnion(owned)
        let workspacePaths = objects.compactMap { object -> String? in
            guard let path = object["relative_path"] as? String else {return nil}
            // Staging objects retain their exact reference needles above. They
            // have no executable identity and never rearm for byte removal.
            if path.hasPrefix("staging/"),object["state"] as? String == "retained",
               object["sha256"] == nil,strings(object,"reasons").contains("staging_requires_import_recovery") {return nil}
            return root.appendingPathComponent(path).path
        }
        let fence = try MediaRoundDeletionFence(db,ids:observedIDs,events:history.events,commands:history.commands,needles:needles,pendingRequestTasks:tasks,holdDigests:holdDigests,filePaths:workspacePaths)
        let historyFinished = ProcessInfo.processInfo.systemUptime
        let audit: JSON = ["deleted":true,"round_id":rid,"project_id":project,"actor":c.principal,"actor_kind":c.isOwner ? "owner" : "agent","reason":reason,"counts":counts,"kept_attachments":keptAudit,
            "preparation_seconds":historyFinished-started,"preparation_timings":["graph_seconds":graphFinished-started,"references_seconds":referencesSeconds,"cleanup_seconds":cleanupFinished-historySelected,"history_seconds":historySelected-referencesFinished+historyFinished-cleanupFinished+(parallelHistory?.1 ?? 0)]]
        result = "complete"
        return .init(version:version,project:project,round:rid,predecessor:predecessor,records:removed,history:history,
                     historyProgress:progress,bytes:cleanup,audit:audit,keptAttachments:keptAttachments,
                     handoffOnlyIDs:handoffOnlyIDs,fence:fence,recordSizes:selectedSizes,batchGraph:batchGraph)
    }

    func mediaRoundDeletionReferences(_ snapshot: Database,owned: Set<Data>,retainedAttachments: Set<Data>,handoffOnlyIDs: Set<Data>,
                                      needles: Set<Data>,holdDigests: Set<Data>,deletionTasks: Set<Data>,
                                      partition: TicketCleanupRowRange? = nil,
                                      budget: MediaRoundDeletionReferenceBudget) throws -> MediaRoundDeletionReferences {
        let holdNeedles = needles.union(holdDigests)
        let needleLengths = Set(needles.map(\.count)),holdNeedleLengths = Set(holdNeedles.map(\.count))
        var selection = MediaRoundDeletionReferences()
        // The shared stream validates complete unrelated envelopes but returns
        // only headers above 16 KiB. Exact SQL matching admits relevant payloads
        // below the same safe bound; unrelated prose needs no second traversal.
        try self.streamTicketCleanupRows(snapshot,needles:needles.union(deletionTasks),holdDigests:holdDigests,partition:partition) {projected,size in
            selection.rowsRead += 1
            func projectMatches(_ row: PurgeRow) throws -> Bool {
                var inventory = TicketCleanupInventory();inventory.needles = needles
                return try self.ticketCleanupBatchLargeMatch(snapshot,row:row,inventory:inventory)
            }
            var row = projected
            if size > TicketCleanupInventory.projectionByteLimit,bool(row.value,"_cleanup_large_match") {
                // Linked ticket IDs only protect pending owner requests.
                if row.type == "project",!deletionTasks.isEmpty,try !projectMatches(row) {return}
                guard size <= TicketCleanupInventory.rowByteLimit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","A selected deletion reference exceeds the 4 MiB payload limit; nothing was removed.")}
                row = .init(id:row.id,type:row.type,project:row.project,value:try self.record(snapshot,row.id,type:row.type))
            }
            if owned.contains(row.key) {return}
            var value = row.value
            if retainedAttachments.contains(row.key) {
                guard handoffOnlyIDs.contains(row.key) else {return}
                // Only the proven handoff marker is exempt. Other exact
                // references still protect the round.
                value.removeValue(forKey:"media_cleanup_round_id")
            }
            let large = bool(value,"_cleanup_large_match")
            let pending = row.type == "request" && row.value["state"] as? String == "pending"
            let hold = row.type == "storage_hold"
            let targets = hold ? holdNeedles : needles
            let lengths = hold ? holdNeedleLengths : needleLengths
            var matches = large,pendingReference = false,traversalBudget = 2_000_000
            // Traverse every value under the existing graph bounds. Most text
            // atoms have no matching byte length and need no Data allocation.
            do {
                try TicketCleanupInventory.strings(value,{text in
                    guard (!matches || pending && !pendingReference),lengths.contains(text.utf8.count) else {return}
                    let token = Data(text.utf8)
                    matches = matches || targets.contains(token)
                    pendingReference = pendingReference || pending && owned.contains(token)
                },budget:&traversalBudget)
            } catch let error as CoreError where row.type == "project" && error.code == "REFERENCE_GRAPH_LIMIT" {
                if try projectMatches(row) {throw error}
                return
            }
            if pending,deletionTasks.contains(Data((row.value["task_id"] as? String ?? "").utf8)) || pendingReference || large {
                throw CoreError("MEDIA_OWNER_REQUEST_PENDING","Answer or cancel the unresolved owner request before deleting this round.")
            }
            let accounting = ["cleanup_job","cleanup_preview"].contains(row.type) || row.type == "storage_job" && [Self.ticketObjectDeletionKind,"archive_cleanup_delete","archive_cleanup_cursor"].contains(row.value["kind"] as? String ?? "")
            if accounting {return}
            if !hold,matches {
                throw CoreError("MEDIA_ROUND_REFERENCED","Another retained round, ticket or record still uses this round's records or files; nothing was removed.",details:["record_id":row.id,"record_type":row.type])
            }
            if hold && matches {
                if row.value["kind"] as? String == "media_reference",
                   ["owner_id","attachment_id"].contains(where: { field in
                       (row.value[field] as? String).map {owned.contains(Data($0.utf8))} == true
                   }) {
                    throw CoreError("MEDIA_ROUND_REFERENCED","A retained media reference still requires a round-owned record.",
                                    details:["record_id":row.id,"record_type":row.type])
                }
                try budget.charge(size)
                var value = row.value;value["record_type"] = row.type;selection.rows.append(value)
                selection.ids.insert(row.key)
            }
        }
        return selection
    }
}
